#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root (use sudo)" >&2
    exit 1
fi

SANDCASTLE_DOCKER_PREFIX="${SANDCASTLE_DOCKER_PREFIX:-sc_}"
SERVICE_NAME="${SANDCASTLE_DOCKER_PREFIX}docker"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

if [ ! -f "$SERVICE_FILE" ]; then
    echo "Service ${SERVICE_NAME}.service is not installed"
    exit 0
fi

echo "Uninstalling ${SERVICE_NAME}.service..."

# Stop if running
if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    echo "  stopping ${SERVICE_NAME}..."
    systemctl stop "${SERVICE_NAME}.service"
    echo "  stopped"
fi

# Disable from boot
if systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    echo "  disabling ${SERVICE_NAME}..."
    systemctl disable "${SERVICE_NAME}.service"
    echo "  disabled"
fi

# Remove service file
rm -f "$SERVICE_FILE"
echo "  removed ${SERVICE_FILE}"

# Reload systemd
systemctl daemon-reload
echo "  reloaded systemd daemon"

echo ""
echo "=== Uninstall complete ==="
