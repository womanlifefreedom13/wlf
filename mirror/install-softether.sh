#!/usr/bin/env bash
# Run on server as root.
# Installs SoftEther VPN Server from local tarball in the nginx mirror.
# Usage: LOCAL_MIRROR_URL=http://localhost:8080 bash install-softether.sh

set -euo pipefail

[[ $EUID -ne 0 ]] && echo "Run as root" && exit 1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; PLAIN='\033[0m'
info()  { echo -e "${GREEN}[INFO]${PLAIN} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${PLAIN} $*"; }
error() { echo -e "${RED}[ERROR]${PLAIN} $*" >&2; exit 1; }

LOCAL_MIRROR_URL="${LOCAL_MIRROR_URL:-http://localhost:8080}"
SE_MIRROR="${LOCAL_MIRROR_URL}/softether"
INSTALL_DIR="/opt/softether-vpnserver"
WORK_DIR="/tmp/softether-install"

# Step 1: Dependencies from Arvan apt mirror
info "Installing SoftEther build dependencies from apt..."
apt-get update -y
apt-get install -y \
    libssl-dev \
    libreadline-dev \
    libncurses-dev \
    zlib1g-dev \
    make \
    gcc

# Step 2: Get tarball filename from mirror metadata
curl -sf "${SE_MIRROR}/" -o /dev/null || \
    error "Cannot reach local mirror at ${SE_MIRROR}. Run server-setup.sh first."

FILENAME=$(curl -fsSL "${SE_MIRROR}/filename.txt" 2>/dev/null | tr -d '[:space:]' || true)
VERSION=$(curl -fsSL "${SE_MIRROR}/version.txt"   2>/dev/null | tr -d '[:space:]' || true)

# Fallback: auto-discover from autoindex HTML
if [[ -z "$FILENAME" ]]; then
    warn "filename.txt not found; auto-discovering from mirror index..."
    FILENAME=$(curl -fsSL "${SE_MIRROR}/" \
        | grep -oE 'href="[^"]*vpnserver[^"]*linux-x64-64bit\.tar\.gz"' \
        | sed 's/href="//;s/"//' \
        | head -1)
fi
[[ -z "$FILENAME" ]] && error "Cannot determine SoftEther tarball filename"
info "SoftEther tarball: ${FILENAME} (${VERSION})"

# Step 3: Download from local mirror
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

info "Downloading ${FILENAME}..."
wget -q --show-progress -O "${WORK_DIR}/${FILENAME}" "${SE_MIRROR}/${FILENAME}"

# Step 4: Extract
info "Extracting..."
tar -xzf "${WORK_DIR}/${FILENAME}" -C "$WORK_DIR"
EXTRACTED_DIR=$(tar -tzf "${WORK_DIR}/${FILENAME}" | head -1 | cut -d/ -f1)
[[ -z "$EXTRACTED_DIR" ]] && error "Could not determine extracted directory name"

# Step 5: Run SoftEther installer (prebuilt tarball — no compilation)
cd "${WORK_DIR}/${EXTRACTED_DIR}"
info "Running SoftEther installer (non-interactive)..."
printf '1\n1\n1\n' | make install 2>&1 | tail -20

# Step 6: Copy to /opt for clean layout and systemd service
info "Installing to ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"
cp -r "${WORK_DIR}/${EXTRACTED_DIR}"/. "$INSTALL_DIR/"
chmod +x "${INSTALL_DIR}/vpnserver"

# Step 7: Create systemd service
info "Creating systemd service..."
cat > /etc/systemd/system/softether-vpnserver.service << 'EOF'
[Unit]
Description=SoftEther VPN Server
After=network.target

[Service]
Type=forking
ExecStart=/opt/softether-vpnserver/vpnserver start
ExecStop=/opt/softether-vpnserver/vpnserver stop
KillMode=process
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable softether-vpnserver

# Cleanup
rm -rf "$WORK_DIR"

echo ""
info "SoftEther VPN Server ${VERSION} installed."
info "Start:   systemctl start softether-vpnserver"
info "Status:  systemctl status softether-vpnserver"
info "CLI:     /opt/softether-vpnserver/vpncmd"
info "Web mgr: https://$(hostname -I | awk '{print $1}'):5555/"
