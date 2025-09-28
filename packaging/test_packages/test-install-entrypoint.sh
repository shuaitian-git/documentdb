#!/bin/bash
set -e

# Change to the test directory
cd /test-install

# Run the test
adduser --disabled-password --gecos "" documentdb
chown -R documentdb:documentdb .
su documentdb -c "make check"