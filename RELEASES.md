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
| Tag | `IntuneWin32Helper-v2.0.0` |
| Branch (Zweitzeiger) | `release/IntuneWin32Helper-v2.0.0` |
| Belegt am | 2026-09-25 |
| Vom Tool selbst gemeldet | `$toolVersion = "2.0"` in `start-IntuneWin32Helper.ps1` |

Zurückkehren:

```powershell
git fetch origin --tags
git checkout IntuneWin32Helper-v2.0.0
```

Der **Tag** ist der verbindliche Rückweg: unveränderlich, zeigt auf `dd47702`.
Seine Message ist nur eine Zeile — was den Stand ausmacht, steht hier.

Der gleichnamige **Branch** zeigt auf denselben Commit und existiert nur als
Zweitzeiger. Er wird nicht weiterentwickelt und ist **nicht** nach `main` zu
mergen — das würde die gesamte Entwicklung danach zurückdrehen. Wer
sichergehen will, nimmt den Tag: auf einen Branch kann versehentlich gepusht
werden, auf einen Tag nicht.

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

---

## Offene Feldprüfung für `main`

Was seit `dd47702` dazugekommen ist, ist gegen Parser, AST und Logiktests geprüft —
aber **nie auf einer Windows-Maschine gegen einen echten Tenant gelaufen**. Diese Liste
ist der Weg von „strukturell grün" zu „im Feld belegt". Jeder Punkt nennt, was ihn
belegt; abgehakt wird er erst mit diesem Beleg, nicht mit einer Vermutung.

**Schritt 0 — zuerst, weil alles andere daran hängt**

- [x] Läuft `IntuneWin32Helper/Tests/Invoke-RepoChecks.ps1` überhaupt unter **Windows
      PowerShell 5.1**? Bisher lief es ausschließlich unter `pwsh` 7.4.6 in einer
      Linux-Cloud-Session. Beleg: `powershell.exe -NoProfile -File …` endet mit
      „Alle Pruefungen bestanden." und Exit 0.

      **Beleg (2026-09-28, Windows 11 Cloud PC, PowerShell 5.1.26100.9444):**
      Auf `84af612` lief es **nicht** — Abbruch vor der ersten Prüfung mit
      „Split-Path : Das Argument kann nicht an den Parameter "Path" gebunden werden,
      da es sich um eine leere Zeichenfolge handelt." (`Invoke-RepoChecks.ps1:18`).
      Ursache: `$PSScriptRoot` ist unter 5.1 im `param()`-Default leer, wenn das
      Skript per `-File` startet — genau so ruft es der pre-commit-Hook auf. Unter
      Windows war damit **jeder** Commit an `IntuneWin32Helper/` blockiert. Mit
      `& .\…ps1` lief es auch vorher (105 Prüfungen, Exit 0).
      Behoben (Default im Rumpf setzen) plus Prüfung 25 `NoAutoPathInParamDefault`.
      Danach: `powershell.exe -NoProfile -File IntuneWin32Helper\Tests\Invoke-RepoChecks.ps1`
      → „Dateien: 6   Pruefungen: 111 / Alle Pruefungen bestanden.", Exit 0.
      Gegenprobe gefahren: Default zurückgebaut → `-File` bricht wie oben ab (Exit 1),
      per `&` meldet Prüfung 25 „Invoke-RepoChecks.ps1:18 Default von $RepoRoot
      benutzt $PSScriptRoot" (Exit 1); Rückbau bytegleich, wieder grün.

      Beifund beim selben Lauf: `GroupAppAssignment/Test-GroupAppAssignment.ps1` unter
      5.1 „381 passed, 2 failed" („load with $expand: one call", „write Replace: one
      fresh read, one POST, no DELETE") — ein einzelnes `PSCustomObject` hat unter 5.1
      kein `.Count`, der Mock-Zähler `Get-Calls` lieferte `$null`. Nur der Test war
      betroffen; im Tool selbst sind alle 31 `.Count` ohne `@()` Arrays, Listen,
      Hashtables oder `,$ops.ToArray()` (AST-Suchlauf). Behoben mit `@(Get-Calls …)`.
      Danach „383 passed, 0 failed", Exit 0; Gegenprobe mit dem Stand von `84af612`
      wieder „381 passed, 2 failed", Exit 1.

**Die Korrekturen, die noch keinen Feldbeleg haben**

- [ ] **Fehlgeschlagener Upload bricht ab** statt „Finished." zu melden
      (`Templates/deploy_template.ps1`, Guard am Ende). Beleg: ein Lauf mit absichtlich
      unbrauchbarer Quelle endet mit `throw`, und das Protokoll zeigt den Hinweis auf
      den möglichen inhaltslosen App-Eintrag. Das war der GIMP-Fall.
- [ ] **WinGet-Erkennung prüft die Version** (`Templates/detection_template-WinGetApp.ps1`,
      `& $wingetPath upgrade --id … --exact`). Beleg: auf einem Client mit *veralteter*
      WinGet-App liefert das Skript Exit 1, mit *aktueller* Exit 0. Nachlesbar im Log
      `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\<PackageID>_Detect.log`.
- [ ] **Native MSI-Erkennungsregel** (`New-IntuneWin32AppDetectionRuleMSI` mit
      `ProductCode` und `greaterThanOrEqual`). Beleg: Intune nimmt die Regel an, das
      Portal zeigt sie als MSI-Regel statt als Skript, und ein Client erkennt korrekt.
- [ ] **Requirement Rule pro App** aus den neuen `Apps.csv`-Spalten `Architecture`
      und `MinimumOS`. Beleg: eine App bewusst abweichend setzen, das Portal zeigt die
      abweichenden Werte.
- [ ] **Logo landet immer im Paket** (`Resolve-PackageLogo`, `Resize-IconFile`). Wichtig,
      weil der Kopier-Fallback unter Windows noch nie gelaufen ist. Beleg: Paketbau mit
      einer `.png`- **und** einer `.jpg`-URL, in beiden Fällen liegt eine Bilddatei im
      Paket und das Icon erscheint im Portal.
- [ ] **Abgeleitete Installationsbefehle** (`Get-InstallerEngine`,
      `Get-DerivedInstallCommands`). Beleg: je ein Inno-, ein NSIS- und ein
      wixburn-Setup — erkannte Engine stimmt, und der vorgeschlagene Silent-Switch
      installiert wirklich ohne Interaktion.
- [ ] **Inventar** (`Get-AppInventory` über `Get-IntuneWin32App`). Beleg: der Dialog
      erscheint, die Spalte `Intune` stimmt gegen das Portal — und wie lange der Abruf
      beim echten App-Bestand dauert, gehört notiert. Das ist die einzige Neuerung, die
      bei jedem Start Zeit kostet.
- [ ] **Vorlagen-Fingerprint** (`Get-TemplateFingerprint`,
      `Get-PackageTemplateFingerprint`). Beleg: ein altes Paket wird in der Spalte
      `Template` als veraltet geführt, `Update-DeployScript` zieht es nach und legt
      `deploy.ps1.bak` an; im erzeugten `deploy.ps1` steht ein echter Hash und nicht
      mehr der Platzhalter `#TPLFP#`.
- [ ] **Pfadlängen-Warnung** (`Measure-PackageContentPath`). Beleg: eine tief
      verschachtelte Quelle löst die Warnung aus.
- [ ] **Löschschutz** (`Remove-PackageFolder`). Beleg: ein Paket über die UI löschen —
      nur der Paketordner verschwindet, das Paket-Wurzelverzeichnis bleibt.

**Offene Punkte ohne Feldbezug**

- [ ] `ServiceUI.exe` ist ein Microsoft-Binary. Weiterverbreitungsrecht ist **nicht**
      geklärt, nur dokumentiert (`IntuneWin32Helper/THIRD-PARTY-NOTICES.md`).
- [ ] Supersedence — bewusst zurückgestellt.
- [ ] Aktionen direkt aus der Inventarzeile (anlegen / erneuern / entfernen). Am
      nützlichsten wäre „entfernen": ein Geister-Eintrag ließe sich aus dem Inventar
      löschen statt im Portal.
- [ ] Der Zeiger-Branch `release/IntuneWin32Helper-v2.0.0` kann weg, der Tag hält den
      Commit. Cloud-Sessions dürfen keine Refs löschen.

Sobald ein Lauf auf `main` gegen einen echten Tenant durch ist, gehört ein neuer
Abschnitt nach oben in diese Datei — mit Commit, Tag und Transcript-Datum.
