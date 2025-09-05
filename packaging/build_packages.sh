#!/bin/bash

set -euo pipefail

# Function to display help message
function show_help {
    echo "Usage: $0 --os <OS> --pg <PG_VERSION> [--test-clean-install] [--output-dir <DIR>] [-h|--help]"
    echo ""
    echo "Description:"
    echo "  This script builds extension packages (DEB/RPM) using Docker."
    echo ""
    echo "Mandatory Arguments:"
    echo "  --os                 OS to build packages for. Possible values: [deb11, deb12, ubuntu22.04, ubuntu24.04, rhel8, rhel9]"
    echo "  --pg                 PG version to build packages for. Possible values: [15, 16, 17]"
    echo ""
    echo "Optional Arguments:"
    echo "  --version            The version of documentdb to build. Examples: [0.100.0, 0.101.0]"
    echo "  --test-clean-install Test installing the packages in a clean Docker container."
    echo "  --output-dir         Relative path from the repo root of the directory where to drop the packages. The directory will be created if it doesn't exist. Default: packaging"
    echo "  -h, --help           Display this help message."
    exit 0
}

# Initialize variables
OS=""
PG=""
DOCUMENTDB_VERSION=""
TEST_CLEAN_INSTALL=false
OUTPUT_DIR="packaging"  # Default value for output directory
PACKAGE_TYPE=""  # Will be set to "deb" or "rpm"

# Process arguments to convert long options to short ones
while [[ $# -gt 0 ]]; do
    case "$1" in
        --os)
            shift
            case $1 in
                deb11|deb12|deb13|ubuntu22.04|ubuntu24.04)
                    OS=$1
                    PACKAGE_TYPE="deb"
                    ;;
                rhel8|rhel9)
                    OS=$1
                    PACKAGE_TYPE="rpm"
                    ;;
                *)
                    echo "Invalid --os value. Allowed values are [deb11, deb12, ubuntu22.04, ubuntu24.04, rhel8, rhel9]"
                    exit 1
                    ;;
            esac
            ;;
        --pg)
            shift
            case $1 in
                15|16|17)
                    PG=$1
                    ;;
                *)
                    echo "Invalid --pg value. Allowed values are [15, 16, 17]"
                    exit 1
                    ;;
            esac
            ;;
        --version)
            shift
            DOCUMENTDB_VERSION=$1
            ;;
        --test-clean-install)
            TEST_CLEAN_INSTALL=true
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

# Check mandatory arguments
if [[ -z "$OS" ]]; then
    echo "Error: --os is required."
    show_help
    exit 1
fi

if [[ -z "$PG" ]]; then
    echo "Error: --pg is required."
    show_help
    exit 1
fi

# get the version from control file
if [[ -z "$DOCUMENTDB_VERSION" ]]; then
    DOCUMENTDB_VERSION=$(grep -E "^default_version" pg_documentdb_core/documentdb_core.control | sed -E "s/.*'([0-9]+\.[0-9]+-[0-9]+)'.*/\1/")
    DOCUMENTDB_VERSION=$(echo $DOCUMENTDB_VERSION | sed "s/-/./g")
    echo "DOCUMENTDB_VERSION extracted from control file: $DOCUMENTDB_VERSION"
    if [[ -z "$DOCUMENTDB_VERSION" ]]; then
        echo "Error: --version is required and could not be found in the control file."
        show_help
        exit 1
    fi
fi

# Set the appropriate Docker image and configuration based on the OS
DOCKERFILE=""
OS_VERSION_NUMBER=""

if [[ "$PACKAGE_TYPE" == "deb" ]]; then
    DOCKERFILE="packaging/Dockerfile_build_deb_packages"
    case $OS in
        deb11)
            DOCKER_IMAGE="debian:bullseye"
            ;;
        deb12)
            DOCKER_IMAGE="debian:bookworm"
            ;;
        deb13)
            DOCKER_IMAGE="debian:trixie"
            ;;
        ubuntu22.04)
            DOCKER_IMAGE="ubuntu:22.04"
            ;;
        ubuntu24.04)
            DOCKER_IMAGE="ubuntu:24.04"
            ;;
    esac
elif [[ "$PACKAGE_TYPE" == "rpm" ]]; then
    DOCKERFILE="packaging/Dockerfile_build_rpm_packages"
    case $OS in
        rhel8)
            DOCKER_IMAGE="rockylinux:8"
            OS_VERSION_NUMBER="8"
            ;;
        rhel9)
            DOCKER_IMAGE="rockylinux:9"
            OS_VERSION_NUMBER="9"
            ;;
        *)
            echo "Error: Invalid OS specified for RPM build: $OS"
            exit 1
            ;;
    esac
fi

TAG=documentdb-build-packages-$OS-pg$PG:latest

repo_root=$(git rev-parse --show-toplevel)
abs_output_dir="$repo_root/$OUTPUT_DIR"
cd "$repo_root"

echo "Building $PACKAGE_TYPE packages for OS: $OS, PostgreSQL version: $PG, DOCUMENTDB version: $DOCUMENTDB_VERSION"
echo "Output directory: $abs_output_dir"

# Create the output directory if it doesn't exist
mkdir -p "$abs_output_dir"

# Build the Docker image while showing the output to the console
if [[ "$PACKAGE_TYPE" == "deb" ]]; then
    docker build -t "$TAG" -f "$DOCKERFILE" \
        --build-arg BASE_IMAGE="$DOCKER_IMAGE" \
        --build-arg POSTGRES_VERSION="$PG" \
        --build-arg DOCUMENTDB_VERSION="$DOCUMENTDB_VERSION" .
    # Run the Docker container to build the packages
    docker run --rm --env OS="$OS" -v "$abs_output_dir:/output" "$TAG"
elif [[ "$PACKAGE_TYPE" == "rpm" ]]; then
    docker build -t "$TAG" -f "$DOCKERFILE" \
        --build-arg BASE_IMAGE="$DOCKER_IMAGE" \
        --build-arg POSTGRES_VERSION="$PG" \
        --build-arg DOCUMENTDB_VERSION="$DOCUMENTDB_VERSION" \
        --build-arg OS_VERSION_ARG="$OS_VERSION_NUMBER" .
    # Run the Docker container to build the packages
    docker run --rm --env OS="$OS" --env POSTGRES_VERSION="$PG" -v "$abs_output_dir:/output" "$TAG"
fi

echo "Packages built successfully!!"

if [[ $TEST_CLEAN_INSTALL == true ]]; then
    echo "Testing clean installation in a Docker container..."

    if [[ "$PACKAGE_TYPE" == "deb" ]]; then
        deb_package_name=$(ls "$abs_output_dir" | grep -E "${OS}-postgresql-$PG-documentdb_${DOCUMENTDB_VERSION}.*\.deb" | grep -v "dbg" | head -n 1)
        deb_package_rel_path="$OUTPUT_DIR/$deb_package_name"

        echo "Debian package path: $deb_package_rel_path"

        # Build the Docker image while showing the output to the console
        docker build -t documentdb-test-packages:latest -f packaging/test_packages/Dockerfile_test_install_deb_packages \
            --build-arg BASE_IMAGE="$DOCKER_IMAGE" \
            --build-arg POSTGRES_VERSION="$PG" \
            --build-arg DEB_PACKAGE_REL_PATH="$deb_package_rel_path" .

        # Run the Docker container to test the packages
        docker run --rm documentdb-test-packages:latest

    elif [[ "$PACKAGE_TYPE" == "rpm" ]]; then
        rpm_package_name=$(ls "$abs_output_dir" | grep -E "${OS}-postgresql${PG}-documentdb-${DOCUMENTDB_VERSION}.*\.x86_64\.rpm" | head -n 1)
        if [[ -z "$rpm_package_name" ]]; then
            echo "Error: Could not find the built RPM package in $abs_output_dir for testing."
            exit 1
        fi
        package_rel_path="$OUTPUT_DIR/$rpm_package_name"
        
        echo "RPM package path for testing: $package_rel_path"
        
        # Build the Docker image while showing the output to the console
        docker build -t documentdb-test-rpm-packages:latest -f packaging/test_packages/Dockerfile_test_install_rpm_packages \
            --build-arg BASE_IMAGE="$DOCKER_IMAGE" \
            --build-arg POSTGRES_VERSION="$PG" \
            --build-arg RPM_PACKAGE_REL_PATH="$package_rel_path" \
            --build-arg OS_VERSION_ARG="$OS_VERSION_NUMBER" .
            
        # Run the Docker container to test the packages
        docker run --rm --env POSTGRES_VERSION="$PG" documentdb-test-rpm-packages:latest
    fi

    echo "Clean installation test successful!!"
fi

echo "Packages are available in $abs_output_dir"