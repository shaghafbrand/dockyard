#!/bin/bash
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load env file
ENV_NAME="${1:-default}"
ENV_FILE="${BUILD_DIR}/env.${ENV_NAME}"
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: env file not found: ${ENV_FILE}" >&2
    exit 1
fi
source "$ENV_FILE"

SANDCASTLE_ROOT="${SANDCASTLE_ROOT:-/sandcastle}"
SANDCASTLE_DOCKER_PREFIX="${SANDCASTLE_DOCKER_PREFIX:-sc_}"
RUNTIME_DIR="${SANDCASTLE_ROOT}/docker-runtime"
RUN_DIR="${RUNTIME_DIR}/run"
BRIDGE="${SANDCASTLE_DOCKER_PREFIX}docker0"
EXEC_ROOT="/run/${SANDCASTLE_DOCKER_PREFIX}docker"
SERVICE_NAME="${SANDCASTLE_DOCKER_PREFIX}docker"
DOCKER_SOCKET="${SANDCASTLE_ROOT}/docker.sock"
CONTAINERD_SOCKET="${EXEC_ROOT}/containerd/containerd.sock"

echo "=== Sandcastle Docker Status (env: ${ENV_NAME}) ==="
echo ""

# --- env vars ---
echo "Variables:"
echo "  SANDCASTLE_ROOT=${SANDCASTLE_ROOT}"
echo "  SANDCASTLE_DOCKER_PREFIX=${SANDCASTLE_DOCKER_PREFIX}"
echo "  SANDCASTLE_BRIDGE_CIDR=${SANDCASTLE_BRIDGE_CIDR:-}"
echo "  SANDCASTLE_FIXED_CIDR=${SANDCASTLE_FIXED_CIDR:-}"
echo "  SANDCASTLE_POOL_BASE=${SANDCASTLE_POOL_BASE:-}"
echo "  SANDCASTLE_POOL_SIZE=${SANDCASTLE_POOL_SIZE:-}"
echo ""

# --- derived vars ---
echo "Derived:"
echo "  RUNTIME_DIR=${RUNTIME_DIR}"
echo "  RUN_DIR=${RUN_DIR}"
echo "  EXEC_ROOT=${EXEC_ROOT}"
echo "  BRIDGE=${BRIDGE}"
echo "  SERVICE_NAME=${SERVICE_NAME}"
echo "  DOCKER_SOCKET=${DOCKER_SOCKET}"
echo "  CONTAINERD_SOCKET=${CONTAINERD_SOCKET}"
echo ""

# --- systemd service ---
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
if [ -f "$SERVICE_FILE" ]; then
    echo "systemd:    $(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || echo "unknown") ($(systemctl is-enabled "${SERVICE_NAME}.service" 2>/dev/null || echo "unknown"))"
else
    echo "systemd:    not installed"
fi

# --- containerd ---
check_pid() {
    local name="$1"
    local pidfile="$2"
    if [ -f "$pidfile" ]; then
        local pid
        pid=$(cat "$pidfile")
        if [ -d "/proc/${pid}" ]; then
            echo "${name}: running (pid ${pid})"
        else
            echo "${name}: dead (stale pid ${pid})"
        fi
    else
        echo "${name}: not running"
    fi
}

check_pid "containerd" "${RUN_DIR}/containerd.pid"
check_pid "dockerd   " "${EXEC_ROOT}/dockerd.pid"

# --- bridge ---
if ip link show "$BRIDGE" &>/dev/null; then
    local_ip=$(ip -4 addr show "$BRIDGE" 2>/dev/null | grep -oP 'inet \K[^ ]+' || echo "no ip")
    echo "bridge:     ${BRIDGE} (${local_ip})"
else
    echo "bridge:     ${BRIDGE} not found"
fi

# --- sockets ---
if [ -e "$DOCKER_SOCKET" ]; then
    echo "socket:     ${DOCKER_SOCKET}"
else
    echo "socket:     ${DOCKER_SOCKET} not found"
fi

if [ -e "$CONTAINERD_SOCKET" ]; then
    echo "containerd: ${CONTAINERD_SOCKET}"
else
    echo "containerd: ${CONTAINERD_SOCKET} not found"
fi

# --- connectivity test ---
echo ""
echo "Connectivity:"
if [ -e "$DOCKER_SOCKET" ]; then
    echo "  DOCKER_HOST=unix://${DOCKER_SOCKET} docker run --rm alpine /bin/ash -c 'ping -c 3 heise.de'"
    DOCKER_HOST="unix://${DOCKER_SOCKET}" docker run --rm alpine /bin/ash -c 'ping -c 3 heise.de' 2>&1 | sed 's/^/  /'
else
    echo "  skipped (docker socket not found)"
fi

# --- paths ---
echo ""
echo "Paths:"
echo "  runtime:  ${RUNTIME_DIR}"
echo "  data:     ${SANDCASTLE_ROOT}/docker"
echo "  exec:     ${EXEC_ROOT}"
echo "  logs:     ${RUNTIME_DIR}/log"
