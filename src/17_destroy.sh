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

    echo "This will remove all installed dockyard docker files:"
    echo "  ${SERVICE_FILE}    (docker systemd service)"
    echo "  ${DOCKYARD_ROOT}/  (all instance data: binaries, config, data, logs, sockets)"
    echo ""
    if [[ "$YES" != true ]]; then
        read -p "Continue? [y/N] " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
        fi
    fi

    # --- 1. Stop and remove systemd service (or stop daemons directly) ---
    if [ -f "$SERVICE_FILE" ]; then
        cmd_disable
    else
        # No systemd service — stop daemons directly
        for pidfile in "${RUN_DIR}/dockerd.pid" "${RUN_DIR}/containerd.pid"; do
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
        stop_daemon sysbox-fs "${SYSBOX_RUN_DIR}/sysbox-fs.pid" 10
        stop_daemon sysbox-mgr "${SYSBOX_RUN_DIR}/sysbox-mgr.pid" 10
        rm -rf "$SYSBOX_RUN_DIR"
        rm -f "$DOCKER_SOCKET" "$CONTAINERD_SOCKET"
        if ip link show "$BRIDGE" &>/dev/null; then
            ip link set "$BRIDGE" down 2>/dev/null || true
            ip link delete "$BRIDGE" 2>/dev/null || true
        fi
        sleep 2
    fi

    # --- 1.5. Remove leftover user-defined network bridges from the pool ---
    cleanup_pool_bridges

    # --- 2. Remove AppArmor fusermount3 entry for this instance ---
    local apparmor_file="/etc/apparmor.d/local/fusermount3"
    local apparmor_begin="# dockyard:${DOCKYARD_DOCKER_PREFIX}:begin"
    if grep -qF "$apparmor_begin" "$apparmor_file" 2>/dev/null; then
        awk -v start="$apparmor_begin" \
            -v stop="# dockyard:${DOCKYARD_DOCKER_PREFIX}:end" \
            '$0 == start { skip=1 } skip { if ($0 == stop) { skip=0 }; next } { print }' \
            "$apparmor_file" > "${apparmor_file}.tmp" \
            && mv "${apparmor_file}.tmp" "$apparmor_file"
        if [ -f /etc/apparmor.d/fusermount3 ]; then
            apparmor_parser -r /etc/apparmor.d/fusermount3 2>/dev/null || true
        fi
        echo "Removed AppArmor fusermount3 entry for ${DOCKYARD_DOCKER_PREFIX}"
    fi

    # --- 3. Remove instance root (all state: binaries, config, data, logs, sockets) ---
    if [ -d "$DOCKYARD_ROOT" ]; then
        rm -rf "$DOCKYARD_ROOT"
        echo "Removed ${DOCKYARD_ROOT}/"
    fi

    # --- 4. Remove instance user and group ---
    if getent passwd "${INSTANCE_USER}" &>/dev/null; then
        userdel "${INSTANCE_USER}" 2>/dev/null || true
        echo "Removed user ${INSTANCE_USER}"
    fi
    if getent group "${INSTANCE_GROUP}" &>/dev/null; then
        groupdel "${INSTANCE_GROUP}" 2>/dev/null || true
        echo "Removed group ${INSTANCE_GROUP}"
    fi

    echo ""
    echo "=== Uninstall complete ==="
}
