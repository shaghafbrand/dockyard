#!/bin/bash
set -euo pipefail

# Must run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root (use sudo)" >&2
    exit 1
fi

SANDCASTLE_ROOT="${SANDCASTLE_ROOT:-/sandcastle}"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${BUILD_DIR}/.tmp"
BIN_DIR="${SANDCASTLE_ROOT}/docker-runtime/bin"

DOCKER_VERSION="29.2.1"
DOCKER_ROOTLESS_VERSION="29.2.1"
SYSBOX_VERSION="0.6.7"
SYSBOX_DEB="sysbox-ce_${SYSBOX_VERSION}-0.linux_amd64.deb"

DOCKER_URL="https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz"
DOCKER_ROOTLESS_URL="https://download.docker.com/linux/static/stable/x86_64/docker-rootless-extras-${DOCKER_ROOTLESS_VERSION}.tgz"
SYSBOX_URL="https://downloads.nestybox.com/sysbox/releases/v${SYSBOX_VERSION}/${SYSBOX_DEB}"

mkdir -p "${CACHE_DIR}" "${BIN_DIR}"

# Download helper: skip if already cached
download() {
    local url="$1"
    local dest="${CACHE_DIR}/$(basename "$url")"
    if [ -f "$dest" ]; then
        echo "Cached: $(basename "$dest")"
    else
        echo "Downloading: $(basename "$url")"
        curl -fsSL -o "$dest" "$url"
    fi
}

echo "=== Downloading artifacts ==="
download "$DOCKER_URL"
download "$DOCKER_ROOTLESS_URL"
download "$SYSBOX_URL"

echo "=== Extracting Docker binaries ==="
tar -xzf "${CACHE_DIR}/docker-${DOCKER_VERSION}.tgz" -C "${CACHE_DIR}"
cp -f "${CACHE_DIR}/docker/"* "${BIN_DIR}/"

echo "=== Extracting Docker rootless extras ==="
tar -xzf "${CACHE_DIR}/docker-rootless-extras-${DOCKER_ROOTLESS_VERSION}.tgz" -C "${CACHE_DIR}"
cp -f "${CACHE_DIR}/docker-rootless-extras/"* "${BIN_DIR}/"

echo "=== Extracting sysbox from .deb ==="
SYSBOX_EXTRACT="${CACHE_DIR}/sysbox-extract"
mkdir -p "$SYSBOX_EXTRACT"
cd "$SYSBOX_EXTRACT"
ar x "${CACHE_DIR}/${SYSBOX_DEB}"
# data.tar.gz contains the binaries under usr/bin/
tar -xzf data.tar.* 2>/dev/null || tar -xf data.tar.* 2>/dev/null
cp -f usr/bin/sysbox-runc "${BIN_DIR}/"
cp -f usr/bin/sysbox-mgr "${BIN_DIR}/"
cp -f usr/bin/sysbox-fs "${BIN_DIR}/"
cd "$BUILD_DIR"

chmod +x "${BIN_DIR}"/*

echo "=== Installed binaries ==="
ls -1 "${BIN_DIR}/"
