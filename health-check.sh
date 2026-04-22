#!/bin/bash
# Prüft HTTP-Status, PHP-FPM Socket und DB-Verbindung aller Sites
# Sendet Webhook-Alert bei Problemen
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash health-check.sh"
[[ ! -f /etc/wp-hosting/config ]] && err "Konfiguration nicht gefunden."

source /etc/wp-hosting/config

SITES_DIR="/etc/wp-hosting/sites"

clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   WordPress Health Check                     ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Infrastruktur-Checks ──────────────────────────────────────────────────
echo -e "${BOLD}── Infrastruktur ──────────────────────────────${NC}"

# Nginx
if systemctl is-active --quiet nginx; then
    log "Nginx läuft"
else
    warn "Nginx ist NICHT aktiv"
    INFRA_ISSUES+=("Nginx gestoppt")
fi

# PHP-FPM
if systemctl is-active --quiet php8.3-fpm; then
    log "PHP 8.3-FPM läuft"
else
    warn "PHP 8.3-FPM ist NICHT aktiv"
    INFRA_ISSUES+=("PHP-FPM gestoppt")
fi

# Redis
if systemctl is-active --quiet redis-server; then
    log "Redis läuft"
else
    warn "Redis ist NICHT aktiv"
    INFRA_ISSUES+=("Redis gestoppt")
fi

# MariaDB-Verbindung von dieser VM
if mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" -p"$DB_ADMIN_PASS" \
    -e "SELECT 1;" &>/dev/null 2>&1; then
    log "Datenbankverbindung (${DB_HOST}) OK"
else
    warn "Datenbankverbindung (${DB_HOST}) FEHLGESCHLAGEN"
    INFRA_ISSUES+=("DB-Verbindung fehlgeschlagen")
fi

echo ""

# ── Initialisierung der Zähler ────────────────────────────────────────────
declare -a INFRA_ISSUES=()
declare -a SITE_ISSUES=()
OK_COUNT=0
WARN_COUNT=0

# ── Prüfung wenn keine Sites vorhanden ───────────────────────────────────
if [[ -z "$(ls -A "$SITES_DIR" 2>/dev/null)" ]]; then
    info "Keine installierten Sites gefunden."
    echo ""
    exit 0
fi

# ── Pro-Site Checks ───────────────────────────────────────────────────────
echo -e "${BOLD}── Sites ───────────────────────────────────────${NC}"
printf "%-35s %-8s %-8s %-8s %-8s\n" "Domain" "HTTP" "FPM" "DB" "Redis"
echo "────────────────────────────────────────────────────────────────────"

for f in "${SITES_DIR}"/*.txt; do
    DOMAIN=$(basename "$f" .txt)
    SITE_PATH="/var/www/${DOMAIN}"
    DOMAIN_SAFE=$(echo "$DOMAIN" | tr '.' '_' | tr '-' '_')
    SOCK="/run/php/php8.3-fpm-${DOMAIN}.sock"

    SITE_OK=true
    HTTP_STATUS="?"
    FPM_STATUS="?"
    DB_STATUS="?"
    REDIS_STATUS="?"

    # HTTP-Check (intern, ohne SSL — über localhost)
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 --max-time 10 \
        -H "Host: ${DOMAIN}" \
        "http://127.0.0.1/" 2>/dev/null || echo "ERR")

    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "301" || "$HTTP_CODE" == "302" ]]; then
        HTTP_STATUS="${GREEN}${HTTP_CODE}${NC}"
    else
        HTTP_STATUS="${RED}${HTTP_CODE}${NC}"
        SITE_OK=false
    fi

    # PHP-FPM Socket
    if [[ -S "$SOCK" ]]; then
        FPM_STATUS="${GREEN}OK${NC}"
    else
        FPM_STATUS="${RED}FEHLT${NC}"
        SITE_OK=false
    fi

    # Datenbankverbindung (liest Credentials aus der Site-Datei)
    SITE_DB_NAME=$(grep "^DB-Name:" "$f" 2>/dev/null | awk '{print $2}' || echo "")
    SITE_DB_USER=$(grep "^DB-User:" "$f" 2>/dev/null | awk '{print $2}' || echo "")
    SITE_DB_PASS=$(grep "^DB-Pass:" "$f" 2>/dev/null | awk '{print $2}' || echo "")

    if [[ -n "$SITE_DB_NAME" && -n "$SITE_DB_USER" ]]; then
        if mysql -h "$DB_HOST" -u "$SITE_DB_USER" -p"$SITE_DB_PASS" \
            "$SITE_DB_NAME" -e "SELECT 1;" &>/dev/null 2>&1; then
            DB_STATUS="${GREEN}OK${NC}"
        else
            DB_STATUS="${RED}FEHLER${NC}"
            SITE_OK=false
        fi
    else
        DB_STATUS="${YELLOW}n/a${NC}"
    fi

    # Redis-Check (Object Cache aktiv?)
    if [[ -d "$SITE_PATH" ]] && command -v wp &>/dev/null; then
        REDIS_OK=$(wp redis status --path="$SITE_PATH" --allow-root 2>/dev/null | grep -ci "connected" || echo "0")
        if [[ "$REDIS_OK" -gt 0 ]]; then
            REDIS_STATUS="${GREEN}OK${NC}"
        else
            REDIS_STATUS="${YELLOW}OFF${NC}"
        fi
    else
        REDIS_STATUS="${YELLOW}n/a${NC}"
    fi

    # Ausgabe der Zeile
    printf "%-35s " "$DOMAIN"
    echo -ne "${HTTP_STATUS}     ${FPM_STATUS}   ${DB_STATUS}   ${REDIS_STATUS}\n" | \
        sed 's/\x1b\[[0-9;]*m//g' | cat -v | \
        awk '{printf "%-8s %-8s %-8s %-8s\n", $1, $2, $3, $4}' 2>/dev/null || \
        echo -e "${HTTP_STATUS}     ${FPM_STATUS}     ${DB_STATUS}     ${REDIS_STATUS}"

    if $SITE_OK; then
        ((OK_COUNT++))
    else
        ((WARN_COUNT++))
        SITE_ISSUES+=("${DOMAIN}: HTTP=${HTTP_CODE} FPM=$(echo -e "$FPM_STATUS" | sed 's/\x1b\[[0-9;]*m//g') DB=$(echo -e "$DB_STATUS" | sed 's/\x1b\[[0-9;]*m//g')")
    fi
done

echo ""

# ── Disk Usage ────────────────────────────────────────────────────────────
echo -e "${BOLD}── Disk Usage (/var/www) ───────────────────────${NC}"
df -h /var/www | tail -1 | awk '{printf "  Belegt: %s von %s (%s)\n", $3, $2, $5}'
echo ""

# ── Ergebnis & Webhook ────────────────────────────────────────────────────
TOTAL=$((OK_COUNT + WARN_COUNT))

if [[ ${#SITE_ISSUES[@]} -eq 0 && ${#INFRA_ISSUES[@]} -eq 0 ]]; then
    echo -e "${BOLD}╔══════════════════════════════════════════════╗"
    echo -e "║   Alle Checks bestanden ✓                    ║"
    echo -e "╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${GREEN}${TOTAL}/${TOTAL}${NC} Sites OK"
    WEBHOOK_STATUS="up"
    WEBHOOK_MSG="${TOTAL}/${TOTAL} Sites OK — alle Health Checks bestanden"
else
    echo -e "${BOLD}${RED}╔══════════════════════════════════════════════╗"
    echo -e "║   Probleme gefunden!                         ║"
    echo -e "╚══════════════════════════════════════════════╝${NC}"
    echo ""
    [[ ${#INFRA_ISSUES[@]} -gt 0 ]] && \
        echo -e "  ${RED}Infrastruktur:${NC} ${INFRA_ISSUES[*]}"
    echo -e "  ${GREEN}${OK_COUNT}/${TOTAL}${NC} Sites OK, ${RED}${WARN_COUNT}/${TOTAL}${NC} mit Problemen"
    echo ""
    for ISSUE in "${SITE_ISSUES[@]}"; do
        echo -e "  ${RED}✗${NC} ${ISSUE}"
    done
    WEBHOOK_STATUS="down"
    WEBHOOK_MSG="${WARN_COUNT}/${TOTAL} Sites haben Probleme: ${SITE_ISSUES[*]}"
fi

echo ""

# Webhook nur senden wenn es Probleme gibt (oder --force Flag gesetzt)
FORCE_WEBHOOK="${1:-}"
if [[ -n "${WEBHOOK_URL:-}" ]] && \
   [[ "$WEBHOOK_STATUS" == "down" || "$FORCE_WEBHOOK" == "--notify" ]]; then
    curl -fsS "${WEBHOOK_URL}?status=${WEBHOOK_STATUS}&msg=$(python3 -c \
        "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" \
        "$WEBHOOK_MSG" 2>/dev/null || echo "$WEBHOOK_MSG")" \
        -o /dev/null 2>/dev/null && \
        log "Webhook-Alert gesendet" || warn "Webhook fehlgeschlagen"
    echo ""
fi
