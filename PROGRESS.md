# Progress

## Current Status: All 29 tests passing

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full design rationale and [FINDINGS.md](FINDINGS.md) for root-cause analysis of resolved issues.

## Source Split (src/ → dist/dockyard.sh)

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

## Test Suite (cmd/dockyardtest/main.go)

29 tests across 3 instances (A=dy1_, B=dy2_, C=dy3_) plus 1 nested-root test. Per-test timing shown in output; total elapsed printed in summary.

| Phase | Tests | Description |
|-------|-------|-------------|
| Upload and gen-env | 01–04 | Upload script, generate configs |
| Create (concurrent) | 05 | Create all 3 instances in parallel |
| Service health | 06 | Per-instance docker services active |
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

### Confirmed kernels

| Kernel | Status |
|--------|--------|
| Ubuntu 24.04 LTS `6.8.0-101-generic` (reference VM 100.106.185.92) | ✅ 29/29 |
| mainline `6.18.0-061800-generic` (Ubuntu 25.04, incus VM on sandman) | ✅ 29/29 |
| Ubuntu 25.10 `6.17.0-14-generic` | ❌ kernel-specific EPERM in user namespaces |

## Completed

- [x] All 29 tests pass on target VM (100.106.185.92)
- [x] 29/29 tests pass on mainline kernel 6.18.0-061800-generic
- [x] verify subcommand (6-check post-install smoke test: service, socket, API, container, ping, DinD)
- [x] Per-instance sysbox via 0.6.7.9-tc fork (--run-dir via runtimeArgs, no wrapper)
- [x] Per-instance user/group (`${PREFIX}docker`) with socket group ownership
- [x] FHS-aligned directory layout (bin/, etc/, lib/, log/, run/ under DOCKYARD_ROOT)
- [x] Explicit iptables management (no --iptables=true, rules scoped to bridge name)
- [x] Self-contained systemd services (all paths hardcoded at create time)
- [x] build.sh awk fix for heredoc shebangs
- [x] Nested DOCKYARD_ROOT path test (test 29)

## Pending

- [ ] Add arm64 support (low priority)
- [ ] Non-Ubuntu OS compatibility (low priority)
