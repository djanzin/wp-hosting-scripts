#!/bin/bash
# Streamt Nginx- und PHP-Logs einer Site parallel (live tail)
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen
#
# Usage:
#   sudo bash tail-logs.sh <domain>           — alle Logs der Site
#   sudo bash tail-logs.sh <domain> errors    — nur Fehler-Logs
#   sudo bash tail-logs.sh <domain> php       — nur PHP-Logs
#   sudo bash tail-logs.sh <domain> nginx     — nur Nginx-Logs

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

[[ $EUID -ne 0 ]] && { echo "Als root ausführen: sudo bash tail-logs.sh <domain>" >&2; exit 1; }

DOMAIN="${1:-}"
FILTER="${2:-all}"

if [[ -z "$DOMAIN" ]]; then
    echo "Usage: tail-logs.sh <domain> [all|errors|php|nginx]"
    echo ""
    echo "Verfügbare Sites:"
    for f in /etc/wp-hosting/sites/*.txt; do
        [[ -f "$f" ]] && echo "  - $(basename "$f" .txt)"
    done
    exit 1
fi

DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/^www\.//')
[[ ! -f "/etc/wp-hosting/sites/${DOMAIN}.txt" ]] && { echo "Site '${DOMAIN}' nicht gefunden." >&2; exit 1; }

ACCESS_LOG="/var/log/nginx/${DOMAIN}.access.log"
ERROR_LOG="/var/log/nginx/${DOMAIN}.error.log"
PHP_SLOW="/var/log/php/${DOMAIN}.slow.log"
PHP_ERROR="/var/log/php/${DOMAIN}.error.log"

# Welche Logs streamen?
declare -a LOGS
declare -a TAGS
declare -a COLORS

case "$FILTER" in
    errors)
        [[ -f "$ERROR_LOG" ]]  && LOGS+=("$ERROR_LOG")  && TAGS+=("nginx-err") && COLORS+=("$RED")
        [[ -f "$PHP_ERROR" ]]  && LOGS+=("$PHP_ERROR")  && TAGS+=("php-err")   && COLORS+=("$RED")
        ;;
    php)
        [[ -f "$PHP_SLOW" ]]   && LOGS+=("$PHP_SLOW")   && TAGS+=("php-slow")  && COLORS+=("$YELLOW")
        [[ -f "$PHP_ERROR" ]]  && LOGS+=("$PHP_ERROR")  && TAGS+=("php-err")   && COLORS+=("$RED")
        ;;
    nginx)
        [[ -f "$ACCESS_LOG" ]] && LOGS+=("$ACCESS_LOG") && TAGS+=("access")    && COLORS+=("$GREEN")
        [[ -f "$ERROR_LOG" ]]  && LOGS+=("$ERROR_LOG")  && TAGS+=("nginx-err") && COLORS+=("$RED")
        ;;
    all|*)
        [[ -f "$ACCESS_LOG" ]] && LOGS+=("$ACCESS_LOG") && TAGS+=("access")    && COLORS+=("$GREEN")
        [[ -f "$ERROR_LOG" ]]  && LOGS+=("$ERROR_LOG")  && TAGS+=("nginx-err") && COLORS+=("$RED")
        [[ -f "$PHP_SLOW" ]]   && LOGS+=("$PHP_SLOW")   && TAGS+=("php-slow")  && COLORS+=("$YELLOW")
        [[ -f "$PHP_ERROR" ]]  && LOGS+=("$PHP_ERROR")  && TAGS+=("php-err")   && COLORS+=("$RED")
        ;;
esac

if [[ ${#LOGS[@]} -eq 0 ]]; then
    echo "Keine Log-Dateien gefunden für ${DOMAIN}" >&2
    exit 1
fi

echo -e "${BOLD}Streaming Logs für ${CYAN}${DOMAIN}${NC} (Filter: ${FILTER})"
for i in "${!LOGS[@]}"; do
    echo -e "  ${COLORS[$i]}[${TAGS[$i]}]${NC} ${LOGS[$i]}"
done
echo -e "${BOLD}Beenden mit Ctrl+C${NC}"
echo ""

# Aufräumen bei Beendigung
PIDS=()
cleanup() {
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

# Jeden Log-Stream mit farbigem Tag-Prefix in Background starten
for i in "${!LOGS[@]}"; do
    TAG="${COLORS[$i]}[${TAGS[$i]}]${NC}"
    tail -F "${LOGS[$i]}" 2>/dev/null | while IFS= read -r line; do
        echo -e "${TAG} ${line}"
    done &
    PIDS+=($!)
done

wait
