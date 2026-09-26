# Rückkehrpunkte

Stände, die nachweislich gegen einen echten Tenant gelaufen sind. Wenn die
Weiterentwicklung etwas bricht, ist das hier der Weg zurück.

Ein Rückkehrpunkt kommt erst dann in diese Liste, wenn ein Lauf gegen einen
echten Tenant belegt ist (Transcript). „Die Prüfskripte sind grün" genügt
nicht — das belegt nur, dass das Skript parst und die Struktur stimmt, nicht
dass Intune den Aufruf annimmt.

---

## IntuneWin32Helper 2.0.0 — im Feld gelaufener Stand

| | |
|---|---|
| Commit | `dd47702` |
| Branch | `release/IntuneWin32Helper-v2.0.0` |
| Belegt am | 2026-09-25 |
| Vom Tool selbst gemeldet | `$toolVersion = "2.0"` in `start-IntuneWin32Helper.ps1` |

Zurückkehren:

```powershell
git fetch origin release/IntuneWin32Helper-v2.0.0
git checkout release/IntuneWin32Helper-v2.0.0
```

Der Branch ist ein reiner Zeiger auf `dd47702` und wird nicht weiterentwickelt.
Er ist **nicht** nach `main` zu mergen — das würde die gesamte Entwicklung
danach zurückdrehen.

In diesem Stand gibt es noch **keine** `VERSION`-Datei — die pro-Tool-Version
kam erst mit dem pre-commit-Hook danach. Die Zahl 2.0.0 folgt dem, was das Tool
damals selbst meldete.

### Beleg

Transcript-Lauf vom 2026-09-25, 14:26:45 Ortszeit (12:26:45 UTC), Windows
PowerShell 5.1.26100.9457, drei Apps im Bulk-Lauf (IrfanView, Greenshot, GIMP).
`dd47702` ist der letzte Commit vor dem Lauf, der das Tool berührt; der nächste
folgte erst 12:49 UTC. Am Inhalt gegen das Transcript geprüft, nicht nur am
Zeitstempel:

| Erwartung an `dd47702` | Beleg im Transcript |
|---|---|
| `Update-DeployScript` vorhanden | „Updating outdated deploy.ps1" |
| keine `$uploadResult`-Prüfung | „Finished." trotz Fehlschlag bei GIMP |
| `Initialize-IntuneConnection` vorhanden | Tenant-Dialog genau einmal (Zeile 24) |
| `[int]]`-Syntaxfehler behoben | Skript läuft überhaupt |

### Was in diesem Stand nachweislich funktioniert

- Der Tenant-Dialog erscheint genau **einmal pro Lauf**, nicht pro App. App 2
  und 3 melden „Access token still valid".
- `Update-DeployScript` zieht bestehende `deploy.ps1` aus der aktuellen Vorlage
  nach und sichert die alte als `deploy.ps1.bak`. Im Lauf für alle drei Apps
  geschehen.
- Paketbau und Upload nach Intune für IrfanView und Greenshot.

### Bekannte Mängel dieses Stands

Er ist „bekanntermaßen gelaufen", nicht „fehlerfrei". Wer hierher zurückkehrt,
holt sich diese Fehler bewusst mit zurück:

- **Ein fehlgeschlagener Upload meldet trotzdem „Finished."** Bei GIMP
  scheiterte der Upload (Azure: 403 „SAS identifier cannot be found"), das
  Skript lief weiter und die App blieb ohne Inhalt in Intune liegen. In einem
  größeren Stapel fällt das niemandem auf.
- **Die WinGet-Erkennung ist versionsblind.** `winget list --id X` meldet die
  App, sobald die ID vorhanden ist. Eine veraltete Fassung gilt als aktuell und
  wird nie erneuert.
- **Logo-URLs ohne `.png`-Endung gehen in einen Upload zu Cloudinary.** Mit
  leeren Zugangsdaten — wie in der Beispielkonfiguration — bricht der Paketbau
  dabei ab.
- Jede App bekommt dieselbe Requirement Rule (x64 / W10_20H2).
- Erkennung immer per Skript, auch bei MSI mit vorliegendem ProductCode.
- Kein Inventar: nicht erkennbar, welche Definition kein Paket hat, welches
  Paket nicht veröffentlicht ist oder wo eine App doppelt in Intune liegt.

Alles davon ist auf `main` behoben — dort aber noch **nicht gegen echte
Hardware geprüft**, nur gegen Parser, AST und Logiktests. Sobald ein Lauf auf
`main` gegen einen echten Tenant erfolgreich war, gehört der neue
Rückkehrpunkt hierher und dieser Abschnitt wird zur Historie.
