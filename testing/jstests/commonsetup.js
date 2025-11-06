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
 * NOTE: We don't use 'use strict' here because we need to set global variables
 * and strict mode in an IIFE makes 'this' undefined in the mongo shell.
 */

(function() {
    print("Loading commonsetup.js for DocumentDB compatibility...");

    // ========================================================================
    // 1. Set up TestData object
    // ========================================================================
    // Many MongoDB tests expect TestData to exist and contain test metadata
    if (typeof TestData === 'undefined') {
        TestData = {};
    }
    
    // Test name from environment variable (set by test runner)
    TestData.testName = _getEnv('JS_TEST_NAME') || 'unknown';
    
    // Storage engine identifier (for test compatibility)
    TestData.storageEngine = "DocumentDB";
    
    // SSL/TLS is always enabled in our test environment
    TestData.useSSL = true;
    TestData.sslAllowInvalidCertificates = true;
    
    // We're not running in a sharded environment
    TestData.isSharded = false;
    
    print("  TestData.testName: " + TestData.testName);
    print("  TestData.storageEngine: " + TestData.storageEngine);

    // ========================================================================
    // 2. Set up TestsDirectoryInfo object
    // ========================================================================
    // Provides paths to test directories for tests that need to load helpers
    if (typeof TestsDirectoryInfo === 'undefined') {
        TestsDirectoryInfo = {};
    }
    
    // Root directory of the test project
    TestsDirectoryInfo.rootDir = _getEnv('TEST_ROOT_DIR') || '';
    
    // MongoDB test repository root (where jstests/ directory is located)
    TestsDirectoryInfo.mongoTestsRoot = _getEnv('MONGO_TEST_WORKING_DIR') || '';
    
    // For compatibility, set same value for mongoTestVersionRoot
    TestsDirectoryInfo.mongoTestVersionRoot = TestsDirectoryInfo.mongoTestsRoot;
    
    if (TestsDirectoryInfo.mongoTestsRoot) {
        print("  MongoDB tests root: " + TestsDirectoryInfo.mongoTestsRoot);
    }

    // ========================================================================
    // 3. Stub out sharding-related features
    // ========================================================================
    // DocumentDB doesn't support sharding, so we stub out sharding commands
    // to prevent tests from failing when checking for sharding capabilities
    
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

    // ========================================================================
    // 4. Override isdbgrid() to return false
    // ========================================================================
    // Some tests check if they're running against mongos (isdbgrid)
    // We're not a sharded cluster, so always return false
    var originalIsdbgrid = typeof isdbgrid !== 'undefined' ? isdbgrid : null;
    isdbgrid = function() {
        return false;
    };

    // ========================================================================
    // 5. Additional compatibility patches
    // ========================================================================
    
    // Helper function to check if we're in DocumentDB mode
    function isDocumentDB() {
        return true;
    }
    
    // Make it globally available
    if (typeof globalThis !== 'undefined') {
        globalThis.isDocumentDB = isDocumentDB;
    }

    print("commonsetup.js loaded successfully.");
})();
