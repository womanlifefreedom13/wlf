#!/usr/bin/env bash
# Run on Mac. Downloads latest binaries for XMPlus, AmneziaWG, SoftEther.
# Requirements: curl, gunzip (built-in on Mac).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_DIR="${SCRIPT_DIR}/packages"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; PLAIN='\033[0m'
info()  { echo -e "${GREEN}[INFO]${PLAIN} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${PLAIN} $*"; }
error() { echo -e "${RED}[ERROR]${PLAIN} $*" >&2; exit 1; }

if command -v jq &>/dev/null; then
    JQ=1
else
    warn "jq not found; using grep/sed fallback"
    JQ=0
fi

gh_latest_tag() {
    local repo="$1"
    local json
    json=$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest")
    if [ "$JQ" -eq 1 ]; then
        echo "$json" | jq -r '.tag_name'
    else
        echo "$json" | grep '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/'
    fi
}

gh_tag_fallback() {
    local repo="$1"
    curl -fsLS -o /dev/null -w '%{url_effective}' \
        "https://github.com/${repo}/releases/latest" \
        | grep -oE 'tag/[^/]+$' | sed 's|tag/||'
}

# ─── 1. XMPlus ───────────────────────────────────────────────────────────────
download_xmplus() {
    info "=== Downloading XMPlus (linux amd64) ==="
    local dir="${PACKAGES_DIR}/xmplus"
    mkdir -p "$dir"

    local tag
    tag=$(gh_latest_tag "XMPlusDev/XMPlus") || true
    if [[ -z "$tag" || "$tag" == "null" ]]; then
        warn "GitHub API failed; using redirect fallback"
        tag=$(gh_tag_fallback "XMPlusDev/XMPlus")
    fi
    [[ -z "$tag" ]] && error "Could not determine XMPlus version"
    info "XMPlus latest: $tag"

    local zip_url="https://github.com/XMPlusDev/XMPlus/releases/download/${tag}/XMPlus-linux-64.zip"
    info "Downloading XMPlus binary zip..."
    curl -fL --retry 3 --retry-delay 2 -o "${dir}/XMPlus-linux-64.zip" "$zip_url"

    info "Downloading XMPlus.service..."
    curl -fL --retry 3 --retry-delay 2 \
        -o "${dir}/XMPlus.service" \
        "https://raw.githubusercontent.com/XMPlusDev/XMPlus/scripts/XMPlus.service"

    info "Downloading XMPlus.sh (management script)..."
    curl -fL --retry 3 --retry-delay 2 \
        -o "${dir}/XMPlus.sh" \
        "https://raw.githubusercontent.com/XMPlusDev/XMPlus/scripts/XMPlus.sh"

    echo "$tag" > "${dir}/version.txt"
    info "XMPlus done (${tag})"
}

# ─── 2. AmneziaWG ────────────────────────────────────────────────────────────
download_amneziawg() {
    info "=== Downloading AmneziaWG .deb packages (Ubuntu 24.04 Noble) ==="
    local dir="${PACKAGES_DIR}/amneziawg"
    mkdir -p "$dir"

    local ppa_base="https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu"
    local suite="noble"

    for arch in amd64 all; do
        local pkg_gz_url="${ppa_base}/dists/${suite}/main/binary-${arch}/Packages.gz"
        info "Fetching PPA package index for arch=${arch}..."
        curl -fsSL --retry 3 --retry-delay 2 "$pkg_gz_url" \
            | gunzip > "${dir}/Packages-${arch}.txt"
    done

    local pkg_name="" pkg_file=""
    for arch in amd64 all; do
        while IFS= read -r line; do
            case "$line" in
                Package:*)  pkg_name="${line#Package: }" ;;
                Filename:*) pkg_file="${line#Filename: }" ;;
                "")
                    if [[ "${pkg_name:-}" == amneziawg* && -n "${pkg_file:-}" ]]; then
                        local deb_url="${ppa_base}/${pkg_file}"
                        local deb_name
                        deb_name=$(basename "$pkg_file")
                        if [[ ! -f "${dir}/${deb_name}" ]]; then
                            info "  Downloading: $deb_name"
                            curl -fL --retry 3 --retry-delay 2 \
                                -o "${dir}/${deb_name}" "$deb_url"
                        else
                            info "  Already exists: $deb_name"
                        fi
                    fi
                    pkg_name=""; pkg_file=""
                    ;;
            esac
        done < "${dir}/Packages-${arch}.txt"
    done

    local deb_count
    deb_count=$(ls "${dir}/"*.deb 2>/dev/null | wc -l)
    if [[ "$deb_count" -eq 0 ]]; then
        warn "No .deb files found — check PPA URL or suite name"
    else
        info "AmneziaWG done (${deb_count} .deb files)"
    fi
}

# ─── 3. SoftEther VPN ────────────────────────────────────────────────────────
download_softether() {
    info "=== Downloading SoftEther VPN Server (Linux x64) ==="
    local dir="${PACKAGES_DIR}/softether"
    mkdir -p "$dir"

    local tag
    tag=$(gh_latest_tag "SoftEtherVPN/SoftEtherVPN_Stable") || true
    if [[ -z "$tag" || "$tag" == "null" ]]; then
        warn "GitHub API failed; using redirect fallback"
        tag=$(gh_tag_fallback "SoftEtherVPN/SoftEtherVPN_Stable")
    fi
    [[ -z "$tag" ]] && error "Could not determine SoftEther version"
    info "SoftEther latest: $tag"

    # Discover exact tarball filename (contains build date) via expanded_assets
    local assets_html
    assets_html=$(curl -fsSL \
        "https://github.com/SoftEtherVPN/SoftEtherVPN_Stable/releases/expanded_assets/${tag}")

    local asset_path
    asset_path=$(echo "$assets_html" \
        | grep -oE '"[^"]*vpnserver[^"]*linux-x64-64bit\.tar\.gz"' \
        | tr -d '"' \
        | head -1)
    [[ -z "$asset_path" ]] && error "Could not find SoftEther linux-x64 asset for ${tag}"

    local dl_url="https://github.com${asset_path}"
    local filename
    filename=$(basename "$asset_path")

    info "Downloading ${filename}..."
    curl -fL --retry 3 --retry-delay 2 \
        --progress-bar \
        -o "${dir}/${filename}" "$dl_url"

    echo "$filename" > "${dir}/filename.txt"
    echo "$tag"      > "${dir}/version.txt"
    info "SoftEther done (${filename})"
}

# ─── Main ────────────────────────────────────────────────────────────────────
mkdir -p "${PACKAGES_DIR}"
download_xmplus
echo ""
download_amneziawg
echo ""
download_softether

echo ""
info "All downloads complete."
info "Files in ${PACKAGES_DIR}:"
find "${PACKAGES_DIR}" -type f | sort
echo ""
info "Next step: run  mirror/mac-transfer.sh <SERVER_IP> [USER] [PORT]"
