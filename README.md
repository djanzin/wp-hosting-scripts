# WP Hosting Scripts

Bash-Scripts zur automatisierten Einrichtung von WordPress- und WooCommerce-Hosting auf Ubuntu 24.04 LTS mit Proxmox.

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

| Script | Zweck | Wann ausführen |
|---|---|---|
| `setup-db.sh` | Datenbank-VM einrichten | Einmalig auf der DB-VM |
| `setup-web.sh` | Web-VM einrichten | Einmalig pro Web-VM |
| `install-wp.sh` | Neue WordPress/WooCommerce-Site anlegen | Für jede neue Site |

## Reihenfolge

### 1. Datenbank-VM

```bash
curl -sO https://raw.githubusercontent.com/djanzin/wp-hosting-scripts/main/setup-db.sh
sudo bash setup-db.sh
```

Notiere die ausgegebenen DB-Zugangsdaten — werden für `setup-web.sh` benötigt.

### 2. Web-VM(s)

```bash
curl -sO https://raw.githubusercontent.com/djanzin/wp-hosting-scripts/main/setup-web.sh
sudo bash setup-web.sh
```

Das Script fragt nach:
- VM-Typ: WordPress oder WooCommerce
- IP der Datenbank-VM
- DB-Admin-Zugangsdaten (von Schritt 1)
- Standard-Admin-E-Mail für WordPress-Sites
- IP des Nginx Proxy Managers

### 3. Neue WordPress-Site anlegen

```bash
curl -sO https://raw.githubusercontent.com/djanzin/wp-hosting-scripts/main/install-wp.sh
sudo bash install-wp.sh
```

Das Script fragt nach:
- Domain (z.B. `meinshop.de`)
- Typ: WordPress oder WooCommerce

Danach NPM Proxy-Host für die Domain anlegen (HTTP → Web-VM:80).

---

## Was wird installiert

### Web-VM
- Nginx (optimiert, FastCGI-Cache auf WooCommerce-VMs)
- PHP 8.3-FPM (eigener Pool pro Site)
- Redis (Object Cache)
- WP-CLI
- phpMyAdmin (Port 8080)
- Filebrowser (Port 8090)
- Fail2ban, UFW

### Datenbank-VM
- MariaDB (InnoDB-Buffer dynamisch an RAM angepasst)
- Zugriff nur von Web-VM-IPs

### Pro Site
- Nginx-Vhost
- PHP-FPM-Pool (WooCommerce: static, WordPress: dynamic)
- MariaDB-Datenbank + eigener User
- WordPress auf Deutsch
- Redis Object Cache Plugin
- WooCommerce + Nginx Helper (bei WooCommerce-Typ)
- Zufälliger Admin-User (14 Zeichen) + Passwort (28 Zeichen)

## Zugangsdaten

Zugangsdaten jeder Site werden gespeichert unter:
```
/etc/wp-hosting/sites/<domain>.txt
```

## Voraussetzungen

- Ubuntu 24.04 LTS auf allen VMs
- Nginx Proxy Manager läuft bereits (für SSL-Terminierung)
- Cloudflare (empfohlen, für DNS + DDoS-Schutz)
- VMs können sich gegenseitig via IP erreichen
