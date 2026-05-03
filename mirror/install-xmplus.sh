#!/usr/bin/env bash
# Run on server as root.
# Installs XMPlus from the local nginx mirror.
# Usage: LOCAL_MIRROR_URL=http://localhost:8080 bash install-xmplus.sh

set -euo pipefail

[[ $EUID -ne 0 ]] && echo "Run as root" && exit 1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; PLAIN='\033[0m'
info()  { echo -e "${GREEN}[INFO]${PLAIN} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${PLAIN} $*"; }
error() { echo -e "${RED}[ERROR]${PLAIN} $*" >&2; exit 1; }

LOCAL_MIRROR_URL="${LOCAL_MIRROR_URL:-http://localhost:8080}"
XMPLUS_MIRROR="${LOCAL_MIRROR_URL}/xmplus"

# Dependencies from Arvan apt mirror
info "Installing dependencies from apt..."
apt-get update -y
apt-get install -y wget curl unzip tar cron socat

# Verify mirror
curl -sf "${XMPLUS_MIRROR}/" -o /dev/null || \
    error "Cannot reach local mirror at ${XMPLUS_MIRROR}. Run server-setup.sh first."

VERSION=$(curl -fsSL "${XMPLUS_MIRROR}/version.txt" | tr -d '[:space:]')
[[ -z "$VERSION" ]] && error "Cannot read version.txt from mirror"
info "Installing XMPlus ${VERSION}"

# Stop existing service
if systemctl is-active --quiet XMPlus 2>/dev/null; then
    info "Stopping existing XMPlus service..."
    systemctl stop XMPlus
fi

# Clean previous install
rm -rf /usr/local/XMPlus
rm -f /usr/bin/XMPlus /usr/bin/xmplus

# Download and extract
mkdir -p /usr/local/XMPlus
cd /usr/local/XMPlus

info "Downloading XMPlus-linux-64.zip from local mirror..."
wget -q -O /usr/local/XMPlus/XMPlus-linux.zip "${XMPLUS_MIRROR}/XMPlus-linux-64.zip"

info "Extracting..."
unzip -o XMPlus-linux.zip
rm -f XMPlus-linux.zip
chmod +x XMPlus

# Install systemd service
info "Installing systemd service..."
wget -q -O /etc/systemd/system/XMPlus.service "${XMPLUS_MIRROR}/XMPlus.service"
systemctl daemon-reload
systemctl enable XMPlus

# Install management script
info "Installing management script -> /usr/bin/XMPlus"
wget -q -O /usr/bin/XMPlus "${XMPLUS_MIRROR}/XMPlus.sh"
chmod +x /usr/bin/XMPlus
ln -sf /usr/bin/XMPlus /usr/bin/xmplus

# Copy config files (only if not already present)
mkdir -p /etc/XMPlus
for f in geoip.dat geosite.dat dns.json route.json outbound.json inbound.json rulelist config.yml; do
    [[ -f "/usr/local/XMPlus/${f}" ]] && [[ ! -f "/etc/XMPlus/${f}" ]] && \
        cp "/usr/local/XMPlus/${f}" "/etc/XMPlus/${f}" && \
        info "  Copied ${f}"
done

echo ""
info "XMPlus ${VERSION} installed."
info "Edit /etc/XMPlus/config.yml before starting."
info "Start:  systemctl start XMPlus"
info "Manage: XMPlus {start|stop|restart|status|log}"
