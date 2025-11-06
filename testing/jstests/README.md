# Guidance for running jstests with the custom harness

This document outlines the approach for running MongoDB's official `jstests` using a custom test harness that invokes the `mongo` shell, similar to the strategy used by `pgmongo`.

## Core Strategy

The fundamental idea is to execute each `.js` test file within a `mongo` shell process and determine the outcome based on the process's exit code. This avoids the complexity of re-implementing the entire `mongo` shell environment (assertions, commands, etc.) in a different language.

1.  **Test Runner**: A script (e.g., in Python or Bash) will be responsible for:
    *   Discovering all `*.js` test files.
    *   Reading a manifest/CSV file that maps test names to their expected outcomes (`Pass`, `Fail`, `Skip`).
    *   For each test, invoking `mongo <test_file.js> --eval "load('commonsetup.js');"`
    *   Comparing the `mongo` process's exit code to the expected outcome.
    *   Reporting any discrepancies (e.g., a test passed when it was expected to fail).

2.  **`commonsetup.js`**: This crucial JavaScript file is pre-loaded into the shell before the test runs. Its purpose is to "patch" the environment to make it compatible with our target database. This includes:
    *   Overriding built-in functions that don't apply (e.g., sharding-specific commands).
    *   Adding polyfills or helper functions.
    *   Potentially disabling tests dynamically by having them throw a specific exception.

3.  **Outcome Manifest (`expected_outcomes.csv`)**: A simple CSV file will track how each test is expected to behave. This allows us to accept that some tests will fail (due to unsupported features) without breaking the build.
    ```csv
    test_name,expected_outcome
    core/t1.js,Pass
    core/t2.js,Fail
    sharding/s1.js,Skip
    ```

## SCRAM-SHA-256 Authentication

A known issue with the legacy `mongo` shell is its handling of SCRAM-SHA-256 authentication. The shell may incorrectly calculate the salt. The `run_jstests_local.sh` script contains a workaround for this by manually generating a valid password hash and using it for authentication. This logic will need to be integrated into the final test runner.

## Future Work for `mongosh` and ECMAScript tests

This initial approach focuses on the legacy `mongo` shell. Supporting `mongosh` for modern tests will require significant additions:

*   **Asynchronous Handling**: The test runner must be adapted to handle the asynchronous nature of `mongosh`. It cannot simply launch the process and wait for it to exit. It will need a mechanism to wait for the test's main promise to resolve or reject.
*   **ECMAScript Features**: The test runner and any pre-loaded scripts must be compatible with modern JavaScript syntax.
*   **Separate Outcome Manifests**: It's likely that a separate manifest will be needed to track outcomes for tests run with `mongosh`, as test behavior may differ between the two shells.
