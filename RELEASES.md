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
- [x] **WinGet-Erkennung prüft die Version** (`Templates/detection_template-WinGetApp.ps1`,
      `& $wingetPath upgrade --id … --exact`). Beleg: auf einem Client mit *veralteter*
      WinGet-App liefert das Skript Exit 1, mit *aktueller* Exit 0. Nachlesbar im Log
      `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\<PackageID>_Detect.log`.
      **Vorher gefunden und behoben (`1df2a30`):** seit `c6eb0eb` stand dort
      `if ($wingetPrg_Existing -notlike …)` — auf dem Zeilen-Array von winget ist das
      für eine *installierte* App wahr; sie galt als „NOT found", die Versionsprüfung
      wurde nie erreicht. Test `Tests/Test-WinGetDetection.ps1`, Prüfung 27.
      **Beleg (Client, PROD `zarenko.onmicrosoft.com`, 2026-09-28, Stand `1df2a30`):**
      App „IW32H-Feldtest WinGet Everything" (`voidtools.Everything`) auf dem Cloud PC
      CPC-alexa-LAP19, installiert war Everything 1.4.1.1026.
      `voidtools.Everything_Detect.log`: 12:26:49 „App voidtools.Everything found.",
      12:26:55 „An upgrade is available … reporting as NOT installed" (**Exit 1**);
      nach dem Upgrade durch winget 12:27:03 „found.", 12:27:04 „No upgrade available -
      voidtools.Everything is current." (**Exit 0**). `AppWorkload.log`: NotDetected →
      Detected. Programmliste danach: „Everything 1.4.1.1032 (x64)". winget für SYSTEM:
      `Microsoft.DesktopAppInstaller_1.28.239.0`.
- [x] **Native MSI-Erkennungsregel** (`New-IntuneWin32AppDetectionRuleMSI` mit
      `ProductCode` und `greaterThanOrEqual`). Beleg: Intune nimmt die Regel an, das
      Portal zeigt sie als MSI-Regel statt als Skript, und ein Client erkennt korrekt.
      **Beleg:** Intune nimmt die Regel an (Lauf 2, Test-Tenant: Transcript Z. 335,
      Graph `win32LobAppProductCodeDetection`, `greaterThanOrEqual 24.09.00.0`; die
      Skript-Apps desselben Laufs: `win32LobAppPowerShellScriptDetection`). Client
      (PROD, App `e739d7af-…` „IW32H-Feldtest 7-Zip MSI"): PSADT 14:15:17
      `msiexec.exe /i … 7z2409-x64.msi … /QN`, Exit 0; `AppWorkload.log` 12:15:34 UTC
      „DetectionState NotInstalled → Installed", „detection state: Detected"; in der
      Programmliste „7-Zip 24.09 (x64 edition) 24.09.00.0". Ins Portal selbst hat noch
      niemand geschaut — die Regel ist über Graph belegt.
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
- [x] **Abgeleitete Installationsbefehle** (`Get-InstallerEngine`,
      `Get-DerivedInstallCommands`). Beleg: je ein Inno-, ein NSIS- und ein
      wixburn-Setup — erkannte Engine stimmt, und der vorgeschlagene Silent-Switch
      installiert wirklich ohne Interaktion.
      **Zwischenstand (2026-09-28) — offen, weil die Installation auf einem Client
      fehlt:** `Get-InstallerEngine` auf echten, gültig signierten Installern:
      `Greenshot-INSTALLER-1.3.315-RELEASE.exe` → `inno`
      (`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`), `npp.8.9.8.1.Installer.x64.exe` →
      `nsis` (`/S`), `vc_redist.x64.exe` (aka.ms/vs/17) → `burn` (`/quiet /norestart`).
      Dazu im Feldlauf 2 das MSI (7-Zip 24.09) → `msi`, Transcript Z. 311–313.
      **Client (PROD, Cloud PC, 2026-09-28), PSADT-Logs unter
      `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\Feldtest_IW32H-*_Install.log`,
      alle „Installation is running in [Silent] mode":**
      - **NSIS — belegt:** Everything 1.4.1.1026, `… /S`, Exit 0 nach 1,7 s; Intune
        „Detected"; Programmliste „Everything 1.4.1.1026 (x64)".
      - **burn — belegt:** VC++ 2013 x64 12.0.40664, `vcredist_x64_2013.exe /quiet
        /norestart`, Exit 0 nach 19 s; Intune „Detected"; Programmliste
        „Microsoft Visual C++ 2013 Redistributable (x64) - 12.0.40664". (Der erste
        Versuch mit VC++ 2015–2022 endete still mit 1638 „andere Version installiert" —
        auf dem PC lag schon 14.50 unter dem neuen Namen „… v14 Redistributable".)
      - **Inno — offen:** Greenshot 1.3.315, `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`,
        Exit 0, Intune „Detected" — **aber ins Profil von SYSTEM installiert**
        (`HKU\S-1-5-18\…\Uninstall\Greenshot_is1`, `InstallLocation
        C:\Windows\system32\config\systemprofile\AppData\Local\Programs\Greenshot\`);
        der Benutzer hatte die App nicht. Die Erkennung durchsuchte HKCU (= die von
        SYSTEM) und verdeckte das. Behoben in `9ffd02d` (`/ALLUSERS`, Erkennung ohne
        HKCU, Prüfung 28). Mit `/ALLUSERS` zeigt das Inno-Protokoll
        (`…\Logs\IW32H-Greenshot-Inno.log`) „Administrative install mode: Yes",
        „Install mode root key: HKEY_LOCAL_MACHINE" — der Schalter wirkt. Die
        Installation brach aber ab: „Das Setup hat entdeckt, dass Greenshot zurzeit
        ausgeführt wird … Defaulting to Cancel" (Exit 1). Es lief die Instanz aus der
        ersten Fehlinstallation (siehe unten).
        **Nachgeholt — belegt (2026-09-29, nach Neustart, Stand `18215f0` / 2.0.10):**
        neue App `e4c2c43c-…` „IW32H-Feldtest Greenshot Inno HKLM" mit dem abgeleiteten
        Befehl. PSADT 11:21:46 `… /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /ALLUSERS`,
        Modus `[Silent]`, **Exit 0** nach 6 s; Programmliste
        `HKLM …\Uninstall\Greenshot_is1`, `InstallLocation=C:\Program Files\Greenshot\`;
        `AppWorkload.log` 09:22:08 UTC NotDetected → **Detected** (Erkennung nur noch
        über HKLM). Damit sind Inno, NSIS, burn und MSI auf einem Client belegt.
- [ ] **Inventar** (`Get-AppInventory` über `Get-IntuneWin32App`). Beleg: der Dialog
      erscheint, die Spalte `Intune` stimmt gegen das Portal — und wie lange der Abruf
      beim echten App-Bestand dauert, gehört notiert. Das ist die einzige Neuerung, die
      bei jedem Start Zeit kostet.
      **Zwischenstand — offen, weil den Dialog noch kein Mensch gesehen hat:**
      Mit den echten Funktionen (ohne Dialog), Transcripts `…\2026-09-28_11-42-26.log`
      (Test) und `…\2026-09-28_11-42-47.log` (PROD, nur lesend):
      Abrufdauer `Get-IntuneWin32App` — **PROD `zarenko.onmicrosoft.com`: 63 Win32-Apps
      in 17,7 s**; Test-Tenant: 16 in 3,7–4,1 s. `Get-AppInventory` selbst: 0,1 s.
      Spalte `Intune` gegen Graph: die drei veröffentlichten Test-Apps `yes`, eine
      Definition ohne Paket `create package`.
      **Dabei gefundener Fehler, behoben:** der inhaltslose Eintrag aus dem
      Upload-Abbruch stand als `yes` / `up to date` im Inventar — genau die
      „Geister-App", für die das Inventar gebaut wurde, blieb unsichtbar. Jetzt
      `no content` / „remove the entry without content in Intune"
      (`Test-IntuneAppHasContent`: `committedContentVersion` leer oder
      `publishingState` ≠ `published`; beides liefert die Liste schon mit). Im
      Test-Tenant gibt es zwei solche Einträge — unseren und einen älteren.
      Belegt durch `Tests/Test-InventoryAndRenewal.ps1`; Gegenprobe gefahren.
- [x] **Vorlagen-Fingerprint** (`Get-TemplateFingerprint`,
      `Get-PackageTemplateFingerprint`). Beleg: ein altes Paket wird in der Spalte
      `Template` als veraltet geführt, `Update-DeployScript` zieht es nach und legt
      `deploy.ps1.bak` an; im erzeugten `deploy.ps1` steht ein echter Hash und nicht
      mehr der Platzhalter `#TPLFP#`.
      **Im Feld zuerst gescheitert** (Transcript `…\2026-09-28_11-38-27.log`): zwei
      echte alte Pakete — gerendert aus den Vorlagen von `1b6e2f0` (Stempel
      `e55bbacf73f3`) und des Tags v2.0.0 (ohne Stempel). Das Inventar führte sie
      richtig als `outdated` / `unstamped`, aber `Update-DeployScript` lieferte für
      **beide** `False`, keine `.bak`, alter Stempel. Ursache: es erneuerte nur Skripte
      ohne `$Tenant` — das kennt schon die Vorlage von 2.0.0. Vorlagen-Korrekturen
      (etwa `Invoke-IntuneModuleCall`) hätten kein bestehendes Paket erreicht.
      Behoben: `Update-DeployScript` entscheidet jetzt nach demselben Stempel wie das
      Inventar; Test `Tests/Test-InventoryAndRenewal.ps1`, Gegenprobe gefahren.
      **Beleg danach** (`…\2026-09-28_11-42-26.log`): beide → `True`, `.bak` angelegt,
      Stempel `e55bbacf73f3` bzw. leer → `10f1ec2ad1dd` (= aktueller Stand), `#TPLFP#`
      nicht mehr im Skript, das erneuerte Skript nutzt `Invoke-IntuneModuleCall`;
      Architektur/MinimumOS (`x64`/`W11_22H2`) blieben erhalten.
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

**Im Feld gefunden, nicht behoben — Entscheidung beim Inhaber**

- [x] **ServiceUI startet den Installer als SYSTEM auf dem Benutzer-Desktop.**
      **Behoben in `1de65e5` (2.0.11):** Standard still und ohne ServiceUI, neue
      `Apps.csv`-Spalte `Interactive` für Pakete mit PSADT-Dialogen; Besitzer SYSTEM
      am 2026-09-29 von einer Admin-Sitzung bestätigt (PID 5388, Session 2, beendet).
      **Feldbeleg danach:** App `4cf12745-…` „IW32H-Feldtest Greenshot Standard"
      (Paket ohne `ServiceUI.exe`, `Install command: Invoke-AppDeployToolkit.exe
      -DeploymentType Install -DeployMode Silent`). PSADT 16:10:04 UTC „Session 0
      detected but deployment mode was explicitly set to [Silent]", Exit 0; Intune
      NotDetected → Detected; HKLM `C:\Program Files\Greenshot\`. Danach **kein**
      `Greenshot.exe`, weder in der Benutzersitzung 2 noch sonst. Die interaktive
      Variante ist noch nicht im Feld gelaufen.
      Befund vorher: Jeder
      Installationsbefehl lautet `ServiceUi.exe -Process:Explorer.exe
      Invoke-AppDeployToolkit.exe … -DeployMode Silent`. Greenshots Inno-Setup startet
      die App nach der Installation selbst — im Feld (2026-09-28, 14:14:41) lief danach
      `Greenshot.exe` (PID 12412) in der Sitzung des Benutzers (Session 2), dessen
      Besitzer der Benutzer nicht lesen durfte (`GetOwner` ReturnValue 2; bei
      `explorer.exe` desselben Benutzers 0) — mit großer Wahrscheinlichkeit SYSTEM. Ein
      SYSTEM-Prozess mit Dateidialogen auf dem Desktop ist ein Weg zur Rechteausweitung.
      **Reproduziert am 2026-09-29:** nach der HKLM-Installation lief wieder
      `Greenshot.exe` (PID 5388, jetzt aus `C:\Program Files\Greenshot`) in Session 2,
      Besitzer für den Benutzer nicht lesbar (ReturnValue 2).
      Da immer `-DeployMode Silent` gilt, bringt ServiceUI hier keinen Nutzen.
      Vorschlag: ServiceUI aus den Befehlen nehmen; das erledigt auch die offene Frage
      des Weiterverbreitungsrechts. Auf Wunsch nur dokumentiert.
- [x] **Deinstallation traf per `Contains` jeden Treffer; Suchname fest am Intune-Namen;
      `detection.ps1` wurde nie erneuert.** Gefunden beim Vergleich mit
      `ps-tools/uninstall-Apps.ps1` (2026-09-29). PSADT 4.1.8 vergleicht
      `Uninstall-ADTApplication -Name` standardmäßig per `Contains` und entfernt jeden
      Treffer; die Erkennung prüft „beginnt mit". `Update-DeployScript` erneuerte nur
      `deploy.ps1` — der Stempel stand danach auf „current", die alte Erkennung blieb.
      **Behoben in `482b655` (2.0.12):** gleiche Präfix-Regel
      (`-Name '<Name>*' -NameMatch 'Wildcard'`), `Apps.csv`-Spalte `ArpName`, ein Pfad
      `Write-DetectionScript` für Anlegen und Erneuern.
      **Feldbeleg (PROD, Deinstallation über Intune — vorher nie im Feld gelaufen):**
      App `7f8d9267-…` „IW32H-Feldtest Greenshot ArpName" mit `ArpName = Greenshot`, ohne
      Handanpassung, Intent `uninstall`. Erkennung 16:24:20 UTC über den Suchnamen
      „found"; PSADT „Found installed application [Greenshot 1.3.315]" — genau ein
      Treffer —, `unins000.exe /SILENT /VERYSILENT /SUPPRESSMSGBOXES /NORESTART`, Exit 0;
      danach Erkennung „NOT found", Intune NotDetected, HKLM-Eintrag und
      `C:\Program Files\Greenshot` weg; Everything, Notepad++, 7-Zip unberührt.
- [ ] **Azure-403 beim ersten Chunk.** Bei 3 von 12 Uploads am 2026-09-28 (alle mit
      2–6 Chunks; gezählt über die Transcripts `…\Logs\2026-09-28_*.log`) scheiterte
      der erste Chunk mit „(403) AuthenticationFailed"; die Wiederholung in
      IntuneWin32App 1.5.0 rettete jeden. Das ist das Fehlerbild des
      GIMP-Falls vom 2026-09-25 (dort 1.4.4, ohne diese Wiederholung). Hinweis darauf,
      dass 1.5.0 nicht einfach durch 1.4.4 ersetzt werden sollte.

- [ ] **Zurückgelassen vom Feldtest 2026-09-28 — aufräumen:** in PROD die Apps
      `IW32H-Feldtest *` (7-Zip MSI, Everything (NSIS), Greenshot (Inno), Greenshot
      Inno-Log, Greenshot Inno HKLM, VC++ 2013 x64 (burn), WinGet Everything; die
      Greenshot-Apps außer „Greenshot ArpName" sind inzwischen gelöscht), alle
      *required* (bzw. *uninstall*) an die Gruppe
      `IW32H-Feldtest` (`379dcbdb-bbca-4c45-bde5-0b05e755f23e`, nur CPC-alexa-LAP19);
      auf dem Cloud PC installiert: 7-Zip 24.09, Everything 1.4.1.1032, VC++ 2013 x64,
      Greenshot ist seit 2026-09-29 wieder vollständig entfernt (SYSTEM-Profil-Eintrag
      verschwunden, HKLM-Installation per Intune deinstalliert); lokal
      `C:\IntuneFeldtest`. Die abgeleiteten Deinstallationsbefehle suchen nach dem
      Intune-Namen „IW32H-Feldtest …" und greifen deshalb nicht. Der Test-Tenant ist
      aufgeräumt (auch die GIMP-Geister-App vom 2026-09-25).

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


## Offene Feldprüfung: Hauptfenster (Stufe 1, 2026-10-09)

Das Hauptfenster ersetzt die Startkacheln samt `createApps`, `deployApps` und der beiden
Auswahldialoge (`Start-InventoryLoop`, `Show-InventoryDialog`). Belegt ist **offline**:
`Tests/Test-MainWindowModel.ps1` (Zeilenzustände, `Apps.csv`-Roundtrip) und
`Tests/Test-MainWindowUi.ps1` (UI Automation gegen das echte Fenster und die echte
`Start-InventoryLoop` ohne Tenant: 46 Prüfungen), dazu die Prüfungen 31/32 in
`Invoke-RepoChecks.ps1`. Gegenproben gefahren: 9 Rückbauten für die beiden Tests, 9 für
die Prüfungen, 2 für die Schleife — jeder schlug an. Dabei gefunden und behoben:
`[Windows.FontWeights]::SemiBold` ohne Klammern im `-ArgumentList` wurde als Text
übergeben und scheiterte erst beim Anzeigen.

**Feldlauf 2026-10-09 („Lauf 3")** — Windows 11 de-DE, PowerShell 5.1, PSADT 4.1.8, Tenant
`zarenko.onmicrosoft.com` (PROD, ein Tenant konfiguriert), Transcript
`IntuneWin32Helper\Logs\2026-10-09_21-26-56.log` (lokal, `Logs/` ist nicht versioniert).
Vom Inhaber im Hauptfenster gefahren: eine App, **VSC-Wizard 1.0.117**, Nicht-WinGet-Weg mit
`InstallCmd` aus `Apps.csv`. Das Portal sah nach Aussage des Inhabers unauffällig aus —
das ist eine Beobachtung, kein Messwert dieses Transcripts. Im Transcript:
`Authenticating against tenant [zarenko.onmicrosoft.com]` / „Successfully retrieved access
token using client credentials"; `69 Win32 app(s) in the tenant`; `Creating PSADT
application: VSC-Wizard - 1.0.117`; „ToDo: now add/copy all required files for setup"
(Z. 44); „Longest client-side path: 152 of 259 characters"; `Detection rule: script`;
`Requirement rule: architecture [x64], minimum OS [W10_20H2]`; `Install command:
Invoke-AppDeployToolkit.exe … -DeployMode Silent`; `Build summary: 1 built, 0 failed`;
`Parameter -bulk is NOT set`; `Access token still valid for tenant [zarenko…]`;
`Finished.`; `Deployment summary: 1 succeeded, 0 failed`; danach **`70 Win32 app(s) in the
tenant`** — der Neuabruf nach dem Deploy zeigt die neue App.

- [x] **Hauptfenster → Build → Deploy, eine App** (`Build-AppPackage`,
      `Invoke-PackageBuild`, `Invoke-PackageDeploy`, Neuabruf). Beleg: Lauf 3 oben.
      Zusätzlich offline: WinGet-Weg (7-Zip, `LatestAvailable`) in einen temporären
      Paketordner gebaut — genau **ein** Rückgabewert (der Pfad), `in\`, `out\`,
      `deploy.ps1`, `detection.ps1`, Logo, keine Platzhalter `#…#` übrig, Stempel =
      aktueller Stand (`b1199138dd3a`), das Inventar führt die Zeile als `Package` /
      `current`.

**Weiterhin nicht belegt** — jeweils mit dem Beleg, der sie abhakt:

- [ ] **Mehrere Apps in einem Deploy.** Lauf 3 war eine App. Seit Stufe 3 übergibt das Tool kein
      `-bulk` mehr, sondern je Paket `-Mode New|Update` (siehe Abschnitt Stufe 3 unten). Beleg:
      Transcript mit zwei Apps und `Deployment summary: 2 succeeded, 0 failed, 0 skipped`.
- [ ] **Tenant-Wechsel im Fenster** meldet neu an (`-Force`). Lauf 3 hatte einen Tenant.
      Beleg: nach dem Wechsel `Authenticating against tenant [<neuer>]` im Transcript
      und die Spalte `Intune` zeigt den Bestand des neuen Tenants, nicht den des alten.
- [ ] **Abrufdauer** der Tenant-Apps — jetzt beim Start und bei jedem Refresh/Deploy, nicht
      mehr nur in „Deploy existing apps" (früher gemessen: PROD 63 Apps in 17,7 s). Das
      Transcript trägt keine Zeitstempel; gemessen werden muss mit Stoppuhr oder einem
      Zeitstempel um `Read-TenantWin32Apps`.
- [ ] **Paketbau ohne `InstallCmd`** (Befehle werden aus `Files\` abgeleitet) und der
      **MSI-Weg** (`SingleMSI`). Lauf 3 hatte den Befehl in `Apps.csv`.
- [ ] **Bearbeiten/Anlegen/Duplizieren** gehen weiter über den alten `Open-EditDialog`
      (Stufe 2 ersetzt ihn); der Dialog hat keine Automation-IDs und ist nicht
      maschinell bedient worden. Beleg: eine Definition anlegen, bearbeiten, löschen;
      `Apps.csv` danach unverändert bis auf diese Zeile.

## Stufe 5: Apps, die nur in Intune liegen (2026-10-11)

Das Inventar kannte nur Definitionen und Pakete. Jetzt hat auch jede App im Tenant, zu der es hier weder
Definition noch Paket gibt, eine Zeile. Der Vermerk `Created by IntuneWin32Helper <Version>`, den
`deploy.ps1` seit jeher beim Anlegen schreibt (`Add-IntuneWin32App -Notes`), trennt „vom Tool“ von „fremd“.
Fremde Apps sind standardmäßig ausgeblendet (Ansicht „All (foreign Intune apps hidden)“), eigene Ansichten
zeigen sie; Retire lässt fremde Apps nie zu (Schutz in `Get-RetirePlan`, zusätzlich im Knopf).

Belegt:

- `Tests/Test-IntuneOnly.ps1` (neu) und Erweiterung von `Test-RetireRebuild.ps1` (fremde App gewählt →
  nichts gelöscht, App mit Vermerk → gelöscht), `Test-MainWindowUi.ps1` (201 Prüfungen: fremde Zeile in der
  Standardansicht nicht da, in ihrer Ansicht da, Retire dort aus; ToolOnly-Zeile: nur Retire möglich),
  Prüfung 37 (Schutz in `Get-RetirePlan`, Vermerk in der Vorlage).
- Sieben RÃ¼ckbauten in neun LÃ¤ufen (Schutz entfernt — gegen drei Tests und die Prüfung —, Vermerk-Erkennung auf „immer ja“,
  Intune-only-Zeile nicht angelegt, doppelte Zeile für definierte App, Standardansicht ungefiltert,
  Retire-Knopf ohne Fremd-Regel, Vermerk in der Vorlage geändert) — jede schlug an.
- **Gegen den echten Tenant, nur gelesen** (`zarenko.onmicrosoft.com`, 69 Apps): 24 mit dem Vermerk,
  45 ohne. Inventar: 62 Zeilen in 0,2 s — 39 mit Definition, 8 „Intune only“ (u. a. die fünf Reste des
  Feldtests vom 28.09. und zwei Chrome-Versionen), 15 fremde.

Nicht belegt / Grenzen:

- **Ältere Apps ohne Vermerk gelten als fremd**, auch wenn das Tool sie angelegt hat; sie sind dann
  nur über „Foreign apps in Intune“ zu sehen und von hier nicht zu löschen. Gehört eine solche App dazu,
  hilft eine Definition in `Apps.csv` (dann ist sie keine Intune-only-Zeile mehr). Ob 45 Apps ohne Vermerk
  im Tenant überwiegend solche sind, ist nicht geprüft.
- Die Ansichtsauswahl ist nicht gespeichert: das Fenster startet immer mit ausgeblendeten fremden Apps.
- Aus einer Intune-only-Zeile lässt sich (noch) keine Definition erzeugen.
## Feldprüfung, zweiter Teil: Mehrfach-Deploy, Zuweisungsarten, Tenant-Wechsel, Geschwindigkeit (2026-10-11)

Wieder Wegwerf-Kopie und Testapps „ZZ IW32H Multi A/B/C“ in `zarenko.onmicrosoft.com`; am Ende 69 Apps,
keine Testreste. Die Rückfrage-Fenster sind als Bild geprüft (WPF-Rendering, kein Bildschirmfoto:
in dieser Sitzung gibt es keinen abgreifbaren Desktop).

Belegt im Feld:

- **Mehrere Apps in einem Deploy**: drei Apps in einem Lauf (Plan → drei Pakete gebaut → drei Uploads,
  `Deployment summary: 3 succeeded`). Beim ersten Lauf wiederholte das Modul einen Azure-403 beim ersten
  Chunk selbst (Eintrag „Azure-403 beim ersten Chunk“ oben) — der Upload ging durch.
- **Zuweisungsarten**: „alle Benutzer / available“ und eine Ausschluss-Gruppe zusammen →
  `Get-TenantAppAssignmentInfo` zählt 2 (Graph liefert beide). Echte Gruppen anlegen konnte ich nicht:
  die App-Registrierung darf keine Entra-Gruppen lesen (403), die Ausschluss-Gruppe war eine schon
  vorhandene aus einer anderen App.
- **Tenant-Wechsel**: Wechsel auf `3jr2s6t19s.onmicrosoft.com` und zurück (nur gelesen): 11 bzw. 72 Apps,
  die Testapps nur im richtigen Tenant sichtbar, Wechsel je ca. 0,2 s.
- **Rückfrage-Fenster** mit drei Apps, Dubletten-Hinweis und „could not be read“: lesbar bei 760 px Breite
  (bei 560 px brachen die Id-Zeilen mitten in der Angabe um — Breite angehoben).

Geschwindigkeit (gemessen, `Stopwatch`, gleiche Maschine, 39 echte Definitionen):

| Schritt | vorher | jetzt |
|---|---|---|
| Tenant-Apps lesen (Start, Refresh, Deploy, Retire) | 14,8 s (`Get-IntuneWin32App`) | 0,3–0,4 s (Graph direkt) |
| Zuweisungen je App in der Rückfrage | — | 0,23 s |
| `check-prereqs` (Start und **jedes** deploy.ps1) | 2,9 s, bei jedem Aufruf | 0,05 s, nur einmal je Prozess |
| Paketbau: Wartezeit je App | fest 5 s | wartet auf die Dateien (0 s) |
| Drei Apps bauen und verteilen, gesamt | 112 s | 65 s |
| Hauptfenster aufbauen (39 Zeilen) | — | 0,85 s |
| Inventar berechnen | — | 0,05–0,15 s |

Zur 112→65-s-Zeile: im ersten Lauf steckten 22 s Azure-Wiederholung (403) und 5,4 s Modulprüfung im ersten
deploy.ps1; der reine Bau sank von 30 auf 15 s. Der Rest (je App ca. 4,5 s `IntuneWinAppUtil.exe` und
ca. 10 s Upload) ist Arbeit außerhalb des Tools. Stichprobe, ein Lauf je Stand.

Nicht belegt:

- Gruppen-Zuweisungen mit „Einschließen“ (kein Gruppenzugriff), Zuweisungen mit Filter.
- Paketbau und Upload parallelisieren (nicht versucht; Risiko: gemeinsame Laufwerksbuchstaben für `subst`).
- Abrufdauer in einem Tenant mit deutlich mehr als 70 Apps (Graph-Seiten à 500 sind eingebaut und getestet,
  im Feld nur 1 Seite).
## Feldprüfung Stufe 3 und 4 gegen den Test-Tenant (2026-10-10) — Ergebnis

Gelaufen in einer Wegwerf-Kopie des Tools (eigener Paketordner, eigene `Apps.csv` mit einer Zeile
„ZZ IW32H Feldtest“, Kopie von ProcessExplorer, Version `LatestAvailable`) gegen `zarenko.onmicrosoft.com`
mit den Tool-Funktionen (`Invoke-InventoryDeploy`, `Invoke-InventoryRetire`, `Invoke-InventoryRebuild`);
die Antworten der Rückfragen waren skriptgesteuert (Fenster-Optik nicht gesehen). Vorher/nachher stand
der Tenant bei 69 Apps (68 `win32LobApp` + 1 `win32CatalogApp`), keine Testapp übrig.

Belegt im Feld:

- **Create**: Plan „not in Intune yet“ → Paket gebaut → `deploy.ps1 -Mode New` → genau eine App.
- **Skip**: zweiter Deploy → Rückfrage nennt „already in Intune“, mit „Ja“ bleibt es bei einer App.
- **Update** (Rückfrage mit „Nein“): gleiche Id, `committedContentVersion` 1 → 2; die **Zuweisung blieb**
  (Graph: 1 Zuweisung „alle Benutzer / available“ vor und nach dem Update).
- **Erneuern**: Template geändert → Zeile `template outdated`, Next `renew from template, then deploy`;
  nach dem Deploy `current`, `.bak`-Dateien angelegt.
- **Retire**: „Nein“ löscht nichts; „Ja“ → `REMOVED`, App im Tenant weg (unabhängig nachgelesen),
  Definition und Paketordner blieben, Zeile danach `Next: deploy`.
- **Rebuild**: bauen → löschen (verifiziert) → neu anlegen; genau eine App mit neuer Id.
- **Dubletten**: mit `deploy.ps1 -Mode New` am Plan vorbei erzwungen → Inventar `yes (2x)`, Next
  `check duplicates in Intune`, Plan `Skip: 2 apps … remove the duplicates first`; Retire nennt beide
  Ids und löscht beide.

Was der Feldtest aufgedeckt hat (alles behoben, mit Test):

1. **Die Zuweisungszahl in der Rückfrage war falsch.** `Get-IntuneWin32AppAssignment` (Modul 1.5.0) lieferte
   für eine App mit einer „alle Benutzer“-Zuweisung **keine** Zuweisung, Graph lieferte sie. Die Rückfrage
   hätte „assignments: 0“ gesagt, obwohl es eine gab. Jetzt liest `Get-TenantAppAssignmentInfo` direkt über
   Graph; Feldprobe: „assignments: 1“. Ursache im Modul nicht geklärt. Test: `Test-RetireRebuild.ps1`,
   `Test-TenantRead.ps1`, Prüfung 35.
2. **Die Tenant-Liste hinkt hinterher.** `Get-IntuneWin32App` (Filter `isof`) führte eine gerade angelegte
   App erst nach 40 bis 120 Sekunden; die einfache Liste ohne Filter schon nach wenigen. In der Lücke sah
   ein zweiter Deploy „nicht in Intune“ und hätte eine Dublette angelegt. Jetzt liest
   `Read-TenantWin32Apps` direkt über Graph; Feldprobe: die Liste direkt nach dem Anlegen enthält die App.
   Eine Stichprobe, keine Garantie.
3. **Eigener Fehler beim Beheben von 2:** ein Vergleich auf `win32LobApp` ließ die Enterprise-App-Catalog-App
   „Remote Help“ (`win32CatalogApp`, vom Filter `isof` des Moduls mitgeführt) aus der Liste fallen (68 statt 69) —
   vom Feldvergleich Modul gegen neue Liste gefunden. Test: `Test-TenantRead.ps1` (Katalog-App in der Antwort).

Nicht belegt:

- Die Fenster-Optik der Rückfragen im echten Hauptfenster (der Dialog selbst ist per UI Automation getestet).
- Mehr als eine Zuweisungsart (nur „alle Benutzer / available“ geprüft), Gruppen-Zuweisungen.
- Mehrere Apps in einem Deploy, Tenant-Wechsel im Fenster, Abrufdauer bei großen Tenants.
## Offene Feldprüfung: Retire und Rebuild (Stufe 4, 2026-10-10)

Zwei neue Knöpfe löschen **Apps in Intune** (nicht rückgängig zu machen): **Retire from Intune**
(`Invoke-InventoryRetire`) und **Rebuild** (`Invoke-InventoryRebuild`: Paket neu bauen → alte App
löschen → neue anlegen, genau in dieser Reihenfolge). Beschlossen war, dass Retire Zuweisungen
mitlöschen darf; sie werden **nicht** wiederhergestellt, die Rückfrage nennt ihre Zahl.

Belegt ist **offline**:

- `Tests/Test-RetireRebuild.ps1` (neu; das Modul ist nachgebaut, auch das echte Verhalten
  „`Remove-IntuneWin32App` warnt statt zu werfen"): gelöscht werden nur Apps mit Name **und**
  Version der Zeile, die Ids kommen aus dem frisch gelesenen Tenant (eine Id aus einem veralteten
  Fenster wird nicht angefasst), eine andere Version bleibt, Dubletten werden einzeln genannt und alle
  gelöscht; die Rückfrage nennt Id, Inhalt und Zuweisungen („could not be read" statt „0", wenn das
  Modul nur warnt); „Nein" und nicht lesbarer Tenant löschen nichts; ein Löschen, das nur warnt, wird
  `StillListed` gemeldet (nicht `Removed`), ein werfender Aufruf `Failed`, ein nicht lesbarer Tenant
  danach `Unverified`; Rebuild: Reihenfolge bauen → löschen → anlegen, scheitert der Bau, bleibt die
  App in Intune unberührt, bleibt die alte App stehen, wird keine neue angelegt.
- Prüfung 35 in `Invoke-RepoChecks.ps1` (Löschen nur in `Remove-TenantWin32Apps` mit Nachlesen;
  Rückfrage vor dem Löschen und mit Standardantwort Nein; Rebuild löscht nie vor dem Bau; die
  Schleife löscht nie direkt) und `Test-MainWindowUi.ps1` (Knopfzustände, beide Aktionen kommen mit
  der gewählten Zeile zurück).
- Gegenproben: 13 Rückbauten (andere Version mit gelöscht, Stand des Fensters statt frisch gelesen,
  Prüfung nach dem Löschen entfernt, Nachlesen entfernt, Löschen vor dem Bau, Anlegen trotz Rest,
  Standardantwort Ja, Löschen in der Schleife, Löschaufruf außerhalb der Funktion, Zweig fehlt,
  Zuweisungen „0" statt „nicht lesbar", Retire-Knopf immer aktiv) — jede schlug an.
- Aus der Modulquelle (1.5.0) gelesen, **nicht** im Feld geprüft: `Remove-IntuneWin32App` fängt
  Fehler und warnt nur (deshalb das Nachlesen); `Get-IntuneWin32AppAssignment` warnt ebenfalls nur.

**Nicht belegt** (keiner dieser Läufe ist gemacht; Löschen gegen einen echten Tenant braucht die
ausdrückliche Freigabe des Inhabers und eine Test-App, nicht eine produktive):

- [x] **Retire im Feld** gegen eine Test-App: Rückfrage, `REMOVED  <Name> - <Version>  <Id>`,
      `Retire summary: 1 removed, 0 not removed.`, App im Portal weg, Definition und Paketordner da.
- [x] **Das Nachlesen im Feld**: dass die Liste eine gerade gelöschte App wirklich nicht mehr führt
      (sonst würde ein erfolgreiches Löschen als `StillListed` gemeldet - sichtbar, nicht gefährlich).
- [x] **Rebuild im Feld** einer Test-App: erst `Build summary`, dann `Retire summary`, dann
      `Deployment summary: 1 succeeded`; im Portal genau eine App mit neuer Id und Inhalt.
- [x] **Zuweisungszahl** in der Rückfrage gegen eine App mit bekannter Zuweisung.
- [x] **Dubletten bereinigen** mit Retire (Test-Tenant mit zwei gleichen Apps).
- [x] **Die Rückfrage** ist seit 2026-10-10 ein eigenes Fenster (`Show-ConfirmDialog`), das per UI Automation geklickt wird (`Test-MainWindowUi.ps1`: Tasten, Standardknopf, Fokus, Schließen = sichere Antwort). Vorher geprüft war,
      welcher Text und welche Tasten übergeben werden, und dass die Vorgabe Nein ist (Prüfung 35).
## Offene Feldprüfung: Deploy-Plan statt blindem Anlegen (Stufe 3, 2026-10-10)

Vorher legte der Bulk-Lauf **immer** eine neue App an, auch wenn dieselbe App in derselben Version
schon in Intune lag (`deploy_template.ps1`, Zweig „BULK IS SET"). Jetzt entscheidet das Tool vorher:
`Invoke-InventoryDeploy` liest Intune frisch (`Read-TenantWin32Apps`), plant (`Get-DeployPlan`:
Create / Skip / Update), fragt mit dem Plan, baut nur, was verteilt wird, und ruft
`Invoke-PackageDeploy` mit `-Mode` und `-UpdateAppId` je Paket. Das Inventar gleicht Intune nach
**Name und Version** ab (`displayVersion`); zwei Versionen derselben App waren bisher als
„Dubletten" (`yes (2x)`) markiert.

Belegt ist **offline**:

- `Tests/Test-DeployPlan.ps1` (neu): Inventar nach Name+Version (gleiche Version, andere Version,
  App ohne `displayVersion`, zwei Versionen, echte Dublette), Plan je Zustand, `-ReplaceExisting`
  ersetzt weder Dubletten noch inhaltslose Einträge, nicht gelesener Intune-Zustand wird nicht
  geplant, `Invoke-PackageDeploy` ruft ein aufzeichnendes Skript mit `-Mode`/`-UpdateAppId` und
  ohne `-bulk` auf und bricht VOR dem ersten Upload ab, wenn eine Entscheidung fehlt,
  `Invoke-InventoryDeploy` liest neu (die Auswahl stammt aus einem Fenster mit leerem Intune),
  baut übersprungene Zeilen nicht, tut bei Abbruch und nicht lesbarem Tenant nichts.
- Prüfung 34 in `Invoke-RepoChecks.ps1` (kein Deploy am Plan vorbei; `-Mode` im Template;
  Ergebnis des Updates wird nicht verworfen) und angepasste Prüfung 32.
- Gegenproben: 10 Rückbauten (Dubletten-Regel, neu lesen, Bau übersprungener Zeilen, `-Mode`
  weglassen, Versionsabgleich, Deploy am Plan vorbei, verworfenes Update-Ergebnis, Geister-Eintrag,
  nicht gelesener Zustand) — jede schlug an.
- Aus der Modulquelle (1.5.0, `Update-IntuneWin32AppPackageFile.ps1`) gelesen, **nicht** im Feld
  geprüft: Das Update legt eine neue contentVersion an und setzt nur `committedContentVersion` und
  `largeIcon` per PATCH; Erkennungsregel, Befehlszeilen, Anforderungen und Zuweisungen werden
  dort nicht angefasst. Bei einem Fehler warnt das Modul und gibt nichts zurück — das Template
  prüft das Ergebnis jetzt (vorher: `$uploadResult = $app`, ein gescheitertes Update blieb
  unsichtbar).

**Folge der Template-Änderung:** der Vorlagen-Fingerabdruck hat sich geändert; jedes vorhandene
Paket steht einmal als `Package, template outdated` da und wird beim nächsten Deploy erneuert
(mit `.bak`). Das ist der vorgesehene Weg, aber im Feld noch nicht gelaufen.

**Nicht belegt:**

- [x] **Create im Feld mit dem neuen Template**: eine App, die es in Intune nicht gibt; Transcript
      mit `Decision of the calling run: create a new app`, `Finished.`, `Deployment summary: 1
      succeeded, 0 failed, 0 skipped`, App in Intune mit Inhalt.
- [x] **Skip im Feld**: dieselbe App direkt nochmal deployen — das Fenster fragt, bei „Ja" kommt
      `SKIPPED  <Name> - <Version>: already in Intune`, in Intune bleibt **eine** App.
- [x] **Update im Feld** (Frage mit „Nein" beantworten) gegen eine App **mit Zuweisung**: nach dem
      Lauf ist die Zuweisung noch da, `committedContentVersion` ist gestiegen, Erkennungsregel
      unverändert. Erst das belegt, dass „Zuweisungen bleiben" stimmt.
- [x] **Erneuern vorhandener Pakete** (`template outdated` → Deploy) mit dem neuen Template.
- [x] **Der Fragedialog** ist seit 2026-10-10 `Show-ConfirmDialog` und per UI Automation bedient (Antworten Yes/No/Cancel, Schließen = Cancel); vorher war er ein `MessageBox`:
      geprüft ist, welcher Text und welche Tasten übergeben werden, nicht, wie er aussieht.
- [ ] **Zwei Versionen derselben App** in einem Tenant: `yes` für beide, kein „Dubletten"-Hinweis.
## Offene Feldprüfung: Bearbeiten-Dialog und verwaiste Ordner (Stufe 2, 2026-10-09)

`Open-EditDialog` ist neu (Kopf mit Fakten zur Zeile, Felder in Gruppen, Auswahllisten aus dem
Modul, Haken, mehrzeilige Befehle, Hinweise, OK prüft Name+Version auch auf Doppelte), dazu der
Knopf **Remove orphan folder** (`Remove-OrphanPackages`). Belegt ist **offline**:
`Tests/Test-MainWindowModel.ps1` (Löschschutz an temporären Ordnern: Ordner mit Definition,
Ordner nicht als `<Name> - <Version>` benannt, Ordner ohne `deploy.ps1`, Ordner außerhalb der
Wurzel — jeweils nicht gelöscht; Auswahllisten enthalten jeden Wert der echten `Apps.csv`),
`Tests/Test-MainWindowUi.ps1` (106 Prüfungen, darunter der Dialog über UI Automation: Typ jedes
Steuerelements, WinGet-Felder nur bei `LatestAvailable`, Hinweis zu `ArpName` folgt dem Feld,
OK bleibt bei leerem/doppeltem Namen offen, Rückgabewerte, Abbruch) und Prüfung 33. Gegenproben:
8 Rückbauten (Löschschutz, Dialog) und 5 für Prüfung 33 bzw. die Diagnose — jeder schlug an.
Dialoggröße mit einer echten Definition (VSC-Wizard): 780 × 1243 px auf einem Arbeitsbereich von
5120 × 1392, OK ohne Scrollen sichtbar.

**Nicht belegt:**

- [ ] **Die Rückfrage vor dem Löschen** ist ein Win32-`MessageBox` und per UI Automation nicht
      bedienbar; geprüft ist nur, dass der Zweig `YesNo` verlangt (Prüfung 33), nicht, wie der
      Text aussieht. Beleg: einen verwaisten Ordner im Fenster wirklich entfernen — Transcript
      mit `REMOVED  <Name>`, Ordner weg, App in Intune unberührt.
- [ ] **Bearbeiten, Anlegen und Duplizieren im Fenster gegen echte Daten**: `Apps.csv` danach
      unverändert bis auf die bearbeitete Zeile (`git diff`).
- [ ] **Die Prefill-Knöpfe** (`From WinGet...`, `From MSI...`) sind nicht bedient worden — ein
      WinGet-Suchdialog und ein Dateidialog sind per UI Automation nicht sinnvoll zu fahren.
- [ ] **Kleine Bildschirme**: `MaxHeight` begrenzt das Fenster auf den Arbeitsbereich minus 40 px,
      die Felder scrollen, OK/Cancel bleiben stehen. Gemessen nur auf dem großen Bildschirm.

**Beifund (erledigt):** die Spalte `PackageName` in `Apps.csv` wurde vom Paketbau nicht gelesen —
`#PN#` im `deploy.ps1` kommt aus `DisplayName` (`Write-DeployScript`). Auf Entscheidung des Inhabers
entfernt: `Get-AppsCsvColumns` kennt sie als aufgegebene Spalte, ein Speichern über `Save-AppsCsv` lässt
sie aus der Datei fallen, der Dialog zeigt sie nicht mehr. Die Variable `$PackageName` im erzeugten
`deploy.ps1` bleibt (Template unangetastet, sonst würde der Template-Fingerabdruck alle Pakete als veraltet
markieren).