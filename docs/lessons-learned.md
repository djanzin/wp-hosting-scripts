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
