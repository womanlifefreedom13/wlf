#!/usr/bin/env bash
# Run on Mac. Transfers packages/ and server scripts to the Iranian server.
# Usage: ./mac-transfer.sh <SERVER_IP> [SERVER_USER] [SSH_PORT]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_DIR="${SCRIPT_DIR}/packages"

SERVER_IP="${1:?Usage: $0 <SERVER_IP> [SERVER_USER] [SSH_PORT]}"
SERVER_USER="${2:-root}"
SSH_PORT="${3:-22}"

RED='\033[0;31m'; GREEN='\033[0;32m'; PLAIN='\033[0m'
info()  { echo -e "${GREEN}[INFO]${PLAIN} $*"; }
error() { echo -e "${RED}[ERROR]${PLAIN} $*" >&2; exit 1; }

[[ -d "$PACKAGES_DIR" ]] || \
    error "packages/ directory not found. Run mac-download.sh first."

SSH_OPTS="-p ${SSH_PORT} -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"

info "Testing SSH to ${SERVER_USER}@${SERVER_IP}:${SSH_PORT} ..."
ssh $SSH_OPTS "${SERVER_USER}@${SERVER_IP}" "echo 'SSH OK'" || \
    error "SSH failed. Check IP, user, and port."

info "Creating /tmp/wlf-mirror on server..."
ssh $SSH_OPTS "${SERVER_USER}@${SERVER_IP}" "mkdir -p /tmp/wlf-mirror/packages"

info "Syncing packages/ -> server:/tmp/wlf-mirror/packages/ ..."
rsync -avz --progress \
    -e "ssh ${SSH_OPTS}" \
    "${PACKAGES_DIR}/" \
    "${SERVER_USER}@${SERVER_IP}:/tmp/wlf-mirror/packages/"

info "Syncing server scripts..."
rsync -avz --progress \
    -e "ssh ${SSH_OPTS}" \
    "${SCRIPT_DIR}/server-setup.sh" \
    "${SCRIPT_DIR}/nginx-mirror.conf" \
    "${SCRIPT_DIR}/install-xmplus.sh" \
    "${SCRIPT_DIR}/install-amneziawg.sh" \
    "${SCRIPT_DIR}/install-softether.sh" \
    "${SERVER_USER}@${SERVER_IP}:/tmp/wlf-mirror/"

info "Making scripts executable..."
ssh $SSH_OPTS "${SERVER_USER}@${SERVER_IP}" "chmod +x /tmp/wlf-mirror/*.sh"

echo ""
info "Transfer complete."
info ""
info "On the server, run as root:"
info "  bash /tmp/wlf-mirror/server-setup.sh"
info "Then install each tool:"
info "  bash /tmp/wlf-mirror/install-xmplus.sh"
info "  bash /tmp/wlf-mirror/install-amneziawg.sh"
info "  bash /tmp/wlf-mirror/install-softether.sh"
