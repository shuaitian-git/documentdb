#!/usr/bin/env python3
"""
DocumentDB Test Runner for MongoDB JStests

This script runs MongoDB's official jstests against a DocumentDB-compatible database.

1. Reads a test manifest (tests.csv) that lists tests and expected outcomes
2. For each test, runs it using the mongo shell with environment patching
3. Compares actual results with expected outcomes
4. Reports results and generates test reports

Usage:
    python3 run_tests.py [options]

Options:
    --jstests-dir DIR       Path to MongoDB jstests directory
    --mongo-shell PATH      Path to mongo shell executable (default: auto-detect)
    --connection-string URI MongoDB connection string (default: from env or localhost)
    --manifest FILE         Path to test manifest CSV (default: ./tests.csv)
    --commonsetup FILE      Path to commonsetup.js (default: ./commonsetup.js)
    --output-dir DIR        Directory for test output logs (default: ./test-results)
    --filter PATTERN        Run only tests matching pattern (regex)
    --verbose               Enable verbose output
    --parallel N            Run tests in parallel with N workers (default: 1)
"""

import argparse
import csv
import os
import subprocess
import sys
import re
from pathlib import Path
from dataclasses import dataclass
from typing import List, Optional
from enum import Enum
import json
from datetime import datetime

# ============================================================================
# Data Models
# ============================================================================

class TestOutcome(Enum):
    """Expected test outcome"""
    PASS = "pass"
    FAIL = "fail"
    SKIP = "skip"

class TestResult(Enum):
    """Actual test result"""
    PASSED = "passed"
    FAILED = "failed"
    SKIPPED = "skipped"
    ERROR = "error"

@dataclass
class TestCase:
    """Represents a single test case"""
    name: str
    expected_outcome: TestOutcome
    test_file: Path

@dataclass
class TestRun:
    """Results from running a single test"""
    test_case: TestCase
    result: TestResult
    exit_code: int
    duration_ms: float
    stdout: str
    stderr: str
    matches_expectation: bool

# ============================================================================
# Test Runner
# ============================================================================

class DocumentDBTestRunner:
    """Main test runner class"""
    
    def __init__(self, args):
        self.args = args
        self.jstests_dir = Path(args.jstests_dir).expanduser()
        self.mongo_shell = args.mongo_shell or self._find_mongo_shell()
        self.connection_string = args.connection_string
        self.manifest_file = Path(args.manifest)
        self.commonsetup_file = Path(args.commonsetup)
        self.ssl_helper_file = Path(args.ssl_helper) if hasattr(args, 'ssl_helper') else Path(__file__).parent / "sslEnabledParallelShell.js"
        self.output_dir = Path(args.output_dir)
        self.filter_pattern = re.compile(args.filter) if args.filter else None
        self.verbose = args.verbose
        self.drop_collections = args.drop_collections if hasattr(args, 'drop_collections') else True
        
        # Parse connection string to extract components
        self._parse_connection_string()
        
        # Create output directory
        self.output_dir.mkdir(parents=True, exist_ok=True)
        
        # Statistics
        self.total_tests = 0
        self.passed = 0
        self.failed = 0
        self.skipped = 0
        self.errors = 0
        self.unexpected_pass = 0
        self.unexpected_fail = 0
    
    def _find_mongo_shell(self) -> str:
        """Auto-detect mongo shell executable"""
        # Only use legacy mongo shell for jstests compatibility
        try:
            result = subprocess.run(['which', 'mongo'], capture_output=True, text=True)
            if result.returncode == 0:
                return result.stdout.strip()
        except Exception:
            pass
        raise RuntimeError("Could not find legacy mongo shell. Please specify with --mongo-shell")
    
    def _parse_connection_string(self):
        """Parse connection string to extract host, port, username, password"""
        # Simple parsing for host:port format
        # Format: mongodb://username:password@host:port or just host:port
        self.username = None
        self.password = None
        self.host = "localhost"
        self.port = "27017"
        
        conn_str = self.connection_string
        
        # Check for mongodb:// prefix
        if conn_str.startswith("mongodb://"):
            conn_str = conn_str[10:]  # Remove mongodb://
            
            # Check for username:password@
            if "@" in conn_str:
                auth, host_port = conn_str.split("@", 1)
                if ":" in auth:
                    self.username, self.password = auth.split(":", 1)
                conn_str = host_port
        
        # Parse host:port
        if ":" in conn_str:
            self.host, self.port = conn_str.split(":", 1)
        else:
            self.host = conn_str
    
    def load_tests(self) -> List[TestCase]:
        """Load test cases from the manifest CSV"""
        tests = []
        
        with open(self.manifest_file, 'r') as f:
            # Skip comment lines and empty lines before creating the CSV reader
            lines = [line for line in f if line.strip() and not line.strip().startswith('#')]
        
        # Parse the CSV from the filtered lines
        reader = csv.DictReader(lines)
        for row in reader:
            # Skip empty test names
            if not row.get('test_name') or not row['test_name'].strip():
                continue
            
            test_name = row['test_name'].strip()
            expected = TestOutcome(row['expected_outcome'].strip().lower())
            # If test_name starts with jstests/, construct path from repo root
            if test_name.startswith('jstests/'):
                test_file = self.jstests_dir.parent / test_name
            else:
                test_file = self.jstests_dir / test_name
            
            # Apply filter if specified
            if self.filter_pattern and not self.filter_pattern.search(test_name):
                continue
            
            tests.append(TestCase(
                name=test_name,
                expected_outcome=expected,
                test_file=test_file
            ))
        
        return tests
    
    def drop_all_collections(self, test_name: str) -> bool:
        """
        Drop all collections in all databases before running a test.
        This ensures test isolation and prevents test interference.
        """
        if not self.drop_collections:
            return True
        
        drop_script = """
        var dbs = db.getMongo().getDBNames();
        for(var i in dbs) {
            var dbName = dbs[i];
            // Skip system databases
            if (dbName == 'admin' || dbName == 'config' || dbName == 'local') {
                continue;
            }
            var database = db.getMongo().getDB(dbName);
            var colls = database.getCollectionNames();
            for(var j in colls) {
                var collName = colls[j];
                // Skip system collections
                if (collName.startsWith('system.')) {
                    continue;
                }
                database.getCollection(collName).drop();
            }
        }
        """
        
        cmd = [
            self.mongo_shell,
            self.connection_string,
            '--tls',
            '--tlsAllowInvalidCertificates',
            '--eval', drop_script
        ]
        
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=30
            )
            if result.returncode != 0:
                if self.verbose:
                    print(f"  Warning: Failed to drop collections: {result.stderr[:100]}")
                return False
            return True
        except Exception as e:
            if self.verbose:
                print(f"  Warning: Exception while dropping collections: {str(e)[:100]}")
            return False
    
    def log_test_name_to_server(self, test_name: str) -> bool:
        """
        Log test name to server by running a dummy command.
        This helps isolate connection failures from test failures.
        """
        # Escape special characters in test name for JavaScript string
        escaped_name = test_name.replace('\\', '\\\\').replace("'", "\\'")
        
        log_script = f"db.runCommand({{'TESTCASE: {escaped_name}':1}})"
        
        cmd = [
            self.mongo_shell,
            self.connection_string,
            '--tls',
            '--tlsAllowInvalidCertificates',
            '--eval', log_script
        ]
        
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=10
            )
            return result.returncode == 0 or 'command not found' in result.stdout.lower()
        except Exception:
            return False
    
    def run_test(self, test_case: TestCase) -> TestRun:
        """Run a single test case"""
        if self.verbose:
            print(f"Running: {test_case.name}")
        
        # Skip if requested
        if test_case.expected_outcome == TestOutcome.SKIP:
            return TestRun(
                test_case=test_case,
                result=TestResult.SKIPPED,
                exit_code=0,
                duration_ms=0,
                stdout="",
                stderr="",
                matches_expectation=True
            )
        
        # Check if test file exists
        if not test_case.test_file.exists():
            return TestRun(
                test_case=test_case,
                result=TestResult.ERROR,
                exit_code=-1,
                duration_ms=0,
                stdout="",
                stderr=f"Test file not found: {test_case.test_file}",
                matches_expectation=False
            )
        
        # Pre-test cleanup: Drop all collections
        if self.verbose:
            print(f"  Dropping collections...")
        if not self.drop_all_collections(test_case.name):
            if self.verbose:
                print(f"  Warning: Could not drop collections, continuing anyway")
        
        # Log test name to server for debugging
        if self.verbose:
            print(f"  Logging test name to server...")
        if not self.log_test_name_to_server(test_case.name):
            if self.verbose:
                print(f"  Warning: Could not log test name (connection issue?)")
        
        # Get test name without extension for JS_TEST_NAME environment variable
        test_name_no_ext = Path(test_case.name).stem
        
        # Build mongo shell command
        # Load SSL helper first, then commonsetup.js, then the test file
        cmd = [
            self.mongo_shell,
            self.connection_string,
            '--tls',
            '--tlsAllowInvalidCertificates',
        ]
        
        # Load SSL helper if it exists
        if self.ssl_helper_file.exists():
            cmd.append(str(self.ssl_helper_file.absolute()))
        
        # Load commonsetup.js
        cmd.append(str(self.commonsetup_file.absolute()))
        
        # Load the actual test file
        cmd.append(str(test_case.test_file))
        
        # Set up environment variables for the test
        env = os.environ.copy()
        env['JS_TEST_NAME'] = test_name_no_ext
        env['TEST_ROOT_DIR'] = str(Path.cwd())
        env['MONGO_TEST_WORKING_DIR'] = str(self.jstests_dir.parent)
        
        # Add username/password to environment for SSL helper
        if self.username:
            env['MONGO_USERNAME'] = self.username
        if self.password:
            env['MONGO_PASSWORD'] = self.password
        
        # Run the test
        # Set working directory to MongoDB repo root so tests can find helper files
        start_time = datetime.now()
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=300,  # 5 minute timeout per test
                cwd=str(self.jstests_dir.parent),  # Run from /tmp/mongo_r7.0.11
                env=env
            )
            duration_ms = (datetime.now() - start_time).total_seconds() * 1000
            exit_code = result.returncode
            stdout = result.stdout
            stderr = result.stderr
        except subprocess.TimeoutExpired:
            duration_ms = 300000
            exit_code = -1
            stdout = ""
            stderr = "Test timed out after 5 minutes"
        except Exception as e:
            duration_ms = (datetime.now() - start_time).total_seconds() * 1000
            exit_code = -1
            stdout = ""
            stderr = str(e)
        
        # Determine result
        if exit_code == 0:
            result_status = TestResult.PASSED
        else:
            result_status = TestResult.FAILED
        
        # Check if result matches expectation
        matches = self._check_expectation(test_case.expected_outcome, result_status)
        
        return TestRun(
            test_case=test_case,
            result=result_status,
            exit_code=exit_code,
            duration_ms=duration_ms,
            stdout=stdout,
            stderr=stderr,
            matches_expectation=matches
        )
    
    def _check_expectation(self, expected: TestOutcome, actual: TestResult) -> bool:
        """Check if actual result matches expected outcome"""
        if expected == TestOutcome.PASS:
            return actual == TestResult.PASSED
        elif expected == TestOutcome.FAIL:
            return actual == TestResult.FAILED
        else:  # SKIP
            return True
    
    def report_test_result(self, run: TestRun):
        """Print test result to console"""
        test_name = run.test_case.name
        result = run.result.value
        duration = f"{run.duration_ms:.2f}ms"
        
        if run.matches_expectation:
            if run.result == TestResult.SKIPPED:
                symbol = "⊘"
                color = "\033[0;33m"  # Yellow
                self.skipped += 1
            elif run.result == TestResult.PASSED:
                symbol = "✓"
                color = "\033[0;32m"  # Green
                self.passed += 1
            else:  # Expected fail
                symbol = "✓"
                color = "\033[0;32m"  # Green (expected to fail)
                self.passed += 1
        else:
            symbol = "✗"
            color = "\033[0;31m"  # Red
            if run.result == TestResult.PASSED:
                self.unexpected_pass += 1
                result = "UNEXPECTED PASS"
            else:
                self.unexpected_fail += 1
                result = "UNEXPECTED FAIL"
            self.failed += 1
        
        reset = "\033[0m"
        print(f"{color}{symbol}{reset} {test_name} - {result} ({duration})")
        
        if not run.matches_expectation and self.verbose:
            print(f"  Expected: {run.test_case.expected_outcome.value}")
            print(f"  Exit code: {run.exit_code}")
            if run.stderr:
                print(f"  Error: {run.stderr[:200]}")
    
    def write_test_output(self, run: TestRun):
        """Write detailed test output to file"""
        output_file = self.output_dir / f"{run.test_case.name.replace('/', '_')}.log"
        output_file.parent.mkdir(parents=True, exist_ok=True)
        
        with open(output_file, 'w') as f:
            f.write(f"Test: {run.test_case.name}\n")
            f.write(f"Expected: {run.test_case.expected_outcome.value}\n")
            f.write(f"Result: {run.result.value}\n")
            f.write(f"Exit Code: {run.exit_code}\n")
            f.write(f"Duration: {run.duration_ms:.2f}ms\n")
            f.write(f"Matches Expectation: {run.matches_expectation}\n")
            f.write(f"\n=== STDOUT ===\n{run.stdout}\n")
            f.write(f"\n=== STDERR ===\n{run.stderr}\n")
    
    def run_all_tests(self) -> int:
        """Run all tests and return exit code"""
        print(f"Loading tests from: {self.manifest_file}")
        tests = self.load_tests()
        self.total_tests = len(tests)
        
        print(f"Found {self.total_tests} tests to run")
        print(f"Using mongo shell: {self.mongo_shell}")
        print(f"Connection string: {self.connection_string}")
        print(f"Output directory: {self.output_dir}")
        print("")
        
        # Run each test
        for test in tests:
            run = self.run_test(test)
            self.report_test_result(run)
            self.write_test_output(run)
        
        # Print summary
        print("\n" + "=" * 80)
        print("TEST SUMMARY")
        print("=" * 80)
        print(f"Total:            {self.total_tests}")
        print(f"Passed:           {self.passed}")
        print(f"Failed:           {self.failed}")
        print(f"Skipped:          {self.skipped}")
        print(f"Unexpected Pass:  {self.unexpected_pass}")
        print(f"Unexpected Fail:  {self.unexpected_fail}")
        print("=" * 80)
        
        # Return non-zero exit code if there were unexpected results
        if self.unexpected_pass > 0 or self.unexpected_fail > 0:
            return 1
        return 0

# ============================================================================
# Main Entry Point
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="DocumentDB Test Runner for MongoDB JStests",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )
    
    parser.add_argument(
        '--jstests-dir',
        default='/tmp/mongo_r7.0.11/jstests',
        help='Path to MongoDB jstests directory (default: MongoDB 7.0.11)'
    )
    parser.add_argument(
        '--mongo-shell',
        help='Path to mongo shell executable (auto-detect if not specified)'
    )
    parser.add_argument(
        '--connection-string',
        default=os.environ.get('MONGO_CONNECTION_STRING', 
                              'mongodb://testuser:Admin100@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true'),
        help='MongoDB connection string'
    )
    parser.add_argument(
        '--manifest',
        default='tests.csv',
        help='Path to test manifest CSV'
    )
    parser.add_argument(
        '--commonsetup',
        default='commonsetup.js',
        help='Path to commonsetup.js'
    )
    parser.add_argument(
        '--ssl-helper',
        default='sslEnabledParallelShell.js',
        help='Path to SSL helper JS file'
    )
    parser.add_argument(
        '--output-dir',
        default=str(Path.home() / 'tmp' / 'jstests-results'),
        help='Directory for test output logs'
    )
    parser.add_argument(
        '--filter',
        help='Run only tests matching pattern (regex)'
    )
    parser.add_argument(
        '--verbose',
        action='store_true',
        help='Enable verbose output'
    )
    parser.add_argument(
        '--no-drop-collections',
        dest='drop_collections',
        action='store_false',
        default=True,
        help='Skip dropping collections before each test'
    )
    parser.add_argument(
        '--parallel',
        type=int,
        default=1,
        help='Run tests in parallel with N workers (not yet implemented)'
    )
    
    args = parser.parse_args()
    
    # Create and run test runner
    runner = DocumentDBTestRunner(args)
    exit_code = runner.run_all_tests()
    
    sys.exit(exit_code)

if __name__ == '__main__':
    main()
