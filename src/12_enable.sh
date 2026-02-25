cmd_enable() {
    require_root

    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

    if [ -f "$SERVICE_FILE" ]; then
        echo "Error: ${SERVICE_FILE} already exists." >&2
        exit 1
    fi

    echo "Installing ${SERVICE_NAME}.service (with per-instance sysbox)..."

    cat > "$SERVICE_FILE" <<SERVICEEOF
[Unit]
Description=Dockyard Docker (${SERVICE_NAME})
After=network-online.target nss-lookup.target firewalld.service time-set.target
Before=docker.service
Wants=network-online.target
StartLimitBurst=3
StartLimitIntervalSec=60

[Service]
Type=forking
PIDFile=${RUN_DIR}/dockerd.pid
Environment=PATH=${BIN_DIR}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Create runtime and sysbox directories
ExecStartPre=/bin/mkdir -p ${LOG_DIR} ${RUN_DIR}/containerd ${SYSBOX_RUN_DIR} ${DOCKER_DATA}/containerd ${SYSBOX_DATA_DIR}

# Clean stale sockets
ExecStartPre=-/bin/rm -f ${CONTAINERD_SOCKET} ${DOCKER_SOCKET}

# Enable IP forwarding
ExecStartPre=/bin/bash -c 'sysctl -w net.ipv4.ip_forward=1 >/dev/null'

# Create bridge
ExecStartPre=/bin/bash -c 'if ! ip link show ${BRIDGE} &>/dev/null; then ip link add ${BRIDGE} type bridge && ip addr add ${DOCKYARD_BRIDGE_CIDR} dev ${BRIDGE} && ip link set ${BRIDGE} up; fi'

# Add iptables rules for container networking (bridge)
ExecStartPre=/bin/bash -c 'iptables -I FORWARD -i ${BRIDGE} -o ${BRIDGE} -j ACCEPT && iptables -I FORWARD -i ${BRIDGE} ! -o ${BRIDGE} -j ACCEPT && iptables -I FORWARD -o ${BRIDGE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT && iptables -t nat -I POSTROUTING -s ${DOCKYARD_FIXED_CIDR} ! -o ${BRIDGE} -j MASQUERADE'

# Add iptables rules for user-defined networks (from default-address-pool)
ExecStartPre=/bin/bash -c 'iptables -I FORWARD -s ${DOCKYARD_POOL_BASE} -j ACCEPT && iptables -I FORWARD -d ${DOCKYARD_POOL_BASE} -j ACCEPT && iptables -t nat -I POSTROUTING -s ${DOCKYARD_POOL_BASE} -j MASQUERADE'

# Start sysbox-mgr and wait for socket
ExecStartPre=/bin/bash -c '${BIN_DIR}/sysbox-mgr --run-dir ${SYSBOX_RUN_DIR} --data-root ${SYSBOX_DATA_DIR} &>${LOG_DIR}/sysbox-mgr.log & echo \$! > ${SYSBOX_RUN_DIR}/sysbox-mgr.pid; i=0; while [ ! -e ${SYSBOX_RUN_DIR}/sysmgr.sock ]; do sleep 1; i=\$((i+1)); if [ \$i -ge 30 ]; then echo "sysbox-mgr did not start within 30s" >&2; exit 1; fi; done'

# Start sysbox-fs and wait for socket
ExecStartPre=/bin/bash -c '${BIN_DIR}/sysbox-fs --run-dir ${SYSBOX_RUN_DIR} --mountpoint ${SYSBOX_DATA_DIR} &>${LOG_DIR}/sysbox-fs.log & echo \$! > ${SYSBOX_RUN_DIR}/sysbox-fs.pid; i=0; while [ ! -e ${SYSBOX_RUN_DIR}/sysfs.sock ]; do sleep 1; i=\$((i+1)); if [ \$i -ge 30 ]; then echo "sysbox-fs did not start within 30s" >&2; exit 1; fi; done'

# Start containerd and wait for socket
ExecStartPre=/bin/bash -c '${BIN_DIR}/containerd --root ${DOCKER_DATA}/containerd --state ${RUN_DIR}/containerd --address ${CONTAINERD_SOCKET} &>${LOG_DIR}/containerd.log & echo \$! > ${RUN_DIR}/containerd.pid; i=0; while [ ! -e ${CONTAINERD_SOCKET} ]; do sleep 1; i=\$((i+1)); if [ \$i -ge 30 ]; then echo "containerd did not start within 30s" >&2; exit 1; fi; done'

# Start dockerd
ExecStart=/bin/bash -c '${BIN_DIR}/dockerd --config-file ${ETC_DIR}/daemon.json --containerd ${CONTAINERD_SOCKET} --data-root ${DOCKER_DATA} --exec-root ${RUN_DIR} --pidfile ${RUN_DIR}/dockerd.pid --bridge ${BRIDGE} --fixed-cidr ${DOCKYARD_FIXED_CIDR} --default-address-pool base=${DOCKYARD_POOL_BASE},size=${DOCKYARD_POOL_SIZE} --host unix://${DOCKER_SOCKET} --iptables=false --group ${INSTANCE_GROUP} &>${LOG_DIR}/dockerd.log & i=0; while [ ! -e ${DOCKER_SOCKET} ]; do sleep 1; i=\$((i+1)); if [ \$i -ge 30 ]; then echo "dockerd did not start within 30s" >&2; exit 1; fi; done'

# Stop containerd
ExecStopPost=-/bin/bash -c 'if [ -f ${RUN_DIR}/containerd.pid ]; then kill \$(cat ${RUN_DIR}/containerd.pid) 2>/dev/null; rm -f ${RUN_DIR}/containerd.pid; fi'

# Clean up docker/containerd sockets
ExecStopPost=-/bin/rm -f ${DOCKER_SOCKET} ${CONTAINERD_SOCKET}

# Remove iptables rules (bridge)
ExecStopPost=-/bin/bash -c 'iptables -D FORWARD -i ${BRIDGE} -o ${BRIDGE} -j ACCEPT 2>/dev/null; iptables -D FORWARD -i ${BRIDGE} ! -o ${BRIDGE} -j ACCEPT 2>/dev/null; iptables -D FORWARD -o ${BRIDGE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; iptables -t nat -D POSTROUTING -s ${DOCKYARD_FIXED_CIDR} ! -o ${BRIDGE} -j MASQUERADE 2>/dev/null'

# Remove iptables rules (user-defined networks)
ExecStopPost=-/bin/bash -c 'iptables -D FORWARD -s ${DOCKYARD_POOL_BASE} -j ACCEPT 2>/dev/null; iptables -D FORWARD -d ${DOCKYARD_POOL_BASE} -j ACCEPT 2>/dev/null; iptables -t nat -D POSTROUTING -s ${DOCKYARD_POOL_BASE} -j MASQUERADE 2>/dev/null'

# Remove bridge
ExecStopPost=-/bin/bash -c 'if ip link show ${BRIDGE} &>/dev/null; then ip link set ${BRIDGE} down 2>/dev/null; ip link delete ${BRIDGE} 2>/dev/null; fi'

# Stop sysbox-fs
ExecStopPost=-/bin/bash -c 'if [ -f ${SYSBOX_RUN_DIR}/sysbox-fs.pid ]; then kill \$(cat ${SYSBOX_RUN_DIR}/sysbox-fs.pid) 2>/dev/null || true; rm -f ${SYSBOX_RUN_DIR}/sysbox-fs.pid; fi'

# Stop sysbox-mgr
ExecStopPost=-/bin/bash -c 'if [ -f ${SYSBOX_RUN_DIR}/sysbox-mgr.pid ]; then kill \$(cat ${SYSBOX_RUN_DIR}/sysbox-mgr.pid) 2>/dev/null || true; rm -f ${SYSBOX_RUN_DIR}/sysbox-mgr.pid; fi'

# Clean up sysbox run dir
ExecStopPost=-/bin/rm -rf ${SYSBOX_RUN_DIR}

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
    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service"
    echo "  enabled ${SERVICE_NAME}.service (will start on boot)"
    echo ""
    echo "  sudo systemctl start ${SERVICE_NAME}    # start"
    echo "  sudo systemctl status ${SERVICE_NAME}   # check status"
    echo "  sudo journalctl -u ${SERVICE_NAME} -f   # follow logs"
}
