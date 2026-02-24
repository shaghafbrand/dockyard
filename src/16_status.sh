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

    # --- systemd services ---
    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

    if [ -f "$SERVICE_FILE" ]; then
        echo "systemd (docker): $(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || echo "unknown") ($(systemctl is-enabled "${SERVICE_NAME}.service" 2>/dev/null || echo "unknown"))"
    else
        echo "systemd (docker): not installed"
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

    check_pid "sysbox-mgr" "${SYSBOX_RUN_DIR}/sysbox-mgr.pid"
    check_pid "sysbox-fs " "${SYSBOX_RUN_DIR}/sysbox-fs.pid"
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
