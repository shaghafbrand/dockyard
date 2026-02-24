cmd_stop() {
    require_root

    # Kill DinD ownership watcher
    if [ -f "${RUN_DIR}/dind-watcher.pid" ]; then
        kill "$(cat "${RUN_DIR}/dind-watcher.pid")" 2>/dev/null || true
        rm -f "${RUN_DIR}/dind-watcher.pid"
    fi

    # Reverse startup order: dockerd -> containerd -> sysbox
    stop_daemon dockerd "${EXEC_ROOT}/dockerd.pid" 20
    stop_daemon containerd "${RUN_DIR}/containerd.pid" 10
    stop_daemon sysbox-fs "${SYSBOX_RUN_DIR}/sysbox-fs.pid" 10
    stop_daemon sysbox-mgr "${SYSBOX_RUN_DIR}/sysbox-mgr.pid" 10
    rm -rf "$SYSBOX_RUN_DIR"

    # Clean up sockets
    rm -f "$DOCKER_SOCKET" "$CONTAINERD_SOCKET"

    # Remove iptables rules (bridge)
    iptables -D FORWARD -i "$BRIDGE" -o "$BRIDGE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$BRIDGE" ! -o "$BRIDGE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o "$BRIDGE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "$DOCKYARD_FIXED_CIDR" ! -o "$BRIDGE" -j MASQUERADE 2>/dev/null || true
    # Remove iptables rules (pool)
    iptables -D FORWARD -s "$DOCKYARD_POOL_BASE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d "$DOCKYARD_POOL_BASE" -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "$DOCKYARD_POOL_BASE" -j MASQUERADE 2>/dev/null || true

    # Remove bridge
    if ip link show "$BRIDGE" &>/dev/null; then
        ip link set "$BRIDGE" down
        ip link delete "$BRIDGE"
        echo "Bridge ${BRIDGE} removed"
    fi

    # Remove leftover user-defined network bridges from the pool range
    cleanup_pool_bridges

    echo "=== All daemons stopped ==="
}
