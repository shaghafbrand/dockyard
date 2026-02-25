# Sysbox Bundled Service Fix

> **ARCHIVED — doubly-superseded architecture**
>
> This document describes the first intermediate design where each dockyard
> instance ran its own bundled sysbox daemon (`${PREFIX}sysbox.service`). That
> approach was abandoned because sysbox 0.6.7 CE has hardcoded socket paths
> (`/run/sysbox/sysfs.sock`, `/run/sysbox/sysmgr.sock`) — only one sysbox
> daemon can run per host.
>
> A second intermediate design used a **single shared `dockyard-sysbox.service`**
> per host (`Requires=` from each docker service). That too has been superseded.
>
> **Current architecture**: Per-instance sysbox using the
> `github.com/thieso2/sysbox` fork (version `0.6.7.9-tc`), which adds
> `--run-dir` to all three sysbox binaries. Each instance runs its own isolated
> sysbox pair with `--run-dir` passed via `runtimeArgs` in `daemon.json`. No
> wrapper script, no shared sysbox service, no ref-counting.
>
> See [ARCHITECTURE.md](ARCHITECTURE.md) for the current design and
> [FINDINGS.md](FINDINGS.md) for the full root-cause analysis.

---

## Problem (historical)

The dockyard installer had a critical dependency issue:

1. **Extracted but not launched**: The .deb was extracted to get sysbox binaries (sysbox-runc, sysbox-mgr, sysbox-fs) into the instance's `bin/` directory, but nothing started them.

2. **Missing systemd unit**: The generated `${PREFIX}docker.service` had hard dependencies:
   ```
   After=sysbox.service
   Requires=sysbox.service
   ```
   But this `sysbox.service` was never created — the .deb was only extracted for binaries, not installed via dpkg.

3. **Idle binaries**: sysbox-mgr and sysbox-fs need to be running before dockerd starts (they're daemons), but nothing launched them.

4. **Manual start also broken**: The `cmd_start()` function checked for system-wide sysbox processes via `pgrep`, expecting them to be managed by systemd, which didn't exist.

## Solution

Created a **bundled sysbox systemd service** (`${PREFIX}sysbox.service`) that:

### 1. New Derived Variable
Added `SYSBOX_SERVICE_NAME` to `derive_vars()`:
```bash
SYSBOX_SERVICE_NAME="${DOCKYARD_DOCKER_PREFIX}sysbox"
```

### 2. Bundled Sysbox Service (`cmd_enable()`)
Generates `${PREFIX}sysbox.service` that:
- Starts sysbox-mgr first
- Then starts sysbox-fs (depends on mgr)
- Uses bundled binaries from `${BIN_DIR}/`
- Stores data in `${DOCKYARD_ROOT}/sysbox/`
- Logs to `${LOG_DIR}/sysbox-{mgr,fs}.log`
- Tracks PIDs in `${RUN_DIR}/sysbox-{mgr,fs}.pid`

### 3. Updated Docker Service Dependencies
Changed docker service to depend on bundled sysbox:
```bash
After=${SYSBOX_SERVICE_NAME}.service
Requires=${SYSBOX_SERVICE_NAME}.service
```

### 4. Manual Start (`cmd_start()`)
Now starts bundled sysbox daemons directly:
- Creates `/run/sysbox` directory
- Starts sysbox-mgr with bundled binary
- Starts sysbox-fs with bundled binary
- Validates both are running before continuing
- Adds PIDs to cleanup handler

### 5. Manual Stop (`cmd_stop()`)
Stops daemons in reverse order:
```
dockerd → containerd → sysbox-fs → sysbox-mgr
```

### 6. Service Management (`cmd_enable/disable()`)
- `enable`: Installs and enables both sysbox and docker services
- `disable`: Stops, disables, and removes both services

### 7. Status Display (`cmd_status()`)
Shows status of both services:
- systemd service states
- PID checks for sysbox-mgr, sysbox-fs, containerd, dockerd

### 8. Cleanup (`cmd_destroy()`)
- Stops both services (or daemons if no systemd)
- Removes sysbox data directory `${DOCKYARD_ROOT}/sysbox/`
- Removes both service files

### 9. Conflict Detection (`check_prefix_conflict()`)
Added sysbox service conflict check to prevent prefix collisions.

## Architecture

### Startup Sequence
```
systemd starts ${PREFIX}sysbox.service
  └─ sysbox-mgr starts (manages container creation)
       └─ sysbox-fs starts (manages container filesystems)
            └─ systemd starts ${PREFIX}docker.service
                 └─ containerd starts
                      └─ dockerd starts
```

### Service Dependency Chain
```
${PREFIX}sysbox.service (manages bundled sysbox daemons)
  ↓ (Requires=)
${PREFIX}docker.service (manages containerd + dockerd)
```

### Directory Structure (per instance, historical — superseded by FHS layout)
```
${DOCKYARD_ROOT}/
├── bin/                     # dockerd, containerd, sysbox-mgr, sysbox-fs, sysbox-runc, docker
├── etc/                     # daemon.json, dockyard.env
├── lib/
│   ├── docker/              # Docker data
│   ├── sysbox/              # Sysbox data-root + mountpoint
│   └── docker-config/       # DOCKER_CONFIG
├── log/                     # containerd.log, dockerd.log, sysbox-mgr.log, sysbox-fs.log
└── run/
    ├── docker.sock
    ├── dockerd.pid
    ├── containerd/
    │   └── containerd.sock
    └── sysbox/              # sysmgr.sock, sysfs.sock, sysbox-mgr.pid, sysbox-fs.pid

/etc/systemd/system/
└── ${PREFIX}docker.service  # no shared sysbox service
```

## Testing

To verify the fix works:

### 1. Fresh Install
```bash
./dockyard.sh gen-env
sudo ./dockyard.sh create
```

Check that both services are running:
```bash
systemctl status dy_sysbox
systemctl status dy_docker
```

### 2. Manual Start (no systemd)
```bash
./dockyard.sh gen-env
sudo ./dockyard.sh create --no-systemd --no-start
sudo ./dockyard.sh start
./dockyard.sh status
```

Should show all 4 daemons running:
- sysbox-mgr
- sysbox-fs
- containerd
- dockerd

### 3. Container Test
```bash
DOCKER_HOST=unix:///dockyard/docker.sock docker run --rm alpine echo "Hello from sysbox!"
```

Should successfully run container with sysbox-runc runtime.

### 4. Cleanup
```bash
sudo ./dockyard.sh destroy
```

Should remove both services and all data directories.

## Benefits

1. **Self-contained**: Each dockyard instance has its own isolated sysbox installation
2. **No system dependencies**: Doesn't require system-wide sysbox.service
3. **Multiple instances**: Different prefixes can run side-by-side without conflict
4. **Proper lifecycle**: sysbox daemons start/stop with docker service
5. **Clean separation**: Each instance's sysbox data is isolated in its own directory

## Backward Compatibility

This is a **breaking change** for existing installations that assumed system-wide sysbox.

Existing installations will need to:
1. Run `sudo ./dockyard.sh disable` to remove old service
2. Re-run `sudo ./dockyard.sh enable` to create new bundled sysbox service
3. Or do a full `destroy` and `create` cycle
