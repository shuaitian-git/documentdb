#!/bin/bash

# fail if trying to reference a variable that is not set.
set -u

# exit immediately if a command exits with a non-zero status
set -e

PGVERSION=""
SOURCEDIR=""
INSTALL="False"

while getopts "d:v:i" opt; do
  case $opt in
    d) SOURCEDIR="$OPTARG"
    ;;
    v) PGVERSION="$OPTARG"
    ;;
    i) INSTALL="True"
    ;;
  esac

  # Assume empty string if it's unset since we cannot reference to
  # an unset variabled due to "set -u".
  case ${OPTARG:-""} in
    -*) echo "Option $opt needs a valid argument. use -h to get help."
    exit 1
    ;;
  esac
done

if [ "$SOURCEDIR" == "" ]; then
    echo "Source directory not provided. Use -d to provide source directory."
    exit 1
fi

if [ "$PGVERSION" == "" ]; then
    echo "Postgres version not provided. Use -v to provide Postgres version."
    exit 1
fi

source="${BASH_SOURCE[0]}"
while [[ -h $source ]]; do
   scriptroot="$( cd -P "$( dirname "$source" )" && pwd )"
   source="$(readlink "$source")"

   # if $source was a relative symlink, we need to resolve it relative to the path where the
   # symlink file was located
   [[ $source != /* ]] && source="$scriptroot/$source"
done

scriptDir="$( cd -P "$( dirname "$source" )" && pwd )"

. $scriptDir/utils.sh

pgBinDir=$(GetPostgresPath $PGVERSION)
PATH=$pgBinDir:$PATH;
pg_config_path=$pgBinDir/pg_config

# Install cargo-pgrx
if command -v cargo-pgrx > /dev/null; then
    echo "cargo-pgrx is already installed."
else
    echo "Installing cargo-pgrx..."
    cargo install --locked cargo-pgrx@$(grep -o 'pgrx = "[^"]*"' $SOURCEDIR/Cargo.toml | cut -d '"' -f 2 | sed 's/=//')
fi

cargo pgrx init --pg$PGVERSION $pg_config_path

if [ "$INSTALL" == "True" ]; then
    pushd $SOURCEDIR
    cargo pgrx install --release --sudo --pg-config $pg_config_path
    popd
fi