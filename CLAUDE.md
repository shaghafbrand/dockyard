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

Everything else is derived: `RUNTIME_DIR`, `BRIDGE`, `EXEC_ROOT`, `SERVICE_NAME`, `SYSBOX_SERVICE_NAME`, `DOCKER_SOCKET`, `CONTAINERD_SOCKET`.

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
| Docker Compose | 2.32.4 | github.com/docker/compose |
| Docker Buildx | 0.31.1 | github.com/docker/buildx |
| Sysbox CE (.deb) | 0.6.7 | downloads.nestybox.com |

### Bundled Sysbox: Per-Instance Runtime

Each dockyard instance bundles its own isolated sysbox installation:

**Extraction (not installation)**: The sysbox .deb is extracted to get binaries (sysbox-runc, sysbox-mgr, sysbox-fs) but NOT installed via dpkg. No system-wide sysbox.service is created.

**Bundled Service**: A `${PREFIX}sysbox.service` systemd unit is generated that:
- Starts sysbox-mgr first (manages container creation)
- Then starts sysbox-fs (manages container filesystems)
- Uses bundled binaries from `${BIN_DIR}/`
- Stores data in `${DOCKYARD_ROOT}/sysbox/`
- Logs to `${LOG_DIR}/sysbox-{mgr,fs}.log`

**Startup Sequence**:
```
${PREFIX}sysbox.service starts
  ├─ sysbox-mgr (manages container lifecycle)
  └─ sysbox-fs (manages container filesystems)
       └─ ${PREFIX}docker.service starts
            ├─ containerd
            └─ dockerd (with sysbox-runc as default runtime)
```

**Service Dependencies**: The docker service has `Requires=${SYSBOX_SERVICE_NAME}.service`, ensuring sysbox starts first.

**Isolation Benefits**:
- Multiple dockyard instances can run different sysbox versions
- No system-wide sysbox dependency or conflicts
- Each instance's sysbox data is isolated
- Clean uninstall removes everything (no system-wide state)

### Self-Contained Systemd Services

The service file template expands all variables at create time. The generated `.service` file has no external dependencies on this repo's scripts. This is intentional — the service works even if this repo is deleted.

### Networking: Explicit iptables, Not Docker-Managed

Docker's built-in iptables management (`--iptables=true`) uses global chain names (`DOCKER-FORWARD`, `DOCKER-USER`, etc.) that get clobbered when multiple dockerd instances start. We disable it (`--iptables=false`) and manage iptables explicitly in the systemd service lifecycle:

- **ExecStartPre**: Inserts 3 FORWARD rules + 1 NAT MASQUERADE rule, all scoped to the instance's bridge name
- **ExecStopPost**: Removes the same rules

Each rule uses `-i $BRIDGE` or `-o $BRIDGE` so instances can never interfere with each other or with the system Docker.

### Directory Layout (per instance)

```
${DOCKYARD_ROOT}/
├── docker.sock              # Docker API socket
├── docker/                  # Docker data (images, containers, volumes)
│   └── containerd/          # Containerd content store
├── sysbox/                  # Sysbox data (bundled instance-specific)
└── docker-runtime/
    ├── bin/                 # dockerd, containerd, sysbox-{runc,mgr,fs}, dockyardctl, docker wrapper, etc.
    ├── etc/
    │   ├── daemon.json      # Docker daemon config
    │   └── dockyard.env     # Copy of config (written by create)
    ├── lib/
    │   └── docker/
    │       └── cli-plugins/ # Docker CLI plugins (docker-compose, docker-buildx)
    ├── log/
    │   ├── sysbox-mgr.log   # Sysbox manager logs
    │   ├── sysbox-fs.log    # Sysbox filesystem logs
    │   ├── containerd.log   # Containerd logs
    │   └── dockerd.log      # Docker daemon logs
    └── run/
        ├── sysbox-mgr.pid   # Sysbox manager PID
        ├── sysbox-fs.pid    # Sysbox filesystem PID
        └── containerd.pid   # Containerd PID

/run/${PREFIX}docker/        # Runtime state (tmpfs)
├── containerd/
│   └── containerd.sock
└── dockerd.pid

/etc/systemd/system/
├── ${PREFIX}sysbox.service  # Bundled sysbox service
└── ${PREFIX}docker.service  # Docker service (depends on sysbox)
```

## Script Conventions

- `set -euo pipefail`
- Env loading: `set -a; source "$ENV_FILE"; set +a`
- Operations are idempotent (bridge creation, iptables removal, socket cleanup)
- Binaries are cached in `.tmp/` to avoid re-downloading
- `status` works without root (uses `/proc/$pid` instead of `kill -0`)
