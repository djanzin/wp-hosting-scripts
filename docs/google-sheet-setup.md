# Site-Liste aus Google Sheet (über n8n)

Komfortable Pflege der Site-Liste in einem Google Sheet; `fetch-sheet.sh` holt sie
über einen n8n-Webhook und erzeugt die `sites.csv` für `batch-install.sh`.

```
Google Sheet ──> n8n (Webhook → Google Sheets → CSV) ──> fetch-sheet.sh ──> sites.csv ──> batch-install.sh
```

> **Sicherheits-Grenze:** Im Sheet stehen NUR nicht-geheime Inventardaten. Credentials
> (DB-Passwort, R2/S3/SES-Keys) bleiben in `setup-web.conf` auf dem Server — niemals ins Sheet.

## 1. Google Sheet anlegen

Tabelle „Sites", **erste Zeile = Header** mit exakt diesen Spaltennamen:

| domain | type | shop_name | admin_ip |
|---|---|---|---|
| blog1.de | wordpress | | |
| best4software.de | woocommerce | Best4Software | |
| intern.de | woocommerce | Intern | 203.0.113.10 |

- `type` = `wordpress` | `woocommerce` | `mainwp`
- `shop_name` nur bei woocommerce (leer = Domain)
- `admin_ip` optional (wp-admin/Login auf IP beschränken)
- Zusätzliche Spalten (z.B. `matomo_site_id`, Notizen) stören nicht — `batch-install.sh`
  liest nur die ersten vier. Reihenfolge der vier muss stimmen.

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

   Beispiel Code-Node (Function) vor „Respond", erzeugt CSV-Text:
   ```js
   const header = 'domain,type,shop_name,admin_ip';
   const esc = v => {
     v = (v ?? '').toString();
     return /[",\n]/.test(v) ? '"' + v.replace(/"/g,'""') + '"' : v;
   };
   const rows = items.map(i => {
     const d = i.json;
     return [d.domain, d.type, d.shop_name, d.admin_ip].map(esc).join(',');
   });
   return [{ json: { csv: [header, ...rows].join('\n') } }];
   ```
   Im „Respond to Webhook"-Node dann `{{ $json.csv }}` als Body, Content-Type `text/csv`.

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
