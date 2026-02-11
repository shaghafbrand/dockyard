#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root (use sudo)" >&2
    exit 1
fi

SANDCASTLE_ROOT="${SANDCASTLE_ROOT:-/sandcastle}"
SANDCASTLE_DOCKER_PREFIX="${SANDCASTLE_DOCKER_PREFIX:-sc_}"
SANDCASTLE_BRIDGE_CIDR="${SANDCASTLE_BRIDGE_CIDR:-172.30.0.1/24}"
SANDCASTLE_FIXED_CIDR="${SANDCASTLE_FIXED_CIDR:-172.30.0.0/24}"
SANDCASTLE_POOL_BASE="${SANDCASTLE_POOL_BASE:-172.31.0.0/16}"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="${SANDCASTLE_DOCKER_PREFIX}docker"
SERVICE_SRC="${BUILD_DIR}/etc/sc_docker.service"
SERVICE_DST="/etc/systemd/system/${SERVICE_NAME}.service"

echo "Installing ${SERVICE_NAME}.service..."
echo "  source: ${SERVICE_SRC}"
echo "  destination: ${SERVICE_DST}"
echo "  BUILD_DIR: ${BUILD_DIR}"
echo "  SANDCASTLE_ROOT: ${SANDCASTLE_ROOT}"
echo "  PREFIX: ${SANDCASTLE_DOCKER_PREFIX}"
echo "  BRIDGE_CIDR: ${SANDCASTLE_BRIDGE_CIDR}"
echo "  FIXED_CIDR: ${SANDCASTLE_FIXED_CIDR}"
echo "  POOL_BASE: ${SANDCASTLE_POOL_BASE}"

# Copy service file, replacing placeholders with actual values
sed -e "s|__BUILD_DIR__|${BUILD_DIR}|g" \
    -e "s|__SANDCASTLE_ROOT__|${SANDCASTLE_ROOT}|g" \
    -e "s|__SANDCASTLE_DOCKER_PREFIX__|${SANDCASTLE_DOCKER_PREFIX}|g" \
    -e "s|__SANDCASTLE_BRIDGE_CIDR__|${SANDCASTLE_BRIDGE_CIDR}|g" \
    -e "s|__SANDCASTLE_FIXED_CIDR__|${SANDCASTLE_FIXED_CIDR}|g" \
    -e "s|__SANDCASTLE_POOL_BASE__|${SANDCASTLE_POOL_BASE}|g" \
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
