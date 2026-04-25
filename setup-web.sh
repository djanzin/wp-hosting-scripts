#!/bin/bash
# Einmalige Einrichtung einer WordPress-Web-VM (Nginx, PHP 8.3, Redis, phpMyAdmin, Filebrowser)
# Voraussetzung: Ubuntu 24.04 LTS, als root ausführen

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash setup-web.sh"
[[ ! -f /etc/os-release ]] || ! grep -q "24.04" /etc/os-release && warn "Skript optimiert für Ubuntu 24.04"

clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   WordPress Web-VM Setup — Ubuntu 24.04      ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ── VM-Typ ─────────────────────────────────────────────────────────────────
echo "Welche Art von Web-VM wird eingerichtet?"
echo "  1) WordPress (Standard)"
echo "  2) WooCommerce (Performance-optimiert)"
echo ""
read -rp "Auswahl [1/2]: " vm_choice
case "$vm_choice" in
    1) VM_TYPE="wordpress" ;;
    2) VM_TYPE="woocommerce" ;;
    *) err "Ungültige Auswahl." ;;
esac

# ── Konfiguration abfragen ─────────────────────────────────────────────────
echo ""
read -rp "IP-Adresse der Datenbank-VM (z.B. 192.168.1.100): " DB_HOST
[[ -z "$DB_HOST" ]] && err "DB-Host darf nicht leer sein."

read -rp "DB-Admin-Benutzer (von setup-db.sh ausgegeben): " DB_ADMIN_USER
[[ -z "$DB_ADMIN_USER" ]] && err "DB-Admin-Benutzer darf nicht leer sein."

read -rsp "DB-Admin-Passwort (von setup-db.sh ausgegeben): " DB_ADMIN_PASS
echo ""
[[ -z "$DB_ADMIN_PASS" ]] && err "DB-Admin-Passwort darf nicht leer sein."

read -rp "Standard-Admin-E-Mail für WordPress-Sites: " WP_ADMIN_EMAIL
[[ -z "$WP_ADMIN_EMAIL" ]] && err "E-Mail darf nicht leer sein."

read -rp "IP-Adresse des Nginx Proxy Managers (für Real-IP): " NPM_IP
[[ -z "$NPM_IP" ]] && NPM_IP="127.0.0.1"

read -rp "Webhook-URL für Benachrichtigungen (leer = deaktiviert): " WEBHOOK_URL

echo ""
info "VM-Typ: ${BOLD}${VM_TYPE}${NC}"
info "DB-Host: ${BOLD}${DB_HOST}${NC}"
echo ""
read -rp "Einrichtung starten? [j/N]: " confirm
[[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."

# ── System aktualisieren ───────────────────────────────────────────────────
info "System wird aktualisiert..."
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get upgrade -yq
DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
    curl wget unzip git ca-certificates gnupg \
    fail2ban ufw mysql-client \
    unattended-upgrades apt-listchanges \
    nginx redis-server \
    php8.3-fpm php8.3-mysql php8.3-redis php8.3-curl php8.3-gd \
    php8.3-mbstring php8.3-xml php8.3-zip php8.3-intl \
    php8.3-soap php8.3-bcmath php8.3-imagick php8.3-opcache
log "Pakete installiert"

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
    echo 'vm.vfs_cache_pressure=50'   >> /etc/sysctl.conf
    sysctl -p &>/dev/null
    log "Swap konfiguriert (${SWAP_SIZE}, swappiness=10)"
else
    warn "Swapfile existiert bereits — übersprungen"
fi

# ── WP-CLI ────────────────────────────────────────────────────────────────
curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
mv wp-cli.phar /usr/local/bin/wp
log "WP-CLI installiert"

# ── PHP 8.3 konfigurieren ─────────────────────────────────────────────────
PHP_INI="/etc/php/8.3/fpm/php.ini"

if [[ "$VM_TYPE" == "woocommerce" ]]; then
    MEM_LIMIT="512M"; UPLOAD_SIZE="128M"; MAX_EXEC="300"
    MAX_INPUT_VARS="10000"; OPCACHE_MEM="256"; OPCACHE_FILES="20000"
else
    MEM_LIMIT="256M"; UPLOAD_SIZE="64M"; MAX_EXEC="60"
    MAX_INPUT_VARS="5000"; OPCACHE_MEM="128"; OPCACHE_FILES="10000"
fi

sed -i "s/memory_limit = .*/memory_limit = ${MEM_LIMIT}/" "$PHP_INI"
sed -i "s/upload_max_filesize = .*/upload_max_filesize = ${UPLOAD_SIZE}/" "$PHP_INI"
sed -i "s/post_max_size = .*/post_max_size = ${UPLOAD_SIZE}/" "$PHP_INI"
sed -i "s/max_execution_time = .*/max_execution_time = ${MAX_EXEC}/" "$PHP_INI"
sed -i "s/max_input_time = .*/max_input_time = ${MAX_EXEC}/" "$PHP_INI"
sed -i "/max_input_vars/d" "$PHP_INI"
echo "max_input_vars = ${MAX_INPUT_VARS}" >> "$PHP_INI"

# OPcache
cat >> "$PHP_INI" <<EOF

[opcache]
opcache.enable=1
opcache.memory_consumption=${OPCACHE_MEM}
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=${OPCACHE_FILES}
opcache.revalidate_freq=2
opcache.fast_shutdown=1
opcache.enable_cli=0
opcache.validate_timestamps=1
opcache.save_comments=1
EOF
log "PHP 8.3 konfiguriert (${MEM_LIMIT} RAM, OPcache ${OPCACHE_MEM}MB)"

# ── Redis konfigurieren ───────────────────────────────────────────────────
REDIS_MEM=$( [[ "$VM_TYPE" == "woocommerce" ]] && echo "512mb" || echo "256mb" )

sed -i "s/^# maxmemory .*/maxmemory ${REDIS_MEM}/" /etc/redis/redis.conf
sed -i "s/^maxmemory .*/maxmemory ${REDIS_MEM}/" /etc/redis/redis.conf
grep -q "^maxmemory " /etc/redis/redis.conf || echo "maxmemory ${REDIS_MEM}" >> /etc/redis/redis.conf

sed -i "s/^# maxmemory-policy.*/maxmemory-policy allkeys-lru/" /etc/redis/redis.conf
sed -i "s/^maxmemory-policy.*/maxmemory-policy allkeys-lru/" /etc/redis/redis.conf
grep -q "^maxmemory-policy" /etc/redis/redis.conf || echo "maxmemory-policy allkeys-lru" >> /etc/redis/redis.conf

# Persistenz deaktivieren — Redis dient nur als Cache
sed -i "s/^save /# save /" /etc/redis/redis.conf
log "Redis konfiguriert (${REDIS_MEM} RAM, allkeys-lru)"

# ── Nginx Basis-Konfiguration ─────────────────────────────────────────────
cat > /etc/nginx/nginx.conf <<'NGINXEOF'
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 2048;
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 30;
    keepalive_requests 1000;
    types_hash_max_size 2048;
    server_tokens off;
    client_max_body_size 128M;
    client_body_buffer_size 128k;
    client_header_timeout 30s;
    client_body_timeout 30s;
    send_timeout 30s;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 5;
    gzip_min_length 256;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml image/svg+xml;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent"';
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
NGINXEOF

# FastCGI-Cache nur auf WooCommerce-VMs
if [[ "$VM_TYPE" == "woocommerce" ]]; then
    mkdir -p /var/cache/nginx/wp
    chown www-data:www-data /var/cache/nginx/wp
    cat > /etc/nginx/conf.d/fastcgi-cache.conf <<'CACHEEOF'
# WooCommerce FastCGI Cache
fastcgi_cache_path /var/cache/nginx/wp levels=1:2 keys_zone=WPCACHE:100m max_size=10g inactive=60m use_temp_path=off;
CACHEEOF
    log "Nginx FastCGI-Cache konfiguriert"
fi

# Real-IP: NPM + Cloudflare IP-Ranges
# Mit real_ip_recursive entfernt Nginx die vertrauenswürdigen IPs aus
# X-Forwarded-For von hinten → übrig bleibt die echte Besucher-IP,
# die dann für Rate-Limiting und Logs verwendet wird.
cat > /etc/nginx/conf.d/real-ip.conf <<EOF
# Nginx Proxy Manager (interner Proxy)
set_real_ip_from ${NPM_IP};

# Cloudflare IPv4-Ranges (https://www.cloudflare.com/ips/)
set_real_ip_from 103.21.244.0/22;
set_real_ip_from 103.22.200.0/22;
set_real_ip_from 103.31.4.0/22;
set_real_ip_from 104.16.0.0/13;
set_real_ip_from 104.24.0.0/14;
set_real_ip_from 108.162.192.0/18;
set_real_ip_from 131.0.72.0/22;
set_real_ip_from 141.101.64.0/18;
set_real_ip_from 162.158.0.0/15;
set_real_ip_from 172.64.0.0/13;
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 188.114.96.0/20;
set_real_ip_from 190.93.240.0/20;
set_real_ip_from 197.234.240.0/22;
set_real_ip_from 198.41.128.0/17;

# Cloudflare IPv6-Ranges
set_real_ip_from 2400:cb00::/32;
set_real_ip_from 2606:4700::/32;
set_real_ip_from 2803:f800::/32;
set_real_ip_from 2405:b500::/32;
set_real_ip_from 2405:8100::/32;
set_real_ip_from 2a06:98c0::/29;
set_real_ip_from 2c0f:f248::/32;

real_ip_header    X-Forwarded-For;
real_ip_recursive on;
EOF

rm -f /etc/nginx/sites-enabled/default
log "Nginx konfiguriert"

# ── Log-Rotation ──────────────────────────────────────────────────────────
cat > /etc/logrotate.d/wordpress-hosting <<'EOF'
/var/log/nginx/*.log /var/log/php/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 www-data adm
    sharedscripts
    postrotate
        nginx -s reopen 2>/dev/null || true
        systemctl reload php8.3-fpm 2>/dev/null || true
    endscript
}
EOF
log "Log-Rotation konfiguriert (14 Tage, täglich komprimiert)"

# ── phpMyAdmin ────────────────────────────────────────────────────────────
info "phpMyAdmin wird installiert..."
PMA_VERSION="5.2.2"
PMA_DIR="/var/www/phpmyadmin"

wget -q "https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}/phpMyAdmin-${PMA_VERSION}-all-languages.tar.gz" -O /tmp/pma.tar.gz
tar -xzf /tmp/pma.tar.gz -C /tmp/
mv "/tmp/phpMyAdmin-${PMA_VERSION}-all-languages" "$PMA_DIR"
rm /tmp/pma.tar.gz

BLOWFISH_SECRET=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32) || true

cat > "${PMA_DIR}/config.inc.php" <<EOF
<?php
\$cfg['blowfish_secret'] = '${BLOWFISH_SECRET}';
\$cfg['Servers'][1]['host'] = '${DB_HOST}';
\$cfg['Servers'][1]['port'] = '3306';
\$cfg['Servers'][1]['connect_type'] = 'tcp';
\$cfg['Servers'][1]['compress'] = false;
\$cfg['Servers'][1]['AllowNoPassword'] = false;
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';
\$cfg['TempDir'] = '/tmp/phpmyadmin';
\$cfg['CheckConfigurationPermissions'] = false;
EOF

mkdir -p /tmp/phpmyadmin
chown www-data:www-data /tmp/phpmyadmin
chown -R www-data:www-data "$PMA_DIR"

cat > /etc/nginx/sites-available/phpmyadmin <<EOF
server {
    listen 8080;
    server_name _;
    root ${PMA_DIR};
    index index.php;

    access_log /var/log/nginx/phpmyadmin.access.log;
    error_log  /var/log/nginx/phpmyadmin.error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(ht|git) {
        deny all;
    }
}
EOF
ln -sf /etc/nginx/sites-available/phpmyadmin /etc/nginx/sites-enabled/
log "phpMyAdmin installiert (Port 8080 → DB: ${DB_HOST})"

# ── Filebrowser ───────────────────────────────────────────────────────────
if command -v filebrowser &>/dev/null; then
    info "Filebrowser bereits installiert"
else
    info "Filebrowser wird installiert..."
    FB_VERSION=$(curl -s https://api.github.com/repos/filebrowser/filebrowser/releases/latest | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
    wget -q "https://github.com/filebrowser/filebrowser/releases/download/v${FB_VERSION}/linux-amd64-filebrowser.tar.gz" -O /tmp/fb.tar.gz
    tar -xzf /tmp/fb.tar.gz -C /usr/local/bin/ filebrowser
    chmod +x /usr/local/bin/filebrowser
    rm /tmp/fb.tar.gz
fi

mkdir -p /etc/filebrowser
FB_ADMIN_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 24) || true
FB_HASHED_PASS=$(filebrowser hash "$FB_ADMIN_PASS" 2>/dev/null || echo "$FB_ADMIN_PASS")

cat > /etc/filebrowser/settings.json <<'EOF'
{
  "port": 8090,
  "baseURL": "",
  "address": "0.0.0.0",
  "log": "stdout",
  "database": "/etc/filebrowser/database.db",
  "root": "/var/www"
}
EOF

filebrowser config init --database /etc/filebrowser/database.db \
    --address 0.0.0.0 --port 8090 --root /var/www 2>/dev/null || true
filebrowser users add admin "$FB_ADMIN_PASS" --perm.admin --database /etc/filebrowser/database.db 2>/dev/null || true

cat > /etc/systemd/system/filebrowser.service <<'EOF'
[Unit]
Description=Filebrowser
After=network.target

[Service]
ExecStart=/usr/local/bin/filebrowser --config /etc/filebrowser/settings.json --database /etc/filebrowser/database.db
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable filebrowser
log "Filebrowser installiert (Port 8090)"

# ── Fail2ban ─────────────────────────────────────────────────────────────
cat > /etc/fail2ban/jail.d/wordpress.conf <<'EOF'
[nginx-req-limit]
enabled = true
filter  = nginx-req-limit
logpath = /var/log/nginx/*.error.log
maxretry = 10
bantime  = 3600

[sshd]
enabled = true
maxretry = 5
bantime  = 3600
EOF
log "Fail2ban konfiguriert"

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

# ── UFW ───────────────────────────────────────────────────────────────────
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
# phpMyAdmin + Filebrowser nur vom NPM erreichbar
ufw allow from "$NPM_IP" to any port 8080
ufw allow from "$NPM_IP" to any port 8090
ufw allow 19999/tcp
ufw --force enable
log "Firewall konfiguriert (22, 80 offen | 8080+8090 nur von NPM: ${NPM_IP} | 19999)"

# ── Verzeichnisstruktur ───────────────────────────────────────────────────
mkdir -p /var/www
mkdir -p /etc/wp-hosting/sites
chown -R www-data:www-data /var/www

# Verbindung zur DB testen
info "Datenbankverbindung wird getestet..."
if mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" -p"$DB_ADMIN_PASS" -e "SELECT 1;" &>/dev/null; then
    log "Datenbankverbindung erfolgreich"
else
    warn "Datenbankverbindung fehlgeschlagen — bitte nach dem Setup prüfen"
fi

# ── Wöchentlicher Auto-Update Cron ────────────────────────────────────────
echo ""
read -rp "Wöchentliche automatische WordPress-Updates aktivieren? (sonntags 03:00) [j/N]: " AUTO_UPDATE
if [[ "$AUTO_UPDATE" == "j" || "$AUTO_UPDATE" == "J" ]]; then
    cat > /usr/local/bin/wp-auto-update.sh <<'AUEOF'
#!/bin/bash
# Wöchentlicher automatischer WordPress-Update (alle Sites, kein Interaktion)
source /etc/wp-hosting/config 2>/dev/null || exit 1
LOG="/var/log/wp-auto-update.log"
SITES_DIR="/etc/wp-hosting/sites"
UPDATED=0; FAILED=0

echo "[$(date '+%Y-%m-%d %H:%M')] Auto-Update gestartet" >> "$LOG"

for CRED_FILE in "${SITES_DIR}"/*.txt; do
    DOMAIN=$(basename "$CRED_FILE" .txt)
    SITE_PATH="/var/www/${DOMAIN}"
    [[ ! -d "$SITE_PATH" ]] && continue

    WP="wp --path=${SITE_PATH} --allow-root"
    $WP maintenance-mode activate 2>/dev/null || true
    $WP core update            2>>"$LOG" && \
    $WP plugin update --all    2>>"$LOG" && \
    $WP theme update --all     2>>"$LOG" && \
    $WP core update-db         2>>"$LOG" && \
    $WP cache flush            2>/dev/null || true
    EXIT=$?
    $WP maintenance-mode deactivate 2>/dev/null || true

    if [[ $EXIT -eq 0 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M')] OK: ${DOMAIN}" >> "$LOG"
        ((UPDATED++))
    else
        echo "[$(date '+%Y-%m-%d %H:%M')] FEHLER: ${DOMAIN}" >> "$LOG"
        ((FAILED++))
    fi
done

# FastCGI Cache leeren
[[ -d /var/cache/nginx/wp ]] && rm -rf /var/cache/nginx/wp/* 2>/dev/null || true

MSG="Auto-Update: ${UPDATED} OK, ${FAILED} Fehler"
echo "[$(date '+%Y-%m-%d %H:%M')] ${MSG}" >> "$LOG"

# Webhook-Benachrichtigung
if [[ -n "${WEBHOOK_URL:-}" ]]; then
    STATUS=$( [[ $FAILED -eq 0 ]] && echo "up" || echo "down" )
    curl -fsS "${WEBHOOK_URL}?status=${STATUS}&msg=${MSG}" -o /dev/null 2>/dev/null || true
fi
AUEOF
    chmod +x /usr/local/bin/wp-auto-update.sh
    echo "0 3 * * 0 root /usr/local/bin/wp-auto-update.sh" > /etc/cron.d/wp-auto-update
    log "Auto-Update-Cron aktiviert (sonntags 03:00 → /var/log/wp-auto-update.log)"
fi

# Konfiguration speichern
cat > /etc/wp-hosting/config <<EOF
VM_TYPE=${VM_TYPE}
DB_HOST=${DB_HOST}
DB_ADMIN_USER=${DB_ADMIN_USER}
DB_ADMIN_PASS=${DB_ADMIN_PASS}
WP_ADMIN_EMAIL=${WP_ADMIN_EMAIL}
NPM_IP=${NPM_IP}
WEBHOOK_URL=${WEBHOOK_URL:-}
EOF
chmod 600 /etc/wp-hosting/config

# ── Services starten ──────────────────────────────────────────────────────
systemctl restart php8.3-fpm
systemctl restart nginx
systemctl restart redis-server
systemctl restart fail2ban
systemctl start filebrowser
log "Alle Services gestartet"

# ── Zusammenfassung ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗"
echo -e "║   Setup abgeschlossen ✓                      ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  VM-Typ:        ${BOLD}${VM_TYPE}${NC}"
echo -e "  DB-Host:       ${BOLD}${DB_HOST}${NC}"
echo -e "  phpMyAdmin:    ${BOLD}http://$(hostname -I | awk '{print $1}'):8080${NC}"
echo -e "  Filebrowser:   ${BOLD}http://$(hostname -I | awk '{print $1}'):8090${NC}"
echo -e "  FB Benutzer:   ${BOLD}admin${NC}"
echo -e "  FB Passwort:   ${BOLD}${FB_ADMIN_PASS}${NC}"
echo ""
echo -e "  Netdata:       ${BOLD}http://$(hostname -I | awk '{print $1}'):19999${NC}"
echo -e "  Konfiguration: ${BOLD}/etc/wp-hosting/config${NC}"
echo -e "  Sites:         ${BOLD}/etc/wp-hosting/sites/<domain>.txt${NC}"
echo ""
echo -e "${YELLOW}  → Filebrowser-Passwort notieren!${NC}"
echo -e "${YELLOW}  → NPM Proxy-Hosts für Port 8080, 8090 und 19999 anlegen.${NC}"
echo -e "${YELLOW}  → Netdata in Uptime Kuma als Monitor hinzufügen.${NC}"
echo ""
