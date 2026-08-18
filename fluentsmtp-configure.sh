#!/usr/bin/env bash
# FluentSMTP auf einer Site konfigurieren (Amazon SES SMTP).
# Aufruf:   fluentsmtp-configure.sh <domain> <sender_email> <sender_name> <host> <port>
# stdin:    Zeile 1 = SMTP-Username, Zeile 2 = SMTP-Passwort
# Gibt NIE Credential-Werte aus.
set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <domain> <sender_email> <sender_name> <host> <port>" >&2
    exit 1
fi

DOMAIN=$1 SENDER=$2 NAME=$3 HOST=$4 PORT=$5
SITE_PATH="/var/www/$DOMAIN"
PHP_FILE="/usr/local/lib/wp-hosting/fluentsmtp-set.php"

[ -d "$SITE_PATH" ] || { echo "FEHLER: $SITE_PATH existiert nicht" >&2; exit 1; }
[ -f "$PHP_FILE" ]  || { echo "FEHLER: $PHP_FILE fehlt" >&2; exit 1; }

SITE_USER=$(stat -c %U "$SITE_PATH")
[ "$SITE_USER" != "root" ] || { echo "FEHLER: Site-User ist root?" >&2; exit 1; }

IFS= read -r SMTP_USER || true
IFS= read -r SMTP_PASS || true

# Formatwaechter: SES-SMTP-User = Access-Key-Form (AKIA + 16), Dummies erlaubt.
case "$SMTP_USER" in
    AKIA????????????????) ;;
    *) echo "FEHLER: SMTP-User hat nicht die erwartete Form (Laenge ${#SMTP_USER})" >&2; exit 1 ;;
esac
[ "${#SMTP_PASS}" -ge 30 ] || { echo "FEHLER: SMTP-Passwort zu kurz (Laenge ${#SMTP_PASS})" >&2; exit 1; }

sudo -n -u "$SITE_USER" env \
    FSMTP_SENDER="$SENDER" FSMTP_NAME="$NAME" FSMTP_HOST="$HOST" FSMTP_PORT="$PORT" \
    FSMTP_USER="$SMTP_USER" FSMTP_PASS="$SMTP_PASS" \
    wp --path="$SITE_PATH" eval-file "$PHP_FILE" 2>&1 \
    | sed -E "s/(AKIA[A-Za-z0-9]{16}|[A-Za-z0-9+\/=]{30,})/<redacted>/g"

exit "${PIPESTATUS[0]}"
