# Progress

## Current Status: All 27 tests passing

## Architecture: Per-Instance Sysbox (0.6.7.2-tc fork)

Nestybox sysbox 0.6.7 CE has hardcoded socket paths — only one sysbox pair can
run per host. The fork (`github.com/thieso2/sysbox`, version `0.6.7.2-tc`) adds
`--run-dir` to `sysbox-mgr` and `sysbox-fs`, and `SYSBOX_RUN_DIR` env var
support in `sysbox-runc`. Each dockyard instance now runs its own fully isolated
sysbox-mgr and sysbox-fs pair.

See [FINDINGS.md](FINDINGS.md) for the full root-cause analysis.

### Architecture Summary

| Resource | Architecture |
|----------|-------------|
| sysbox-mgr + sysbox-fs | Per-instance in `${DOCKYARD_ROOT}/docker-runtime/bin/` |
| sysbox socket/PID dir | Per-instance `${DOCKYARD_ROOT}/sysbox-run/` |
| sysbox data/mountpoint | Per-instance `${DOCKYARD_ROOT}/sysbox/` |
| sysbox-runc | Wrapper script (sets `SYSBOX_RUN_DIR`) + real binary as `sysbox-runc-bin` |
| systemd service | Per-instance `${PREFIX}docker.service` only (no shared sysbox service) |
| sysbox start/stop | Inline ExecStartPre/ExecStopPost in the docker service |

### Pinned Versions

| Software | Version | Reason |
|----------|---------|--------|
| Docker CE (static) | 29.2.1 | Latest stable |
| docker:26.1-dind | 26.1 | runc 1.1.12 — compatible with sysbox 0.6.7 |
| Sysbox (fork) | 0.6.7.2-tc | Adds --run-dir; allows per-instance sysbox |

`docker:dind` latest (27.x) uses runc 1.3.3 which has a strict procfs check
incompatible with sysbox's bind-mount of `/proc/sys` entries.
See FINDINGS.md for details.

### Per-Instance User and Group

Each dockyard instance gets a dedicated system user and group (`${PREFIX}docker`):

- Ownership: `DOCKYARD_ROOT` chowned to `${INSTANCE_USER}:${INSTANCE_GROUP}`
- Socket access: `dockerd --group ${INSTANCE_GROUP}` → socket is `root:${GROUP} 660`
- Users in the group can use the socket without `sudo`
- Both are removed cleanly on `destroy`

### Source Split (src/ → dist/dockyard.sh)

```
src/00_header.sh     shebang, set -euo pipefail, SCRIPT_DIR
src/01_env.sh        env loading + derive_vars (SYSBOX_RUN_DIR, SYSBOX_DATA_DIR, INSTANCE_USER/GROUP)
src/02_helpers.sh    helper functions
src/03_checks.sh     conflict checks
src/10_gen_env.sh    gen-env command
src/11_create.sh     create command (static tarball install, sysbox-runc wrapper, groupadd/useradd, chown)
src/12_enable.sh     enable command (per-instance docker service with sysbox ExecStartPre/StopPost)
src/13_disable.sh    disable command (service removal only)
src/14_start.sh      start command (inline sysbox start + --group flag)
src/15_stop.sh       stop command (inline sysbox stop)
src/16_status.sh     status command
src/17_destroy.sh    destroy command (sysbox dirs + userdel/groupdel)
src/90_usage.sh      usage text
src/99_dispatch.sh   command dispatch
```

Build: `./build.sh` → `dist/dockyard.sh`

Note: `build.sh` uses `awk 'NR==1 && /^#!/ {next} {print}'` to strip per-file
shebangs — the previous `grep -v '^#!'` would also strip `#!/bin/sh` lines
inside heredocs (the sysbox-runc wrapper heredoc).

### Test Suite (cmd/dockyardtest/main.go)

27 tests across 3 instances (A=dy1_, B=dy2_, C=dy3_). Per-test timing shown in
output; total elapsed printed in summary.

| Phase | Tests | Description |
|-------|-------|-------------|
| Upload and gen-env | 01–04 | Upload script, generate configs |
| Create (concurrent) | 05 | Create all 3 instances in parallel |
| Service health | 06 | Per-instance docker services active (no shared sysbox check) |
| Container run | 07 | Basic `docker run` on each instance |
| Networking | 08–09 | Outbound ping + DNS resolution |
| DinD | 10–12 | Start DinD (no --privileged), inner container, inner networking |
| Isolation | 13 | Daemon-level: A's containers not in B's docker ps |
| Stop/start cycle | 14 | systemctl stop/start instance A; verify containers still run |
| Socket permissions | 15 | Socket mode last octet = 0; group = `${PREFIX}docker` |
| Destroy under load | 16 | Running container present at destroy time; must succeed |
| Double destroy | 17 | Second destroy must exit 0 (idempotent) |
| Cleanup check | 18 | A's service, bridge, and iptables rules all gone |
| Survivor check | 19 | B+C unaffected by A's destruction |
| Reboot | 20 | Full host reboot; B+C come back automatically via systemd |
| Post-reboot health | 21–24 | Services, containers, networking, DinD on B+C |
| Final teardown | 25–26 | Destroy B and C |
| Full cleanup | 27 | No residual services, bridges, iptables, data dirs, users/groups |

Tests 05, 07–13, 19–24 run instance-level checks concurrently using goroutines.
Results are sorted by instance label before printing.

## Completed

- [x] All 27 tests pass on target VM (100.106.185.92)
- [x] Per-test timing output
- [x] Per-instance sysbox via 0.6.7.2-tc fork
- [x] sysbox-runc wrapper script (sets SYSBOX_RUN_DIR)
- [x] build.sh awk fix for heredoc shebangs
- [x] Per-instance user/group (`${PREFIX}docker`)
- [x] Socket group ownership verified in test suite

## Pending

- [ ] Add arm64 support (low priority)
- [ ] Non-Ubuntu OS compatibility (low priority)
