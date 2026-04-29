#!/bin/bash
# Synchronisiert private Plugin- und Theme-ZIPs aus den konfigurierten Buckets
# Voraussetzung: setup-web.sh wurde mit PLUGIN_BUCKET / THEME_BUCKET ausgeführt
#
# Usage:
#   sudo bash sync-plugins.sh                — Plugins UND Themes sync (Mirror)
#   sudo bash sync-plugins.sh --plugins      — nur Plugins
#   sudo bash sync-plugins.sh --themes       — nur Themes
#   sudo bash sync-plugins.sh --list         — Inventar (lokal + remote)

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

[[ -z "${RCLONE_REMOTE:-}" ]] && err "RCLONE_REMOTE nicht konfiguriert."

PLUGINS_LOCAL="/etc/wp-hosting/plugins"
THEMES_LOCAL="/etc/wp-hosting/themes"
mkdir -p "$PLUGINS_LOCAL" "$THEMES_LOCAL"

MODE="all"
case "${1:-}" in
    --plugins) MODE="plugins" ;;
    --themes)  MODE="themes" ;;
    --list)    MODE="list" ;;
    "")        MODE="all" ;;
    *)         err "Unbekannte Option: $1 (--plugins, --themes, --list)" ;;
esac

# ── Listen-Modus ──────────────────────────────────────────────────────────
if [[ "$MODE" == "list" ]]; then
    echo -e "${BOLD}── Plugins ───────────────────────────────────────${NC}"
    echo -e "${BLUE}Lokal (${PLUGINS_LOCAL}):${NC}"
    ls -lh "$PLUGINS_LOCAL"/*.zip 2>/dev/null | awk '{printf "  %-40s %s\n", $9, $5}' || echo "  (keine)"
    if [[ -n "${PLUGIN_BUCKET:-}" ]]; then
        echo -e "${BLUE}Remote (${RCLONE_REMOTE}:${PLUGIN_BUCKET}):${NC}"
        rclone ls "${RCLONE_REMOTE}:${PLUGIN_BUCKET}/" 2>/dev/null | awk '{printf "  %-40s %s Bytes\n", $2, $1}' || echo "  (Bucket leer / nicht erreichbar)"
    fi
    echo ""
    echo -e "${BOLD}── Themes ────────────────────────────────────────${NC}"
    echo -e "${BLUE}Lokal (${THEMES_LOCAL}):${NC}"
    ls -lh "$THEMES_LOCAL"/*.zip 2>/dev/null | awk '{printf "  %-40s %s\n", $9, $5}' || echo "  (keine)"
    if [[ -n "${THEME_BUCKET:-}" ]]; then
        echo -e "${BLUE}Remote (${RCLONE_REMOTE}:${THEME_BUCKET}):${NC}"
        rclone ls "${RCLONE_REMOTE}:${THEME_BUCKET}/" 2>/dev/null | awk '{printf "  %-40s %s Bytes\n", $2, $1}' || echo "  (Bucket leer / nicht erreichbar)"
    fi
    exit 0
fi

# ── Sync-Funktion ─────────────────────────────────────────────────────────
sync_bucket() {
    local bucket="$1" local_dir="$2" label="$3"
    if [[ -z "$bucket" ]]; then
        warn "$label-Bucket nicht konfiguriert in /etc/wp-hosting/config — übersprungen"
        return 0
    fi
    info "Sync ${RCLONE_REMOTE}:${bucket}/ → ${local_dir}/"
    if rclone sync "${RCLONE_REMOTE}:${bucket}/" "$local_dir/" --include "*.zip" 2>&1; then
        local found
        found=$(ls "$local_dir"/*.zip 2>/dev/null | wc -l)
        log "${found} ${label}-ZIP(s) lokal verfügbar"
        ls -lh "$local_dir"/*.zip 2>/dev/null | awk '{printf "  %-40s %s\n", $9, $5}'
    else
        warn "$label-Sync fehlgeschlagen — Bucket erreichbar?"
        return 1
    fi
}

# ── Plugins ───────────────────────────────────────────────────────────────
if [[ "$MODE" == "all" || "$MODE" == "plugins" ]]; then
    sync_bucket "${PLUGIN_BUCKET:-}" "$PLUGINS_LOCAL" "Plugin"
    echo ""
fi

# ── Themes ────────────────────────────────────────────────────────────────
if [[ "$MODE" == "all" || "$MODE" == "themes" ]]; then
    sync_bucket "${THEME_BUCKET:-}" "$THEMES_LOCAL" "Theme"
    echo ""
fi

info "Hinweis: Neue Sites bekommen die ZIPs automatisch beim install-wp.sh."
info "Bestehende Sites müssen manuell aktualisiert werden:"
echo "  wp plugin install /etc/wp-hosting/plugins/<plugin>.zip --activate --force \\"
echo "    --path=/var/www/<domain> --allow-root"
echo "  wp theme install /etc/wp-hosting/themes/<theme>.zip --force \\"
echo "    --path=/var/www/<domain> --allow-root"
