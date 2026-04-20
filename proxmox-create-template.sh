#!/bin/bash
# Erstellt ein Ubuntu 24.04 Cloud-init Template in Proxmox
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
echo "║   Proxmox Template erstellen                 ║"
echo "║   Ubuntu 24.04 LTS Cloud-init                ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Konfiguration abfragen ─────────────────────────────────────────────────
read -rp "Template-VM-ID [Standard: 9000]: " TEMPLATE_ID
TEMPLATE_ID=${TEMPLATE_ID:-9000}

if qm status "$TEMPLATE_ID" &>/dev/null; then
    err "VM-ID ${TEMPLATE_ID} existiert bereits. Andere ID wählen oder bestehende VM löschen."
fi

# Verfügbare Storages anzeigen
echo ""
info "Verfügbare Storages:"
pvesm status | awk 'NR>1 {print "  " $1 " (" $2 ")"}'
echo ""
read -rp "Storage für Template [Standard: local-lvm]: " STORAGE
STORAGE=${STORAGE:-local-lvm}

read -rp "Netzwerk-Bridge [Standard: vmbr0]: " BRIDGE
BRIDGE=${BRIDGE:-vmbr0}

echo ""
info "Template-ID: ${BOLD}${TEMPLATE_ID}${NC}"
info "Storage:     ${BOLD}${STORAGE}${NC}"
info "Bridge:      ${BOLD}${BRIDGE}${NC}"
echo ""
read -rp "Template erstellen? [j/N]: " confirm
[[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."

# ── Ubuntu 24.04 Cloud Image herunterladen ─────────────────────────────────
IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMG_FILE="/tmp/ubuntu-24.04-cloud.img"

if [[ -f "$IMG_FILE" ]]; then
    warn "Image bereits vorhanden — wird wiederverwendet."
else
    info "Ubuntu 24.04 Cloud Image wird heruntergeladen..."
    wget -q --show-progress "$IMG_URL" -O "$IMG_FILE"
    log "Image heruntergeladen"
fi

# ── VM erstellen ──────────────────────────────────────────────────────────
info "VM ${TEMPLATE_ID} wird erstellt..."

qm create "$TEMPLATE_ID" \
    --name "ubuntu-2404-template" \
    --memory 2048 \
    --cores 2 \
    --net0 "virtio,bridge=${BRIDGE}" \
    --ostype l26 \
    --machine q35 \
    --bios ovmf \
    --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=1" \
    --scsihw virtio-scsi-pci \
    --serial0 socket \
    --vga serial0 \
    --agent enabled=1,fstrim_cloned_disks=1 \
    --onboot 0

# Cloud Image als Disk importieren
info "Disk wird importiert..."
qm importdisk "$TEMPLATE_ID" "$IMG_FILE" "$STORAGE"
qm set "$TEMPLATE_ID" --scsi0 "${STORAGE}:vm-${TEMPLATE_ID}-disk-1,cache=writethrough,discard=on,ssd=1"

# Cloud-init Drive
qm set "$TEMPLATE_ID" --ide2 "${STORAGE}:cloudinit"

# Boot von der Disk
qm set "$TEMPLATE_ID" --boot order=scsi0

# Cloud-init Standardwerte
qm set "$TEMPLATE_ID" \
    --citype nocloud \
    --ciuser ubuntu \
    --ipconfig0 "ip=dhcp"

# Disk auf 10 GB vergrößern (Basis für spätere Klone)
qm resize "$TEMPLATE_ID" scsi0 10G

log "VM ${TEMPLATE_ID} konfiguriert"

# ── In Template umwandeln ─────────────────────────────────────────────────
qm template "$TEMPLATE_ID"
log "Template erstellt: ubuntu-2404-template (ID: ${TEMPLATE_ID})"

# Temporäres Image entfernen
rm -f "$IMG_FILE"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗"
echo -e "║   Template fertig ✓                          ║"
echo -e "╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Template-ID:  ${BOLD}${TEMPLATE_ID}${NC}"
echo -e "  Storage:      ${BOLD}${STORAGE}${NC}"
echo ""
echo -e "${YELLOW}  → Jetzt proxmox-create-vm.sh ausführen um VMs zu klonen.${NC}"
echo ""
