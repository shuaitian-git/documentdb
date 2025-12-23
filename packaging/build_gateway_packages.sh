#!/bin/bash

set -euo pipefail

# set script_dir to the parent directory of the script
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Function to display help message
function show_help {
    echo "Usage: $0 [--test-clean-install --documentdb-package <PATH>] [--output-dir <DIR>] [-h|--help]"
    echo ""
    echo "Description:"
    echo "  This script builds the DocumentDB gateway package (DEB) using Docker."
    echo "  The gateway is distro-agnostic and PG-version agnostic."
    echo ""
    echo "Optional Arguments:"
    echo "  --test-clean-install     Test installing the gateway package in a clean Docker container."
    echo "                           Requires --documentdb-package to be specified."
    echo "  --documentdb-package     Path to DocumentDB .deb package (required for --test-clean-install)."
    echo "  --output-dir             Directory for output packages. Default: packaging"
    echo "  -h, --help               Display this help message."
    echo ""
    echo "Examples:"
    echo "  # Build gateway package only:"
    echo "  $0"
    echo ""
    echo "  # Build and test with existing DocumentDB package:"
    echo "  $0 --test-clean-install --documentdb-package packaging/deb12-postgresql-17-documentdb_0.109-0_amd64.deb"
    exit 0
}

# Initialize variables
TEST_CLEAN_INSTALL=false
DOCUMENTDB_PACKAGE=""
OUTPUT_DIR="packaging"

# Process arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --test-clean-install)
            TEST_CLEAN_INSTALL=true
            ;;
        --documentdb-package)
            shift
            DOCUMENTDB_PACKAGE=$1
            ;;
        --output-dir)
            shift
            OUTPUT_DIR=$1
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo "Unknown argument: $1"
            show_help
            exit 1
            ;;
    esac
    shift
done

# Validate test-clean-install requirements
if [[ $TEST_CLEAN_INSTALL == true && -z "$DOCUMENTDB_PACKAGE" ]]; then
    echo "Error: --documentdb-package is required when using --test-clean-install"
    show_help
    exit 1
fi

# Extract gateway version from Cargo.toml
GATEWAY_VERSION=$(grep '^version' "${script_dir}/pg_documentdb_gw/Cargo.toml" | head -n1 | sed 's/version *= *"\(.*\)"/\1/')
echo "Gateway version: $GATEWAY_VERSION"

abs_output_dir="$script_dir/$OUTPUT_DIR"

# Build configuration - gateway uses Debian bookworm as base (works on all Debian/Ubuntu)
DOCKERFILE="${script_dir}/packaging/deb/Dockerfile-deb-gateway"
DOCKER_IMAGE="rust:slim-bookworm"
TAG="documentdb-gateway-build:latest"

echo "Building gateway DEB package"
echo "Output directory: $abs_output_dir"

# Create the output directory if it doesn't exist
mkdir -p "$abs_output_dir"
chmod 777 "$abs_output_dir"

# Build the Docker image
docker build -t "$TAG" -f "$DOCKERFILE" \
    --build-arg BASE_IMAGE="$DOCKER_IMAGE" "$script_dir"

# Run the Docker container to build the package
docker run --rm -v "$abs_output_dir:/output" "$TAG"

echo "Gateway package built successfully!"

# Test clean installation if requested
if [[ $TEST_CLEAN_INSTALL == true ]]; then
    echo "Testing clean installation in a Docker container..."

    # Validate DocumentDB package exists
    if [[ ! -f "${script_dir}/${DOCUMENTDB_PACKAGE}" ]]; then
        echo "Error: DocumentDB package not found: ${DOCUMENTDB_PACKAGE}"
        exit 1
    fi

    # Extract PG version from package name (e.g., postgresql-17-documentdb -> 17)
    PG_VERSION=$(echo "$DOCUMENTDB_PACKAGE" | grep -oP 'postgresql-\K\d+' || echo "17")
    echo "Detected PostgreSQL version from package: $PG_VERSION"

    # Find the gateway package we just built
    gateway_package_name=$(ls "$abs_output_dir" | grep -E "^documentdb_gateway_.*\.deb" | grep -v "dbg" | head -n 1)
    if [[ -z "$gateway_package_name" ]]; then
        echo "Error: Gateway package not found in $abs_output_dir"
        exit 1
    fi
    gateway_package_rel_path="$OUTPUT_DIR/$gateway_package_name"

    echo "Testing with:"
    echo "  DocumentDB package: $DOCUMENTDB_PACKAGE"
    echo "  Gateway package: $gateway_package_rel_path"
    echo "  PostgreSQL version: $PG_VERSION"

    # Build test image using unified test Dockerfile
    docker build -t documentdb-test-gateway:latest \
        --target test-gateway \
        -f "${script_dir}/packaging/test_packages/deb/Dockerfile-deb-test" \
        --build-arg BASE_IMAGE="debian:bookworm-slim" \
        --build-arg POSTGRES_VERSION="$PG_VERSION" \
        --build-arg DEB_PACKAGE_REL_PATH="$DOCUMENTDB_PACKAGE" \
        --build-arg DEB_GATEWAY_PACKAGE_REL_PATH="$gateway_package_rel_path" "$script_dir"

    # Run the test
    docker run --rm documentdb-test-gateway:latest

    echo "Clean installation test successful!"
fi

echo "Gateway package available in $abs_output_dir"
