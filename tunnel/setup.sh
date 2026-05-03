#!/usr/bin/env bash
# Setup script for Ubuntu 24.04 — installs Python deps for the tunnel.
set -e

if ! command -v python3 &>/dev/null; then
    echo "python3 not found — installing..."
    sudo apt-get update -q && sudo apt-get install -y python3 python3-pip python3-venv
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 -m venv "$SCRIPT_DIR/.venv"
source "$SCRIPT_DIR/.venv/bin/activate"
pip install --upgrade pip -q
pip install -r "$SCRIPT_DIR/requirements.txt" -q

echo ""
echo "Setup complete. Activate the venv with:"
echo "  source $SCRIPT_DIR/.venv/bin/activate"
echo ""
echo "Usage:"
echo "  # Iran side:"
echo "  python -m tunnel entry --config settings.json"
echo ""
echo "  # Free-internet side:"
echo "  python -m tunnel exit --config settings.json"
echo ""
echo "  # Or load config from GitHub:"
echo "  python -m tunnel entry --config https://raw.githubusercontent.com/USER/REPO/main/settings.json"
