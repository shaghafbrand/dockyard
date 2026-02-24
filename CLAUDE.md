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

Everything else is derived: `RUNTIME_DIR`, `BRIDGE`, `EXEC_ROOT`, `SERVICE_NAME`, `DOCKER_SOCKET`, `CONTAINERD_SOCKET`, `INSTANCE_USER`, `INSTANCE_GROUP`.

`SYSBOX_SERVICE_NAME` is always `dockyard-sysbox` (host-level shared, not prefixed).

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

- `check_prefix_conflict()` — bridge exists, exec-root dir exists, docker systemd service exists, sysbox systemd service exists
- `check_root_conflict()` — `docker-runtime/bin/` already present
- `check_subnet_conflict()` — `ip route` overlap for fixed CIDR and pool base

### Downloaded Software

Defined in `cmd_create()`, cached in `.tmp/`:

| Software | Version | Source |
|----------|---------|--------|
| Docker CE (static) | 29.2.1 | download.docker.com |
| Docker Rootless Extras | 29.2.1 | download.docker.com |
| Sysbox CE (.deb) | 0.6.7 | downloads.nestybox.com |

### Shared Sysbox Daemon (Host-Level)

Sysbox 0.6.7 CE has hardcoded socket paths (`/run/sysbox/sysfs.sock`, `/run/sysbox/sysmgr.sock`). Only one sysbox-mgr + sysbox-fs can run per host.

**Architecture**: A single `dockyard-sysbox.service` is shared across all instances:
- Shared binaries: `/usr/local/lib/dockyard/sysbox-{fs,mgr}` (copied on first `create`)
- Shared data: `/var/lib/dockyard-sysbox/`
- Shared logs: `/var/log/dockyard-sysbox/`
- `sysbox-runc` stays per-instance in `${BIN_DIR}/` (invoked by containerd via daemon.json)

**Systemd mode**: `${PREFIX}docker.service` has `Requires=dockyard-sysbox.service`. Systemd handles ref-counting automatically — starts sysbox with the first docker service, stops it after the last.

**Non-systemd mode**: `sysbox_acquire()` / `sysbox_release()` with `flock` on `/run/sysbox/dockyard-refcount.lock`. First acquire starts sysbox; last release stops it.

**Startup Sequence**:
```
dockyard-sysbox.service starts (shared, once per host)
  ├─ sysbox-mgr (manages container creation)
  └─ sysbox-fs (manages container filesystems)
       └─ ${PREFIX}docker.service starts (per instance)
            ├─ containerd
            └─ dockerd (with sysbox-runc as default runtime)
```

**Lifecycle**: The shared service is installed on first `create` (skipped if already present) and removed by `disable`/`destroy` only when no `*_docker.service` files remain.

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
└── docker-runtime/
    ├── bin/                             # dockerd, containerd, sysbox-runc, dockyardctl, docker wrapper
    ├── etc/
    │   ├── daemon.json                  # Docker daemon config
    │   └── dockyard.env                 # Copy of config (written by create)
    ├── lib/
    │   └── docker/                      # DOCKER_CONFIG dir (credentials, config)
    ├── log/
    │   ├── containerd.log
    │   └── dockerd.log
    └── run/
        └── containerd.pid

/run/${PREFIX}docker/                    # Runtime state (tmpfs)
├── containerd/
│   └── containerd.sock
└── dockerd.pid

/etc/systemd/system/
├── dockyard-sysbox.service              # Shared sysbox service (one per host)
└── ${PREFIX}docker.service              # Per-instance docker service (Requires=dockyard-sysbox)

# Shared sysbox resources (created on first install, removed on last destroy)
/usr/local/lib/dockyard/sysbox-{fs,mgr}  # Shared sysbox-mgr and sysbox-fs binaries
/var/lib/dockyard-sysbox/                # Shared sysbox data
/var/log/dockyard-sysbox/                # Shared sysbox logs
/run/sysbox/                             # Sysbox sockets + ref-count lock
```

## Script Conventions

- `set -euo pipefail`
- Env loading: `set -a; source "$ENV_FILE"; set +a`
- Operations are idempotent (bridge creation, iptables removal, socket cleanup)
- Binaries are cached in `.tmp/` to avoid re-downloading
- `status` works without root (uses `/proc/$pid` instead of `kill -0`)
