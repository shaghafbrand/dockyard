#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root (use sudo)" >&2
    exit 1
fi

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_SRC="${BUILD_DIR}/etc/sc-docker.service"
SERVICE_DST="/etc/systemd/system/sc-docker.service"

echo "Installing sc-docker.service..."
echo "  source: ${SERVICE_SRC}"
echo "  destination: ${SERVICE_DST}"
echo "  BUILD_DIR: ${BUILD_DIR}"

# Copy service file, replacing __BUILD_DIR__ placeholder with actual path
sed "s|__BUILD_DIR__|${BUILD_DIR}|g" "$SERVICE_SRC" > "$SERVICE_DST"
echo "  installed service file (BUILD_DIR=${BUILD_DIR})"

# Set permissions
chmod 644 "$SERVICE_DST"
echo "  set permissions to 644"

# Reload systemd to pick up the new unit
systemctl daemon-reload
echo "  reloaded systemd daemon"

# Enable the service to start on boot
systemctl enable sc-docker.service
echo "  enabled sc-docker.service (will start on boot)"

echo ""
echo "=== Installation complete ==="
echo ""
echo "Commands:"
echo "  sudo systemctl start sc-docker    # start now"
echo "  sudo systemctl stop sc-docker     # stop"
echo "  sudo systemctl status sc-docker   # check status"
echo "  sudo journalctl -u sc-docker -f   # follow logs"
echo ""
echo "To override SANDCASTLE_ROOT, edit:"
echo "  sudo systemctl edit sc-docker"
echo "  and add: [Service]"
echo "           Environment=SANDCASTLE_ROOT=/your/path"
