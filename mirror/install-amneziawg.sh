#!/usr/bin/env bash
# Run on server as root.
# Installs AmneziaWG from local .deb files in the nginx mirror.
# Kernel headers come from Arvan apt mirror; .deb packages come from local mirror.
# Usage: LOCAL_MIRROR_URL=http://localhost:8080 bash install-amneziawg.sh

set -euo pipefail

[[ $EUID -ne 0 ]] && echo "Run as root" && exit 1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; PLAIN='\033[0m'
info()  { echo -e "${GREEN}[INFO]${PLAIN} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${PLAIN} $*"; }
error() { echo -e "${RED}[ERROR]${PLAIN} $*" >&2; exit 1; }

LOCAL_MIRROR_URL="${LOCAL_MIRROR_URL:-http://localhost:8080}"
AWG_MIRROR="${LOCAL_MIRROR_URL}/amneziawg"
WORK_DIR="/tmp/amneziawg-install"

# Step 1: System dependencies from Arvan apt mirror
info "Installing kernel headers and DKMS from apt (Arvan mirror)..."
apt-get update -y
apt-get install -y \
    "linux-headers-$(uname -r)" \
    dkms \
    build-essential \
    wireguard-tools \
    iproute2

# Step 2: Verify mirror
curl -sf "${AWG_MIRROR}/" -o /dev/null || \
    error "Cannot reach local mirror at ${AWG_MIRROR}. Run server-setup.sh first."

# Step 3: Discover and download .deb files from mirror autoindex
mkdir -p "$WORK_DIR"

info "Discovering .deb packages in local mirror..."
DEB_FILES=$(curl -fsSL "${AWG_MIRROR}/" \
    | grep -oE 'href="[^"]*\.deb"' \
    | sed 's/href="//;s/"//')

[[ -z "$DEB_FILES" ]] && error "No .deb files found at ${AWG_MIRROR}"

for deb in $DEB_FILES; do
    filename=$(basename "$deb")
    info "  Downloading: ${filename}"
    wget -q -O "${WORK_DIR}/${filename}" "${AWG_MIRROR}/${filename}"
done

# Step 4: Install in correct order (dkms first, then tools)
DKMS_DEB=$(ls "${WORK_DIR}/"*dkms*.deb 2>/dev/null | head -1 || true)
TOOLS_DEB=$(ls "${WORK_DIR}/"*tools*.deb 2>/dev/null | head -1 || true)

if [[ -n "$DKMS_DEB" ]]; then
    info "Installing DKMS package: $(basename "$DKMS_DEB")"
    dpkg -i "$DKMS_DEB" || apt-get install -f -y
fi

if [[ -n "$TOOLS_DEB" ]]; then
    info "Installing tools package: $(basename "$TOOLS_DEB")"
    dpkg -i "$TOOLS_DEB" || apt-get install -f -y
fi

# Install any remaining .deb files
for deb in "${WORK_DIR}/"*.deb; do
    [[ "$deb" == "${DKMS_DEB:-}" ]] && continue
    [[ "$deb" == "${TOOLS_DEB:-}" ]] && continue
    [[ -f "$deb" ]] || continue
    info "Installing: $(basename "$deb")"
    dpkg -i "$deb" || apt-get install -f -y
done

rm -rf "$WORK_DIR"

# Step 5: Verify
echo ""
if command -v awg &>/dev/null; then
    info "awg installed: $(awg --version 2>/dev/null || echo 'ok')"
else
    warn "awg not in PATH yet — relogin or check: dpkg -l | grep amneziawg"
fi

if lsmod | grep -q amneziawg 2>/dev/null; then
    info "AmneziaWG kernel module is loaded"
else
    info "Module not loaded yet — will load when an interface is brought up."
    info "Force load: modprobe amneziawg"
fi

echo ""
info "AmneziaWG installation complete."
info "Config directory: /etc/amnezia/amneziawg/"
info "Commands: awg, awg-quick up <config>"
