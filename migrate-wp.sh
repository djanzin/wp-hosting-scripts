#!/bin/bash
# Migriert eine externe WordPress-Site auf diesen Server
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen
# Methoden: SSH (rsync) oder lokale Tar-Datei + SQL-Dump

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash migrate-wp.sh"
[[ ! -f /etc/wp-hosting/config ]] && err "Konfiguration nicht gefunden. Bitte zuerst setup-web.sh ausführen."
command -v wp &>/dev/null || err "WP-CLI nicht gefunden."

source /etc/wp-hosting/config

clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   WordPress Site migrieren                   ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Ziel-Domain ───────────────────────────────────────────────────────────
read -rp "Ziel-Domain auf diesem Server (z.B. meinshop.de): " DOMAIN
DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/^www\.//')
[[ -z "$DOMAIN" ]] && err "Domain darf nicht leer sein."
[[ -d "/var/www/${DOMAIN}" ]] && err "Site '${DOMAIN}' existiert bereits."

echo ""
echo "Typ der Site?"
echo "  1) WordPress"
echo "  2) WooCommerce"
echo ""
read -rp "Auswahl [1/2]: " site_choice
case "$site_choice" in
    1) SITE_TYPE="wordpress" ;;
    2) SITE_TYPE="woocommerce" ;;
    *) err "Ungültige Auswahl." ;;
esac

echo ""
echo "Wie sollen Dateien und Datenbank übertragen werden?"
echo "  1) SSH (rsync vom Quell-Server)"
echo "  2) Lokale Dateien (tar.gz + SQL-Dump bereits auf diesem Server)"
echo ""
read -rp "Auswahl [1/2]: " method_choice

# ── Variablen ──────────────────────────────────────────────────────────────
DOMAIN_SAFE=$(echo "$DOMAIN" | tr '.' '_' | tr '-' '_')
SITE_PATH="/var/www/${DOMAIN}"
DB_NAME="wp_${DOMAIN_SAFE}"
DB_USER="wpdb_$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 10)"
DB_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32)
SYSTEM_USER="wp_${DOMAIN_SAFE:0:20}"
WEB_VM_IP=$(hostname -I | awk '{print $1}')

case "$method_choice" in
    1)
        # ── SSH-Methode ────────────────────────────────────────────────────
        read -rp "SSH-Zugang zum Quell-Server (user@host): " SRC_SSH
        [[ -z "$SRC_SSH" ]] && err "SSH-Zugang darf nicht leer sein."

        read -rp "WordPress-Pfad auf dem Quell-Server (z.B. /var/www/html): " SRC_PATH
        [[ -z "$SRC_PATH" ]] && err "Quell-Pfad darf nicht leer sein."

        read -rp "Alter Domain-Name auf dem Quell-Server: " SRC_DOMAIN
        [[ -z "$SRC_DOMAIN" ]] && err "Alte Domain darf nicht leer sein."

        # DB-Zugangsdaten aus wp-config.php lesen
        info "Lese Datenbank-Zugangsdaten vom Quell-Server..."
        SRC_DB_NAME=$(ssh -o StrictHostKeyChecking=no "$SRC_SSH" \
            "grep DB_NAME ${SRC_PATH}/wp-config.php | grep -o \"'[^']*'\" | tail -1 | tr -d \"'\"" 2>/dev/null || echo "")
        SRC_DB_USER=$(ssh -o StrictHostKeyChecking=no "$SRC_SSH" \
            "grep DB_USER ${SRC_PATH}/wp-config.php | grep -o \"'[^']*'\" | tail -1 | tr -d \"'\"" 2>/dev/null || echo "")
        SRC_DB_PASS=$(ssh -o StrictHostKeyChecking=no "$SRC_SSH" \
            "grep DB_PASSWORD ${SRC_PATH}/wp-config.php | grep -o \"'[^']*'\" | tail -1 | tr -d \"'\"" 2>/dev/null || echo "")
        SRC_DB_HOST=$(ssh -o StrictHostKeyChecking=no "$SRC_SSH" \
            "grep DB_HOST ${SRC_PATH}/wp-config.php | grep -o \"'[^']*'\" | tail -1 | tr -d \"'\"" 2>/dev/null || echo "localhost")

        if [[ -z "$SRC_DB_NAME" ]]; then
            warn "Konnte DB-Daten nicht automatisch lesen."
            read -rp "Datenbank-Name auf Quell-Server: " SRC_DB_NAME
            read -rp "Datenbank-User auf Quell-Server: " SRC_DB_USER
            read -rsp "Datenbank-Passwort auf Quell-Server: " SRC_DB_PASS; echo ""
            read -rp "Datenbank-Host auf Quell-Server [localhost]: " SRC_DB_HOST
            SRC_DB_HOST=${SRC_DB_HOST:-localhost}
        else
            log "DB-Zugangsdaten gelesen (DB: ${SRC_DB_NAME})"
        fi

        echo ""
        info "Quelle:  ${BOLD}${SRC_SSH}:${SRC_PATH}${NC}"
        info "Ziel:    ${BOLD}${SITE_PATH}${NC}"
        echo ""
        read -rp "Migration starten? [j/N]: " confirm
        [[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."

        # Dateien via rsync übertragen
        info "Dateien werden übertragen (rsync)..."
        mkdir -p "$SITE_PATH"
        rsync -az --progress \
            -e "ssh -o StrictHostKeyChecking=no" \
            "${SRC_SSH}:${SRC_PATH}/" \
            "${SITE_PATH}/"
        log "Dateien übertragen"

        # DB exportieren und importieren
        info "Datenbank wird exportiert und importiert..."
        TMP_SQL="/tmp/migrate-${DOMAIN_SAFE}-$(date +%s).sql.gz"
        ssh -o StrictHostKeyChecking=no "$SRC_SSH" \
            "mysqldump -h ${SRC_DB_HOST} -u ${SRC_DB_USER} -p${SRC_DB_PASS} \
            --single-transaction --quick ${SRC_DB_NAME} | gzip" > "$TMP_SQL"

        # Neue DB anlegen
        mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" -p"$DB_ADMIN_PASS" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'${WEB_VM_IP}' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${WEB_VM_IP}';
FLUSH PRIVILEGES;
SQL
        zcat "$TMP_SQL" | mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" -p"$DB_ADMIN_PASS" "$DB_NAME"
        rm -f "$TMP_SQL"
        log "Datenbank importiert"
        ;;

    2)
        # ── Lokale Dateien ─────────────────────────────────────────────────
        read -rp "Pfad zur tar.gz-Datei (WordPress-Dateien): " TAR_FILE
        [[ ! -f "$TAR_FILE" ]] && err "Datei nicht gefunden: ${TAR_FILE}"

        read -rp "Pfad zur SQL-Datei (.sql oder .sql.gz): " SQL_FILE
        [[ ! -f "$SQL_FILE" ]] && err "Datei nicht gefunden: ${SQL_FILE}"

        read -rp "Alter Domain-Name in der Datenbank: " SRC_DOMAIN
        [[ -z "$SRC_DOMAIN" ]] && err "Alte Domain darf nicht leer sein."

        echo ""
        read -rp "Migration starten? [j/N]: " confirm
        [[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."

        # Dateien entpacken
        info "Dateien werden entpackt..."
        mkdir -p "$SITE_PATH"
        tar -xzf "$TAR_FILE" -C "$SITE_PATH" --strip-components=1
        log "Dateien entpackt"

        # DB anlegen und importieren
        info "Datenbank wird importiert..."
        mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" -p"$DB_ADMIN_PASS" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'${WEB_VM_IP}' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${WEB_VM_IP}';
FLUSH PRIVILEGES;
SQL
        if [[ "$SQL_FILE" == *.gz ]]; then
            zcat "$SQL_FILE" | mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" -p"$DB_ADMIN_PASS" "$DB_NAME"
        else
            mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" -p"$DB_ADMIN_PASS" "$DB_NAME" < "$SQL_FILE"
        fi
        log "Datenbank importiert"
        ;;

    *) err "Ungültige Auswahl." ;;
esac

# ── wp-config.php aktualisieren ───────────────────────────────────────────
info "wp-config.php wird aktualisiert..."
wp config set DB_NAME     "$DB_NAME" --path="$SITE_PATH" --allow-root
wp config set DB_USER     "$DB_USER" --path="$SITE_PATH" --allow-root
wp config set DB_PASSWORD "$DB_PASS" --path="$SITE_PATH" --allow-root
wp config set DB_HOST     "$DB_HOST" --path="$SITE_PATH" --allow-root
wp config set WP_REDIS_HOST  "127.0.0.1" --path="$SITE_PATH" --allow-root
wp config set WP_REDIS_PORT  "6379"      --path="$SITE_PATH" --allow-root
wp config set WP_CACHE_KEY_SALT "${DOMAIN}:" --path="$SITE_PATH" --allow-root
wp config set DISABLE_WP_CRON "true" --raw --path="$SITE_PATH" --allow-root
chmod 600 "${SITE_PATH}/wp-config.php"
log "wp-config.php aktualisiert"

# ── URLs in DB ersetzen ───────────────────────────────────────────────────
info "URLs werden ersetzt (${SRC_DOMAIN} → ${DOMAIN})..."
wp search-replace "https://${SRC_DOMAIN}" "https://${DOMAIN}" \
    --path="$SITE_PATH" --allow-root --skip-columns=guid
wp search-replace "http://${SRC_DOMAIN}" "https://${DOMAIN}" \
    --path="$SITE_PATH" --allow-root --skip-columns=guid
wp cache flush --path="$SITE_PATH" --allow-root 2>/dev/null || true
log "URLs ersetzt"

# ── Redis Object Cache installieren ──────────────────────────────────────
wp plugin install redis-cache --activate --path="$SITE_PATH" --allow-root 2>/dev/null || true
wp redis enable --path="$SITE_PATH" --allow-root 2>/dev/null || true

# ── Systemuser + Berechtigungen ───────────────────────────────────────────
useradd -r -s /sbin/nologin -d "$SITE_PATH" "$SYSTEM_USER" 2>/dev/null || true
chown -R "${SYSTEM_USER}:www-data" "$SITE_PATH"
find "$SITE_PATH" -type d -exec chmod 750 {} \;
find "$SITE_PATH" -type f -exec chmod 640 {} \;
chmod 600 "${SITE_PATH}/wp-config.php"
log "Berechtigungen gesetzt"

# ── PHP-FPM Pool (von install-wp.sh Logik übernommen) ─────────────────────
TOTAL_RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
if [[ "$SITE_TYPE" == "woocommerce" ]]; then
    MAX_CHILDREN=$((TOTAL_RAM_MB / 4 / 120)); [[ $MAX_CHILDREN -lt 4 ]] && MAX_CHILDREN=4
    PM_MODE="static"; PM_EXTRA="pm.max_children = ${MAX_CHILDREN}"
    PHP_MEM="512M"; PHP_UPLOAD="128M"; PHP_EXEC="300"; PHP_VARS="10000"
else
    MAX_CHILDREN=$((TOTAL_RAM_MB / 4 / 80)); [[ $MAX_CHILDREN -lt 3 ]] && MAX_CHILDREN=3
    START=$((MAX_CHILDREN / 3)); [[ $START -lt 1 ]] && START=1
    PM_MODE="dynamic"
    PM_EXTRA="pm.max_children = ${MAX_CHILDREN}
pm.start_servers = ${START}
pm.min_spare_servers = 1
pm.max_spare_servers = $((START + 1))"
    PHP_MEM="256M"; PHP_UPLOAD="64M"; PHP_EXEC="60"; PHP_VARS="5000"
fi

cat > "/etc/php/8.3/fpm/pool.d/${DOMAIN}.conf" <<EOF
[${DOMAIN}]
user  = ${SYSTEM_USER}
group = www-data
listen = /run/php/php8.3-fpm-${DOMAIN}.sock
listen.owner = www-data
listen.group = www-data
listen.mode  = 0660
pm = ${PM_MODE}
${PM_EXTRA}
pm.max_requests = 500
php_admin_value[memory_limit]         = ${PHP_MEM}
php_admin_value[upload_max_filesize]  = ${PHP_UPLOAD}
php_admin_value[post_max_size]        = ${PHP_UPLOAD}
php_admin_value[max_execution_time]   = ${PHP_EXEC}
php_admin_value[max_input_vars]       = ${PHP_VARS}
php_admin_value[error_log]            = /var/log/php/${DOMAIN}.error.log
php_admin_flag[log_errors]            = on
EOF
mkdir -p /var/log/php

# ── Nginx Vhost ───────────────────────────────────────────────────────────
SOCK="/run/php/php8.3-fpm-${DOMAIN}.sock"
cat > "/etc/nginx/sites-available/${DOMAIN}" <<EOF
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    root ${SITE_PATH};
    index index.php;
    access_log /var/log/nginx/${DOMAIN}.access.log main;
    error_log  /var/log/nginx/${DOMAIN}.error.log warn;
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    location / { try_files \$uri \$uri/ /index.php?\$args; }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${SOCK};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff|woff2|svg|webp)\$ {
        expires 30d; add_header Cache-Control "public, no-transform"; log_not_found off;
    }
    location ~ /\.(ht|git|env) { deny all; }
    location = /xmlrpc.php     { deny all; }
    location = /wp-login.php   { include snippets/fastcgi-php.conf; fastcgi_pass unix:${SOCK}; include fastcgi_params; }
}
EOF
ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"

# ── WP-Cron ───────────────────────────────────────────────────────────────
echo "*/5 * * * * ${SYSTEM_USER} /usr/local/bin/wp --path=${SITE_PATH} cron event run --due-now --allow-root 2>/dev/null" \
    > "/etc/cron.d/wpcron-${DOMAIN_SAFE}"
chmod 644 "/etc/cron.d/wpcron-${DOMAIN_SAFE}"

# ── Services neu laden ────────────────────────────────────────────────────
nginx -t && systemctl reload nginx
systemctl reload php8.3-fpm

# ── Credentials speichern ─────────────────────────────────────────────────
mkdir -p /etc/wp-hosting/sites
cat > "/etc/wp-hosting/sites/${DOMAIN}.txt" <<EOF
Domain:        https://${DOMAIN}
Typ:           ${SITE_TYPE} (migriert von ${SRC_DOMAIN})
Installiert:   $(date '+%Y-%m-%d %H:%M')

── WordPress ─────────────────────────────────
WP-Admin URL:  https://${DOMAIN}/wp-admin
Admin-User:    (vom Quell-Server übernommen)
Admin-Pass:    (vom Quell-Server übernommen)

── Datenbank ─────────────────────────────────
DB-Host:       ${DB_HOST}
DB-Name:       ${DB_NAME}
DB-User:       ${DB_USER}
DB-Pass:       ${DB_PASS}

── Server ────────────────────────────────────
Site-Pfad:     ${SITE_PATH}
System-User:   ${SYSTEM_USER}
Migriert von:  ${SRC_DOMAIN}
EOF
chmod 600 "/etc/wp-hosting/sites/${DOMAIN}.txt"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗"
echo -e "║   Migration abgeschlossen ✓                  ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  URL:        ${BOLD}https://${DOMAIN}${NC}"
echo -e "  WP-Admin:   ${BOLD}https://${DOMAIN}/wp-admin${NC}"
echo -e "  DB-Name:    ${BOLD}${DB_NAME}${NC}"
echo ""
echo -e "${YELLOW}  → NPM Proxy-Host für https://${DOMAIN} anlegen (→ Port 80).${NC}"
echo -e "${YELLOW}  → Admin-Zugangsdaten vom Quell-Server gelten weiterhin.${NC}"
echo -e "${YELLOW}  → Permalinks unter Einstellungen → Permalinks einmal speichern.${NC}"
echo ""
