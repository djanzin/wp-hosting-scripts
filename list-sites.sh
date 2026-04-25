#!/bin/bash
# Zeigt alle installierten WordPress-Sites mit Status
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

[[ $EUID -ne 0 ]] && { echo "Als root ausführen."; exit 1; }
[[ ! -f /etc/wp-hosting/config ]] && { echo "Konfiguration nicht gefunden."; exit 1; }

source /etc/wp-hosting/config

clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   WordPress Sites — Übersicht                ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

SITES_DIR="/etc/wp-hosting/sites"
if [[ -z "$(ls -A "$SITES_DIR" 2>/dev/null)" ]]; then
    echo "  Keine Sites installiert."
    exit 0
fi

TOTAL=0; RUNNING=0; ISSUES=0

printf "  %-35s %-14s %-8s %-8s %-8s %-12s\n" "DOMAIN" "TYP" "NGINX" "PHP-FPM" "REDIS" "INSTALLIERT"
echo "  $(printf '%.0s─' {1..90})"

for CRED_FILE in "${SITES_DIR}"/*.txt; do
    DOMAIN=$(basename "$CRED_FILE" .txt)
    SITE_PATH="/var/www/${DOMAIN}"
    DOMAIN_SAFE=$(echo "$DOMAIN" | tr '.' '_' | tr '-' '_')

    TYPE=$(grep "^Typ:" "$CRED_FILE" 2>/dev/null | awk '{print $2}' || echo "?")
    INSTALLED=$(grep "^Installiert:" "$CRED_FILE" 2>/dev/null | cut -d' ' -f2 || echo "?")

    # Nginx-Vhost aktiv?
    if [[ -L "/etc/nginx/sites-enabled/${DOMAIN}" ]]; then
        NGINX_STATUS="${GREEN}✓ aktiv${NC}"
    else
        NGINX_STATUS="${RED}✗ fehlt${NC}"
        ISSUES=$((ISSUES + 1))
    fi

    # PHP-FPM Socket vorhanden?
    if [[ -S "/run/php/php8.3-fpm-${DOMAIN}.sock" ]]; then
        PHP_STATUS="${GREEN}✓ läuft${NC}"
    else
        PHP_STATUS="${RED}✗ fehlt${NC}"
        ISSUES=$((ISSUES + 1))
    fi

    # Redis erreichbar?
    if command -v redis-cli &>/dev/null && redis-cli ping &>/dev/null; then
        REDIS_STATUS="${GREEN}✓ ok${NC}"
    else
        REDIS_STATUS="${RED}✗ fehlt${NC}"
    fi

    printf "  %-35s %-14s " "$DOMAIN" "$TYPE"
    echo -ne "$NGINX_STATUS      $PHP_STATUS    $REDIS_STATUS   $INSTALLED\n" | \
        sed "s/\x1b\[[0-9;]*m//g" | awk '{printf "%-8s %-8s %-8s %-12s\n", $1, $2, $3, $4}' || \
        echo "$NGINX_STATUS $PHP_STATUS $REDIS_STATUS $INSTALLED"

    TOTAL=$((TOTAL + 1))
    [[ -S "/run/php/php8.3-fpm-${DOMAIN}.sock" ]] && RUNNING=$((RUNNING + 1)) || true
done

echo ""
echo "  Gesamt: ${BOLD}${TOTAL}${NC} Sites | Läuft: ${BOLD}${RUNNING}${NC}"
[[ $ISSUES -gt 0 ]] && echo -e "  ${YELLOW}Hinweis: ${ISSUES} Problem(e) erkannt — Nginx/PHP-FPM prüfen.${NC}"

# VM-Status
echo ""
echo -e "  ${BOLD}VM-Status:${NC}"
echo -e "  Nginx:      $(systemctl is-active nginx       2>/dev/null | sed 's/active/\x1b[32m✓ aktiv\x1b[0m/' | sed 's/inactive/\x1b[31m✗ inaktiv\x1b[0m/')"
echo -e "  PHP-FPM:    $(systemctl is-active php8.3-fpm  2>/dev/null | sed 's/active/\x1b[32m✓ aktiv\x1b[0m/' | sed 's/inactive/\x1b[31m✗ inaktiv\x1b[0m/')"
echo -e "  Redis:      $(systemctl is-active redis-server 2>/dev/null | sed 's/active/\x1b[32m✓ aktiv\x1b[0m/' | sed 's/inactive/\x1b[31m✗ inaktiv\x1b[0m/')"
echo -e "  Netdata:    $(systemctl is-active netdata      2>/dev/null | sed 's/active/\x1b[32m✓ aktiv\x1b[0m/' | sed 's/inactive/\x1b[31m✗ inaktiv\x1b[0m/')"
echo -e "  VM-Typ:     ${BOLD}${VM_TYPE}${NC} | DB-Host: ${BOLD}${DB_HOST}${NC}"
echo ""

# Disk-Nutzung
echo -e "  ${BOLD}Disk-Nutzung /var/www:${NC}"
du -sh /var/www/*/  2>/dev/null | sort -rh | head -10 | awk '{printf "  %-10s %s\n", $1, $2}' || true
echo ""
