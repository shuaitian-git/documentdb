/**
 * commonsetup.js - Environment Patcher for DocumentDB Testing
 * 
 * This file is injected into the mongo shell before running each test.
 * Its purpose is to patch the environment to make tests compatible with DocumentDB.
 * 
 * This includes:
 * - Stubbing out unsupported features (e.g., sharding commands)
 * - Overriding functions that have different behavior
 * - Adding polyfills or helper functions
 * - Setting up test environment variables
 */

(function() {
    'use strict';

    // Print a banner so we know this setup script is being loaded
    print("Loading commonsetup.js for DocumentDB compatibility...");

    // Example: Stub out sharding-related commands that DocumentDB doesn't support
    // This prevents tests from failing when they check for sharding capabilities
    if (typeof sh === 'undefined') {
        sh = {
            status: function() {
                throw new Error("Sharding is not supported in DocumentDB");
            },
            enableSharding: function() {
                throw new Error("Sharding is not supported in DocumentDB");
            }
        };
    }

    // Example: Override or stub functions as needed
    // Add more patches here as we discover incompatibilities

    print("commonsetup.js loaded successfully.");
})();
