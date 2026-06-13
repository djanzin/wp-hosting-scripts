#!/bin/bash
# DNS-/Mail-Readiness-Check für eine oder mehrere Domains VOR der Site-Installation.
# Prüft: A-Record, www, SPF, DMARC, optional SES-DKIM. Read-only, keine Änderungen.
#
# Usage:
#   bash check-dns.sh example.com
#   bash check-dns.sh example.com --ip 1.2.3.4         # A-Record gegen erwartete IP prüfen
#   bash check-dns.sh example.com shop.de blog.de      # mehrere Domains nacheinander
#   bash check-dns.sh example.com --dkim xyz123        # SES-DKIM-Selektoren prüfen (Token)
#
# Braucht 'dig' (paket: dnsutils / bind-utils). Läuft auch ohne root.

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
bad()  { echo -e "  ${RED}✗${NC} $1"; }
note() { echo -e "  ${YELLOW}!${NC} $1"; }

command -v dig >/dev/null 2>&1 || { echo -e "${RED}dig fehlt — installieren: apt-get install -y dnsutils${NC}"; exit 1; }

EXPECT_IP=""; DKIM_TOKEN=""; DOMAINS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)   EXPECT_IP="${2:-}"; shift 2 ;;
        --dkim) DKIM_TOKEN="${2:-}"; shift 2 ;;
        --*)    echo "Unbekannte Option: $1"; exit 1 ;;
        *)      DOMAINS+=("$1"); shift ;;
    esac
done

[[ ${#DOMAINS[@]} -eq 0 ]] && { echo "Usage: bash check-dns.sh <domain> [<domain> ...] [--ip IP] [--dkim TOKEN]"; exit 1; }

READY=0; ISSUES=0

for DOMAIN in "${DOMAINS[@]}"; do
    echo ""
    echo -e "${BOLD}── ${DOMAIN} ──${NC}"
    PROBLEM=0

    # A-Record
    A=$(dig +short A "$DOMAIN" | grep -E '^[0-9.]+$' | head -1)
    if [[ -z "$A" ]]; then
        bad "A-Record fehlt"; PROBLEM=1
    elif [[ -n "$EXPECT_IP" && "$A" != "$EXPECT_IP" ]]; then
        note "A-Record = ${A} (erwartet ${EXPECT_IP})"; PROBLEM=1
    else
        ok "A-Record = ${A}"
    fi

    # www
    WWW=$(dig +short A "www.${DOMAIN}" | grep -E '^[0-9.]+$' | head -1)
    WWWC=$(dig +short CNAME "www.${DOMAIN}" | head -1)
    if [[ -n "$WWW" || -n "$WWWC" ]]; then ok "www → ${WWW:-$WWWC}"; else note "www fehlt (optional)"; fi

    # SPF
    SPF=$(dig +short TXT "$DOMAIN" | tr -d '"' | grep -i "v=spf1" | head -1)
    if [[ -n "$SPF" ]]; then
        ok "SPF: ${SPF}"
        echo "$SPF" | grep -qi "amazonses.com" || note "  SPF enthält kein 'include:amazonses.com' (für SES-Versand nötig)"
    else
        bad "SPF fehlt (TXT v=spf1 …)"; PROBLEM=1
    fi

    # DMARC
    DMARC=$(dig +short TXT "_dmarc.${DOMAIN}" | tr -d '"' | grep -i "v=DMARC1" | head -1)
    if [[ -n "$DMARC" ]]; then ok "DMARC: ${DMARC}"; else note "DMARC fehlt (_dmarc TXT v=DMARC1 …) — empfohlen"; fi

    # SES-DKIM (3 CNAMEs <token>-1/2/3._domainkey → ...dkim.amazonses.com)
    if [[ -n "$DKIM_TOKEN" ]]; then
        DKIM_OK=0
        for n in 1 2 3; do
            SEL="${DKIM_TOKEN}-${n}._domainkey.${DOMAIN}"
            R=$(dig +short CNAME "$SEL" | head -1)
            [[ -n "$R" ]] && DKIM_OK=$((DKIM_OK + 1))
        done
        if [[ $DKIM_OK -eq 3 ]]; then ok "SES-DKIM: 3/3 CNAMEs gesetzt"
        else bad "SES-DKIM: nur ${DKIM_OK}/3 CNAMEs"; PROBLEM=1; fi
    else
        note "DKIM ungeprüft (kein --dkim TOKEN angegeben)"
    fi

    if [[ $PROBLEM -eq 0 ]]; then READY=$((READY + 1)); else ISSUES=$((ISSUES + 1)); fi
done

echo ""
echo -e "${BOLD}Zusammenfassung:${NC} ${GREEN}${READY} bereit${NC}, ${RED}${ISSUES} mit Problemen${NC}"
[[ $ISSUES -gt 0 ]] && exit 1 || exit 0
