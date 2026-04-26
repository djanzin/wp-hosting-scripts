# WP Hosting Scripts

Vollautomatisiertes WordPress- und WooCommerce-Hosting auf Ubuntu 24.04 LTS mit Proxmox. Jede Site bekommt einen eigenen PHP-FPM-Pool, Systemuser, Datenbank, SFTP-Zugang und Filebrowser-User.

## Architektur

```
Internet → Cloudflare → Nginx Proxy Manager (SSL-Terminierung)
                                ↓ HTTP intern
                ┌───────────────┴───────────────┐
           Web-VM 1                        Web-VM 2
        (WordPress)                    (WooCommerce)
        Nginx + FastCGI-Cache          Nginx + FastCGI-Cache
        PHP 8.3-FPM (pro Site)        PHP 8.3-FPM (pro Site)
        Redis Object Cache             Redis Object Cache
        phpMyAdmin :8080               phpMyAdmin :8080
        Filebrowser :8090              Filebrowser :8090
        Netdata :19999                 Netdata :19999
                └───────────────┬───────────────┘
                           Datenbank-VM
                             MariaDB
                          Netdata :19999
```

---

## Scripts

| Script | Ausführen auf | Zweck | Wann |
|---|---|---|---|
| `proxmox-create-template.sh` | Proxmox Host | Ubuntu 24.04 Cloud-init Template erstellen | Einmalig |
| `proxmox-create-vm.sh` | Proxmox Host | VM aus Template klonen & konfigurieren | Pro neue VM |
| `setup-db.sh` | Datenbank-VM | MariaDB, Backups, Monitoring, SSH-Hardening | Einmalig pro VM |
| `setup-web.sh` | Web-VM | Nginx, PHP, Redis, Tools, Monitoring, Backups | Einmalig pro VM |
| `install-wp.sh` | Web-VM | Neue WordPress- oder WooCommerce-Site anlegen | Pro neue Site |
| `delete-wp.sh` | Web-VM | Site vollständig entfernen | Bei Bedarf |
| `maintenance.sh` | Web-VM | Maintenance Mode ein-/ausschalten | Bei Bedarf |
| `update-wp.sh` | Web-VM | WordPress Core, Plugins, Themes aktualisieren | Regelmäßig |
| `list-sites.sh` | Web-VM | Alle Sites mit Status anzeigen | Bei Bedarf |
| `clone-site.sh` | Web-VM | Bestehende Site auf neue Domain klonen | Bei Bedarf |
| `migrate-wp.sh` | Web-VM | Externe WordPress-Site importieren | Bei Bedarf |
| `health-check.sh` | Web-VM | HTTP, PHP-FPM, DB aller Sites prüfen | Bei Bedarf |
| `reset-wp-admin.sh` | Web-VM | WordPress-Admin-Passwort zurücksetzen | Bei Bedarf |
| `rotate-keys.sh` | Web-VM | WordPress Security Keys rotieren | Alle 3–6 Monate |
| `db-backup.sh` | Datenbank-VM | Manuellen MariaDB-Dump erstellen | Bei Bedarf |

---

## Komplette Einrichtung — Schritt für Schritt

### Schritt 1 — Template erstellen (Proxmox Host, einmalig)

```bash
bash proxmox-create-template.sh
```

Erstellt ein Ubuntu 24.04 Cloud-init Template (Standard-ID: 9000).

---

### Schritt 2 — VMs anlegen (Proxmox Host)

```bash
bash proxmox-create-vm.sh   # Datenbank-VM
bash proxmox-create-vm.sh   # WordPress-VM
bash proxmox-create-vm.sh   # WooCommerce-VM
```

**Empfohlene Ressourcen:**

| VM | vCPU | RAM | Disk |
|---|---|---|---|
| Datenbank | 4 | 8 GB | 50 GB |
| WordPress | 2 | 4 GB | 30 GB |
| WooCommerce | 4 | 8 GB | 40 GB |

---

### Schritt 3 — Datenbank-VM einrichten

```bash
ssh ubuntu@<DB-VM-IP>
sudo bash setup-db.sh
```

Gibt DB-Admin-Zugangsdaten aus → für Schritt 4 notieren.

---

### Schritt 4 — Web-VMs einrichten (je VM wiederholen)

```bash
ssh ubuntu@<WEB-VM-IP>
sudo bash setup-web.sh
```

Fragt nach: VM-Typ, DB-VM-IP, DB-Zugangsdaten, Admin-E-Mail, NPM-IP, Webhook-URL, SEOpress-Key, Remote-Backup-Ziel.

---

### Schritt 5 — Neue Site anlegen

```bash
sudo bash install-wp.sh
```

Fragt nach Domain und Typ (WordPress oder WooCommerce).
Danach NPM Proxy-Host anlegen: `https://domain.de → http://<WEB-VM-IP>:80`

---

### Schritt 6 — Site freischalten

Jede neue Site startet im **Maintenance Mode**:

```bash
sudo bash maintenance.sh
```

→ Domain auswählen → freischalten → Site ist live.

---

## Was wird pro Site installiert

### Infrastruktur
- Eigener **Systemuser** (`wp_domain_com`) — PHP-FPM läuft unter diesem User
- Eigener **PHP-FPM-Pool** (dynamic für WP, static für WooCommerce, Slow Log ab 5s)
- Eigener **Nginx-Vhost** mit FastCGI-Cache und WebP-Serving
- Eigene **MariaDB-Datenbank** + User mit 32-stelligem Passwort
- **WP-Cron** via System-Cron (alle 5 Minuten, kein Frontend-Overhead)
- **SFTP-Zugang** (Chroot-Jail, Passwort-Auth, landet direkt im Site-Verzeichnis)
- **Filebrowser-User** mit Scope auf das Site-Verzeichnis

### WordPress-Konfiguration
- Sprache: `en_US`, Zeitzone: `Europe/Berlin`, Datum: `Y-m-d H:i`
- Permalinks: `/%category%/%postname%/`
- Admin-Profil: Danijel Janzin, Spitzname Dany
- `DISALLOW_FILE_EDIT`, `FORCE_SSL_ADMIN`, `WP_DEBUG false`
- `WP_MEMORY_LIMIT 256M` / `WP_MAX_MEMORY_LIMIT 512M`
- `WP_POST_REVISIONS 5`, `EMPTY_TRASH_DAYS 7`, `AUTOSAVE_INTERVAL 120`
- `WP_CACHE true` (FastCGI + Redis Object Cache)
- X-Forwarded-Proto-Fix für HTTPS hinter NPM

### Plugins (automatisch installiert & konfiguriert)
| Plugin | Zweck |
|---|---|
| Redis Object Cache | Object-Caching via Redis |
| Nginx Helper | FastCGI-Cache automatisch leeren |
| FluentSMTP | SMTP-E-Mail-Versand |
| Antispam Bee | Kommentar-Spam filtern |
| Simple Cloudflare Turnstile | Bot-Schutz für Formulare |
| WebP Converter for Media | Bilder bei Upload in WebP konvertieren |
| Two Factor | 2FA für WP-Admin |
| SEOpress + SEOpress Pro | SEO (Pro-ZIP + Lizenz-Key aus Config) |
| FAZ Cookie Manager | DSGVO-konformes Cookie Consent (GitHub) |

### Bloat-Entfernung
- Plugins: `hello`, `akismet` gelöscht
- Themes: `twentytwentyone` bis `twentytwentyfour` gelöscht
- Inhalte: Hello-World-Post, Sample-Page, Standard-Kommentar gelöscht
- Dateien: `readme.html`, `license.txt`, `wp-config-sample.php` gelöscht
- Pingbacks + Trackbacks deaktiviert

### Must-Use Plugins (automatisch, nicht deaktivierbar)
| Datei | Funktion |
|---|---|
| `server-cache.php` | Site-Health-Cache-Warnung unterdrücken |
| `performance.php` | Heartbeat drosseln, Admin-Bar ausblenden, Author-Enumeration blockieren |
| `maintenance-mode.php` | Maintenance Mode (Flag-Datei `/wp-content/.maintenance-active`) |
| `digital-checkout.php` | Widerrufsrecht-Checkbox bei WooCommerce (nur wenn downloadbare Produkte im Warenkorb) |

### WooCommerce (zusätzlich)
- Land: Deutschland, Währung: EUR
- Gastbestellung aktiviert, Checkout-Login-Erinnerung aktiviert
- Tracking, Marketplace-Vorschläge, Remote-Logging deaktiviert
- **Rechtliche Seiten** automatisch angelegt: Impressum, Datenschutzerklärung, AGB, Widerrufsbelehrung, Lieferung & Download
- AGB als Terms-Page, Datenschutz als Privacy-Page zugewiesen
- **E-Mail-Absender**: Shop-Name + `noreply@domain.de` + Footer mit Impressum-Link
- **Widerrufsrecht-Checkbox** beim Checkout (§ 356 Abs. 5 BGB) — nur bei digitalen Produkten, server-seitig validiert, Zustimmung mit Zeitstempel in Bestellung gespeichert

> ⚠️ Rechtliche Texte müssen manuell befüllt werden. Empfehlung: [IT-Recht Kanzlei](https://www.it-recht-kanzlei.de) (Digital-Paket).

---

## Monitoring & Alerts

| Alert | Trigger | Kanal |
|---|---|---|
| 🟡 Disk Warnung | Partition > 80% belegt | Webhook (stündlich) |
| 🔴 Disk Kritisch | Partition > 90% belegt | Webhook (stündlich) |
| 🟢 Disk OK | Partition wieder < 80% | Webhook (Recovery) |
| 🟡 SSL Warnung | Zertifikat läuft in < 30 Tagen ab | Webhook (täglich 07:00) |
| 🔴 SSL Kritisch | Zertifikat läuft in < 7 Tagen ab | Webhook (täglich 07:00) |
| 🟢 SSL Erneuert | Zertifikat wieder > 30 Tage gültig | Webhook (Recovery) |
| Auto-Update | Wöchentlicher Update-Lauf abgeschlossen | Webhook (sonntags 03:00) |

Alle Alerts nutzen state-tracking — kein Spam, nur bei Zustandsänderung.
Webhook-Format kompatibel mit **Discord** und **Slack**.

---

## Backup

### WordPress-Dateien (Web-VM)
- Täglich 02:00: `wp-content/` als `.tar.gz` nach `/var/backups/wp-files/`
- 7 Tage lokale Aufbewahrung
- Optional: Remote-Upload via rclone (Cloudflare R2, S3, SFTP)

### Datenbank (DB-VM)
- Täglich 02:00: Alle Datenbanken als komprimierter SQL-Dump nach `/var/backups/mysql/`
- 7 Tage lokale Aufbewahrung
- Optional: Remote-Upload via rclone

---

## Zugangsdaten

| Datei | Inhalt |
|---|---|
| `/etc/wp-hosting/config` | VM-Typ, DB-Zugangsdaten, Webhook-URL, SEOpress-Key (Web-VM) |
| `/etc/wp-hosting/db-credentials.txt` | DB-Admin-Zugangsdaten (DB-VM) |
| `/etc/wp-hosting/sites/<domain>.txt` | WP-Admin, DB, Filebrowser, SFTP pro Site |
| `/etc/wp-hosting/deleted/<domain>.<datum>.txt` | Archivierte Zugangsdaten gelöschter Sites |

---

## SFTP-Zugang pro Site

```
Host:     <Web-VM-IP>
Port:     22
User:     wp_domain_com
Passwort: <aus /etc/wp-hosting/sites/domain.txt>
Pfad:     /site  (entspricht /var/www/domain.com)
```

Chroot-Jail — kein Zugriff auf andere Sites möglich.

---

## Maintenance Mode

```bash
sudo bash maintenance.sh
```

- Zeigt alle Sites mit Status `[LIVE]` oder `[MAINTENANCE]`
- Besucher sehen eine 503-Seite (dunkles Design, kein WordPress-Branding)
- Admins können sich einloggen und normal arbeiten
- Neue Sites starten automatisch im Maintenance Mode

---

## Voraussetzungen

- Proxmox VE 8.x
- Nginx Proxy Manager (SSL-Terminierung)
- Cloudflare (empfohlen, für Real-IP-Header)
- VMs können sich gegenseitig per IP erreichen
- Für Webhooks: Discord- oder Slack-Webhook-URL
