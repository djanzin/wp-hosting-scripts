#!/bin/bash
# Maintenance Mode ein-/ausschalten für WordPress-Sites
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash maintenance.sh"
[[ ! -f /etc/wp-hosting/config ]] && err "Konfiguration nicht gefunden. Bitte zuerst setup-web.sh ausführen."

source /etc/wp-hosting/config

clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   Maintenance Mode                           ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

SITES_DIR="/etc/wp-hosting/sites"
if [[ -z "$(ls -A "$SITES_DIR" 2>/dev/null)" ]]; then
    err "Keine installierten Sites gefunden."
fi

echo "Installierte Sites:"
for f in "${SITES_DIR}"/*.txt; do
    [[ -f "$f" ]] || continue
    SITE_DOMAIN=$(basename "$f" .txt)
    FLAG="/var/www/${SITE_DOMAIN}/wp-content/.maintenance-active"
    if [[ -f "$FLAG" ]]; then
        echo -e "  ${YELLOW}[MAINTENANCE]${NC} ${SITE_DOMAIN}"
    else
        echo -e "  ${GREEN}[LIVE]       ${NC} ${SITE_DOMAIN}"
    fi
done
echo ""

read -rp "Domain: " DOMAIN
DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/^www\.//')
[[ -z "$DOMAIN" ]] && err "Domain darf nicht leer sein."

CRED_FILE="${SITES_DIR}/${DOMAIN}.txt"
[[ ! -f "$CRED_FILE" ]] && err "Site '${DOMAIN}' nicht gefunden."

DOMAIN_SAFE=$(echo "$DOMAIN" | tr '.' '_' | tr '-' '_')
SYSTEM_USER="wp_${DOMAIN_SAFE:0:20}"
SITE_PATH="/var/www/${DOMAIN}"
FLAG="${SITE_PATH}/wp-content/.maintenance-active"

echo ""
if [[ -f "$FLAG" ]]; then
    echo -e "  Aktueller Status: ${YELLOW}${BOLD}MAINTENANCE${NC}"
    echo ""
    read -rp "Site freischalten (LIVE)? [j/N]: " confirm
    [[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."
    rm -f "$FLAG"
    echo ""
    log "${BOLD}${DOMAIN}${NC} ist jetzt ${GREEN}LIVE${NC}"
else
    echo -e "  Aktueller Status: ${GREEN}${BOLD}LIVE${NC}"
    echo ""
    read -rp "Maintenance Mode aktivieren? [j/N]: " confirm
    [[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."
    touch "$FLAG"
    chown "${SYSTEM_USER}:www-data" "$FLAG"
    chmod 640 "$FLAG"
    echo ""
    log "${BOLD}${DOMAIN}${NC} ist jetzt im ${YELLOW}MAINTENANCE MODE${NC}"
fi

echo ""
