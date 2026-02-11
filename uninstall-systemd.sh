#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root (use sudo)" >&2
    exit 1
fi

SERVICE="sc_docker.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE}"

if [ ! -f "$SERVICE_FILE" ]; then
    echo "Service ${SERVICE} is not installed"
    exit 0
fi

echo "Uninstalling ${SERVICE}..."

# Stop if running
if systemctl is-active --quiet "$SERVICE"; then
    echo "  stopping ${SERVICE}..."
    systemctl stop "$SERVICE"
    echo "  stopped"
fi

# Disable from boot
if systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
    echo "  disabling ${SERVICE}..."
    systemctl disable "$SERVICE"
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
