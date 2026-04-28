#!/bin/bash
# Verifiziert Datei- und DB-Backups (Integrität, Entschlüsselbarkeit)
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash backup-verify.sh"

FILES_DIR="/var/backups/wp-files"
DB_DIR="/var/backups/mysql"
AGE_KEY="/etc/wp-hosting/backup-key.txt"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Bei Webhook-Push (Cron-Modus) keine Farben
if [[ "${1:-}" == "--quiet" ]]; then
    QUIET=true
else
    QUIET=false
    clear
    echo -e "${BOLD}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║   Backup-Verifikation                        ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
fi

OK=0
FAILED=0
FAILED_FILES=()

verify_file() {
    local f="$1"
    local kind="$2"   # "files" oder "db"

    if [[ "$f" == *.age ]]; then
        [[ ! -f "$AGE_KEY" ]] && { FAILED_FILES+=("$f (age-Key fehlt)"); return 1; }
        # Nur ein leichter Decrypt-Check: Header lesen
        age -d -i "$AGE_KEY" "$f" 2>/dev/null | head -c 1 >/dev/null || \
            { FAILED_FILES+=("$f (Entschlüsselung)"); return 1; }
    fi

    if [[ "$kind" == "files" ]]; then
        # tar.gz Integritätsprüfung (zlib-CRC + tar header)
        if [[ "$f" == *.age ]]; then
            age -d -i "$AGE_KEY" "$f" 2>/dev/null | tar -tzf - >/dev/null 2>&1 || \
                { FAILED_FILES+=("$f (tar-corrupt)"); return 1; }
        else
            tar -tzf "$f" >/dev/null 2>&1 || { FAILED_FILES+=("$f (tar-corrupt)"); return 1; }
        fi
    else
        # SQL-Dump: muss CREATE/INSERT enthalten
        local content
        if [[ "$f" == *.age ]]; then
            content=$(age -d -i "$AGE_KEY" "$f" 2>/dev/null | zcat 2>/dev/null | head -c 4096)
        else
            content=$(zcat "$f" 2>/dev/null | head -c 4096)
        fi
        echo "$content" | grep -qE "^(CREATE|INSERT|--|/\*)" || \
            { FAILED_FILES+=("$f (kein SQL-Inhalt)"); return 1; }
    fi
    return 0
}

# Datei-Backups (jeweils das jüngste pro Domain)
$QUIET || echo -e "${BOLD}── Datei-Backups ──────────────────────────────${NC}"
declare -A SEEN
if [[ -d "$FILES_DIR" ]]; then
    while IFS= read -r f; do
        DOMAIN=$(basename "$f" | sed -E 's/_[0-9-]+\.tar\.gz(\.age)?$//')
        [[ -n "${SEEN[$DOMAIN]:-}" ]] && continue  # nur jüngstes pro Domain
        SEEN[$DOMAIN]=1

        if verify_file "$f" "files"; then
            $QUIET || log "$(basename "$f")"
            OK=$((OK+1))
        else
            $QUIET || warn "$(basename "$f")"
            FAILED=$((FAILED+1))
        fi
    done < <(ls -t "$FILES_DIR"/*.tar.gz "$FILES_DIR"/*.tar.gz.age 2>/dev/null || true)
fi

# DB-Backups (jeweils das jüngste pro DB)
$QUIET || echo ""
$QUIET || echo -e "${BOLD}── DB-Backups ──────────────────────────────────${NC}"
declare -A SEEN_DB
if [[ -d "$DB_DIR" ]]; then
    while IFS= read -r f; do
        DB=$(basename "$f" | sed -E 's/_[0-9_]+\.sql\.gz(\.age)?$//')
        [[ -n "${SEEN_DB[$DB]:-}" ]] && continue
        SEEN_DB[$DB]=1

        if verify_file "$f" "db"; then
            $QUIET || log "$(basename "$f")"
            OK=$((OK+1))
        else
            $QUIET || warn "$(basename "$f")"
            FAILED=$((FAILED+1))
        fi
    done < <(ls -t "$DB_DIR"/*.sql.gz "$DB_DIR"/*.sql.gz.age 2>/dev/null || true)
fi

# Ergebnis
$QUIET || echo ""
TOTAL=$((OK + FAILED))
if [[ $FAILED -eq 0 ]]; then
    $QUIET || echo -e "${GREEN}${TOTAL}/${TOTAL} Backups OK${NC}"
    STATUS="up"
    MSG="Backup-Verify: ${OK} Backups OK"
else
    $QUIET || echo -e "${RED}${FAILED}/${TOTAL} FEHLERHAFT:${NC}"
    $QUIET || for ff in "${FAILED_FILES[@]}"; do echo "  - $ff"; done
    STATUS="down"
    MSG="Backup-Verify FEHLER: ${FAILED}/${TOTAL} (${FAILED_FILES[*]})"
fi

# Webhook
source /etc/wp-hosting/config 2>/dev/null || true
if [[ -n "${WEBHOOK_URL:-}" ]] && [[ "$STATUS" == "down" || "${1:-}" == "--notify" || "${2:-}" == "--notify" ]]; then
    curl -fsS -G --data-urlencode "msg=${MSG}" "${WEBHOOK_URL}?status=${STATUS}" \
        -o /dev/null 2>/dev/null || true
fi

[[ $FAILED -eq 0 ]] && exit 0 || exit 1
