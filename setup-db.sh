#!/bin/bash
# Einmalige Einrichtung der Datenbank-VM (MariaDB, optimiert für WordPress/WooCommerce)
# Voraussetzung: Ubuntu 24.04 LTS, als root ausführen

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash setup-db.sh"

clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   Datenbank-VM Setup — Ubuntu 24.04          ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

read -rp "IPs der Web-VMs, kommagetrennt (z.B. 192.168.1.10,192.168.1.11): " WEB_VM_IPS
[[ -z "$WEB_VM_IPS" ]] && err "Mindestens eine Web-VM-IP angeben."

echo ""
echo "Remote-Backup für MariaDB-Dumps konfigurieren?"
echo "  1) Cloudflare R2"
echo "  2) S3-kompatibel (AWS, MinIO, etc.)"
echo "  3) SFTP"
echo "  4) Überspringen (nur lokale Backups)"
echo ""
read -rp "Auswahl [1-4]: " RCLONE_CHOICE

RCLONE_REMOTE=""
case "$RCLONE_CHOICE" in
    1)
        read -rp "R2 Account-ID: " R2_ACCOUNT_ID
        read -rp "R2 Access Key ID: " R2_KEY_ID
        read -rsp "R2 Access Key Secret: " R2_KEY_SECRET; echo ""
        read -rp "R2 Bucket-Name: " R2_BUCKET
        RCLONE_REMOTE="r2"
        RCLONE_DEST="r2:${R2_BUCKET}/mysql-backups"
        ;;
    2)
        read -rp "S3 Region (z.B. eu-central-1): " S3_REGION
        read -rp "S3 Bucket-Name: " S3_BUCKET
        read -rp "S3 Access Key ID: " S3_KEY_ID
        read -rsp "S3 Access Key Secret: " S3_KEY_SECRET; echo ""
        read -rp "S3 Endpoint (leer = AWS Standard): " S3_ENDPOINT
        RCLONE_REMOTE="s3backup"
        RCLONE_DEST="s3backup:${S3_BUCKET}/mysql-backups"
        ;;
    3)
        read -rp "SFTP Host: " SFTP_HOST
        read -rp "SFTP User: " SFTP_USER
        read -rp "SFTP Pfad (z.B. /backups/mysql): " SFTP_PATH
        read -rp "SFTP Port [22]: " SFTP_PORT; SFTP_PORT=${SFTP_PORT:-22}
        RCLONE_REMOTE="sftpbackup"
        RCLONE_DEST="sftpbackup:${SFTP_PATH}"
        ;;
    4) RCLONE_REMOTE="" ;;
    *) warn "Ungültige Auswahl — Remote-Backup übersprungen"; RCLONE_REMOTE="" ;;
esac

echo ""
info "Datenbank-VM wird für ${BOLD}WordPress & WooCommerce${NC} optimiert"
echo ""
read -rp "Einrichtung starten? [j/N]: " confirm
[[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."

# ── System aktualisieren ───────────────────────────────────────────────────
info "System wird aktualisiert..."
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get upgrade -yq
DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
    curl wget ufw ca-certificates mariadb-server \
    unattended-upgrades apt-listchanges
log "Pakete installiert"

# ── rclone installieren ───────────────────────────────────────────────────
if [[ -n "$RCLONE_REMOTE" ]]; then
    if command -v rclone &>/dev/null; then
        log "rclone bereits installiert ($(rclone --version 2>/dev/null | head -1))"
    else
        curl -fsS https://rclone.org/install.sh | bash 2>&1 | tail -3
        log "rclone installiert"
    fi

    mkdir -p /root/.config/rclone
    case "$RCLONE_CHOICE" in
        1) cat >> /root/.config/rclone/rclone.conf <<EOF

[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_KEY_ID}
secret_access_key = ${R2_KEY_SECRET}
endpoint = https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
EOF
            ;;
        2) cat >> /root/.config/rclone/rclone.conf <<EOF

[s3backup]
type = s3
provider = AWS
access_key_id = ${S3_KEY_ID}
secret_access_key = ${S3_KEY_SECRET}
region = ${S3_REGION}
${S3_ENDPOINT:+endpoint = ${S3_ENDPOINT}}
acl = private
EOF
            ;;
        3) cat >> /root/.config/rclone/rclone.conf <<EOF

[sftpbackup]
type = sftp
host = ${SFTP_HOST}
user = ${SFTP_USER}
port = ${SFTP_PORT}
key_file = /root/.ssh/id_rsa
EOF
            warn "SFTP: SSH-Key /root/.ssh/id_rsa muss manuell auf Ziel-Server hinterlegt werden."
            ;;
    esac
    chmod 600 /root/.config/rclone/rclone.conf
    log "rclone konfiguriert (Remote: ${RCLONE_REMOTE})"
fi

# ── Automatische Sicherheitsupdates ───────────────────────────────────────
cat > /etc/apt/apt.conf.d/50unattended-upgrades-wp <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
log "Automatische Sicherheitsupdates konfiguriert"

# ── Swap ──────────────────────────────────────────────────────────────────
if [[ ! -f /swapfile ]]; then
    TOTAL_RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
    if   [[ $TOTAL_RAM_MB -lt 2048 ]];  then SWAP_SIZE="2G"
    elif [[ $TOTAL_RAM_MB -lt 8192 ]];  then SWAP_SIZE="${TOTAL_RAM_MB}M"
    else                                     SWAP_SIZE="4G"
    fi
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo 'vm.swappiness=10'           >> /etc/sysctl.conf
    sysctl -p &>/dev/null
    log "Swap konfiguriert (${SWAP_SIZE}, swappiness=10)"
else
    warn "Swapfile existiert bereits — übersprungen"
fi

# ── MariaDB konfigurieren ─────────────────────────────────────────────────
# Puffergröße dynamisch an verfügbaren RAM anpassen (50% für InnoDB)
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
IB_POOL_MB=$((TOTAL_RAM_MB / 2))
IB_POOL="${IB_POOL_MB}M"

# InnoDB-Instanzen: 1 pro GB Buffer Pool, max 8
IB_INSTANCES=$((IB_POOL_MB / 1024))
[[ $IB_INSTANCES -lt 1 ]] && IB_INSTANCES=1
[[ $IB_INSTANCES -gt 8 ]] && IB_INSTANCES=8

cat > /etc/mysql/conf.d/wordpress-optimized.cnf <<EOF
[mysqld]
# Zeichensatz
character-set-server  = utf8mb4
collation-server      = utf8mb4_unicode_ci

# InnoDB — Kernspeicher
innodb_buffer_pool_size       = ${IB_POOL}
innodb_buffer_pool_instances  = ${IB_INSTANCES}
innodb_log_file_size          = 256M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method           = O_DIRECT
innodb_read_io_threads        = 4
innodb_write_io_threads       = 4
innodb_file_per_table         = 1
innodb_stats_on_metadata      = 0

# Verbindungen
max_connections               = 200
thread_cache_size             = 20
table_open_cache              = 4096
table_definition_cache        = 2048

# Abfragen
tmp_table_size                = 64M
max_heap_table_size           = 64M
join_buffer_size               = 4M
sort_buffer_size               = 4M
read_buffer_size               = 2M
read_rnd_buffer_size           = 2M

# Query Cache deaktiviert (veraltet, schadet mehr als es nützt)
query_cache_size              = 0
query_cache_type              = 0

# Slow Query Log
slow_query_log                = 1
slow_query_log_file           = /var/log/mysql/slow.log
long_query_time               = 2

# Netzwerk — lauscht auf allen Interfaces für Remote-Zugriff
bind-address                  = 0.0.0.0
EOF
log "MariaDB konfiguriert (InnoDB Buffer: ${IB_POOL}, ${IB_INSTANCES} Instanz(en))"

# ── MariaDB sichern & Admin-User anlegen ───────────────────────────────────
systemctl restart mariadb

mysql -e "DELETE FROM mysql.user WHERE User='';"
mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
mysql -e "DROP DATABASE IF EXISTS test;"
mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
mysql -e "FLUSH PRIVILEGES;"

ADMIN_USER="wp_admin"
ADMIN_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32) || true

# Admin-User für jede Web-VM-IP anlegen
IFS=',' read -ra VM_IPS <<< "$WEB_VM_IPS"
for VM_IP in "${VM_IPS[@]}"; do
    VM_IP=$(echo "$VM_IP" | tr -d ' ')
    mysql -e "CREATE OR REPLACE USER '${ADMIN_USER}'@'${VM_IP}' IDENTIFIED BY '${ADMIN_PASS}';"
    mysql -e "GRANT ALL PRIVILEGES ON *.* TO '${ADMIN_USER}'@'${VM_IP}' WITH GRANT OPTION;"
    log "DB-Admin-User für ${VM_IP} angelegt"
done
mysql -e "FLUSH PRIVILEGES;"

# ── UFW ────────────────────────────────────────────────────────────────────
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp

for VM_IP in "${VM_IPS[@]}"; do
    VM_IP=$(echo "$VM_IP" | tr -d ' ')
    ufw allow from "$VM_IP" to any port 3306
    log "UFW: MySQL-Zugriff von ${VM_IP} erlaubt"
done

ufw allow 19999/tcp
ufw --force enable
log "Firewall konfiguriert (22, 3306 von Web-VMs, 19999)"

# ── SSH Hardening ─────────────────────────────────────────────────────────
SSH_CONFIG="/etc/ssh/sshd_config"
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/'          "$SSH_CONFIG"
sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/'                  "$SSH_CONFIG"
sed -i 's/^#*LoginGraceTime.*/LoginGraceTime 20/'             "$SSH_CONFIG"
sed -i 's/^#*X11Forwarding.*/X11Forwarding no/'               "$SSH_CONFIG"
sed -i 's/^#*AllowTcpForwarding.*/AllowTcpForwarding no/'     "$SSH_CONFIG"

echo ""
read -rp "SSH Public Key für ubuntu-User hinterlegen? (leer = überspringen): " SSH_PUB_KEY
if [[ -n "$SSH_PUB_KEY" ]]; then
    mkdir -p /home/ubuntu/.ssh
    echo "$SSH_PUB_KEY" >> /home/ubuntu/.ssh/authorized_keys
    chmod 700 /home/ubuntu/.ssh
    chmod 600 /home/ubuntu/.ssh/authorized_keys
    chown -R ubuntu:ubuntu /home/ubuntu/.ssh 2>/dev/null || true
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
    sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/'    "$SSH_CONFIG"
    log "SSH Key hinterlegt — Passwort-Login deaktiviert"
else
    warn "Kein SSH Key — Passwort-Login bleibt aktiv"
fi
systemctl restart ssh

# ── Netdata ───────────────────────────────────────────────────────────────
if systemctl is-active --quiet netdata 2>/dev/null; then
    log "Netdata bereits installiert"
else
    info "Netdata wird installiert..."
    wget -qO /tmp/netdata-kickstart.sh https://get.netdata.cloud/kickstart.sh
    bash /tmp/netdata-kickstart.sh --non-interactive --stable-channel --disable-telemetry 2>&1 | tail -5 || true
    rm -f /tmp/netdata-kickstart.sh
    log "Netdata installiert (Port 19999)"
fi

# ── MariaDB Backup-Cron ────────────────────────────────────────────────────
mkdir -p /var/backups/mysql
RCLONE_DEST_CFG="${RCLONE_DEST:-}"
cat > /usr/local/bin/mysql-backup.sh <<BEOF
#!/bin/bash
set -eo pipefail
BACKUP_DIR="/var/backups/mysql"
DATE=\$(date +%Y%m%d_%H%M)
KEEP_DAYS=7
LOG="/var/log/mysql-backup.log"
OUTFILE="\${BACKUP_DIR}/all-databases_\${DATE}.sql.gz"
RCLONE_DEST="${RCLONE_DEST_CFG}"

echo "[\$(date '+%Y-%m-%d %H:%M')] Backup gestartet" >> "\$LOG"
if mysqldump --all-databases --single-transaction --quick --lock-tables=false \
    | gzip > "\$OUTFILE"; then
    SIZE=\$(du -sh "\$OUTFILE" | cut -f1)
    echo "[\$(date '+%Y-%m-%d %H:%M')] Lokal OK — \${SIZE}" >> "\$LOG"

    # Remote-Upload via rclone
    if [[ -n "\$RCLONE_DEST" ]] && command -v rclone &>/dev/null; then
        rclone copy "\$OUTFILE" "\$RCLONE_DEST" 2>> "\$LOG"
        if [[ \$? -eq 0 ]]; then
            echo "[\$(date '+%Y-%m-%d %H:%M')] Remote-Upload OK → \${RCLONE_DEST}" >> "\$LOG"
        else
            echo "[\$(date '+%Y-%m-%d %H:%M')] Remote-Upload FEHLER!" >> "\$LOG"
        fi
    fi
else
    echo "[\$(date '+%Y-%m-%d %H:%M')] FEHLER beim Backup!" >> "\$LOG"
fi

find "\$BACKUP_DIR" -name "*.sql.gz" -mtime +\${KEEP_DAYS} -delete
BEOF
chmod +x /usr/local/bin/mysql-backup.sh
echo "0 2 * * * root /usr/local/bin/mysql-backup.sh" > /etc/cron.d/mysql-backup
log "MariaDB Backup-Cron konfiguriert (täglich 02:00 → /var/backups/mysql, 7 Tage)"

# ── Services starten ───────────────────────────────────────────────────────
systemctl enable mariadb
systemctl restart mariadb
log "MariaDB gestartet"

# ── Zusammenfassung ────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗"
echo -e "║   Setup abgeschlossen ✓                      ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  DB-Host-IP:    ${BOLD}$(hostname -I | awk '{print $1}')${NC}"
echo ""
echo -e "${BOLD}  Diese Daten bei setup-web.sh eingeben:${NC}"
echo -e "  DB-Admin-User: ${BOLD}${ADMIN_USER}${NC}"
echo -e "  DB-Admin-Pass: ${BOLD}${ADMIN_PASS}${NC}"
echo ""
echo -e "  InnoDB Buffer: ${BOLD}${IB_POOL}${NC}"
echo ""

# Zugangsdaten lokal sichern
mkdir -p /etc/wp-hosting
cat > /etc/wp-hosting/db-credentials.txt <<EOF
DB_HOST=$(hostname -I | awk '{print $1}')
DB_ADMIN_USER=${ADMIN_USER}
DB_ADMIN_PASS=${ADMIN_PASS}
EOF
chmod 600 /etc/wp-hosting/db-credentials.txt
echo -e "  Netdata:       ${BOLD}http://$(hostname -I | awk '{print $1}'):19999${NC}"
echo ""
echo -e "${YELLOW}  → Zugangsdaten gespeichert: /etc/wp-hosting/db-credentials.txt${NC}"
echo -e "${YELLOW}  → Unbedingt notieren — werden nur einmal angezeigt!${NC}"
echo -e "${YELLOW}  → Netdata in Uptime Kuma als Monitor hinzufügen.${NC}"
echo ""
