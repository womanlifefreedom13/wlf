#!/usr/bin/env bash
# Run on server as root.
# Sets up /opt/local-mirror/ and enables nginx on port 8080 as a local file mirror.

set -euo pipefail

[[ $EUID -ne 0 ]] && echo "Run as root" && exit 1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; PLAIN='\033[0m'
info()  { echo -e "${GREEN}[INFO]${PLAIN} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${PLAIN} $*"; }
error() { echo -e "${RED}[ERROR]${PLAIN} $*" >&2; exit 1; }

PACKAGES_SRC="/tmp/wlf-mirror/packages"
MIRROR_ROOT="/opt/local-mirror"
NGINX_CONF_SRC="/tmp/wlf-mirror/nginx-mirror.conf"
NGINX_CONF_DEST="/etc/nginx/sites-available/local-mirror"
NGINX_ENABLED="/etc/nginx/sites-enabled/local-mirror"

command -v nginx &>/dev/null || error "nginx is not installed."

# Create mirror directory structure
info "Creating ${MIRROR_ROOT}/ ..."
mkdir -p "${MIRROR_ROOT}/xmplus"
mkdir -p "${MIRROR_ROOT}/amneziawg"
mkdir -p "${MIRROR_ROOT}/softether"

# Copy packages
info "Copying XMPlus files..."
cp -v "${PACKAGES_SRC}/xmplus/"* "${MIRROR_ROOT}/xmplus/" 2>/dev/null || \
    warn "No XMPlus files found in ${PACKAGES_SRC}/xmplus/"

info "Copying AmneziaWG .deb files..."
cp -v "${PACKAGES_SRC}/amneziawg/"*.deb "${MIRROR_ROOT}/amneziawg/" 2>/dev/null || \
    warn "No AmneziaWG .deb files found"

info "Copying SoftEther files..."
for f in "${PACKAGES_SRC}/softether/"*.tar.gz \
          "${PACKAGES_SRC}/softether/filename.txt" \
          "${PACKAGES_SRC}/softether/version.txt"; do
    [[ -f "$f" ]] && cp -v "$f" "${MIRROR_ROOT}/softether/"
done

# Set permissions
chown -R www-data:www-data "${MIRROR_ROOT}" 2>/dev/null || true
chmod -R 755 "${MIRROR_ROOT}"

# Install nginx config
info "Installing nginx site config -> ${NGINX_CONF_DEST}"
cp "$NGINX_CONF_SRC" "$NGINX_CONF_DEST"
ln -sfn "$NGINX_CONF_DEST" "$NGINX_ENABLED"

# Test and reload nginx
info "Testing nginx config..."
nginx -t || error "nginx config test failed. Check ${NGINX_CONF_DEST}"

info "Reloading nginx..."
systemctl reload nginx

sleep 1
if curl -sf "http://localhost:8080/" -o /dev/null; then
    info "Mirror is UP at http://localhost:8080/"
else
    warn "Could not reach http://localhost:8080/ — check: journalctl -u nginx -n 20"
fi

echo ""
info "Mirror directory contents:"
find "${MIRROR_ROOT}" -type f | sort
echo ""
info "Mirror URLs:"
info "  http://localhost:8080/xmplus/"
info "  http://localhost:8080/amneziawg/"
info "  http://localhost:8080/softether/"
echo ""
info "Setup done. Now run the install scripts."
