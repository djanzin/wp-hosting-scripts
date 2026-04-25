#!/bin/bash
# Klont das Ubuntu 24.04 Template und erstellt eine fertig konfigurierte VM
# Ausführen auf dem Proxmox-Host als root

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen."
command -v qm &>/dev/null || err "qm nicht gefunden — Script muss auf dem Proxmox-Host laufen."

clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   Proxmox VM erstellen (Template-Klon)       ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ── VM-Typ wählen ──────────────────────────────────────────────────────────
echo "Welche VM soll erstellt werden?"
echo "  1) Datenbank-VM    (4 vCPU, 8 GB RAM, 50 GB Disk)"
echo "  2) WordPress-VM    (2 vCPU, 4 GB RAM, 30 GB Disk)"
echo "  3) WooCommerce-VM  (4 vCPU, 8 GB RAM, 40 GB Disk)"
echo ""
read -rp "Auswahl [1/2/3]: " vm_choice

case "$vm_choice" in
    1) VM_TYPE="db";          VM_CORES=4; VM_RAM=8192;  VM_DISK=50; VM_LABEL="Datenbank" ;;
    2) VM_TYPE="wordpress";   VM_CORES=2; VM_RAM=4096;  VM_DISK=30; VM_LABEL="WordPress" ;;
    3) VM_TYPE="woocommerce"; VM_CORES=4; VM_RAM=8192;  VM_DISK=40; VM_LABEL="WooCommerce" ;;
    *) err "Ungültige Auswahl." ;;
esac

# ── Konfiguration abfragen ─────────────────────────────────────────────────
echo ""
NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
read -rp "VM-ID [Standard: ${NEXT_ID}]: " VM_ID
VM_ID=${VM_ID:-$NEXT_ID}

if qm status "$VM_ID" &>/dev/null; then
    err "VM-ID ${VM_ID} existiert bereits."
fi

read -rp "Template-VM-ID [Standard: 9000]: " TEMPLATE_ID
TEMPLATE_ID=${TEMPLATE_ID:-9000}

if ! qm status "$TEMPLATE_ID" &>/dev/null; then
    err "Template ${TEMPLATE_ID} nicht gefunden. Zuerst proxmox-create-template.sh ausführen."
fi

read -rp "Hostname (z.B. wp-web-01): " VM_NAME
[[ -z "$VM_NAME" ]] && err "Hostname darf nicht leer sein."

read -rp "IP-Adresse (z.B. 192.168.1.10): " VM_IP
[[ -z "$VM_IP" ]] && err "IP darf nicht leer sein."
[[ ! "$VM_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && err "Ungültige IP: ${VM_IP}"

read -rp "Subnetz-Maske in CIDR (z.B. 24): " VM_CIDR
VM_CIDR=${VM_CIDR:-24}

read -rp "Gateway (z.B. 192.168.1.1): " VM_GW
[[ -z "$VM_GW" ]] && err "Gateway darf nicht leer sein."

read -rp "DNS-Server [Standard: 1.1.1.1]: " VM_DNS
VM_DNS=${VM_DNS:-1.1.1.1}

read -rp "Netzwerk-Bridge [Standard: vmbr0]: " VM_BRIDGE
VM_BRIDGE=${VM_BRIDGE:-vmbr0}

read -rp "MAC-Adresse (leer = automatisch generieren): " VM_MAC
if [[ -n "$VM_MAC" ]]; then
    [[ ! "$VM_MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] && \
        err "Ungültige MAC-Adresse (Format: AA:BB:CC:DD:EE:FF)"
fi

# Verfügbare Storages anzeigen
echo ""
info "Verfügbare Storages:"
mapfile -t STORAGE_LIST < <(pvesm status | awk 'NR>1 {print $1}')
for i in "${!STORAGE_LIST[@]}"; do
    TYPE=$(pvesm status | awk -v name="${STORAGE_LIST[$i]}" '$1==name {print $2}')
    printf "  %d) %s (%s)\n" "$((i+1))" "${STORAGE_LIST[$i]}" "$TYPE"
done
echo ""
read -rp "Storage [Nummer oder Name]: " STORAGE_INPUT
if [[ "$STORAGE_INPUT" =~ ^[0-9]+$ ]] && \
   [[ "$STORAGE_INPUT" -ge 1 ]] && \
   [[ "$STORAGE_INPUT" -le "${#STORAGE_LIST[@]}" ]]; then
    STORAGE="${STORAGE_LIST[$((STORAGE_INPUT-1))]}"
else
    STORAGE="${STORAGE_INPUT:-local-lvm}"
fi
info "Storage: ${BOLD}${STORAGE}${NC}"

# Optionaler SSH Public Key
echo ""
read -rp "SSH Public Key einfügen (leer = überspringen): " SSH_KEY

# Zufälliges Cloud-init Passwort
CI_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20) || true

echo ""
echo -e "${BOLD}Zusammenfassung:${NC}"
echo -e "  Typ:      ${BOLD}${VM_LABEL}${NC}"
echo -e "  VM-ID:    ${BOLD}${VM_ID}${NC}"
echo -e "  Name:     ${BOLD}${VM_NAME}${NC}"
echo -e "  vCPU:     ${BOLD}${VM_CORES}${NC}"
echo -e "  RAM:      ${BOLD}$((VM_RAM / 1024)) GB${NC}"
echo -e "  Disk:     ${BOLD}${VM_DISK} GB${NC}"
echo -e "  IP:       ${BOLD}${VM_IP}/${VM_CIDR}${NC}"
echo -e "  Gateway:  ${BOLD}${VM_GW}${NC}"
echo -e "  Bridge:   ${BOLD}${VM_BRIDGE}${NC}"
echo -e "  MAC:      ${BOLD}${VM_MAC:-automatisch}${NC}"
echo ""
read -rp "VM erstellen? [j/N]: " confirm
[[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."

# ── Template klonen ────────────────────────────────────────────────────────
info "Template wird geklont (Full Clone)..."
qm clone "$TEMPLATE_ID" "$VM_ID" \
    --name "$VM_NAME" \
    --full \
    --storage "$STORAGE"
log "Klon erstellt"

# ── VM konfigurieren ──────────────────────────────────────────────────────
info "VM wird konfiguriert..."

qm set "$VM_ID" \
    --cores "$VM_CORES" \
    --memory "$VM_RAM" \
    --balloon 0

# Disk nur vergrößern wenn Zielgröße > aktuelle Größe (Proxmox unterstützt kein Shrinking)
CURRENT_DISK_GB=$(qm config "$VM_ID" | grep "scsi0:" | grep -oP 'size=\K[0-9]+' || echo "0")
if [[ "${VM_DISK}" -gt "${CURRENT_DISK_GB:-0}" ]]; then
    qm resize "$VM_ID" scsi0 "${VM_DISK}G"
    log "Disk auf ${VM_DISK} GB vergrößert"
else
    warn "Template-Disk (${CURRENT_DISK_GB} GB) ≥ Zielgröße (${VM_DISK} GB) — Größe wird beibehalten"
fi

# Netzwerk-Interface mit optionaler MAC
NET0_CONFIG="virtio,bridge=${VM_BRIDGE}"
[[ -n "$VM_MAC" ]] && NET0_CONFIG="virtio=${VM_MAC},bridge=${VM_BRIDGE}"
qm set "$VM_ID" --net0 "$NET0_CONFIG"

# Cloud-init
qm set "$VM_ID" \
    --ipconfig0 "ip=${VM_IP}/${VM_CIDR},gw=${VM_GW}" \
    --nameserver "$VM_DNS" \
    --searchdomain "local" \
    --ciuser ubuntu \
    --cipassword "$CI_PASS"

if [[ -n "$SSH_KEY" ]]; then
    echo "$SSH_KEY" > /tmp/vm-sshkey.pub
    qm set "$VM_ID" --sshkeys /tmp/vm-sshkey.pub
    rm -f /tmp/vm-sshkey.pub
    log "SSH Key hinterlegt"
fi

# Auto-Start nach Proxmox-Neustart
qm set "$VM_ID" --onboot 1

# Tags für Übersicht in Proxmox UI
qm set "$VM_ID" --tags "$VM_TYPE,wordpress-hosting"

log "VM ${VM_ID} konfiguriert"

# ── VM starten ────────────────────────────────────────────────────────────
info "VM wird gestartet..."
qm start "$VM_ID"

# Warten bis VM erreichbar ist
info "Warte auf SSH-Erreichbarkeit (max. 120s)..."
for i in $(seq 1 24); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes \
        ubuntu@"$VM_IP" "echo ok" &>/dev/null; then
        break
    fi
    sleep 5
    echo -n "."
done
echo ""

# ── Zugangsdaten ausgeben ─────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗"
echo -e "║   VM fertig ✓                                ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  VM-ID:         ${BOLD}${VM_ID}${NC}"
echo -e "  Typ:           ${BOLD}${VM_LABEL}${NC}"
echo -e "  IP:            ${BOLD}${VM_IP}${NC}"
echo -e "  SSH-User:      ${BOLD}ubuntu${NC}"
echo -e "  SSH-Passwort:  ${BOLD}${CI_PASS}${NC}"
echo ""

case "$VM_TYPE" in
    db)
        echo -e "${BOLD}  Nächster Schritt — auf der VM ausführen:${NC}"
        echo -e "  ssh ubuntu@${VM_IP}"
        echo -e "  curl -sO https://raw.githubusercontent.com/djanzin/wp-hosting-scripts/main/setup-db.sh"
        echo -e "  sudo bash setup-db.sh"
        ;;
    wordpress|woocommerce)
        echo -e "${BOLD}  Nächster Schritt — auf der VM ausführen:${NC}"
        echo -e "  ssh ubuntu@${VM_IP}"
        echo -e "  curl -sO https://raw.githubusercontent.com/djanzin/wp-hosting-scripts/main/setup-web.sh"
        echo -e "  sudo bash setup-web.sh"
        ;;
esac

echo ""
echo -e "${YELLOW}  → SSH-Passwort notieren!${NC}"
echo ""
