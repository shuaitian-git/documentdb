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
import time

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
    
    # Constants for retry logic
    MAX_FLAKY_TEST_RETRIES = 5  # Retry expected-pass tests up to 5 times
    
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
        self.enable_retries = getattr(args, 'enable_retries', True)
        self.check_transactions = getattr(args, 'check_transactions', False)
        self.pg_host = getattr(args, 'pg_host', 'localhost')
        self.pg_port = getattr(args, 'pg_port', 5432)
        
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
        self.unexpected_failures = []  # List of test names that unexpectedly failed
        self.unexpected_passes = []  # List of test names that unexpectedly passed
    
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
    
    def drop_all_collections(self, test_name: str, max_retries: int = 3) -> bool:
        """
        Drop all collections from all databases (except admin, config, local).
        
        CRITICAL:
        - Simple drop loop (no inline verification - that caused issues)
        - Retry on failure via ExecuteShellCommandWithRetry
        - Assert.Fail if drop command fails (we return False, caller fails test)
        - Rely on synchronous shell command (no explicit waits)
        """
        if not self.drop_collections:
            return True
        
        # JavaScript to drop all collections
        drop_script = """
        var dbs = db.getMongo().getDBNames();
        for(var i in dbs) {
            if (dbs[i] == 'config' || dbs[i] == 'admin' || dbs[i] == 'local') {
                continue;
            }
            var database = db.getMongo().getDB(dbs[i]);
            var colls = database.getCollectionNames();
            for(var j in colls) {
                if (!colls[j].startsWith('system.')) {
                    database.getCollection(colls[j]).drop();
                }
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
        
        # RETRY LOGIC
        for attempt in range(max_retries):
            if attempt > 0 and self.verbose:
                print(f"  Retrying drop (attempt {attempt + 1}/{max_retries})...")
            
            try:
                result = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    timeout=30
                )
                
                # If shell command succeeds, drop is complete
                # No verification, no waits - trust synchronous shell execution
                if result.returncode == 0:
                    return True
                
                if self.verbose:
                    print(f"  Drop failed (attempt {attempt + 1}): {result.stderr[:100]}")
            
            except Exception as e:
                if self.verbose:
                    print(f"  Drop exception (attempt {attempt + 1}): {str(e)[:100]}")
        
        # ALL RETRIES FAILED
        return False
    
    def verify_collections_dropped(self) -> tuple[bool, str]:
        """
        Verify that all non-system collections were actually dropped.
        Returns (success, error_message).
        
        This provides extra assurance that cleanup completed, which is important
        for diagnosing flaky test failures.
        """
        verify_script = """
        var dbs = db.getMongo().getDBNames();
        var foundCollections = [];
        for(var i in dbs) {
            var dbName = dbs[i];
            if (dbName == 'admin' || dbName == 'config' || dbName == 'local') {
                continue;
            }
            var database = db.getMongo().getDB(dbName);
            var colls = database.getCollectionNames();
            for(var j in colls) {
                if (!colls[j].startsWith('system.')) {
                    foundCollections.push(dbName + '.' + colls[j]);
                }
            }
        }
        if (foundCollections.length > 0) {
            print('LEFTOVER_COLLECTIONS:' + foundCollections.join(','));
            quit(1);
        }
        """
        
        cmd = [
            self.mongo_shell,
            self.connection_string,
            '--tls',
            '--tlsAllowInvalidCertificates',
            '--eval', verify_script
        ]
        
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=10
            )
            if result.returncode != 0:
                # Found leftover collections
                error_lines = result.stdout.split('\n')
                for line in error_lines:
                    if 'LEFTOVER_COLLECTIONS:' in line:
                        colls = line.split(':', 1)[1]
                        return False, f"Found leftover collections: {colls}"
                return False, f"Verification failed: {result.stderr[:100]}"
            return True, ""
        except Exception as e:
            return False, f"Verification exception: {str(e)[:100]}"
    
    def force_close_connections(self) -> bool:
        """
        Force close all idle connections to prevent connection leaks.
        This helps with test isolation during long runs.
        """
        close_script = """
        // Close this connection cleanly
        db.adminCommand({serverStatus: 1});
        """
        
        cmd = [
            self.mongo_shell,
            self.connection_string,
            '--tls',
            '--tlsAllowInvalidCertificates',
            '--eval', close_script
        ]
        
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=5
            )
            return result.returncode == 0
        except Exception:
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
    
    def check_active_transactions(self) -> List[dict]:
        """
        Check for active PostgreSQL transactions that might indicate test leaks.
        Returns list of transactions in 'idle in transaction' state.
        """
        if not self.check_transactions:
            return []
        
        try:
            # Try to use psycopg2 if available
            try:
                import psycopg2
                conn = psycopg2.connect(
                    host=self.pg_host,
                    port=self.pg_port,
                    database='postgres',
                    user='postgres'
                )
                cursor = conn.cursor()
                cursor.execute("""
                    SELECT pid, state, query, state_change 
                    FROM pg_stat_activity 
                    WHERE state = 'idle in transaction'
                    AND pid != pg_backend_pid()
                """)
                rows = cursor.fetchall()
                cursor.close()
                conn.close()
                
                return [
                    {'pid': row[0], 'state': row[1], 'query': row[2], 'state_change': str(row[3])}
                    for row in rows
                ]
            except ImportError:
                # Fall back to psql command
                result = subprocess.run(
                    [
                        'psql',
                        '-h', self.pg_host,
                        '-p', str(self.pg_port),
                        '-U', 'postgres',
                        '-d', 'postgres',
                        '-t',  # tuples only
                        '-A',  # unaligned
                        '-c', "SELECT pid, state, query FROM pg_stat_activity WHERE state = 'idle in transaction'"
                    ],
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                if result.returncode == 0 and result.stdout.strip():
                    transactions = []
                    for line in result.stdout.strip().split('\n'):
                        parts = line.split('|')
                        if len(parts) >= 3:
                            transactions.append({'pid': parts[0], 'state': parts[1], 'query': parts[2]})
                    return transactions
                return []
        except Exception as e:
            if self.verbose:
                print(f"  Warning: Could not check for active transactions: {e}")
            return []
    
    def run_test(self, test_case: TestCase) -> TestRun:
        """
        Run a single test case with retry logic.
        Expected-pass tests are retried up to 5 times on failure
        Expected-fail tests are not retried.
        """
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
        
        # Determine retry strategy based on expected outcome
        # Expected-pass tests: retry up to 5 times (for flaky tests)
        # Expected-fail tests: no retries
        max_attempts = self.MAX_FLAKY_TEST_RETRIES if (
            self.enable_retries and test_case.expected_outcome == TestOutcome.PASS
        ) else 1
        
        # Try running the test with retries
        all_outputs = []
        for attempt in range(1, max_attempts + 1):
            if attempt > 1:
                if self.verbose:
                    print(f"  Retry attempt {attempt}/{max_attempts}")
                # Small delay between retries
                time.sleep(1)
            
            # Run the test (single attempt)
            test_run = self._run_test_single_attempt(test_case)
            all_outputs.append(f"--- Attempt {attempt} ---\n{test_run.stdout}\n{test_run.stderr}")
            
            # If result matches expectation, we're done
            if test_run.matches_expectation:
                return test_run
            
            # If this is not the last attempt, continue retrying
            if attempt < max_attempts:
                continue
            
            # Last attempt failed - return with combined output
            test_run.stdout = "\n\n".join(all_outputs)
            test_run.stderr = f"Failed after {max_attempts} attempts"
            return test_run
        
        # Should never reach here, but return last run just in case
        return test_run
    
    def _run_test_single_attempt(self, test_case: TestCase) -> TestRun:
        """Execute a single test attempt without retry logic"""
        
        # Pre-test cleanup: Drop all collections
        # FAIL TEST if cleanup fails
        # Running a test on dirty state leads to flaky failures
        if self.verbose:
            print(f"  Dropping collections...")
        if not self.drop_all_collections(test_case.name):
            # FAIL IMMEDIATELY - don't run test on dirty state
            error_msg = f"CLEANUP FAILED: Could not drop collections before test '{test_case.name}'.\n"
            error_msg += "(Assert.Fail on cleanup failure).\n"
            error_msg += "Test isolation requires clean state - dirty state leads to flaky failures."
            
            if self.verbose:
                print(f"  ❌ CLEANUP FAILED - Test will not run")
            
            return TestRun(
                test_case=test_case,
                result=TestResult.ERROR,
                exit_code=-1,
                duration_ms=0,
                stdout="",
                stderr=error_msg,
                matches_expectation=False
            )
        
        # Drop succeeded
        # No verification, no waits - just proceed to run the test
        
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
        
        # Post-test check: Look for transaction leaks
        active_txns = self.check_active_transactions()
        if active_txns:
            txn_info = f"\n\nWARNING: {len(active_txns)} active transaction(s) found after test:\n"
            for txn in active_txns[:3]:  # Show first 3
                txn_info += f"  PID {txn.get('pid')}: {txn.get('query', '')[:80]}\n"
            stderr += txn_info
            if self.verbose:
                print(f"  ⚠️  Transaction leak detected: {len(active_txns)} active")
        
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
                self.unexpected_passes.append(test_name)
                result = "UNEXPECTED PASS"
            else:
                self.unexpected_fail += 1
                self.unexpected_failures.append(test_name)
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
        
        # Record start time
        from datetime import datetime
        start_time = datetime.now()
        
        # Run each test
        for idx, test in enumerate(tests, 1):
            run = self.run_test(test)
            self.report_test_result(run)
            
            # Only write log file if test failed or didn't match expectation
            if not run.matches_expectation:
                self.write_test_output(run)
        
        # Calculate total duration
        end_time = datetime.now()
        total_duration = end_time - start_time
        hours, remainder = divmod(int(total_duration.total_seconds()), 3600)
        minutes, seconds = divmod(remainder, 60)
        
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
        if hours > 0:
            print(f"Duration:         {hours}h {minutes}m {seconds}s")
        elif minutes > 0:
            print(f"Duration:         {minutes}m {seconds}s")
        else:
            print(f"Duration:         {seconds}s")
        print("=" * 80)
        
        # Print list of unexpected failures if any
        if self.unexpected_failures:
            print("\n" + "=" * 80)
            print("UNEXPECTEDLY FAILED TESTS")
            print("=" * 80)
            for test_name in self.unexpected_failures:
                print(f"  - {test_name}")
            print("=" * 80)
            print(f"\nTo rerun only failed tests, create a CSV with these tests and use:")
            print(f"  python3 run_tests.py --manifest <your_failed_tests.csv>")
        
        # Print list of unexpected passes if any
        if self.unexpected_passes:
            print("\n" + "=" * 80)
            print("UNEXPECTEDLY PASSED TESTS")
            print("=" * 80)
            for test_name in self.unexpected_passes:
                print(f"  - {test_name}")
            print("=" * 80)
            print(f"\nThese tests were expected to fail but passed!")
            print(f"Consider updating tests.csv to mark them as 'pass'")
        
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
        '--no-retries',
        dest='enable_retries',
        action='store_false',
        default=True,
        help='Disable retry logic for flaky tests (expected-pass tests retry up to 5 times by default)'
    )
    parser.add_argument(
        '--check-transactions',
        dest='check_transactions',
        action='store_true',
        default=False,
        help='Check for transaction leaks after each test (requires PostgreSQL access)'
    )
    parser.add_argument(
        '--pg-host',
        default='localhost',
        help='PostgreSQL host for transaction leak detection (default: localhost)'
    )
    parser.add_argument(
        '--pg-port',
        type=int,
        default=5432,
        help='PostgreSQL port for transaction leak detection (default: 5432)'
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
