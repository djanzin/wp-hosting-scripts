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

# ── Optionaler Config-Modus (reproduzierbarer, non-interaktiver Aufbau) ─────
# Usage: sudo bash setup-web.sh --config setup-web.conf
# Die Config setzt die unten abgefragten Variablen vorab; gesetzte Werte werden
# NICHT erneut erfragt. Fehlende Pflichtfelder brechen wie gewohnt mit Fehler ab.
NONINT=false
CONFIG_FILE=""
_ARGS=("$@")
_i=0
while [[ $_i -lt ${#_ARGS[@]} ]]; do
    case "${_ARGS[$_i]}" in
        --config) _i=$((_i+1)); CONFIG_FILE="${_ARGS[$_i]:-}" ;;
        --yes|--non-interactive) NONINT=true ;;
        --help|-h) echo "Usage: sudo bash setup-web.sh [--config <datei>] [--yes]"; exit 0 ;;
    esac
    _i=$((_i+1))
done
if [[ -n "$CONFIG_FILE" ]]; then
    [[ -f "$CONFIG_FILE" ]] || err "Config-Datei nicht gefunden: ${CONFIG_FILE}"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    NONINT=true
    info "Config-Modus: ${CONFIG_FILE} (non-interaktiv)"
fi

# ask VAR "Prompt"  — fragt nur interaktiv und nur wenn VAR noch leer ist.
# Im Config-Modus bleibt ein nicht gesetzter Wert leer (Pflichtprüfung folgt beim Aufrufer).
ask() {
    local __var="$1" __prompt="$2"
    [[ -n "${!__var:-}" ]] && return 0
    if $NONINT; then printf -v "$__var" '%s' ""; return 0; fi
    read -rp "$__prompt" "$__var"
}
ask_secret() {
    local __var="$1" __prompt="$2"
    [[ -n "${!__var:-}" ]] && return 0
    if $NONINT; then printf -v "$__var" '%s' ""; return 0; fi
    read -rsp "$__prompt" "$__var"; echo ""
}
# confirm "Prompt"  — im Config/NONINT-Modus automatisch ja.
confirm_or_die() {
    $NONINT && return 0
    local ans; read -rp "$1" ans
    [[ "$ans" != "j" && "$ans" != "J" ]] && err "Abgebrochen."
}

# clear scheitert ohne TERM (z.B. non-interaktiv über SSH) und würde mit set -e
# das ganze Skript killen → non-fatal machen.
clear 2>/dev/null || true
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   WordPress Web-VM Setup — Ubuntu 24.04      ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ── VM-Typ ─────────────────────────────────────────────────────────────────
# Config-Modus: VM_TYPE direkt (wordpress|woocommerce|mainwp) setzen.
if [[ -z "${VM_TYPE:-}" ]]; then
    echo "Welche Art von Web-VM wird eingerichtet?"
    echo "  1) WordPress (Standard)"
    echo "  2) WooCommerce (Performance-optimiert)"
    echo "  3) MainWP Dashboard (Admin-only, viel RAM, kein public Frontend)"
    echo ""
    read -rp "Auswahl [1/2/3]: " vm_choice
    case "$vm_choice" in
        1) VM_TYPE="wordpress" ;;
        2) VM_TYPE="woocommerce" ;;
        3) VM_TYPE="mainwp" ;;
        *) err "Ungültige Auswahl." ;;
    esac
fi
case "$VM_TYPE" in
    wordpress|woocommerce|mainwp) ;;
    *) err "Ungültiger VM_TYPE: ${VM_TYPE} (erlaubt: wordpress, woocommerce, mainwp)" ;;
esac

# ── Konfiguration abfragen (interaktiv oder aus --config) ──────────────────
echo ""
DB_HOST="${DB_HOST:-}";           ask DB_HOST          "IP-Adresse der Datenbank-VM (z.B. 192.168.1.100): "
[[ -z "$DB_HOST" ]] && err "DB-Host darf nicht leer sein (Config: DB_HOST)."

DB_ADMIN_USER="${DB_ADMIN_USER:-}"; ask DB_ADMIN_USER  "DB-Admin-Benutzer (von setup-db.sh ausgegeben): "
[[ -z "$DB_ADMIN_USER" ]] && err "DB-Admin-Benutzer darf nicht leer sein (Config: DB_ADMIN_USER)."

DB_ADMIN_PASS="${DB_ADMIN_PASS:-}"; ask_secret DB_ADMIN_PASS "DB-Admin-Passwort (von setup-db.sh ausgegeben): "
[[ -z "$DB_ADMIN_PASS" ]] && err "DB-Admin-Passwort darf nicht leer sein (Config: DB_ADMIN_PASS)."

# Admin-E-Mail wird von install-wp.sh pro Site aus der Domain abgeleitet
# (admin_dany@<domain>). Dieses Feld ist daher optional (Alt-Wert, ungenutzt).
WP_ADMIN_EMAIL="${WP_ADMIN_EMAIL:-}"; ask WP_ADMIN_EMAIL "Standard-Admin-E-Mail (optional, wird pro Site abgeleitet): "

# NPM-IP: aus Config (NPM_IP) übernehmen, sonst Auto-Detection + Prompt.
# Auto-Detection: erste IP im selben /24, die :81 (NPM-Admin) öffnet (Bash /dev/tcp).
if [[ -z "${NPM_IP:-}" ]]; then
    NPM_IP_GUESS=""
    MY_IP=$(hostname -I | awk '{print $1}')
    if [[ -n "$MY_IP" ]] && ! $NONINT; then
        SUBNET="${MY_IP%.*}"
        info "Suche NPM im Subnetz ${SUBNET}.0/24 (Port 81)..."
        for i in $(seq 1 254); do
            CANDIDATE="${SUBNET}.${i}"
            [[ "$CANDIDATE" == "$MY_IP" ]] && continue
            if timeout 0.3 bash -c "</dev/tcp/${CANDIDATE}/81" 2>/dev/null; then
                NPM_IP_GUESS="$CANDIDATE"
                break
            fi
        done
    fi
    if $NONINT; then
        err "NPM_IP ist im --config-Modus Pflicht (IP des Reverse-Proxy/Caddy, z.B. 10.1.2.2) — sonst ist Real-IP kaputt und ufw sperrt den Proxy von phpMyAdmin/Filebrowser aus."
    elif [[ -n "$NPM_IP_GUESS" ]]; then
        read -rp "IP-Adresse des Nginx Proxy Managers (Vorschlag: ${NPM_IP_GUESS}): " NPM_IP
        [[ -z "$NPM_IP" ]] && NPM_IP="$NPM_IP_GUESS"
    else
        read -rp "IP-Adresse des Nginx Proxy Managers (für Real-IP): " NPM_IP
        [[ -z "$NPM_IP" ]] && NPM_IP="127.0.0.1"
    fi
fi

# Optionale Felder (leer erlaubt) — nur interaktiv erfragen wenn nicht in Config gesetzt.
WEBHOOK_URL="${WEBHOOK_URL:-}";  $NONINT || read -rp "Webhook-URL für Benachrichtigungen (leer = deaktiviert): " WEBHOOK_URL
SEOPRESS_KEY="${SEOPRESS_KEY:-}"; $NONINT || { read -rsp "SEOpress Pro Lizenz-Key (leer = überspringen): " SEOPRESS_KEY; echo ""; }
# Zentrale Matomo-Instanz (Host ohne https:// und ohne Slash, z.B. analytics.example.com).
# Nur informativ in /etc/wp-hosting/config — Matomo-Site-Anlage + SEOpress-Tracking
# laufen zentral über provision-endpoint.sh (der Matomo-Token bleibt dort, nicht auf der VM).
MATOMO_URL="${MATOMO_URL:-}"; $NONINT || read -rp "Matomo-Host (z.B. analytics.example.com, leer = überspringen): " MATOMO_URL
# Defensiv: evtl. mitkopiertes Schema/Slash entfernen
MATOMO_URL="${MATOMO_URL#https://}"; MATOMO_URL="${MATOMO_URL#http://}"; MATOMO_URL="${MATOMO_URL%%/}"

echo ""
echo -e "${BOLD}Remote-Backup für WordPress-Dateien (wp-content) — PFLICHT${NC}"
echo "  1) Cloudflare R2"
echo "  2) S3-kompatibel (AWS, MinIO, etc.)"
echo "  3) SFTP"
echo ""

# Hostname für eindeutigen Pfad (verhindert Kollisionen mehrerer Web-VMs auf gleichem Bucket)
WEB_HOSTNAME=$(hostname -s)

RCLONE_REMOTE="${RCLONE_REMOTE:-}"
if [[ -n "$RCLONE_REMOTE" ]]; then
    # ── Config-Modus: Remote-Backup vorab gesetzt ──
    # Erwartet aus Config: RCLONE_REMOTE (r2|s3backup|sftpbackup) + RCLONE_CHOICE (1|2|3)
    # + die jeweiligen Felder (R2_* / S3_* / SFTP_*). RCLONE_DEST wird hier abgeleitet.
    case "$RCLONE_REMOTE" in
        r2)
            [[ -z "${R2_ACCOUNT_ID:-}" || -z "${R2_KEY_ID:-}" || -z "${R2_KEY_SECRET:-}" || -z "${R2_BUCKET:-}" ]] && \
                err "R2-Config unvollständig (R2_ACCOUNT_ID/R2_KEY_ID/R2_KEY_SECRET/R2_BUCKET)."
            RCLONE_CHOICE=1
            RCLONE_DEST="r2:${R2_BUCKET}/${WEB_HOSTNAME}"
            ;;
        s3backup)
            [[ -z "${S3_BUCKET:-}" || -z "${S3_KEY_ID:-}" || -z "${S3_KEY_SECRET:-}" ]] && \
                err "S3-Config unvollständig (S3_BUCKET/S3_KEY_ID/S3_KEY_SECRET)."
            S3_REGION="${S3_REGION:-}"; S3_ENDPOINT="${S3_ENDPOINT:-}"
            RCLONE_CHOICE=2
            RCLONE_DEST="s3backup:${S3_BUCKET}/${WEB_HOSTNAME}"
            ;;
        sftpbackup)
            [[ -z "${SFTP_HOST:-}" || -z "${SFTP_USER:-}" || -z "${SFTP_PATH:-}" ]] && \
                err "SFTP-Config unvollständig (SFTP_HOST/SFTP_USER/SFTP_PATH)."
            SFTP_PORT="${SFTP_PORT:-22}"
            RCLONE_CHOICE=3
            RCLONE_DEST="sftpbackup:${SFTP_PATH}/${WEB_HOSTNAME}"
            ;;
        *) err "Ungültiger RCLONE_REMOTE: ${RCLONE_REMOTE} (erlaubt: r2, s3backup, sftpbackup)." ;;
    esac
else
    $NONINT && err "RCLONE_REMOTE ist im --config-Modus Pflicht (r2 | s3backup | sftpbackup)."
    while [[ -z "$RCLONE_REMOTE" ]]; do
        read -rp "Auswahl [1-3]: " RCLONE_CHOICE
        case "$RCLONE_CHOICE" in
            1)
                read -rp "R2 Account-ID: " R2_ACCOUNT_ID
                read -rp "R2 Access Key ID: " R2_KEY_ID
                read -rsp "R2 Access Key Secret: " R2_KEY_SECRET; echo ""
                read -rp "R2 Bucket-Name: " R2_BUCKET
                [[ -z "$R2_ACCOUNT_ID" || -z "$R2_KEY_ID" || -z "$R2_KEY_SECRET" || -z "$R2_BUCKET" ]] && \
                    { warn "Alle R2-Felder sind Pflicht — bitte erneut eingeben."; continue; }
                RCLONE_REMOTE="r2"
                RCLONE_DEST="r2:${R2_BUCKET}/${WEB_HOSTNAME}"
                ;;
            2)
                read -rp "S3 Region (z.B. eu-central-1): " S3_REGION
                read -rp "S3 Bucket-Name: " S3_BUCKET
                read -rp "S3 Access Key ID: " S3_KEY_ID
                read -rsp "S3 Access Key Secret: " S3_KEY_SECRET; echo ""
                read -rp "S3 Endpoint (leer = AWS Standard): " S3_ENDPOINT
                [[ -z "$S3_BUCKET" || -z "$S3_KEY_ID" || -z "$S3_KEY_SECRET" ]] && \
                    { warn "Bucket, Key-ID und Secret sind Pflicht — bitte erneut eingeben."; continue; }
                RCLONE_REMOTE="s3backup"
                RCLONE_DEST="s3backup:${S3_BUCKET}/${WEB_HOSTNAME}"
                ;;
            3)
                read -rp "SFTP Host: " SFTP_HOST
                read -rp "SFTP User: " SFTP_USER
                read -rp "SFTP Pfad-Präfix (z.B. /backups): " SFTP_PATH
                read -rp "SFTP Port [22]: " SFTP_PORT; SFTP_PORT=${SFTP_PORT:-22}
                [[ -z "$SFTP_HOST" || -z "$SFTP_USER" || -z "$SFTP_PATH" ]] && \
                    { warn "Host, User und Pfad sind Pflicht — bitte erneut eingeben."; continue; }
                RCLONE_REMOTE="sftpbackup"
                RCLONE_DEST="sftpbackup:${SFTP_PATH}/${WEB_HOSTNAME}"
                ;;
            *) warn "Ungültig — Remote-Backup ist Pflicht. Bitte 1, 2 oder 3 wählen." ;;
        esac
    done
fi

info "Remote-Backup-Pfad: ${BOLD}${RCLONE_DEST}${NC}"

# Optionale Buckets (leer erlaubt) — interaktiv erfragen, sonst aus Config übernehmen.
PLUGIN_BUCKET="${PLUGIN_BUCKET:-}"; $NONINT || read -rp "Bucket-Name für Plugin-ZIPs (z.B. wp-plugins, leer = überspringen): " PLUGIN_BUCKET
[[ -n "$PLUGIN_BUCKET" ]] && info "Plugin-Bucket: ${BOLD}${RCLONE_REMOTE}:${PLUGIN_BUCKET}${NC}"

THEME_BUCKET="${THEME_BUCKET:-}";   $NONINT || read -rp "Bucket-Name für Theme-ZIPs (z.B. wp-themes, leer = überspringen): " THEME_BUCKET

# R2-Layout ist fix — im Config-Modus ohne gesetzten Bucket auf wp-plugins/wp-themes
# defaulten, statt den Pro-Plugin/Theme-Sync still zu überspringen (Live-Bug 2026-07).
if [[ "$RCLONE_REMOTE" == "r2" ]]; then
    [[ -z "$PLUGIN_BUCKET" ]] && { PLUGIN_BUCKET="wp-plugins"; info "PLUGIN_BUCKET nicht gesetzt → Default r2:wp-plugins"; }
    [[ -z "$THEME_BUCKET"  ]] && { THEME_BUCKET="wp-themes";   info "THEME_BUCKET nicht gesetzt → Default r2:wp-themes"; }
fi
[[ -n "$THEME_BUCKET"  ]] && info "Theme-Bucket:  ${BOLD}${RCLONE_REMOTE}:${THEME_BUCKET}${NC}"
[[ -z "$PLUGIN_BUCKET" ]] && warn "PLUGIN_BUCKET leer — Pro-Plugins werden NICHT synchronisiert."
[[ -z "$THEME_BUCKET"  ]] && warn "THEME_BUCKET leer — Blocksy-Theme wird NICHT synchronisiert."

# age-Verschlüsselung: Config-Variable ENABLE_AGE (true/false) oder interaktiv.
if [[ -z "${ENABLE_AGE:-}" ]]; then
    if $NONINT; then
        ENABLE_AGE=false
    else
        echo ""
        read -rp "Backups mit age verschlüsseln? [j/N]: " ENABLE_AGE_CHOICE
        ENABLE_AGE=false
        [[ "$ENABLE_AGE_CHOICE" == "j" || "$ENABLE_AGE_CHOICE" == "J" ]] && ENABLE_AGE=true
    fi
fi
# ENABLE_AGE strikt auf true/false normalisieren — sonst würde ein Config-Wert wie
# "yes" bei `$ENABLE_AGE && …` als Kommando ausgeführt (Hänger).
case "${ENABLE_AGE,,}" in true|1|yes|y|j) ENABLE_AGE=true ;; *) ENABLE_AGE=false ;; esac

echo ""
info "VM-Typ: ${BOLD}${VM_TYPE}${NC}"
info "DB-Host: ${BOLD}${DB_HOST}${NC}"
$ENABLE_AGE && info "Backup-Verschlüsselung: ${BOLD}aktiv (age)${NC}"
echo ""
confirm_or_die "Einrichtung starten? [j/N]: "

# ── System aktualisieren ───────────────────────────────────────────────────
info "System wird aktualisiert..."
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get upgrade -yq
DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
    curl wget unzip git ca-certificates gnupg age \
    fail2ban ufw mysql-client \
    unattended-upgrades apt-listchanges \
    nginx redis-server \
    php8.3-fpm php8.3-mysql php8.3-redis php8.3-curl php8.3-gd \
    php8.3-mbstring php8.3-xml php8.3-zip php8.3-intl \
    php8.3-soap php8.3-bcmath php8.3-imagick php8.3-opcache
log "Pakete installiert"

# ── rclone installieren & konfigurieren ───────────────────────────────────
if [[ -n "$RCLONE_REMOTE" ]]; then
    if command -v rclone &>/dev/null; then
        log "rclone bereits installiert ($(rclone --version 2>/dev/null | head -1))"
    else
        curl -fsS https://rclone.org/install.sh | bash 2>&1 | tail -3
        log "rclone installiert"
    fi

    mkdir -p /root/.config/rclone
    # rclone.conf frisch schreiben (nicht anhängen) — idempotent bei Re-Run,
    # sonst doppelte [r2]/[s3backup]-Sektionen.
    case "$RCLONE_CHOICE" in
        1) cat > /root/.config/rclone/rclone.conf <<EOF

[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_KEY_ID}
secret_access_key = ${R2_KEY_SECRET}
endpoint = https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
EOF
            ;;
        2) cat > /root/.config/rclone/rclone.conf <<EOF

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
        3) cat > /root/.config/rclone/rclone.conf <<EOF

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
    log "rclone konfiguriert (Remote: ${RCLONE_REMOTE} → ${RCLONE_DEST})"

    # Plugin-ZIPs vom Plugin-Bucket laden
    if [[ -n "$PLUGIN_BUCKET" ]]; then
        mkdir -p /etc/wp-hosting/plugins
        info "Lade Plugin-ZIPs aus ${RCLONE_REMOTE}:${PLUGIN_BUCKET}..."
        if rclone copy "${RCLONE_REMOTE}:${PLUGIN_BUCKET}/" /etc/wp-hosting/plugins/ \
            --include "*.zip" 2>/dev/null; then
            FOUND=$(ls /etc/wp-hosting/plugins/*.zip 2>/dev/null | wc -l)
            log "  ${FOUND} Plugin-ZIP(s) geladen → /etc/wp-hosting/plugins/"
        else
            warn "  Plugin-Bucket leer oder nicht erreichbar — manuell befüllen"
        fi
    fi

    # Theme-ZIPs vom Theme-Bucket laden (Blocksy + Child)
    if [[ -n "$THEME_BUCKET" ]]; then
        mkdir -p /etc/wp-hosting/themes
        info "Lade Theme-ZIPs aus ${RCLONE_REMOTE}:${THEME_BUCKET}..."
        if rclone copy "${RCLONE_REMOTE}:${THEME_BUCKET}/" /etc/wp-hosting/themes/ \
            --include "*.zip" 2>/dev/null; then
            FOUND=$(ls /etc/wp-hosting/themes/*.zip 2>/dev/null | wc -l)
            log "  ${FOUND} Theme-ZIP(s) geladen → /etc/wp-hosting/themes/"
        else
            warn "  Theme-Bucket leer oder nicht erreichbar — manuell befüllen"
        fi
    fi
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
    echo 'vm.vfs_cache_pressure=50'   >> /etc/sysctl.conf
    sysctl -p &>/dev/null
    log "Swap konfiguriert (${SWAP_SIZE}, swappiness=10)"
else
    warn "Swapfile existiert bereits — übersprungen"
fi

# ── WP-CLI ────────────────────────────────────────────────────────────────
curl -fsSL -o wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
mv wp-cli.phar /usr/local/bin/wp
log "WP-CLI installiert"

# ── PHP 8.3 konfigurieren ─────────────────────────────────────────────────
PHP_INI="/etc/php/8.3/fpm/php.ini"

case "$VM_TYPE" in
    woocommerce)
        MEM_LIMIT="512M"; UPLOAD_SIZE="128M"; MAX_EXEC="300"
        MAX_INPUT_VARS="10000"; OPCACHE_MEM="256"; OPCACHE_FILES="20000"
        ;;
    mainwp)
        # MainWP Dashboard: hoher RAM-Bedarf für viele verwaltete Sites + lange Sync-Operationen
        MEM_LIMIT="1536M"; UPLOAD_SIZE="128M"; MAX_EXEC="600"
        MAX_INPUT_VARS="10000"; OPCACHE_MEM="256"; OPCACHE_FILES="20000"
        ;;
    *)  # wordpress
        MEM_LIMIT="256M"; UPLOAD_SIZE="64M"; MAX_EXEC="60"
        MAX_INPUT_VARS="5000"; OPCACHE_MEM="128"; OPCACHE_FILES="10000"
        ;;
esac

sed -i "s/memory_limit = .*/memory_limit = ${MEM_LIMIT}/" "$PHP_INI"
sed -i "s/upload_max_filesize = .*/upload_max_filesize = ${UPLOAD_SIZE}/" "$PHP_INI"
sed -i "s/post_max_size = .*/post_max_size = ${UPLOAD_SIZE}/" "$PHP_INI"
sed -i "s/max_execution_time = .*/max_execution_time = ${MAX_EXEC}/" "$PHP_INI"
sed -i "s/max_input_time = .*/max_input_time = ${MAX_EXEC}/" "$PHP_INI"
sed -i "/max_input_vars/d" "$PHP_INI"
echo "max_input_vars = ${MAX_INPUT_VARS}" >> "$PHP_INI"

# OPcache (idempotent — nur anhängen wenn noch nicht vorhanden)
grep -q '^\[opcache\]' "$PHP_INI" || cat >> "$PHP_INI" <<EOF

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
case "$VM_TYPE" in
    woocommerce) REDIS_MEM="512mb" ;;
    mainwp)      REDIS_MEM="1024mb" ;;
    *)           REDIS_MEM="256mb" ;;
esac

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

# FastCGI-Cache für alle VM-Typen (WordPress + WooCommerce)
mkdir -p /var/cache/nginx/wp
chown www-data:www-data /var/cache/nginx/wp
cat > /etc/nginx/conf.d/fastcgi-cache.conf <<'CACHEEOF'
# WordPress / WooCommerce FastCGI Page Cache
fastcgi_cache_path /var/cache/nginx/wp levels=1:2 keys_zone=WPCACHE:100m max_size=10g inactive=60m use_temp_path=off;
CACHEEOF
log "Nginx FastCGI-Cache konfiguriert"

cat > /etc/nginx/conf.d/webp.conf <<'WEBPEOF'
# WebP: $webp_suffix wird in Vhosts für try_files genutzt
map $http_accept $webp_suffix {
    default  "";
    "~*webp" ".webp";
}
WEBPEOF
log "Nginx WebP-Serving konfiguriert"

# Real-IP: NPM + Cloudflare IP-Ranges (dynamisch von cloudflare.com)
# Mit real_ip_recursive entfernt Nginx die vertrauenswürdigen IPs aus
# X-Forwarded-For von hinten → übrig bleibt die echte Besucher-IP,
# die dann für Rate-Limiting und Logs verwendet wird.
CF_IPS_V4=$(curl -sf --max-time 10 https://www.cloudflare.com/ips-v4 || true)
CF_IPS_V6=$(curl -sf --max-time 10 https://www.cloudflare.com/ips-v6 || true)

# Fallback auf bekannte Ranges wenn Abruf fehlschlägt
if [[ -z "$CF_IPS_V4" ]]; then
    warn "Cloudflare IPv4-Ranges konnten nicht abgerufen werden — Fallback auf hardcodierte Ranges"
    CF_IPS_V4="103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
104.16.0.0/13
104.24.0.0/14
108.162.192.0/18
131.0.72.0/22
141.101.64.0/18
162.158.0.0/15
172.64.0.0/13
173.245.48.0/20
188.114.96.0/20
190.93.240.0/20
197.234.240.0/22
198.41.128.0/17"
fi
if [[ -z "$CF_IPS_V6" ]]; then
    warn "Cloudflare IPv6-Ranges konnten nicht abgerufen werden — Fallback auf hardcodierte Ranges"
    CF_IPS_V6="2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32"
fi

{
    echo "# Nginx Proxy Manager (interner Proxy)"
    echo "set_real_ip_from ${NPM_IP};"
    echo ""
    echo "# Cloudflare IPv4-Ranges (https://www.cloudflare.com/ips/)"
    while IFS= read -r ip; do
        [[ -n "$ip" ]] && echo "set_real_ip_from ${ip};"
    done <<< "$CF_IPS_V4"
    echo ""
    echo "# Cloudflare IPv6-Ranges"
    while IFS= read -r ip; do
        [[ -n "$ip" ]] && echo "set_real_ip_from ${ip};"
    done <<< "$CF_IPS_V6"
    echo ""
    echo "real_ip_header    X-Forwarded-For;"
    echo "real_ip_recursive on;"
} > /etc/nginx/conf.d/real-ip.conf

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
PMA_DIR="/var/www/phpmyadmin"

if [[ -f "${PMA_DIR}/index.php" ]]; then
    log "phpMyAdmin bereits installiert"
else
    info "phpMyAdmin wird installiert..."
    PMA_VERSION=$(curl -sf https://www.phpmyadmin.net/home_page/version.txt | head -1 | tr -d '[:space:]')
    [[ -z "$PMA_VERSION" ]] && PMA_VERSION="5.2.2" && warn "phpMyAdmin-Version konnte nicht abgerufen werden — Fallback: 5.2.2"
    info "phpMyAdmin Version: ${PMA_VERSION}"
    wget -q "https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}/phpMyAdmin-${PMA_VERSION}-all-languages.tar.gz" -O /tmp/pma.tar.gz
    tar -xzf /tmp/pma.tar.gz -C /tmp/
    rm -rf "$PMA_DIR"
    mv "/tmp/phpMyAdmin-${PMA_VERSION}-all-languages" "$PMA_DIR"
    rm -f /tmp/pma.tar.gz
fi

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

# Basic-Auth für phpMyAdmin (zweiter Schutzwall vor dem phpMyAdmin-Login)
PMA_AUTH_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20) || true
PMA_AUTH_HASH=$(openssl passwd -apr1 "$PMA_AUTH_PASS")
echo "admin:${PMA_AUTH_HASH}" > /etc/nginx/.pma_htpasswd
chmod 640 /etc/nginx/.pma_htpasswd
chown root:www-data /etc/nginx/.pma_htpasswd

cat > /etc/nginx/sites-available/phpmyadmin <<EOF
server {
    listen 8080;
    server_name _;
    root ${PMA_DIR};
    index index.php;

    access_log /var/log/nginx/phpmyadmin.access.log;
    error_log  /var/log/nginx/phpmyadmin.error.log;

    auth_basic "phpMyAdmin";
    auth_basic_user_file /etc/nginx/.pma_htpasswd;

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
log "phpMyAdmin installiert (Port 8080 → DB: ${DB_HOST}, Basic-Auth: admin)"

# ── Filebrowser ───────────────────────────────────────────────────────────
if command -v filebrowser &>/dev/null; then
    info "Filebrowser bereits installiert"
else
    info "Filebrowser wird installiert..."
    FB_VERSION=$(curl -s https://api.github.com/repos/filebrowser/filebrowser/releases/latest | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
    [[ -z "$FB_VERSION" ]] && { FB_VERSION="2.31.2"; warn "Filebrowser-Version via GitHub-API nicht ermittelbar — Fallback v${FB_VERSION}"; }
    if wget -q "https://github.com/filebrowser/filebrowser/releases/download/v${FB_VERSION}/linux-amd64-filebrowser.tar.gz" -O /tmp/fb.tar.gz && [[ -s /tmp/fb.tar.gz ]]; then
        tar -xzf /tmp/fb.tar.gz -C /usr/local/bin/ filebrowser
        chmod +x /usr/local/bin/filebrowser
        rm -f /tmp/fb.tar.gz
    else
        warn "Filebrowser-Download fehlgeschlagen (v${FB_VERSION}) — übersprungen (SFTP bleibt verfügbar)"
        rm -f /tmp/fb.tar.gz
    fi
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

# Systemd-Härtung: root auf notwendige Pfade beschränken
ProtectSystem=strict
ReadWritePaths=/var/www /etc/filebrowser /tmp
ProtectHome=true
NoNewPrivileges=yes
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable filebrowser
log "Filebrowser installiert (Port 8090)"

# ── Fail2ban ─────────────────────────────────────────────────────────────
# Filter: wp-login.php Brute-Force
cat > /etc/fail2ban/filter.d/nginx-wp-login.conf <<'EOF'
[Definition]
failregex = ^<HOST> .* "POST /wp-login\.php
ignoreregex =
EOF

# Filter: xmlrpc.php Angriffe (wir liefern 403 → jeder Hit ist verdächtig)
cat > /etc/fail2ban/filter.d/nginx-wp-xmlrpc.conf <<'EOF'
[Definition]
failregex = ^<HOST> .* "(GET|POST) /xmlrpc\.php
ignoreregex =
EOF

# Filter: PHP-Aufrufe in Uploads (typischer Webshell-Angriff)
cat > /etc/fail2ban/filter.d/nginx-wp-noscript.conf <<'EOF'
[Definition]
failregex = ^<HOST> .* "(GET|POST) /wp-content/uploads/.*\.php
            ^<HOST> .* "(GET|POST) /wp-content/.*\.php\?
ignoreregex =
EOF

# Cloudflare-IPs als ignoreip — verhindert dass fail2ban Cloudflare-Edge-IPs bant
# (würde sonst die Site für ALLE CF-User blocken). Echter X-Forwarded-For-User wird
# durch nginx real_ip_recursive korrekt extrahiert und vom richtigen Jail erfasst.
CF_IGNOREIP=$(echo "${CF_IPS_V4} ${CF_IPS_V6}" | tr '\n' ' ')

# Jails
cat > /etc/fail2ban/jail.d/wordpress.conf <<EOF
[DEFAULT]
backend = polling
# Cloudflare IPv4/IPv6 Ranges + localhost + Web-VM selbst
ignoreip = 127.0.0.1/8 ::1 ${NPM_IP} ${CF_IGNOREIP}

[nginx-wp-login]
enabled  = true
filter   = nginx-wp-login
logpath  = /var/log/nginx/*.access.log
port     = http,https
maxretry = 5
findtime = 600
bantime  = 7200

[nginx-wp-xmlrpc]
enabled  = true
filter   = nginx-wp-xmlrpc
logpath  = /var/log/nginx/*.access.log
port     = http,https
maxretry = 2
findtime = 600
bantime  = 86400

[nginx-wp-noscript]
enabled  = true
filter   = nginx-wp-noscript
logpath  = /var/log/nginx/*.access.log
port     = http,https
maxretry = 1
findtime = 600
bantime  = 86400

[sshd]
enabled  = true
maxretry = 5
bantime  = 3600
EOF
log "Fail2ban konfiguriert (wp-login, xmlrpc, noscript Jails aktiv)"

# ── SSH Hardening & SFTP ─────────────────────────────────────────────────
SSH_CONFIG="/etc/ssh/sshd_config"
# Globale Härtung per Drop-in — Ubuntu includet sshd_config.d/*.conf zuerst; ein
# 01-* gewinnt per first-match-wins über 50-cloud-init.conf (PasswordAuthentication).
SSHD_DROPIN="/etc/ssh/sshd_config.d/01-wp-hosting-hardening.conf"
{
    echo "PermitRootLogin no"
    echo "MaxAuthTries 3"
    echo "LoginGraceTime 20"
    echo "X11Forwarding no"
    echo "AllowTcpForwarding no"
    echo "PubkeyAuthentication yes"
} > "$SSHD_DROPIN"
chmod 644 "$SSHD_DROPIN"

# SFTP Subsystem auf internal-sftp umstellen (für Chroot)
if grep -q "^Subsystem\s*sftp" "$SSH_CONFIG"; then
    sed -i 's|^Subsystem\s*sftp.*|Subsystem sftp internal-sftp|' "$SSH_CONFIG"
else
    echo "Subsystem sftp internal-sftp" >> "$SSH_CONFIG"
fi

# Match-Block für chroot SFTP (nur einmal einfügen)
if ! grep -q "Match Group sftpusers" "$SSH_CONFIG"; then
    cat >> "$SSH_CONFIG" <<'SFTPEOF'

# ── Chroot SFTP pro Site ───────────────────────────────────────────────────
Match Group sftpusers
    ChrootDirectory /var/sftp/%u
    ForceCommand internal-sftp -d /site
    AllowTcpForwarding no
    X11Forwarding no
    PasswordAuthentication yes
SFTPEOF
fi

# sftpusers Gruppe und Basis-Verzeichnis
groupadd --system sftpusers 2>/dev/null || true
mkdir -p /var/sftp
chown root:root /var/sftp
chmod 755 /var/sftp
log "SFTP Chroot konfiguriert (/var/sftp)"

echo ""
SSH_PUB_KEY="${SSH_PUB_KEY:-}"; $NONINT || read -rp "SSH Public Key für ubuntu-User hinterlegen? (leer = überspringen): " SSH_PUB_KEY
if [[ -n "$SSH_PUB_KEY" ]] && id ubuntu &>/dev/null; then
    mkdir -p /home/ubuntu/.ssh
    grep -qF "$SSH_PUB_KEY" /home/ubuntu/.ssh/authorized_keys 2>/dev/null \
        || echo "$SSH_PUB_KEY" >> /home/ubuntu/.ssh/authorized_keys
    chmod 700 /home/ubuntu/.ssh
    chmod 600 /home/ubuntu/.ssh/authorized_keys
    chown -R ubuntu:ubuntu /home/ubuntu/.ssh
    echo "PasswordAuthentication no" >> "$SSHD_DROPIN"
    log "SSH Key hinterlegt — Passwort-Login global deaktiviert (SFTP-User behalten Passwort via Match-Block)"
elif [[ -n "$SSH_PUB_KEY" ]]; then
    warn "User 'ubuntu' fehlt — SSH-Key NICHT hinterlegt, Passwort-Login bleibt aktiv (kein Lockout)."
else
    warn "Kein SSH Key — Passwort-Login bleibt aktiv"
fi
if sshd -t 2>/dev/null; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || warn "SSH-Neustart fehlgeschlagen"
else
    warn "sshd-Config-Test (sshd -t) fehlgeschlagen — SSH NICHT neu gestartet."
fi

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
# HTTP nur vom Reverse-Proxy (Caddy) — Traffic kommt immer über Cloudflare→Caddy;
# direkter :80-Zugriff würde CrowdSec/WAF umgehen.
ufw allow from "$NPM_IP" to any port 80
# phpMyAdmin + Filebrowser nur vom NPM erreichbar
ufw allow from "$NPM_IP" to any port 8080
ufw allow from "$NPM_IP" to any port 8090
# Netdata streamt OUTBOUND zum Parent; inbound 19999 NICHT weltoffen öffnen.
# Nur freigeben, wenn ein Monitoring-Parent gesetzt ist (NETDATA_PARENT_IP, optional).
if [[ -n "${NETDATA_PARENT_IP:-}" ]]; then
    ufw allow from "$NETDATA_PARENT_IP" to any port 19999
fi
ufw --force enable
log "Firewall konfiguriert (22 offen | 80+8080+8090 nur von NPM: ${NPM_IP}${NETDATA_PARENT_IP:+ | 19999 nur von ${NETDATA_PARENT_IP}})"

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

# ── WordPress-Updates: zentral via MainWP (kein Auto-Update-Cron) ────────────────────────────────────────
# Bewusst KEIN unbeaufsichtigter Auto-Update-Cron. Updates werden kontrolliert
# über das zentrale MainWP-Dashboard ausgerollt (Update-Vorschau, gestaffelt,
# Rollback) — verhindert, dass ein fehlerhaftes Update viele Shops gleichzeitig
# zerlegt. MainWP-„Backup vor Update" zusätzlich aktivieren. Für manuelle
# CLI-Updates einzelner Sites steht update-wp.sh bereit (inkl. Pre-Update-Snapshots).
log "WordPress-Updates laufen zentral über MainWP (kein Auto-Update-Cron)"

# ── OPcache-Status PHP-Endpoint ───────────────────────────────────────────
mkdir -p /var/lib/wp-hosting
cat > /var/lib/wp-hosting/opcache-status.php <<'PHPEOF'
<?php
// OPcache-Status — wird per-Site über Nginx-Vhost mit Basic-Auth bereitgestellt
header('Content-Type: text/plain; charset=utf-8');
if (!function_exists('opcache_get_status')) { http_response_code(503); echo "OPcache not available\n"; exit; }
$s = @opcache_get_status(false);
if (!$s) { echo "OPcache disabled in this pool\n"; exit; }
$mem   = $s['memory_usage']     ?? [];
$stats = $s['opcache_statistics'] ?? [];
$total_mem = ($mem['used_memory'] ?? 0) + ($mem['free_memory'] ?? 0) + ($mem['wasted_memory'] ?? 0);
printf("OPcache:        %s\n", !empty($s['opcache_enabled']) ? 'enabled' : 'disabled');
printf("Memory used:    %.1f / %.1f MB  (wasted: %.1f MB)\n",
    ($mem['used_memory'] ?? 0)/1048576,
    $total_mem/1048576,
    ($mem['wasted_memory'] ?? 0)/1048576);
printf("Hit rate:       %.2f%%\n", $stats['opcache_hit_rate'] ?? 0);
printf("Hits / Misses:  %d / %d\n", $stats['hits'] ?? 0, $stats['misses'] ?? 0);
printf("Cached files:   %d / %d (max keys)\n", $stats['num_cached_scripts'] ?? 0, $stats['max_cached_keys'] ?? 0);
printf("Restarts:       oom=%d  hash=%d  manual=%d\n",
    $stats['oom_restarts'] ?? 0, $stats['hash_restarts'] ?? 0, $stats['manual_restarts'] ?? 0);
printf("Last restart:   %s\n", !empty($stats['last_restart_time']) ? date('Y-m-d H:i:s', $stats['last_restart_time']) : 'never');
PHPEOF
chmod 644 /var/lib/wp-hosting/opcache-status.php
log "OPcache-Status-Endpoint angelegt (→ https://<domain>/opcache-status, Basic-Auth)"

# ── WordPress Datei-Backup Script ────────────────────────────────────────
BACKUP_LOCAL="/var/backups/wp-files"
mkdir -p "$BACKUP_LOCAL"

cat > /usr/local/bin/wp-backup-files.sh <<BACKUPEOF
#!/bin/bash
# WordPress wp-content Datei-Backup (täglich 02:00)
set -euo pipefail

SITES_DIR="/etc/wp-hosting/sites"
BACKUP_DIR="${BACKUP_LOCAL}"
RCLONE_DEST="${RCLONE_REMOTE:+${RCLONE_DEST}}"
RETENTION_DAYS=7
LOG="/var/log/wp-backup-files.log"
DATE=\$(date '+%Y-%m-%d')
ERRORS=0

mkdir -p "\$BACKUP_DIR"
echo "[\$(date '+%Y-%m-%d %H:%M')] Datei-Backup gestartet" >> "\$LOG"

# Verschlüsselung: Wenn /etc/wp-hosting/backup-recipient.txt existiert,
# wird jedes Backup mit age + Public-Key verschlüsselt (.tar.gz.age).
RECIPIENT_FILE="/etc/wp-hosting/backup-recipient.txt"
ENCRYPT=false
if [[ -f "\$RECIPIENT_FILE" ]] && command -v age &>/dev/null; then
    ENCRYPT=true
fi

for f in "\${SITES_DIR}"/*.txt; do
    [[ -f "\$f" ]] || continue
    DOMAIN=\$(basename "\$f" .txt)
    SITE_PATH="/var/www/\${DOMAIN}"
    CONTENT_PATH="\${SITE_PATH}/wp-content"

    [[ -d "\$CONTENT_PATH" ]] || continue

    if \$ENCRYPT; then
        ARCHIVE="\${BACKUP_DIR}/\${DOMAIN}_\${DATE}.tar.gz.age"
        if tar -czf - \
            --exclude="\${CONTENT_PATH}/cache" \
            --exclude="\${CONTENT_PATH}/upgrade" \
            --exclude="\${CONTENT_PATH}/wflogs" \
            -C "\$SITE_PATH" wp-content 2>/dev/null \
            | age -R "\$RECIPIENT_FILE" -o "\$ARCHIVE" 2>/dev/null; then
            SIZE=\$(du -sh "\$ARCHIVE" 2>/dev/null | cut -f1)
            echo "[\$(date '+%Y-%m-%d %H:%M')] OK \${DOMAIN} (\${SIZE}, verschlüsselt)" >> "\$LOG"
        else
            echo "[\$(date '+%Y-%m-%d %H:%M')] FEHLER \${DOMAIN}" >> "\$LOG"
            ERRORS=\$((ERRORS + 1))
        fi
    else
        ARCHIVE="\${BACKUP_DIR}/\${DOMAIN}_\${DATE}.tar.gz"
        if tar -czf "\$ARCHIVE" \
            --exclude="\${CONTENT_PATH}/cache" \
            --exclude="\${CONTENT_PATH}/upgrade" \
            --exclude="\${CONTENT_PATH}/wflogs" \
            -C "\$SITE_PATH" wp-content 2>/dev/null; then
            SIZE=\$(du -sh "\$ARCHIVE" 2>/dev/null | cut -f1)
            echo "[\$(date '+%Y-%m-%d %H:%M')] OK \${DOMAIN} (\${SIZE})" >> "\$LOG"
        else
            echo "[\$(date '+%Y-%m-%d %H:%M')] FEHLER \${DOMAIN}" >> "\$LOG"
            ERRORS=\$((ERRORS + 1))
        fi
    fi
done

# Erst lokale Retention durchsetzen (alte Backups löschen)
# Danach Mirror-Sync nach Remote → Remote spiegelt Local exakt → 7 Tage auch Remote
find "\$BACKUP_DIR" \( -name "*.tar.gz" -o -name "*.tar.gz.age" \) \
    -mtime +\${RETENTION_DAYS} -delete 2>/dev/null || true

# Mirror-Sync: rclone löscht auf Remote was lokal nicht mehr da ist
# → Lokale Retention (find -mtime +7) erzwingt automatisch 7-Tage-Retention auch auf Remote
# bwlimit: tagsüber (08-22) auf 8 MB/s gedrosselt, nachts unbegrenzt
if [[ -n "\${RCLONE_DEST:-}" ]] && command -v rclone &>/dev/null; then
    if rclone sync "\$BACKUP_DIR" "\$RCLONE_DEST" \
        --bwlimit "08:00,8M 22:00,off" \
        --transfers 4 --checkers 8 \
        2>>"\$LOG"; then
        REMOTE_COUNT=\$(rclone size "\$RCLONE_DEST" --json 2>/dev/null | grep -oE '"count":[0-9]+' | cut -d: -f2 || echo "?")
        echo "[\$(date '+%Y-%m-%d %H:%M')] Remote-Sync OK → \${RCLONE_DEST} (\${REMOTE_COUNT} Dateien)" >> "\$LOG"
    else
        echo "[\$(date '+%Y-%m-%d %H:%M')] Remote-Sync FEHLER" >> "\$LOG"
        ERRORS=\$((ERRORS + 1))
    fi
else
    echo "[\$(date '+%Y-%m-%d %H:%M')] WARNUNG: Remote-Sync übersprungen (RCLONE_DEST nicht konfiguriert)" >> "\$LOG"
    ERRORS=\$((ERRORS + 1))
fi

echo "[\$(date '+%Y-%m-%d %H:%M')] Datei-Backup abgeschlossen (Fehler: \${ERRORS})" >> "\$LOG"

# Webhook bei Fehler
source /etc/wp-hosting/config 2>/dev/null || true
if [[ \${ERRORS} -gt 0 ]] && [[ -n "\${WEBHOOK_URL:-}" ]]; then
    MSG="Backup FEHLER: \${ERRORS} Fehler beim WP-Datei-Backup — \$(hostname -s)"
    curl -fsS -G --data-urlencode "msg=\${MSG}" "\${WEBHOOK_URL}?status=down" \
        -o /dev/null 2>/dev/null || true
fi
BACKUPEOF

chmod +x /usr/local/bin/wp-backup-files.sh
# flock verhindert parallele Läufe wenn ein Backup länger als 24h dauert
echo "0 2 * * * root /usr/bin/flock -n /var/lock/wp-backup-files.lock /usr/local/bin/wp-backup-files.sh" > /etc/cron.d/wp-backup-files
log "Datei-Backup eingerichtet (täglich 02:00, flock-protected → ${BACKUP_LOCAL})"

# Wöchentliche Backup-Verifikation (Sonntag 04:00)
if [[ -f /usr/local/bin/backup-verify.sh ]] || [[ -f "$(dirname "$0")/backup-verify.sh" ]]; then
    # Script-Pfad ermitteln und installieren
    SRC_VERIFY="$(dirname "$0")/backup-verify.sh"
    if [[ -f "$SRC_VERIFY" ]]; then
        cp "$SRC_VERIFY" /usr/local/bin/backup-verify.sh
        chmod +x /usr/local/bin/backup-verify.sh
    fi
    echo "0 4 * * 0 root /usr/local/bin/backup-verify.sh --quiet --notify" > /etc/cron.d/backup-verify
    log "Backup-Verifikation eingerichtet (sonntags 04:00, Webhook bei Fehler)"
fi

# Wöchentliches DB-Cleanup (Sonntag 05:00 — nach Backup-Verify)
if [[ -f "$(dirname "$0")/db-cleanup.sh" ]]; then
    cp "$(dirname "$0")/db-cleanup.sh" /usr/local/bin/db-cleanup.sh
    chmod +x /usr/local/bin/db-cleanup.sh
    echo "0 5 * * 0 root /usr/bin/flock -n /var/lock/wp-db-cleanup.lock /usr/local/bin/db-cleanup.sh --quiet --notify" > /etc/cron.d/db-cleanup
    log "DB-Cleanup eingerichtet (sonntags 05:00 → /var/log/wp-db-cleanup.log)"
fi

# ── Disk Space Alert Script ───────────────────────────────────────────────
cat > /usr/local/bin/disk-alert.sh <<'ALERTEOF'
#!/bin/bash
# Disk Space Alert — stündlich via Cron
# Sendet Webhook-Alert bei vollem Speicher, Recovery-Alert wenn wieder OK.
set -euo pipefail

source /etc/wp-hosting/config 2>/dev/null || exit 0
[[ -z "${WEBHOOK_URL:-}" ]] && exit 0

THRESHOLD_WARN=80    # % belegt → Warnung
THRESHOLD_CRIT=90    # % belegt → Kritisch
HOST=$(hostname -s)
STATE_DIR="/var/lib/wp-hosting/disk-state"
mkdir -p "$STATE_DIR"

send_webhook() {
    local status="$1" emoji="$2" level="$3" mount="$4" pct="$5" avail="$6"
    local msg="${emoji} Disk ${level}: ${HOST} | ${mount} | ${pct}% belegt | ${avail} frei"
    curl -fsS -G \
        --data-urlencode "msg=${msg}" \
        "${WEBHOOK_URL}?status=${status}" \
        -o /dev/null 2>/dev/null || true
}

while IFS= read -r line; do
    mount=$(awk '{print $1}' <<< "$line")
    pct=$(awk '{print $2}' <<< "$line" | tr -d '%')
    avail=$(awk '{print $3}' <<< "$line")
    [[ -z "$pct" || ! "$pct" =~ ^[0-9]+$ ]] && continue

    state_file="${STATE_DIR}/$(echo "$mount" | tr '/' '_' | tr -d ' ')"
    last=$(cat "$state_file" 2>/dev/null || echo "ok")

    if   [[ $pct -ge $THRESHOLD_CRIT ]]; then
        [[ "$last" != "crit" ]] && send_webhook "down" "🔴" "KRITISCH" "$mount" "$pct" "$avail"
        echo "crit" > "$state_file"
    elif [[ $pct -ge $THRESHOLD_WARN ]]; then
        [[ "$last" == "ok"   ]] && send_webhook "down" "🟡" "WARNUNG"  "$mount" "$pct" "$avail"
        echo "warn" > "$state_file"
    else
        [[ "$last" != "ok"   ]] && send_webhook "up"   "🟢" "OK"       "$mount" "$pct" "$avail"
        echo "ok"   > "$state_file"
    fi
done < <(df --output=target,pcent,avail -h 2>/dev/null | tail -n +2 \
    | grep -Ev "tmpfs|devtmpfs|udev|overlay|squashfs|^/run|^/dev$|^/sys")
ALERTEOF

chmod +x /usr/local/bin/disk-alert.sh
echo "0 * * * * root /usr/local/bin/disk-alert.sh" > /etc/cron.d/disk-alert
mkdir -p /var/lib/wp-hosting/disk-state
log "Disk Space Alert eingerichtet (stündlich → Webhook bei >80% / >90%)"

# ── SSL Certificate Monitor ───────────────────────────────────────────────
cat > /usr/local/bin/ssl-monitor.sh <<'SSLEOF'
#!/bin/bash
# SSL Certificate Monitor — alle 6 Stunden via Cron
# Nur Alert wenn Zertifikat-Erneuerung fehlgeschlagen ist (< 2 Tage).
# Optimiert für NPMplus mit Let's Encrypt Short-Lived Certificates (6 Tage).
set -euo pipefail

source /etc/wp-hosting/config 2>/dev/null || exit 0
[[ -z "${WEBHOOK_URL:-}" ]] && exit 0

CRIT_DAYS=2     # Alert wenn < 2 Tage — Erneuerung definitiv fehlgeschlagen
SITES_DIR="/etc/wp-hosting/sites"
STATE_DIR="/var/lib/wp-hosting/ssl-state"
mkdir -p "$STATE_DIR"

[[ -z "$(ls -A "$SITES_DIR" 2>/dev/null)" ]] && exit 0

send_webhook() {
    local status="$1" emoji="$2" msg="$3"
    curl -fsS -G \
        --data-urlencode "msg=${emoji} ${msg}" \
        "${WEBHOOK_URL}?status=${status}" \
        -o /dev/null 2>/dev/null || true
}

for cred_file in "${SITES_DIR}"/*.txt; do
    [[ -f "$cred_file" ]] || continue
    domain=$(basename "$cred_file" .txt)

    # Zertifikat per TLS-Handshake prüfen (Timeout 10 Sek)
    expiry_str=$(echo | timeout 10 openssl s_client \
        -servername "$domain" \
        -connect "${domain}:443" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null \
        | cut -d= -f2) || continue
    [[ -z "$expiry_str" ]] && continue

    expiry_epoch=$(date -d "$expiry_str" +%s 2>/dev/null) || continue
    days_left=$(( (expiry_epoch - $(date +%s)) / 86400 ))

    state_file="${STATE_DIR}/${domain}"
    last=$(cat "$state_file" 2>/dev/null || echo "ok")

    if [[ $days_left -le $CRIT_DAYS ]]; then
        # Nur alert wenn noch nicht gemeldet (kein Spam alle 6h)
        [[ "$last" != "crit" ]] && \
            send_webhook "down" "🔴" "SSL Erneuerung fehlgeschlagen: ${domain} | Läuft ab in ${days_left} Tag(en) — sofort NPMplus prüfen!"
        echo "crit" > "$state_file"
    else
        # Recovery: Zertifikat wurde erfolgreich erneuert
        [[ "$last" == "crit" ]] && \
            send_webhook "up" "🟢" "SSL OK: ${domain} | Zertifikat erneuert, noch ${days_left} Tage gültig"
        echo "ok" > "$state_file"
    fi
done
SSLEOF

chmod +x /usr/local/bin/ssl-monitor.sh
echo "0 */6 * * * root /usr/local/bin/ssl-monitor.sh" > /etc/cron.d/ssl-monitor
mkdir -p /var/lib/wp-hosting/ssl-state
log "SSL Monitor eingerichtet (alle 6h → Alert nur bei Erneuerungsfehler <2 Tage)"

# ── Cloudflare IP Auto-Update ─────────────────────────────────────────────
cat > /usr/local/bin/cf-ip-update.sh <<'CFEOF'
#!/bin/bash
# Aktualisiert Cloudflare IP-Ranges in nginx real-ip.conf
set -euo pipefail

source /etc/wp-hosting/config 2>/dev/null || true

CF_IPS_V4=$(curl -sf --max-time 10 https://www.cloudflare.com/ips-v4 || true)
CF_IPS_V6=$(curl -sf --max-time 10 https://www.cloudflare.com/ips-v6 || true)

[[ -z "$CF_IPS_V4" || -z "$CF_IPS_V6" ]] && exit 0  # Abruf fehlgeschlagen – nichts überschreiben

{
    echo "# Nginx Proxy Manager (interner Proxy)"
    echo "set_real_ip_from ${NPM_IP};"
    echo ""
    echo "# Cloudflare IPv4-Ranges (https://www.cloudflare.com/ips/)"
    while IFS= read -r ip; do
        [[ -n "$ip" ]] && echo "set_real_ip_from ${ip};"
    done <<< "$CF_IPS_V4"
    echo ""
    echo "# Cloudflare IPv6-Ranges"
    while IFS= read -r ip; do
        [[ -n "$ip" ]] && echo "set_real_ip_from ${ip};"
    done <<< "$CF_IPS_V6"
    echo ""
    echo "real_ip_header    X-Forwarded-For;"
    echo "real_ip_recursive on;"
} > /etc/nginx/conf.d/real-ip.conf

nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
CFEOF

chmod +x /usr/local/bin/cf-ip-update.sh
echo "0 4 * * 1 root /usr/local/bin/cf-ip-update.sh" > /etc/cron.d/cf-ip-update
log "Cloudflare IP Auto-Update eingerichtet (montags 04:00 Uhr)"

# ── Backup-Verschlüsselung (age) ──────────────────────────────────────────
# Wenn am Anfang gewählt: Keypair generieren (age ist nun installiert)
if $ENABLE_AGE; then
    AGE_KEY_FILE="/etc/wp-hosting/backup-key.txt"
    AGE_PUB_FILE="/etc/wp-hosting/backup-recipient.txt"

    if [[ -f "$AGE_KEY_FILE" ]]; then
        warn "age-Key existiert bereits — wird beibehalten"
    else
        age-keygen -o "$AGE_KEY_FILE" 2>/dev/null
        chmod 600 "$AGE_KEY_FILE"
        grep "^# public key:" "$AGE_KEY_FILE" | awk '{print $4}' > "$AGE_PUB_FILE"
        chmod 644 "$AGE_PUB_FILE"
        log "age-Keypair generiert: ${AGE_KEY_FILE}"
    fi
fi

# Konfiguration speichern
mkdir -p /etc/wp-hosting/plugins

cat > /etc/wp-hosting/config <<EOF
VM_TYPE=${VM_TYPE}
DB_HOST=${DB_HOST}
DB_ADMIN_USER=${DB_ADMIN_USER}
DB_ADMIN_PASS=${DB_ADMIN_PASS}
WP_ADMIN_EMAIL=${WP_ADMIN_EMAIL}
NPM_IP=${NPM_IP}
WEBHOOK_URL=${WEBHOOK_URL:-}
RCLONE_REMOTE=${RCLONE_REMOTE:-}
RCLONE_DEST=${RCLONE_DEST:-}
PLUGIN_BUCKET=${PLUGIN_BUCKET:-}
THEME_BUCKET=${THEME_BUCKET:-}
SEOPRESS_KEY=${SEOPRESS_KEY:-}
MATOMO_URL=${MATOMO_URL:-}
PMA_AUTH_PASS=${PMA_AUTH_PASS}
EOF
chmod 600 /etc/wp-hosting/config

# ── Services starten ──────────────────────────────────────────────────────
systemctl restart php8.3-fpm
systemctl restart nginx
systemctl restart redis-server
systemctl restart fail2ban || warn "fail2ban-Neustart fehlgeschlagen — mit 'fail2ban-client -t' prüfen"
systemctl start filebrowser || warn "Filebrowser-Start fehlgeschlagen (evtl. nicht installiert) — übersprungen"
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
echo -e "  PMA Benutzer:  ${BOLD}admin${NC}"
echo -e "  PMA Passwort:  ${BOLD}${PMA_AUTH_PASS}${NC}  (Basic-Auth)"
echo -e "  Filebrowser:   ${BOLD}http://$(hostname -I | awk '{print $1}'):8090${NC}"
echo -e "  FB Benutzer:   ${BOLD}admin${NC}"
echo -e "  FB Passwort:   ${BOLD}${FB_ADMIN_PASS}${NC}"
echo ""
echo -e "  Netdata:       ${BOLD}http://$(hostname -I | awk '{print $1}'):19999${NC}"
echo -e "  Konfiguration: ${BOLD}/etc/wp-hosting/config${NC}"
echo -e "  Sites:         ${BOLD}/etc/wp-hosting/sites/<domain>.txt${NC}"
echo -e "  Datei-Backup:  ${BOLD}${BACKUP_LOCAL}${NC} (täglich 02:00)"
echo -e "  Disk Alert:    ${BOLD}/usr/local/bin/disk-alert.sh${NC} (stündlich, Webhook bei >80%/>90%)"
echo -e "  SSL Monitor:   ${BOLD}/usr/local/bin/ssl-monitor.sh${NC} (alle 6h, Alert nur bei Erneuerungsfehler)"
[[ -n "${RCLONE_REMOTE:-}" ]] && \
    echo -e "  Remote-Backup: ${BOLD}${RCLONE_DEST}${NC}"

# age-Key prominent ausgeben — User MUSS ihn sichern
if $ENABLE_AGE && [[ -f /etc/wp-hosting/backup-key.txt ]]; then
    echo ""
    echo -e "${YELLOW}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}${BOLD}║   age-Key — JETZT SICHERN (Passwort-Manager)!║${NC}"
    echo -e "${YELLOW}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    cat /etc/wp-hosting/backup-key.txt
    echo ""
    echo -e "${YELLOW}Ohne diesen Key sind verschlüsselte Backups NICHT wiederherstellbar!${NC}"
    echo -e "${YELLOW}Datei: /etc/wp-hosting/backup-key.txt${NC}"
fi
echo ""
echo -e "${YELLOW}  → phpMyAdmin- und Filebrowser-Passwort notieren!${NC}"
[[ -n "${SEOPRESS_KEY:-}" ]] && \
    echo -e "${YELLOW}  → SEOpress Pro ZIP hochladen: scp wp-seopress-pro-*.zip root@$(hostname -I | awk '{print $1}'):/etc/wp-hosting/plugins/seopress-pro.zip${NC}"
echo -e "${YELLOW}  → NPM Proxy-Hosts für Port 8080, 8090 und 19999 anlegen.${NC}"
echo -e "${YELLOW}  → Netdata in Uptime Kuma als Monitor hinzufügen.${NC}"
echo ""
