#!/bin/bash
# Aktualisiert WordPress Core, Plugins und Themes aller installierten Sites
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash update-wp.sh"
[[ ! -f /etc/wp-hosting/config ]] && err "Konfiguration nicht gefunden. Bitte zuerst setup-web.sh ausführen."
command -v wp &>/dev/null || err "WP-CLI nicht gefunden."

clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   WordPress Bulk-Update                      ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

SITES_DIR="/etc/wp-hosting/sites"
if [[ -z "$(ls -A "$SITES_DIR" 2>/dev/null)" ]]; then
    err "Keine installierten Sites gefunden."
fi

# Auswahl: alle oder einzelne Site
echo "Was soll aktualisiert werden?"
echo "  1) Alle Sites"
echo "  2) Einzelne Site auswählen"
echo ""
read -rp "Auswahl [1/2]: " update_choice

SITES_TO_UPDATE=()
case "$update_choice" in
    1)
        for f in "${SITES_DIR}"/*.txt; do
            SITES_TO_UPDATE+=("$(basename "$f" .txt)")
        done
        ;;
    2)
        echo ""
        echo "Installierte Sites:"
        for f in "${SITES_DIR}"/*.txt; do
            echo "  - $(basename "$f" .txt)"
        done
        echo ""
        read -rp "Domain: " SINGLE_DOMAIN
        SINGLE_DOMAIN=$(echo "$SINGLE_DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/^www\.//')
        [[ ! -f "${SITES_DIR}/${SINGLE_DOMAIN}.txt" ]] && err "Site '${SINGLE_DOMAIN}' nicht gefunden."
        SITES_TO_UPDATE=("$SINGLE_DOMAIN")
        ;;
    *) err "Ungültige Auswahl." ;;
esac

echo ""
echo "Was soll aktualisiert werden?"
echo "  1) Alles (Core + Plugins + Themes)"
echo "  2) Nur Plugins"
echo "  3) Nur Themes"
echo "  4) Nur WordPress Core"
echo ""
read -rp "Auswahl [1-4]: " scope_choice

UPDATE_CORE=false; UPDATE_PLUGINS=false; UPDATE_THEMES=false
case "$scope_choice" in
    1) UPDATE_CORE=true; UPDATE_PLUGINS=true; UPDATE_THEMES=true ;;
    2) UPDATE_PLUGINS=true ;;
    3) UPDATE_THEMES=true ;;
    4) UPDATE_CORE=true ;;
    *) err "Ungültige Auswahl." ;;
esac

echo ""
info "${#SITES_TO_UPDATE[@]} Site(s) werden aktualisiert..."
echo ""

# Ergebnis-Tracking
UPDATED=(); FAILED=(); SKIPPED=()

for DOMAIN in "${SITES_TO_UPDATE[@]}"; do
    SITE_PATH="/var/www/${DOMAIN}"
    DOMAIN_SAFE=$(echo "$DOMAIN" | tr '.' '_' | tr '-' '_')
    SYSTEM_USER="wp_${DOMAIN_SAFE:0:20}"

    if [[ ! -d "$SITE_PATH" ]]; then
        warn "Verzeichnis nicht gefunden: ${SITE_PATH} — übersprungen"
        SKIPPED+=("$DOMAIN")
        continue
    fi

    echo -e "${BLUE}──────────────────────────────────────────────${NC}"
    info "Aktualisiere: ${BOLD}${DOMAIN}${NC}"

    WP_CMD="wp --path=${SITE_PATH} --allow-root"
    SITE_OK=true

    # Maintenance Mode aktivieren
    $WP_CMD maintenance-mode activate 2>/dev/null || true

    if $UPDATE_CORE; then
        if $WP_CMD core update 2>&1 | grep -qE "Success|already"; then
            log "  Core aktualisiert"
        else
            warn "  Core-Update fehlgeschlagen"
            SITE_OK=false
        fi
    fi

    if $UPDATE_PLUGINS; then
        PLUGIN_COUNT=$($WP_CMD plugin update --all 2>&1 | grep -c "Updated" || echo "0")
        log "  Plugins: ${PLUGIN_COUNT} aktualisiert"
    fi

    if $UPDATE_THEMES; then
        THEME_COUNT=$($WP_CMD theme update --all 2>&1 | grep -c "Updated" || echo "0")
        log "  Themes: ${THEME_COUNT} aktualisiert"
    fi

    # Datenbank-Migration falls nötig
    $WP_CMD core update-db 2>&1 | grep -q "Success" && log "  DB-Schema aktualisiert" || true

    # Caches leeren
    $WP_CMD cache flush 2>/dev/null || true
    $WP_CMD transient delete --all 2>/dev/null || true
    log "  Cache geleert"

    # Maintenance Mode deaktivieren
    $WP_CMD maintenance-mode deactivate 2>/dev/null || true

    if $SITE_OK; then
        UPDATED+=("$DOMAIN")
    else
        FAILED+=("$DOMAIN")
    fi
done

# ── FastCGI Cache leeren (WooCommerce-VMs) ────────────────────────────────
if [[ -d /var/cache/nginx/wp ]]; then
    rm -rf /var/cache/nginx/wp/*
    log "FastCGI-Cache geleert"
fi

# ── OPcache leeren ────────────────────────────────────────────────────────
# PHP-FPM neu laden → alle kompilierten Bytecode-Dateien verworfen
# Verhindert, dass veraltete OPcache-Einträge nach Core-Updates aktiv bleiben
systemctl reload php8.3-fpm
log "OPcache geleert (PHP-FPM neu geladen)"

# ── Webhook-Benachrichtigung ──────────────────────────────────────────────
WEBHOOK_URL="${WEBHOOK_URL:-}"
[[ -f /etc/wp-hosting/config ]] && source /etc/wp-hosting/config 2>/dev/null || true

if [[ -n "${WEBHOOK_URL:-}" ]]; then
    MSG="${#UPDATED[@]} Site(s) aktualisiert"
    [[ ${#FAILED[@]} -gt 0 ]] && MSG="${MSG}, ${#FAILED[@]} Fehler: ${FAILED[*]}"
    STATUS=$( [[ ${#FAILED[@]} -eq 0 ]] && echo "up" || echo "down" )
    curl -fsS "${WEBHOOK_URL}?status=${STATUS}&msg=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$MSG" 2>/dev/null || echo "$MSG")" \
        -o /dev/null 2>/dev/null && log "Webhook-Benachrichtigung gesendet" || warn "Webhook fehlgeschlagen"
fi

# ── Zusammenfassung ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗"
echo -e "║   Update abgeschlossen ✓                     ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Erfolgreich:  ${BOLD}${#UPDATED[@]}${NC} Site(s)"
[[ ${#SKIPPED[@]} -gt 0 ]] && echo -e "  Übersprungen: ${BOLD}${#SKIPPED[@]}${NC} Site(s)"
[[ ${#FAILED[@]}  -gt 0 ]] && echo -e "${RED}  Fehler:       ${BOLD}${#FAILED[@]}${NC}${RED} Site(s): ${FAILED[*]}${NC}"
echo ""
