#!/bin/bash
# Rotiert WordPress Security Keys & Salts aller (oder einer einzelnen) Site
# Zwingt alle eingeloggten User zum Re-Login — empfohlen alle 3-6 Monate
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash rotate-keys.sh"
[[ ! -f /etc/wp-hosting/config ]] && err "Konfiguration nicht gefunden."
command -v wp &>/dev/null || err "WP-CLI nicht gefunden."

source /etc/wp-hosting/config

SITES_DIR="/etc/wp-hosting/sites"
[[ -z "$(ls -A "$SITES_DIR" 2>/dev/null)" ]] && err "Keine installierten Sites gefunden."

clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   WordPress Security Keys rotieren           ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "${YELLOW}  Alle eingeloggten Benutzer werden abgemeldet!${NC}"
echo ""

# ── Site-Auswahl ──────────────────────────────────────────────────────────
echo "Welche Sites sollen rotiert werden?"
echo "  1) Alle Sites"
echo "  2) Einzelne Site auswählen"
echo ""
read -rp "Auswahl [1/2]: " rotate_choice

SITES_TO_ROTATE=()
case "$rotate_choice" in
    1)
        for f in "${SITES_DIR}"/*.txt; do
            SITES_TO_ROTATE+=("$(basename "$f" .txt)")
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
        SITES_TO_ROTATE=("$SINGLE_DOMAIN")
        ;;
    *) err "Ungültige Auswahl." ;;
esac

echo ""
info "${#SITES_TO_ROTATE[@]} Site(s) werden rotiert..."
echo ""

# ── Rotation ──────────────────────────────────────────────────────────────
ROTATED=(); FAILED=()

for DOMAIN in "${SITES_TO_ROTATE[@]}"; do
    SITE_PATH="/var/www/${DOMAIN}"

    if [[ ! -d "$SITE_PATH" ]]; then
        warn "Verzeichnis nicht gefunden: ${SITE_PATH} — übersprungen"
        FAILED+=("$DOMAIN")
        continue
    fi

    echo -e "${BLUE}──────────────────────────────────────────────${NC}"
    info "Rotiere Keys: ${BOLD}${DOMAIN}${NC}"

    if wp config shuffle-salts --path="$SITE_PATH" --allow-root 2>/dev/null; then
        log "  Security Keys rotiert"
        # Alle aktiven Sessions für alle User beenden
        if wp user list --path="$SITE_PATH" --allow-root --field=user_login 2>/dev/null | \
           xargs -I{} wp user session destroy {} --all --path="$SITE_PATH" --allow-root 2>/dev/null; then
            log "  Alle User-Sessions beendet"
        else
            warn "  Sessions konnten nicht vollständig beendet werden"
        fi
        ROTATED+=("$DOMAIN")
    else
        warn "  Key-Rotation fehlgeschlagen"
        FAILED+=("$DOMAIN")
    fi
done

# ── Webhook-Benachrichtigung ──────────────────────────────────────────────
if [[ -n "${WEBHOOK_URL:-}" ]]; then
    MSG="${#ROTATED[@]} Site(s): Security Keys rotiert"
    [[ ${#FAILED[@]} -gt 0 ]] && MSG="${MSG}, ${#FAILED[@]} Fehler: ${FAILED[*]}"
    STATUS=$( [[ ${#FAILED[@]} -eq 0 ]] && echo "up" || echo "down" )
    curl -fsS "${WEBHOOK_URL}?status=${STATUS}&msg=$(python3 -c \
        "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$MSG" 2>/dev/null || echo "$MSG")" \
        -o /dev/null 2>/dev/null && log "Webhook-Benachrichtigung gesendet" || warn "Webhook fehlgeschlagen"
fi

# ── Zusammenfassung ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗"
echo -e "║   Key-Rotation abgeschlossen ✓               ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Rotiert:  ${BOLD}${#ROTATED[@]}${NC} Site(s)"
[[ ${#FAILED[@]} -gt 0 ]] && echo -e "${RED}  Fehler:   ${BOLD}${#FAILED[@]}${NC}${RED} Site(s): ${FAILED[*]}${NC}"
echo ""
echo -e "${YELLOW}  → Alle eingeloggten Benutzer wurden abgemeldet.${NC}"
echo ""

# ── Optionaler Cron einrichten ────────────────────────────────────────────
CRON_FILE="/etc/cron.d/wp-rotate-keys"

if [[ ! -f "$CRON_FILE" ]]; then
    echo ""
    echo "Automatische Key-Rotation einrichten?"
    echo "  1) Alle 3 Monate (1. Jan, Apr, Jul, Okt — 04:00 Uhr)"
    echo "  2) Alle 6 Monate (1. Jan + Jul — 04:00 Uhr)"
    echo "  3) Kein automatischer Cron"
    echo ""
    read -rp "Auswahl [1/2/3]: " cron_choice

    case "$cron_choice" in
        1)
            echo "0 4 1 1,4,7,10 * root /usr/local/bin/rotate-keys-auto.sh" > "$CRON_FILE"
            chmod 644 "$CRON_FILE"
            INTERVAL="vierteljährlich"
            ;;
        2)
            echo "0 4 1 1,7 * root /usr/local/bin/rotate-keys-auto.sh" > "$CRON_FILE"
            chmod 644 "$CRON_FILE"
            INTERVAL="halbjährlich"
            ;;
        3)
            info "Kein Cron eingerichtet."
            exit 0
            ;;
        *) err "Ungültige Auswahl." ;;
    esac

    # Nicht-interaktives Wrapper-Script für den Cron
    cat > /usr/local/bin/rotate-keys-auto.sh <<'AUTOEOF'
#!/bin/bash
# Automatische Security-Key-Rotation (alle Sites, nicht-interaktiv)
set -euo pipefail

[[ ! -f /etc/wp-hosting/config ]] && exit 0
source /etc/wp-hosting/config

command -v wp &>/dev/null || exit 1

ROTATED=0; FAILED=0
SITES_DIR="/etc/wp-hosting/sites"

for f in "${SITES_DIR}"/*.txt; do
    DOMAIN=$(basename "$f" .txt)
    SITE_PATH="/var/www/${DOMAIN}"
    [[ ! -d "$SITE_PATH" ]] && continue

    if wp config shuffle-salts --path="$SITE_PATH" --allow-root &>/dev/null; then
        wp user list --path="$SITE_PATH" --allow-root --field=user_login 2>/dev/null | \
            xargs -I{} wp user session destroy {} --all --path="$SITE_PATH" --allow-root &>/dev/null || true
        ROTATED=$((ROTATED + 1))
    else
        FAILED=$((FAILED + 1))
    fi
done

# Webhook
if [[ -n "${WEBHOOK_URL:-}" ]]; then
    MSG="${ROTATED} Site(s): Security Keys rotiert (auto)"
    [[ $FAILED -gt 0 ]] && MSG="${MSG}, ${FAILED} Fehler"
    STATUS=$( [[ $FAILED -eq 0 ]] && echo "up" || echo "down" )
    curl -fsS "${WEBHOOK_URL}?status=${STATUS}&msg=$(python3 -c \
        "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$MSG" 2>/dev/null || echo "$MSG")" \
        -o /dev/null 2>/dev/null || true
fi

logger "wp-rotate-keys: ${ROTATED} rotiert, ${FAILED} Fehler"
AUTOEOF
    chmod +x /usr/local/bin/rotate-keys-auto.sh
    log "Cron eingerichtet: ${INTERVAL} (/etc/cron.d/wp-rotate-keys)"
fi
