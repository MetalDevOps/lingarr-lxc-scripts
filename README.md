# Lingarr LXC Deploy (Proxmox)

Deploy [Lingarr](https://github.com/lingarr-translate/lingarr) directly in a Proxmox LXC container, no Docker required.

## Requirements

- Proxmox VE 7.x or 8.x
- Root access on the Proxmox host
- Media folders accessible on the host

## Quick Start

```bash
MOUNTS="/mnt/media/media:/media" bash create-lxc.sh
```

This creates the container, installs all dependencies, builds Lingarr, and starts the service. The access URL (`http://<IP>:9876`) is printed at the end.

## Files

| File | Runs on | Description |
|------|---------|-------------|
| `create-lxc.sh` | Proxmox host | Creates and configures the LXC container |
| `deploy.sh` | Inside LXC | Installs dependencies, builds, and configures everything |
| `update.sh` | Inside LXC | Updates to the latest version |
| `lingarr.service` | Reference | systemd unit (installed automatically by deploy) |
| `lingarr.env` | Reference | Environment variables template |

## Media Mounts

Use the `MOUNTS` variable to bind-mount host directories into the container. Format: comma-separated `host_path:container_path` pairs.

**Single mount point:**

```bash
MOUNTS="/mnt/media/media:/media" bash create-lxc.sh
```

Inside the LXC: `/media/movies`, `/media/tv`

**Multiple mount points:**

```bash
MOUNTS="/mnt/media/media:/media,/mnt/media2/media:/media2" bash create-lxc.sh
```

Inside the LXC: `/media/movies`, `/media/tv`, `/media2/movies`, `/media2/tv`

These paths should match the root folders configured in Radarr/Sonarr.

## Container Configuration

`create-lxc.sh` accepts environment variables to customize the container:

| Variable | Default | Description |
|----------|---------|-------------|
| `CTID` | auto | Container ID |
| `HOSTNAME` | `lingarr` | Hostname |
| `STORAGE` | `local-lvm` | Storage pool for the root disk |
| `MEMORY` | `2048` | RAM in MB |
| `CORES` | `2` | CPU cores |
| `DISK_SIZE` | `8` | Root disk in GB |
| `NET_BRIDGE` | `vmbr0` | Network bridge |
| `IP_ADDRESS` | `dhcp` | Static IP (e.g. `192.168.1.50/24,gw=192.168.1.1`) or `dhcp` |
| `MOUNTS` | — | **Required.** Comma-separated `host_path:container_path` pairs |

Example with all options:

```bash
MOUNTS="/mnt/media/media:/media,/mnt/media2/media:/media2" \
IP_ADDRESS="192.168.1.50/24,gw=192.168.1.1" \
MEMORY=4096 \
bash create-lxc.sh
```

## Directory Structure Inside the LXC

```
/opt/lingarr/
├── source/          # Git repository clone
├── publish/         # Compiled application
├── config/          # Persistent data (SQLite databases)
└── backups/         # Config backups before updates

/app/config → /opt/lingarr/config/   # Compatibility symlink
/etc/lingarr/lingarr.env             # Configuration
/etc/lingarr/media-paths             # Saved media mount paths

/media                                # Bind mount from host (example)
/media2                               # Bind mount from host (example)
```

## Lingarr Configuration

Edit `/etc/lingarr/lingarr.env` inside the container to configure integrations:

```bash
pct exec <CTID> -- nano /etc/lingarr/lingarr.env
```

After editing, restart the service:

```bash
pct exec <CTID> -- systemctl restart lingarr
```

## Updating

```bash
pct exec <CTID> -- bash /opt/lingarr/source/scripts/lxc/update.sh
```

Or by entering the container:

```bash
pct enter <CTID>
bash /opt/lingarr/source/scripts/lxc/update.sh
```

The update builds everything before stopping the service, resulting in ~5 seconds of downtime. If the new version fails to start, rollback instructions are displayed automatically.

### Manual Rollback

```bash
systemctl stop lingarr.service
mv /opt/lingarr/publish /opt/lingarr/publish-bad
mv /opt/lingarr/publish-old /opt/lingarr/publish
systemctl start lingarr.service
```

## Useful Commands

```bash
# Service status
pct exec <CTID> -- systemctl status lingarr

# Live logs
pct exec <CTID> -- journalctl -u lingarr -f

# Restart
pct exec <CTID> -- systemctl restart lingarr

# Enter the container
pct enter <CTID>
```

## Notes

- The container is created as **privileged** to simplify media folder permissions.
- The SQLite database lives in `/opt/lingarr/config/` and persists across updates.
- The `/app/config` path is hardcoded in Lingarr — the symlink resolves this without modifying source code.
- Config backups are kept automatically (5 most recent) in `/opt/lingarr/backups/`.
- Media mount paths are saved to `/etc/lingarr/media-paths` and used to configure systemd `ReadWritePaths`.
