#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Env loading ──────────────────────────────────────────────

load_env() {
    if [ -n "${DOCKYARD_ENV:-}" ]; then
        if [ ! -f "$DOCKYARD_ENV" ]; then
            echo "Error: DOCKYARD_ENV file not found: ${DOCKYARD_ENV}" >&2
            exit 1
        fi
        echo "Loading ${DOCKYARD_ENV}..."
        set -a; source "$DOCKYARD_ENV"; set +a
    elif [ -f "${DOCKYARD_ROOT:-/dockyard}/env.dockyard" ]; then
        echo "Loading ${DOCKYARD_ROOT:-/dockyard}/env.dockyard..."
        set -a; source "${DOCKYARD_ROOT:-/dockyard}/env.dockyard"; set +a
    fi
}

derive_vars() {
    DOCKYARD_ROOT="${DOCKYARD_ROOT:-/dockyard}"
    DOCKYARD_DOCKER_PREFIX="${DOCKYARD_DOCKER_PREFIX:-dy_}"
    DOCKYARD_BRIDGE_CIDR="${DOCKYARD_BRIDGE_CIDR:-172.30.0.1/24}"
    DOCKYARD_FIXED_CIDR="${DOCKYARD_FIXED_CIDR:-172.30.0.0/24}"
    DOCKYARD_POOL_BASE="${DOCKYARD_POOL_BASE:-172.31.0.0/16}"
    DOCKYARD_POOL_SIZE="${DOCKYARD_POOL_SIZE:-24}"

    RUNTIME_DIR="${DOCKYARD_ROOT}/docker-runtime"
    BIN_DIR="${RUNTIME_DIR}/bin"
    ETC_DIR="${RUNTIME_DIR}/etc"
    LOG_DIR="${RUNTIME_DIR}/log"
    RUN_DIR="${RUNTIME_DIR}/run"
    BRIDGE="${DOCKYARD_DOCKER_PREFIX}docker0"
    EXEC_ROOT="/run/${DOCKYARD_DOCKER_PREFIX}docker"
    SERVICE_NAME="${DOCKYARD_DOCKER_PREFIX}docker"
    DOCKER_SOCKET="${DOCKYARD_ROOT}/docker.sock"
    CONTAINERD_SOCKET="${EXEC_ROOT}/containerd/containerd.sock"
    DOCKER_DATA="${DOCKYARD_ROOT}/docker"
}

# ── Helpers ──────────────────────────────────────────────────

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: must run as root (use sudo)" >&2
        exit 1
    fi
}

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
            return 1
        fi
    done
}

# ── Commands ─────────────────────────────────────────────────

cmd_install() {
    local INSTALL_SYSTEMD=true
    local START_DAEMON=true
    for arg in "$@"; do
        case "$arg" in
            --no-systemd) INSTALL_SYSTEMD=false ;;
            --no-start)   START_DAEMON=false ;;
            -h|--help)    install_usage ;;
            --*)          echo "Unknown option: $arg" >&2; install_usage ;;
        esac
    done

    require_root

    echo "Installing dockyard docker..."
    echo "  DOCKYARD_ROOT:          ${DOCKYARD_ROOT}"
    echo "  DOCKYARD_DOCKER_PREFIX: ${DOCKYARD_DOCKER_PREFIX}"
    echo "  DOCKYARD_BRIDGE_CIDR:   ${DOCKYARD_BRIDGE_CIDR}"
    echo "  DOCKYARD_FIXED_CIDR:    ${DOCKYARD_FIXED_CIDR}"
    echo "  DOCKYARD_POOL_BASE:     ${DOCKYARD_POOL_BASE}"
    echo "  DOCKYARD_POOL_SIZE:     ${DOCKYARD_POOL_SIZE}"
    echo ""
    echo "  bridge:      ${BRIDGE}"
    echo "  exec-root:   ${EXEC_ROOT}"
    echo "  service:     ${SERVICE_NAME}.service"
    echo "  runtime:     ${RUNTIME_DIR}"
    echo "  data:        ${DOCKER_DATA}"
    echo "  socket:      ${DOCKER_SOCKET}"
    echo ""

    # --- Check for existing installation ---
    if [ -d "${BIN_DIR}" ]; then
        echo "Error: ${BIN_DIR} already exists — docker is already installed in this DOCKYARD_ROOT" >&2
        exit 1
    fi

    if ip link show "$BRIDGE" &>/dev/null; then
        echo "Error: bridge ${BRIDGE} already exists — a docker with this DOCKYARD_DOCKER_PREFIX is running" >&2
        exit 1
    fi

    if [ -d "$EXEC_ROOT" ]; then
        echo "Error: ${EXEC_ROOT} already exists — a docker with this DOCKYARD_DOCKER_PREFIX is running" >&2
        exit 1
    fi

    # Check for subnet collisions
    local FIXED_NET="${DOCKYARD_FIXED_CIDR%/*}"
    if ip route | grep -qF "${FIXED_NET}/"; then
        echo "Error: DOCKYARD_FIXED_CIDR ${DOCKYARD_FIXED_CIDR} conflicts with an existing route:" >&2
        echo "  $(ip route | grep -F "${FIXED_NET}/")" >&2
        exit 1
    fi

    local POOL_NET="${DOCKYARD_POOL_BASE%/*}"
    local POOL_TWO_OCTETS="${POOL_NET%.*.*}"
    if ip route | grep -qE "^${POOL_TWO_OCTETS}\."; then
        echo "Error: DOCKYARD_POOL_BASE ${DOCKYARD_POOL_BASE} overlaps with existing routes:" >&2
        echo "  $(ip route | grep -E "^${POOL_TWO_OCTETS}\.")" >&2
        exit 1
    fi

    # --- 1. Download and extract binaries ---
    local CACHE_DIR="${SCRIPT_DIR}/.tmp"

    local DOCKER_VERSION="29.2.1"
    local DOCKER_ROOTLESS_VERSION="29.2.1"
    local SYSBOX_VERSION="0.6.7"
    local SYSBOX_DEB="sysbox-ce_${SYSBOX_VERSION}-0.linux_amd64.deb"

    local DOCKER_URL="https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz"
    local DOCKER_ROOTLESS_URL="https://download.docker.com/linux/static/stable/x86_64/docker-rootless-extras-${DOCKER_ROOTLESS_VERSION}.tgz"
    local SYSBOX_URL="https://downloads.nestybox.com/sysbox/releases/v${SYSBOX_VERSION}/${SYSBOX_DEB}"

    mkdir -p "$LOG_DIR" "$RUN_DIR" "$ETC_DIR" "$BIN_DIR"
    mkdir -p "$DOCKER_DATA"
    mkdir -p "$CACHE_DIR"
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
    tar -xzf "${CACHE_DIR}/docker-${DOCKER_VERSION}.tgz" -C "$CACHE_DIR"
    cp -f "${CACHE_DIR}/docker/"* "$BIN_DIR/"

    echo "Extracting Docker rootless extras..."
    tar -xzf "${CACHE_DIR}/docker-rootless-extras-${DOCKER_ROOTLESS_VERSION}.tgz" -C "$CACHE_DIR"
    cp -f "${CACHE_DIR}/docker-rootless-extras/"* "$BIN_DIR/"

    echo "Extracting sysbox from .deb..."
    local SYSBOX_EXTRACT="${CACHE_DIR}/sysbox-extract"
    mkdir -p "$SYSBOX_EXTRACT"
    cd "$SYSBOX_EXTRACT"
    ar x "${CACHE_DIR}/${SYSBOX_DEB}"
    tar -xzf data.tar.* 2>/dev/null || tar -xf data.tar.* 2>/dev/null
    cp -f usr/bin/sysbox-runc "$BIN_DIR/"
    cp -f usr/bin/sysbox-mgr "$BIN_DIR/"
    cp -f usr/bin/sysbox-fs "$BIN_DIR/"
    cd "$SCRIPT_DIR"

    chmod +x "$BIN_DIR"/*
    echo "Installed binaries to ${BIN_DIR}/"

    # Write daemon.json (embedded — no external file dependency)
    cat > "${ETC_DIR}/daemon.json" <<DAEMONJSONEOF
{
  "default-runtime": "sysbox-runc",
  "runtimes": {
    "sysbox-runc": {
      "path": "${BIN_DIR}/sysbox-runc"
    }
  },
  "storage-driver": "overlay2"
}
DAEMONJSONEOF
    echo "Installed config to ${ETC_DIR}/daemon.json"

    # Write env.dockyard (resolved values for post-install commands)
    cat > "${DOCKYARD_ROOT}/env.dockyard" <<ENVEOF
DOCKYARD_ROOT=${DOCKYARD_ROOT}
DOCKYARD_DOCKER_PREFIX=${DOCKYARD_DOCKER_PREFIX}
DOCKYARD_BRIDGE_CIDR=${DOCKYARD_BRIDGE_CIDR}
DOCKYARD_FIXED_CIDR=${DOCKYARD_FIXED_CIDR}
DOCKYARD_POOL_BASE=${DOCKYARD_POOL_BASE}
DOCKYARD_POOL_SIZE=${DOCKYARD_POOL_SIZE}
ENVEOF
    echo "Installed env to ${DOCKYARD_ROOT}/env.dockyard"

    # --- 2. Install systemd service ---
    if [ "$INSTALL_SYSTEMD" = true ]; then
        echo ""
        echo "Installing ${SERVICE_NAME}.service..."
        local SERVICE_DST="/etc/systemd/system/${SERVICE_NAME}.service"

        cat > "$SERVICE_DST" <<SERVICEEOF
[Unit]
Description=Dockyard Docker (${SERVICE_NAME})
After=network-online.target nss-lookup.target firewalld.service sysbox.service time-set.target
Before=docker.service
Wants=network-online.target
Requires=sysbox.service
StartLimitBurst=3
StartLimitIntervalSec=60

[Service]
Type=forking
PIDFile=${EXEC_ROOT}/dockerd.pid

# Create directories
ExecStartPre=/bin/mkdir -p ${LOG_DIR} ${RUN_DIR} ${EXEC_ROOT}/containerd ${DOCKER_DATA}/containerd

# Clean stale sockets
ExecStartPre=-/bin/rm -f ${CONTAINERD_SOCKET} ${DOCKER_SOCKET}

# Create bridge
ExecStartPre=/bin/bash -c 'if ! ip link show ${BRIDGE} &>/dev/null; then ip link add ${BRIDGE} type bridge && ip addr add ${DOCKYARD_BRIDGE_CIDR} dev ${BRIDGE} && ip link set ${BRIDGE} up; fi'

# Add iptables rules for container networking
ExecStartPre=/bin/bash -c 'iptables -I FORWARD -i ${BRIDGE} -o ${BRIDGE} -j ACCEPT && iptables -I FORWARD -i ${BRIDGE} ! -o ${BRIDGE} -j ACCEPT && iptables -I FORWARD -o ${BRIDGE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT && iptables -t nat -I POSTROUTING -s ${DOCKYARD_FIXED_CIDR} ! -o ${BRIDGE} -j MASQUERADE'

# Start containerd and wait for socket
ExecStartPre=/bin/bash -c '${BIN_DIR}/containerd --root ${DOCKER_DATA}/containerd --state ${EXEC_ROOT}/containerd --address ${CONTAINERD_SOCKET} &>${LOG_DIR}/containerd.log & echo \$! > ${RUN_DIR}/containerd.pid; i=0; while [ ! -e ${CONTAINERD_SOCKET} ]; do sleep 1; i=\$((i+1)); if [ \$i -ge 30 ]; then echo "containerd did not start within 30s" >&2; exit 1; fi; done'

# Start dockerd
ExecStart=/bin/bash -c '${BIN_DIR}/dockerd --config-file ${ETC_DIR}/daemon.json --containerd ${CONTAINERD_SOCKET} --data-root ${DOCKER_DATA} --exec-root ${EXEC_ROOT} --pidfile ${EXEC_ROOT}/dockerd.pid --bridge ${BRIDGE} --fixed-cidr ${DOCKYARD_FIXED_CIDR} --default-address-pool base=${DOCKYARD_POOL_BASE},size=${DOCKYARD_POOL_SIZE} --host unix://${DOCKER_SOCKET} --iptables=false &>${LOG_DIR}/dockerd.log & i=0; while [ ! -e ${DOCKER_SOCKET} ]; do sleep 1; i=\$((i+1)); if [ \$i -ge 30 ]; then echo "dockerd did not start within 30s" >&2; exit 1; fi; done'

# Stop containerd
ExecStopPost=-/bin/bash -c 'if [ -f ${RUN_DIR}/containerd.pid ]; then kill \$(cat ${RUN_DIR}/containerd.pid) 2>/dev/null; rm -f ${RUN_DIR}/containerd.pid; fi'

# Clean up sockets
ExecStopPost=-/bin/rm -f ${DOCKER_SOCKET} ${CONTAINERD_SOCKET}

# Remove iptables rules
ExecStopPost=-/bin/bash -c 'iptables -D FORWARD -i ${BRIDGE} -o ${BRIDGE} -j ACCEPT 2>/dev/null; iptables -D FORWARD -i ${BRIDGE} ! -o ${BRIDGE} -j ACCEPT 2>/dev/null; iptables -D FORWARD -o ${BRIDGE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; iptables -t nat -D POSTROUTING -s ${DOCKYARD_FIXED_CIDR} ! -o ${BRIDGE} -j MASQUERADE 2>/dev/null'

# Remove bridge
ExecStopPost=-/bin/bash -c 'if ip link show ${BRIDGE} &>/dev/null; then ip link set ${BRIDGE} down 2>/dev/null; ip link delete ${BRIDGE} 2>/dev/null; fi'

TimeoutStartSec=60
TimeoutStopSec=30
Restart=on-failure
RestartSec=5

LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
SERVICEEOF
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
            cmd_start
        fi
    fi

    echo ""
    echo "=== Installation complete ==="
    echo ""
    echo "To use:"
    echo "  DOCKER_HOST=\"unix://${DOCKER_SOCKET}\" docker run -ti alpine ash"
    if [ "$INSTALL_SYSTEMD" = true ]; then
        echo ""
        echo "  sudo systemctl status ${SERVICE_NAME}   # check status"
        echo "  sudo systemctl stop ${SERVICE_NAME}     # stop"
        echo "  sudo journalctl -u ${SERVICE_NAME} -f   # follow logs"
    fi
}

cmd_start() {
    require_root

    export PATH="${BIN_DIR}:${PATH}"

    mkdir -p "$LOG_DIR" "$RUN_DIR" "${EXEC_ROOT}/containerd" "$DOCKER_DATA/containerd"

    # Clean up stale sockets/pids from previous runs
    rm -f "$CONTAINERD_SOCKET" "$DOCKER_SOCKET"
    for pidfile in "${RUN_DIR}/containerd.pid" "${EXEC_ROOT}/dockerd.pid"; do
        if [ -f "$pidfile" ]; then
            local pid
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
        if ip link show "$BRIDGE" &>/dev/null; then
            ip link set "$BRIDGE" down 2>/dev/null || true
            ip link delete "$BRIDGE" 2>/dev/null || true
        fi
        exit 1
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
        ip addr add "$DOCKYARD_BRIDGE_CIDR" dev "$BRIDGE"
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

    wait_for_file "$CONTAINERD_SOCKET" "containerd" || cleanup
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
        --fixed-cidr "$DOCKYARD_FIXED_CIDR" \
        --default-address-pool "base=${DOCKYARD_POOL_BASE},size=${DOCKYARD_POOL_SIZE}" \
        --host "unix://${DOCKER_SOCKET}" \
        &>"${LOG_DIR}/dockerd.log" &
    DOCKERD_PID=$!
    STARTED_PIDS+=("$DOCKERD_PID")

    wait_for_file "$DOCKER_SOCKET" "dockerd" 30 || cleanup
    echo "  dockerd ready (pid ${DOCKERD_PID})"

    echo "=== All daemons started ==="
    echo "Run: DOCKER_HOST=unix://${DOCKER_SOCKET} docker ps"
}

cmd_stop() {
    require_root

    # Reverse startup order
    stop_daemon dockerd "${EXEC_ROOT}/dockerd.pid" 20
    stop_daemon containerd "${RUN_DIR}/containerd.pid" 10

    # Clean up sockets
    rm -f "$DOCKER_SOCKET" "$CONTAINERD_SOCKET"

    # Remove bridge
    if ip link show "$BRIDGE" &>/dev/null; then
        ip link set "$BRIDGE" down
        ip link delete "$BRIDGE"
        echo "Bridge ${BRIDGE} removed"
    fi

    echo "=== All daemons stopped ==="
}

cmd_status() {
    echo "=== Dockyard Docker Status ==="
    echo ""

    echo "Variables:"
    echo "  DOCKYARD_ROOT=${DOCKYARD_ROOT}"
    echo "  DOCKYARD_DOCKER_PREFIX=${DOCKYARD_DOCKER_PREFIX}"
    echo "  DOCKYARD_BRIDGE_CIDR=${DOCKYARD_BRIDGE_CIDR}"
    echo "  DOCKYARD_FIXED_CIDR=${DOCKYARD_FIXED_CIDR}"
    echo "  DOCKYARD_POOL_BASE=${DOCKYARD_POOL_BASE}"
    echo "  DOCKYARD_POOL_SIZE=${DOCKYARD_POOL_SIZE}"
    echo ""

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
    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    if [ -f "$SERVICE_FILE" ]; then
        echo "systemd:    $(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || echo "unknown") ($(systemctl is-enabled "${SERVICE_NAME}.service" 2>/dev/null || echo "unknown"))"
    else
        echo "systemd:    not installed"
    fi

    # --- pid checks ---
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
        local local_ip
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
    echo "  data:     ${DOCKER_DATA}"
    echo "  exec:     ${EXEC_ROOT}"
    echo "  logs:     ${LOG_DIR}"
}

cmd_uninstall() {
    require_root

    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

    echo "This will remove all installed dockyard docker files:"
    echo "  ${SERVICE_FILE}              (systemd service)"
    echo "  ${RUNTIME_DIR}/    (binaries, config, logs, pids)"
    echo "  ${DOCKER_DATA}/            (images, containers, volumes)"
    echo "  ${DOCKER_SOCKET}        (socket)"
    echo "  ${EXEC_ROOT}/                         (runtime state)"
    echo ""
    read -p "Continue? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi

    # --- 1. Stop and remove systemd service ---
    if [ -f "$SERVICE_FILE" ]; then
        echo "Removing ${SERVICE_NAME}.service..."
        if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
            echo "  stopping ${SERVICE_NAME}..."
            systemctl stop "${SERVICE_NAME}.service"
            echo "  stopped"
        fi
        if systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
            systemctl disable "${SERVICE_NAME}.service"
            echo "  disabled"
        fi
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        echo "  removed ${SERVICE_FILE}"
    else
        # No systemd service — stop daemons directly
        for pidfile in "${EXEC_ROOT}/dockerd.pid" "${RUN_DIR}/containerd.pid"; do
            if [ -f "$pidfile" ]; then
                local pid
                pid=$(cat "$pidfile")
                if kill -0 "$pid" 2>/dev/null; then
                    echo "Stopping pid ${pid}..."
                    kill "$pid" 2>/dev/null || true
                fi
                rm -f "$pidfile"
            fi
        done
        rm -f "$DOCKER_SOCKET" "$CONTAINERD_SOCKET"
        if ip link show "$BRIDGE" &>/dev/null; then
            ip link set "$BRIDGE" down 2>/dev/null || true
            ip link delete "$BRIDGE" 2>/dev/null || true
        fi
        sleep 2
    fi

    # --- 2. Remove runtime state ---
    if [ -d "$EXEC_ROOT" ]; then
        rm -rf "$EXEC_ROOT"
        echo "Removed ${EXEC_ROOT}/"
    fi

    # --- 3. Remove socket ---
    if [ -e "$DOCKER_SOCKET" ]; then
        rm -f "$DOCKER_SOCKET"
        echo "Removed ${DOCKER_SOCKET}"
    fi

    # --- 4. Remove runtime binaries, config, logs, pids ---
    if [ -d "$RUNTIME_DIR" ]; then
        rm -rf "$RUNTIME_DIR"
        echo "Removed ${RUNTIME_DIR}/"
    fi

    # --- 5. Remove docker data (images, containers, volumes) ---
    if [ -d "$DOCKER_DATA" ]; then
        rm -rf "$DOCKER_DATA"
        echo "Removed ${DOCKER_DATA}/"
    fi

    # --- 6. Remove env file ---
    rm -f "${DOCKYARD_ROOT}/env.dockyard"
    echo "Removed ${DOCKYARD_ROOT}/env.dockyard"

    echo ""
    echo "=== Uninstall complete ==="
}

# ── Usage ────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: ./dockyard.sh <command> [options]

Commands:
  install     Download binaries, install config, set up systemd, start daemon
  start       Start daemons manually (without systemd)
  stop        Stop manually started daemons
  status      Show instance status
  uninstall   Stop and remove everything

Environment:
  DOCKYARD_ENV    Path to env file (e.g. DOCKYARD_ENV=./env.thies)
  DOCKYARD_ROOT   Installation root (default: /dockyard)

Post-install commands auto-load $DOCKYARD_ROOT/env.dockyard.

Examples:
  sudo ./dockyard.sh install
  DOCKYARD_ENV=./env.thies sudo -E ./dockyard.sh install
  sudo ./dockyard.sh install --no-systemd --no-start
  sudo ./dockyard.sh start
  sudo ./dockyard.sh stop
  ./dockyard.sh status
  sudo ./dockyard.sh uninstall
EOF
    exit 0
}

install_usage() {
    cat <<'EOF'
Usage: sudo ./dockyard.sh install [OPTIONS]

Install dockyard docker: download binaries, install config,
set up systemd service, and start the daemon.

Options:
  --no-systemd    Skip systemd service installation
  --no-start      Don't start the daemon after install
  -h, --help      Show this help

Environment:
  DOCKYARD_ENV    Path to env file with custom settings

Examples:
  sudo ./dockyard.sh install
  DOCKYARD_ENV=./env.thies sudo -E ./dockyard.sh install
  sudo ./dockyard.sh install --no-systemd --no-start
EOF
    exit 0
}

# ── Dispatch ─────────────────────────────────────────────────

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    install)
        load_env
        derive_vars
        cmd_install "$@"
        ;;
    start)
        load_env
        derive_vars
        cmd_start
        ;;
    stop)
        load_env
        derive_vars
        cmd_stop
        ;;
    status)
        load_env
        derive_vars
        cmd_status
        ;;
    uninstall)
        load_env
        derive_vars
        cmd_uninstall
        ;;
    -h|--help|"")
        usage
        ;;
    *)
        echo "Unknown command: $COMMAND" >&2
        usage
        ;;
esac
