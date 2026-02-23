cmd_create() {
    local INSTALL_SYSTEMD=true
    local START_DAEMON=true
    for arg in "$@"; do
        case "$arg" in
            --no-systemd) INSTALL_SYSTEMD=false ;;
            --no-start)   START_DAEMON=false ;;
            -h|--help)    create_usage ;;
            --*)          echo "Unknown option: $arg" >&2; create_usage ;;
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
    check_private_cidr "$DOCKYARD_BRIDGE_CIDR" "DOCKYARD_BRIDGE_CIDR" || exit 1
    check_private_cidr "$DOCKYARD_FIXED_CIDR"  "DOCKYARD_FIXED_CIDR"  || exit 1
    check_private_cidr "$DOCKYARD_POOL_BASE"   "DOCKYARD_POOL_BASE"   || exit 1
    check_root_conflict "$DOCKYARD_ROOT" || exit 1
    check_prefix_conflict "$DOCKYARD_DOCKER_PREFIX" || exit 1
    check_subnet_conflict "$DOCKYARD_FIXED_CIDR" "$DOCKYARD_POOL_BASE" || exit 1

    # --- 1. Download and extract binaries ---
    local CACHE_DIR="${SCRIPT_DIR}/.tmp"

    # Version compatibility notes — do not upgrade these without reading:
    #
    # DOCKER_VERSION: static binary from download.docker.com/linux/static/stable.
    #   Uses sysbox-runc as default runtime → the bundled runc 1.3.3 is never
    #   called for sandbox containers, so this version does NOT trigger the
    #   sysbox procfs incompatibility (nestybox/sysbox#973).
    #   Minimum 29.x required for the DinD ownership watcher (commit 2deac51).
    #
    # SYSBOX_VERSION: 0.6.7 is the last CE release (May 2024). EE archived Aug
    #   2025. Incompatible with containerd.io ≥ 1.7.28-2 and ≥ 2.x when used
    #   via apt (does not affect the static binary path used here).
    #   The inner sandbox image pins containerd.io=1.7.27-1 to stay clear of
    #   both the 1.7.28-2 runc-1.3.3 issue and the containerd-2.x breakage.
    #   See Sandcastle issue #56, nestybox/sysbox#973, opencontainers/runc#4968.
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
    mkdir -p "$SYSBOX_SHARED_BIN" "$SYSBOX_SHARED_DATA" "$SYSBOX_SHARED_LOG"

    # Allow sysbox-fs FUSE mounts at the dockyard sysbox mountpoint.
    # The default fusermount3 AppArmor profile (tightened in Ubuntu 25.10+)
    # only permits FUSE mounts under $HOME, /mnt, /tmp, etc.  Without this
    # override every sysbox container fails with a context-deadline-exceeded
    # RPC error from sysbox-fs.
    if [ -d /etc/apparmor.d ]; then
        mkdir -p /etc/apparmor.d/local
        cat > /etc/apparmor.d/local/fusermount3 <<APPARMOR
# Allow sysbox-fs FUSE mounts (shared dockyard-sysbox mountpoint)
mount fstype=fuse options=(nosuid,nodev) options in (ro,rw) -> ${SYSBOX_SHARED_DATA}/**/,
umount ${SYSBOX_SHARED_DATA}/**/,
APPARMOR
        if [ -f /etc/apparmor.d/fusermount3 ]; then
            apparmor_parser -r /etc/apparmor.d/fusermount3
            echo "  AppArmor fusermount3 profile updated"
        fi
    fi

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
    dpkg-deb -x "${CACHE_DIR}/${SYSBOX_DEB}" "$SYSBOX_EXTRACT"
    # sysbox-runc is per-instance (called by containerd via daemon.json)
    cp -f "$SYSBOX_EXTRACT/usr/bin/sysbox-runc" "$BIN_DIR/"
    # sysbox-mgr and sysbox-fs go to the shared location (one daemon per host)
    cp -f "$SYSBOX_EXTRACT/usr/bin/sysbox-mgr" "$SYSBOX_SHARED_BIN/"
    cp -f "$SYSBOX_EXTRACT/usr/bin/sysbox-fs" "$SYSBOX_SHARED_BIN/"
    chmod +x "$SYSBOX_SHARED_BIN/"sysbox-{mgr,fs}

    mkdir -p "${RUNTIME_DIR}/lib/docker"

    chmod +x "$BIN_DIR"/*

    # Rename docker CLI binary, replace with DOCKER_HOST wrapper
    mv -f "${BIN_DIR}/docker" "${BIN_DIR}/docker-cli"
    cat > "${BIN_DIR}/docker" <<DOCKEREOF
#!/bin/bash
export DOCKER_HOST="unix://${DOCKER_SOCKET}"
export DOCKER_CONFIG="${RUNTIME_DIR}/lib/docker"
exec "\$(dirname "\$0")/docker-cli" "\$@"
DOCKEREOF
    chmod +x "${BIN_DIR}/docker"

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
  "storage-driver": "overlay2",
  "userland-proxy-path": "${BIN_DIR}/docker-proxy",
  "features": {
    "buildkit": true
  }
}
DAEMONJSONEOF
    echo "Installed config to ${ETC_DIR}/daemon.json"

    # Copy config file and dockyardctl into instance
    cp "$LOADED_ENV_FILE" "${ETC_DIR}/dockyard.env"
    cp "${SCRIPT_DIR}/dockyard.sh" "${BIN_DIR}/dockyardctl"
    chmod +x "${BIN_DIR}/dockyardctl"
    echo "Installed env to ${ETC_DIR}/dockyard.env"
    echo "Installed dockyardctl to ${BIN_DIR}/dockyardctl"

    # --- 2. Install systemd service ---
    if [ "$INSTALL_SYSTEMD" = true ]; then
        echo ""
        cmd_enable
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
    echo "  ${BIN_DIR}/docker run -ti alpine ash"
    echo ""
    echo "Manage this instance:"
    echo "  ${BIN_DIR}/dockyardctl status"
    echo "  sudo ${BIN_DIR}/dockyardctl destroy"
}
