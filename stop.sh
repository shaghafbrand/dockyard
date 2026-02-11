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
RUN_DIR="${DOCKYARD_ROOT}/docker-runtime/run"
BRIDGE="${DOCKYARD_DOCKER_PREFIX}docker0"
EXEC_ROOT="/run/${DOCKYARD_DOCKER_PREFIX}docker"

stop_daemon() {
    local name="$1"
    local pidfile="$2"
    local timeout="${3:-10}"

    if [ ! -f "$pidfile" ]; then
        echo "${name}: no pid file"
        return 0
    fi

    local pid
    pid=$(cat "$pidfile")

    if ! kill -0 "$pid" 2>/dev/null; then
        echo "${name}: not running (stale pid ${pid})"
        rm -f "$pidfile"
        return 0
    fi

    echo "Stopping ${name} (pid ${pid})..."
    kill "$pid"

    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        i=$((i + 1))
        if [ "$i" -ge "$timeout" ]; then
            echo "  ${name} did not stop in ${timeout}s — sending SIGKILL"
            kill -9 "$pid" 2>/dev/null || true
            sleep 1
            break
        fi
    done

    rm -f "$pidfile"
    echo "  ${name} stopped"
}

# Reverse startup order
stop_daemon dockerd "${EXEC_ROOT}/dockerd.pid" 20
stop_daemon containerd "${RUN_DIR}/containerd.pid" 10

# Clean up socket
rm -f "${DOCKYARD_ROOT}/docker.sock"
rm -f "${EXEC_ROOT}/containerd/containerd.sock"

# Remove bridge
if ip link show "$BRIDGE" &>/dev/null; then
    ip link set "$BRIDGE" down
    ip link delete "$BRIDGE"
    echo "Bridge ${BRIDGE} removed"
fi

echo "=== All daemons stopped ==="
