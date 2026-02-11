#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root (use sudo -E)" >&2
    exit 1
fi

SANDCASTLE_ROOT="${SANDCASTLE_ROOT:-/sandcastle}"
SANDCASTLE_DOCKER_PREFIX="${SANDCASTLE_DOCKER_PREFIX:-sc_}"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="${SANDCASTLE_DOCKER_PREFIX}docker"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
EXEC_ROOT="/run/${SANDCASTLE_DOCKER_PREFIX}docker"

echo "This will remove all installed sandcastle docker files:"
echo "  ${SERVICE_FILE}              (systemd service)"
echo "  ${SANDCASTLE_ROOT}/docker-runtime/    (binaries, config, logs, pids)"
echo "  ${SANDCASTLE_ROOT}/docker/            (images, containers, volumes)"
echo "  ${SANDCASTLE_ROOT}/docker.sock        (socket)"
echo "  ${EXEC_ROOT}/                         (runtime state)"
echo ""
read -p "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# --- 1. Stop and remove systemd service ---
if [ -f "$SERVICE_FILE" ]; then
    echo "Removing ${SERVICE_NAME}.service..."
    if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        echo "  stopping ${SERVICE_NAME}..."
        systemctl stop "${SERVICE_NAME}.service"
        echo "  stopped"
    fi
    if systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
        systemctl disable "${SERVICE_NAME}.service"
        echo "  disabled"
    fi
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    echo "  removed ${SERVICE_FILE}"
else
    # No systemd service — stop daemons directly
    if [ -x "${BUILD_DIR}/stop.sh" ]; then
        "${BUILD_DIR}/stop.sh" || true
    fi
fi

# --- 2. Remove runtime state ---
if [ -d "$EXEC_ROOT" ]; then
    rm -rf "$EXEC_ROOT"
    echo "Removed ${EXEC_ROOT}/"
fi

# --- 3. Remove socket ---
if [ -e "${SANDCASTLE_ROOT}/docker.sock" ]; then
    rm -f "${SANDCASTLE_ROOT}/docker.sock"
    echo "Removed ${SANDCASTLE_ROOT}/docker.sock"
fi

# --- 4. Remove runtime binaries, config, logs, pids ---
if [ -d "${SANDCASTLE_ROOT}/docker-runtime" ]; then
    rm -rf "${SANDCASTLE_ROOT}/docker-runtime"
    echo "Removed ${SANDCASTLE_ROOT}/docker-runtime/"
fi

# --- 5. Remove docker data (images, containers, volumes) ---
if [ -d "${SANDCASTLE_ROOT}/docker" ]; then
    rm -rf "${SANDCASTLE_ROOT}/docker"
    echo "Removed ${SANDCASTLE_ROOT}/docker/"
fi

echo ""
echo "=== Uninstall complete ==="
