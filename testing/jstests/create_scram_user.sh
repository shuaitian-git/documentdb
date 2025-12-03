#!/bin/bash

################################################################################
# SCRAM-SHA-256 User Creation for DocumentDB
#
# This script creates a user with a compatible 28-byte SCRAM-SHA-256
# salt, which is required for legacy mongo shell authentication.
################################################################################

set -e # Exit on error

# ============================================================================
# Configuration
# ============================================================================

# Endpoint configuration
MONGO_HOST="${MONGO_HOST:-localhost}"
MONGO_PORT="${MONGO_PORT:-10260}"
MONGO_USER="${MONGO_USER:-testuser}"
MONGO_PASSWORD="${MONGO_PASSWORD:-Admin100}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ============================================================================
# Helper Functions
# ============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ============================================================================
# SCRAM-SHA-256 User Creation (28-byte salt fix)
# ============================================================================

create_mongodb_compatible_user() {
    local username="$1"
    local password="$2"
    local pg_port="${3:-9712}"

    log_info "Creating MongoDB-compatible user: $username"

    # This Python script creates a SCRAM-SHA-256 hash with 28-byte salt
    # (MongoDB requirement) instead of PostgreSQL's default 16-byte salt
    local sql_commands
    sql_commands=$(python3 - "$password" "$username" <<'PYTHON_SCRIPT'
import hashlib
import base64
import secrets
import sys
import hmac

def create_scram_sha256(password, iterations=4096, salt_length=28):
    # Generate random salt
    salt = secrets.token_bytes(salt_length)
    
    # Normalize password (MongoDB uses SASLprep, we'll use simple UTF-8)
    password_normalized = password.encode('utf-8')
    
    # Generate salted password using PBKDF2
    salted_password = hashlib.pbkdf2_hmac('sha256', password_normalized, salt, iterations, dklen=32)
    
    # Generate client key and stored key using HMAC
    client_key = hmac.new(salted_password, b'Client Key', hashlib.sha256).digest()
    stored_key = hashlib.sha256(client_key).digest()
    
    # Generate server key using HMAC
    server_key = hmac.new(salted_password, b'Server Key', hashlib.sha256).digest()
    
    # Format the SCRAM hash
    scram_hash = f"SCRAM-SHA-256${iterations}:{base64.b64encode(salt).decode()}${base64.b64encode(stored_key).decode()}:{base64.b64encode(server_key).decode()}"
    return scram_hash

password = sys.argv[1]
username = sys.argv[2]
scram_hash = create_scram_sha256(password)

print(f"DROP USER IF EXISTS {username};")
print(f"CREATE USER {username} PASSWORD '{scram_hash}';")
print(f"ALTER USER {username} CREATEDB SUPERUSER;")
PYTHON_SCRIPT
)

    # Execute the SQL (requires psql access)
    log_info "Executing SQL to create user..."
    echo "$sql_commands" | psql -h localhost -p "$pg_port" -U documentdb -d postgres

    if [ $? -eq 0 ]; then
        log_info "User '$username' created successfully with 28-byte SCRAM salt"
    else
        log_error "Failed to create user"
        return 1
    fi
}

# ============================================================================
# Main Script
# ============================================================================

main() {
    log_info "Starting user creation process..."
    create_mongodb_compatible_user "$MONGO_USER" "$MONGO_PASSWORD"
    exit $?
}

main "$@"
