#!/bin/bash
# Batch-Installer — legt mehrere Sites aus einer CSV non-interaktiv an.
# Ruft install-wp.sh pro Zeile mit --yes auf, sammelt Ergebnisse, Zusammenfassung am Ende.
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen.
#
# Usage:
#   sudo bash batch-install.sh sites.csv
#   sudo bash batch-install.sh sites.csv --dry-run   # nur anzeigen, was passieren würde
#
# CSV-Format (Header-Zeile + eine Zeile pro Site, #-Kommentare und Leerzeilen erlaubt):
#   domain,type,shop_name,admin_ip
#   blog1.de,wordpress,,
#   best4software.de,woocommerce,Best4Software,
#   shop2.de,woocommerce,Mein Shop,1.2.3.4
#
# Spalten nach 'type' sind optional. shop_name nur bei woocommerce relevant.
# Vorhandene Sites werden von install-wp.sh selbst erkannt (übersprungen/Fehler).

set -uo pipefail   # kein -e: ein fehlgeschlagener Site-Install soll den Batch nicht killen

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash batch-install.sh <csv>"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="${SCRIPT_DIR}/install-wp.sh"
[[ -f "$INSTALL" ]] || err "install-wp.sh nicht gefunden neben batch-install.sh (${INSTALL})"

CSV="${1:-}"
DRY_RUN=false
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=true
[[ -z "$CSV" ]] && err "Usage: sudo bash batch-install.sh <csv> [--dry-run]"
[[ -f "$CSV" ]] || err "CSV nicht gefunden: ${CSV}"

# Felder trimmen (führende/abschließende Leerzeichen)
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

OK_LIST=(); FAIL_LIST=(); SKIP_LIST=()
LINE_NO=0; FIRST=true

while IFS= read -r RAW || [[ -n "$RAW" ]]; do
    LINE_NO=$((LINE_NO + 1))
    # CR entfernen (falls CSV aus Windows/Excel), trimmen
    RAW="${RAW%$'\r'}"
    LINE="$(trim "$RAW")"
    [[ -z "$LINE" ]] && continue                 # Leerzeile
    [[ "$LINE" == \#* ]] && continue             # Kommentar
    # Header-Zeile (erste Datenzeile) überspringen, wenn sie 'domain' enthält
    if $FIRST; then
        FIRST=false
        [[ "$LINE" == domain,* || "$LINE" == "domain" ]] && continue
    fi

    # Spalten 1-5 werden verarbeitet (Spalte 5 = matomo_site_id); alles ab 6 = _REST (ignoriert).
    IFS=',' read -r C_DOMAIN C_TYPE C_SHOP C_IP C_MATOMO _REST <<< "$LINE"
    DOMAIN="$(trim "${C_DOMAIN:-}")"
    TYPE="$(trim "${C_TYPE:-}")"
    SHOP="$(trim "${C_SHOP:-}")"
    IP="$(trim "${C_IP:-}")"
    MATOMO_ID="$(trim "${C_MATOMO:-}")"

    if [[ -z "$DOMAIN" || -z "$TYPE" ]]; then
        warn "Zeile ${LINE_NO}: domain/type fehlt — übersprungen (${LINE})"
        SKIP_LIST+=("Zeile ${LINE_NO}: ${LINE}")
        continue
    fi

    # install-wp.sh-Argumente zusammenbauen
    ARGS=(--domain "$DOMAIN" --type "$TYPE" --yes)
    [[ -n "$SHOP"      ]] && ARGS+=(--shop-name "$SHOP")
    [[ -n "$IP"        ]] && ARGS+=(--admin-ip "$IP")
    [[ -n "$MATOMO_ID" ]] && ARGS+=(--matomo-site-id "$MATOMO_ID")

    echo ""
    echo -e "${BOLD}── [${LINE_NO}] ${DOMAIN} (${TYPE})${NC}"
    if $DRY_RUN; then
        info "DRY-RUN: install-wp.sh ${ARGS[*]}"
        OK_LIST+=("$DOMAIN (dry-run)")
        continue
    fi

    if bash "$INSTALL" "${ARGS[@]}"; then
        log "${DOMAIN} installiert"
        OK_LIST+=("$DOMAIN")
    else
        warn "${DOMAIN} FEHLGESCHLAGEN (Exit $?) — Batch läuft weiter"
        FAIL_LIST+=("$DOMAIN")
    fi
done < "$CSV"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗"
echo -e "║   Batch-Install abgeschlossen                ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo -e "  ${GREEN}OK:${NC}          ${#OK_LIST[@]}"
echo -e "  ${RED}Fehler:${NC}      ${#FAIL_LIST[@]}"
echo -e "  ${YELLOW}Übersprungen:${NC} ${#SKIP_LIST[@]}"
if [[ ${#FAIL_LIST[@]} -gt 0 ]]; then
    echo ""
    echo -e "${RED}Fehlgeschlagene Sites (einzeln prüfen / mit --resume erneut):${NC}"
    printf '  - %s\n' "${FAIL_LIST[@]}"
fi
echo ""
$DRY_RUN && info "DRY-RUN — es wurde nichts installiert."

[[ ${#FAIL_LIST[@]} -gt 0 ]] && exit 1 || exit 0
