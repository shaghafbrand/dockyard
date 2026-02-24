# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Dockyard: multi-instance Docker daemon installer with sysbox-runc as default runtime. Runs isolated Docker instances side-by-side with the system Docker on the same host. Each instance gets its own bridge network, containerd, socket, and data directory.

## Key Commands

```bash
# Generate a config with randomized networks
./dockyard.sh gen-env
DOCKYARD_DOCKER_PREFIX=test_ DOCKYARD_ROOT=/test ./dockyard.sh gen-env

# Create instance (requires dockyard.env)
sudo ./dockyard.sh create
sudo ./dockyard.sh create --no-systemd --no-start

# Create with explicit env file
DOCKYARD_ENV=./custom.env sudo -E ./dockyard.sh create

# Post-create (reads ./dockyard.env or $DOCKYARD_ENV)
sudo ./dockyard.sh start
sudo ./dockyard.sh stop
./dockyard.sh status
sudo ./dockyard.sh destroy
```

Using a custom instance:
```bash
DOCKER_HOST=unix:///dockyard/docker.sock docker ps
```

## Architecture

### Single Script, Subcommand Interface

Everything lives in `dockyard.sh` with subcommands: `gen-env`, `create`, `enable`, `disable`, `start`, `stop`, `status`, `destroy`. The script is fully self-contained: embedded daemon.json, no external file dependencies.

### Environment Loading

All commands except `gen-env` require a config file (mandatory, no silent fallback):

1. If `DOCKYARD_ENV` is set → source that file (error if missing)
2. Else if `./dockyard.env` exists in current directory → source it
3. Else if `../etc/dockyard.env` exists relative to the script → source it (installed copy at `$BIN_DIR/dockyard.sh` finds `$ETC_DIR/dockyard.env`)
4. Else if `$DOCKYARD_ROOT/docker-runtime/etc/dockyard.env` exists → source it
5. Otherwise → error: `"No config found. Run './dockyard.sh gen-env' or set DOCKYARD_ENV."`

The `gen-env` command creates the config file. It does not go through `load_env()`.

### Environment Variables

Each env file defines 6 variables that fully configure an instance:

| Variable | Purpose | Must be unique per instance |
|----------|---------|----------------------------|
| `DOCKYARD_ROOT` | Base directory for data/runtime/socket | Yes |
| `DOCKYARD_DOCKER_PREFIX` | Prefix for bridge, service name, exec-root | Yes |
| `DOCKYARD_BRIDGE_CIDR` | Bridge IP/mask (e.g. `172.22.147.1/24`) | Yes |
| `DOCKYARD_FIXED_CIDR` | Container subnet (e.g. `172.22.147.0/24`) | Yes |
| `DOCKYARD_POOL_BASE` | Address pool for user networks | Yes |
| `DOCKYARD_POOL_SIZE` | Pool subnet size in CIDR bits | No |

Everything else is derived: `RUNTIME_DIR`, `BRIDGE`, `EXEC_ROOT`, `SERVICE_NAME`, `DOCKER_SOCKET`, `CONTAINERD_SOCKET`, `INSTANCE_USER`, `INSTANCE_GROUP`, `SYSBOX_RUN_DIR`, `SYSBOX_DATA_DIR`.

### gen-env: Config Generation

`gen-env` generates a `dockyard.env` file with conflict-free randomized networks:

- Picks random /24 from `172.16.0.0/12` for bridge CIDR
- Picks random /16 from `172.16.0.0/12` (different second octet) for pool base
- Validates against `ip route`, retries up to 10 times on collision
- Checks prefix conflicts (bridge, exec-root, systemd service)
- Checks root dir conflicts (existing installation)
- All checks skippable with `--nocheck`
- All 6 variables overridable via environment

### Collision Checks (Shared Helpers)

Three reusable helpers used by both `gen-env` and `create`:

- `check_prefix_conflict()` — bridge exists, exec-root dir exists, docker systemd service exists
- `check_root_conflict()` — `docker-runtime/bin/` already present
- `check_subnet_conflict()` — `ip route` overlap for fixed CIDR and pool base

### Downloaded Software

Defined in `cmd_create()`, cached in `.tmp/`:

| Software | Version | Source |
|----------|---------|--------|
| Docker CE (static) | 29.2.1 | download.docker.com |
| Docker Rootless Extras | 29.2.1 | download.docker.com |
| Sysbox (fork, static tarball) | 0.6.7.2-tc | github.com/thieso2/sysbox |

`dpkg-deb` is no longer needed. The fork ships as a static tarball containing all three binaries (`sysbox-mgr`, `sysbox-fs`, `sysbox-runc-bin`).

### Per-Instance Sysbox Daemon (0.6.7.2-tc fork)

Nestybox sysbox 0.6.7 CE hardcodes its socket paths (`/run/sysbox/sysmgr.sock`, `/run/sysbox/sysfs.sock`) with no flag to override them. The fork (`github.com/thieso2/sysbox`, version `0.6.7.2-tc`) adds:

1. `--run-dir <dir>` flag to `sysbox-mgr` and `sysbox-fs` — sets the directory for sockets and PID files
2. `SYSBOX_RUN_DIR` environment variable support in `sysbox-runc` — read at startup in `libsysbox/sysbox/sysbox.go` `init()`, calls `SetSockAddr()` on both gRPC clients

Result: each dockyard instance runs its own fully isolated sysbox-mgr and sysbox-fs pair.

**Derived variables** (set in `derive_vars()`):
- `SYSBOX_RUN_DIR="${DOCKYARD_ROOT}/sysbox-run"` — sockets + PID files
- `SYSBOX_DATA_DIR="${DOCKYARD_ROOT}/sysbox"` — sysbox-mgr data-root and sysbox-fs mountpoint

**sysbox-runc wrapper script.** sysbox-runc does not accept `--run-dir` as a CLI flag, and passing it via `runtimeArgs` in daemon.json causes exit status 1. Instead, sysbox-runc reads `SYSBOX_RUN_DIR` from its environment. Solution: install the real binary as `sysbox-runc-bin` and install a thin wrapper at `sysbox-runc`:

```sh
#!/bin/sh
export SYSBOX_RUN_DIR="/dy1/sysbox-run"
exec "/dy1/docker-runtime/bin/sysbox-runc-bin" "$@"
```

daemon.json points to the wrapper with no `runtimeArgs`.

**Startup Sequence**:
```
${PREFIX}docker.service starts (per instance)
  ExecStartPre: sysbox-mgr starts with --run-dir ${SYSBOX_RUN_DIR} --data-root ${SYSBOX_DATA_DIR}
  ExecStartPre: wait for ${SYSBOX_RUN_DIR}/sysmgr.sock
  ExecStartPre: sysbox-fs starts with --run-dir ${SYSBOX_RUN_DIR} --mountpoint ${SYSBOX_DATA_DIR}
  ExecStartPre: wait for ${SYSBOX_RUN_DIR}/sysfs.sock
  ExecStartPre: iptables rules inserted
  ExecStart: containerd
  ExecStart: dockerd (with --group ${INSTANCE_GROUP})
  ExecStopPost: iptables rules removed
  ExecStopPost: kill sysbox-fs
  ExecStopPost: kill sysbox-mgr
  ExecStopPost: rm -rf ${SYSBOX_RUN_DIR}
```

There is no shared sysbox service. No ref-counting. No `dockyard-sysbox.service`.

### Per-Instance User and Group

Each dockyard instance creates a dedicated system user and group at `create` time:

- User/group name: `${DOCKYARD_DOCKER_PREFIX}docker` (e.g. `dy1_docker`)
- Derived vars: `INSTANCE_USER="${DOCKYARD_DOCKER_PREFIX}docker"`, `INSTANCE_GROUP="${DOCKYARD_DOCKER_PREFIX}docker"`
- Ownership: `DOCKYARD_ROOT` is `chown -R ${INSTANCE_USER}:${INSTANCE_GROUP}` after install
- Socket access: `dockerd --group ${INSTANCE_GROUP}` makes the socket `root:${GROUP} 660`
- Users in the group can access the socket without `sudo`
- Both user and group are removed by `destroy`

### Self-Contained Systemd Services

The service file template expands all variables at create time. The generated `.service` file has no external dependencies on this repo's scripts. This is intentional — the service works even if this repo is deleted.

### Networking: Explicit iptables, Not Docker-Managed

Docker's built-in iptables management (`--iptables=true`) uses global chain names (`DOCKER-FORWARD`, `DOCKER-USER`, etc.) that get clobbered when multiple dockerd instances start. We disable it (`--iptables=false`) and manage iptables explicitly in the systemd service lifecycle:

- **ExecStartPre**: Inserts 3 FORWARD rules + 1 NAT MASQUERADE rule, all scoped to the instance's bridge name
- **ExecStopPost**: Removes the same rules

Each rule uses `-i $BRIDGE` or `-o $BRIDGE` so instances can never interfere with each other or with the system Docker.

### Directory Layout (per instance)

```
${DOCKYARD_ROOT}/                        # owned by ${INSTANCE_USER}:${INSTANCE_GROUP}
├── docker.sock                          # Docker API socket (root:${GROUP} 660)
├── docker/                              # Docker data (images, containers, volumes)
│   └── containerd/                      # Containerd content store
├── sysbox-run/                          # Per-instance sysbox sockets + PID files
│   ├── sysmgr.sock
│   ├── sysfs.sock
│   ├── sysbox-mgr.pid
│   └── sysbox-fs.pid
├── sysbox/                              # sysbox-mgr data-root + sysbox-fs mountpoint
└── docker-runtime/
    ├── bin/                             # dockerd, containerd, sysbox-mgr, sysbox-fs,
    │                                    # sysbox-runc (wrapper), sysbox-runc-bin (actual),
    │                                    # docker-cli, docker (wrapper), dockyardctl
    ├── etc/
    │   ├── daemon.json                  # Docker daemon config
    │   └── dockyard.env                 # Copy of config (written by create)
    ├── lib/
    │   └── docker/                      # DOCKER_CONFIG dir (credentials, config)
    ├── log/
    │   ├── containerd.log
    │   ├── dockerd.log
    │   ├── sysbox-mgr.log
    │   └── sysbox-fs.log
    └── run/
        └── containerd.pid

/run/${PREFIX}docker/                    # Runtime state (tmpfs)
├── containerd/
│   └── containerd.sock
└── dockerd.pid

/etc/systemd/system/
└── ${PREFIX}docker.service              # Per-instance docker service (no shared sysbox service)

/etc/apparmor.d/local/fusermount3        # Per-instance tagged block, removed on destroy
```

## Key Files

- `src/01_env.sh` — `derive_vars()` with `SYSBOX_RUN_DIR`, `SYSBOX_DATA_DIR`, `INSTANCE_USER`, `INSTANCE_GROUP`
- `src/11_create.sh` — groupadd/useradd, binary install (static tarball, not .deb), sysbox-runc wrapper install, chown after install
- `src/12_enable.sh` — per-instance docker.service with inline sysbox ExecStartPre/ExecStopPost, `--group` flag for dockerd
- `src/13_disable.sh` — removes docker service only (no shared sysbox service logic)
- `src/14_start.sh` — starts sysbox-mgr and sysbox-fs inline before containerd/dockerd, `--group` flag
- `src/15_stop.sh` — stops dockerd, containerd, sysbox-fs, sysbox-mgr in order
- `src/17_destroy.sh` — removes `sysbox-run/` and `sysbox/` dirs, userdel/groupdel
- `ARCHITECTURE.md` — comprehensive design doc with mermaid diagrams
- `FINDINGS.md` — root cause analysis of all discovered issues
- `PROGRESS.md` — architecture summary and test phase breakdown

## Script Conventions

- `set -euo pipefail`
- Env loading: `set -a; source "$ENV_FILE"; set +a`
- Operations are idempotent (bridge creation, iptables removal, socket cleanup)
- Binaries are cached in `.tmp/` to avoid re-downloading
- `status` works without root (uses `/proc/$pid` instead of `kill -0`)
- `build.sh` uses `awk 'NR==1 && /^#!/ {next} {print}'` to strip per-file shebangs — `grep -v '^#!'` would also strip `#!` lines inside heredocs
