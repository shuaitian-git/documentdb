/**
 * commonsetup.js - Environment Patcher for DocumentDB Testing
 * 
 * This file is injected into the mongo shell before running each test.
 * Its purpose is to patch the environment to make tests compatible with DocumentDB.
 * 
 * This includes:
 * - Setting up TestData and test environment variables
 * - Stubbing out unsupported features (e.g., sharding commands)
 * - Overriding functions that have different behavior
 * - Adding polyfills or helper functions
 * - Setting up test environment variables
 * 
 */

(function() {
    print("Loading commonsetup.js for DocumentDB compatibility...");

    // Many jstests expect TestData to exist and contain test metadata
    if (typeof TestData === 'undefined') {
        TestData = {};
    }
    
    // Test name from environment variable (set by test runner)
    TestData.testName = _getEnv('JS_TEST_NAME') || 'unknown';
    
    // Storage engine identifier
    TestData.storageEngine = "DocumentDB";
    
    // SSL/TLS is always enabled in our test environment
    TestData.useSSL = true;
    TestData.sslAllowInvalidCertificates = true;
    
    // We're not running in a sharded environment
    TestData.isSharded = false;
    
    print("  TestData.testName: " + TestData.testName);
    print("  TestData.storageEngine: " + TestData.storageEngine);


    /* Set up TestsDirectoryInfo object. */
    // Provides paths to test directories for tests that need to load helpers
    if (typeof TestsDirectoryInfo === 'undefined') {
        TestsDirectoryInfo = {};
    }
    
    TestsDirectoryInfo.rootDir = _getEnv('TEST_ROOT_DIR') || '';
    
    TestsDirectoryInfo.mongoTestsRoot = _getEnv('MONGO_TEST_WORKING_DIR') || '';
    
    // For compatibility, set same value for mongoTestVersionRoot
    TestsDirectoryInfo.mongoTestVersionRoot = TestsDirectoryInfo.mongoTestsRoot;
    
    if (TestsDirectoryInfo.mongoTestsRoot) {
        print("  The jstests root: " + TestsDirectoryInfo.mongoTestsRoot);
    }

    /* Stub out sharding-related features */
    // DocumentDB doesn't support sharding, so we stub out sharding commands
    if (typeof sh === 'undefined') {
        sh = {
            status: function() {
                return {
                    ok: 0,
                    errmsg: "Sharding is not supported in DocumentDB"
                };
            },
            enableSharding: function() {
                throw new Error("Sharding is not supported in DocumentDB");
            },
            shardCollection: function() {
                throw new Error("Sharding is not supported in DocumentDB");
            },
            addShard: function() {
                throw new Error("Sharding is not supported in DocumentDB");
            },
            getBalancerState: function() {
                return false;
            }
        };
    }

    /* Override isdbgrid() to return false */
    // Some tests check if they're running against mongos (isdbgrid)
    // We're not a sharded cluster, so always return false
    var originalIsdbgrid = typeof isdbgrid !== 'undefined' ? isdbgrid : null;
    isdbgrid = function() {
        return false;
    };

    print("commonsetup.js loaded successfully.");
})();
