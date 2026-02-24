#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Env loading ──────────────────────────────────────────────

LOADED_ENV_FILE=""

# Returns 0 on success, 1 if no config file exists.
# Exits immediately if DOCKYARD_ENV is set but the file is missing.
try_load_env() {
    local script_env="${SCRIPT_DIR}/../etc/dockyard.env"
    local root_env="${DOCKYARD_ROOT:-/dockyard}/docker-runtime/etc/dockyard.env"

    if [ -n "${DOCKYARD_ENV:-}" ]; then
        if [ ! -f "$DOCKYARD_ENV" ]; then
            echo "Error: DOCKYARD_ENV file not found: ${DOCKYARD_ENV}" >&2
            exit 1
        fi
        LOADED_ENV_FILE="$(cd "$(dirname "$DOCKYARD_ENV")" && pwd)/$(basename "$DOCKYARD_ENV")"
    elif [ -f "./dockyard.env" ]; then
        LOADED_ENV_FILE="$(pwd)/dockyard.env"
    elif [ -f "$script_env" ]; then
        LOADED_ENV_FILE="$(cd "$(dirname "$script_env")" && pwd)/$(basename "$script_env")"
    elif [ -f "$root_env" ]; then
        LOADED_ENV_FILE="$root_env"
    else
        return 1
    fi

    echo "Loading ${LOADED_ENV_FILE}..."
    set -a; source "$LOADED_ENV_FILE"; set +a
}

load_env() {
    if ! try_load_env; then
        echo "Error: No config found." >&2
        echo "Run './dockyard.sh gen-env' to generate one, or set DOCKYARD_ENV." >&2
        exit 1
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

    # Per-instance system user and group (socket ownership + access control)
    INSTANCE_USER="${DOCKYARD_DOCKER_PREFIX}docker"
    INSTANCE_GROUP="${DOCKYARD_DOCKER_PREFIX}docker"

    # Per-instance sysbox daemons (separate sysbox-mgr + sysbox-fs per installation)
    SYSBOX_RUN_DIR="${DOCKYARD_ROOT}/sysbox-run"
    SYSBOX_DATA_DIR="${DOCKYARD_ROOT}/sysbox"
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

cleanup_pool_bridges() {
    # Remove leftover kernel bridge interfaces (br-*) whose IP falls within
    # DOCKYARD_POOL_BASE. When dockerd exits, it does not clean up user-defined
    # network bridges. Left behind, they cause "overlaps with existing routes"
    # errors on the next install because the pool CIDR is still in the routing table.
    local pool_base="${DOCKYARD_POOL_BASE:-}"
    [ -n "$pool_base" ] || return 0

    # Extract the first two octets of the pool base (e.g. "10.89" from "10.89.0.0/16")
    local pool_prefix
    pool_prefix=$(echo "$pool_base" | grep -oP '^\d+\.\d+')

    local removed=0
    while IFS= read -r iface; do
        [[ "$iface" == br-* ]] || continue
        local iface_ip
        iface_ip=$(ip addr show "$iface" 2>/dev/null | grep -oP 'inet \K[^/]+' | head -1)
        if [[ -n "$iface_ip" && "$iface_ip" == ${pool_prefix}.* ]]; then
            echo "Removing leftover pool bridge: ${iface} (${iface_ip})"
            ip link set "$iface" down 2>/dev/null || true
            ip link delete "$iface" 2>/dev/null || true
            removed=$((removed + 1))
        fi
    done < <(ip link show type bridge 2>/dev/null | grep -oP '^\d+: \K[^:@]+')

    [ "$removed" -gt 0 ] || true
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

# ── Collision checks ─────────────────────────────────────────

check_prefix_conflict() {
    local prefix="${1:-$DOCKYARD_DOCKER_PREFIX}"
    local bridge="${prefix}docker0"
    local exec_root="/run/${prefix}docker"
    local docker_service="${prefix}docker.service"
    local sysbox_service="${prefix}sysbox.service"

    if ip link show "$bridge" &>/dev/null; then
        echo "Error: Bridge ${bridge} already exists — DOCKYARD_DOCKER_PREFIX=${prefix} is in use." >&2
        echo "Use: DOCKYARD_DOCKER_PREFIX=myprefix_ ./dockyard.sh gen-env" >&2
        return 1
    fi
    if [ -d "$exec_root" ]; then
        echo "Error: ${exec_root} already exists — DOCKYARD_DOCKER_PREFIX=${prefix} is in use." >&2
        echo "Use: DOCKYARD_DOCKER_PREFIX=myprefix_ ./dockyard.sh gen-env" >&2
        return 1
    fi
    if systemctl list-unit-files "$docker_service" &>/dev/null 2>&1 && systemctl cat "$docker_service" &>/dev/null 2>&1; then
        echo "Error: Systemd service ${docker_service} already exists — DOCKYARD_DOCKER_PREFIX=${prefix} is in use." >&2
        echo "Use: DOCKYARD_DOCKER_PREFIX=myprefix_ ./dockyard.sh gen-env" >&2
        return 1
    fi
    if systemctl list-unit-files "$sysbox_service" &>/dev/null 2>&1 && systemctl cat "$sysbox_service" &>/dev/null 2>&1; then
        echo "Error: Systemd service ${sysbox_service} already exists — DOCKYARD_DOCKER_PREFIX=${prefix} is in use." >&2
        echo "Use: DOCKYARD_DOCKER_PREFIX=myprefix_ ./dockyard.sh gen-env" >&2
        return 1
    fi
    return 0
}

check_root_conflict() {
    local root="${1:-$DOCKYARD_ROOT}"
    if [ -d "${root}/docker-runtime/bin" ]; then
        echo "Error: ${root}/docker-runtime/bin/ already exists — dockyard is already installed at this root." >&2
        echo "Use: DOCKYARD_ROOT=/other/path ./dockyard.sh gen-env" >&2
        return 1
    fi
    return 0
}

check_private_cidr() {
    local cidr="$1"
    local label="$2"
    local ip="${cidr%/*}"
    local o1 o2
    IFS='.' read -r o1 o2 _ <<< "$ip"

    # 10.0.0.0/8
    if [ "$o1" -eq 10 ]; then return 0; fi
    # 172.16.0.0/12
    if [ "$o1" -eq 172 ] && [ "$o2" -ge 16 ] && [ "$o2" -le 31 ]; then return 0; fi
    # 192.168.0.0/16
    if [ "$o1" -eq 192 ] && [ "$o2" -eq 168 ]; then return 0; fi

    echo "Error: ${label} ${cidr} is not in an RFC 1918 private range." >&2
    echo "  Valid ranges: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16" >&2
    return 1
}

check_subnet_conflict() {
    local fixed_cidr="$1"
    local pool_base="$2"

    local fixed_net="${fixed_cidr%/*}"
    if ip route | grep -qF "${fixed_net}/"; then
        echo "Error: DOCKYARD_FIXED_CIDR ${fixed_cidr} conflicts with an existing route:" >&2
        echo "  $(ip route | grep -F "${fixed_net}/")" >&2
        return 1
    fi

    local pool_net="${pool_base%/*}"
    local pool_two_octets="${pool_net%.*.*}"
    if ip route | grep -qE "^${pool_two_octets}\."; then
        echo "Error: DOCKYARD_POOL_BASE ${pool_base} overlaps with existing routes:" >&2
        echo "  $(ip route | grep -E "^${pool_two_octets}\.")" >&2
        return 1
    fi
    return 0
}

# ── Commands ─────────────────────────────────────────────────

cmd_gen_env() {
    local NOCHECK=false
    for arg in "$@"; do
        case "$arg" in
            --nocheck)  NOCHECK=true ;;
            -h|--help)  gen_env_usage ;;
            --*)        echo "Unknown option: $arg" >&2; gen_env_usage ;;
        esac
    done

    # Determine output file
    local out_file="${DOCKYARD_ENV:-./dockyard.env}"
    if [ -f "$out_file" ]; then
        echo "Error: ${out_file} already exists. Remove it first or set DOCKYARD_ENV to a different path." >&2
        exit 1
    fi

    # Apply env var overrides or defaults
    local root="${DOCKYARD_ROOT:-/dockyard}"
    local prefix="${DOCKYARD_DOCKER_PREFIX:-dy_}"
    local pool_size="${DOCKYARD_POOL_SIZE:-24}"

    # Generate random networks if not provided via env
    local bridge_cidr="${DOCKYARD_BRIDGE_CIDR:-}"
    local fixed_cidr="${DOCKYARD_FIXED_CIDR:-}"
    local pool_base="${DOCKYARD_POOL_BASE:-}"

    if [ -z "$bridge_cidr" ] || [ -z "$fixed_cidr" ] || [ -z "$pool_base" ]; then
        local attempts=0
        local max_attempts=10

        while [ $attempts -lt $max_attempts ]; do
            attempts=$((attempts + 1))

            # Random /24 from 172.16.0.0/12 for bridge
            local b2=$(( RANDOM % 16 + 16 ))   # 16-31
            local b3=$(( RANDOM % 256 ))        # 0-255
            bridge_cidr="${DOCKYARD_BRIDGE_CIDR:-172.${b2}.${b3}.1/24}"
            fixed_cidr="${DOCKYARD_FIXED_CIDR:-172.${b2}.${b3}.0/24}"

            # Random /16 from 172.16.0.0/12 for pool (different second octet)
            local p2=$(( RANDOM % 16 + 16 ))    # 16-31
            while [ "$p2" -eq "$b2" ]; do
                p2=$(( RANDOM % 16 + 16 ))
            done
            pool_base="${DOCKYARD_POOL_BASE:-172.${p2}.0.0/16}"

            if [ "$NOCHECK" = true ]; then
                break
            fi

            if check_subnet_conflict "$fixed_cidr" "$pool_base" 2>/dev/null; then
                break
            fi

            # Reset for next attempt (only re-randomize what wasn't user-provided)
            [ -n "${DOCKYARD_BRIDGE_CIDR:-}" ] || bridge_cidr=""
            [ -n "${DOCKYARD_FIXED_CIDR:-}" ] || fixed_cidr=""
            [ -n "${DOCKYARD_POOL_BASE:-}" ] || pool_base=""

            if [ $attempts -eq $max_attempts ]; then
                echo "Error: Could not find non-conflicting subnets after ${max_attempts} attempts." >&2
                echo "Provide explicit values via DOCKYARD_BRIDGE_CIDR, DOCKYARD_FIXED_CIDR, DOCKYARD_POOL_BASE." >&2
                exit 1
            fi
        done
    else
        # All three provided explicitly — validate unless --nocheck
        if [ "$NOCHECK" = false ]; then
            check_subnet_conflict "$fixed_cidr" "$pool_base" || exit 1
        fi
    fi

    # Validate all CIDRs are in RFC 1918 private ranges
    check_private_cidr "$bridge_cidr" "DOCKYARD_BRIDGE_CIDR" || exit 1
    check_private_cidr "$fixed_cidr"  "DOCKYARD_FIXED_CIDR"  || exit 1
    check_private_cidr "$pool_base"   "DOCKYARD_POOL_BASE"   || exit 1

    # Conflict checks (unless --nocheck)
    if [ "$NOCHECK" = false ]; then
        check_prefix_conflict "$prefix" || exit 1
        check_root_conflict "$root" || exit 1
    fi

    # Write config file
    cat > "$out_file" <<EOF
# Dockyard configuration
# Generated by: dockyard.sh gen-env

DOCKYARD_ROOT=${root}
DOCKYARD_DOCKER_PREFIX=${prefix}
DOCKYARD_BRIDGE_CIDR=${bridge_cidr}
DOCKYARD_FIXED_CIDR=${fixed_cidr}
DOCKYARD_POOL_BASE=${pool_base}
DOCKYARD_POOL_SIZE=${pool_size}
EOF

    echo "Generated ${out_file}:"
    echo ""
    cat "$out_file"
}

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
PIDFile=${EXEC_ROOT}/dockerd.pid

# Create runtime and sysbox directories
ExecStartPre=/bin/mkdir -p ${LOG_DIR} ${RUN_DIR} ${EXEC_ROOT}/containerd ${DOCKER_DATA}/containerd ${SYSBOX_RUN_DIR} ${SYSBOX_DATA_DIR}

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
ExecStartPre=/bin/bash -c '${BIN_DIR}/containerd --root ${DOCKER_DATA}/containerd --state ${EXEC_ROOT}/containerd --address ${CONTAINERD_SOCKET} &>${LOG_DIR}/containerd.log & echo \$! > ${RUN_DIR}/containerd.pid; i=0; while [ ! -e ${CONTAINERD_SOCKET} ]; do sleep 1; i=\$((i+1)); if [ \$i -ge 30 ]; then echo "containerd did not start within 30s" >&2; exit 1; fi; done'

# Start dockerd
ExecStart=/bin/bash -c '${BIN_DIR}/dockerd --config-file ${ETC_DIR}/daemon.json --containerd ${CONTAINERD_SOCKET} --data-root ${DOCKER_DATA} --exec-root ${EXEC_ROOT} --pidfile ${EXEC_ROOT}/dockerd.pid --bridge ${BRIDGE} --fixed-cidr ${DOCKYARD_FIXED_CIDR} --default-address-pool base=${DOCKYARD_POOL_BASE},size=${DOCKYARD_POOL_SIZE} --host unix://${DOCKER_SOCKET} --iptables=false --group ${INSTANCE_GROUP} &>${LOG_DIR}/dockerd.log & i=0; while [ ! -e ${DOCKER_SOCKET} ]; do sleep 1; i=\$((i+1)); if [ \$i -ge 30 ]; then echo "dockerd did not start within 30s" >&2; exit 1; fi; done'

# Start DinD ownership watcher (fixes sysbox uid mapping for Docker 29+)
ExecStartPost=/bin/bash -c 'SYSBOX_UID_OFFSET=\$(awk -F: '"'"'\$1=="sysbox"{print \$2;exit}'"'"' /etc/subuid 2>/dev/null || echo 231072); SYSBOX_DOCKER_DIR=${SYSBOX_DATA_DIR}/docker; mkdir -p "\$SYSBOX_DOCKER_DIR"; find "\$SYSBOX_DOCKER_DIR" -maxdepth 1 -mindepth 1 -uid 0 -exec chown "\${SYSBOX_UID_OFFSET}:\${SYSBOX_UID_OFFSET}" {} \; 2>/dev/null || true; (while true; do for d in "\$SYSBOX_DOCKER_DIR"/*/; do [ -d "\$d" ] || continue; uid=\$(stat -c "%u" "\$d" 2>/dev/null) || continue; [ "\$uid" = "0" ] && chown "\${SYSBOX_UID_OFFSET}:\${SYSBOX_UID_OFFSET}" "\$d" 2>/dev/null; done; sleep 1; done) & echo \$! > ${RUN_DIR}/dind-watcher.pid'

# Kill DinD watcher on stop
ExecStopPost=-/bin/bash -c 'kill \$(cat ${RUN_DIR}/dind-watcher.pid 2>/dev/null) 2>/dev/null || true; rm -f ${RUN_DIR}/dind-watcher.pid'

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

cmd_disable() {
    require_root

    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

    if [ -f "$SERVICE_FILE" ]; then
        if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
            echo "Stopping ${SERVICE_NAME}..."
            systemctl stop "${SERVICE_NAME}.service"
            echo "  stopped"
        fi
        if systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
            systemctl disable "${SERVICE_NAME}.service"
            echo "  disabled"
        fi
        rm -f "$SERVICE_FILE"
        echo "Removed ${SERVICE_FILE}"
    else
        echo "Warning: ${SERVICE_FILE} does not exist." >&2
    fi

    systemctl daemon-reload
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

    # --- 1. Start per-instance sysbox daemons ---
    mkdir -p "$SYSBOX_RUN_DIR" "$SYSBOX_DATA_DIR"

    echo "Starting sysbox-mgr..."
    "${BIN_DIR}/sysbox-mgr" --run-dir "${SYSBOX_RUN_DIR}" --data-root "${SYSBOX_DATA_DIR}" \
        &>"${LOG_DIR}/sysbox-mgr.log" &
    SYSBOX_MGR_PID=$!
    echo "$SYSBOX_MGR_PID" > "${SYSBOX_RUN_DIR}/sysbox-mgr.pid"
    STARTED_PIDS+=("$SYSBOX_MGR_PID")
    wait_for_file "${SYSBOX_RUN_DIR}/sysmgr.sock" "sysbox-mgr" 30 || cleanup
    echo "  sysbox-mgr ready (pid ${SYSBOX_MGR_PID})"

    echo "Starting sysbox-fs..."
    "${BIN_DIR}/sysbox-fs" --run-dir "${SYSBOX_RUN_DIR}" --mountpoint "${SYSBOX_DATA_DIR}" \
        &>"${LOG_DIR}/sysbox-fs.log" &
    SYSBOX_FS_PID=$!
    echo "$SYSBOX_FS_PID" > "${SYSBOX_RUN_DIR}/sysbox-fs.pid"
    STARTED_PIDS+=("$SYSBOX_FS_PID")
    wait_for_file "${SYSBOX_RUN_DIR}/sysfs.sock" "sysbox-fs" 30 || cleanup
    echo "  sysbox-fs ready (pid ${SYSBOX_FS_PID})"

    # --- 1b. DinD ownership watcher ---
    # Sysbox creates each container's /var/lib/docker backing dir at
    # ${SYSBOX_DATA_DIR}/docker/<id> owned by root:root.
    # The container's uid namespace maps uid 0 → SYSBOX_UID_OFFSET, so container
    # root can't access a root-owned directory.  Docker 29+ makes chmod on the
    # data-root fatal, so DinD breaks on every new container.
    # Fix: read the actual sysbox uid offset and chown each backing dir to it.
    SYSBOX_UID_OFFSET=$(awk -F: '$1=="sysbox" {print $2; exit}' /etc/subuid 2>/dev/null || echo 231072)
    SYSBOX_DOCKER_DIR="${SYSBOX_DATA_DIR}/docker"

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
        --group "${INSTANCE_GROUP}" \
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
    echo "  ${SERVICE_FILE}              (docker systemd service)"
    echo "  ${RUNTIME_DIR}/    (binaries, config, logs, pids)"
    echo "  ${DOCKER_DATA}/            (images, containers, volumes)"
    echo "  ${SYSBOX_DATA_DIR}/        (sysbox data)"
    echo "  ${DOCKER_SOCKET}        (socket)"
    echo "  ${EXEC_ROOT}/                         (runtime state)"
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

    # --- 6. Remove per-instance sysbox data ---
    if [ -d "$SYSBOX_DATA_DIR" ]; then
        rm -rf "$SYSBOX_DATA_DIR"
        echo "Removed ${SYSBOX_DATA_DIR}/ (sysbox data)"
    fi

    # --- 6b. Remove AppArmor fusermount3 entry for this instance ---
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

    # --- 9. Remove instance user and group ---
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

# ── Usage ────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: ./dockyard.sh <command> [options]

Commands:
  gen-env     Generate a conflict-free dockyard.env config file
  create      Download binaries, install config, set up systemd, start daemon
  enable      Install systemd service for this instance
  disable     Remove systemd service for this instance
  start       Start daemons manually (without systemd)
  stop        Stop manually started daemons
  status      Show instance status
  destroy     Stop and remove everything

All commands except gen-env require a config file:
  1. $DOCKYARD_ENV (if set)
  2. ./dockyard.env (in current directory)
  3. ../etc/dockyard.env (relative to script — for installed copy)
  4. $DOCKYARD_ROOT/docker-runtime/etc/dockyard.env

Examples:
  ./dockyard.sh gen-env
  sudo ./dockyard.sh create
  sudo ./dockyard.sh create --no-systemd --no-start
  sudo ./dockyard.sh start
  sudo ./dockyard.sh stop
  ./dockyard.sh status
  sudo ./dockyard.sh destroy

  # Multiple instances
  DOCKYARD_DOCKER_PREFIX=test_ DOCKYARD_ROOT=/test ./dockyard.sh gen-env
  DOCKYARD_ENV=./dockyard.env sudo -E ./dockyard.sh create
EOF
    exit 0
}

gen_env_usage() {
    cat <<'EOF'
Usage: ./dockyard.sh gen-env [OPTIONS]

Generate a dockyard.env config file with randomized, conflict-free networks.

Options:
  --nocheck     Skip all conflict checks
  -h, --help    Show this help

Output: ./dockyard.env (or $DOCKYARD_ENV if set). Errors if file exists.

Override any variable via environment:
  DOCKYARD_ROOT           Installation root (default: /dockyard)
  DOCKYARD_DOCKER_PREFIX  Prefix for bridge/service (default: dy_)
  DOCKYARD_BRIDGE_CIDR    Bridge IP/mask (default: random from 172.16.0.0/12)
  DOCKYARD_FIXED_CIDR     Container subnet (default: derived from bridge)
  DOCKYARD_POOL_BASE      Address pool base (default: random from 172.16.0.0/12)
  DOCKYARD_POOL_SIZE      Pool subnet size (default: 24)

Examples:
  ./dockyard.sh gen-env
  DOCKYARD_DOCKER_PREFIX=test_ ./dockyard.sh gen-env
  DOCKYARD_ROOT=/docker2 DOCKYARD_DOCKER_PREFIX=d2_ ./dockyard.sh gen-env
  ./dockyard.sh gen-env --nocheck
EOF
    exit 0
}

create_usage() {
    cat <<'EOF'
Usage: sudo ./dockyard.sh create [OPTIONS]

Create a dockyard instance: download binaries, install config,
set up systemd service, and start the daemon.

Requires a dockyard.env config file (run gen-env first).

Options:
  --no-systemd    Skip systemd service installation
  --no-start      Don't start the daemon after install
  -h, --help      Show this help

Examples:
  ./dockyard.sh gen-env && sudo ./dockyard.sh create
  sudo ./dockyard.sh create --no-systemd --no-start
  DOCKYARD_ENV=./custom.env sudo -E ./dockyard.sh create
EOF
    exit 0
}

# ── Dispatch ─────────────────────────────────────────────────

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    gen-env)
        cmd_gen_env "$@"
        ;;
    create)
        if ! try_load_env; then
            echo "No config found — auto-generating with random networks..."
            cmd_gen_env
            load_env
        fi
        derive_vars
        cmd_create "$@"
        ;;
    enable)
        load_env
        derive_vars
        cmd_enable
        ;;
    disable)
        load_env
        derive_vars
        cmd_disable
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
    destroy)
        load_env
        derive_vars
        cmd_destroy "$@"
        ;;
    -h|--help|"")
        usage
        ;;
    *)
        echo "Unknown command: $COMMAND" >&2
        usage
        ;;
esac

