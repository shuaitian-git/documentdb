# Running MongoDB JStests Locally

This guide shows how to run MongoDB's official jstests against the DocumentDB gateway using the custom test harness.

## Prerequisites: have DocumentDB setup and running

### Option 1: Using DevContainer (Recommended)

1. Open this repository in VS Code with the Dev Containers extension
2. The devcontainer will automatically set up the environment
3. Follow steps 1-3 in `docs/v1/building.md` to build and start DocumentDB

### Option 2: Manual Setup

Ensure you have the following installed and running:
- PostgreSQL 16 with DocumentDB extensions on port 9712
- DocumentDB gateway on port 10260 with TLS enabled
- Legacy MongoDB shell (`mongo` command)

## Quick Start

```bash
# 1. Clone MongoDB 7.0.11 tests (jstests directory only)
git clone --branch r7.0.11 --depth 1 --filter=blob:none --sparse https://github.com/mongodb/mongo.git /tmp/mongo_r7.0.11
cd /tmp/mongo_r7.0.11
git sparse-checkout set jstests
cd -

# 2. Create test user (one-time setup)
./testing/jstests/create_scram_user.sh

# 3. Run tests
cd testing/jstests
python3 run_tests.py
```

## Detailed Setup

### 1. Clone MongoDB Test Repository

Clone only the `jstests` directory using Git sparse checkout (~10-20 MB instead of ~118 MB):

```bash
git clone --branch r7.0.11 --depth 1 --filter=blob:none --sparse https://github.com/mongodb/mongo.git /tmp/mongo_r7.0.11
cd /tmp/mongo_r7.0.11
git sparse-checkout set jstests
```

This downloads MongoDB 7.0.11's test suite which is required to run the jstests.

### 2. Install Legacy Mongo Shell

The legacy `mongo` shell (not `mongosh`) is required to run jstests. If using the devcontainer, this is already installed.

**Ubuntu/Debian:**
```bash
curl -JLO https://downloads.mongodb.org/linux/mongodb-shell-linux-x86_64-debian10-v6.0-latest.tgz
tar -xvzf mongodb-shell-linux-x86_64-debian10-v6.0-latest.tgz
sudo cp mongodb-linux-x86_64-debian10-6.0.0-rc5-30-g7dc5d8f/bin/mongo /usr/bin/mongo
rm mongodb-shell-linux-x86_64-debian10-v6.0-latest.tgz
rm -rf mongodb-linux-x86_64-debian10-6.0.0-rc5-30-g7dc5d8f

# Verify installation
mongo --version
# Should show: MongoDB shell version v6.0.x
```

### 3. Create Test User

The test harness requires a user with SCRAM-SHA-256 authentication:

```bash
./testing/jstests/create_scram_user.sh
```

This creates user `testuser` with password `Admin100` and SUPERUSER privileges.

## Running Tests

### Basic Usage

Run all tests defined in `jstests_baseline_70.csv`:
```bash
cd testing/jstests
python3 run_tests.py
```

### Filter Tests

Use `--filter` with a regex pattern to run specific tests:

```bash
# Run tests matching "timestamp"
python3 run_tests.py --filter timestamp

# Run tests in core/query directory
python3 run_tests.py --filter "core/query"

# Run a specific test
python3 run_tests.py --filter "cursor1"
```

### Command-Line Options

```bash
# Enable verbose output (shows test execution details)
python3 run_tests.py --verbose

# Use custom connection string
python3 run_tests.py --connection-string "mongodb://user:pass@host:port/?tls=true"

# Specify custom jstests directory
python3 run_tests.py --jstests-dir /path/to/mongo/jstests

# Disable collection cleanup between tests
python3 run_tests.py --no-drop-collections

# Disable retry logic for flaky tests
python3 run_tests.py --no-retries

# Specify custom output directory for logs
python3 run_tests.py --output-dir /path/to/logs
```

### View Test Results

Test results and detailed logs are saved to `~/tmp/jstests-results/` by default:

```bash
# View logs for failed tests only (they're the only ones written)
ls ~/tmp/jstests-results/

# View a specific test's output
cat ~/tmp/jstests-results/jstests_core_index_index8.js.log

# Check for unexpected failures
grep "UNEXPECTED FAIL" ~/tmp/jstests-results/*.log
```

## Test Manifest (jstests_baseline_70.csv)

The `jstests_baseline_70.csv` file defines which tests to run and their expected outcomes:

```csv
test_name,expected_outcome,comment
jstests/core/query/cursor/cursor1.js,Pass,
jstests/core/index/index8.js,Pass,
jstests/unsupported/feature.js,Fail,Known limitation
jstests/skip/this_test.js,Skip,Not applicable
```

### Expected Outcomes

- **Pass** - Test should succeed (exit code 0)
- **Fail** - Test is expected to fail (known DocumentDB limitation)
- **Skip** - Test should not be run

### Adding New Tests

To add tests:
1. Identify the test file path relative to the jstests directory
2. Add a new line to `jstests_baseline_70.csv` with the test path and expected outcome
3. Run the test to verify it works as expected

## Troubleshooting

### PostgreSQL/Gateway Not Running

**Error:** `Connection refused` or `Could not drop collections`

**Solution:**
```bash
# Check if PostgreSQL is running
ps aux | grep postgres

# Check if gateway is running
ps aux | grep documentdb_gateway

# Restart services (from repository root)
./scripts/start_oss_server.sh -s  # Stop
./scripts/start_oss_server.sh -c -g  # Start with gateway
```

### Authentication Failures

**Error:** `Invalid account` or `Authentication failed`

**Solution:**
```bash
# Recreate the test user
./testing/jstests/create_scram_user.sh

# Verify user exists
psql -h localhost -p 9712 -U documentdb -d postgres -c "SELECT usename FROM pg_user WHERE usename = 'testuser';"
```

### Tests Fail Unexpectedly

**Error:** Tests marked as `Pass` are failing

**Solution:**
```bash
# Run with verbose output to see details
python3 run_tests.py --filter <test_name> --verbose

# Check the detailed log file
cat ~/tmp/jstests-results/jstests_<test_path>.log

# Verify extensions are loaded
psql -h localhost -p 9712 -U documentdb -d postgres -c "SELECT extname FROM pg_extension WHERE extname LIKE '%documentdb%' OR extname LIKE '%rum%';"
```

### Missing Test Files

**Error:** `Test file not found`

**Solution:**
```bash
# Ensure MongoDB tests are cloned
ls /tmp/mongo_r7.0.11/jstests

# If missing, clone again
git clone --branch r7.0.11 --depth 1 --filter=blob:none --sparse https://github.com/mongodb/mongo.git /tmp/mongo_r7.0.11
cd /tmp/mongo_r7.0.11
git sparse-checkout set jstests
```

## Architecture

The test harness workflow:

1. **Load Test Manifest** - Reads `jstests_baseline_70.csv` to get test list and expected outcomes
2. **Pre-Test Cleanup** - Drops all collections to ensure test isolation
3. **Inject Compatibility Layer** - Loads `commonsetup.js` to patch MongoDB APIs for DocumentDB
4. **Execute Test** - Runs the jstest using the legacy `mongo` shell
5. **Compare Results** - Checks if actual outcome matches expected outcome
6. **Retry Logic** - Retries expected-pass tests up to 5 times on failure (for flaky tests)
7. **Generate Reports** - Writes detailed logs for failed/unexpected tests

### Key Components

- **run_tests.py** - Main test runner with retry logic and result tracking
- **jstests_baseline_70.csv** - Test manifest defining which tests to run
- **commonsetup.js** - Compatibility shim for DocumentDB-specific behavior
- **create_scram_user.sh** - Creates SCRAM-SHA-256 authenticated test user
- **sslEnabledParallelShell.js** - Helper for parallel shell operations with SSL
