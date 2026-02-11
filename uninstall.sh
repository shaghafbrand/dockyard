#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root (use sudo)" >&2
    exit 1
fi

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load env file
ENV_NAME="${1:-default}"
ENV_FILE="${BUILD_DIR}/env.${ENV_NAME}"
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: env file not found: ${ENV_FILE}" >&2
    exit 1
fi
echo "Loading ${ENV_FILE}..."
source "$ENV_FILE"

DOCKYARD_ROOT="${DOCKYARD_ROOT:-/dockyard}"
DOCKYARD_DOCKER_PREFIX="${DOCKYARD_DOCKER_PREFIX:-dy_}"
SERVICE_NAME="${DOCKYARD_DOCKER_PREFIX}docker"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
EXEC_ROOT="/run/${DOCKYARD_DOCKER_PREFIX}docker"

echo "This will remove all installed dockyard docker files:"
echo "  ${SERVICE_FILE}              (systemd service)"
echo "  ${DOCKYARD_ROOT}/docker-runtime/    (binaries, config, logs, pids)"
echo "  ${DOCKYARD_ROOT}/docker/            (images, containers, volumes)"
echo "  ${DOCKYARD_ROOT}/docker.sock        (socket)"
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
if [ -e "${DOCKYARD_ROOT}/docker.sock" ]; then
    rm -f "${DOCKYARD_ROOT}/docker.sock"
    echo "Removed ${DOCKYARD_ROOT}/docker.sock"
fi

# --- 4. Remove runtime binaries, config, logs, pids ---
if [ -d "${DOCKYARD_ROOT}/docker-runtime" ]; then
    rm -rf "${DOCKYARD_ROOT}/docker-runtime"
    echo "Removed ${DOCKYARD_ROOT}/docker-runtime/"
fi

# --- 5. Remove docker data (images, containers, volumes) ---
if [ -d "${DOCKYARD_ROOT}/docker" ]; then
    rm -rf "${DOCKYARD_ROOT}/docker"
    echo "Removed ${DOCKYARD_ROOT}/docker/"
fi

echo ""
echo "=== Uninstall complete ==="
