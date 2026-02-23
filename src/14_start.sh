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

    # --- 1. Start shared sysbox daemons (ref-counted, one instance per host) ---
    mkdir -p /run/sysbox

    local SYSBOX_COUNT
    SYSBOX_COUNT=$(sysbox_acquire)
    echo "Sysbox refcount after acquire: ${SYSBOX_COUNT}"

    if [ "$SYSBOX_COUNT" -eq 1 ]; then
        echo "Starting shared sysbox daemons (first dockyard instance on this host)..."
        mkdir -p "$SYSBOX_SHARED_DATA" "$SYSBOX_SHARED_LOG"

        echo "  Starting sysbox-mgr..."
        "${SYSBOX_SHARED_BIN}/sysbox-mgr" --data-root "${SYSBOX_SHARED_DATA}" \
            &>"${SYSBOX_SHARED_LOG}/sysbox-mgr.log" &
        SYSBOX_MGR_PID=$!
        echo "$SYSBOX_MGR_PID" > "/run/sysbox/sysbox-mgr.pid"
        STARTED_PIDS+=("$SYSBOX_MGR_PID")
        sleep 2
        if ! kill -0 "$SYSBOX_MGR_PID" 2>/dev/null; then
            sysbox_release >/dev/null
            echo "Error: sysbox-mgr failed to start" >&2
            cleanup
        fi
        echo "  sysbox-mgr ready (pid ${SYSBOX_MGR_PID})"

        echo "  Starting sysbox-fs..."
        "${SYSBOX_SHARED_BIN}/sysbox-fs" --mountpoint "${SYSBOX_SHARED_DATA}" \
            &>"${SYSBOX_SHARED_LOG}/sysbox-fs.log" &
        SYSBOX_FS_PID=$!
        echo "$SYSBOX_FS_PID" > "/run/sysbox/sysbox-fs.pid"
        STARTED_PIDS+=("$SYSBOX_FS_PID")
        sleep 2
        if ! kill -0 "$SYSBOX_FS_PID" 2>/dev/null; then
            sysbox_release >/dev/null
            echo "Error: sysbox-fs failed to start" >&2
            cleanup
        fi
        echo "  sysbox-fs ready (pid ${SYSBOX_FS_PID})"
    else
        echo "  Shared sysbox already running (refcount=${SYSBOX_COUNT})"
    fi

    # --- 1b. DinD ownership watcher ---
    # Sysbox creates each container's /var/lib/docker backing dir at
    # ${DOCKYARD_ROOT}/sysbox/docker/<id> owned by root:root.
    # The container's uid namespace maps uid 0 → SYSBOX_UID_OFFSET, so container
    # root can't access a root-owned directory.  Docker 29+ makes chmod on the
    # data-root fatal, so DinD breaks on every new container.
    # Fix: read the actual sysbox uid offset and chown each backing dir to it.
    SYSBOX_UID_OFFSET=$(awk -F: '$1=="sysbox" {print $2; exit}' /etc/subuid 2>/dev/null || echo 231072)
    SYSBOX_DOCKER_DIR="${SYSBOX_SHARED_DATA}/docker"

    # Fix any dirs left over from before this watcher existed (e.g. after reinstall).
    find "$SYSBOX_DOCKER_DIR" -maxdepth 1 -mindepth 1 -uid 0 \
        -exec chown "${SYSBOX_UID_OFFSET}:${SYSBOX_UID_OFFSET}" {} \; 2>/dev/null || true

    # Background watcher: fix new dirs within ~1 s of container creation.
    (
        while true; do
            for d in "${SYSBOX_DOCKER_DIR}"/*/; do
                [ -d "$d" ] || continue
                uid=$(stat -c '%u' "$d" 2>/dev/null) || continue
                [ "$uid" = "0" ] && \
                    chown "${SYSBOX_UID_OFFSET}:${SYSBOX_UID_OFFSET}" "$d" 2>/dev/null
            done
            sleep 1
        done
    ) &
    DIND_WATCHER_PID=$!
    echo "$DIND_WATCHER_PID" > "${RUN_DIR}/dind-watcher.pid"
    STARTED_PIDS+=("$DIND_WATCHER_PID")
    echo "  DinD ownership watcher started (uid offset ${SYSBOX_UID_OFFSET}, pid ${DIND_WATCHER_PID})"

    # --- 2. Create bridge ---
    if ! ip link show "$BRIDGE" &>/dev/null; then
        echo "Creating bridge ${BRIDGE}..."
        ip link add "$BRIDGE" type bridge
        ip addr add "$DOCKYARD_BRIDGE_CIDR" dev "$BRIDGE"
        ip link set "$BRIDGE" up
    else
        echo "Bridge ${BRIDGE} already exists"
    fi

    # Enable IP forwarding
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    # Bridge rules (idempotent)
    iptables -C FORWARD -i "$BRIDGE" -o "$BRIDGE" -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD -i "$BRIDGE" -o "$BRIDGE" -j ACCEPT
    iptables -C FORWARD -i "$BRIDGE" ! -o "$BRIDGE" -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD -i "$BRIDGE" ! -o "$BRIDGE" -j ACCEPT
    iptables -C FORWARD -o "$BRIDGE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD -o "$BRIDGE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -t nat -C POSTROUTING -s "$DOCKYARD_FIXED_CIDR" ! -o "$BRIDGE" -j MASQUERADE 2>/dev/null ||
        iptables -t nat -I POSTROUTING -s "$DOCKYARD_FIXED_CIDR" ! -o "$BRIDGE" -j MASQUERADE

    # Pool rules
    iptables -C FORWARD -s "$DOCKYARD_POOL_BASE" -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD -s "$DOCKYARD_POOL_BASE" -j ACCEPT
    iptables -C FORWARD -d "$DOCKYARD_POOL_BASE" -j ACCEPT 2>/dev/null ||
        iptables -I FORWARD -d "$DOCKYARD_POOL_BASE" -j ACCEPT
    iptables -t nat -C POSTROUTING -s "$DOCKYARD_POOL_BASE" -j MASQUERADE 2>/dev/null ||
        iptables -t nat -I POSTROUTING -s "$DOCKYARD_POOL_BASE" -j MASQUERADE

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
        --iptables=false \
        &>"${LOG_DIR}/dockerd.log" &
    DOCKERD_PID=$!
    STARTED_PIDS+=("$DOCKERD_PID")

    wait_for_file "$DOCKER_SOCKET" "dockerd" 30 || cleanup
    echo "  dockerd ready (pid ${DOCKERD_PID})"

    echo "=== All daemons started ==="
    echo "Run: DOCKER_HOST=unix://${DOCKER_SOCKET} docker ps"
}
