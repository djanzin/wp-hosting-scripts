#!/bin/bash
# Manueller MariaDB-Dump aller WordPress-Datenbanken
# Wird automatisch täglich um 02:00 via /etc/cron.d/mysql-backup ausgeführt
# Kann auch manuell gestartet werden: sudo bash db-backup.sh
#
# Verhalten identisch zum Auto-Cron (/usr/local/bin/mysql-backup.sh):
#   - Encryption mit age, falls /etc/wp-hosting/backup-recipient.txt existiert
#   - Mirror auf Remote via rclone sync (Ziel aus /etc/wp-hosting/db-backup.conf)
#   - flock auf /var/lock/mysql-backup.lock — verhindert Konflikt mit 02:00-Cron

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

# Remote-Ziel aus zentraler Config (von setup-db.sh geschrieben)
RCLONE_DEST=""
[[ -f /etc/wp-hosting/db-backup.conf ]] && source /etc/wp-hosting/db-backup.conf

# Encryption aktiv? — gleiche Detection wie Auto-Cron
RECIPIENT_FILE="/etc/wp-hosting/backup-recipient.txt"
ENCRYPT=false
EXT="sql.gz"
if [[ -f "$RECIPIENT_FILE" ]] && command -v age &>/dev/null; then
    ENCRYPT=true
    EXT="sql.gz.age"
fi

# flock — blockiert wenn Auto-Cron gerade läuft (oder paralleler manueller Lauf)
exec 9>/var/lock/mysql-backup.lock
if ! flock -n 9; then
    err "Auto-Cron-Backup läuft gerade (oder paralleler manueller Lauf) — bitte später erneut starten."
fi

clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   MariaDB Backup                             ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

if $ENCRYPT; then
    info "Verschlüsselung: ${BOLD}aktiv${NC}${BLUE} (age, Recipient: ${RECIPIENT_FILE})"
else
    info "Verschlüsselung: ${BOLD}aus${NC}${BLUE} (Recipient-File nicht vorhanden oder age fehlt)"
fi
if [[ -n "$RCLONE_DEST" ]]; then
    info "Remote-Mirror:  ${BOLD}${RCLONE_DEST}${NC}"
else
    warn "Remote-Mirror nicht konfiguriert — Backup bleibt lokal-only."
fi
echo ""

echo "Was soll gesichert werden?"
echo "  1) Alle Datenbanken (ein File)"
echo "  2) Jede Datenbank einzeln"
echo ""
read -rp "Auswahl [1/2]: " backup_choice

info "Backup wird erstellt..."

case "$backup_choice" in
    1)
        OUTFILE="${BACKUP_DIR}/all-databases_${DATE}.${EXT}"
        if $ENCRYPT; then
            mysqldump --all-databases \
                --single-transaction \
                --quick \
                --lock-tables=false \
                --skip-lock-tables \
                | gzip | age -R "$RECIPIENT_FILE" -o "$OUTFILE"
        else
            mysqldump --all-databases \
                --single-transaction \
                --quick \
                --lock-tables=false \
                --skip-lock-tables \
                | gzip > "$OUTFILE"
        fi
        SIZE=$(du -sh "$OUTFILE" | cut -f1)
        log "Alle Datenbanken → ${OUTFILE} (${SIZE})"
        echo "[$(date '+%Y-%m-%d %H:%M')] Manuell: All-DB Backup OK — ${SIZE} (encrypt=${ENCRYPT})" >> "$LOG"
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
            OUTFILE="${BACKUP_DIR}/${DATE}/${DB}.${EXT}"
            if $ENCRYPT; then
                mysqldump "$DB" \
                    --single-transaction \
                    --quick \
                    --lock-tables=false \
                    | gzip | age -R "$RECIPIENT_FILE" -o "$OUTFILE"
            else
                mysqldump "$DB" \
                    --single-transaction \
                    --quick \
                    --lock-tables=false \
                    | gzip > "$OUTFILE"
            fi
            SIZE=$(du -sh "$OUTFILE" | cut -f1)
            log "${DB} → ${OUTFILE} (${SIZE})"
        done <<< "$DBS"
        echo "[$(date '+%Y-%m-%d %H:%M')] Manuell: Einzel-DB Backup OK (${DATE}, encrypt=${ENCRYPT})" >> "$LOG"
        ;;
    *) err "Ungültige Auswahl." ;;
esac

# Alte Backups aufräumen — flach UND in Subdirs, verschlüsselt UND unverschlüsselt
find "$BACKUP_DIR" \( -name "*.sql.gz" -o -name "*.sql.gz.age" \) -mtime +"$KEEP_DAYS" -delete 2>/dev/null || true
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$KEEP_DAYS" \
    -exec rm -rf {} + 2>/dev/null || true

# Mirror nach Remote — gleiche Flags wie Auto-Cron
SYNC_STATUS="übersprungen"
if [[ -n "$RCLONE_DEST" ]] && command -v rclone &>/dev/null; then
    info "Mirror nach Remote: ${RCLONE_DEST}"
    if rclone sync "$BACKUP_DIR" "$RCLONE_DEST" \
        --bwlimit "08:00,8M 22:00,off" \
        --transfers 4 --checkers 8 \
        2>>"$LOG"; then
        log "Remote-Sync OK"
        echo "[$(date '+%Y-%m-%d %H:%M')] Manueller Sync OK → ${RCLONE_DEST}" >> "$LOG"
        SYNC_STATUS="OK → ${RCLONE_DEST}"
    else
        warn "Remote-Sync fehlgeschlagen — Backup liegt nur lokal."
        echo "[$(date '+%Y-%m-%d %H:%M')] Manueller Sync FEHLER" >> "$LOG"
        SYNC_STATUS="FEHLER (siehe ${LOG})"
    fi
elif [[ -z "$RCLONE_DEST" ]]; then
    warn "RCLONE_DEST nicht konfiguriert — kein Remote-Sync. (/etc/wp-hosting/db-backup.conf prüfen)"
    SYNC_STATUS="nicht konfiguriert"
elif ! command -v rclone &>/dev/null; then
    warn "rclone nicht installiert — kein Remote-Sync."
    SYNC_STATUS="rclone fehlt"
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗"
echo -e "║   Backup abgeschlossen ✓                     ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Backup-Verzeichnis: ${BOLD}${BACKUP_DIR}${NC}"
echo -e "  Verschlüsselung:    ${BOLD}$($ENCRYPT && echo "aktiv (age)" || echo "aus")${NC}"
echo -e "  Remote-Mirror:      ${BOLD}${SYNC_STATUS}${NC}"
echo -e "  Aufbewahrung:       ${BOLD}${KEEP_DAYS} Tage${NC}"
echo -e "  Log:                ${BOLD}${LOG}${NC}"
echo ""
