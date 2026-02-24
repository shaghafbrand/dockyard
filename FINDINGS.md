# Findings

## Sysbox 0.6.7 CE: No configurable socket paths

**Date**: 2026-02-23
**Severity**: Architectural blocker for naive per-instance sysbox
**Status**: RESOLVED — forked sysbox (0.6.7.4-tc)

`sysbox-fs` and `sysbox-mgr` have NO flag to change their socket paths:
- `/run/sysbox/sysfs.sock` — hardcoded in sysbox-fs
- `/run/sysbox/sysmgr.sock` — hardcoded in sysbox-mgr

`sysbox-runc` has `--no-sysbox-fs` / `--no-sysbox-mgr` for debug only; no custom socket path flags.

**Confirmed via**: `sysbox-fs --help` and `sysbox-mgr --help` on target VM (Ubuntu 24.04.1).

### Consequence

Multiple dockyard instances **cannot** each run their own isolated sysbox daemon — the second instance's sysbox-fs will fail to bind the already-held socket. Under `Restart=on-failure` the service keeps restarting, appearing "active" while actually broken.

When the **first** instance (which successfully bound the socket) is destroyed, the socket disappears and all other instances immediately lose sysbox → DinD breaks.

### Intermediate solution (superseded): Shared sysbox daemon with ref-counting

An intermediate architecture used a single shared `dockyard-sysbox.service` per host (`Requires=` from each docker service). This was workable but meant all instances shared one sysbox process — no true per-instance isolation of the runtime daemon.

### Final solution: Fork sysbox to add `--run-dir`

The fork (`github.com/thieso2/sysbox`, version `0.6.7.4-tc`) adds:
- `--run-dir <dir>` flag to `sysbox-mgr` and `sysbox-fs` — configures the socket/pid directory
- `SYSBOX_RUN_DIR` environment variable support in `sysbox-runc`

Each dockyard instance now starts its own sysbox-mgr and sysbox-fs with a unique `--run-dir` pointing to `${DOCKYARD_ROOT}/sysbox-run/`. There is no shared sysbox service.

---

## sysbox-runc has no --run-dir flag; reads SYSBOX_RUN_DIR env var instead

**Date**: 2026-02-24
**Severity**: Integration blocker for per-instance sysbox-runc

`sysbox-runc` does not accept `--run-dir` as a CLI flag. Passing it via `runtimeArgs` in daemon.json causes exit status 1 at container start time.

**Root cause**: sysbox-runc reads its socket paths from the environment variable `SYSBOX_RUN_DIR`, not from a CLI argument. The variable is consumed in `libsysbox/sysbox/sysbox.go` `init()`, which calls `SetSockAddr()` on both the sysbox-mgr and sysbox-fs gRPC clients.

**Fix**: Install the real sysbox-runc binary as `sysbox-runc-bin`. Install a thin wrapper script at `sysbox-runc` that sets `SYSBOX_RUN_DIR` before exec-ing the real binary:

```sh
#!/bin/sh
export SYSBOX_RUN_DIR="/dy1/sysbox-run"
exec "/dy1/docker-runtime/bin/sysbox-runc-bin" "$@"
```

daemon.json's `runtimes` block points to the wrapper with no `runtimeArgs`.

---

## build.sh grep -v '#!' stripped heredoc shebangs

**Date**: 2026-02-24
**Severity**: Build correctness bug — wrapper script shebangs silently removed

`build.sh` used `grep -v '^#!'` to strip the per-file shebang line before concatenating source files. This also stripped any `#!/bin/sh` line that appeared inside a heredoc in a source file (specifically the sysbox-runc wrapper script heredoc in `src/11_create.sh`).

**Symptom**: The installed `sysbox-runc` wrapper lacked its `#!/bin/sh` shebang and failed to execute.

**Fix**: Replace `grep -v '^#!'` with `awk 'NR==1 && /^#!/ {next} {print}'`, which skips only the first line of each source file when it is a shebang, leaving all subsequent lines intact regardless of their content.

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

## sysbox-runc --run-dir CLI flag: seccomp socket not redirected (0.6.7.4-tc)

**Date**: 2026-02-24
**Severity**: Containers fail to start when `--run-dir` is used via `runtimeArgs`
**Status**: Open — tracked in https://github.com/thieso2/sysbox/issues/4

### Symptom

When `daemon.json` passes `--run-dir` via `runtimeArgs`, containers fail with:

```
container_linux.go:2573: sending seccomp fd to sysbox-fs caused:
Unable to establish connection with seccomp-tracer:
dial unix /run/sysbox/sysfs-seccomp.sock: connect: no such file or directory
```

### Root cause: init() vs app.Before() timing

`sysbox-runc` processes `--run-dir` in `app.Before`, which fires after all `init()` functions have run. The `sysfs-seccomp.sock` path is computed at init time from the default `runDir = "/run/sysbox"` and is not updated when `SetRunDir` is later called from `app.Before`.

`SYSBOX_RUN_DIR` env var works correctly because `sysbox.go`'s `init()` calls `SetRunDir()` before any socket path is fixed — so all three sockets (sysmgr, sysfs, sysfs-seccomp) pick up the correct directory.

### Workaround

Install sysbox-runc as a wrapper script that exports `SYSBOX_RUN_DIR` before exec'ing the real binary. The env var path correctly redirects all sockets including the seccomp tracer.

### Fix needed

`SetRunDir()` (or the seccomp socket path construction) must also update `sysfs-seccomp.sock` to use the provided dir, not the initial `/run/sysbox` default.

---

## Test cleanup check false negative

**Date**: 2026-02-23

The cleanup test checked `ip link show dy2_docker0` and parsed the output for "does not exist" string. When the bridge is gone, the command exits non-zero AND prints "Device ... does not exist." — the logic was correct, but the bridge may have been left by the pool cleanup bug. Resolved by fixing the underlying destroy and using exit-code-based checks.
