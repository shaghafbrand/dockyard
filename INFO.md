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

Sysbox (0.6.6) runs via systemd (`sysbox-fs.service`, `sysbox-mgr.service`) and is shared by both Docker daemons.

## Files

| File | Purpose |
|---|---|
| `install.sh` | Install: download binaries, install systemd service, start daemon |
| `uninstall.sh` | Uninstall: stop daemon, remove systemd service, remove all files |
| `start.sh` | Creates bridge, starts containerd + dockerd |
| `stop.sh` | Stops dockerd + containerd, removes bridge |
| `env.sh` | Sets `SANDCASTLE_ROOT` and `DOCKER_HOST` for shell |
| `etc/daemon.json` | dockerd config (sysbox default, insecure registries) |
| `etc/sc_docker.service` | systemd unit template |

## Usage

```bash
sudo -E ./install.sh                   # install, enable systemd, start
source ./env.sh                        # configure shell
docker run --rm hello-world            # verify (uses sysbox-runc)
sudo -E ./install.sh --no-systemd     # install without systemd service
sudo -E ./install.sh --no-start       # install without starting
sudo -E ./install.sh -h               # show all options and env vars
sudo -E ./uninstall.sh                 # remove everything
```

To use system docker while our docker is running:
```bash
docker -H unix:///run/docker.sock ...
```
