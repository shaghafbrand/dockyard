cmd_destroy() {
    local YES=false
    for arg in "$@"; do
        case "$arg" in
            --yes|-y) YES=true ;;
            -h|--help) usage ;;
        esac
    done

    require_root

    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    local SYSBOX_SERVICE_FILE="/etc/systemd/system/${SYSBOX_SERVICE_NAME}.service"

    echo "This will remove all installed dockyard docker files:"
    echo "  ${SERVICE_FILE}              (docker systemd service)"
    echo "  ${RUNTIME_DIR}/    (binaries, config, logs, pids)"
    echo "  ${DOCKER_DATA}/            (images, containers, volumes)"
    echo "  ${DOCKER_SOCKET}        (socket)"
    echo "  ${EXEC_ROOT}/                         (runtime state)"
    echo "  (shared sysbox resources removed only if this is the last instance)"
    echo ""
    if [[ "$YES" != true ]]; then
        read -p "Continue? [y/N] " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
        fi
    fi

    # --- 1. Stop and remove systemd services (or stop daemons directly) ---
    if [ -f "$SERVICE_FILE" ] || [ -f "$SYSBOX_SERVICE_FILE" ]; then
        cmd_disable
    else
        # No systemd services — stop daemons directly
        # Kill DinD watcher
        if [ -f "${RUN_DIR}/dind-watcher.pid" ]; then
            kill "$(cat "${RUN_DIR}/dind-watcher.pid")" 2>/dev/null || true
            rm -f "${RUN_DIR}/dind-watcher.pid"
        fi
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
        # Release shared sysbox ref-count; stop if last
        local sysbox_count
        sysbox_count=$(sysbox_release)
        if [ "$sysbox_count" -eq 0 ]; then
            stop_daemon sysbox-fs "/run/sysbox/sysbox-fs.pid" 10
            stop_daemon sysbox-mgr "/run/sysbox/sysbox-mgr.pid" 10
            rm -f "$SYSBOX_REFCOUNT"
        fi
        rm -f "$DOCKER_SOCKET" "$CONTAINERD_SOCKET"
        if ip link show "$BRIDGE" &>/dev/null; then
            ip link set "$BRIDGE" down 2>/dev/null || true
            ip link delete "$BRIDGE" 2>/dev/null || true
        fi
        sleep 2
    fi

    # --- 1.5. Remove leftover user-defined network bridges from the pool ---
    cleanup_pool_bridges

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

    # --- 6. Remove shared sysbox resources if this was the last instance ---
    # In systemd mode: cmd_disable removed the shared service file if last instance.
    # In non-systemd mode: refcount file is gone (sysbox_release set it to 0).
    local shared_sysbox_last=false
    if [ ! -f "/etc/systemd/system/${SYSBOX_SERVICE_NAME}.service" ]; then
        local refcount_val
        refcount_val=$(cat "$SYSBOX_REFCOUNT" 2>/dev/null || echo "0")
        if [ "$refcount_val" -le 0 ]; then
            shared_sysbox_last=true
        fi
    fi
    if [ "$shared_sysbox_last" = true ]; then
        if [ -d "$SYSBOX_SHARED_DATA" ]; then
            rm -rf "$SYSBOX_SHARED_DATA"
            echo "Removed ${SYSBOX_SHARED_DATA}/ (shared sysbox data)"
        fi
        if [ -d "$SYSBOX_SHARED_BIN" ]; then
            rm -rf "$SYSBOX_SHARED_BIN"
            echo "Removed ${SYSBOX_SHARED_BIN}/ (shared sysbox binaries)"
        fi
        if [ -d "$SYSBOX_SHARED_LOG" ]; then
            rm -rf "$SYSBOX_SHARED_LOG"
            echo "Removed ${SYSBOX_SHARED_LOG}/ (shared sysbox logs)"
        fi
    fi

    # --- 7. Remove env file ---
    rm -f "${ETC_DIR}/dockyard.env"
    echo "Removed ${ETC_DIR}/dockyard.env"

    # --- 8. Remove DOCKYARD_ROOT if empty ---
    if [ -d "$DOCKYARD_ROOT" ]; then
        if rmdir "$DOCKYARD_ROOT" 2>/dev/null; then
            echo "Removed ${DOCKYARD_ROOT}/ (was empty)"
        else
            echo "Note: ${DOCKYARD_ROOT}/ not empty, left in place"
        fi
    fi

    echo ""
    echo "=== Uninstall complete ==="
}
