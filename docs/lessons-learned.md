# Lessons Learned

Wiederkehrende Fehlerklassen und die daraus abgeleiteten Regeln. **Zweck:** ein
einmal gemachter Fehler soll nicht erneut passieren — weder von Menschen noch von
KI-Assistenten, die an diesem Repo arbeiten. Jeder Eintrag nennt Symptom, Ursache,
Fix und die dauerhafte Regel.

> Betriebs-/Homelab-spezifische Entscheidungen (IPs, Secret-Manager-Layout, VM-Matrix)
> stehen **nicht hier**, sondern im privaten Provisioning-Repo. Diese Datei bleibt
> generisch, damit sie im öffentlichen Repo keine internen Details preisgibt.

## 2026-07-16 · `clear` bricht non-interaktive Skript-Läufe unter `set -e` ab

**Symptom:** Ein Skript, das interaktiv einwandfrei läuft, bricht bei Aufruf ohne
TTY (über SSH mit Heredoc/Pipe, aus einem anderen Skript, per Cron) sofort mit
`clear: ... TERM environment variable not set.` ab — noch bevor die eigentliche
Arbeit beginnt.

**Ursache:** `clear` (ncurses) beendet sich ohne gesetztes `TERM` mit Exit-Code 1.
Unter `set -euo pipefail` reißt dieser Exit-Code das ganze Skript mit. Bei einem
Cron- oder Backup-Skript heißt das: es läuft *nie*, und zwar lautlos.

**Fix:** Nie nacktes `clear`. Immer:

```bash
clear 2>/dev/null || true
```

**Regel:** Jedes neue Skript, das `clear` (oder einen anderen TTY-abhängigen Befehl)
nutzt, MUSS ihn so absichern. Dieser Fix war ursprünglich nur in `setup-db.sh`,
`setup-web.sh`, `install-wp.sh` — die Klasse blieb in 16 weiteren Skripten offen und
wurde am 2026-07-16 repo-weit geschlossen. Lehre zusätzlich: **einen erkannten Fix
sofort auf alle betroffenen Stellen anwenden, nicht nur dort, wo er gerade weh tut.**

## 2026-07-16 · Host-Key-Kollision nach VM-Neubau (`known_hosts`)

**Symptom:** Nach dem Löschen und Neu-Klonen einer VM auf derselben IP schlägt SSH
mit `REMOTE HOST IDENTIFICATION HAS CHANGED` fehl (oder `accept-new` verweigert
stumm), obwohl der Login-Key korrekt ist.

**Ursache:** Die neue VM hat einen neuen Host-Key, die IP steht aber noch mit dem
alten Key in `~/.ssh/known_hosts`.

**Regel:** Nach jedem VM-Neubau die betroffenen IPs aus `known_hosts` entfernen,
bevor man sich verbindet:

```bash
ssh-keygen -R <ip>
```

## 2026-07-16 · Verify-Schleifen dürfen bei Misserfolg nicht `exit 0` liefern

**Symptom:** Eine Warte-/Prüf-Schleife („bis SSH erreichbar", „bis Dienst up")
meldet Erfolg, obwohl die Prüfung nie zutraf.

**Ursache:** `for i in $(seq …); do <check> && break; sleep N; done` endet, wenn alle
Versuche scheitern, mit dem Exit-Code des letzten `sleep` (= 0). Ein leeres Ergebnis
plus Exit 0 wird fälschlich als „bestanden" gelesen.

**Regel:** Erfolg an einem **expliziten Marker** festmachen, nicht am Schleifen-Exit:

```bash
ok=0
for i in $(seq 1 N); do
  if <check>; then ok=1; break; fi
  sleep N
done
[ "$ok" = 1 ] || { echo "FAILED"; exit 1; }
```

## 2026-07-16 · Generierte Credentials sofort sichern, nie als Klartext zwischenlagern

**Symptom:** Setup-Skripte erzeugen Passwörter (cloud-init, DB, WP-Admin). Wenn man
sie „für später" in einer Textdatei sammelt, entsteht ein unverschlüsselter
Secret-Speicher auf der Platte.

**Regel:** Ein generiertes Secret in dem Moment, in dem es entsteht, in den
Secret-Manager schreiben. Keine Klartext-Sammeldatei als Zwischenschritt.

## 2026-07-16 · Gleiche Funktion, zwei Implementierungen: age-Verschlüsselung

**Symptom:** `setup-db.sh` und `setup-web.sh` verschlüsselten Backups beide mit age,
aber unterschiedlich: `setup-db` nahm einen Public-Key (`AGE_RECIPIENT`) aus der Config
(kein Secret auf der Maschine), `setup-web` erzeugte pro VM ein eigenes Keypair und
legte den Secret-Key auf der (potenziell exponierten) Web-VM ab.

**Warum das ein Problem ist:** (1) Sicherheit — ein Secret-Key, der Backups
entschlüsselt, gehört nicht auf die Maschine, deren Backups er schützt. (2) Betrieb —
N VM-Keypairs statt eines Stack-Keys sind mehr Schlüssel-Verwaltung. (3) Inkonsistenz —
zwei Wege für dieselbe Sache laden zu Fehlern ein.

**Fix:** `setup-web.sh` akzeptiert jetzt `AGE_RECIPIENT` (Public-Key) wie `setup-db.sh`;
ist er gesetzt, wird nur der Public-Key hinterlegt und kein Secret erzeugt. Das lokale
Keypair bleibt als Fallback, wenn kein Recipient angegeben ist.

**Regel:** Dieselbe Funktion in mehreren Skripten IMMER gleich implementieren.
Secret-Material nie auf der Maschine ablegen, die es schützen soll.

## 2026-07-16 · Harter Reboot einer frischen cloud-init-VM zerstört dpkg-Transaktionen

**Symptom:** Nach einem `qm stop`/`start` (harter Reboot) kurz nach dem ersten Boot
bricht ein Setup-Skript mit `E: dpkg was interrupted, you must manually run
'dpkg --configure -a'` ab (apt EXIT 100). `dpkg --audit` meldet eine korrupte Datei
unter `/var/lib/dpkg/updates/` („end of file after field name").

**Ursache:** Frische cloud-init-VMs fahren beim ersten Boot `unattended-upgrades`/
`apt-daily`. Ein harter Stop mitten in einer dpkg-Transaktion hinterlässt ein
korruptes Transaktionsjournal. (Aufgetreten beim RAM-Reboot direkt nach VM-Erstellung —
timing-abhängig: nur die VM, deren dpkg-Commit gerade lief, war betroffen.)

**Zwei Fixes (beide umgesetzt):**
1. **Specs vor dem ersten Boot setzen** → kein nachträglicher harter Reboot.
   `proxmox-create-vm.sh` nimmt jetzt einen RAM-Override entgegen, sodass die VM
   gleich mit dem Zielwert startet.
2. **Setup-Skripte robust machen:** vor apt `dpkg --configure -a` (heilt ein
   unterbrochenes dpkg) und apt-Aufrufe mit `-o DPkg::Lock::Timeout=300` (wartet auf
   ein noch laufendes unattended-upgrades statt am Lock zu scheitern).

**Regel:** Frische cloud-init-VMs nicht hart neu starten, solange cloud-init/
unattended-upgrades laufen können — Specs vor dem Boot festlegen. Jedes Skript, das
apt nutzt, heilt dpkg und wartet auf den Lock.

## 2026-07-16 · Request-abfangende Drop-ins/mu-Plugins müssen CLI + Cron ausnehmen

**Symptom:** Nach `install-wp` gibt jeder wp-cli-Aufruf auf der Site die HTML-
Wartungsseite zurück statt eines Ergebnisses (`wp plugin list` → `<!DOCTYPE html>`).
Damit sind alle wp-cli-basierten Wartungsskripte (update-wp, db-cleanup, health-check,
rotate-keys, reset-wp-admin) auf einer Site im Maintenance-Mode unbrauchbar.

**Ursache:** Das `maintenance-mode.php`-mu-Plugin fing den Request ab (Flag gesetzt),
prüfte aber nur wp-login + Login-Cookie — nicht den **CLI-/Cron-Kontext**. Da eine
frische Site nach install *immer* im Maintenance-Mode steht, traf das jeden wp-cli-Lauf.

**Fix:** Ganz oben im mu-Plugin:
```php
if ( ( defined( 'WP_CLI' ) && WP_CLI ) || ( defined( 'DOING_CRON' ) && DOING_CRON ) ) {
    return;
}
```

**Regel:** Jedes Drop-in/mu-Plugin, das Requests abfängt oder umleitet (Maintenance,
Redirects, Auth-Gates), MUSS `WP_CLI` und `DOING_CRON` früh ausnehmen.

## 2026-07-16 · Plugin-Aktivierung, die plugins_api() aufruft, unter wp-cli trennen

**Symptom:** `wp plugin install <zip> --activate` bricht mit `PHP Fatal error:
Cannot redeclare plugins_api()` ab (das Plugin wird zwar aktiv, aber der Log ist
verschmutzt und ein `[✓]`-Log danach ist irreführend). Beobachtet bei PostX Pro
(`ultimate-post-pro`).

**Ursache:** wp-cli lädt für den `install`-Teil `wp-admin/includes/plugin-install.php`.
Der Aktivierungs-Hook des Plugins ruft `plugins_api()` auf und lädt dieselbe Datei per
`require` erneut → Doppel-Deklaration, im selben Prozess.

**Fix:** Install und Aktivierung in **getrennte** wp-cli-Aufrufe splitten
(`wp plugin install <zip>` ohne `--activate`, danach `wp plugin activate <slug>`). Im
reinen activate-Prozess ist `plugin-install.php` nicht vorgeladen.

**Regel:** Plugins, deren Aktivierungs-Hook `plugins_api()`/Update-APIs anfasst,
nie mit `install --activate` in einem Zug installieren — Schritte trennen.

**Nachtrag (Woo-Stack):** Die Klasse trifft mehrere lokale Pro-ZIPs (PostX →
`plugins_api()`, WowInvoice/WowStore → `Cannot declare class WP_Upgrader`). Statt
Einzelfixe ein Helper `install_local_zip()`, der `install` und `activate` immer trennt
und den **Slug aus dem ZIP-Top-Ordner** (`unzip -Z1 … | head -1`) statt aus fragilem
wp-cli-Output ermittelt. Alle lokalen ZIP-Installs laufen darüber.

**Sonderfall Versions-Inkompatibilität (FunnelKit):** Eine Pro-ZIP im Bucket, die nicht
zur aktuellen wp.org-Free-Basis passt, wirft nach Aktivierung bei *jedem* WP-Load einen
Fatal (`Class BWFAN_API_Loader not found`) und **vergiftet alle folgenden wp-cli-Aufrufe**
(Folgeschritte scheitern, Lauf bricht ab, Cleanup-Trap entfernt die Site). Solche Plugins
nur **installieren, nicht aktivieren** — Aktivierung manuell, sobald die ZIP-Version passt.

## 2026-07-16 · `userdel` ohne `groupdel` → verwaiste Gruppe blockiert `useradd` (Exit 9)

**Symptom:** Ein Re-Install (`--resume`) bricht mit EXIT 9 bei `useradd` ab — obwohl der
User zuvor per `if ! id "$USER"` geprüft wird.

**Ursache:** `useradd` legt User **+ gleichnamige Gruppe** an. Beim Cleanup entfernt
`userdel` nur den User, **nicht** die Gruppe (sie ist nicht leer — `www-data` wurde per
`usermod -aG` Mitglied). Beim Re-Install ist der User weg (`id` schlägt fehl → `useradd`
läuft), aber `useradd` will die **verwaiste gleichnamige Gruppe** neu anlegen →
„group already exists", Exit-Code 9.

**Fix:** (a) useradd robust: `groupadd -f "$USER"` + `useradd -g "$USER" …` (nutzt eine
vorhandene Gruppe statt neu anzulegen). (b) Cleanup ergänzt `groupdel` nach `userdel`.

**Regel:** Wer `userdel` macht, macht auch `groupdel` der gleichnamigen Gruppe. Wer
`useradd` mit Auto-Gruppe nutzt, muss mit einer vorhandenen gleichnamigen Gruppe umgehen.

## 2026-07-16 · `ls glob | …` in `$(...)` bricht bei leerem Match unter pipefail ab

**Symptom:** Ein Skript bricht **kommentarlos mit EXIT 2** ab (keine Fehlermeldung) —
z.B. `install-wp --type mainwp` direkt nach dem Start auf einer VM ohne Sites.

**Ursache:** `VAR=$(ls /pfad/*.ext 2>/dev/null | wc -l)` — matcht das Glob nichts,
gibt `ls` **exit 2**. `2>/dev/null` unterdrückt nur die Meldung, **nicht** den Exit-Code.
Unter `set -o pipefail` propagiert die Pipe die 2, `set -e` bricht ab. (Ironisch: der
Zähl-Check, der die *zweite* Site auf einer MainWP-VM verhindern sollte, crashte bei der
*ersten* — leeres Verzeichnis.) Trügerisch: die Stellen in `setup-web` crashten nicht,
weil dort tatsächlich .zip-Dateien lagen (Glob matchte) — der Bug schläft, bis das Glob leer ist.

**Fix:** `|| true` anhängen (Exit-Code egal, nur die wc-Zahl zählt) — konsistent mit dem
bereits in `status.sh` verwendeten Muster. Betraf `install-wp`, `sync-plugins`, `setup-web` (2×).

**Regel:** Jede `$(ls glob … | …)`-Zählung in einer command-substitution unter pipefail
mit `|| true` absichern (oder bash-nativ mit `nullglob`).

**Variante SIGPIPE (Exit 141):** Dieselbe Klasse trifft `$(langer_befehl | head …)` —
`head` schließt die Pipe nach seinen Zeilen/Bytes, der noch schreibende linke Befehl
(`unzip -Z1`, `zcat` einer großen Datei, `find` mit vielen Treffern) bekommt **SIGPIPE**,
was unter `set -o pipefail` als **Exit 141** (128+13) durchschlägt und `set -e` abbrechen
lässt. Ironischerweise im `install_local_zip`-Helper selbst reproduziert (`unzip -Z1 | head -1`).
Fix: `|| true` an die command-substitution. Betroffen abgesichert: `install-wp` (unzip),
`backup-verify` (zcat), `restore-wp` (find). Stellen mit garantiert kurzer linker Ausgabe
(`rclone --version`, `dig`, `df` → `head/tail`) sind praktisch unkritisch und bewusst gelassen.
