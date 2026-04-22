#!/bin/bash
# Manueller MariaDB-Dump aller WordPress-Datenbanken
# Wird automatisch täglich um 02:00 via /etc/cron.d/mysql-backup ausgeführt
# Kann auch manuell gestartet werden: sudo bash db-backup.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen."

BACKUP_DIR="/var/backups/mysql"
DATE=$(date +%Y%m%d_%H%M)
KEEP_DAYS=7
LOG="/var/log/mysql-backup.log"

mkdir -p "$BACKUP_DIR"

clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   MariaDB Backup                             ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

echo "Was soll gesichert werden?"
echo "  1) Alle Datenbanken (ein File)"
echo "  2) Jede Datenbank einzeln"
echo ""
read -rp "Auswahl [1/2]: " backup_choice

info "Backup wird erstellt..."

case "$backup_choice" in
    1)
        OUTFILE="${BACKUP_DIR}/all-databases_${DATE}.sql.gz"
        mysqldump --all-databases \
            --single-transaction \
            --quick \
            --lock-tables=false \
            --skip-lock-tables \
            | gzip > "$OUTFILE"
        SIZE=$(du -sh "$OUTFILE" | cut -f1)
        log "Alle Datenbanken → ${OUTFILE} (${SIZE})"
        echo "[$(date '+%Y-%m-%d %H:%M')] All-DB Backup OK — ${SIZE}" >> "$LOG"
        ;;
    2)
        # Nur WordPress-Datenbanken (Präfix wp_)
        DBS=$(mysql -e "SHOW DATABASES;" | grep -E "^wp_" || true)
        if [[ -z "$DBS" ]]; then
            warn "Keine wp_* Datenbanken gefunden."
            exit 0
        fi
        mkdir -p "${BACKUP_DIR}/${DATE}"
        while IFS= read -r DB; do
            OUTFILE="${BACKUP_DIR}/${DATE}/${DB}.sql.gz"
            mysqldump "$DB" \
                --single-transaction \
                --quick \
                --lock-tables=false \
                | gzip > "$OUTFILE"
            SIZE=$(du -sh "$OUTFILE" | cut -f1)
            log "${DB} → ${OUTFILE} (${SIZE})"
        done <<< "$DBS"
        echo "[$(date '+%Y-%m-%d %H:%M')] Einzel-DB Backup OK (${DATE})" >> "$LOG"
        ;;
    *) err "Ungültige Auswahl." ;;
esac

# Alte Backups aufräumen
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +"$KEEP_DAYS" -delete 2>/dev/null || true
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$KEEP_DAYS" \
    -exec rm -rf {} + 2>/dev/null || true

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗"
echo -e "║   Backup abgeschlossen ✓                     ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Backup-Verzeichnis: ${BOLD}${BACKUP_DIR}${NC}"
echo -e "  Aufbewahrung:       ${BOLD}${KEEP_DAYS} Tage${NC}"
echo -e "  Log:                ${BOLD}${LOG}${NC}"
echo ""
