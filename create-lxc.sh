#!/usr/bin/env bash
#
# create-lxc.sh — Creates and configures a Proxmox LXC container for Lingarr
# Run this on the Proxmox host.
#
set -euo pipefail

# =============================================================================
# Configuration — adjust these variables to your environment
# =============================================================================
CTID="${CTID:-}"                          # Empty = auto-detect next available
HOSTNAME="${HOSTNAME:-lingarr}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
MEMORY="${MEMORY:-2048}"
CORES="${CORES:-2}"
DISK_SIZE="${DISK_SIZE:-8}"
NET_BRIDGE="${NET_BRIDGE:-vmbr0}"
IP_ADDRESS="${IP_ADDRESS:-dhcp}"          # e.g. "192.168.1.50/24,gw=192.168.1.1" or "dhcp"
DEPLOY_SCRIPT="${DEPLOY_SCRIPT:-$(dirname "$(readlink -f "$0")")/deploy.sh}"

# Media mount points — comma-separated list of host_path:container_path
# Example: MOUNTS="/mnt/media/media:/media,/mnt/media2/media:/media2"
MOUNTS="${MOUNTS:-}"

# =============================================================================
# Helpers
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()  { err "$@"; exit 1; }

# =============================================================================
# Preflight checks
# =============================================================================
command -v pveversion &>/dev/null || die "This script must run on a Proxmox VE host."
[[ $(id -u) -eq 0 ]] || die "This script must run as root."

if [[ -z "$MOUNTS" ]]; then
    die "MOUNTS must be set.\n  Usage: MOUNTS=\"/mnt/media/media:/media,/mnt/media2/media:/media2\" bash $0\n  Format: comma-separated host_path:container_path pairs"
fi

[[ -f "$DEPLOY_SCRIPT" ]] || die "deploy.sh not found at: $DEPLOY_SCRIPT"

# Parse and validate mount points
IFS=',' read -ra MOUNT_PAIRS <<< "$MOUNTS"
MOUNT_PATHS=()  # Container paths for passing to deploy.sh

for pair in "${MOUNT_PAIRS[@]}"; do
    host_path="${pair%%:*}"
    container_path="${pair##*:}"

    [[ "$pair" == *":"* ]] || die "Invalid mount format '$pair'. Expected host_path:container_path"
    [[ -d "$host_path" ]]  || die "Host path does not exist: $host_path"

    MOUNT_PATHS+=("$container_path")
    log "Mount: $host_path -> $container_path"
done

# =============================================================================
# Auto-detect next available CTID
# =============================================================================
if [[ -z "$CTID" ]]; then
    CTID=$(pvesh get /cluster/nextid)
    log "Auto-detected CTID: $CTID"
fi

# =============================================================================
# Download Debian 12 template if missing
# =============================================================================
TEMPLATE_NAME=$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | sort -V | tail -1)
if [[ -z "$TEMPLATE_NAME" ]]; then
    die "Could not find Debian 12 template in available list. Run: pveam update"
fi

TEMPLATE_PATH="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"
if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE_NAME"; then
    log "Downloading template: $TEMPLATE_NAME ..."
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"
else
    log "Template already available: $TEMPLATE_NAME"
fi

# =============================================================================
# Build network config string
# =============================================================================
if [[ "$IP_ADDRESS" == "dhcp" ]]; then
    NET_CONFIG="name=eth0,bridge=${NET_BRIDGE},ip=dhcp"
else
    NET_CONFIG="name=eth0,bridge=${NET_BRIDGE},ip=${IP_ADDRESS}"
fi

# =============================================================================
# Create the LXC container
# =============================================================================
log "Creating LXC container $CTID ($HOSTNAME) ..."
pct create "$CTID" "$TEMPLATE_PATH" \
    --hostname "$HOSTNAME" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --rootfs "${STORAGE}:${DISK_SIZE}" \
    --net0 "$NET_CONFIG" \
    --features nesting=1 \
    --unprivileged 0 \
    --start 0

# =============================================================================
# Configure bind mounts for media
# =============================================================================
log "Configuring media bind mounts ..."
for i in "${!MOUNT_PAIRS[@]}"; do
    pair="${MOUNT_PAIRS[$i]}"
    host_path="${pair%%:*}"
    container_path="${pair##*:}"
    pct set "$CTID" -mp"$i" "${host_path},mp=${container_path}"
done

# =============================================================================
# Start the container
# =============================================================================
log "Starting container $CTID ..."
pct start "$CTID"

# Wait for container to be fully running
log "Waiting for container to be ready ..."
for i in $(seq 1 30); do
    if pct status "$CTID" | grep -q "running"; then
        break
    fi
    sleep 1
done
sleep 3  # Extra time for network initialization

# =============================================================================
# Push and execute deploy script
# =============================================================================
log "Pushing deploy.sh into container ..."
pct push "$CTID" "$DEPLOY_SCRIPT" /root/deploy.sh --perms 755

# Pass media mount paths to deploy.sh so it can configure systemd ReadWritePaths
MEDIA_PATHS=$(IFS=','; echo "${MOUNT_PATHS[*]}")

log "Running deploy.sh inside container (this will take several minutes) ..."
pct exec "$CTID" -- bash /root/deploy.sh --media-paths "$MEDIA_PATHS"

# =============================================================================
# Print access info
# =============================================================================
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  Lingarr LXC Container Ready!${NC}"
echo -e "${CYAN}========================================${NC}"
echo -e "  CTID:      ${GREEN}$CTID${NC}"
echo -e "  Hostname:  ${GREEN}$HOSTNAME${NC}"

# Try to get the container IP
CONTAINER_IP=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
if [[ "$CONTAINER_IP" != "unknown" && -n "$CONTAINER_IP" ]]; then
    echo -e "  IP:        ${GREEN}$CONTAINER_IP${NC}"
    echo -e "  URL:       ${GREEN}http://${CONTAINER_IP}:9876${NC}"
else
    echo -e "  IP:        ${YELLOW}Could not detect — check with: pct exec $CTID -- hostname -I${NC}"
fi

echo ""
echo -e "  Mounts:"
for pair in "${MOUNT_PAIRS[@]}"; do
    echo -e "    ${GREEN}${pair%%:*}${NC} -> ${GREEN}${pair##*:}${NC}"
done

echo ""
echo -e "  Manage:    ${CYAN}pct exec $CTID -- bash${NC}"
echo -e "  Logs:      ${CYAN}pct exec $CTID -- journalctl -u lingarr -f${NC}"
echo -e "  Status:    ${CYAN}pct exec $CTID -- systemctl status lingarr${NC}"
echo -e "  Update:    ${CYAN}pct exec $CTID -- bash /opt/lingarr/source/scripts/lxc/update.sh${NC}"
echo -e "${CYAN}========================================${NC}"
