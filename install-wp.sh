#!/bin/bash
# Installiert eine neue WordPress- oder WooCommerce-Site
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash install-wp.sh"
[[ ! -f /etc/wp-hosting/config ]] && err "Konfiguration nicht gefunden. Bitte zuerst setup-web.sh ausführen."

# ── Konfiguration laden ────────────────────────────────────────────────────
source /etc/wp-hosting/config

clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   WordPress Site Installer                   ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"
info "VM-Typ: ${BOLD}${VM_TYPE}${NC} | DB-Host: ${BOLD}${DB_HOST}${NC}"
echo ""

# ── Eingaben ────────────────────────────────────────────────────────────────
read -rp "Domain (ohne https://, z.B. meinshop.de): " DOMAIN
DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/^www\.//')
[[ -z "$DOMAIN" ]] && err "Domain darf nicht leer sein."
[[ ! "$DOMAIN" =~ ^[a-z0-9][a-z0-9.-]+\.[a-z]{2,}$ ]] && err "Ungültige Domain: ${DOMAIN}"

echo ""
echo "Welche Installation?"
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
read -rp "WP-Admin-Zugang auf bestimmte IP beschränken? (leer = kein Limit): " ADMIN_IP

# Shop-Name nur bei WooCommerce abfragen
WOO_SHOP_NAME=""
if [[ "$SITE_TYPE" == "woocommerce" ]]; then
    echo ""
    read -rp "Shop-Name für E-Mail-Versand (leer = Domain): " WOO_SHOP_NAME
    [[ -z "$WOO_SHOP_NAME" ]] && WOO_SHOP_NAME="$DOMAIN"
fi

echo ""
info "Domain:    ${BOLD}${DOMAIN}${NC}"
info "Typ:       ${BOLD}${SITE_TYPE}${NC}"
[[ -n "$ADMIN_IP" ]]       && info "Admin-IP:  ${BOLD}${ADMIN_IP}${NC}"
[[ -n "$WOO_SHOP_NAME" ]]  && info "Shop-Name: ${BOLD}${WOO_SHOP_NAME}${NC}"
echo ""
read -rp "Installation starten? [j/N]: " confirm
[[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."

# ── Zugangsdaten generieren ────────────────────────────────────────────────
# Sanitized Domain für Systemnamen (nur Buchstaben/Zahlen)
DOMAIN_SAFE=$(echo "$DOMAIN" | tr '.' '_' | tr '-' '_')

DB_NAME="wp_${DOMAIN_SAFE}"
# DB-Username max 32 Zeichen (MariaDB-Limit)
DB_USER="wpdb_$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 10 || true)"
DB_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32) || true

WP_ADMIN_USER=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 14) || true
WP_ADMIN_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9!@#%^&*' | head -c 28) || true

SITE_PATH="/var/www/${DOMAIN}"
SYSTEM_USER="wp_${DOMAIN_SAFE:0:20}"
PHP_POOL="/etc/php/8.3/fpm/pool.d/${DOMAIN}.conf"
NGINX_VHOST="/etc/nginx/sites-available/${DOMAIN}"

# ── Prüfen ob Site bereits existiert ─────────────────────────────────────
[[ -d "$SITE_PATH" ]] && err "Verzeichnis ${SITE_PATH} existiert bereits."
[[ -f "$NGINX_VHOST" ]] && err "Nginx-Vhost für ${DOMAIN} existiert bereits."

# ── Systemuser anlegen ────────────────────────────────────────────────────
if ! id "$SYSTEM_USER" &>/dev/null; then
    useradd -r -s /sbin/nologin -d "$SITE_PATH" "$SYSTEM_USER"
fi
log "Systemuser: ${SYSTEM_USER}"

# ── Site-Verzeichnis ──────────────────────────────────────────────────────
mkdir -p "${SITE_PATH}"
chown "${SYSTEM_USER}:www-data" "${SITE_PATH}"
chmod 750 "${SITE_PATH}"
log "Verzeichnis: ${SITE_PATH}"

# ── PHP-FPM Pool ──────────────────────────────────────────────────────────
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))

if [[ "$SITE_TYPE" == "woocommerce" ]]; then
    # WooCommerce: static process manager für konstante Performance
    WORKER_MEM=120
    MAX_CHILDREN=$((TOTAL_RAM_MB / 4 / WORKER_MEM))
    [[ $MAX_CHILDREN -lt 4 ]] && MAX_CHILDREN=4
    [[ $MAX_CHILDREN -gt 20 ]] && MAX_CHILDREN=20

    cat > "$PHP_POOL" <<EOF
[${DOMAIN}]
user  = ${SYSTEM_USER}
group = www-data

listen = /run/php/php8.3-fpm-${DOMAIN}.sock
listen.owner = www-data
listen.group = www-data
listen.mode  = 0660

; static: Prozesse bleiben immer aktiv — besser für WooCommerce unter Last
pm               = static
pm.max_children  = ${MAX_CHILDREN}
pm.max_requests  = 500

php_admin_value[memory_limit]         = 512M
php_admin_value[upload_max_filesize]  = 128M
php_admin_value[post_max_size]        = 128M
php_admin_value[max_execution_time]   = 300
php_admin_value[max_input_time]       = 300
php_admin_value[max_input_vars]       = 10000
php_admin_value[error_log]            = /var/log/php/${DOMAIN}.error.log
php_admin_flag[log_errors]            = on

slowlog                               = /var/log/php/${DOMAIN}.slow.log
request_slowlog_timeout               = 5s
EOF
else
    # WordPress: dynamic — spart RAM bei wenig Traffic
    WORKER_MEM=80
    MAX_CHILDREN=$((TOTAL_RAM_MB / 4 / WORKER_MEM))
    [[ $MAX_CHILDREN -lt 3 ]] && MAX_CHILDREN=3
    [[ $MAX_CHILDREN -gt 12 ]] && MAX_CHILDREN=12
    START=$((MAX_CHILDREN / 3))
    [[ $START -lt 1 ]] && START=1

    cat > "$PHP_POOL" <<EOF
[${DOMAIN}]
user  = ${SYSTEM_USER}
group = www-data

listen = /run/php/php8.3-fpm-${DOMAIN}.sock
listen.owner = www-data
listen.group = www-data
listen.mode  = 0660

pm                   = dynamic
pm.max_children      = ${MAX_CHILDREN}
pm.start_servers     = ${START}
pm.min_spare_servers = 1
pm.max_spare_servers = $((START + 1))
pm.max_requests      = 500

php_admin_value[memory_limit]         = 256M
php_admin_value[upload_max_filesize]  = 64M
php_admin_value[post_max_size]        = 64M
php_admin_value[max_execution_time]   = 60
php_admin_value[max_input_time]       = 60
php_admin_value[max_input_vars]       = 5000
php_admin_value[error_log]            = /var/log/php/${DOMAIN}.error.log
php_admin_flag[log_errors]            = on

slowlog                               = /var/log/php/${DOMAIN}.slow.log
request_slowlog_timeout               = 5s
EOF
fi

mkdir -p /var/log/php
log "PHP-FPM Pool konfiguriert (${SITE_TYPE}, ${MAX_CHILDREN} Worker)"

# ── Nginx Vhost ───────────────────────────────────────────────────────────
SOCK="/run/php/php8.3-fpm-${DOMAIN}.sock"

if [[ "$SITE_TYPE" == "woocommerce" && "$VM_TYPE" == "woocommerce" ]]; then
    # WooCommerce: FastCGI-Cache mit smarten Bypass-Regeln
    cat > "$NGINX_VHOST" <<EOF
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    root ${SITE_PATH};
    index index.php;

    access_log /var/log/nginx/${DOMAIN}.access.log main;
    error_log  /var/log/nginx/${DOMAIN}.error.log warn;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    add_header X-XSS-Protection "1; mode=block";

    # Cache-Bypass: Warenkörbe, Login, Admin, POST-Requests
    set \$skip_cache 0;
    if (\$request_method = POST)                                          { set \$skip_cache 1; }
    if (\$query_string != "")                                             { set \$skip_cache 1; }
    if (\$request_uri ~* "/cart|/checkout|/my-account|/wc-api|/wp-admin|\?wc-ajax=|/feed") {
        set \$skip_cache 1;
    }
    if (\$http_cookie ~* "wordpress_logged_in|woocommerce_items_in_cart|woocommerce_cart_hash|wp_woocommerce_session") {
        set \$skip_cache 1;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${SOCK};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;

        fastcgi_cache            WPCACHE;
        fastcgi_cache_valid      200 301 302 1h;
        fastcgi_cache_use_stale  error timeout updating http_500;
        fastcgi_cache_lock       on;
        fastcgi_cache_bypass     \$skip_cache;
        fastcgi_no_cache         \$skip_cache;
        fastcgi_cache_key        "\$scheme\$request_method\$host\$request_uri";
        add_header               X-FastCGI-Cache \$upstream_cache_status;
    }

    location ~* \.(jpg|jpeg|png|gif)\$ {
        add_header Vary Accept;
        try_files \$uri\$webp_suffix \$uri =404;
        expires 30d;
        add_header Cache-Control "public, no-transform";
        log_not_found off;
    }

    location ~* \.(ico|css|js|pdf|txt|woff|woff2|ttf|svg|webp|avif)\$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
        log_not_found off;
    }

    location ~ /\.(ht|git|env) { deny all; }
    location = /xmlrpc.php     { deny all; }

$(if [[ -n "$ADMIN_IP" ]]; then
cat <<IPEOF
    location /wp-admin/ {
        allow ${ADMIN_IP};
        deny all;
    }
    location = /wp-login.php {
        allow ${ADMIN_IP};
        deny all;
        limit_req zone=login burst=3 nodelay;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${SOCK};
        include fastcgi_params;
    }
IPEOF
else
cat <<NOIPEOF
    location = /wp-login.php { limit_req zone=login burst=3 nodelay; include snippets/fastcgi-php.conf; fastcgi_pass unix:${SOCK}; include fastcgi_params; }
NOIPEOF
fi)
}
EOF
else
    # WordPress: FastCGI-Cache (ohne WooCommerce-spezifische Bypass-Regeln)
    cat > "$NGINX_VHOST" <<EOF
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    root ${SITE_PATH};
    index index.php;

    access_log /var/log/nginx/${DOMAIN}.access.log main;
    error_log  /var/log/nginx/${DOMAIN}.error.log warn;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    add_header X-XSS-Protection "1; mode=block";

    # Cache-Bypass: Admin, Login, eingeloggte User, POST-Requests
    set \$skip_cache 0;
    if (\$request_method = POST)                              { set \$skip_cache 1; }
    if (\$query_string != "")                                 { set \$skip_cache 1; }
    if (\$request_uri ~* "/wp-admin|/wp-login\.php|/feed")   { set \$skip_cache 1; }
    if (\$http_cookie ~* "wordpress_logged_in")               { set \$skip_cache 1; }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${SOCK};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;

        fastcgi_cache            WPCACHE;
        fastcgi_cache_valid      200 301 302 1h;
        fastcgi_cache_use_stale  error timeout updating http_500;
        fastcgi_cache_lock       on;
        fastcgi_cache_bypass     \$skip_cache;
        fastcgi_no_cache         \$skip_cache;
        fastcgi_cache_key        "\$scheme\$request_method\$host\$request_uri";
        add_header               X-FastCGI-Cache \$upstream_cache_status;
    }

    location ~* \.(jpg|jpeg|png|gif)\$ {
        add_header Vary Accept;
        try_files \$uri\$webp_suffix \$uri =404;
        expires 30d;
        add_header Cache-Control "public, no-transform";
        log_not_found off;
    }

    location ~* \.(ico|css|js|pdf|txt|woff|woff2|ttf|svg|webp|avif)\$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
        log_not_found off;
    }

    location ~ /\.(ht|git|env) { deny all; }
    location = /xmlrpc.php     { deny all; }

$(if [[ -n "$ADMIN_IP" ]]; then
cat <<IPEOF
    location /wp-admin/ {
        allow ${ADMIN_IP};
        deny all;
    }
    location = /wp-login.php {
        allow ${ADMIN_IP};
        deny all;
        limit_req zone=login burst=3 nodelay;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${SOCK};
        include fastcgi_params;
    }
IPEOF
else
cat <<NOIPEOF
    location = /wp-login.php { limit_req zone=login burst=3 nodelay; include snippets/fastcgi-php.conf; fastcgi_pass unix:${SOCK}; include fastcgi_params; }
NOIPEOF
fi)
}
EOF
fi

# Rate-Limit Zone für wp-login (einmalig in nginx.conf wenn noch nicht vorhanden)
if ! grep -q "zone=login" /etc/nginx/nginx.conf; then
    sed -i '/http {/a\    limit_req_zone $binary_remote_addr zone=login:10m rate=1r\/s;' /etc/nginx/nginx.conf
fi

ln -sf "$NGINX_VHOST" "/etc/nginx/sites-enabled/${DOMAIN}"
log "Nginx Vhost erstellt"

# ── Datenbank anlegen ─────────────────────────────────────────────────────
mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" -p"$DB_ADMIN_PASS" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'$(hostname -I | awk '{print $1}')' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'$(hostname -I | awk '{print $1}')';
FLUSH PRIVILEGES;
SQL
log "Datenbank angelegt: ${DB_NAME}"

# ── WordPress installieren ────────────────────────────────────────────────
info "WordPress wird heruntergeladen..."
sudo -u "$SYSTEM_USER" wp core download --path="$SITE_PATH" --locale=en_US --allow-root

sudo -u "$SYSTEM_USER" wp config create \
    --path="$SITE_PATH" \
    --dbname="$DB_NAME" \
    --dbuser="$DB_USER" \
    --dbpass="$DB_PASS" \
    --dbhost="$DB_HOST" \
    --dbcharset="utf8mb4" \
    --dbcollate="utf8mb4_unicode_ci" \
    --extra-php="define('WP_REDIS_HOST', '127.0.0.1');
define('WP_REDIS_PORT', 6379);
define('WP_CACHE_KEY_SALT', '${DOMAIN}:');
define('DISABLE_WP_CRON', true);
define('WP_POST_REVISIONS', 5);
define('EMPTY_TRASH_DAYS', 7);
define('DISALLOW_FILE_EDIT', true);
define('FORCE_SSL_ADMIN', true);
$([ -n "${SEOPRESS_KEY:-}" ] && echo "define('SEOPRESS_LICENSE_KEY', '${SEOPRESS_KEY}');")
define('WP_DEBUG', false);
define('WP_DEBUG_LOG', false);
define('WP_DEBUG_DISPLAY', false);
define('WP_MEMORY_LIMIT', '256M');
define('WP_MAX_MEMORY_LIMIT', '512M');
define('AUTOSAVE_INTERVAL', 120);
define('WP_CACHE', true);
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') { \$_SERVER['HTTPS'] = 'on'; }" \
    --allow-root

sudo -u "$SYSTEM_USER" wp core install \
    --path="$SITE_PATH" \
    --url="https://${DOMAIN}" \
    --title="${DOMAIN}" \
    --admin_user="$WP_ADMIN_USER" \
    --admin_password="$WP_ADMIN_PASS" \
    --admin_email="$WP_ADMIN_EMAIL" \
    --skip-email \
    --allow-root
log "WordPress installiert"

# ── WordPress-Einstellungen ────────────────────────────────────────────────
sudo -u "$SYSTEM_USER" wp option update timezone_string "Europe/Berlin"  --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update date_format "Y-m-d"              --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update time_format "H:i"                --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update WPLANG ""                        --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp rewrite structure "/%category%/%postname%/"    --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp rewrite flush                                  --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp user update "$WP_ADMIN_USER" \
    --first_name="Danijel" \
    --last_name="Janzin" \
    --nickname="Dany" \
    --display_name="Dany" \
    --path="$SITE_PATH" --allow-root

# Kommentar-Einstellungen
sudo -u "$SYSTEM_USER" wp option update require_name_email          "1"    --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update comment_moderation          "0"    --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update comment_whitelist           "1"    --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update close_comments_for_old_posts "1"  --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update close_comments_days_old     "90"  --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update default_comment_status      "open" --path="$SITE_PATH" --allow-root

# Media-Größen
sudo -u "$SYSTEM_USER" wp option update thumbnail_size_w "300"  --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update thumbnail_size_h "300"  --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update thumbnail_crop   "1"    --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update medium_size_w    "768"  --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update medium_size_h    "0"    --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update large_size_w     "1200" --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update large_size_h     "0"    --path="$SITE_PATH" --allow-root

log "Einstellungen gesetzt (Timezone: Europe/Berlin, Sprache: English, Permalinks: /%category%/%postname%/)"

# ── Redis Object Cache ─────────────────────────────────────────────────────
sudo -u "$SYSTEM_USER" wp plugin install redis-cache --activate --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp redis enable --path="$SITE_PATH" --allow-root 2>/dev/null || true
log "Redis Object Cache aktiviert"

# ── FluentSMTP (E-Mail-Versand) ───────────────────────────────────────────
sudo -u "$SYSTEM_USER" wp plugin install fluent-smtp --activate --path="$SITE_PATH" --allow-root
log "FluentSMTP installiert (→ SMTP-Zugangsdaten in WP-Admin → FluentSMTP eintragen)"

# ── WebP Bildoptimierung ──────────────────────────────────────────────────
sudo -u "$SYSTEM_USER" wp plugin install webp-converter-for-media --activate --path="$SITE_PATH" --allow-root
log "Converter for Media installiert (WebP-Konvertierung bei Upload)"

# ── Two Factor (2FA für WP-Admin) ────────────────────────────────────────
sudo -u "$SYSTEM_USER" wp plugin install two-factor --activate --path="$SITE_PATH" --allow-root
log "Two Factor installiert (→ Profil → Two Factor Options → QR-Code scannen)"

# ── SEOpress ──────────────────────────────────────────────────────────────
sudo -u "$SYSTEM_USER" wp plugin install seopress --activate --path="$SITE_PATH" --allow-root
SEOPRESS_PRO_ZIP="/etc/wp-hosting/plugins/seopress-pro.zip"
if [[ -f "$SEOPRESS_PRO_ZIP" ]]; then
    sudo -u "$SYSTEM_USER" wp plugin install "$SEOPRESS_PRO_ZIP" --activate --path="$SITE_PATH" --allow-root
    log "SEOpress + SEOpress Pro installiert"
else
    log "SEOpress installiert (Pro ZIP nicht gefunden → /etc/wp-hosting/plugins/seopress-pro.zip)"
fi

# ── FAZ Cookie Manager (DSGVO Cookie Consent) ────────────────────────────
FAZ_URL=$(curl -s https://api.github.com/repos/fabiodalez-dev/FAZ-Cookie-Manager/releases/latest \
    | grep "browser_download_url.*full\.zip" | head -1 | sed 's/.*"\(https[^"]*\)".*/\1/')
if [[ -n "$FAZ_URL" ]]; then
    sudo -u "$SYSTEM_USER" wp plugin install "$FAZ_URL" --activate --path="$SITE_PATH" --allow-root
    log "FAZ Cookie Manager installiert (→ Setup-Wizard in WP-Admin ausführen)"
else
    warn "FAZ Cookie Manager: GitHub-URL nicht gefunden — manuell installieren"
fi

# ── Antispam Bee (Kommentar-Spam) ─────────────────────────────────────────
sudo -u "$SYSTEM_USER" wp plugin install antispam-bee --activate --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update antispam_bee \
    '{"regexp_check":1,"gravatar_check":1,"time_check":1,"country_code":"","flag_spam":0,"delete_spam":1,"spam_delete_days":7,"generate_css":0,"already_commented":0,"safe_number_chars":0,"no_comment_reason":0}' \
    --format=json --path="$SITE_PATH" --allow-root 2>/dev/null || true
log "Antispam Bee aktiviert"

# ── Cloudflare Turnstile (Fake-Anmeldungen / Bot-Schutz) ──────────────────
sudo -u "$SYSTEM_USER" wp plugin install simple-cloudflare-turnstile --activate --path="$SITE_PATH" --allow-root
log "Cloudflare Turnstile installiert (→ Site Key + Secret Key in WP-Admin eintragen)"

# ── Nginx Helper (FastCGI Cache-Invalidierung — für alle Site-Typen) ───────
sudo -u "$SYSTEM_USER" wp plugin install nginx-helper --activate --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update rt_wp_nginx_helper_options \
    '{"enable_purge":"1","cache_method":"enable_fastcgi","purge_method":"get_request","enable_map":null,"enable_log":null,"log_level":"INFO","log_filesize":"5","enable_stamp":null,"purge_homepage_on_edit":"1","purge_homepage_on_del":"1","purge_archive_on_edit":"1","purge_archive_on_del":"1","purge_archive_on_new_comment":"1","purge_archive_on_deleted_comment":"1","purge_page_on_mod":"1","purge_page_on_new_comment":"1","purge_page_on_deleted_comment":"1","nginx_server_ip":"127.0.0.1","purge_url":"","redis_hostname":"127.0.0.1","redis_port":"6379","redis_prefix":"nginx-cache:"}' \
    --format=json --path="$SITE_PATH" --allow-root 2>/dev/null || true
log "Nginx Helper (FastCGI Cache-Invalidierung) aktiviert"

# ── WooCommerce ────────────────────────────────────────────────────────────
if [[ "$SITE_TYPE" == "woocommerce" ]]; then
    info "WooCommerce wird installiert..."
    sudo -u "$SYSTEM_USER" wp plugin install woocommerce --activate --path="$SITE_PATH" --allow-root

    # Deutsche Sprachdateien
    sudo -u "$SYSTEM_USER" wp language plugin install woocommerce en_US --path="$SITE_PATH" --allow-root 2>/dev/null || true
    log "WooCommerce installiert"
fi

# ── Bloat entfernen ───────────────────────────────────────────────────────
# Überflüssige Plugins
sudo -u "$SYSTEM_USER" wp plugin delete hello akismet \
    --path="$SITE_PATH" --allow-root 2>/dev/null || true

# Alte Default-Themes (twentytwentyfive bleibt als Fallback)
for theme in twentytwentyone twentytwentytwo twentytwentythree twentytwentyfour; do
    sudo -u "$SYSTEM_USER" wp theme delete "$theme" \
        --path="$SITE_PATH" --allow-root 2>/dev/null || true
done

# Standard-Inhalte
sudo -u "$SYSTEM_USER" wp post delete 1 2 --force \
    --path="$SITE_PATH" --allow-root 2>/dev/null || true   # Hello World + Sample Page
sudo -u "$SYSTEM_USER" wp comment delete 1 --force \
    --path="$SITE_PATH" --allow-root 2>/dev/null || true   # Standard-Kommentar

# Pingbacks / Trackbacks deaktivieren
sudo -u "$SYSTEM_USER" wp option update default_ping_status "closed" \
    --path="$SITE_PATH" --allow-root
sudo -u "$SYSTEM_USER" wp option update default_pingback_flag "0" \
    --path="$SITE_PATH" --allow-root

# Admin-E-Mail-Bestätigung deaktivieren (WordPress-Nag alle 6 Monate)
sudo -u "$SYSTEM_USER" wp option update admin_email_lifespan "2147483647" \
    --path="$SITE_PATH" --allow-root

# WordPress-eigene Registrierungsseite deaktivieren (WooCommerce nicht betroffen)
sudo -u "$SYSTEM_USER" wp option update users_can_register "0" \
    --path="$SITE_PATH" --allow-root

# Sicherheits-Dateien entfernen
rm -f "${SITE_PATH}/readme.html" \
      "${SITE_PATH}/license.txt" \
      "${SITE_PATH}/wp-config-sample.php"

# WooCommerce-Tracking + Marketing + Einstellungen
if [[ "$SITE_TYPE" == "woocommerce" ]]; then
    sudo -u "$SYSTEM_USER" wp option update woocommerce_allow_tracking "no"                  --path="$SITE_PATH" --allow-root 2>/dev/null || true
    sudo -u "$SYSTEM_USER" wp option update woocommerce_show_marketplace_suggestions "no"    --path="$SITE_PATH" --allow-root 2>/dev/null || true
    sudo -u "$SYSTEM_USER" wp option update woocommerce_remote_logging_enabled "no"          --path="$SITE_PATH" --allow-root 2>/dev/null || true
    sudo -u "$SYSTEM_USER" wp option update woocommerce_default_country "DE"                 --path="$SITE_PATH" --allow-root 2>/dev/null || true
    sudo -u "$SYSTEM_USER" wp option update woocommerce_currency "EUR"                       --path="$SITE_PATH" --allow-root 2>/dev/null || true
    sudo -u "$SYSTEM_USER" wp option update woocommerce_weight_unit "kg"                     --path="$SITE_PATH" --allow-root 2>/dev/null || true
    sudo -u "$SYSTEM_USER" wp option update woocommerce_dimension_unit "cm"                  --path="$SITE_PATH" --allow-root 2>/dev/null || true
    sudo -u "$SYSTEM_USER" wp option update woocommerce_enable_guest_checkout "yes"          --path="$SITE_PATH" --allow-root 2>/dev/null || true
    sudo -u "$SYSTEM_USER" wp option update woocommerce_enable_checkout_login_reminder "yes" --path="$SITE_PATH" --allow-root 2>/dev/null || true

    # E-Mail-Absender
    sudo -u "$SYSTEM_USER" wp option update woocommerce_email_from_name    "${WOO_SHOP_NAME}"                                              --path="$SITE_PATH" --allow-root 2>/dev/null || true
    sudo -u "$SYSTEM_USER" wp option update woocommerce_email_from_address "noreply@${DOMAIN}"                                             --path="$SITE_PATH" --allow-root 2>/dev/null || true
    sudo -u "$SYSTEM_USER" wp option update woocommerce_email_footer_text  "${WOO_SHOP_NAME} | https://${DOMAIN} | Impressum: https://${DOMAIN}/impressum" --path="$SITE_PATH" --allow-root 2>/dev/null || true
fi

log "Bloat entfernt (Plugins, Themes, Demo-Inhalte, Pingbacks, Sicherheitsdateien)"

# ── WooCommerce: Rechtliche Seiten (Digital-Only) ─────────────────────────
if [[ "$SITE_TYPE" == "woocommerce" ]]; then
    info "Rechtliche Seiten werden angelegt..."

    IMPRESSUM_ID=$(sudo -u "$SYSTEM_USER" wp post create \
        --post_type=page --post_title="Impressum" --post_name="impressum" \
        --post_status=publish \
        --post_content="<p><em>[Impressum-Text hier einfügen]</em></p><p>Empfehlung: <a href=\"https://www.it-recht-kanzlei.de\">IT-Recht Kanzlei</a></p>" \
        --porcelain --path="$SITE_PATH" --allow-root)

    DATENSCHUTZ_ID=$(sudo -u "$SYSTEM_USER" wp post create \
        --post_type=page --post_title="Datenschutzerklaerung" --post_name="datenschutz" \
        --post_status=publish \
        --post_content="<p><em>[Datenschutzerklärung hier einfügen]</em></p><p>Empfehlung: <a href=\"https://www.it-recht-kanzlei.de\">IT-Recht Kanzlei</a></p>" \
        --porcelain --path="$SITE_PATH" --allow-root)

    AGB_ID=$(sudo -u "$SYSTEM_USER" wp post create \
        --post_type=page --post_title="AGB" --post_name="agb" \
        --post_status=publish \
        --post_content="<p><em>[AGB hier einfügen]</em></p><p>Empfehlung: <a href=\"https://www.it-recht-kanzlei.de\">IT-Recht Kanzlei</a></p>" \
        --porcelain --path="$SITE_PATH" --allow-root)

    WIDERRUF_ID=$(sudo -u "$SYSTEM_USER" wp post create \
        --post_type=page --post_title="Widerrufsbelehrung" --post_name="widerrufsbelehrung" \
        --post_status=publish \
        --post_content="<p><em>[Widerrufsbelehrung fuer digitale Gueter hier einfuegen]</em></p><p>Hinweis: Bei digitalen Produkten erlischt das Widerrufsrecht mit Beginn der Ausfuehrung (Paragraph 356 Abs. 5 BGB).</p><p>Empfehlung: <a href=\"https://www.it-recht-kanzlei.de\">IT-Recht Kanzlei</a></p>" \
        --porcelain --path="$SITE_PATH" --allow-root)

    LIEFERUNG_ID=$(sudo -u "$SYSTEM_USER" wp post create \
        --post_type=page --post_title="Lieferung und Download" --post_name="lieferung" \
        --post_status=publish \
        --post_content="<p><em>[Lieferbedingungen fuer digitale Produkte hier einfuegen]</em></p><p>Digitale Produkte werden nach abgeschlossener Zahlung sofort per Download bereitgestellt.</p>" \
        --porcelain --path="$SITE_PATH" --allow-root)

    # WooCommerce/WordPress Seiten zuweisen
    sudo -u "$SYSTEM_USER" wp option update woocommerce_terms_page_id     "$AGB_ID"         --path="$SITE_PATH" --allow-root
    sudo -u "$SYSTEM_USER" wp option update wp_page_for_privacy_policy    "$DATENSCHUTZ_ID" --path="$SITE_PATH" --allow-root

    # Versandkostenrechner im Warenkorb ausblenden (digital = kein Versand)
    sudo -u "$SYSTEM_USER" wp option update woocommerce_enable_shipping_calc "no" --path="$SITE_PATH" --allow-root 2>/dev/null || true

    log "Rechtliche Seiten angelegt: Impressum (${IMPRESSUM_ID}), Datenschutz (${DATENSCHUTZ_ID}), AGB (${AGB_ID}), Widerruf (${WIDERRUF_ID}), Lieferung (${LIEFERUNG_ID})"
fi

# ── Must-Use Plugin: Cache-Check deaktivieren ────────────────────────────
mkdir -p "${SITE_PATH}/wp-content/mu-plugins"

cat > "${SITE_PATH}/wp-content/mu-plugins/server-cache.php" <<'MUPLUGIN'
<?php
/**
 * Caching wird durch Nginx FastCGI Cache + Redis auf Server-Ebene gehandhabt.
 * Deaktiviert den WordPress Site Health Page-Cache-Check.
 */
add_filter('site_status_tests', function($tests) {
    unset($tests['async']['page_cache']);
    return $tests;
});
MUPLUGIN

cat > "${SITE_PATH}/wp-content/mu-plugins/performance.php" <<'MUPLUGIN'
<?php
/**
 * Performance & Security:
 * - Heartbeat im Frontend deaktivieren, im Admin auf 60 Sek. drosseln
 * - Admin-Bar für Nicht-Admins ausblenden
 * - Author-Enumeration blockieren
 */

// Heartbeat
add_filter('heartbeat_settings', function($settings) {
    $settings['interval'] = 60;
    return $settings;
});
add_action('init', function() {
    if (!is_admin()) {
        wp_deregister_script('heartbeat');
    }
});

// Admin-Bar für Nicht-Admins ausblenden
add_action('after_setup_theme', function() {
    if (!current_user_can('manage_options')) {
        show_admin_bar(false);
    }
});

// Author-Enumeration blockieren
add_action('template_redirect', function() {
    if (is_author() && isset($_GET['author'])) {
        wp_redirect(home_url('/'), 301);
        exit;
    }
});
add_action('init', function() {
    if (preg_match('/\?author=([0-9]*)/i', $_SERVER['REQUEST_URI'])) {
        wp_redirect(home_url('/'), 301);
        exit;
    }
});
MUPLUGIN

log "Must-Use Plugins erstellt (Cache-Check, Heartbeat, Admin-Bar, Author-Enumeration)"

# ── Must-Use Plugin: Digital Checkout Consent (nur WooCommerce) ───────────
if [[ "$SITE_TYPE" == "woocommerce" ]]; then
    cat > "${SITE_PATH}/wp-content/mu-plugins/digital-checkout.php" <<'MUPLUGIN'
<?php
/**
 * Digital Goods Checkout: Widerrufsrecht-Checkbox (§ 356 Abs. 5 BGB)
 *
 * Zeigt beim Checkout eine Pflicht-Checkbox an, wenn der Warenkorb
 * downloadbare Produkte enthält. Die Zustimmung wird mit Zeitstempel
 * in der Bestellung gespeichert (Nachweispflicht).
 */

/**
 * Prüft ob der aktuelle Warenkorb downloadbare Produkte enthält.
 */
function _wph_cart_has_downloadable(): bool {
    if ( ! function_exists( 'WC' ) || ! WC()->cart ) {
        return false;
    }
    foreach ( WC()->cart->get_cart() as $item ) {
        $product = $item['data'] ?? null;
        if ( $product && $product->is_downloadable() ) {
            return true;
        }
    }
    return false;
}

/**
 * Checkbox vor dem Bestell-Button anzeigen.
 */
add_action( 'woocommerce_review_order_before_submit', function () {
    if ( ! _wph_cart_has_downloadable() ) {
        return;
    }

    $widerruf_url = '';
    $widerruf_page = get_page_by_path( 'widerrufsbelehrung' );
    if ( $widerruf_page ) {
        $widerruf_url = get_permalink( $widerruf_page->ID );
    }
    ?>
    <div class="digital-withdrawal-consent" style="margin:0 0 1.2em;padding:.8em;background:#f8f8f8;border-left:3px solid #d63638;">
        <label style="display:flex;align-items:flex-start;gap:.6em;cursor:pointer;font-size:.9em;line-height:1.4;">
            <input type="checkbox"
                   name="digital_withdrawal_consent"
                   id="digital_withdrawal_consent"
                   value="1"
                   style="margin-top:.15em;flex-shrink:0;" />
            <span>
                Ich stimme ausdrücklich zu, dass mit der Ausführung des Vertrags
                vor Ablauf der Widerrufsfrist begonnen wird. Mir ist bekannt, dass
                mein Widerrufsrecht mit Beginn der Ausführung erlischt.
                <?php if ( $widerruf_url ) : ?>
                    (<a href="<?php echo esc_url( $widerruf_url ); ?>" target="_blank" rel="noopener">Widerrufsbelehrung</a>)
                <?php endif; ?>
            </span>
        </label>
    </div>
    <?php
} );

/**
 * Server-seitige Validierung — läuft unabhängig vom Theme.
 */
add_action( 'woocommerce_checkout_process', function () {
    if ( ! _wph_cart_has_downloadable() ) {
        return;
    }
    if ( empty( $_POST['digital_withdrawal_consent'] ) ) {
        wc_add_notice(
            'Bitte bestätige, dass du auf dein Widerrufsrecht bei digitalen Produkten verzichtest.',
            'error'
        );
    }
} );

/**
 * Zustimmung mit Zeitstempel in der Bestellung speichern.
 */
add_action( 'woocommerce_checkout_order_created', function ( $order ) {
    if ( ! empty( $_POST['digital_withdrawal_consent'] ) ) {
        $order->update_meta_data( '_digital_withdrawal_consent', current_time( 'mysql' ) );
        $order->save();
    }
} );
MUPLUGIN
    log "Must-Use Plugin: Digital Checkout Consent (Widerrufsrecht-Checkbox)"
fi

# ── Must-Use Plugin: Maintenance Mode ────────────────────────────────────
cat > "${SITE_PATH}/wp-content/mu-plugins/maintenance-mode.php" <<'MUPLUGIN'
<?php
/**
 * Maintenance Mode
 *
 * Aktivieren:   touch wp-content/.maintenance-active
 * Deaktivieren: rm wp-content/.maintenance-active
 *
 * Eingeloggte User (Admin) sehen die Seite immer normal.
 * wp-login.php ist immer erreichbar.
 */

$_wph_flag = dirname( __FILE__ ) . '/../.maintenance-active';

if ( ! file_exists( $_wph_flag ) ) {
    return;
}

// wp-login.php immer durchlassen
if ( isset( $_SERVER['REQUEST_URI'] ) &&
     strpos( $_SERVER['REQUEST_URI'], 'wp-login.php' ) !== false ) {
    return;
}

// Eingeloggte User durchlassen (Cookie-Check vor WordPress-Init)
foreach ( array_keys( $_COOKIE ) as $_wph_key ) {
    if ( strpos( $_wph_key, 'wordpress_logged_in_' ) === 0 ) {
        return;
    }
}

http_response_code( 503 );
header( 'Retry-After: 3600' );
header( 'Content-Type: text/html; charset=UTF-8' );

$_wph_host = htmlspecialchars( $_SERVER['HTTP_HOST'] ?? '', ENT_QUOTES, 'UTF-8' );
?><!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Wartung &mdash; <?php echo $_wph_host; ?></title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: #0f172a;
    color: #e2e8f0;
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 2rem;
  }
  .card { max-width: 460px; width: 100%; text-align: center; }
  .icon { font-size: 3rem; margin-bottom: 1.5rem; }
  h1   { font-size: 1.8rem; font-weight: 700; margin-bottom: .75rem; letter-spacing: -.02em; }
  p    { color: #94a3b8; line-height: 1.65; font-size: .95rem; }
  .domain { color: #38bdf8; font-size: .85rem; margin-top: 2rem; opacity: .8; }
</style>
</head>
<body>
<div class="card">
  <div class="icon">🔧</div>
  <h1>Wartungsarbeiten</h1>
  <p>Diese Seite wird gerade eingerichtet<br>und ist in Kürze verfügbar.</p>
  <p class="domain"><?php echo $_wph_host; ?></p>
</div>
</body>
</html>
<?php
die();
MUPLUGIN
log "Must-Use Plugin: Maintenance Mode erstellt"

# ── WP-Cron via System-Cron ───────────────────────────────────────────────
# DISABLE_WP_CRON=true → kein Cron-Aufruf bei jedem Seitenaufruf
echo "*/5 * * * * ${SYSTEM_USER} /usr/local/bin/wp --path=${SITE_PATH} cron event run --due-now --allow-root 2>/dev/null" \
    > "/etc/cron.d/wpcron-${DOMAIN_SAFE}"
chmod 644 "/etc/cron.d/wpcron-${DOMAIN_SAFE}"
log "WP-Cron via System-Cron (alle 5 Minuten)"

# ── Berechtigungen setzen ─────────────────────────────────────────────────
chown -R "${SYSTEM_USER}:www-data" "$SITE_PATH"
find "$SITE_PATH" -type d -exec chmod 750 {} \;
find "$SITE_PATH" -type f -exec chmod 640 {} \;
chmod 600 "${SITE_PATH}/wp-config.php"
log "Berechtigungen gesetzt"

# ── Maintenance Mode aktivieren ───────────────────────────────────────────
touch "${SITE_PATH}/wp-content/.maintenance-active"
chown "${SYSTEM_USER}:www-data" "${SITE_PATH}/wp-content/.maintenance-active"
chmod 640 "${SITE_PATH}/wp-content/.maintenance-active"
log "Maintenance Mode aktiviert (→ sudo bash maintenance.sh zum Freischalten)"

# ── Services neu laden ────────────────────────────────────────────────────
nginx -t && systemctl reload nginx
systemctl reload php8.3-fpm
log "Nginx und PHP-FPM neu geladen"

# ── Filebrowser User anlegen ─────────────────────────────────────────────
FB_DB="/etc/filebrowser/database.db"
FB_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20) || true
FB_USER="${DOMAIN_SAFE:0:32}"

if [[ -f "$FB_DB" ]] && command -v filebrowser &>/dev/null; then
    filebrowser users add "$FB_USER" "$FB_PASS" \
        --scope "$SITE_PATH" \
        --database "$FB_DB" \
        --perm.create \
        --perm.rename \
        --perm.modify \
        --perm.delete \
        --perm.download 2>/dev/null || \
    filebrowser users update "$FB_USER" \
        --password "$FB_PASS" \
        --scope "$SITE_PATH" \
        --database "$FB_DB" 2>/dev/null || true
    log "Filebrowser User angelegt: ${FB_USER}"
else
    warn "Filebrowser nicht gefunden — User manuell anlegen"
    FB_PASS="n/a"
fi

# ── SFTP Chroot einrichten ────────────────────────────────────────────────
SFTP_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20) || true
SFTP_CHROOT="/var/sftp/${SYSTEM_USER}"

# sftpusers Gruppe sicherstellen (falls setup-web.sh noch nicht gelaufen)
groupadd --system sftpusers 2>/dev/null || true

# User zur SFTP-Gruppe hinzufügen und Passwort setzen
usermod -aG sftpusers "$SYSTEM_USER"
echo "${SYSTEM_USER}:${SFTP_PASS}" | chpasswd

# Chroot-Verzeichnis (muss root:root 755 sein — SSH-Anforderung)
mkdir -p "${SFTP_CHROOT}"
chown root:root "${SFTP_CHROOT}"
chmod 755 "${SFTP_CHROOT}"

# site/-Unterverzeichnis als Bind-Mount-Ziel
mkdir -p "${SFTP_CHROOT}/site"
chown "${SYSTEM_USER}:www-data" "${SFTP_CHROOT}/site"
chmod 750 "${SFTP_CHROOT}/site"

# Bind-Mount (idempotent)
if ! mountpoint -q "${SFTP_CHROOT}/site"; then
    mount --bind "${SITE_PATH}" "${SFTP_CHROOT}/site"
fi

# fstab-Eintrag (idempotent)
FSTAB_ENTRY="${SITE_PATH} ${SFTP_CHROOT}/site none bind 0 0"
if ! grep -qF "$FSTAB_ENTRY" /etc/fstab; then
    echo "$FSTAB_ENTRY" >> /etc/fstab
fi

log "SFTP Chroot eingerichtet: ${SFTP_CHROOT}"

# ── Zugangsdaten speichern ────────────────────────────────────────────────
CRED_FILE="/etc/wp-hosting/sites/${DOMAIN}.txt"
cat > "$CRED_FILE" <<EOF
Domain:        https://${DOMAIN}
Typ:           ${SITE_TYPE}
Installiert:   $(date '+%Y-%m-%d %H:%M')

── WordPress ─────────────────────────────────
WP-Admin URL:  https://${DOMAIN}/wp-admin
Admin-User:    ${WP_ADMIN_USER}
Admin-Pass:    ${WP_ADMIN_PASS}
Admin-E-Mail:  ${WP_ADMIN_EMAIL}

── Datenbank ─────────────────────────────────
DB-Host:       ${DB_HOST}
DB-Name:       ${DB_NAME}
DB-User:       ${DB_USER}
DB-Pass:       ${DB_PASS}

── Filebrowser ───────────────────────────────
FB-User:       ${FB_USER}
FB-Pass:       ${FB_PASS}

── SFTP ──────────────────────────────────────
SFTP-Host:     $(hostname -I | awk '{print $1}')
SFTP-Port:     22
SFTP-User:     ${SYSTEM_USER}
SFTP-Pass:     ${SFTP_PASS}
SFTP-Pfad:     /site

── Server ────────────────────────────────────
Site-Pfad:     ${SITE_PATH}
PHP-Pool:      ${PHP_POOL}
Nginx-Vhost:   ${NGINX_VHOST}
System-User:   ${SYSTEM_USER}
Admin-IP:      ${ADMIN_IP:-unbeschränkt}
EOF
chmod 600 "$CRED_FILE"

# ── Ausgabe ───────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗"
echo -e "║   ${SITE_TYPE^} installiert ✓"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  URL:           ${BOLD}https://${DOMAIN}${NC}"
echo -e "  WP-Admin:      ${BOLD}https://${DOMAIN}/wp-admin${NC}"
echo -e "  Admin-User:    ${BOLD}${WP_ADMIN_USER}${NC}"
echo -e "  Admin-Pass:    ${BOLD}${WP_ADMIN_PASS}${NC}"
echo ""
echo -e "  DB-Name:       ${BOLD}${DB_NAME}${NC}"
echo -e "  DB-User:       ${BOLD}${DB_USER}${NC}"
echo -e "  DB-Pass:       ${BOLD}${DB_PASS}${NC}"
echo ""
echo -e "  FB-User:       ${BOLD}${FB_USER}${NC}"
echo -e "  FB-Pass:       ${BOLD}${FB_PASS}${NC}"
echo ""
echo -e "  SFTP-Host:     ${BOLD}$(hostname -I | awk '{print $1}')${NC}"
echo -e "  SFTP-User:     ${BOLD}${SYSTEM_USER}${NC}"
echo -e "  SFTP-Pass:     ${BOLD}${SFTP_PASS}${NC}"
echo -e "  SFTP-Pfad:     ${BOLD}/site${NC}"
echo ""
echo -e "${YELLOW}  → Zugangsdaten gespeichert: ${CRED_FILE}${NC}"
echo -e "${YELLOW}  → Site ist im Maintenance Mode — freischalten: sudo bash maintenance.sh${NC}"
echo -e "${YELLOW}  → NPM Proxy-Host für https://${DOMAIN} anlegen (→ Port 80).${NC}"
if [[ "$SITE_TYPE" == "woocommerce" ]]; then
echo -e "${YELLOW}  → Rechtliche Texte befüllen (Impressum, Datenschutz, AGB, Widerruf):${NC}"
echo -e "${YELLOW}     Empfehlung: https://www.it-recht-kanzlei.de (Digital-Paket)${NC}"
fi
echo ""
