#!/bin/bash
# Holt die Site-Liste aus einem Google Sheet (über einen n8n-Webhook) und
# schreibt eine lokale sites.csv für batch-install.sh.
#
# Datenfluss:  Google Sheet → n8n (Webhook → Google Sheets → CSV-Response) → hier → sites.csv
# Es werden NUR nicht-geheime Inventardaten geholt (Domain, Typ, Shop-Name, Admin-IP).
# Credentials (DB-/R2-/SES-Keys) bleiben in setup-web.conf auf dem Server.
#
# Usage:
#   bash fetch-sheet.sh                 # → sites.csv (fragt vor Überschreiben)
#   bash fetch-sheet.sh --out neu.csv   # anderes Zieldateiname
#   bash fetch-sheet.sh --force         # vorhandene Zieldatei ohne Rückfrage ersetzen
#   bash fetch-sheet.sh --print         # nur ausgeben, nichts schreiben
#
# Config (erste gefundene wird genutzt):
#   ./sheet.conf  oder  /etc/wp-hosting/sheet.conf
#     SHEET_WEBHOOK_URL="https://n8n.example.com/webhook/wp-sites"
#     SHEET_WEBHOOK_TOKEN="optional-bearer-token"   # leer = ohne Auth-Header

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

command -v curl >/dev/null 2>&1 || err "curl nicht gefunden."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Config laden ───────────────────────────────────────────────────────────
CONF=""
for c in "${SCRIPT_DIR}/sheet.conf" "/etc/wp-hosting/sheet.conf"; do
    [[ -f "$c" ]] && { CONF="$c"; break; }
done
[[ -z "$CONF" ]] && err "Keine sheet.conf gefunden (./sheet.conf oder /etc/wp-hosting/sheet.conf). Vorlage: sheet.conf.example"
# shellcheck disable=SC1090
source "$CONF"
SHEET_WEBHOOK_URL="${SHEET_WEBHOOK_URL:-}"
SHEET_WEBHOOK_TOKEN="${SHEET_WEBHOOK_TOKEN:-}"
[[ -z "$SHEET_WEBHOOK_URL" ]] && err "SHEET_WEBHOOK_URL nicht gesetzt in ${CONF}"

# ── Argumente ──────────────────────────────────────────────────────────────
OUT="${SCRIPT_DIR}/sites.csv"
FORCE=false; PRINT_ONLY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)   OUT="${2:-}"; shift 2 ;;
        --force) FORCE=true; shift ;;
        --print) PRINT_ONLY=true; shift ;;
        --help|-h) sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) err "Unbekannte Option: $1" ;;
    esac
done

# ── Sheet holen ────────────────────────────────────────────────────────────
info "Hole Site-Liste von n8n-Webhook…"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

CURL_ARGS=(-fsS --max-time 30 -H "Accept: text/csv")
[[ -n "$SHEET_WEBHOOK_TOKEN" ]] && CURL_ARGS+=(-H "Authorization: Bearer ${SHEET_WEBHOOK_TOKEN}")

if ! curl "${CURL_ARGS[@]}" "$SHEET_WEBHOOK_URL" -o "$TMP"; then
    err "Abruf fehlgeschlagen. URL/Token in ${CONF} prüfen, n8n-Workflow aktiv?"
fi

# ── Validierung: ist das wirklich die CSV (und nicht ein n8n-Fehler-JSON)? ──
[[ -s "$TMP" ]] || err "Leere Antwort vom Webhook erhalten."
FIRST_LINE="$(head -1 "$TMP" | tr -d '\r')"
if [[ "$FIRST_LINE" == \{* || "$FIRST_LINE" == \[* ]]; then
    warn "Antwort sieht nach JSON aus, nicht nach CSV — n8n-Workflow liefert evtl. einen Fehler:"
    head -3 "$TMP"
    err "Abgebrochen (keine CSV erhalten)."
fi
# Header muss eine 'domain'-Spalte enthalten
echo "$FIRST_LINE" | grep -qiE '(^|,)\s*domain\s*(,|$)' || \
    err "CSV-Header enthält keine 'domain'-Spalte (erhalten: ${FIRST_LINE}). Sheet-Spalten prüfen."

# Datenzeilen zählen (ohne Header, ohne Leerzeilen)
ROWS="$(tail -n +2 "$TMP" | grep -cvE '^[[:space:]]*$' || true)"
[[ "$ROWS" -eq 0 ]] && warn "Sheet enthält keine Datenzeilen (nur Header)."

if $PRINT_ONLY; then
    cat "$TMP"
    info "${ROWS} Datenzeile(n) — nur Ausgabe (--print), nichts geschrieben."
    exit 0
fi

# ── Schreiben (atomar, mit Overwrite-Schutz + Backup) ──────────────────────
if [[ -f "$OUT" ]] && ! $FORCE; then
    echo ""
    read -rp "$(echo -e "${YELLOW}${OUT} existiert bereits — überschreiben? [j/N]: ${NC}")" ans
    [[ "$ans" != "j" && "$ans" != "J" ]] && err "Abgebrochen — bestehende ${OUT} unverändert."
fi
[[ -f "$OUT" ]] && cp "$OUT" "${OUT}.bak" && info "Backup: ${OUT}.bak"

# CRLF normalisieren beim Schreiben
tr -d '\r' < "$TMP" > "$OUT"
log "${ROWS} Site(s) → ${OUT}"
echo ""
info "Nächster Schritt — erst Vorschau, dann Anlage:"
echo "  sudo bash batch-install.sh ${OUT} --dry-run"
echo "  sudo bash batch-install.sh ${OUT}"
