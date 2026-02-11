#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root (use sudo)" >&2
    exit 1
fi

SANDCASTLE_ROOT="${SANDCASTLE_ROOT:-/sandcastle}"
SANDCASTLE_DOCKER_PREFIX="${SANDCASTLE_DOCKER_PREFIX:-sc_}"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_DIR="${SANDCASTLE_ROOT}/docker-runtime"
BIN_DIR="${RUNTIME_DIR}/bin"
ETC_DIR="${RUNTIME_DIR}/etc"
LOG_DIR="${BUILD_DIR}/log"
RUN_DIR="${BUILD_DIR}/run"
BRIDGE="${SANDCASTLE_DOCKER_PREFIX}docker0"
EXEC_ROOT="/run/${SANDCASTLE_DOCKER_PREFIX}docker"
CONTAINERD_SOCKET="${EXEC_ROOT}/containerd/containerd.sock"
DOCKER_SOCKET="${SANDCASTLE_ROOT}/docker.sock"
DOCKER_DATA="${SANDCASTLE_ROOT}/docker"

export PATH="${BIN_DIR}:${PATH}"

mkdir -p "$LOG_DIR" "$RUN_DIR" "${EXEC_ROOT}/containerd" "$DOCKER_DATA/containerd"

# Clean up stale sockets/pids from previous runs
rm -f "$CONTAINERD_SOCKET" "$DOCKER_SOCKET"
for pidfile in "${RUN_DIR}/containerd.pid" "${EXEC_ROOT}/dockerd.pid"; do
    if [ -f "$pidfile" ]; then
        pid=$(cat "$pidfile")
        kill "$pid" 2>/dev/null && sleep 1 || true
        rm -f "$pidfile"
    fi
done

# Cleanup helper: kill previously started daemons on failure
STARTED_PIDS=()
cleanup() {
    echo "Startup failed — cleaning up..."
    for pid in "${STARTED_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    # Remove bridge if we created it
    if ip link show "$BRIDGE" &>/dev/null; then
        ip link set "$BRIDGE" down 2>/dev/null || true
        ip link delete "$BRIDGE" 2>/dev/null || true
    fi
    exit 1
}

wait_for_file() {
    local file="$1"
    local label="$2"
    local timeout="${3:-30}"
    local i=0
    while [ ! -e "$file" ]; do
        sleep 1
        i=$((i + 1))
        if [ "$i" -ge "$timeout" ]; then
            echo "Error: $label did not become ready within ${timeout}s" >&2
            cleanup
        fi
    done
}

# --- 1. Verify sysbox is running (managed by systemd) ---
if ! pgrep -x sysbox-mgr >/dev/null || ! pgrep -x sysbox-fs >/dev/null; then
    echo "Error: sysbox is not running. Start it with: sudo systemctl start sysbox-fs sysbox-mgr" >&2
    exit 1
fi
echo "sysbox: running (systemd)"

# --- 2. Create bridge ---
if ! ip link show "$BRIDGE" &>/dev/null; then
    echo "Creating bridge ${BRIDGE}..."
    ip link add "$BRIDGE" type bridge
    ip addr add 172.30.0.1/24 dev "$BRIDGE"
    ip link set "$BRIDGE" up
else
    echo "Bridge ${BRIDGE} already exists"
fi

# --- 3. Start containerd ---
echo "Starting containerd..."
"${BIN_DIR}/containerd" \
    --root "$DOCKER_DATA/containerd" \
    --state "${EXEC_ROOT}/containerd" \
    --address "$CONTAINERD_SOCKET" \
    &>"${LOG_DIR}/containerd.log" &
CONTAINERD_PID=$!
echo "$CONTAINERD_PID" > "${RUN_DIR}/containerd.pid"
STARTED_PIDS+=("$CONTAINERD_PID")

wait_for_file "$CONTAINERD_SOCKET" "containerd"
echo "  containerd ready (pid ${CONTAINERD_PID})"

# --- 4. Start dockerd ---
echo "Starting dockerd..."
"${BIN_DIR}/dockerd" \
    --config-file "${ETC_DIR}/daemon.json" \
    --containerd "$CONTAINERD_SOCKET" \
    --data-root "$DOCKER_DATA" \
    --exec-root "$EXEC_ROOT" \
    --pidfile "${EXEC_ROOT}/dockerd.pid" \
    --bridge "$BRIDGE" \
    --host "unix://${DOCKER_SOCKET}" \
    &>"${LOG_DIR}/dockerd.log" &
DOCKERD_PID=$!
STARTED_PIDS+=("$DOCKERD_PID")

wait_for_file "$DOCKER_SOCKET" "dockerd" 30
echo "  dockerd ready (pid ${DOCKERD_PID})"

echo "=== All daemons started ==="
echo "Run: source ${BUILD_DIR}/env.sh"
