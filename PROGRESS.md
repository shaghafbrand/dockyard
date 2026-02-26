# Progress

## Current Status: All 29 tests passing

## Architecture: Per-Instance Sysbox (0.6.7.9-tc fork)

Nestybox sysbox 0.6.7 CE has hardcoded socket paths — only one sysbox pair can
run per host. The fork (`github.com/thieso2/sysbox`, version `0.6.7.9-tc`) adds
`--run-dir` to `sysbox-mgr`, `sysbox-fs`, and `sysbox-runc`. Each dockyard instance
now runs its own fully isolated sysbox-mgr and sysbox-fs pair, and `--run-dir` is
passed via `runtimeArgs` in `daemon.json` with no wrapper script needed.

The `--run-dir` CLI flag was broken (0.6.7.4-tc through 0.6.7.8-tc) because urfave/cli v1's
`context.GlobalString` in `app.Before` returned the flag default instead of the CLI value.
Fixed in 0.6.7.9-tc by parsing `os.Args` directly in `init()`, bypassing urfave/cli entirely.
See FINDINGS.md and https://github.com/thieso2/sysbox/issues/5.

See [FINDINGS.md](FINDINGS.md) for the full root-cause analysis.

### Architecture Summary

| Resource | Architecture |
|----------|-------------|
| sysbox-mgr + sysbox-fs | Per-instance in `${DOCKYARD_ROOT}/bin/` |
| sysbox socket/PID dir | Per-instance `${DOCKYARD_ROOT}/run/sysbox/` |
| sysbox data/mountpoint | Per-instance `${DOCKYARD_ROOT}/lib/sysbox/` |
| sysbox-runc | Per-instance in `${BIN_DIR}/`; `--run-dir` passed via `runtimeArgs` |
| systemd service | Per-instance `${PREFIX}docker.service` only (no shared sysbox service) |
| sysbox start/stop | Inline ExecStartPre/ExecStopPost in the docker service |

### Pinned Versions

| Software | Version | Reason |
|----------|---------|--------|
| Docker CE (static) | 29.2.1 | Latest stable |
| docker:26.1-dind | 26.1 | runc 1.1.12 — compatible with sysbox 0.6.7 |
| Sysbox (fork) | 0.6.7.9-tc | --run-dir works via runtimeArgs; no wrapper needed |

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
src/11_create.sh     create command (static tarball install, runtimeArgs, groupadd/useradd, chown)
src/12_enable.sh     enable command (per-instance docker service with sysbox ExecStartPre/StopPost)
src/13_disable.sh    disable command (service removal only)
src/14_start.sh      start command (inline sysbox start + --group flag)
src/15_stop.sh       stop command (inline sysbox stop)
src/16_status.sh     status command
src/17_destroy.sh    destroy command (sysbox dirs + userdel/groupdel)
src/18_verify.sh     verify command (smoke-test: service, socket, API, container, ping, DinD)
src/90_usage.sh      usage text
src/99_dispatch.sh   command dispatch
```

Build: `./build.sh` → `dist/dockyard.sh`

Note: `build.sh` uses `awk 'NR==1 && /^#!/ {next} {print}'` to strip per-file
shebangs — the previous `grep -v '^#!'` would also strip `#!/bin/sh` lines
inside heredocs.

### Test Suite (cmd/dockyardtest/main.go)

29 tests across 3 instances (A=dy1_, B=dy2_, C=dy3_) plus 1 nested-root test. Per-test timing shown in
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
| Verify | 14 | `dockyard.sh verify` on all instances — 6/6 checks pass |
| Edge cases | 15–16 | Stop/start cycle; socket permissions |
| Destroy A | 17–19 | Under load, double destroy, cleanup check |
| Survivor check | 20 | B+C unaffected by A's destruction |
| Reboot | 21 | Full host reboot; B+C come back automatically via systemd |
| Post-reboot health | 22–25 | Services, containers, networking, DinD on B+C |
| Final teardown | 26–27 | Destroy B and C |
| Full cleanup | 28 | No residual services, bridges, iptables, data dirs, users/groups |
| Nested root | 29 | DOCKYARD_ROOT at a deeply nested path — full lifecycle |

Tests 05, 07–14, 20–25 run instance-level checks concurrently using goroutines.
Results are sorted by instance label before printing.

## Completed

- [x] All 29 tests pass on target VM (100.106.185.92)
- [x] 29/29 tests pass on mainline kernel 6.18.0-061800-generic (Ubuntu 25.04, incus VM on sandman)
- [x] verify subcommand (6-check post-install smoke test: service, socket, API, container, ping, DinD)
- [x] Per-test timing output
- [x] Per-instance sysbox via 0.6.7.9-tc fork
- [x] sysbox-runc --run-dir via runtimeArgs (no wrapper script)
- [x] build.sh awk fix for heredoc shebangs
- [x] Per-instance user/group (`${PREFIX}docker`)
- [x] Socket group ownership verified in test suite
- [x] FHS-aligned directory layout (bin/, etc/, lib/, log/, run/ under DOCKYARD_ROOT)
- [x] Nested DOCKYARD_ROOT path test (test 29)

## Pending

- [ ] Add arm64 support (low priority)
- [ ] Non-Ubuntu OS compatibility (low priority)
