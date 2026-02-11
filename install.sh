#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: sudo -E ./install.sh [OPTIONS]

Install sandcastle docker: download binaries, install config,
set up systemd service, and start the daemon.

Options:
  --no-systemd    Skip systemd service installation
  --no-start      Don't start the daemon after install
  -h, --help      Show this help

Environment variables:
  SANDCASTLE_ROOT          Data and runtime root  (default: /sandcastle)
  SANDCASTLE_DOCKER_PREFIX Prefix for bridge/service names (default: sc_)
  SANDCASTLE_BRIDGE_CIDR   Bridge IP/mask         (default: 172.30.0.1/24)
  SANDCASTLE_FIXED_CIDR    Container CIDR range   (default: 172.30.0.0/24)
  SANDCASTLE_POOL_BASE     Address pool base      (default: 172.31.0.0/16)
  SANDCASTLE_POOL_SIZE     Address pool subnet    (default: 24)

Example — second instance with different prefix and network:
  export SANDCASTLE_ROOT=/docker2
  export SANDCASTLE_DOCKER_PREFIX=tc_
  export SANDCASTLE_BRIDGE_CIDR=172.32.0.1/24
  export SANDCASTLE_FIXED_CIDR=172.32.0.0/24
  export SANDCASTLE_POOL_BASE=172.33.0.0/16
  sudo -E ./install.sh
EOF
    exit 0
}

# --- Parse flags ---
INSTALL_SYSTEMD=true
START_DAEMON=true
for arg in "$@"; do
    case "$arg" in
        --no-systemd) INSTALL_SYSTEMD=false ;;
        --no-start)   START_DAEMON=false ;;
        -h|--help)    usage ;;
        *) echo "Unknown option: $arg" >&2; usage ;;
    esac
done

# Must run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root (use sudo -E)" >&2
    exit 1
fi

SANDCASTLE_ROOT="${SANDCASTLE_ROOT:-/sandcastle}"
SANDCASTLE_DOCKER_PREFIX="${SANDCASTLE_DOCKER_PREFIX:-sc_}"
SANDCASTLE_BRIDGE_CIDR="${SANDCASTLE_BRIDGE_CIDR:-172.30.0.1/24}"
SANDCASTLE_FIXED_CIDR="${SANDCASTLE_FIXED_CIDR:-172.30.0.0/24}"
SANDCASTLE_POOL_BASE="${SANDCASTLE_POOL_BASE:-172.31.0.0/16}"
SANDCASTLE_POOL_SIZE="${SANDCASTLE_POOL_SIZE:-24}"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"

RUNTIME_DIR="${SANDCASTLE_ROOT}/docker-runtime"
BRIDGE="${SANDCASTLE_DOCKER_PREFIX}docker0"
EXEC_ROOT="/run/${SANDCASTLE_DOCKER_PREFIX}docker"
SERVICE_NAME="${SANDCASTLE_DOCKER_PREFIX}docker"

echo "Installing sandcastle docker..."
echo "  SANDCASTLE_ROOT:          ${SANDCASTLE_ROOT}"
echo "  SANDCASTLE_DOCKER_PREFIX: ${SANDCASTLE_DOCKER_PREFIX}"
echo "  SANDCASTLE_BRIDGE_CIDR:   ${SANDCASTLE_BRIDGE_CIDR}"
echo "  SANDCASTLE_FIXED_CIDR:    ${SANDCASTLE_FIXED_CIDR}"
echo "  SANDCASTLE_POOL_BASE:     ${SANDCASTLE_POOL_BASE}"
echo "  SANDCASTLE_POOL_SIZE:     ${SANDCASTLE_POOL_SIZE}"
echo ""
echo "  bridge:      ${BRIDGE}"
echo "  exec-root:   ${EXEC_ROOT}"
echo "  service:     ${SERVICE_NAME}.service"
echo "  runtime:     ${RUNTIME_DIR}"
echo "  data:        ${SANDCASTLE_ROOT}/docker"
echo "  socket:      ${SANDCASTLE_ROOT}/docker.sock"
echo ""

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

# Check for subnet collisions in the routing table
FIXED_NET="${SANDCASTLE_FIXED_CIDR%/*}"
if ip route | grep -qF "${FIXED_NET}/"; then
    echo "Error: SANDCASTLE_FIXED_CIDR ${SANDCASTLE_FIXED_CIDR} conflicts with an existing route:" >&2
    echo "  $(ip route | grep -F "${FIXED_NET}/")" >&2
    exit 1
fi

# For pool base (/16), check if any subnets within the first two octets exist
POOL_NET="${SANDCASTLE_POOL_BASE%/*}"
POOL_TWO_OCTETS="${POOL_NET%.*.*}"
if ip route | grep -qE "^${POOL_TWO_OCTETS}\."; then
    echo "Error: SANDCASTLE_POOL_BASE ${SANDCASTLE_POOL_BASE} overlaps with existing routes:" >&2
    echo "  $(ip route | grep -E "^${POOL_TWO_OCTETS}\.")" >&2
    exit 1
fi

# --- 1. Download and extract binaries ---
BIN_DIR="${RUNTIME_DIR}/bin"
CACHE_DIR="${BUILD_DIR}/.tmp"

DOCKER_VERSION="29.2.1"
DOCKER_ROOTLESS_VERSION="29.2.1"
SYSBOX_VERSION="0.6.7"
SYSBOX_DEB="sysbox-ce_${SYSBOX_VERSION}-0.linux_amd64.deb"

DOCKER_URL="https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz"
DOCKER_ROOTLESS_URL="https://download.docker.com/linux/static/stable/x86_64/docker-rootless-extras-${DOCKER_ROOTLESS_VERSION}.tgz"
SYSBOX_URL="https://downloads.nestybox.com/sysbox/releases/v${SYSBOX_VERSION}/${SYSBOX_DEB}"

mkdir -p "${RUNTIME_DIR}/log" "${RUNTIME_DIR}/run" "${RUNTIME_DIR}/etc" "${BIN_DIR}"
mkdir -p "${SANDCASTLE_ROOT}/docker"
mkdir -p "${CACHE_DIR}"
mkdir -p /run/sysbox

download() {
    local url="$1"
    local dest="${CACHE_DIR}/$(basename "$url")"
    if [ -f "$dest" ]; then
        echo "  cached: $(basename "$dest")"
    else
        echo "  downloading: $(basename "$url")"
        curl -fsSL -o "$dest" "$url"
    fi
}

echo "Downloading artifacts..."
download "$DOCKER_URL"
download "$DOCKER_ROOTLESS_URL"
download "$SYSBOX_URL"

echo "Extracting Docker binaries..."
tar -xzf "${CACHE_DIR}/docker-${DOCKER_VERSION}.tgz" -C "${CACHE_DIR}"
cp -f "${CACHE_DIR}/docker/"* "${BIN_DIR}/"

echo "Extracting Docker rootless extras..."
tar -xzf "${CACHE_DIR}/docker-rootless-extras-${DOCKER_ROOTLESS_VERSION}.tgz" -C "${CACHE_DIR}"
cp -f "${CACHE_DIR}/docker-rootless-extras/"* "${BIN_DIR}/"

echo "Extracting sysbox from .deb..."
SYSBOX_EXTRACT="${CACHE_DIR}/sysbox-extract"
mkdir -p "$SYSBOX_EXTRACT"
cd "$SYSBOX_EXTRACT"
ar x "${CACHE_DIR}/${SYSBOX_DEB}"
tar -xzf data.tar.* 2>/dev/null || tar -xf data.tar.* 2>/dev/null
cp -f usr/bin/sysbox-runc "${BIN_DIR}/"
cp -f usr/bin/sysbox-mgr "${BIN_DIR}/"
cp -f usr/bin/sysbox-fs "${BIN_DIR}/"
cd "$BUILD_DIR"

chmod +x "${BIN_DIR}"/*
echo "Installed binaries to ${BIN_DIR}/"

cp -f "${BUILD_DIR}/etc/daemon.json" "${RUNTIME_DIR}/etc/daemon.json"
echo "Installed config to ${RUNTIME_DIR}/etc/daemon.json"

# --- 2. Install systemd service ---
if [ "$INSTALL_SYSTEMD" = true ]; then
    echo ""
    echo "Installing ${SERVICE_NAME}.service..."
    SERVICE_SRC="${BUILD_DIR}/etc/sc_docker.service"
    SERVICE_DST="/etc/systemd/system/${SERVICE_NAME}.service"

    sed -e "s|__BUILD_DIR__|${BUILD_DIR}|g" \
        -e "s|__SANDCASTLE_ROOT__|${SANDCASTLE_ROOT}|g" \
        -e "s|__SANDCASTLE_DOCKER_PREFIX__|${SANDCASTLE_DOCKER_PREFIX}|g" \
        -e "s|__SANDCASTLE_BRIDGE_CIDR__|${SANDCASTLE_BRIDGE_CIDR}|g" \
        -e "s|__SANDCASTLE_FIXED_CIDR__|${SANDCASTLE_FIXED_CIDR}|g" \
        -e "s|__SANDCASTLE_POOL_BASE__|${SANDCASTLE_POOL_BASE}|g" \
        "$SERVICE_SRC" > "$SERVICE_DST"
    chmod 644 "$SERVICE_DST"
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service"
    echo "  enabled ${SERVICE_NAME}.service (will start on boot)"
fi

# --- 3. Start daemon ---
if [ "$START_DAEMON" = true ]; then
    echo ""
    if [ "$INSTALL_SYSTEMD" = true ]; then
        echo "Starting via systemd..."
        systemctl start "${SERVICE_NAME}.service"
        echo "  ${SERVICE_NAME}.service started"
    else
        echo "Starting directly..."
        "${BUILD_DIR}/start.sh"
    fi
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "To use:"
echo "  DOCKER_HOST=\"unix://${SANDCASTLE_ROOT}/docker.sock\" docker run -ti alpine ash"
if [ "$INSTALL_SYSTEMD" = true ]; then
    echo ""
    echo "  sudo systemctl status ${SERVICE_NAME}   # check status"
    echo "  sudo systemctl stop ${SERVICE_NAME}     # stop"
    echo "  sudo journalctl -u ${SERVICE_NAME} -f   # follow logs"
fi
