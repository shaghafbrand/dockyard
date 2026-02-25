# Findings

## Sysbox 0.6.7 CE: No configurable socket paths

**Date**: 2026-02-23
**Severity**: Architectural blocker for naive per-instance sysbox
**Status**: RESOLVED — forked sysbox (0.6.7.9-tc)

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

The fork (`github.com/thieso2/sysbox`, version `0.6.7.9-tc`) adds `--run-dir <dir>` to all three sysbox binaries — `sysbox-mgr`, `sysbox-fs`, and `sysbox-runc`. Each dockyard instance now starts its own sysbox-mgr and sysbox-fs with a unique `--run-dir` pointing to `${DOCKYARD_ROOT}/run/sysbox/`. There is no shared sysbox service. `--run-dir` is passed via `runtimeArgs` in `daemon.json`; no wrapper script is needed.

---

## sysbox-runc has no --run-dir flag; reads SYSBOX_RUN_DIR env var instead

**Date**: 2026-02-24
**Severity**: Integration blocker for per-instance sysbox-runc

`sysbox-runc` does not accept `--run-dir` as a CLI flag. Passing it via `runtimeArgs` in daemon.json causes exit status 1 at container start time.

**Root cause**: sysbox-runc reads its socket paths from the environment variable `SYSBOX_RUN_DIR`, not from a CLI argument. The variable is consumed in `libsysbox/sysbox/sysbox.go` `init()`, which calls `SetSockAddr()` on both the sysbox-mgr and sysbox-fs gRPC clients.

**Fix**: Install the real sysbox-runc binary as `sysbox-runc-bin`. Install a thin wrapper script at `sysbox-runc` that sets `SYSBOX_RUN_DIR` before exec-ing the real binary:

```sh
#!/bin/sh
export SYSBOX_RUN_DIR="/dy1/run/sysbox"
exec "/dy1/bin/sysbox-runc-bin" "$@"
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

## sysbox-runc --run-dir CLI flag: seccomp socket not redirected (0.6.7.4–0.6.7.8-tc)

**Date**: 2026-02-24 (confirmed still broken through 0.6.7.8-tc; fixed in 0.6.7.9-tc: 2026-02-25)
**Severity**: Containers fail to start when `--run-dir` is used via `runtimeArgs`
**Status**: RESOLVED in 0.6.7.9-tc — tracked in https://github.com/thieso2/sysbox/issues/5

### Symptom

When `daemon.json` passes `--run-dir` via `runtimeArgs`, containers fail with:

```
container_linux.go:2573: sending seccomp fd to sysbox-fs caused:
Unable to establish connection with seccomp-tracer:
dial unix /run/sysbox/sysfs-seccomp.sock: connect: no such file or directory
```

This error occurs even though `sysfs-seccomp.sock` **is** correctly created at the
per-instance run-dir (e.g. `/dy1/run/sysbox/sysfs-seccomp.sock`). sysbox-runc ignores
the relocated socket and still dials the hardcoded `/run/sysbox/sysfs-seccomp.sock`.

Confirmed present in 0.6.7.4-tc through 0.6.7.7-tc. The `SYSBOX_RUN_DIR` env var path
(read directly in `init()`) works correctly in all versions.

### Confirmed call path via strace + binary wrapper

Instrumented with a debug wrapper at the sysbox-runc binary path. Confirmed:

1. containerd calls `sysbox-runc` directly (not via Docker-generated shim) with:
   `--run-dir /dy1/run/sysbox ... create --bundle ...`
2. `SYSBOX_RUN_DIR` is **not set** in containerd's environment
3. `sysbox.go init()` runs → reads unset `SYSBOX_RUN_DIR` → `runDir = "/run/sysbox"`
4. `app.Before()` calls `sysbox.SetRunDir(context.GlobalString("run-dir"))`
5. Despite `--run-dir /dy1/run/sysbox` in argv, `context.GlobalString("run-dir")` returns
   the default `/run/sysbox` — urfave/cli v1 bug with global flags before subcommands
6. `SetRunDir("/run/sysbox")` is a no-op (same as default)
7. `SendSeccompInit` dials `/run/sysbox/sysfs-seccomp.sock` → fails

Adding `export SYSBOX_RUN_DIR=/dy1/run/sysbox` to the wrapper env makes it work instantly —
confirming the env var path through `init()` is the only reliable mechanism.

### Root cause: urfave/cli v1 GlobalString in app.Before

`context.GlobalString("run-dir")` in `app.Before` does not return the CLI-provided value
`/dy1/run/sysbox`. It returns the flag default `/run/sysbox`. This is a known urfave/cli v1
quirk where global flags passed before a subcommand may not be visible to `app.Before`'s
root context via `GlobalString`.

The 0.6.7.7-tc fix (`os.Setenv("SYSBOX_RUN_DIR", dir)` in `SetRunDir`) does not help
because `SetRunDir` is called with the wrong value (the default).

`SYSBOX_RUN_DIR` env var works correctly because `sysbox.go`'s `init()` reads it before
`app.Before` runs — so `runDir` is set to the correct per-instance path from the start.

### Workaround (used in dockyard 0.6.7.4-tc through 0.6.7.8-tc)

Wrapper script that exports `SYSBOX_RUN_DIR` before exec'ing the real binary:

```sh
#!/bin/sh
export SYSBOX_RUN_DIR="/dy1/run/sysbox"
exec "/dy1/bin/sysbox-runc-bin" "$@"
```

daemon.json pointed to the wrapper with no `runtimeArgs`. No longer needed in 0.6.7.9-tc.

### Fix (0.6.7.9-tc)

Extended `init()` in `sysbox.go` to scan `os.Args` directly for `--run-dir` before urfave/cli
runs. This bypasses `context.GlobalString` entirely and makes `runtimeArgs` work correctly.
The wrapper script and `sysbox-runc-bin` alias are no longer needed.

See: https://github.com/thieso2/sysbox/issues/5

---

## sysbox 0.6.7 incompatible with Linux kernel 6.17 (Ubuntu 25.10+)

**Date**: 2026-02-25
**Severity**: Hard blocker — containers fail to start; no workaround without patching sysbox-runc
**Status**: OPEN — sysbox 0.6.7.x not fixed; Ubuntu 24.04 LTS (kernel 6.8) confirmed working

### Symptom

`docker run` exits immediately with:

```
docker: Error response from daemon: failed to create task for container:
failed to create shim task: OCI runtime create failed:
runc create failed: ... EOF
```

The error appears generic. The OCI runtime log is deleted by containerd before it can be read directly.

### Diagnosis

Install a debug wrapper at the sysbox-runc binary path that copies `--log` output before exec:

```sh
#!/bin/sh
LOGFILE="/tmp/sysbox-runc-$$.json"
exec /path/to/sysbox-runc-real --log "$LOGFILE" "$@"
```

The captured `log.json` shows the fatal entry:

```
nsexec:1050 nsenter: failed to set rootfs parent mount propagation to private: Permission denied
```

### Root cause

`nsexec.c` in sysbox-runc (the C preamble that runs before the Go runtime) calls:

```c
mount("", "/", "", MS_PRIVATE | MS_REC, "")
```

This attempts to change the root mount's propagation to private from within a new user+mount namespace. On **kernel 6.17** (Ubuntu 25.10+), inherited mounts owned by the parent user namespace cannot have their propagation changed from a child user namespace — the kernel returns `EPERM`.

This restriction was tightened in the upstream kernel. Mainline `runc` ≥ 1.2 handles it gracefully; sysbox-runc 0.6.7.x does not.

**Confirmed not fixable by**:
- `--privileged` — nsexec runs before privilege escalation is meaningful here
- `--security-opt seccomp=unconfined` — not a seccomp issue
- AppArmor changes — not an AppArmor issue
- `SYSBOX_RUN_DIR` / `--run-dir` flags — unrelated to namespace setup

### Affected environments

| Distro | Kernel | Status |
|--------|--------|--------|
| Ubuntu 25.10 | 6.17 | ❌ broken |
| Ubuntu 25.04 | 6.14 | ✅ confirmed working |
| Ubuntu 24.04 LTS | 6.8 | ✅ confirmed working |
| Ubuntu 22.04 LTS | 5.15 | ✅ expected working |

### Fix

Requires patching `nsexec.c` in sysbox-runc to handle `EPERM` on the `mount --make-private` call gracefully (or skip it when running in a user namespace where the mount is owned by the parent). No patch is available in 0.6.7.x as of 2026-02-25.

---

## Test cleanup check false negative

**Date**: 2026-02-23

The cleanup test checked `ip link show dy2_docker0` and parsed the output for "does not exist" string. When the bridge is gone, the command exits non-zero AND prints "Device ... does not exist." — the logic was correct, but the bridge may have been left by the pool cleanup bug. Resolved by fixing the underlying destroy and using exit-code-based checks.
