#!/bin/bash
# Maintenance Mode ein-/ausschalten für WordPress-Sites
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen
#
# Interaktiv (wie bisher):
#   sudo bash maintenance.sh
#
# Nicht-interaktiv (für Automatisierung, z.B. deploy-site.sh --go-live):
#   sudo bash maintenance.sh --domain example.com --live --yes
#   sudo bash maintenance.sh --domain example.com --maintenance --yes
#   sudo bash maintenance.sh --status            # nur auflisten, ändert nichts
#
#   --live         Wartungsmodus AUS (Site öffentlich)
#   --maintenance  Wartungsmodus AN
#   --yes          ohne Rückfrage
#   --status       Statusliste ausgeben und beenden
# Ist die Site bereits im Zielzustand, endet das Script mit 0 (idempotent).

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

# ── Argumente ──────────────────────────────────────────────────────────────
DOMAIN="" TARGET="" ASSUME_YES=false STATUS_ONLY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)      DOMAIN="${2:-}"; shift 2 ;;
        --live)        TARGET="live"; shift ;;
        --maintenance) TARGET="maintenance"; shift ;;
        --yes|-y)      ASSUME_YES=true; shift ;;
        --status)      STATUS_ONLY=true; shift ;;
        --help|-h)     grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "Unbekanntes Argument: $1 (--domain, --live, --maintenance, --yes, --status)" ;;
    esac
done
NONINT=false
[[ -n "$DOMAIN" ]] && NONINT=true

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash maintenance.sh"
[[ ! -f /etc/wp-hosting/config ]] && err "Konfiguration nicht gefunden. Bitte zuerst setup-web.sh ausführen."

source /etc/wp-hosting/config

SITES_DIR="/etc/wp-hosting/sites"
FASTCGI_CACHE_DIR="${FASTCGI_CACHE_DIR:-/var/cache/nginx/wp}"
flag_of() { echo "/var/www/$1/wp-content/.maintenance-active"; }

# FastCGI-Cache-Einträge einer Domain entfernen.
# WARUM das sein MUSS: nginx cacht 200er eine Stunde (fastcgi_cache_valid 200 … 1h) und
# beantwortet Anfragen dann ohne PHP — das mu-Plugin, das den Wartungsmodus umsetzt, läuft
# also gar nicht. Ohne Purge sieht ein normaler Besucher nach dem Einschalten weiter die
# alte Seite (verifiziert: normale URL 200, Cache-Buster/POST 503). Umgekehrt beim
# Freischalten: frische Inhalte statt Restbestände.
# Der Cache-Key ist "$scheme$request_method$host$request_uri" und steht im Datei-Header,
# daher lassen sich die Einträge einer Domain per grep finden. Ein Treffer zu viel wäre
# unkritisch (Cache baut sich neu auf), deshalb bewusst simpel gehalten.
purge_fastcgi_cache() {
    local dom="$1" files=() n=0
    [[ -d "$FASTCGI_CACHE_DIR" ]] || return 0
    mapfile -t files < <(grep -rlF -- "$dom" "$FASTCGI_CACHE_DIR" 2>/dev/null || true)
    n=${#files[@]}
    (( n > 0 )) && rm -f -- "${files[@]}"
    info "FastCGI-Cache: ${n} Eintrag/Einträge für ${dom} entfernt"
}

# Im interaktiven Modus Banner + Liste; bei --domain/--status ohne Bildschirm-Clear,
# damit die Ausgabe in Logs und Wrappern lesbar bleibt.
if ! $NONINT && ! $STATUS_ONLY; then
    clear 2>/dev/null || true
    echo -e "${BOLD}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║   Maintenance Mode                           ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
fi

[[ -z "$(ls -A "$SITES_DIR" 2>/dev/null)" ]] && err "Keine installierten Sites gefunden."

if ! $NONINT || $STATUS_ONLY; then
    echo "Installierte Sites:"
    for f in "${SITES_DIR}"/*.txt; do
        [[ -f "$f" ]] || continue
        SITE_DOMAIN=$(basename "$f" .txt)
        if [[ -f "$(flag_of "$SITE_DOMAIN")" ]]; then
            echo -e "  ${YELLOW}[MAINTENANCE]${NC} ${SITE_DOMAIN}"
        else
            echo -e "  ${GREEN}[LIVE]       ${NC} ${SITE_DOMAIN}"
        fi
    done
    echo ""
fi
$STATUS_ONLY && exit 0

if [[ -z "$DOMAIN" ]]; then
    read -rp "Domain: " DOMAIN
fi
DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's#^https\?://##; s#/.*$##; s/^www\.//')
[[ -z "$DOMAIN" ]] && err "Domain darf nicht leer sein."

CRED_FILE="${SITES_DIR}/${DOMAIN}.txt"
[[ ! -f "$CRED_FILE" ]] && err "Site '${DOMAIN}' nicht gefunden."

# Systemuser NICHT aus der Domain ableiten: install-wp benennt ihn
# wp_<12-alnum>_<sha256-8> (z.B. wp_examplecom_1a2b3c4d). Die frühere Ableitung
# "wp_$(domain mit _ statt .)" ergab einen Namen, den es nicht gibt → chown scheiterte,
# set -e brach ab und der Wartungsmodus liess ein Flag mit falschem Eigentuemer zurueck.
# Autoritativ ist die Cred-Datei, die install-wp geschrieben hat; die Ableitung bleibt
# nur als Notnagel fuer alte Sites ohne diesen Eintrag.
SYSTEM_USER=$(sed -nE 's/^System-User:[[:space:]]*//p' "$CRED_FILE" | head -1)
if [[ -z "$SYSTEM_USER" ]]; then
    DOMAIN_SAFE="$(printf '%s' "$DOMAIN" | tr -cd 'a-z0-9' | cut -c1-12)_$(printf '%s' "$DOMAIN" | sha256sum | cut -c1-8)"
    SYSTEM_USER="wp_${DOMAIN_SAFE}"
    warn "System-User nicht in ${CRED_FILE} — abgeleitet: ${SYSTEM_USER}"
fi
id "$SYSTEM_USER" &>/dev/null || err "Systemuser '${SYSTEM_USER}' existiert nicht — Cred-Datei prüfen."
SITE_PATH="/var/www/${DOMAIN}"
FLAG="$(flag_of "$DOMAIN")"

# Aktueller Zustand; ohne --live/--maintenance wird (wie bisher) umgeschaltet.
if [[ -f "$FLAG" ]]; then CURRENT="maintenance"; else CURRENT="live"; fi
if [[ -z "$TARGET" ]]; then
    [[ "$CURRENT" == "maintenance" ]] && TARGET="live" || TARGET="maintenance"
fi

# Idempotenz: schon im Zielzustand → nichts tun, Erfolg melden (wichtig fuer Automatisierung)
if [[ "$CURRENT" == "$TARGET" ]]; then
    info "${DOMAIN} ist bereits ${TARGET^^} — nichts zu tun."
    exit 0
fi

if ! $ASSUME_YES; then
    echo ""
    if [[ "$TARGET" == "live" ]]; then
        echo -e "  Aktueller Status: ${YELLOW}${BOLD}MAINTENANCE${NC}"
        echo ""
        read -rp "Site freischalten (LIVE)? [j/N]: " confirm
    else
        echo -e "  Aktueller Status: ${GREEN}${BOLD}LIVE${NC}"
        echo ""
        read -rp "Maintenance Mode aktivieren? [j/N]: " confirm
    fi
    [[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."
fi

if [[ "$TARGET" == "live" ]]; then
    rm -f "$FLAG"
    [[ -e "$FLAG" ]] && err "Flag konnte nicht entfernt werden: ${FLAG}"
    purge_fastcgi_cache "$DOMAIN"
    echo ""
    log "${BOLD}${DOMAIN}${NC} ist jetzt ${GREEN}LIVE${NC}"
else
    touch "$FLAG"
    chown "${SYSTEM_USER}:www-data" "$FLAG"
    chmod 640 "$FLAG"
    [[ -f "$FLAG" ]] || err "Flag konnte nicht gesetzt werden: ${FLAG}"
    purge_fastcgi_cache "$DOMAIN"
    echo ""
    log "${BOLD}${DOMAIN}${NC} ist jetzt im ${YELLOW}MAINTENANCE MODE${NC}"
fi

echo ""
