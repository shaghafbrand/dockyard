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
