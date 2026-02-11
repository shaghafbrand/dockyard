# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Dockyard: multi-instance Docker daemon installer with sysbox-runc as default runtime. Runs isolated Docker instances side-by-side with the system Docker on the same host. Each instance gets its own bridge network, containerd, socket, and data directory.

## Key Commands

```bash
sudo ./install.sh                  # Install using env.default
sudo ./install.sh thies            # Install using env.thies
sudo ./install.sh thies --no-start # Install without starting
./status.sh                        # Status of default instance
./status.sh thies                  # Status of named instance
sudo ./uninstall.sh                # Remove default instance
sudo ./uninstall.sh thies          # Remove named instance
```

Manual start/stop (without systemd):
```bash
sudo ./start.sh [env-name]
sudo ./stop.sh [env-name]
```

Using a custom instance:
```bash
DOCKER_HOST=unix:///sandcastle/docker.sock docker ps
```

## Architecture

### Environment-Driven Multi-Instance

All scripts take an optional env name argument (default: `default`), loading `env.<name>`. Each env file defines 6 variables that fully configure an instance:

| Variable | Purpose | Must be unique per instance |
|----------|---------|----------------------------|
| `SANDCASTLE_ROOT` | Base directory for data/runtime/socket | Yes |
| `SANDCASTLE_DOCKER_PREFIX` | Prefix for bridge, service name, exec-root | Yes |
| `SANDCASTLE_BRIDGE_CIDR` | Bridge IP/mask (e.g. `172.30.0.1/24`) | Yes |
| `SANDCASTLE_FIXED_CIDR` | Container subnet (e.g. `172.30.0.0/24`) | Yes |
| `SANDCASTLE_POOL_BASE` | Address pool for user networks | Yes |
| `SANDCASTLE_POOL_SIZE` | Pool subnet size in CIDR bits | No |

Everything else is derived: `RUNTIME_DIR`, `BRIDGE`, `EXEC_ROOT`, `SERVICE_NAME`, `DOCKER_SOCKET`, `CONTAINERD_SOCKET`.

### Downloaded Software

Defined in `install.sh` lines 126–133, cached in `.tmp/`:

| Software | Version | Source |
|----------|---------|--------|
| Docker CE (static) | 29.2.1 | download.docker.com |
| Docker Rootless Extras | 29.2.1 | download.docker.com |
| Sysbox CE (.deb) | 0.6.7 | downloads.nestybox.com |

### install.sh Generates Self-Contained Systemd Services

The service file template (line ~187) expands all variables at install time. The generated `.service` file has no external dependencies on this repo's scripts. This is intentional — the service works even if this repo is deleted.

### Networking: Explicit iptables, Not Docker-Managed

Docker's built-in iptables management (`--iptables=true`) uses global chain names (`DOCKER-FORWARD`, `DOCKER-USER`, etc.) that get clobbered when multiple dockerd instances start. We disable it (`--iptables=false`) and manage iptables explicitly in the systemd service lifecycle:

- **ExecStartPre**: Inserts 3 FORWARD rules + 1 NAT MASQUERADE rule, all scoped to the instance's bridge name
- **ExecStopPost**: Removes the same rules

Each rule uses `-i $BRIDGE` or `-o $BRIDGE` so instances can never interfere with each other or with the system Docker.

### Directory Layout (per instance)

```
${SANDCASTLE_ROOT}/
├── docker.sock              # Docker API socket
├── docker/                  # Docker data (images, containers, volumes)
│   └── containerd/          # Containerd content store
└── docker-runtime/
    ├── bin/                 # dockerd, containerd, sysbox-runc, etc.
    ├── etc/daemon.json      # Docker daemon config
    ├── log/                 # containerd.log, dockerd.log
    └── run/                 # containerd.pid

/run/${PREFIX}docker/        # Runtime state (tmpfs)
├── containerd/
│   └── containerd.sock
└── dockerd.pid
```

## Script Conventions

- All scripts use `set -euo pipefail`
- Env loading: `set -a; source "$ENV_FILE"; set +a` (install.sh) or plain `source` (status.sh)
- Operations are idempotent (bridge creation, iptables removal, socket cleanup)
- Binaries are cached in `.tmp/` to avoid re-downloading
- `status.sh` works without root (uses `/proc/$pid` instead of `kill -0`)
