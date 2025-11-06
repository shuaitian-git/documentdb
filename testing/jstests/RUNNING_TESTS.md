# Running MongoDB JStests Locally

This guide shows how to run MongoDB's official jstests against the DocumentDB gateway using the custom test harness.

## Quick Start

```bash
# 1. Start PostgreSQL and DocumentDB gateway
./scripts/build_and_start_gateway.sh -u testuser -p Admin100

# 2. Clone MongoDB 7.0.11 tests
git clone --branch r7.0.11 --depth 1 https://github.com/mongodb/mongo.git /tmp/mongo_r7.0.11

# 3. Make sure legacy mongo shell exist
mongo --version

# 4. One-time setup: Create test user
./testing/jstests/create_scram_user.sh

# 5. Run tests
cd testing/jstests
python3 run_tests.py
```

## Detailed Setup

### 1. Start the Gateway

Make sure servers are running:
- PostgreSQL 16 on port 9712
- DocumentDB gateway on port 10260 with TLS

### 2. Clone MongoDB Test Repository

First time only:
```bash
git clone --branch r7.0.11 --depth 1 https://github.com/mongodb/mongo.git /tmp/mongo_r7.0.11
```

This downloads MongoDB 7.0.11's test suite (~118 MB, takes ~30 seconds).

### 3. Install Mongo Shell

The legacy `mongo` shell is required to run jstests:

```bash
# Ubuntu/Debian
curl -JLO https://downloads.mongodb.org/linux/mongodb-shell-linux-x86_64-debian10-v6.0-latest.tgz
tar -xvzf mongodb-shell-linux-x86_64-debian10-v6.0-latest.tgz
cp mongodb-linux-x86_64-debian10-6.0.0-rc5-30-g7dc5d8f/bin/mongo /usr/bin/mongo
rm mongodb-shell-linux-x86_64-debian10-v6.0-latest.tgz
rm -rf mongodb-linux-x86_64-debian10-6.0.0-rc5-30-g7dc5d8f

# Verify installation
mongo --version
# Should show: MongoDB shell version v6.0.x or similar
```

### 4. Create Test User

The test harness expects a user with SCRAM-SHA-256 authentication:

```bash
./testing/jstests/create_scram_user.sh
```

This creates user `testuser` with password `Admin100`.

## Running Tests

### Run All Tests

```bash
cd testing/jstests
python3 run_tests.py
```

### Run Specific Tests

Use `--filter` with a regex pattern:

```bash
# Run only tests matching "timestamp"
python3 run_tests.py --filter timestamp

# Run tests in a specific directory
python3 run_tests.py --filter "^core/"
```

### Verbose Output

```bash
python3 run_tests.py --verbose
```

### Custom Connection String

```bash
python3 run_tests.py --connection-string "mongodb://user:pass@localhost:10260/?tls=true"
```

### View Test Results

Detailed logs are saved to `~/tmp/jstests-results/`:

```bash
# View a specific test's output
cat ~/tmp/jstests-results/core_db.js.log

# List all test results
ls -lh ~/tmp/jstests-results/
```

## Adding New Tests

Edit `tests.csv` to add more tests:

Expected outcomes:
- `pass` - Test should succeed (exit code 0)
- `fail` - Test is known to fail (expected)
- `skip` - Test should not be run

## Troubleshooting

### Connection refused
```bash
# Verify PostgreSQL is running on port 9712
psql -h localhost -p 9712 -U documentdb -d postgres -c "SELECT 1"

# Recreate the test user
./testing/jstests/create_scram_user.sh
```

### Test fails unexpectedly
```bash
# Run with verbose output
python3 run_tests.py --verbose

# Check the detailed log
cat ~/tmp/jstests-results/<test_name>.log
```

## Architecture

The test harness:
1. Loads test manifest from `tests.csv`
2. For each test, invokes: `mongo --eval 'load("commonsetup.js")' <test_file>`
3. Uses `commonsetup.js` to patch the environment for DocumentDB compatibility
4. Compares exit code to expected outcome
5. Generates detailed logs in `test-results/`
