#!/usr/bin/env bash
#
# deploy.sh — Installs and configures Lingarr inside an LXC container
# Run this inside the LXC container (as root). Idempotent.
#
set -euo pipefail

LINGARR_HOME="/opt/lingarr"
LINGARR_USER="lingarr"
REPO_URL="https://github.com/lingarr-translate/lingarr.git"
REPO_BRANCH="main"

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

# =============================================================================
# Phase 1: System packages
# =============================================================================
log "=== Phase 1: Installing system packages ==="

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

log "Installing base packages ..."
apt-get install -y -qq git curl wget ca-certificates apt-transport-https

# .NET 9.0 SDK
if ! command -v dotnet &>/dev/null; then
    log "Installing .NET 9.0 SDK ..."
    wget -q https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb
    dpkg -i /tmp/packages-microsoft-prod.deb
    rm -f /tmp/packages-microsoft-prod.deb
    apt-get update -qq
    apt-get install -y -qq dotnet-sdk-9.0
else
    log ".NET already installed: $(dotnet --version)"
fi

# Node.js 24
if ! command -v node &>/dev/null; then
    log "Installing Node.js 24 ..."
    curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
    apt-get install -y -qq nodejs
else
    log "Node.js already installed: $(node --version)"
fi

log "dotnet $(dotnet --version) | node $(node --version) | npm $(npm --version)"

# =============================================================================
# Phase 2: User and directories
# =============================================================================
log "=== Phase 2: Setting up user and directories ==="

if ! id "$LINGARR_USER" &>/dev/null; then
    useradd --system --shell /usr/sbin/nologin --home-dir "$LINGARR_HOME" "$LINGARR_USER"
    log "Created system user: $LINGARR_USER"
else
    log "User $LINGARR_USER already exists."
fi

mkdir -p "$LINGARR_HOME"/{source,publish,config,backups}
mkdir -p /etc/lingarr
mkdir -p /app

# Symlink for hardcoded /app/config path
ln -sfn "$LINGARR_HOME/config" /app/config
log "Symlink: /app/config -> $LINGARR_HOME/config"

# =============================================================================
# Phase 3: Build
# =============================================================================
log "=== Phase 3: Cloning and building ==="

# Clone or update repository
if [[ -d "$LINGARR_HOME/source/.git" ]]; then
    log "Repository exists, pulling latest ..."
    cd "$LINGARR_HOME/source"
    git fetch --all
    git reset --hard "origin/$REPO_BRANCH"
else
    log "Cloning repository ..."
    git clone --branch "$REPO_BRANCH" "$REPO_URL" "$LINGARR_HOME/source"
fi

# Build frontend
log "Building frontend ..."
cd "$LINGARR_HOME/source/Lingarr.Client"
npm ci --loglevel=warn
npm run build

# Copy frontend dist to backend wwwroot
log "Copying frontend to wwwroot ..."
rm -rf "$LINGARR_HOME/source/Lingarr.Server/wwwroot"
mkdir -p "$LINGARR_HOME/source/Lingarr.Server/wwwroot"
cp -r "$LINGARR_HOME/source/Lingarr.Client/dist/"* "$LINGARR_HOME/source/Lingarr.Server/wwwroot/"

# Publish backend
log "Publishing backend ..."
cd "$LINGARR_HOME/source"
dotnet publish Lingarr.Server/Lingarr.Server.csproj \
    -c Release \
    -o "$LINGARR_HOME/publish" \
    /p:UseAppHost=false

# Fix ownership
chown -R "$LINGARR_USER:$LINGARR_USER" "$LINGARR_HOME"

# =============================================================================
# Phase 4: Configuration
# =============================================================================
log "=== Phase 4: Configuration ==="

if [[ ! -f /etc/lingarr/lingarr.env ]]; then
    cat > /etc/lingarr/lingarr.env <<'ENVEOF'
# =============================================================================
# Lingarr Environment Configuration
# =============================================================================

# === Core ===
ASPNETCORE_URLS=http://+:9876
ASPNETCORE_ENVIRONMENT=Production

# === Database (sqlite by default, no additional config needed) ===
DB_CONNECTION=sqlite

# === Radarr/Sonarr Integration ===
# RADARR_URL=http://your-radarr:7878
# RADARR_API_KEY=
# SONARR_URL=http://your-sonarr:8989
# SONARR_API_KEY=

# === Translation Service ===
# SERVICE_TYPE=libretranslate
# LIBRE_TRANSLATE_URL=http://your-libretranslate:5000

# === Authentication ===
# AUTH_ENABLED=true

# === Workers ===
# MAX_CONCURRENT_JOBS=1
ENVEOF
    log "Created /etc/lingarr/lingarr.env"
else
    log "/etc/lingarr/lingarr.env already exists, preserving user edits."
fi

chmod 640 /etc/lingarr/lingarr.env
chown root:"$LINGARR_USER" /etc/lingarr/lingarr.env

# =============================================================================
# Phase 5: systemd service
# =============================================================================
log "=== Phase 5: Installing systemd service ==="

cat > /etc/systemd/system/lingarr.service <<'SVCEOF'
[Unit]
Description=Lingarr Subtitle Translation Service
After=network.target

[Service]
Type=simple
User=lingarr
Group=lingarr
WorkingDirectory=/opt/lingarr/publish
ExecStart=/usr/bin/dotnet /opt/lingarr/publish/Lingarr.Server.dll
EnvironmentFile=/etc/lingarr/lingarr.env
Restart=always
RestartSec=10
SyslogIdentifier=lingarr

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/lingarr/config /movies /tv
PrivateTmp=true
LimitNOFILE=65536
TimeoutStartSec=120
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now lingarr.service

# Wait a moment for the service to start
sleep 3

# =============================================================================
# Done
# =============================================================================
if systemctl is-active --quiet lingarr.service; then
    log "=== Lingarr is running! ==="
    systemctl status lingarr.service --no-pager || true
else
    warn "Service may still be starting. Check with: systemctl status lingarr"
    warn "Logs: journalctl -u lingarr -f"
fi

log "Deploy complete."
