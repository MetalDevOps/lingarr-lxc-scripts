#!/usr/bin/env bash
#
# update.sh — Updates Lingarr to the latest version with minimal downtime
# Run this inside the LXC container (as root).
#
# Strategy: build first, atomic swap, ~5s downtime
#
set -euo pipefail

LINGARR_HOME="/opt/lingarr"
LINGARR_USER="lingarr"
REPO_BRANCH="main"
BACKUP_KEEP=5

# =============================================================================
# Helpers
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()  { err "$@"; exit 1; }

# =============================================================================
# Preflight
# =============================================================================
[[ $(id -u) -eq 0 ]] || die "This script must run as root."
[[ -d "$LINGARR_HOME/source/.git" ]] || die "Source directory not found. Run deploy.sh first."
[[ -d "$LINGARR_HOME/publish" ]] || die "Publish directory not found. Run deploy.sh first."

# =============================================================================
# Step 1: Backup config
# =============================================================================
BACKUP_NAME="config-$(date +%Y%m%d-%H%M%S)"
log "Backing up config to $LINGARR_HOME/backups/$BACKUP_NAME ..."
cp -a "$LINGARR_HOME/config" "$LINGARR_HOME/backups/$BACKUP_NAME"

# Clean old backups (keep most recent $BACKUP_KEEP)
cd "$LINGARR_HOME/backups"
BACKUP_COUNT=$(ls -1d config-* 2>/dev/null | wc -l)
if [[ "$BACKUP_COUNT" -gt "$BACKUP_KEEP" ]]; then
    REMOVE_COUNT=$((BACKUP_COUNT - BACKUP_KEEP))
    log "Cleaning $REMOVE_COUNT old backup(s) ..."
    ls -1d config-* | head -n "$REMOVE_COUNT" | xargs rm -rf
fi

# =============================================================================
# Step 2: Pull latest code
# =============================================================================
log "Pulling latest code ..."
cd "$LINGARR_HOME/source"
git fetch --all
git reset --hard "origin/$REPO_BRANCH"

# =============================================================================
# Step 3: Rebuild frontend (old version still running)
# =============================================================================
log "Building frontend ..."
cd "$LINGARR_HOME/source/Lingarr.Client"
npm ci --loglevel=warn
npm run build

# Copy frontend dist to wwwroot
log "Copying frontend to wwwroot ..."
rm -rf "$LINGARR_HOME/source/Lingarr.Server/wwwroot"
mkdir -p "$LINGARR_HOME/source/Lingarr.Server/wwwroot"
cp -r "$LINGARR_HOME/source/Lingarr.Client/dist/"* "$LINGARR_HOME/source/Lingarr.Server/wwwroot/"

# =============================================================================
# Step 4: Publish to staging directory
# =============================================================================
log "Publishing backend to staging directory ..."
rm -rf "$LINGARR_HOME/publish-new"
cd "$LINGARR_HOME/source"
dotnet publish Lingarr.Server/Lingarr.Server.csproj \
    -c Release \
    -o "$LINGARR_HOME/publish-new" \
    /p:UseAppHost=false

# =============================================================================
# Step 5: Atomic swap
# =============================================================================
log "Stopping Lingarr service ..."
systemctl stop lingarr.service

log "Swapping publish directories ..."
rm -rf "$LINGARR_HOME/publish-old"
mv "$LINGARR_HOME/publish" "$LINGARR_HOME/publish-old"
mv "$LINGARR_HOME/publish-new" "$LINGARR_HOME/publish"

chown -R "$LINGARR_USER:$LINGARR_USER" "$LINGARR_HOME/publish"

log "Starting Lingarr service ..."
systemctl start lingarr.service

# =============================================================================
# Step 6: Verify
# =============================================================================
sleep 5

if systemctl is-active --quiet lingarr.service; then
    log "=== Update successful! Lingarr is running. ==="
    rm -rf "$LINGARR_HOME/publish-old"
else
    err "Service failed to start after update!"
    echo ""
    echo -e "${YELLOW}=== ROLLBACK INSTRUCTIONS ===${NC}"
    echo "  systemctl stop lingarr.service"
    echo "  mv $LINGARR_HOME/publish $LINGARR_HOME/publish-bad"
    echo "  mv $LINGARR_HOME/publish-old $LINGARR_HOME/publish"
    echo "  systemctl start lingarr.service"
    echo ""
    echo "Check logs: journalctl -u lingarr --no-pager -n 50"
    exit 1
fi

log "Update complete."
