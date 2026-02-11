# Docker + Sysbox Custom Installation

## Goal

Second Docker daemon (29.2.1, static binaries) at `/docker.sock` with data at `/docker` and sysbox-runc as default runtime. Runs side-by-side with system Docker at `/run/docker.sock`.

## Architecture

```
System Docker                    Our Docker
─────────────                    ──────────
socket:  /run/docker.sock        socket:  /docker.sock
data:    /var/lib/docker          data:    /docker
runtime: runc (default)          runtime: sysbox-runc (default)
bridge:  docker0 (172.20.0.1/16) bridge:  sc_docker0 (172.30.0.1/24)
pools:   172.25.0.0/16           pools:   172.31.0.0/16
containerd: /run/containerd/     containerd: /run/docker-alt/containerd/
```

Sysbox (0.6.6) runs via systemd (`sysbox-fs.service`, `sysbox-mgr.service`) and is shared by both Docker daemons.

## Files

| File | Purpose |
|---|---|
| `setup.sh` | Downloads Docker 29.2.1 + sysbox 0.6.7, extracts to `bin/` |
| `etc/daemon.json` | Custom dockerd config (separate paths, sysbox default, isolated networking) |
| `start.sh` | Creates bridge, starts containerd + dockerd |
| `stop.sh` | Stops dockerd + containerd, removes bridge |
| `env.sh` | Sets `DOCKER_HOST=unix:///docker.sock` for shell |

## Usage

```bash
sudo /home/thies/docker/setup.sh       # one-time: download & install
sudo /home/thies/docker/start.sh       # start containerd + docker
source /home/thies/docker/env.sh       # configure shell
docker run --rm hello-world            # verify (uses sysbox-runc)
sudo /home/thies/docker/stop.sh        # stop everything
```

To use system docker while our docker is running:
```bash
docker -H unix:///run/docker.sock ...
```
