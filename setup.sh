#!/bin/bash
set -euo pipefail

# Must run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root (use sudo)" >&2
    exit 1
fi

SANDCASTLE_ROOT="${SANDCASTLE_ROOT:-/sandcastle}"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"

RUNTIME_DIR="${SANDCASTLE_ROOT}/docker-runtime"

mkdir -p "${BUILD_DIR}/log" "${BUILD_DIR}/run"
mkdir -p "${SANDCASTLE_ROOT}/docker"
mkdir -p "${RUNTIME_DIR}/etc"
mkdir -p /run/sysbox

# Download and extract binaries
"${BUILD_DIR}/download_and_extract.sh"

# Copy config to runtime etc
cp -f "${BUILD_DIR}/etc/daemon.json" "${RUNTIME_DIR}/etc/daemon.json"
echo "Installed config to ${RUNTIME_DIR}/etc/daemon.json"

echo "=== Setup complete ==="
