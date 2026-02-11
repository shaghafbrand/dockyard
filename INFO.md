# Docker + Sysbox Custom Installation

## Goal

Second Docker daemon (29.2.1, static binaries) with sysbox-runc as default runtime. Runs side-by-side with system Docker. All scripts are portable — `SANDCASTLE_ROOT` (default `/sandcastle`) controls where data and socket live.

## Architecture

```
System Docker                    Our Docker
─────────────                    ──────────
socket:  /run/docker.sock        socket:  $SANDCASTLE_ROOT/docker.sock
data:    /var/lib/docker          data:    $SANDCASTLE_ROOT/docker
runtime: runc (default)          runtime: sysbox-runc (default)
bridge:  docker0 (172.20.0.1/16) bridge:  sc_docker0 (172.30.0.1/24)
pools:   172.25.0.0/16           pools:   172.31.0.0/16
containerd: /run/containerd/     containerd: /run/sc_docker/containerd/
```

Sysbox (0.6.7) runs via systemd (`sysbox-fs.service`, `sysbox-mgr.service`) and is shared by both Docker daemons.

## Files

| File | Purpose |
|---|---|
| `install.sh [env]` | Install: download binaries, generate systemd service, start daemon |
| `uninstall.sh [env]` | Uninstall: stop daemon, remove systemd service, remove all files |
| `start.sh [env]` | Creates bridge, starts containerd + dockerd |
| `stop.sh [env]` | Stops dockerd + containerd, removes bridge |
| `status.sh [env]` | Shows status of daemons, bridge, sockets |
| `env.sh` | Sets `SANDCASTLE_ROOT` and `DOCKER_HOST` for shell |
| `env.default` | Default environment (sc_ prefix, /sandcastle) |
| `env.thies` | Custom environment (tc_ prefix, /docker2) |
| `etc/daemon.json` | dockerd config (sysbox default, insecure registries) |

All scripts accept an optional `[env]` argument (default: `default`) to load `env.<name>`.
The systemd service is generated self-contained with all paths hardcoded — no references to start.sh/stop.sh.

## Usage

```bash
sudo ./install.sh                      # install with env.default
sudo ./install.sh thies               # install with env.thies
sudo ./install.sh thies --no-systemd  # install without systemd service
sudo ./install.sh thies --no-start    # install without starting
sudo ./install.sh -h                  # show all options
source ./env.sh                       # configure shell
docker run --rm hello-world           # verify (uses sysbox-runc)
sudo ./start.sh                       # start (env.default)
sudo ./stop.sh thies                  # stop (env.thies)
sudo ./status.sh                      # check status (env.default)
sudo ./uninstall.sh thies             # remove everything (env.thies)
```

To use system docker while our docker is running:
```bash
docker -H unix:///run/docker.sock ...
```
