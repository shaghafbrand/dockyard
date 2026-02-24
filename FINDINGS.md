# Findings

## Sysbox 0.6.7 CE: No configurable socket paths

**Date**: 2026-02-23
**Severity**: Architectural blocker for naive per-instance sysbox

`sysbox-fs` and `sysbox-mgr` have NO flag to change their socket paths:
- `/run/sysbox/sysfs.sock` — hardcoded in sysbox-fs
- `/run/sysbox/sysmgr.sock` — hardcoded in sysbox-mgr

`sysbox-runc` has `--no-sysbox-fs` / `--no-sysbox-mgr` for debug only; no custom socket path flags.

**Confirmed via**: `sysbox-fs --help` and `sysbox-mgr --help` on target VM (Ubuntu 24.04.1).

### Consequence

Multiple dockyard instances **cannot** each run their own isolated sysbox daemon — the second instance's sysbox-fs will fail to bind the already-held socket. Under `Restart=on-failure` the service keeps restarting, appearing "active" while actually broken.

When the **first** instance (which successfully bound the socket) is destroyed, the socket disappears and all other instances immediately lose sysbox → DinD breaks.

### Solution: Shared sysbox daemon with ref-counting

Sysbox must be treated as a **host-level shared daemon** (like the Linux kernel itself). All dockyard instances use the same `/run/sysbox/sysfs.sock`. Container-level isolation (UID namespaces, proc emulation) is still fully per-container — sysbox was designed for multi-tenant use.

**Architecture**:
- `dockyard-sysbox.service` — one per host, not per instance
- Shared binary: `/usr/local/lib/dockyard/sysbox-{fs,mgr}` (copied on first create; sysbox-runc stays per-instance in `${BIN_DIR}/`)
- Shared data: `/var/lib/dockyard-sysbox/`
- Ref-count file: `/run/sysbox/dockyard-refcount` (direct/non-systemd mode)
- First dockyard instance starts sysbox; last one stops it
- Per-instance `${PREFIX}docker.service` `Requires=dockyard-sysbox.service`

---

## docker:dind latest (27.x) incompatible with sysbox 0.6.7

**Date**: 2026-02-23
**Severity**: DinD test failures (tests 10, 11, 12)

Error:
```
runc create failed: unable to start container process: error during container init:
open sysctl net.ipv4.ip_unprivileged_port_start file: unsafe procfs detected:
openat2 /proc/./sys/net/ipv4/ip_unprivileged_port_start: invalid cross-device link
```

**Root cause**: runc 1.3.x (used by Docker 27.x) added a strict "safe procfs" check that detects sysbox-fs's bind-mount of `/proc/sys` entries (which creates cross-device links). This was tracked in `opencontainers/runc#4968` and `nestybox/sysbox#973`.

**Affected**: inner containers launched by the `docker:dind` container's inner dockerd.

**Fix**: Pin `docker:dind` image to `docker:26.1-dind` (uses runc 1.1.12, before the 1.3.x series). runc 1.1.x does NOT have the cross-device link check.

| docker:dind tag | runc version | sysbox compat |
|----------------|-------------|---------------|
| `docker:dind` (latest = 27.x) | 1.3.3 | ❌ broken |
| `docker:26.1-dind` | 1.1.12 | ✅ works |
| `docker:25.0-dind` | 1.1.12 | ✅ works |

---

## Multi-instance bridge isolation: not implemented by default

**Date**: 2026-02-23
**Severity**: Test expectation mismatch (test was wrong, not a bug)

Containers in instance A can reach instance B's bridge IP. This is expected Linux behaviour — the kernel routes between all bridge interfaces on the same host. No `FORWARD DROP` rules exist between dockyard bridges.

**Verdict**: Not a bug. Dockyard's isolation is at the **daemon/socket/data** level, not at the network level. The isolation test was incorrectly expecting network-level isolation. Replaced with daemon-level isolation test (containers from A not visible in B's `docker ps`).

---

## Test cleanup check false negative

**Date**: 2026-02-23

The cleanup test checked `ip link show dy2_docker0` and parsed the output for "does not exist" string. When the bridge is gone, the command exits non-zero AND prints "Device ... does not exist." — the logic was correct, but the bridge may have been left by the pool cleanup bug. Resolved by fixing the underlying destroy and using exit-code-based checks.
