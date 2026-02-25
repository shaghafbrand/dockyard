# ── Collision checks ─────────────────────────────────────────

check_prefix_conflict() {
    local prefix="${1:-$DOCKYARD_DOCKER_PREFIX}"
    local bridge="${prefix}docker0"
    local docker_service="${prefix}docker.service"
    local sysbox_service="${prefix}sysbox.service"

    if ip link show "$bridge" &>/dev/null; then
        echo "Error: Bridge ${bridge} already exists — DOCKYARD_DOCKER_PREFIX=${prefix} is in use." >&2
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
    if [ -d "${root}/bin" ]; then
        echo "Error: ${root}/bin/ already exists — dockyard is already installed at this root." >&2
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

# Cross-check proposed CIDRs against sibling dockyard env files in the given
# directory.  Prevents gen-env for instance B from picking a pool range that
# shares a /16 with instance A's bridge CIDR (and vice versa), which would
# cause a conflict when concurrent creates bring A's bridge up before B's
# check_subnet_conflict runs.
check_sibling_conflict() {
    local fixed_cidr="$1"
    local pool_base="$2"
    local env_dir="$3"

    [ -d "$env_dir" ] || return 0

    local our_bridge_two our_pool_two
    our_bridge_two="${fixed_cidr%.*.*}"     # e.g. "172.21" from 172.21.116.0/24
    our_pool_two="${pool_base%/*}"
    our_pool_two="${our_pool_two%.*.*}"     # e.g. "172.21" from 172.21.0.0/16

    for sibling in "${env_dir}"/*.env; do
        [ -f "$sibling" ] || continue
        local sib_fixed sib_pool
        sib_fixed=$(grep '^DOCKYARD_FIXED_CIDR=' "$sibling" 2>/dev/null | cut -d= -f2) || true
        sib_pool=$(grep '^DOCKYARD_POOL_BASE=' "$sibling" 2>/dev/null | cut -d= -f2) || true
        [ -n "${sib_fixed}${sib_pool}" ] || continue

        if [ -n "$sib_fixed" ]; then
            local sib_two="${sib_fixed%.*.*}"
            # Our pool must not share a /16 with a sibling's bridge
            if [ "$our_pool_two" = "$sib_two" ]; then
                echo "Error: DOCKYARD_POOL_BASE ${pool_base} would overlap with sibling bridge ${sib_fixed} (from ${sibling})" >&2
                return 1
            fi
        fi
        if [ -n "$sib_pool" ]; then
            local sib_pool_two="${sib_pool%/*}"
            sib_pool_two="${sib_pool_two%.*.*}"
            # Our bridge must not share a /16 with a sibling's pool
            if [ "$our_bridge_two" = "$sib_pool_two" ]; then
                echo "Error: DOCKYARD_FIXED_CIDR ${fixed_cidr} would overlap with sibling pool ${sib_pool} (from ${sibling})" >&2
                return 1
            fi
            # Our pool must not share a /16 with a sibling's pool
            if [ "$our_pool_two" = "$sib_pool_two" ]; then
                echo "Error: DOCKYARD_POOL_BASE ${pool_base} would overlap with sibling pool ${sib_pool} (from ${sibling})" >&2
                return 1
            fi
        fi
    done
    return 0
}
