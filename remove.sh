#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root (use sudo)" >&2
    exit 1
fi

SANDCASTLE_ROOT="${SANDCASTLE_ROOT:-/sandcastle}"
SANDCASTLE_DOCKER_PREFIX="${SANDCASTLE_DOCKER_PREFIX:-sc_}"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
EXEC_ROOT="/run/${SANDCASTLE_DOCKER_PREFIX}docker"

echo "This will remove all installed sandcastle docker files:"
echo "  ${SANDCASTLE_ROOT}/docker-runtime/    (binaries + config)"
echo "  ${SANDCASTLE_ROOT}/docker/            (images, containers, volumes)"
echo "  ${SANDCASTLE_ROOT}/docker.sock        (socket)"
echo "  ${EXEC_ROOT}/                         (runtime state)"
echo ""
read -p "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# --- 1. Uninstall systemd service if installed ---
if [ -x "${BUILD_DIR}/uninstall-systemd.sh" ]; then
    "${BUILD_DIR}/uninstall-systemd.sh"
fi

# --- 2. Stop daemons if running ---
if [ -x "${BUILD_DIR}/stop.sh" ]; then
    "${BUILD_DIR}/stop.sh" || true
fi

# --- 3. Remove runtime state ---
if [ -d "$EXEC_ROOT" ]; then
    rm -rf "$EXEC_ROOT"
    echo "Removed ${EXEC_ROOT}/"
fi

# --- 4. Remove socket ---
if [ -e "${SANDCASTLE_ROOT}/docker.sock" ]; then
    rm -f "${SANDCASTLE_ROOT}/docker.sock"
    echo "Removed ${SANDCASTLE_ROOT}/docker.sock"
fi

# --- 5. Remove runtime binaries and config ---
if [ -d "${SANDCASTLE_ROOT}/docker-runtime" ]; then
    rm -rf "${SANDCASTLE_ROOT}/docker-runtime"
    echo "Removed ${SANDCASTLE_ROOT}/docker-runtime/"
fi

# --- 6. Remove docker data (images, containers, volumes) ---
if [ -d "${SANDCASTLE_ROOT}/docker" ]; then
    rm -rf "${SANDCASTLE_ROOT}/docker"
    echo "Removed ${SANDCASTLE_ROOT}/docker/"
fi

echo ""
echo "=== Removal complete ==="
