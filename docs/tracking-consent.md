# Tracking, Analytics, Ad-Feeds & Consent

Architektur und Pro-Shop-Einrichtung für Analytics, Werbe-Pixel, Produktfeeds und
DSGVO/TTDSG-konformes Consent-Gating auf den WooCommerce-Shops.

> **Lean-Architektur (Variante A):** Ein Feed-Tool (PFM), ein Pixel-Tool (PMW),
> eine CMP (FAZ), Analytics über SEOpress→Matomo. Keine offiziellen Channel-Plugins,
> kein Google Tag Manager, kein GA4.

## Überblick

| Zweck | Tool | Consent |
|---|---|---|
| Analytics (Traffic, Verhalten, E-Commerce) | **Matomo** via SEOpress-Modul (cookieless, IP-anon) | consent-frei |
| Alle Ad-Pixel (Google/Meta/TikTok/Pinterest/Bing) + Server-Side CAPI | **Pixel Manager Pro** (PMW) | via FAZ / Consent Mode v2 |
| Produktfeeds/Kataloge (alle Plattformen + Idealo) | **Product Feed Manager** (PFM) | — |
| Consent-Banner (CMP) | **FAZ Cookie Manager** | — |
| GA4, Google Tag Manager, SEOpress-Cookie-Banner | **nicht genutzt** | — |

**Warum so:** PMW ersetzt GTM (turnkey, WooCommerce-spezifisch) und feuert alle Pixel
consent-aware. PFM erzeugt jeden Katalog inkl. Google Content-API-Auto-Sync. Matomo
ersetzt GA4 (self-hosted, cookieless → misst alle Besucher, nicht nur Einwilliger).

## Auto-installiert via `install-wp.sh` (Woo-Sites)

- `best-woocommerce-feed` — Product Feed Manager (Free)
- `woocommerce-google-adwords-conversion-tracking-tag` — Pixel Manager (Free-Basis)
- `pixel-manager-pro.zip` aus `wp-plugins`-Bucket — PMW Pro (für TikTok/Pinterest/Bing + CAPI)
- (SEOpress, FAZ Cookie Manager bereits Teil des Standard-Stacks)

## Pro-Shop-Einrichtung (GUI — manuell pro Shop)

### 1. Analytics — Matomo via SEOpress
**Automatisierbar:** `install-wp.sh --matomo-site-id <n>` (bzw. CSV-Spalte `matomo_site_id`)
setzt das SEOpress-Matomo-Tracking direkt — Host aus `MATOMO_URL` in
`/etc/wp-hosting/config` (in `setup-web.sh` hinterlegt). Aktiviert: cookieless
(`no_cookies`) + DNT → **consent-frei**, self-hosted, mit Site-ID.
- Manuell (ohne Flag): SEOpress → **Analytics → Matomo** → „Enable Matomo tracking",
  Tracking-URL = zentrale Instanz, Site-ID je Shop, cookieless.
- E-Commerce-Tracking im SEOpress-Matomo-Tab je Shop noch aktivieren.
- SEOpress-eigenen **Cookie-Banner: AUS** (FAZ ist die CMP)
- **Kein GA4** einrichten

### 2. Consent — FAZ Cookie Manager (einzige CMP)
- **Google Consent Mode v2** aktivieren
- Kategorien: notwendig / funktional / analytics / marketing — **Default: denied**
- Einziger Consent-Banner auf der Site

### 3. Ad-Pixel — Pixel Manager Pro
Pixel-IDs + Server-Side CAPI je Plattform eintragen; Consent-Mode-Respekt aktiv
(PMW liest die FAZ-Consent-Signale und blockt/entsperrt entsprechend):

| Plattform | Eintragen in PMW | Hinweis |
|---|---|---|
| Google Ads | Conversion-ID + Label | Conversion-Tag = primäres Smart-Bidding-Signal (kein GA4 nötig) |
| Meta | Pixel-ID + CAPI-Token | CAPI = Server-Side, holt iOS/Adblocker-Conversions |
| TikTok | Pixel-ID + CAPI | PMW Pro |
| Pinterest | Tag-ID + CAPI | PMW Pro (kein buggy Pinterest-Plugin) |
| **Bing (Microsoft Ads)** | **UET-Tag-ID** + CAPI | PMW Pro — Details unten |

#### Bing / Microsoft Ads (UET) im Detail
1. Microsoft Advertising → **Tools → Conversion tracking → UET tag** → UET-Tag-ID kopieren
2. UET-Tag-ID in PMW eintragen → PMW feuert Purchase-/E-Commerce-Events inkl. Umsatz automatisch
3. In Microsoft Ads ein **Event-basiertes** Conversion-Ziel anlegen (purchase-Event,
   **nicht** Ziel-URL — weniger fehleranfällig)
4. Enhanced Conversions (gehashte First-Party-Daten) = PMW Pro
5. UET wird über dieselben Consent-Mode-v2-Signale (FAZ) gegated

### 4. Produktfeeds — Product Feed Manager
Pro Plattform einen Feed anlegen (Template wählen), Schedule = täglich (24h):

| Plattform | PFM-Template | Auslieferung |
|---|---|---|
| Google Shopping | Google + **Content-API-Auto-Sync** | direkt an Merchant Center |
| Meta Catalog | Facebook/Meta | Feed-URL → Meta Commerce Manager |
| TikTok | TikTok | Feed-URL → TikTok Catalog |
| Pinterest | Pinterest | Feed-URL → Pinterest Catalog |
| Bing Shopping | Bing/Microsoft | Feed-URL → Microsoft Merchant Center |
| Idealo / Preisvergleich | jeweiliges Template | öffentliche Feed-URL |

EAN/GTIN wird aus dem nativen WooCommerce-GTIN-Feld gemappt. Bei Shops mit >200
Produkten die **PFM-Pro-Lizenz** (1-Site) manuell aktivieren.

## Verifikation (pro Shop nach Einrichtung)

1. **Consent-Test (DevTools → Network), VOR Zustimmung — keine dieser Requests:**
   `facebook.com/tr`, `analytics.tiktok.com`, `ct.pinterest.com`, `bat.bing.com`;
   Google nur als Consent-Mode-„denied"-Ping. `gtag('consent')`-Default = denied.
2. **Nach „Alle akzeptieren":** alle Pixel feuern.
3. **Matomo:** Besuch ohne Consent erscheint trotzdem (cookieless); Testbestellung → Umsatz sichtbar.
4. **Kein Doppel-Tracking:** Testbestellung → je Plattform genau **ein** Purchase-Event.
5. **Server-Side CAPI:** Events-Manager (Meta/TikTok/Pinterest/Bing) → Events kommen „server-side" rein.

## Wichtige Hinweise
- **FAZ↔PMW** läuft über Consent-Mode-v2-Signale (FAZ ist „new" in PMWs CMP-Liste) →
  beim ersten Shop den Consent-Test oben **zwingend** durchführen. Bei Problemen erst
  `gtag('consent')`/`dataLayer` in DevTools prüfen, dann PMW-Consent-Settings.
- **PMW-Pro-ZIP** einmalig als `pixel-manager-pro.zip` in den `wp-plugins`-Bucket legen,
  dann `sudo bash sync-plugins.sh --plugins`.
- Ad-Konten-Verbindungen (Merchant Center / Meta Business / TikTok / Pinterest /
  Microsoft) bleiben manuell pro Shop.
