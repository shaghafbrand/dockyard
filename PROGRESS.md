# Progress

## Current Status: Testing in progress

## Architecture Changes Implemented

### Shared Sysbox Daemon (branch: fix/pin-inner-docker-sysbox-compat)

Resolved the core architectural blocker: sysbox 0.6.7 CE has hardcoded socket
paths (`/run/sysbox/sysfs.sock`, `/run/sysbox/sysmgr.sock`). Multiple dockyard
instances cannot each run their own sysbox daemon.

**Solution**: single `dockyard-sysbox.service` per host, shared by all instances.

| Resource | Old (per-instance) | New (shared) |
|----------|-------------------|--------------|
| sysbox-mgr/fs binaries | `${BIN_DIR}/` | `/usr/local/lib/dockyard/` |
| sysbox data | `${DOCKYARD_ROOT}/sysbox/` | `/var/lib/dockyard-sysbox/` |
| sysbox logs | `${LOG_DIR}/` | `/var/log/dockyard-sysbox/` |
| PID files | `${RUN_DIR}/sysbox-*.pid` | `/run/sysbox/sysbox-*.pid` |
| systemd service | `${PREFIX}sysbox.service` | `dockyard-sysbox.service` |
| sysbox-runc | `${BIN_DIR}/sysbox-runc` | still per-instance (containerd) |

**Ref-counting (non-systemd mode)**: `sysbox_acquire()` / `sysbox_release()` using
`flock` on `/run/sysbox/dockyard-refcount.lock`. First acquire starts sysbox;
last release stops it.

**Systemd mode**: handled automatically — each `${PREFIX}docker.service` has
`Requires=dockyard-sysbox.service`. Systemd starts it with the first docker service
and stops it after the last.

**Last-instance cleanup**: `cmd_disable` only stops/removes `dockyard-sysbox.service`
when no `*_docker.service` files remain. `cmd_destroy` then removes shared dirs.

### Source Split (src/ → dist/dockyard.sh)

```
src/00_header.sh     shebang, set -euo pipefail, SCRIPT_DIR
src/01_env.sh        env loading + derive_vars (+ shared sysbox vars)
src/02_helpers.sh    helper functions (+ sysbox_acquire/sysbox_release)
src/03_checks.sh     conflict checks
src/10_gen_env.sh    gen-env command
src/11_create.sh     create command
src/12_enable.sh     enable command (systemd service install)
src/13_disable.sh    disable command (service removal, last-instance check)
src/14_start.sh      start command (ref-counted sysbox start)
src/15_stop.sh       stop command (ref-counted sysbox stop)
src/16_status.sh     status command
src/17_destroy.sh    destroy command
src/90_usage.sh      usage text
src/99_dispatch.sh   command dispatch
```

Build: `./build.sh` → `dist/dockyard.sh` (1375 lines, syntax-clean)

### Bug Fixes Applied

1. `--iptables=false` — prevent multi-instance iptables conflicts
2. Explicit iptables FORWARD + NAT rules per instance (bridge + pool)
3. IP forwarding via `sysctl net.ipv4.ip_forward=1`
4. DinD ownership watcher (fixes Docker 29+ sysbox uid mapping)
5. DinD watcher in systemd `ExecStartPost`, kills on `ExecStopPost`
6. `destroy --yes/-y` flag for non-interactive uninstall
7. `gen-env` auto-runs on `create` if no config found

### Test Suite (cmd/dockyardtest/main.go)

24 tests across 3 instances (A=dy1_, B=dy2_, C=dy3_):

| Phase | Tests | Description |
|-------|-------|-------------|
| Upload & gen-env | 01-04 | Upload script, generate configs |
| Create (concurrent) | 05 | Create all 3 instances in parallel |
| Service health | 06 | dockyard-sysbox + per-instance docker active |
| Container run | 07 | Basic `docker run` on each instance |
| Networking | 08-09 | Outbound ping + DNS resolution |
| DinD | 10-12 | Start DinD, inner container, inner networking |
| Isolation | 13 | Daemon-level: A's containers not in B's docker ps |
| Partial destroy | 14-16 | Destroy A, verify cleanup, B+C still healthy |
| Reboot | 17-21 | Full reboot, B+C come back, DinD works |
| Full destroy | 22-24 | Destroy B+C, verify complete cleanup |

### Pinned Versions

| Software | Version | Reason |
|----------|---------|--------|
| Docker CE (static) | 29.2.1 | Latest stable |
| docker:26.1-dind | 26.1 | runc 1.1.12 — compatible with sysbox 0.6.7 |
| Sysbox CE | 0.6.7 | Last CE release |

`docker:dind` latest (27.x) uses runc 1.3.3 which has strict procfs check
incompatible with sysbox's bind-mount of `/proc/sys` entries.
See FINDINGS.md for details.

## Pending

- [ ] Run `./dockyardtest --host 100.106.185.92 --user thies` until all 24 tests pass
- [ ] Add arm64 support (low priority)
- [ ] Non-Ubuntu OS compatibility (low priority)
