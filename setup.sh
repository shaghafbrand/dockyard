#!/bin/bash
set -euo pipefail

# Must run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root (use sudo)" >&2
    exit 1
fi

SANDCASTLE_ROOT="${SANDCASTLE_ROOT:-/sandcastle}"
SANDCASTLE_DOCKER_PREFIX="${SANDCASTLE_DOCKER_PREFIX:-sc_}"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"

RUNTIME_DIR="${SANDCASTLE_ROOT}/docker-runtime"
BRIDGE="${SANDCASTLE_DOCKER_PREFIX}docker0"
EXEC_ROOT="/run/${SANDCASTLE_DOCKER_PREFIX}docker"

# --- Check for existing installation ---
if [ -d "${RUNTIME_DIR}/bin" ]; then
    echo "Error: ${RUNTIME_DIR}/bin already exists — docker is already installed in this SANDCASTLE_ROOT" >&2
    exit 1
fi

if ip link show "$BRIDGE" &>/dev/null; then
    echo "Error: bridge ${BRIDGE} already exists — a docker with this SANDCASTLE_DOCKER_PREFIX is running" >&2
    exit 1
fi

if [ -d "$EXEC_ROOT" ]; then
    echo "Error: ${EXEC_ROOT} already exists — a docker with this SANDCASTLE_DOCKER_PREFIX is running" >&2
    exit 1
fi

mkdir -p "${RUNTIME_DIR}/log" "${RUNTIME_DIR}/run"
mkdir -p "${SANDCASTLE_ROOT}/docker"
mkdir -p "${RUNTIME_DIR}/etc"
mkdir -p /run/sysbox

# Download and extract binaries
"${BUILD_DIR}/download_and_extract.sh"

# Copy config to runtime etc
cp -f "${BUILD_DIR}/etc/daemon.json" "${RUNTIME_DIR}/etc/daemon.json"
echo "Installed config to ${RUNTIME_DIR}/etc/daemon.json"

echo "=== Setup complete ==="
