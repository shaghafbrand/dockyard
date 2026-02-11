#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root (use sudo)" >&2
    exit 1
fi

SANDCASTLE_ROOT="${SANDCASTLE_ROOT:-/sandcastle}"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_DIR="${BUILD_DIR}/run"

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
stop_daemon dockerd /run/sc_docker/dockerd.pid 20
stop_daemon containerd "${RUN_DIR}/containerd.pid" 10

# Clean up socket
rm -f "${SANDCASTLE_ROOT}/docker.sock"
rm -f /run/sc_docker/containerd/containerd.sock

# Remove bridge
if ip link show sc_docker0 &>/dev/null; then
    ip link set sc_docker0 down
    ip link delete sc_docker0
    echo "Bridge sc_docker0 removed"
fi

echo "=== All daemons stopped ==="
