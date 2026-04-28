#!/bin/bash
# Synchronisiert Plugin-ZIPs (SEOpress Pro u.a.) aus dem Plugin-Bucket
# Voraussetzung: setup-web.sh wurde mit konfiguriertem PLUGIN_BUCKET ausgeführt
#
# Usage:
#   sudo bash sync-plugins.sh           — alle ZIPs aus Plugin-Bucket nachladen
#   sudo bash sync-plugins.sh --list    — zeigt nur welche Plugins lokal vorhanden sind

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash sync-plugins.sh"
[[ ! -f /etc/wp-hosting/config ]] && err "Konfiguration nicht gefunden."
command -v rclone &>/dev/null || err "rclone nicht installiert."

source /etc/wp-hosting/config

[[ -z "${PLUGIN_BUCKET:-}" ]] && err "PLUGIN_BUCKET nicht konfiguriert in /etc/wp-hosting/config."
[[ -z "${RCLONE_REMOTE:-}" ]] && err "RCLONE_REMOTE nicht konfiguriert."

LOCAL_DIR="/etc/wp-hosting/plugins"
mkdir -p "$LOCAL_DIR"

# Nur listen
if [[ "${1:-}" == "--list" ]]; then
    echo -e "${BOLD}Lokal:${NC}"
    ls -lh "$LOCAL_DIR"/*.zip 2>/dev/null | awk '{printf "  %-40s %s\n", $9, $5}' || echo "  (keine)"
    echo ""
    echo -e "${BOLD}Remote (${RCLONE_REMOTE}:${PLUGIN_BUCKET}):${NC}"
    rclone ls "${RCLONE_REMOTE}:${PLUGIN_BUCKET}/" 2>/dev/null | awk '{printf "  %-40s %s Bytes\n", $2, $1}' || echo "  (Bucket leer oder nicht erreichbar)"
    exit 0
fi

# Sync mit Mirror — entfernt lokale ZIPs die nicht mehr im Bucket sind
info "Synchronisiere ${RCLONE_REMOTE}:${PLUGIN_BUCKET}/ → ${LOCAL_DIR}/"
if rclone sync "${RCLONE_REMOTE}:${PLUGIN_BUCKET}/" "$LOCAL_DIR/" \
    --include "*.zip" 2>&1; then
    FOUND=$(ls "$LOCAL_DIR"/*.zip 2>/dev/null | wc -l)
    log "${FOUND} Plugin-ZIP(s) lokal verfügbar"
    echo ""
    ls -lh "$LOCAL_DIR"/*.zip 2>/dev/null | awk '{printf "  %-40s %s\n", $9, $5}'
else
    err "Sync fehlgeschlagen — Plugin-Bucket nicht erreichbar?"
fi

echo ""
info "Hinweis: Bestehende WordPress-Sites werden NICHT automatisch aktualisiert."
info "Plugin-Update auf einer bestimmten Site:"
echo "  wp plugin install /etc/wp-hosting/plugins/<plugin>.zip --activate --force \\"
echo "    --path=/var/www/<domain> --allow-root"
