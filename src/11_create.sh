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
    echo "  user:        ${INSTANCE_USER}"
    echo "  group:       ${INSTANCE_GROUP}"
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
    # SYSBOX_VERSION: 0.6.7.4-tc is a patched fork (github.com/thieso2/sysbox)
    #   that adds --run-dir to sysbox-mgr and sysbox-fs, and SYSBOX_RUN_DIR env
    #   var support to sysbox-runc, allowing N independent sysbox instances per
    #   host (each with its own socket dir).
    #   NOTE: sysbox-runc's --run-dir CLI flag (also added in 0.6.7.4-tc) is
    #   incomplete — it redirects sysmgr.sock and sysfs.sock but NOT the seccomp
    #   tracer socket (sysfs-seccomp.sock), which is computed before app.Before
    #   fires. The SYSBOX_RUN_DIR env var works correctly because init() runs
    #   before all socket paths are fixed. So sysbox-runc is installed as a thin
    #   wrapper script that sets SYSBOX_RUN_DIR before exec'ing the real binary.
    #   See: https://github.com/thieso2/sysbox/issues/4
    #   Distributed as a static tarball (no .deb, no dpkg dependency).
    local DOCKER_VERSION="29.2.1"
    local DOCKER_ROOTLESS_VERSION="29.2.1"
    local SYSBOX_VERSION="0.6.7.4-tc"
    local SYSBOX_TARBALL="sysbox-static-x86_64.tar.gz"

    local DOCKER_URL="https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz"
    local DOCKER_ROOTLESS_URL="https://download.docker.com/linux/static/stable/x86_64/docker-rootless-extras-${DOCKER_ROOTLESS_VERSION}.tgz"
    local SYSBOX_URL="https://github.com/thieso2/sysbox/releases/download/v${SYSBOX_VERSION}/${SYSBOX_TARBALL}"

    mkdir -p "$LOG_DIR" "$RUN_DIR" "$ETC_DIR" "$BIN_DIR"
    mkdir -p "$DOCKER_DATA"
    mkdir -p "$CACHE_DIR"
    mkdir -p "$SYSBOX_RUN_DIR"
    mkdir -p "$SYSBOX_DATA_DIR"

    # Create system user and group for this instance.
    # dockerd runs as root but creates the socket owned by this group (--group flag),
    # so operators simply join the group to get socket access without sudo.
    if ! getent group "${INSTANCE_GROUP}" &>/dev/null; then
        groupadd --system "${INSTANCE_GROUP}"
        echo "  Created group ${INSTANCE_GROUP}"
    else
        echo "  Group ${INSTANCE_GROUP} already exists"
    fi
    if ! getent passwd "${INSTANCE_USER}" &>/dev/null; then
        useradd --system --no-create-home --shell /bin/false \
            --gid "${INSTANCE_GROUP}" "${INSTANCE_USER}"
        echo "  Created user ${INSTANCE_USER}"
    else
        echo "  User ${INSTANCE_USER} already exists"
    fi

    # Allow sysbox-fs FUSE mounts at this instance's sysbox mountpoint.
    # The default fusermount3 AppArmor profile (tightened in Ubuntu 25.10+)
    # only permits FUSE mounts under $HOME, /mnt, /tmp, etc.  Without this
    # override every sysbox container fails with a context-deadline-exceeded
    # RPC error from sysbox-fs.
    # Each instance appends a tagged block; destroy removes it.
    if [ -d /etc/apparmor.d ]; then
        mkdir -p /etc/apparmor.d/local
        local apparmor_file="/etc/apparmor.d/local/fusermount3"
        local apparmor_begin="# dockyard:${DOCKYARD_DOCKER_PREFIX}:begin"
        local apparmor_end="# dockyard:${DOCKYARD_DOCKER_PREFIX}:end"
        if ! grep -qF "$apparmor_begin" "$apparmor_file" 2>/dev/null; then
            {
                echo "$apparmor_begin"
                echo "mount fstype=fuse options=(nosuid,nodev) options in (ro,rw) -> ${SYSBOX_DATA_DIR}/**/,"
                echo "umount ${SYSBOX_DATA_DIR}/**/,"
                echo "$apparmor_end"
            } >> "$apparmor_file"
        fi
        if [ -f /etc/apparmor.d/fusermount3 ]; then
            apparmor_parser -r /etc/apparmor.d/fusermount3
            echo "  AppArmor fusermount3 profile updated for ${SYSBOX_DATA_DIR}"
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

    echo "Extracting sysbox static binaries..."
    local SYSBOX_EXTRACT="${CACHE_DIR}/sysbox-static-${SYSBOX_VERSION}"
    mkdir -p "$SYSBOX_EXTRACT"
    tar -xzf "${CACHE_DIR}/${SYSBOX_TARBALL}" -C "$SYSBOX_EXTRACT"
    # sysbox-mgr and sysbox-fs go directly to BIN_DIR.
    # sysbox-runc is installed as sysbox-runc-bin; a wrapper script at
    # sysbox-runc sets SYSBOX_RUN_DIR so the binary's init() connects to
    # this instance's per-instance sysbox sockets (including sysfs-seccomp.sock).
    # Using --run-dir via runtimeArgs is incomplete in 0.6.7.4-tc (see comment
    # above), so the env-var-via-wrapper approach is used instead.
    for bin in sysbox-runc sysbox-mgr sysbox-fs; do
        local src
        src=$(find "$SYSBOX_EXTRACT" -name "$bin" -type f | head -1)
        if [ -z "$src" ]; then
            echo "Error: $bin not found in ${SYSBOX_TARBALL}" >&2
            exit 1
        fi
        if [ "$bin" = "sysbox-runc" ]; then
            cp -f "$src" "${BIN_DIR}/sysbox-runc-bin"
            chmod +x "${BIN_DIR}/sysbox-runc-bin"
        else
            cp -f "$src" "$BIN_DIR/$bin"
            chmod +x "$BIN_DIR/$bin"
        fi
    done
    # Wrapper: sets SYSBOX_RUN_DIR so sysbox-runc-bin's init() redirects ALL
    # per-instance sockets (sysmgr.sock, sysfs.sock, sysfs-seccomp.sock).
    cat > "${BIN_DIR}/sysbox-runc" <<SYSBOXWRAPEOF
#!/bin/sh
export SYSBOX_RUN_DIR="${SYSBOX_RUN_DIR}"
exec "${BIN_DIR}/sysbox-runc-bin" "\$@"
SYSBOXWRAPEOF
    chmod +x "${BIN_DIR}/sysbox-runc"

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
    # sysbox-runc is a wrapper script that sets SYSBOX_RUN_DIR before exec'ing
    # the real binary; no runtimeArgs needed.
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

    # Set ownership of the instance root so every file is attributed to the
    # instance user/group. dockerd still runs as root, so it can write freely;
    # the ownership is for identification and directory-level access control.
    chown -R "${INSTANCE_USER}:${INSTANCE_GROUP}" "${DOCKYARD_ROOT}"
    echo "Set ownership of ${DOCKYARD_ROOT}/ to ${INSTANCE_USER}:${INSTANCE_GROUP}"

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
