# Dockyard Architecture

A technical reference for how Dockyard works and the reasoning behind each major design decision.

---

## The Problem

Linux has one dockerd per host. That works until you need genuine daemon-level isolation: separate image stores, separate overlay networks, separate iptables rule sets, different runtimes per tenant, or the ability to destroy one workload's environment without touching another's. Namespaces and cgroups give you container-level isolation but a single daemon is still a single point of failure and a shared blast radius.

The naive fix — "just run more dockerd processes" — breaks immediately:

- **iptables chain collision.** Docker creates global chains (`DOCKER`, `DOCKER-FORWARD`, `DOCKER-USER`, `DOCKER-ISOLATION-STAGE-1`, `DOCKER-ISOLATION-STAGE-2`). When a second daemon starts it overwrites the rules the first daemon wrote. Whichever daemon reloads last wins; the others lose outbound connectivity silently.
- **Containerd socket conflict.** Multiple dockerd processes default to the same containerd socket path.
- **Shared bridge names.** Both daemons try to create `docker0`.
- **Sysbox singleton.** sysbox-mgr and sysbox-fs have hardcoded socket paths (`run sysbox sysmgr.sock`, `run sysbox sysfs.sock`) — only one pair can run per host.

Dockyard solves all four, with no kernel patches, no VMs, and no changes to the host Docker.

---

## Architecture Overview

```mermaid
graph TB
    subgraph "Host systemd"
        SB["dockyard-sysbox.service
(shared, one per host)
sysbox-mgr + sysbox-fs"]

        subgraph "Instance A  dy1_"
            D1["dy1_docker.service
containerd + dockerd
dy1 docker.sock"]
        end

        subgraph "Instance B  dy2_"
            D2["dy2_docker.service
containerd + dockerd
dy2 docker.sock"]
        end

        subgraph "Instance C  dy3_"
            D3["dy3_docker.service
containerd + dockerd
dy3 docker.sock"]
        end
    end

    SB -->|"Requires"| D1
    SB -->|"Requires"| D2
    SB -->|"Requires"| D3

    D1 -->|"sysbox-runc"| SB
    D2 -->|"sysbox-runc"| SB
    D3 -->|"sysbox-runc"| SB
```

Each instance is independent: its own bridge, subnet, iptables rules, containerd, socket, data directory, and systemd service. All share one sysbox daemon because sysbox's architecture requires it.

---

## Design Decisions and Rationale

### 1. Explicit iptables — not `--iptables=true`

**The problem.** When Docker manages iptables it uses globally-named chains. Starting a second daemon stomps the first daemon's rules because `iptables -F DOCKER` flushes the entire chain regardless of which daemon owns which rule.

**The solution.** Set `--iptables=false` in every daemon's `daemon.json` and manage iptables entirely from the systemd service's `ExecStartPre` and `ExecStopPost` hooks. Each instance injects exactly four rules, all scoped to its own bridge name:

```
iptables -I FORWARD -i ${BRIDGE} -o ${BRIDGE} -j ACCEPT
iptables -I FORWARD -i ${BRIDGE} ! -o ${BRIDGE} -j ACCEPT
iptables -I FORWARD -o ${BRIDGE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -I POSTROUTING -s ${FIXED_CIDR} ! -o ${BRIDGE} -j MASQUERADE
```

Because every rule references `${BRIDGE}` (e.g. `dy1_docker0`), instances are mathematically incapable of interfering with each other. Teardown is equally clean: `ExecStopPost` removes the same four rules with `-D`.

**Why not nftables?** iptables is still the lowest common denominator for Ubuntu LTS, Debian, and the Alpine-derived VMs this tooling targets. nftables support is a natural future addition.

---

### 2. Shared sysbox daemon

**The constraint.** Sysbox 0.6.7 CE hardcodes its control socket paths at compile time:

```
/run/sysbox/sysmgr.sock   (sysbox-mgr)
/run/sysbox/sysfs.sock    (sysbox-fs)
```

There is no flag to change them. Running two sysbox-mgr processes on the same host is physically impossible — they fight over the same socket file.

**The solution.** One shared `dockyard-sysbox.service` per host, installed at create time and removed only when the last dockyard instance is destroyed. The shared service owns:

```
/usr/local/lib/dockyard/        sysbox-mgr and sysbox-fs binaries
/var/lib/dockyard-sysbox/       sysbox runtime state
/var/log/dockyard-sysbox/       sysbox logs
```

`sysbox-runc` stays per-instance inside `${BIN_DIR}/` because it is invoked by containerd directly (via `daemon.json`'s `runtimes` block) and needs no shared socket.

**systemd ref-counting.** Every docker service declares `Requires=dockyard-sysbox.service`. systemd starts sysbox before the first docker service that needs it, keeps it running while any docker service is active, and stops it automatically when the last docker service stops. No manual reference counting is needed in normal operation.

**Non-systemd fallback.** For `create --no-systemd`, `sysbox_acquire()` and `sysbox_release()` use `flock` on a counter file to track running instances and start or stop sysbox-mgr and sysbox-fs accordingly.

---

### 3. Static Docker binaries — not distro packages

**Why not `apt install docker.io`?**

- Creates a system-wide `docker.service` that conflicts with instance services.
- Writes to `/usr/bin/dockerd` — shared across all instances, so you cannot run different Docker versions simultaneously.
- Ties instances to the host's package manager and upgrade cycles.
- Leaves global state on removal.

**Static binaries** are downloaded once, cached in `.tmp/`, and copied into `${BIN_DIR}/` during `create`. Each instance owns its complete binary set. Different instances can pin different Docker versions. Removing an instance removes its binaries entirely.

Versions are pinned explicitly in `cmd_create()`:

| Binary | Version | Source |
|--------|---------|--------|
| Docker CE static | 29.2.1 | download.docker.com |
| Docker Rootless Extras | 29.2.1 | download.docker.com |
| Sysbox CE .deb | 0.6.7 | downloads.nestybox.com |

---

### 4. Sysbox binary extraction — not `dpkg install`

**Why not install the .deb?**

- `dpkg -i sysbox.deb` writes to system paths and creates system-wide `sysbox-fs.service` and `sysbox-mgr.service`. These conflict with `dockyard-sysbox.service`.
- dpkg registers the package in the system package database, making future upgrades entangled.
- Uninstall requires `dpkg -r` which removes files even if another tool needs them.

**Binary extraction** uses `dpkg-deb --extract` to unpack the .deb into a temp directory, then copies just the three binaries (`sysbox-runc`, `sysbox-mgr`, `sysbox-fs`). No package database entry, no system service files, no side effects. The binaries end up in `${BIN_DIR}/` (per-instance for sysbox-runc) and `/usr/local/lib/dockyard/` (shared, for mgr and fs).

---

### 5. Self-contained systemd services

The generated `.service` file has all paths expanded at create time:

```ini
[Service]
ExecStartPre=/sbin/iptables -I FORWARD -i dy1_docker0 -o dy1_docker0 -j ACCEPT
ExecStart=/dy1/docker-runtime/bin/dockerd \
    --data-root /dy1/docker \
    --pidfile /dy1/docker-runtime/run/dockerd.pid \
    --host unix:///dy1/docker.sock \
    ...
ExecStopPost=/sbin/iptables -D FORWARD -i dy1_docker0 -o dy1_docker0 -j ACCEPT
```

There are no references to `dockyard.sh`, no environment variables that must be set, no external scripts. The service continues to work even if the dockyard repository is deleted after installation. This is intentional: operational tooling should not depend on source trees being present.

---

### 6. Gen-env: collision-aware config generation

Running multiple instances on the same host requires every instance to have unique values for bridge IP, subnet, pool base, prefix, root directory, and service names. `gen-env` automates this with active conflict detection:

```mermaid
graph TD
    A["gen-env called"] --> B["Pick random /24 from 172.16.0.0/12
for bridge CIDR"]
    B --> C["Check ip route for overlap"]
    C -->|"collision"| B
    C -->|"clear"| D["Pick random /16 from 172.16.0.0/12
(different second octet)
for pool base"]
    D --> E["check_prefix_conflict
bridge exists?
exec-root dir exists?
systemd service exists?"]
    E -->|"collision"| F["Retry up to 10x"]
    F --> B
    E -->|"clear"| G["check_root_conflict
docker-runtime/bin present?"]
    G -->|"exists"| H["Error: already installed"]
    G -->|"clear"| I["Write dockyard.env"]
```

All six variables (`DOCKYARD_ROOT`, `DOCKYARD_DOCKER_PREFIX`, `DOCKYARD_BRIDGE_CIDR`, `DOCKYARD_FIXED_CIDR`, `DOCKYARD_POOL_BASE`, `DOCKYARD_POOL_SIZE`) can be overridden via environment variables. `--nocheck` skips collision detection for scripted use.

---

### 7. Per-instance system user and group

Each instance gets a dedicated system user and group: `${PREFIX}docker` (e.g. `dy1_docker` for prefix `dy1_`).

**Why?**

Without a dedicated group, accessing the docker socket requires `sudo` every time. Docker's traditional answer is a global `docker` group — but a global group grants access to *all* daemons on the host, defeating per-instance access control.

With a per-instance group:

- Operators get access to exactly one instance by joining that instance's group (`usermod -aG dy1_docker alice`) with no effect on other instances.
- `ls -la /dy1` shows `dy1_docker:dy1_docker` ownership, making process and file attribution immediately obvious in `ps`, `lsof`, and audit logs.
- The principle of least privilege is maintained: membership in `dy2_docker` conveys no rights over `/dy1/docker.sock`.

**How it works.** dockerd accepts a `--group` flag that controls the group ownership of the socket it creates. With `--group dy1_docker`, the socket is created as `root:dy1_docker` mode `660`. dockerd itself continues to run as root (required for bridge creation, iptables, and sysbox) — the group only controls socket access.

```
/dy1/docker.sock   root:dy1_docker  660
```

User/group creation happens during `create`, removal during `destroy`. Both operations are idempotent.

---

### 8. Single script, subcommand interface

`dockyard.sh` is the sole artifact you need to deploy. There are no config management tools, no Helm charts, no daemon processes beyond what it installs. The build pipeline (`./build.sh`) concatenates 14 source files in `src/` into `dist/dockyard.sh` but the output is a plain shell script that runs on any Linux system with bash, curl, tar, dpkg-deb, and systemd.

This matters for target environments: cloud VMs, CI nodes, and edge hosts rarely have package managers pre-seeded with the right tools, but they always have bash.

---

## Startup Sequence

```mermaid
sequenceDiagram
    participant SD as systemd
    participant SB as dockyard-sysbox
    participant CT as containerd
    participant DK as dockerd

    SD->>SB: Start dockyard-sysbox.service
    Note over SB: sysbox-mgr starts<br/>sysbox-fs starts
    SB-->>SD: Active

    SD->>CT: Start dy1_docker.service (ExecStartPre)
    Note over CT: iptables rules inserted<br/>FORWARD and NAT MASQUERADE
    CT->>CT: containerd starts
    CT-->>DK: containerd ready
    DK->>DK: dockerd starts
    Note over DK: Registers sysbox-runc runtime<br/>Listens on dy1 docker.sock
    DK-->>SD: Active
```

On shutdown the sequence reverses: dockerd stops, containerd stops, `ExecStopPost` removes the iptables rules. sysbox stops automatically when all docker services referencing it have stopped.

---

## Networking Model

Each instance creates one Linux bridge and one NAT entry. All rules are name-scoped.

```mermaid
graph LR
    subgraph "Instance A  172.22.147.x"
        B1["Bridge: dy1_docker0
172.22.147.1"]
        C1A["container-1
172.22.147.2"]
        C1B["container-2
172.22.147.3"]
    end

    subgraph "Instance B  172.23.80.x"
        B2["Bridge: dy2_docker0
172.23.80.1"]
        C2A["container-3
172.23.80.2"]
    end

    NET["Host network
eth0"]

    C1A --- B1
    C1B --- B1
    C2A --- B2
    B1 -->|"NAT MASQUERADE"| NET
    B2 -->|"NAT MASQUERADE"| NET
```

Containers on different instances cannot reach each other at layer 3 because there is no FORWARD rule between bridges — only rules with `-i ${BRIDGE}` or `-o ${BRIDGE}` are inserted, never cross-bridge rules. This is daemon-level network isolation without any overlay driver or CNI plugin.

---

## Sysbox Integration: Why Docker-in-Docker Works

Sysbox implements a set of Linux kernel subsystem virtualisation that make a container look more like a lightweight VM to its workloads:

- **Procfs virtualisation.** `/proc` inside the container is shim'd so that kernel metadata (e.g. `/proc/sys/kernel/ngroups_max`) appears writable from inside.
- **Sysfs virtualisation.** Prevents host sysfs from leaking into containers.
- **User namespace isolation.** sysbox-runc creates a unique user namespace per container, mapping container UID 0 to a non-zero UID range on the host.

This means a container running `dockerd` inside does not need `--privileged`. It gets the capabilities it needs through the user namespace and the shim'd proc/sysfs, without giving it unrestricted access to the host kernel.

**The runc pin.** runc 1.3.x (shipped with Docker 27.x) introduced a stricter `/proc` safety check that rejects the virtualised `/proc` presented by sysbox-fs. The symptom is an OCI runtime error at container start time. The fix is to pin inner DinD containers to `docker:26.1-dind` which bundles runc 1.1.12.

```
docker:26.1-dind   →   runc 1.1.12   →   works with sysbox 0.6.7
docker:27.x-dind   →   runc 1.3.x    →   OCI error, unusable with sysbox 0.6.7
```

This constraint is sysbox upstream issue #1756 and is tracked in `FINDINGS.md`.

---

## Directory Layout

```
${DOCKYARD_ROOT}/
├── docker.sock                API socket for this instance
├── docker/                    Docker data root (images, containers, volumes)
│   └── containerd/            Containerd content store
├── sysbox/                    (reserved for future per-instance sysbox state)
└── docker-runtime/
    ├── bin/                   dockerd, containerd, sysbox-runc, docker wrapper
    ├── etc/
    │   ├── daemon.json        Generated daemon config
    │   └── dockyard.env       Copy of the env file for this instance
    ├── lib/
    │   └── docker/            DOCKER_CONFIG dir (auth, config.json)
    ├── log/
    │   ├── containerd.log
    │   └── dockerd.log
    └── run/
        ├── containerd.pid
        └── dockerd.pid

/run/${PREFIX}docker/          Tmpfs runtime state
    └── containerd/
        └── containerd.sock

/etc/systemd/system/
    ├── dockyard-sysbox.service    Shared sysbox (one per host)
    └── ${PREFIX}docker.service    Per-instance docker service

/usr/local/lib/dockyard/       Shared sysbox binaries
    ├── sysbox-mgr
    └── sysbox-fs

/var/lib/dockyard-sysbox/      Shared sysbox runtime state
/var/log/dockyard-sysbox/      Shared sysbox logs
```

---

## Resource Naming and Inventory

### Naming Convention

All resources a dockyard instance owns on the host are namespaced under its `PREFIX` (the value of `DOCKYARD_DOCKER_PREFIX`, e.g. `dy1_`). Shared resources carry the literal prefix `dockyard` or `dockyard-sysbox`.

#### Per-instance resources

| Resource type | Name pattern | Example (PREFIX = `dy1_`) |
|---------------|-------------|--------------------------|
| Systemd service | `${PREFIX}docker.service` | `dy1_docker.service` |
| Linux bridge | `${PREFIX}docker0` | `dy1_docker0` |
| System user | `${PREFIX}docker` | `dy1_docker` |
| System group | `${PREFIX}docker` | `dy1_docker` |
| Runtime tmpfs dir | `/run/${PREFIX}docker/` | `/run/dy1_docker/` |
| Containerd state dir | `/run/${PREFIX}docker/containerd/` | `/run/dy1_docker/containerd/` |
| Data root | `${DOCKYARD_ROOT}/` | `/dy1/` |
| API socket | `${DOCKYARD_ROOT}/docker.sock` | `/dy1/docker.sock` |
| Containerd socket | `/run/${PREFIX}docker/containerd/containerd.sock` | `/run/dy1_docker/containerd/containerd.sock` |
| Runtime dir | `${DOCKYARD_ROOT}/docker-runtime/` | `/dy1/docker-runtime/` |
| Binaries | `${DOCKYARD_ROOT}/docker-runtime/bin/` | `/dy1/docker-runtime/bin/` |
| Config | `${DOCKYARD_ROOT}/docker-runtime/etc/` | `/dy1/docker-runtime/etc/` |
| Logs | `${DOCKYARD_ROOT}/docker-runtime/log/` | `/dy1/docker-runtime/log/` |

#### Shared resources (one set per host)

| Resource type | Fixed name | Path |
|---------------|------------|------|
| Sysbox systemd service | `dockyard-sysbox.service` | `/etc/systemd/system/` |
| Sysbox binaries | `sysbox-mgr`, `sysbox-fs` | `/usr/local/lib/dockyard/` |
| Sysbox runtime state | — | `/var/lib/dockyard-sysbox/` |
| Sysbox logs | `sysbox-mgr.log`, `sysbox-fs.log` | `/var/log/dockyard-sysbox/` |
| Refcount file | `dockyard-refcount` | `/run/sysbox/` |
| Refcount lock | `dockyard-refcount.lock` | `/run/sysbox/` |
| AppArmor override | `fusermount3` (scoped to sysbox path) | `/etc/apparmor.d/local/` |

### Resource Scope Diagram

```mermaid
graph TB
    subgraph "Per-Instance  (one complete set per PREFIX)"
        SVC["Systemd service
dy1_docker.service"]
        BR["Bridge
dy1_docker0"]
        UG["User + Group
dy1_docker"]
        DR["Data root
DOCKYARD_ROOT
owns: docker.sock
docker-runtime"]
        RT["Runtime tmpfs
run/dy1_docker
containerd.sock"]
    end

    subgraph "Shared  (one set per host, ref-counted)"
        SS["dockyard-sysbox.service"]
        SB["Sysbox binaries
usr/local/lib/dockyard
sysbox-mgr + sysbox-fs"]
        SD["Sysbox state + logs
var/lib/dockyard-sysbox
var/log/dockyard-sysbox"]
    end

    SVC -->|"Requires"| SS
    SVC -->|"manages"| BR
    SVC -->|"creates"| RT
    UG -->|"owns socket in"| DR
    SS -->|"uses"| SB
    SS -->|"writes"| SD
```

### Socket Access Model

```mermaid
graph LR
    subgraph "Instance dy1_"
        SOCK["docker.sock
root:dy1_docker  660"]
    end

    ROOT["Process running as root"]
    GRP["dy1_docker group member"]
    NEWOP["New operator
usermod -aG dy1_docker alice"]
    OTHER["Other users"]

    ROOT -->|"always allowed"| SOCK
    GRP -->|"group r+w"| SOCK
    NEWOP -->|"joins group"| GRP
    OTHER -. "permission denied" .-> SOCK
```

The separation between instances is strict: membership in `dy2_docker` conveys zero rights over `/dy1/docker.sock`.

---

## Test Suite

The integration test suite (`cmd/dockyardtest/main.go`) runs 27 tests against a real Linux VM over SSH. It covers the full instance lifecycle including edge cases:

| Phase | Tests | What is verified |
|-------|-------|-----------------|
| Setup | 01–04 | Upload, gen-env for 3 instances |
| Create | 05 | Concurrent creation (A+B+C in parallel with 3 s stagger) |
| Service health | 06 | Shared sysbox active + all per-instance docker services active |
| Container basics | 07–09 | Container run, outbound ping, DNS resolution on all instances |
| Docker-in-Docker | 10–12 | DinD start (no --privileged), inner container, inner networking |
| Isolation | 13 | All pairs: containers from A not visible in B or C |
| Stop/start cycle | 14 | systemctl stop then start, iptables re-injected, containers run |
| Socket permissions | 15 | Socket not world-accessible; group-owned by `${PREFIX}docker` |
| Destroy under load | 16 | Destroy A while a container is running — must succeed cleanly |
| Idempotent destroy | 17 | Second destroy on already-destroyed instance returns exit 0 |
| Cleanup check | 18 | A's service, bridge, and iptables rules all gone |
| Survivor check | 19 | B+C unaffected by A's destruction |
| Reboot | 20 | Full host reboot; B+C must come back automatically via systemd |
| Post-reboot health | 21–24 | Services, containers, networking, DinD — all on B+C |
| Final teardown | 25–26 | Destroy B and C |
| Full cleanup | 27 | No residual services, bridges, iptables, data dirs, users, groups, or shared sysbox |

Tests 05, 07–13, 19–24 run instance-level checks concurrently using goroutines. Results are sorted by instance label before printing to ensure deterministic output.

---

## Trade-offs and Alternatives Considered

### Why not rootless Docker?

Rootless Docker runs the daemon in a user namespace without root. It is excellent for single-user workstation isolation but has two drawbacks for the multi-tenant server use case:

1. **Network stack limitations.** Rootless Docker cannot manage iptables rules or create real bridges. It uses `slirp4netns` or `pasta` which are user-space NAT — functional but slower and with different capabilities.
2. **sysbox incompatibility.** sysbox-runc requires the daemon to run as root. Rootless Docker and sysbox are mutually exclusive.

### Why not Kubernetes?

Kubernetes provides strong pod-level isolation but the overhead is substantial: you need at minimum a control plane, kubelet, CNI plugin, and CRI shim. For the use case of "isolated Docker environments on a single bare-metal host", that is several orders of magnitude more complexity than a shell script and a systemd service.

### Why not Docker contexts?

Docker contexts switch the client's `DOCKER_HOST`. They do not isolate the daemon — all contexts still talk to processes running as the same user, sharing the same image store and bridge.

### Why not LXD or LXC?

LXD gives you full OS containers with their own init systems. Each LXD container could run its own Docker. This works but:

- Requires LXD installation and management.
- Each container runs a full Linux image (hundreds of MB overhead).
- Networking is more complex (LXD bridge → LXD container bridge → Docker bridge).
- LXD's storage driver and Docker's storage driver need to be coordinated.

Dockyard achieves similar isolation at much lower overhead because sysbox handles the container-level virtualisation that LXD would otherwise provide.

### Why not containerd directly?

containerd supports multiple namespaces natively. You could run one containerd with separate namespaces for different tenants. This loses the Docker API compatibility that most tooling expects and requires every operator to learn the containerd CLI and gRPC API.

Dockyard preserves the Docker API surface entirely — `DOCKER_HOST=unix:///dy1/docker.sock docker ps` just works.
