#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root (use sudo)" >&2
    exit 1
fi

SANDCASTLE_DOCKER_PREFIX="${SANDCASTLE_DOCKER_PREFIX:-sc_}"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="${SANDCASTLE_DOCKER_PREFIX}docker"
SERVICE_SRC="${BUILD_DIR}/etc/sc_docker.service"
SERVICE_DST="/etc/systemd/system/${SERVICE_NAME}.service"

echo "Installing ${SERVICE_NAME}.service..."
echo "  source: ${SERVICE_SRC}"
echo "  destination: ${SERVICE_DST}"
echo "  BUILD_DIR: ${BUILD_DIR}"
echo "  PREFIX: ${SANDCASTLE_DOCKER_PREFIX}"

# Copy service file, replacing placeholders with actual values
sed -e "s|__BUILD_DIR__|${BUILD_DIR}|g" \
    -e "s|__SANDCASTLE_DOCKER_PREFIX__|${SANDCASTLE_DOCKER_PREFIX}|g" \
    "$SERVICE_SRC" > "$SERVICE_DST"
echo "  installed service file"

# Set permissions
chmod 644 "$SERVICE_DST"
echo "  set permissions to 644"

# Reload systemd to pick up the new unit
systemctl daemon-reload
echo "  reloaded systemd daemon"

# Enable the service to start on boot
systemctl enable "${SERVICE_NAME}.service"
echo "  enabled ${SERVICE_NAME}.service (will start on boot)"

echo ""
echo "=== Installation complete ==="
echo ""
echo "Commands:"
echo "  sudo systemctl start ${SERVICE_NAME}    # start now"
echo "  sudo systemctl stop ${SERVICE_NAME}     # stop"
echo "  sudo systemctl status ${SERVICE_NAME}   # check status"
echo "  sudo journalctl -u ${SERVICE_NAME} -f   # follow logs"
echo ""
echo "To override SANDCASTLE_ROOT, edit:"
echo "  sudo systemctl edit ${SERVICE_NAME}"
echo "  and add: [Service]"
echo "           Environment=SANDCASTLE_ROOT=/your/path"
