#! /bin/bash

# Determine the directory of the currently executing script
SCRIPT_DIR=$(unset CDPATH; cd "$(dirname "$0")" > /dev/null; pwd -P)

# Source the configure script using its absolute path
source "$SCRIPT_DIR/configure.sh" && gcloud builds submit --timeout=90m --config=cloudbuild.yaml .