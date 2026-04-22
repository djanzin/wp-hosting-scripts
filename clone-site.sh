#!/bin/bash
# Klont eine bestehende WordPress-Site auf eine neue Domain (z.B. für Staging)
# Voraussetzung: setup-web.sh wurde ausgeführt, als root ausführen

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen: sudo bash clone-site.sh"
[[ ! -f /etc/wp-hosting/config ]] && err "Konfiguration nicht gefunden. Bitte zuerst setup-web.sh ausführen."
command -v wp &>/dev/null || err "WP-CLI nicht gefunden."

source /etc/wp-hosting/config

clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   WordPress Site klonen                      ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Quell-Site auswählen ───────────────────────────────────────────────────
SITES_DIR="/etc/wp-hosting/sites"
[[ -z "$(ls -A "$SITES_DIR" 2>/dev/null)" ]] && err "Keine installierten Sites gefunden."

echo "Installierte Sites:"
for f in "${SITES_DIR}"/*.txt; do echo "  - $(basename "$f" .txt)"; done
echo ""

read -rp "Quell-Domain (zu klonende Site): " SRC_DOMAIN
SRC_DOMAIN=$(echo "$SRC_DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/^www\.//')
[[ ! -f "${SITES_DIR}/${SRC_DOMAIN}.txt" ]] && err "Site '${SRC_DOMAIN}' nicht gefunden."

read -rp "Ziel-Domain (neue Domain, z.B. staging.meinshop.de): " DST_DOMAIN
DST_DOMAIN=$(echo "$DST_DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/^www\.//')
[[ -z "$DST_DOMAIN" ]] && err "Ziel-Domain darf nicht leer sein."
[[ -f "${SITES_DIR}/${DST_DOMAIN}.txt" ]] && err "Site '${DST_DOMAIN}' existiert bereits."
[[ -d "/var/www/${DST_DOMAIN}" ]] && err "Verzeichnis /var/www/${DST_DOMAIN} existiert bereits."

# Quell-Daten lesen
SRC_PATH="/var/www/${SRC_DOMAIN}"
SRC_DB_NAME=$(grep "^DB-Name:" "${SITES_DIR}/${SRC_DOMAIN}.txt" | awk '{print $2}')
SRC_TYPE=$(grep "^Typ:" "${SITES_DIR}/${SRC_DOMAIN}.txt" | awk '{print $2}')
[[ ! -d "$SRC_PATH" ]] && err "Quell-Verzeichnis nicht gefunden: ${SRC_PATH}"

echo ""
info "Quelle:  ${BOLD}${SRC_DOMAIN}${NC} (${SRC_TYPE})"
info "Ziel:    ${BOLD}${DST_DOMAIN}${NC}"
echo ""
read -rp "Klonen starten? [j/N]: " confirm
[[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."

# ── Ziel-Variablen ─────────────────────────────────────────────────────────
DST_SAFE=$(echo "$DST_DOMAIN" | tr '.' '_' | tr '-' '_')
DST_PATH="/var/www/${DST_DOMAIN}"
DST_DB_NAME="wp_${DST_SAFE}"
DST_DB_USER="wpdb_$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 10)"
DST_DB_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32)
DST_SYSTEM_USER="wp_${DST_SAFE:0:20}"
DST_SOCK="/run/php/php8.3-fpm-${DST_DOMAIN}.sock"
WEB_VM_IP=$(hostname -I | awk '{print $1}')

# ── Systemuser anlegen ────────────────────────────────────────────────────
useradd -r -s /sbin/nologin -d "$DST_PATH" "$DST_SYSTEM_USER" 2>/dev/null || true
log "Systemuser: ${DST_SYSTEM_USER}"

# ── Dateien kopieren ──────────────────────────────────────────────────────
info "Dateien werden kopiert..."
cp -a "$SRC_PATH" "$DST_PATH"
chown -R "${DST_SYSTEM_USER}:www-data" "$DST_PATH"
log "Dateien kopiert: ${SRC_PATH} → ${DST_PATH}"

# ── Datenbank klonen ──────────────────────────────────────────────────────
info "Datenbank wird geklont..."
mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" -p"$DB_ADMIN_PASS" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DST_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DST_DB_USER}'@'${WEB_VM_IP}' IDENTIFIED BY '${DST_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DST_DB_NAME}\`.* TO '${DST_DB_USER}'@'${WEB_VM_IP}';
FLUSH PRIVILEGES;
SQL

# Dump der Quell-DB und Import in Ziel-DB
mysqldump -h "$DB_HOST" -u "$DB_ADMIN_USER" -p"$DB_ADMIN_PASS" \
    --single-transaction --quick "$SRC_DB_NAME" \
    | mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" -p"$DB_ADMIN_PASS" "$DST_DB_NAME"
log "Datenbank geklont: ${SRC_DB_NAME} → ${DST_DB_NAME}"

# ── wp-config.php anpassen ────────────────────────────────────────────────
wp config set DB_NAME     "$DST_DB_NAME" --path="$DST_PATH" --allow-root
wp config set DB_USER     "$DST_DB_USER" --path="$DST_PATH" --allow-root
wp config set DB_PASSWORD "$DST_DB_PASS" --path="$DST_PATH" --allow-root
wp config set WP_CACHE_KEY_SALT "${DST_DOMAIN}:" --path="$DST_PATH" --allow-root
chmod 600 "${DST_PATH}/wp-config.php"
log "wp-config.php aktualisiert"

# ── URLs in DB ersetzen ───────────────────────────────────────────────────
info "URLs werden ersetzt..."
wp search-replace "https://${SRC_DOMAIN}" "https://${DST_DOMAIN}" \
    --path="$DST_PATH" --allow-root --skip-columns=guid
wp search-replace "http://${SRC_DOMAIN}" "https://${DST_DOMAIN}" \
    --path="$DST_PATH" --allow-root --skip-columns=guid
wp cache flush --path="$DST_PATH" --allow-root 2>/dev/null || true
log "URLs ersetzt"

# ── PHP-FPM Pool ──────────────────────────────────────────────────────────
SRC_POOL_FILE="/etc/php/8.3/fpm/pool.d/${SRC_DOMAIN}.conf"
DST_POOL_FILE="/etc/php/8.3/fpm/pool.d/${DST_DOMAIN}.conf"

if [[ -f "$SRC_POOL_FILE" ]]; then
    sed "s|${SRC_DOMAIN}|${DST_DOMAIN}|g; s|${SRC_PATH}|${DST_PATH}|g; \
         s|wp_${SRC_SAFE:0:20}|${DST_SYSTEM_USER}|g" \
        "$SRC_POOL_FILE" > "$DST_POOL_FILE"
    log "PHP-FPM Pool erstellt"
fi

# ── Nginx Vhost ───────────────────────────────────────────────────────────
SRC_VHOST="/etc/nginx/sites-available/${SRC_DOMAIN}"
DST_VHOST="/etc/nginx/sites-available/${DST_DOMAIN}"

if [[ -f "$SRC_VHOST" ]]; then
    sed "s|${SRC_DOMAIN}|${DST_DOMAIN}|g; s|${SRC_PATH}|${DST_PATH}|g; \
         s|php8.3-fpm-${SRC_DOMAIN}|php8.3-fpm-${DST_DOMAIN}|g" \
        "$SRC_VHOST" > "$DST_VHOST"
    ln -sf "$DST_VHOST" "/etc/nginx/sites-enabled/${DST_DOMAIN}"
    log "Nginx Vhost erstellt"
fi

# ── WP-Cron ───────────────────────────────────────────────────────────────
echo "*/5 * * * * ${DST_SYSTEM_USER} /usr/local/bin/wp --path=${DST_PATH} cron event run --due-now --allow-root 2>/dev/null" \
    > "/etc/cron.d/wpcron-${DST_SAFE}"
chmod 644 "/etc/cron.d/wpcron-${DST_SAFE}"

# ── Services neu laden ────────────────────────────────────────────────────
nginx -t && systemctl reload nginx
systemctl reload php8.3-fpm
log "Services neu geladen"

# ── Credentials speichern ─────────────────────────────────────────────────
cat > "${SITES_DIR}/${DST_DOMAIN}.txt" <<EOF
Domain:        https://${DST_DOMAIN}
Typ:           ${SRC_TYPE} (Klon von ${SRC_DOMAIN})
Installiert:   $(date '+%Y-%m-%d %H:%M')

── WordPress ─────────────────────────────────
WP-Admin URL:  https://${DST_DOMAIN}/wp-admin
Admin-User:    (identisch mit Quell-Site)
Admin-Pass:    (identisch mit Quell-Site)
Admin-E-Mail:  ${WP_ADMIN_EMAIL}

── Datenbank ─────────────────────────────────
DB-Host:       ${DB_HOST}
DB-Name:       ${DST_DB_NAME}
DB-User:       ${DST_DB_USER}
DB-Pass:       ${DST_DB_PASS}

── Server ────────────────────────────────────
Site-Pfad:     ${DST_PATH}
System-User:   ${DST_SYSTEM_USER}
Geklont von:   ${SRC_DOMAIN}
EOF
chmod 600 "${SITES_DIR}/${DST_DOMAIN}.txt"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗"
echo -e "║   Klon erstellt ✓                            ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Quelle:   ${BOLD}https://${SRC_DOMAIN}${NC}"
echo -e "  Ziel:     ${BOLD}https://${DST_DOMAIN}${NC}"
echo -e "  DB:       ${BOLD}${DST_DB_NAME}${NC}"
echo ""
echo -e "${YELLOW}  → NPM Proxy-Host für https://${DST_DOMAIN} anlegen (→ Port 80).${NC}"
echo -e "${YELLOW}  → Admin-Passwort der Quell-Site gilt auch für den Klon.${NC}"
echo ""
