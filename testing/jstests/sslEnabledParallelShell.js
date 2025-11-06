/**
 * sslEnabledParallelShell.js - SSL and Authentication Support for Parallel Shells
 * 
 * This file overrides the startParallelShell() function to ensure that any
 * parallel shells spawned by tests use the same SSL and authentication settings
 * as the main test connection.
 * 
 * This is critical for tests that spawn additional connections to test
 * concurrent operations, transactions, or other multi-connection scenarios.
 * 
 */

(function() {
    'use strict';

    // Store the original startParallelShell if it exists
    var originalStartParallelShell = typeof startParallelShell !== 'undefined' ? startParallelShell : null;

    // Override startParallelShell to inject SSL and auth settings
    startParallelShell = function(jsCode, port, noConnect) {
        var args = ["mongo"];
        var x;

        // Convert function into call-string
        if (typeof(jsCode) == "function") {
            var id = Math.floor(Math.random() * 100000);
            jsCode = "var f" + id + " = " + jsCode.toString() + ";f" + id + "();"; 
        }
        else if (typeof(jsCode) == "string") {
            // jsCode is already a string, use as-is
        }
        else {
            throw Error("bad first argument to startParallelShell");
        }
        
        if (noConnect) {
            args.push("--nodb");
        } else if (typeof(db) == "object") {
            // Inject database context into parallel shell
            jsCode = "db = db.getSiblingDB('" + db.getName() + "');" + jsCode;
        }

        // Inject TestData into parallel shell if it exists
        if (typeof TestData !== 'undefined' && TestData) {
            jsCode = "TestData = " + tojson(TestData) + ";" + jsCode;
        }

        // Add SSL/TLS arguments
        args.push("--tls");
        args.push("--tlsAllowInvalidCertificates");
        
        // Add authentication from environment or use test credentials
        var username = _getEnv('MONGO_USERNAME') || 'testuser';
        var password = _getEnv('MONGO_PASSWORD') || 'testpassword';
        args.push("-u", username);
        args.push("-p", password);
        
        // Get host and port from current connection
        if (typeof db == "object") {
            var hostAndPort = db.getMongo().host.split(':');
            var host = hostAndPort[0];
            args.push("--host", host);
            if (!port && hostAndPort.length >= 2) {
                port = hostAndPort[1];
            }
        }
        
        if (port) {
            args.push("--port", port);
        }
        
        args.push("--eval", jsCode);

        // Start the parallel shell
        x = startMongoProgramNoConnect.apply(null, args);
        
        return function() {
            waitProgram(x);
        };
    };

    print("sslEnabledParallelShell.js loaded - parallel shells will use SSL and authentication");
})();
