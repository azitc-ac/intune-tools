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
| Belegt am | 2026-09-25 |
| Vom Tool selbst gemeldet | `$toolVersion = "2.0"` in `start-IntuneWin32Helper.ps1` |

Zurückkehren:

```powershell
git fetch origin --tags
git checkout IntuneWin32Helper-v2.0.0
```

Der **Tag** ist der verbindliche Rückweg: unveränderlich, zeigt auf `dd47702`.
Seine Message ist nur eine Zeile — was den Stand ausmacht, steht hier.

Den gleichnamigen Zweitzeiger-Branch `release/IntuneWin32Helper-v2.0.0` gibt es
nicht mehr (gelöscht am 2026-09-28; er zeigte auf denselben Commit, `git rev-list
--count Tag..Branch` war 0). Der Tag ist der einzige Rückweg — auf einen Branch
kann versehentlich gepusht werden, auf einen Tag nicht.

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

> **Feldlauf 2026-09-28 („Lauf 2")** — Windows 11 Cloud PC (de-DE), PowerShell
> 5.1.26100.9444, IntuneWin32App 1.5.0, Stand `5566a02` (IntuneWin32Helper 2.0.7),
> **Test-Tenant** `3jr2s6t19s.onmicrosoft.com`. Transcript
> `IntuneWin32Helper\Logs\2026-09-28_11-32-29.log` (lokal auf dem Cloud PC, `Logs/`
> ist nicht versioniert). Gefahren wurde das echte `createApps -createAndDeploy`;
> ersetzt waren nur die Klickstellen (Auswahl- und Tenant-Dialog, `pause`, Explorer,
> Editor) und `packetRoot` → `C:\IntuneFeldtest`. Vier Apps, `-bulk`.
> „Graph" heißt unten: `GET /beta/deviceAppManagement/mobileApps/{id}` im Test-Tenant
> direkt danach — die Daten, aus denen das Portal liest; ein Blick ins Portal selbst
> steht aus.
>
> Vor Lauf 2 scheiterte Lauf 1 (Transcript `…\2026-09-28_11-27-14.log`) an **jeder**
> App: `check-prereqs` hatte IntuneWin32App **1.5.0** installiert, das unter de-DE das
> Token-Ablaufdatum nicht parsen kann — behoben in `5566a02`. Und beim Lesen des
> Moduls fiel auf, dass sieben Fehlerpfade per `break` den Upload-Guard umgingen —
> behoben in `883b915`.

- [x] **Fehlgeschlagener Upload bricht ab** statt „Finished." zu melden
      (`Templates/deploy_template.ps1`, Guard am Ende). Beleg: ein Lauf mit absichtlich
      unbrauchbarer Quelle endet mit `throw`, und das Protokoll zeigt den Hinweis auf
      den möglichen inhaltslosen App-Eintrag. Das war der GIMP-Fall.
      **Beleg (Lauf 2):** Für „IW32H-Feldtest Upload-Abbruch" wurde im Testskript der
      Blob-Upload unterdrückt (Inhalt kommt nie im Azure-Speicher an, wie beim 403 von
      GIMP). Transcript Z. 85 „Successfully created Win32 app with ID: 13aa657e-…",
      Z. 103/104 „CommitFile failed", Z. 105 `throw` „Upload to Intune FAILED … An app
      entry may exist in Intune without content and should be removed.", Z. 106
      „FAILED: …". Der Stapel lief weiter; Z. 385–390 „Deployment summary: 3 succeeded,
      1 failed." mit Hinweis auf inhaltslose Einträge. Graph: `13aa657e-…` hat
      `uploadState=0`, `publishingState=notPublished`, `committedContentVersion=''` —
      genau der inhaltslose Eintrag. Nicht im Feld provoziert: die `break`-Pfade des
      Moduls (Token fehlt, Body abgelehnt); belegt nur durch
      `Tests/Test-ModuleCallNoBreak.ps1`.
- [ ] **WinGet-Erkennung prüft die Version** (`Templates/detection_template-WinGetApp.ps1`,
      `& $wingetPath upgrade --id … --exact`). Beleg: auf einem Client mit *veralteter*
      WinGet-App liefert das Skript Exit 1, mit *aktueller* Exit 0. Nachlesbar im Log
      `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\<PackageID>_Detect.log`.
- [ ] **Native MSI-Erkennungsregel** (`New-IntuneWin32AppDetectionRuleMSI` mit
      `ProductCode` und `greaterThanOrEqual`). Beleg: Intune nimmt die Regel an, das
      Portal zeigt sie als MSI-Regel statt als Skript, und ein Client erkennt korrekt.
      **Zwischenstand (Lauf 2) — offen, weil der Client-Teil fehlt:** Intune nimmt die
      Regel an. Transcript Z. 335 „Detection rule: native MSI product code
      [{23170F69-40C1-2702-2409-000001000000}], version >= [24.09.00.0]", Z. 346 App
      `1207f7e5-…` angelegt. Graph: `win32LobAppProductCodeDetection`,
      `greaterThanOrEqual 24.09.00.0` (die Skript-Apps desselben Laufs:
      `win32LobAppPowerShellScriptDetection`). Ein Client hat noch nicht erkannt.
- [x] **Requirement Rule pro App** aus den neuen `Apps.csv`-Spalten `Architecture`
      und `MinimumOS`. Beleg: eine App bewusst abweichend setzen, das Portal zeigt die
      abweichenden Werte.
      **Beleg (Lauf 2), Graph:** „Logo PNG" (x64/W11_22H2) →
      `allowedArchitectures=x64`, `minimumSupportedWindowsRelease=Windows11_22H2`;
      „Logo JPG" (arm64/W10_22H2) → `arm64`, `Windows10_22H2`; „MSI" (Spalten leer) →
      `x64`, `2H20` (= W10_20H2). Hinweis: IntuneWin32App 1.5.0 schreibt die
      Architektur nach `allowedArchitectures` und setzt `applicableArchitectures`
      absichtlich auf `none` (Modul, `New-IntuneWin32AppRequirementRule.ps1` Z. 107–110)
      — wer nur `applicableArchitectures` liest, sieht fälschlich „none".
- [x] **Logo landet immer im Paket** (`Resolve-PackageLogo`, `Resize-IconFile`). Wichtig,
      weil der Kopier-Fallback unter Windows noch nie gelaufen ist. Beleg: Paketbau mit
      einer `.png`- **und** einer `.jpg`-URL, in beiden Fällen liegt eine Bilddatei im
      Paket und das Icon erscheint im Portal.
      **Beleg (Lauf 2):** Z. 126/127 „Trying logo download (.png)… Icon normalised to
      256x256.", Z. 213/214 dasselbe für `.jpg`; ohne URL Z. 55/56 und 307/308 „No logo
      URL specified. Taking default logo." (Kopieren, dann Normalisieren). Im Paket:
      `IW32H-Feldtest Logo PNG.png` 34907 B, `… Logo JPG.png` 49487 B, Standardlogo
      133422 B — alle 256×256. Graph `largeIcon` (image/png) je App byte-gleich groß:
      34907 / 49487 / 133422. Nebenwirkung, gewollt: heruntergeladene Logos werden nach
      `Logos\` übernommen — ein zweiter Lauf nimmt dann das vorhandene Logo.
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
- [x] **Pfadlängen-Warnung** (`Measure-PackageContentPath`). Beleg: eine tief
      verschachtelte Quelle löst die Warnung aus.
      **Beleg (Lauf 2):** Paket „MSI" mit einer Datei 204 Zeichen unter `in\`. Z. 324–326
      „Longest client-side path: 261 of 259 characters (assuming a 57-character IMECache
      prefix). 1 file(s) exceed the limit. … 261 chars Files\E1-…\lange-datei-ft.txt".
      Die übrigen Pakete: „152 of 259", keine Warnung. Der Upload lief trotzdem (nur
      Warnung, kein Abbruch — so gewollt).
- [x] **Löschschutz** (`Remove-PackageFolder`). Beleg: ein Paket über die UI löschen —
      nur der Paketordner verschwindet, das Paket-Wurzelverzeichnis bleibt.
      **Beleg (Lauf 2):** Einen UI-Weg zum Löschen eines *Pakets* gibt es nicht — der
      „Delete"-Knopf im Auswahldialog entfernt Zeilen aus `Apps.csv`;
      `Remove-PackageFolder` hat genau einen Aufrufer, `createApps` bei
      `removeExistingPacketDirOnEachRun = true`. Dieser Weg lief viermal: Z. 37, 108,
      195, 292 „Removing existing package folder: C:\IntuneFeldtest\IW32H-Feldtest …";
      danach existiert `C:\IntuneFeldtest` weiter, die vier Ordner wurden neu angelegt.
      Die Verweigerungszweige (leerer Pfad, Wurzel, außerhalb) sind nicht im Feld
      ausgelöst worden.

**Offene Punkte ohne Feldbezug**

- [ ] `ServiceUI.exe` ist ein Microsoft-Binary. Weiterverbreitungsrecht ist **nicht**
      geklärt, nur dokumentiert (`IntuneWin32Helper/THIRD-PARTY-NOTICES.md`).
- [ ] Supersedence — bewusst zurückgestellt.
- [ ] Aktionen direkt aus der Inventarzeile (anlegen / erneuern / entfernen). Am
      nützlichsten wäre „entfernen": ein Geister-Eintrag ließe sich aus dem Inventar
      löschen statt im Portal.
- [x] Der Zeiger-Branch `release/IntuneWin32Helper-v2.0.0` kann weg, der Tag hält den
      Commit. Cloud-Sessions dürfen keine Refs löschen.
      **Beleg (2026-09-28):** vorher Tag und Branch beide auf
      `dd4770225c9644f2fe9eee66d5dd2802a58d4d23`, `git rev-list --count
      IntuneWin32Helper-v2.0.0..origin/release/IntuneWin32Helper-v2.0.0` = 0.
      `git push origin --delete release/IntuneWin32Helper-v2.0.0` → „[deleted]";
      danach `git branch -r` nur noch `origin/main`, `git ls-remote --tags`
      zeigt den Tag weiterhin.

Sobald ein Lauf auf `main` gegen einen echten Tenant durch ist, gehört ein neuer
Abschnitt nach oben in diese Datei — mit Commit, Tag und Transcript-Datum.
