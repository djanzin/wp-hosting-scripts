# WP Hosting Scripts

Bash-Scripts zur vollautomatisierten Einrichtung von WordPress- und WooCommerce-Hosting auf Ubuntu 24.04 LTS mit Proxmox.

## Architektur

```
Internet → Cloudflare → Nginx Proxy Manager (SSL)
                              ↓ HTTP intern
              ┌───────────────┴───────────────┐
         Web-VM 1                        Web-VM 2
      (WordPress)                    (WooCommerce)
      Nginx, PHP 8.3                 Nginx, PHP 8.3
      Redis, WP-CLI                  Redis, WP-CLI
      phpMyAdmin                     phpMyAdmin
      Filebrowser                    Filebrowser
              └───────────────┬───────────────┘
                         Datenbank-VM
                           (MariaDB)
```

## Scripts

| Script | Ausführen auf | Zweck | Wann |
|---|---|---|---|
| `proxmox-create-template.sh` | Proxmox Host | Ubuntu 24.04 Cloud-init Template erstellen | Einmalig |
| `proxmox-create-vm.sh` | Proxmox Host | VM aus Template klonen & konfigurieren | Pro neue VM |
| `setup-db.sh` | Datenbank-VM | MariaDB, Swap, Netdata, SSH-Hardening | Einmalig pro VM |
| `setup-web.sh` | Web-VM | Nginx, PHP, Redis, phpMyAdmin, Filebrowser, Netdata | Einmalig pro VM |
| `install-wp.sh` | Web-VM | Neue WordPress/WooCommerce-Site anlegen | Pro neue Site |
| `delete-wp.sh` | Web-VM | Site vollständig entfernen | Bei Bedarf |
| `update-wp.sh` | Web-VM | WordPress Core, Plugins, Themes aktualisieren | Regelmäßig |
| `list-sites.sh` | Web-VM | Alle Sites mit Status anzeigen | Bei Bedarf |
| `clone-site.sh` | Web-VM | Bestehende Site auf neue Domain klonen (Staging) | Bei Bedarf |
| `migrate-wp.sh` | Web-VM | Externe Site per SSH oder Datei-Upload migrieren | Bei Bedarf |
| `reset-wp-admin.sh` | Web-VM | WordPress-Admin-Passwort zurücksetzen | Bei Bedarf |
| `db-backup.sh` | Datenbank-VM | Manueller MariaDB-Dump (läuft auch automatisch) | Bei Bedarf |
| `rotate-keys.sh` | Web-VM | WordPress Security Keys & Salts rotieren (zwingt Re-Login) | Alle 3-6 Monate |
| `health-check.sh` | Web-VM | HTTP-Status, PHP-FPM Socket und DB-Verbindung aller Sites prüfen | Bei Bedarf / Cron |

---

## Komplette Einrichtung — Schritt für Schritt

### Schritt 1: Template erstellen (Proxmox Host, einmalig)

```bash
curl -sO https://raw.githubusercontent.com/djanzin/wp-hosting-scripts/main/proxmox-create-template.sh
bash proxmox-create-template.sh
```

Erstellt ein Ubuntu 24.04 Cloud-init Template (Standard-ID: 9000).

---

### Schritt 2: VMs anlegen (Proxmox Host, pro VM)

```bash
curl -sO https://raw.githubusercontent.com/djanzin/wp-hosting-scripts/main/proxmox-create-vm.sh
bash proxmox-create-vm.sh
```

Das Script fragt nach VM-Typ, IP, Hostname, Storage — und gibt am Ende den SSH-Befehl für den nächsten Schritt aus.

**Empfohlene Ressourcen pro VM-Typ:**

| VM-Typ | vCPU | RAM | Disk |
|---|---|---|---|
| Datenbank | 4 | 8 GB | 50 GB |
| WordPress | 2 | 4 GB | 30 GB |
| WooCommerce | 4 | 8 GB | 40 GB |

---

### Schritt 3: Datenbank-VM einrichten

```bash
ssh ubuntu@<DB-VM-IP>
curl -sO https://raw.githubusercontent.com/djanzin/wp-hosting-scripts/main/setup-db.sh
sudo bash setup-db.sh
```

Das Script gibt DB-Admin-Zugangsdaten aus → für Schritt 4 notieren.

---

### Schritt 4: Web-VM(s) einrichten

```bash
ssh ubuntu@<WEB-VM-IP>
curl -sO https://raw.githubusercontent.com/djanzin/wp-hosting-scripts/main/setup-web.sh
sudo bash setup-web.sh
```

Fragt nach VM-Typ (WP/WooCommerce), DB-VM-IP und DB-Zugangsdaten aus Schritt 3.

---

### Schritt 5: Neue WordPress-Site anlegen

```bash
curl -sO https://raw.githubusercontent.com/djanzin/wp-hosting-scripts/main/install-wp.sh
sudo bash install-wp.sh
```

Fragt nach Domain und Typ (WordPress oder WooCommerce). Läuft für **jede neue Site** erneut.

Danach NPM Proxy-Host anlegen: `https://domain.de → http://<WEB-VM-IP>:80`

---

### Site verwalten

```bash
# Übersicht aller Sites mit Status
./list-sites.sh

# Alle Sites aktualisieren (Core + Plugins + Themes)
./update-wp.sh

# Site vollständig entfernen
./delete-wp.sh

# Admin-Passwort zurücksetzen
./reset-wp-admin.sh

# Bestehende Site auf neue Domain klonen (z.B. Staging)
./clone-site.sh

# Externe WordPress-Site migrieren (SSH oder lokale Dateien)
./migrate-wp.sh

# Manueller Datenbank-Dump (DB-VM)
./db-backup.sh

# Security Keys rotieren (alle User werden ausgeloggt)
./rotate-keys.sh

# Health Check (HTTP, PHP-FPM, DB aller Sites)
./health-check.sh

# Health Check mit Webhook-Benachrichtigung (auch bei OK-Status)
./health-check.sh --notify
```

---

## Was wird installiert

### Web-VM
- Nginx (FastCGI-Cache auf WooCommerce-VMs, Rate-Limit für wp-login)
- PHP 8.3-FPM (eigener Pool pro Site, static/dynamic je nach Typ)
- Redis Object Cache (512 MB WooCommerce / 256 MB WordPress)
- WP-CLI
- phpMyAdmin auf Port 8080 — nur von NPM-IP erreichbar
- Filebrowser auf Port 8090 — nur von NPM-IP erreichbar
- Netdata Monitoring auf Port 19999
- Swap (dynamisch berechnet, swappiness=10)
- Log-Rotation (14 Tage, täglich komprimiert)
- Fail2ban, UFW
- SSH-Hardening (Root-Login deaktiviert, optional Key-only Auth)
- Automatische Sicherheitsupdates (unattended-upgrades)
- Optionaler Auto-Update-Cron (sonntags 03:00)
- Webhook-Benachrichtigungen bei Updates

### Datenbank-VM
- MariaDB (InnoDB Buffer dynamisch: 50 % des verfügbaren RAM)
- Automatische Backups täglich 02:00 → /var/backups/mysql (7 Tage)
- Remote-Zugriff nur von Web-VM-IPs
- Slow Query Log aktiviert
- Automatische Sicherheitsupdates (unattended-upgrades)
- Automatische Backups täglich 02:00 + optionaler Remote-Upload (R2/S3/SFTP via rclone)
- Netdata Monitoring auf Port 19999
- Swap (dynamisch berechnet)
- SSH-Hardening (Root-Login deaktiviert, optional Key-only Auth)

### Pro Site (install-wp.sh)
- Nginx-Vhost (optional: wp-admin auf bestimmte IP beschränken)
- PHP-FPM-Pool mit automatisch berechnetem Worker-Count (Slow Log ab 5s)
- `DISALLOW_FILE_EDIT` — Theme/Plugin-Editor im WP-Dashboard deaktiviert
- MariaDB-Datenbank + eigener User (32-stelliges Passwort)
- WordPress auf Deutsch
- Redis Object Cache Plugin
- WooCommerce + Nginx Helper bei WooCommerce-Sites
- Zufälliger Admin-User (14 Zeichen) + Passwort (28 Zeichen)
- System-Cron für WP-Cron (alle 5 Minuten, kein Performance-Overhead)
- Zugangsdaten gespeichert unter `/etc/wp-hosting/sites/<domain>.txt`

---

## Zugangsdaten

| Datei | Inhalt |
|---|---|
| `/etc/wp-hosting/config` | DB-Host, Admin-Credentials (Web-VM) |
| `/etc/wp-hosting/db-credentials.txt` | DB-Admin-Zugangsdaten (DB-VM) |
| `/etc/wp-hosting/sites/<domain>.txt` | WP-Admin + DB-Daten pro Site |

---

## Voraussetzungen

- Proxmox VE (getestet mit 8.x)
- Nginx Proxy Manager läuft bereits (für SSL-Terminierung)
- Cloudflare (empfohlen)
- VMs können sich gegenseitig per IP erreichen
