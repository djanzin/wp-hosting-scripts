#!/bin/bash
# Audit aller Sites: WordPress-Version, veraltete/inaktive Plugins, Sicherheits-Hygiene
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash audit-plugins.sh"
[[ ! -f /etc/wp-hosting/config ]] && err "Konfiguration nicht gefunden."
command -v wp &>/dev/null || err "WP-CLI nicht gefunden."
source /etc/wp-hosting/config

SITES_DIR="/etc/wp-hosting/sites"
[[ -z "$(ls -A "$SITES_DIR" 2>/dev/null)" ]] && err "Keine Sites installiert."

# Optional: nur eine Domain auditen
TARGET_DOMAIN="${1:-}"

clear 2>/dev/null || true
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   Plugin- & Site-Audit                       ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# Schwellwert: Plugins die >365 Tage nicht aktualisiert wurden = veraltet
STALE_DAYS=365
NOW_TS=$(date +%s)
TOTAL_ISSUES=0

for f in "$SITES_DIR"/*.txt; do
    DOMAIN=$(basename "$f" .txt)
    [[ -n "$TARGET_DOMAIN" && "$DOMAIN" != "$TARGET_DOMAIN" ]] && continue

    SITE_PATH="/var/www/${DOMAIN}"
    [[ ! -d "$SITE_PATH" ]] && continue

    WP="wp --path=${SITE_PATH} --allow-root --skip-themes --skip-plugins"
    WP_FULL="wp --path=${SITE_PATH} --allow-root"

    echo -e "${BOLD}── ${DOMAIN} ─────────────────────────────────────────${NC}"

    # WordPress-Version & Update verfügbar?
    WP_VER=$(timeout 15 $WP core version 2>/dev/null || echo "?")
    WP_UPDATE=$(timeout 15 $WP core check-update --field=version 2>/dev/null | head -1 || echo "")
    if [[ -n "$WP_UPDATE" ]]; then
        echo -e "  ${YELLOW}!${NC} WordPress: ${WP_VER} (Update auf ${WP_UPDATE} verfügbar)"
        TOTAL_ISSUES=$((TOTAL_ISSUES+1))
    else
        echo -e "  ${GREEN}✓${NC} WordPress: ${WP_VER}"
    fi

    # Inaktive Plugins (Angriffsfläche — sollten gelöscht werden)
    INACTIVE=$(timeout 30 $WP_FULL plugin list --status=inactive --field=name 2>/dev/null || true)
    if [[ -n "$INACTIVE" ]]; then
        echo -e "  ${YELLOW}!${NC} Inaktive Plugins (sollten entfernt werden):"
        echo "$INACTIVE" | sed 's/^/      - /'
        TOTAL_ISSUES=$((TOTAL_ISSUES+1))
    else
        echo -e "  ${GREEN}✓${NC} Keine inaktiven Plugins"
    fi

    # Plugins mit verfügbarem Update
    PLUGIN_UPDATES=$(timeout 30 $WP_FULL plugin list --update=available --field=name 2>/dev/null || true)
    if [[ -n "$PLUGIN_UPDATES" ]]; then
        UPD_COUNT=$(echo "$PLUGIN_UPDATES" | wc -l)
        echo -e "  ${YELLOW}!${NC} ${UPD_COUNT} Plugin(s) mit Update:"
        echo "$PLUGIN_UPDATES" | sed 's/^/      - /'
        TOTAL_ISSUES=$((TOTAL_ISSUES+1))
    fi

    # Veraltete Plugins (im wp.org-Repo seit >1 Jahr nicht aktualisiert)
    # Holt für jedes aktive Plugin "last_updated" aus der wp.org API
    STALE_LIST=()
    while IFS=$'\t' read -r SLUG VERSION; do
        [[ -z "$SLUG" ]] && continue
        # API: https://api.wordpress.org/plugins/info/1.0/<slug>.json
        LAST_UPD=$(curl -fsS --max-time 5 "https://api.wordpress.org/plugins/info/1.0/${SLUG}.json" 2>/dev/null \
            | grep -oE '"last_updated":"[^"]+"' | cut -d'"' -f4 | cut -d' ' -f1 || echo "")
        if [[ -n "$LAST_UPD" ]]; then
            UPD_TS=$(date -d "$LAST_UPD" +%s 2>/dev/null || echo "0")
            DIFF_DAYS=$(( (NOW_TS - UPD_TS) / 86400 ))
            if [[ $DIFF_DAYS -gt $STALE_DAYS ]]; then
                STALE_LIST+=("${SLUG} (letztes Update vor ${DIFF_DAYS} Tagen)")
            fi
        fi
    done < <(timeout 30 $WP_FULL plugin list --status=active --fields=name,version --format=tsv 2>/dev/null | tail -n +2 || true)

    if [[ ${#STALE_LIST[@]} -gt 0 ]]; then
        echo -e "  ${YELLOW}!${NC} Verlassene Plugins (>${STALE_DAYS} Tage ohne Update im Repo):"
        for p in "${STALE_LIST[@]}"; do echo "      - $p"; done
        TOTAL_ISSUES=$((TOTAL_ISSUES+1))
    fi

    # Default WordPress-Admin-Email noch aktiv?
    ADMIN_EMAIL=$(timeout 10 $WP option get admin_email 2>/dev/null || echo "?")
    if [[ "$ADMIN_EMAIL" == *"@example.com" || "$ADMIN_EMAIL" == "admin@${DOMAIN}" || -z "$ADMIN_EMAIL" ]]; then
        echo -e "  ${YELLOW}!${NC} Admin-E-Mail verdächtig: ${ADMIN_EMAIL}"
        TOTAL_ISSUES=$((TOTAL_ISSUES+1))
    fi

    # User mit "admin" Username
    if timeout 10 $WP user get admin --field=ID 2>/dev/null | grep -qE '^[0-9]+$'; then
        echo -e "  ${RED}!${NC} User 'admin' existiert (Standard-Username — Brute-Force-Ziel)"
        TOTAL_ISSUES=$((TOTAL_ISSUES+1))
    fi

    # Anzahl Posts/Revisions/Transients (DB-Bloat-Indikator)
    REV_COUNT=$(timeout 10 $WP db query "SELECT COUNT(*) FROM \`$($WP db prefix --skip-themes --skip-plugins 2>/dev/null)posts\` WHERE post_type='revision'" --skip-column-names 2>/dev/null || echo "0")
    if [[ "$REV_COUNT" -gt 1000 ]]; then
        echo -e "  ${YELLOW}!${NC} ${REV_COUNT} Post-Revisions in DB (Cleanup empfohlen: wp post delete --force \$(wp post list --post_type=revision --format=ids))"
    fi

    echo ""
done

echo ""
if [[ $TOTAL_ISSUES -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}✓ Keine Auffälligkeiten gefunden${NC}"
else
    echo -e "${YELLOW}${BOLD}${TOTAL_ISSUES} Punkt(e) zur Beachtung${NC}"
fi
echo ""
