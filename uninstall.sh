#!/usr/bin/env bash
#
# uninstall.sh — Completely remove Escriba (whisper-dictation).
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { echo -e "${YELLOW}→${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }

INSTALL_DIR="$HOME/.local/share/whisper-dictation"
CONFIG_DIR="$HOME/.config/whisper-dictation"
BIN="$HOME/.local/bin/whisper-dictation"
PLIST_NAME="com.whisper-dictation.agent"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"

echo -e "${RED}This will remove Escriba and all downloaded models.${NC}"
echo "Config at ${CONFIG_DIR} will be preserved."
echo ""
read -rp "Continue? [y/N] " confirm
[[ "${confirm}" =~ ^[Yy]$ ]] || exit 0

# Stop and remove launchd agent
info "Stopping daemon..."
launchctl bootout "gui/$(id -u)/${PLIST_NAME}" 2>/dev/null || true
rm -f "${PLIST_PATH}"
ok "Daemon removed"

# Remove binary
info "Removing binary..."
rm -f "${BIN}"
ok "Binary removed"

# Remove .app bundle
info "Removing Escriba.app..."
rm -rf "/Applications/Escriba.app"
ok "App bundle removed"

# Remove install directory (whisper.cpp, llama.cpp, models, logs)
info "Removing ${INSTALL_DIR} ..."
rm -rf "${INSTALL_DIR}"
ok "Install directory removed"

echo ""
echo -e "${GREEN}Escriba uninstalled.${NC}"
echo "Config preserved at: ${CONFIG_DIR}"
echo "To remove config too: rm -rf ${CONFIG_DIR}"
