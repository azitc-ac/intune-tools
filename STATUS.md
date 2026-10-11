# Projektstand

Arbeitsdokument zum Wiedereinstieg – in einer neuen Sitzung, auf einem anderen Rechner oder nach einer Pause.
Die `IntuneWin32Helper/README.md` sagt, **wie das Tool funktioniert**; `RELEASES.md` ist das Protokoll **jeder Änderung mit
ihrem Beleg**; diese Datei sagt, **wo es steht, was im Feld gelaufen ist, was offen ist und was entschieden ist**.
Sie fasst zusammen und verweist, sie ersetzt `RELEASES.md` nicht.

Stand: 2026-10-11

Zwei Prüfungen halten die Datei ehrlich (`Tests/Invoke-RepoChecks.ps1`, Prüfung 44): jeder Abschnitt von `RELEASES.md` mit
„Nicht belegt“ oder einem offenen Kästchen ist unten über eine Quellenzeile erwähnt (das Wort „Quelle“, ein Doppelpunkt, dann
die Überschrift des Abschnitts), und jede Quellenzeile nennt einen Abschnitt, den es gibt; außerdem darf `Stand:` nicht älter sein als der jüngste Abschnitt von
`RELEASES.md`. Ein neuer Abschnitt mit offenem Punkt macht den Lauf rot, bis er hier eingetragen ist.

## Wo es steht

IntuneWin32Helper **2.0.12** (`IntuneWin32Helper/VERSION`). Der letzte Rückkehrpunkt mit Transcript-Beleg ist der Tag
`IntuneWin32Helper-v2.0.0`; seither sind das Hauptfenster (eine Zeile je App aus Definition, Paket und Tenant), der Deploy-Plan
(Create/Skip/Update statt blindes Anlegen), Retire und Rebuild, Apps, die nur in Intune liegen, die WinGet-Suche mit lokalem
Index, „Check tenant“, „From installer…“ und die Aufteilung von `functions.ps1` in 14 Dateien dazugekommen. Das meiste davon ist
im Feld gegen den Test-Tenant gelaufen (nächster Abschnitt), manches nur gegen Tests.

`main` ist strukturell grün (Repo-Prüfungen, 19 Testdateien, UI-Prüfung des Hauptfensters per UI Automation). Ein grüner Lauf ist
**kein** Feldbeleg: belegt ist, was ein Transcript, ein IME-Log oder das Portal zeigt.

## Im Feld belegt

Alles gegen `zarenko.onmicrosoft.com` (Test-Tenant, Testapps „ZZ IW32H …“, danach aufgeräumt). Einzelheiten und Transcripts in `RELEASES.md`.

| Was | Beleg (Abschnitt in RELEASES.md) |
| --- | --- |
| Installer-Engines NSIS und Burn auf einem Client, Inno mit Fund (`/ALLUSERS`) | Quelle: IntuneWin32Helper 2.0.0 — im Feld gelaufener Stand |
| Hauptfenster → Build → Deploy, eine App | Quelle: Offene Feldprüfung: Hauptfenster (Stufe 1, 2026-10-09) |
| Create, Skip, Update (Zuweisung bleibt), Erneuern, Retire, Rebuild, Dubletten | Quelle: Feldprüfung Stufe 3 und 4 gegen den Test-Tenant (2026-10-10) — Ergebnis |
| Mehrere Apps in einem Deploy, Zuweisungsarten, Tenant-Wechsel, Geschwindigkeit | Quelle: Feldprüfung, zweiter Teil: Mehrfach-Deploy, Zuweisungsarten, Tenant-Wechsel, Geschwindigkeit (2026-10-11) |
| Tenant-Apps und Zuweisungen direkt über Graph (statt Modul-Cmdlets) | Quelle: Feldprüfung Stufe 3 und 4 gegen den Test-Tenant (2026-10-10) — Ergebnis |
| Apps, die nur in Intune liegen; fremde Apps ausgeblendet | Quelle: Stufe 5: Apps, die nur in Intune liegen (2026-10-11) |
| „Check tenant“ gegen den Test-Tenant, alle fünf Schritte OK | Quelle: Keine MessageBox mehr, Knopf „Check tenant“ (2026-10-11) |
| Retire/Rebuild/Deploy-Plan als Feldläufe | Quelle: Offene Feldprüfung: Retire und Rebuild (Stufe 4, 2026-10-10), Quelle: Offene Feldprüfung: Deploy-Plan statt blindem Anlegen (Stufe 3, 2026-10-10) |
| WinGet-Index gegen das echte CDN (15.546 Pakete) | Quelle: WinGet-Suche mit lokalem Index (2026-10-11) |

## Offen

**Nie von Hand im echten Fenster bedient** (nur per UI Automation oder Rendern geprüft):
„Check tenant“, „From installer…“, „From WinGet…“, „From MSI…“, Return im WinGet-Suchfeld, Fenster-Optik der Rückfragen,
kleine Bildschirme, ein verwaister Ordner im Fenster wirklich entfernt, Bearbeiten/Anlegen/Duplizieren gegen echte Daten
(danach `git diff` auf `Apps.csv`).
Quelle: Editor: „From installer…“ (2026-10-11)
Quelle: Keine MessageBox mehr, Knopf „Check tenant“ (2026-10-11)
Quelle: WinGet-Suche mit lokalem Index (2026-10-11)
Quelle: Offene Feldprüfung: Bearbeiten-Dialog und verwaiste Ordner (Stufe 2, 2026-10-09)
Quelle: Offene Feldprüfung: Retire und Rebuild (Stufe 4, 2026-10-10)
Quelle: Offene Feldprüfung: Deploy-Plan statt blindem Anlegen (Stufe 3, 2026-10-10)

**Nur gegen Tests, nicht im Feld:**
- Ein Tenant, dem das Recht `DeviceManagementApps.ReadWrite.All` fehlt (nur mit selbst gebautem Token getestet).
  Quelle: Keine MessageBox mehr, Knopf „Check tenant“ (2026-10-11)
- Ein echter Paketbau und Deploy über den Lader `functions.ps1` und mit dem neuen PSADT-Log-Pfad (die Tests laden die Funktionen per Syntaxbaum).
  Quelle: `functions.ps1` aufgeteilt (2026-10-11)
  Quelle: Logo mit Namenskürzung, mitlaufende Hinweise, PSADT-Log (2026-10-11)
- „From installer…“ mit einem echten Inno-/NSIS-Setup (getestet mit Dateien, die nur die Kennung tragen); Paketbau ohne `InstallCmd` und der MSI-Weg.
  Quelle: Editor: „From installer…“ (2026-10-11)
  Quelle: Offene Feldprüfung: Hauptfenster (Stufe 1, 2026-10-09)
- Fehlerfundstelle bei Fehlern aus Modul-Cmdlets (zeigt auf den Aufruf in unserem Skript, nicht ins Modul).
  Quelle: Fehlermeldungen mit Fundstelle (2026-10-11)
- Zwei Versionen derselben App im Tenant (`yes` für beide, kein Dubletten-Hinweis).
  Quelle: Offene Feldprüfung: Deploy-Plan statt blindem Anlegen (Stufe 3, 2026-10-10)
- Die Fenster in den Bildern des README sind mit erfundenen Daten gerendert, nicht fotografiert.
  Quelle: Bilder im README (2026-10-11)

**Grenzen des Tenants, gegen den getestet wird:**
- Gruppen-Zuweisungen mit „Einschließen“ und Filter (die App-Registrierung darf keine Entra-Gruppen lesen, 403).
- Abrufdauer in einem Tenant mit deutlich mehr als 70 Apps (Seiten à 500 sind eingebaut, im Feld nur eine Seite).
- Ältere Apps ohne Vermerk gelten als fremd; ob die 45 im Tenant überwiegend vom Tool stammen, ist nicht geprüft.
  Quelle: Feldprüfung, zweiter Teil: Mehrfach-Deploy, Zuweisungsarten, Tenant-Wechsel, Geschwindigkeit (2026-10-11)
  Quelle: Feldprüfung Stufe 3 und 4 gegen den Test-Tenant (2026-10-10) — Ergebnis

**Aus älteren Abschnitten, Kästchen nie abgehakt** (teils vermutlich überholt, nicht erneut geprüft):
- Der Inventar-Abruf („Spalte `Intune` stimmt gegen das Portal“, Dauer): das Hauptfenster hat ihn seitdem ersetzt und im Feld gelaufen, das Kästchen blieb offen.
- Azure-403 beim ersten Chunk eines Uploads: tritt gelegentlich auf (3 von 12 Uploads am 2026-09-28, wieder am 2026-10-11); das Modul 1.5.0 wiederholt selbst und rettet den Upload. Hinweis, 1.5.0 nicht durch 1.4.4 zu ersetzen.
- Reste des Feldtests vom 2026-09-28 (`IW32H-Feldtest *` und die Gruppe `IW32H-Feldtest`): ob sie noch existieren, ist nicht geprüft; vor dem Aufräumen im Portal nachsehen.
- `ServiceUI.exe` ist ein Microsoft-Binary, das Recht zur Weiterverbreitung ist nicht geklärt (nur dokumentiert in `THIRD-PARTY-NOTICES.md`).
- Supersedence: bewusst zurückgestellt.
  Quelle: Offene Feldprüfung für `main`

**Dieses Dokument selbst:**
- Die Prüfung 44 hat nur auf Überschriftsebene gezeigt, dass jeder offene Abschnitt hier vorkommt, nicht je Kästchen; die Zuordnung der Punkte oben ist von Hand und kann Lücken haben.
  Quelle: `STATUS.md` und kaputte Umlaute (2026-10-11)

**Funktionen, die fehlen:**
- Ansichtsauswahl (fremde Apps ein/aus) wird nicht gespeichert; aus einer Intune-only-Zeile lässt sich keine Definition erzeugen.
- Paketbau und Upload parallelisieren (nicht versucht; Risiko: gemeinsame Laufwerksbuchstaben für `subst`).
- Installer-Download für feste Versionen (Hash, Signatur) wie im SCCMAppHelper – bewusst nicht übernommen, als Idee vorgemerkt.
  Quelle: WinGet-Suche mit lokalem Index (2026-10-11)
- Aus dem SCCM-Vergleich noch nicht übernommen: Cache für Paket-Scans, `update.ps1` für Server ohne git.
- Autopilot-Gerät Surface-fKgOHKI: neu zuordnen ist **Entscheidung des Inhabers**, nur lesende Prüfungen.
- Alte Remote-Branches aus Cloud-Sitzungen werden nur auf Wunsch gelöscht.

## Feste Entscheidungen

Nicht ohne Grund neu aufrollen.

- **Tenant** wird einmal am Anfang gewählt und lässt sich im Fenster wechseln.
- **Fremde Apps** (nicht vom Tool angelegt, erkennbar am Vermerk) sind standardmäßig ausgeblendet.
- **Retire** darf auch Zuweisungen löschen; vorher kommt immer die Rückfrage mit Namen, Ids und Zuweisungszahl, Vorgabe „No“.
- **Eine Zeile je App** im Hauptfenster; es gibt keine Startkacheln und keine getrennten Dialoge zum Anlegen und Verteilen.
- **Der Deploy entscheidet vor dem Hochladen** (Plan: Create/Skip/Update), statt blind anzulegen.
- **Vorlagen bleiben im Paket**: ein Template-Fingerabdruck zeigt veraltete Pakete, Erneuern ist ein eigener Schritt mit `.bak`.
- **Keine `MessageBox`**: jede Meldung und Rückfrage geht über `Show-ConfirmDialog`, damit UI Automation sie bedienen kann (Prüfung 40).
- **Fehlermeldungen tragen ihre Fundstelle** (`Format-ErrorDetail`), kein nacktes `$_.Exception.Message`.
- **Logos und Installer-Daten bleiben lokal**, nichts wird zu Dritten hochgeladen.
- **`functions.ps1` ist nur noch der Lader**; eine Funktion steht in genau einer Datei (Prüfungen 41, 42).
- **Windows PowerShell 5.1**, Dateien UTF-8 mit BOM und CRLF (README/RELEASES/STATUS: CRLF ohne BOM).

## Umgebungen und Arbeitsregeln

| | Tenant | Zweck |
| --- | --- | --- |
| Test | `zarenko.onmicrosoft.com` | Feldtests, Testapps „ZZ IW32H …“, danach aufräumen |
| Weitere | `3jr2s6t19s.onmicrosoft.com` | nur lesen (Tenant-Wechsel) |
| Fremd | `prym.com` | nicht anfassen |

- Feldtests nur im Test-Tenant; Löschen gegen einen echten Tenant braucht die ausdrückliche Freigabe des Inhabers und eine Test-App.
- `Config/config.json` enthält Client-Secrets und gehört nicht ins Repo; Kopien davon im Arbeitsverzeichnis werden gelöscht.
- Abgeschlossene, getestete Änderungen werden direkt auf `main` committet und gepusht; nachgefragt wird nur bei Destruktivem oder roten Tests.
- Eine neue Regel wird als Prüfung in `Tests/Invoke-RepoChecks.ps1` gefasst und ist erst fertig, wenn sie beim Rückbau des Fehlers fehlschlägt.
- Screenshots für das README: `IntuneWin32Helper/Docs/Make-Screenshots.ps1` in einer **aktiven** Sitzung (in einer getrennten oder gesperrten malt WPF nichts).
