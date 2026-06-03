# Site-Liste aus Google Sheet (über n8n)

Komfortable Pflege der Site-Liste in einem Google Sheet; `fetch-sheet.sh` holt sie
über einen n8n-Webhook und erzeugt die `sites.csv` für `batch-install.sh`.

```
Google Sheet ──> n8n (Webhook → Google Sheets → CSV) ──> fetch-sheet.sh ──> sites.csv ──> batch-install.sh
```

> **Sicherheits-Grenze:** Im Sheet stehen NUR nicht-geheime Inventardaten. Credentials
> (DB-Passwort, R2/S3/SES-Keys) bleiben in `setup-web.conf` auf dem Server — niemals ins Sheet.

## 1. Google Sheet anlegen (Master-Tabelle)

Tabelle „Sites", **erste Zeile = Header**. Die **ersten 5 Spalten in exakt dieser
Reihenfolge** werden vom Installer verarbeitet (Spalte 5 = `matomo_site_id`), alle
weiteren sind reine Referenz-/Tracking-Felder (zentrale Übersicht aller Sites):

**Script-Spalten (Reihenfolge fix, werden installiert):**

| domain | type | shop_name | admin_ip |
|---|---|---|---|
| blog1.de | wordpress | | |
| best4software.de | woocommerce | Best4Software | |
| intern.de | woocommerce | Intern | 203.0.113.10 |

- `type` = `wordpress` | `woocommerce` | `mainwp`
- `shop_name` nur bei woocommerce (leer = Domain)
- `admin_ip` optional (wp-admin/Login auf IP beschränken)

**Spalte 5 wird verarbeitet, der Rest ist Referenz:**

| Spalte | Zweck |
|---|---|
| `matomo_site_id` | **wird genutzt** → `install-wp.sh --matomo-site-id` setzt SEOpress-Matomo-Tracking (Host aus `MATOMO_URL`). Leer = übersprungen. |
| `google_ads_id` | Google Ads Conversion-ID (in Pixel Manager) |
| `meta_pixel_id` | Meta Pixel-ID |
| `tiktok_pixel_id` | TikTok Pixel-ID |
| `pinterest_tag` | Pinterest Tag-ID |
| `bing_uet_id` | Microsoft/Bing UET-Tag-ID |
| `ses_from_email` | FluentSMTP/SES-Absender (`noreply@domain.de`) |
| `dns_ok` / `installed` / `live` | Status-Häkchen (`x`) |
| `notes` | freie Notizen |

> Vollständige Header-Zeile (kopierbar): siehe `sites.csv.example`. `batch-install.sh`
> verarbeitet die **ersten 5 Spalten** (domain, type, shop_name, admin_ip, matomo_site_id),
> der Rest (Pixel-IDs/Status/Notizen) ist Referenz. **Reihenfolge der ersten 5 muss stimmen.**
> Die Pixel-IDs werden manuell in Pixel Manager je Shop eingetragen (kein Auto-Push, da serialisiert).

## 2. n8n-Workflow

Drei Nodes:

1. **Webhook** (Trigger)
   - Method `GET`, Path z.B. `wp-sites`
   - Optional Header-Auth: Header `Authorization` == `Bearer <DEIN_TOKEN>`
     (gleicher Token wie `SHEET_WEBHOOK_TOKEN` in `sheet.conf`)
   - „Respond" = **Using 'Respond to Webhook' node**

2. **Google Sheets** → *Get Row(s)*
   - Credential: dein Google-Account (in n8n bereits verbunden)
   - Document = das Sheet, Sheet = „Sites", Range = alle Zeilen

3. **Respond to Webhook**
   - Response Code 200, **Content-Type `text/csv`**
   - Body = CSV-String. Entweder ein kleiner Code-Node davor, der die Items zu CSV
     joint, oder „Convert to File" (CSV) → Binary zurückgeben.
   - Erste Zeile MUSS der Header `domain,type,shop_name,admin_ip` sein.

   Beispiel Code-Node (Function) vor „Respond", erzeugt CSV-Text aus allen Spalten.
   `COLS` = Reihenfolge der Spalten; die ersten 5 sind die Script-Spalten:
   ```js
   const COLS = ['domain','type','shop_name','admin_ip',
                 'matomo_site_id','google_ads_id','meta_pixel_id','tiktok_pixel_id',
                 'pinterest_tag','bing_uet_id','ses_from_email','dns_ok','installed','live','notes'];
   const esc = v => {
     v = (v ?? '').toString();
     return /[",\n]/.test(v) ? '"' + v.replace(/"/g,'""') + '"' : v;
   };
   const header = COLS.join(',');
   const rows = items.map(i => COLS.map(c => esc(i.json[c])).join(','));
   return [{ json: { csv: [header, ...rows].join('\n') } }];
   ```
   Im „Respond to Webhook"-Node dann `{{ $json.csv }}` als Body, Content-Type `text/csv`.
   (Die Google-Sheets-Spaltennamen müssen den Keys in `COLS` entsprechen.)

4. **Workflow aktivieren** → Production-Webhook-URL kopieren.

## 3. Server-Konfiguration

```bash
cp sheet.conf.example sheet.conf
# SHEET_WEBHOOK_URL + SHEET_WEBHOOK_TOKEN eintragen
chmod 600 sheet.conf
```

## 4. Ablauf

```bash
bash fetch-sheet.sh --print          # Vorschau (nichts schreiben)
bash fetch-sheet.sh                  # → sites.csv (Backup der alten als .bak)
bash check-dns.sh --csv sites.csv --ip <server-ip>   # DNS-Readiness
sudo bash batch-install.sh sites.csv --dry-run       # Install-Vorschau
sudo bash batch-install.sh sites.csv                 # Anlage
```

## Sicherheit / Robustheit
- `fetch-sheet.sh` erkennt, wenn der Webhook **JSON statt CSV** liefert (n8n-Fehler)
  und bricht ab, statt eine kaputte `sites.csv` zu schreiben.
- Prüft, dass der Header eine `domain`-Spalte hat; normalisiert CRLF.
- Überschreibt `sites.csv` nur nach Rückfrage (`--force` zum Übergehen), legt `.bak` an.
- **Token setzen** — sonst ist die Site-Liste über die Webhook-URL öffentlich abrufbar.
