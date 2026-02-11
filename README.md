# Dockyard

Run multiple isolated Docker daemons on a single host, each with its own network, storage, and socket — without touching the system Docker.

## Why?

The stock Docker daemon is a singleton. You get one `dockerd`, one bridge, one set of iptables rules. If you need isolation between workloads — different runtimes, different networks, different storage — you're stuck with hacks or heavyweight VMs.

Dockyard spins up fully independent Docker instances that:

- **Run sysbox-runc by default** — containers that can run systemd, Docker-in-Docker, and other system workloads without `--privileged`
- **Coexist peacefully** — each instance gets its own bridge, subnet, containerd, socket, and data directory. No shared state, no conflicts
- **Manage their own firewall rules** — no more iptables chain clobbering between daemons (a real problem with multiple dockerd instances)
- **Survive reboots** — systemd services with proper dependency ordering, automatic restart, and clean teardown
- **Install in seconds** — one command downloads Docker + sysbox binaries, generates a self-contained systemd service, and starts everything

## Quick Start

```bash
# Install the default instance
sudo ./install.sh

# Run a container (uses sysbox-runc automatically)
docker run --rm -it alpine ash
```

## Multiple Instances

Each instance is defined by a small env file. Two are included:

**env.default** — primary instance at `/sandcastle` on `172.30.0.0/24`:
```bash
SANDCASTLE_ROOT=/sandcastle
SANDCASTLE_DOCKER_PREFIX=sc_
SANDCASTLE_BRIDGE_CIDR=172.30.0.1/24
SANDCASTLE_FIXED_CIDR=172.30.0.0/24
SANDCASTLE_POOL_BASE=172.31.0.0/16
SANDCASTLE_POOL_SIZE=24
```

**env.thies** — second instance at `/docker2` on `172.32.0.0/24`:
```bash
SANDCASTLE_ROOT=/docker2
SANDCASTLE_DOCKER_PREFIX=tc_
SANDCASTLE_BRIDGE_CIDR=172.32.0.1/24
SANDCASTLE_FIXED_CIDR=172.32.0.0/24
SANDCASTLE_POOL_BASE=172.33.0.0/16
SANDCASTLE_POOL_SIZE=24
```

To add another instance, create `env.myname` with unique values for all six variables, then:

```bash
sudo ./install.sh myname
```

Each instance runs independently with its own systemd service (`sc_docker`, `tc_docker`, etc.), its own bridge, and its own iptables rules scoped to its bridge interface.

## Commands

```bash
sudo ./install.sh [env] [--no-systemd] [--no-start]   # Install instance
sudo ./uninstall.sh [env]                               # Remove instance completely
./status.sh [env]                                       # Show diagnostics
sudo ./start.sh [env]                                   # Start manually (no systemd)
sudo ./stop.sh [env]                                    # Stop manually (no systemd)
```

All commands default to the `default` environment if no argument is given.

## What Gets Installed

The installer downloads static binaries (cached in `.tmp/` for repeated installs):

| Software | Version | Binaries |
|----------|---------|----------|
| [Docker CE](https://download.docker.com/linux/static/stable/x86_64/) | 29.2.1 | dockerd, containerd, docker, ctr, runc, etc. |
| [Docker Rootless Extras](https://download.docker.com/linux/static/stable/x86_64/) | 29.2.1 | dockerd-rootless, vpnkit, rootlesskit, etc. |
| [Sysbox CE](https://github.com/nestybox/sysbox) | 0.6.7 | sysbox-runc, sysbox-mgr, sysbox-fs |

```
${SANDCASTLE_ROOT}/
├── docker.sock                     # Docker API socket
├── docker/                         # Images, containers, volumes
│   └── containerd/
└── docker-runtime/
    ├── bin/                        # dockerd, containerd, sysbox-runc (static binaries)
    ├── etc/daemon.json             # Daemon configuration
    ├── log/                        # containerd.log, dockerd.log
    └── run/                        # PID files

/etc/systemd/system/${PREFIX}docker.service   # Self-contained systemd unit
/run/${PREFIX}docker/                         # Runtime state (tmpfs)
```

The systemd service file is generated with all paths hardcoded at install time. It has no dependency on this repository — you can delete the repo after install and everything keeps running.

## How Networking Works

Each instance creates its own Linux bridge and manages its own iptables rules. Docker's built-in iptables management is disabled (`--iptables=false`) because multiple daemons fight over shared chain names like `DOCKER-FORWARD` — whichever starts last wins and breaks the others.

Instead, each service adds four rules on startup and removes them on shutdown:

```
iptables -I FORWARD -i sc_docker0 -o sc_docker0 -j ACCEPT                              # container ↔ container
iptables -I FORWARD -i sc_docker0 ! -o sc_docker0 -j ACCEPT                             # container → internet
iptables -I FORWARD -o sc_docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT   # internet → container (replies)
iptables -t nat -I POSTROUTING -s 172.30.0.0/24 ! -o sc_docker0 -j MASQUERADE           # NAT for outbound
```

Every rule is scoped to the instance's bridge name, so instances can never interfere with each other or with the system Docker.

## Accessing the System Docker

While dockyard instances are running, the system Docker still works normally:

```bash
docker -H unix:///run/docker.sock ps        # system docker
docker -H unix:///sandcastle/docker.sock ps  # dockyard instance
```

Or set `DOCKER_HOST` to make a dockyard instance the default:

```bash
export DOCKER_HOST=unix:///sandcastle/docker.sock
```

## Prerequisites

- Linux with systemd
- sysbox installed and running (`sysbox-fs.service`, `sysbox-mgr.service`)
- `curl`, `tar`, `ar` for binary downloads
- Root access for installation

## Uninstall

```bash
sudo ./uninstall.sh          # Removes default instance
sudo ./uninstall.sh thies    # Removes named instance
```

This stops the daemon, disables the systemd service, and removes all data including images and containers.

## Authorship

This project was written entirely by [Claude](https://claude.ai) (Anthropic). [Thies C. Arntzen](https://github.com/thieso2) provided direction and requirements as navigator.

## License

MIT License — see [LICENSE](LICENSE) for details.
