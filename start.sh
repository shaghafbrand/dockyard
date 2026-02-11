#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root (use sudo)" >&2
    exit 1
fi

BASE_DIR="/home/thies/docker"
BIN_DIR="${BASE_DIR}/bin"
LOG_DIR="${BASE_DIR}/log"
RUN_DIR="${BASE_DIR}/run"
CONTAINERD_SOCKET="/run/docker-alt/containerd/containerd.sock"

export PATH="${BIN_DIR}:${PATH}"

mkdir -p "$LOG_DIR" "$RUN_DIR" /run/docker-alt/containerd /docker/containerd

# Clean up stale sockets/pids from previous runs
rm -f "$CONTAINERD_SOCKET" /docker.sock
for pidfile in "${RUN_DIR}/containerd.pid" "/run/docker-alt/dockerd.pid"; do
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
    if ip link show sc_docker0 &>/dev/null; then
        ip link set sc_docker0 down 2>/dev/null || true
        ip link delete sc_docker0 2>/dev/null || true
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
if ! ip link show sc_docker0 &>/dev/null; then
    echo "Creating bridge sc_docker0..."
    ip link add sc_docker0 type bridge
    ip addr add 172.30.0.1/24 dev sc_docker0
    ip link set sc_docker0 up
else
    echo "Bridge sc_docker0 already exists"
fi

# --- 3. Start containerd ---
echo "Starting containerd..."
"${BIN_DIR}/containerd" \
    --root /docker/containerd \
    --state /run/docker-alt/containerd \
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
    --config-file "${BASE_DIR}/etc/daemon.json" \
    --containerd "$CONTAINERD_SOCKET" \
    &>"${LOG_DIR}/dockerd.log" &
DOCKERD_PID=$!
STARTED_PIDS+=("$DOCKERD_PID")

wait_for_file /docker.sock "dockerd" 30
echo "  dockerd ready (pid ${DOCKERD_PID})"

echo "=== All daemons started ==="
echo "Run: source ${BASE_DIR}/env.sh"
