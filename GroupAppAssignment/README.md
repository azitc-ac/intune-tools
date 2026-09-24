# GroupAppAssignment – App-Zuweisungen aus Sicht der Gruppe

Gegenstück zum [Intune Bulk App Assignment Tool](https://github.com/TheJamberry/Intune-Bulk-App-Assignment-Tool):
Das geht von den **Apps** aus („diese Apps an diese Gruppen"). Dieses Tool geht von der **Gruppe**
aus – wie `CollectionMembership` in den [SCCM-RightClickTools](https://github.com/azitc-ac/SCCM-RightClickTools/tree/main/CollectionMembership):

- Gruppe wählen (Suche in Entra ID) – oder **Alle Benutzer** / **Alle Geräte**.
- **Links:** alle Intune-Apps, die diesem Ziel *nicht* zugewiesen sind.
- **Rechts:** alle Apps, die ihm zugewiesen sind – mit **Modus** (Erforderlich / Verfügbar /
  Deinstallieren / Verfügbar ohne Registrierung), **Ausschluss** und **Filter**.
- Pfeil-Buttons `Erforderlich >`, `Verfügbar >`, `Deinstallieren >`, `Ausschließen >`, `< Entfernen`;
  Modus und Ausschluss lassen sich rechts im Grid direkt ändern. Doppelklick links = Erforderlich.
- Suche und App-Typ-Filter (z. B. `iosVppApp`) wirken auf beide Seiten.
- Farben rechts: grün = neu, gelb = geändert; links `(wird entfernt)` = Zuweisung wird gelöscht.
- **Speichern** zeigt die Liste der Änderungen, schreibt sie und **liest danach jede berührte App
  aus Intune zurück** – die Anzeige zeigt anschließend den echten Ist-Stand, Abweichungen werden gemeldet.

Es wird nur die Zuweisung **für das gewählte Ziel** angefasst; alle anderen Zuweisungen einer App
bleiben unverändert. Oberfläche zweisprachig (Deutsch/Englisch nach UI-Kultur).

## Voraussetzungen

| | |
|---|---|
| OS / PowerShell | Windows, Windows PowerShell 5.1 (oder 7.x) – WinForms |
| Modul | `Microsoft.Graph.Authentication` (`Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`) |
| Graph-Rechte (delegiert) | `DeviceManagementApps.ReadWrite.All`, `Group.Read.All` – dieselben wie beim Bulk App Assignment Tool, also kein neuer Zustimmungsdialog. Nur mit „Filternamen laden" zusätzlich `DeviceManagementConfiguration.Read.All` |

Anmeldung interaktiv mit dem eigenen Konto (`Connect-MgGraph`), keine App-Registrierung.

## Start

```powershell
Unblock-File .\Manage-GroupAppAssignment.ps1
.\Manage-GroupAppAssignment.ps1                                # Ziel im Fenster wählen
.\Manage-GroupAppAssignment.ps1 -GroupId <Objekt-ID>           # direkt diese Gruppe
.\Manage-GroupAppAssignment.ps1 -GroupId AllUsers              # oder AllDevices
```

oder `Start-GroupAppAssignment.bat` doppelklicken (Parameter werden durchgereicht).

| Parameter | Standard | Bedeutung | im Fenster |
|---|---|---|---|
| `-GroupId` | – | Gruppen-Objekt-ID, `AllUsers` oder `AllDevices` | `...`-Button |
| `-TenantId` | – | Tenant für `Connect-MgGraph` | – (Anmeldedialog) |
| `-VppDeviceLicensing` | `$true` | Lizenztyp für **neue** VPP-Zuweisungen (`iosVppApp`, `macOsVppApp`): Gerät / Benutzer | Checkbox „VPP neu: Gerätelizenz" |
| `-LoadFilterNames` | aus | Namen der Zuweisungsfilter statt ihrer IDs anzeigen. Fordert `DeviceManagementConfiguration.Read.All` an (einmaliger Zustimmungsdialog); ist das Häkchen beim Verbinden noch nicht gesetzt, wird beim Anhaken neu verbunden | Checkbox „Filternamen laden" |
| `-Language` | `auto` | `auto` \| `de` \| `en` | – |

## Verhalten im Detail

- **Neu:** `POST …/mobileApps/{id}/assignments`. **Entfernen:** `DELETE …/assignments/{assignmentId}`.
- **Modus/Ausschluss ändern:** `DELETE` + `POST` (eine Gruppe kann pro App nur einmal zugewiesen sein).
  Filter und Einstellungen (z. B. Win32-Benachrichtigungen, VPP-Lizenztyp) der alten Zuweisung werden
  übernommen, solange es ein Einschluss bleibt; ein Ausschluss hat beides nicht. Scheitert das `POST`,
  wird die alte Zuweisung wiederhergestellt – und gemeldet, falls auch das scheitert.
- **Richtliniensätze (Policy Sets):** Zuweisungen mit `source = policySets` werden grau und
  schreibgeschützt angezeigt („Richtliniensatz"); das Tool ändert oder löscht sie nicht.
  Gibt es für dasselbe Ziel eine direkte und eine Policy-Set-Zuweisung, zeigt es die direkte.
- **Vorab abgelehnt:** Ausschluss für Alle Benutzer/Alle Geräte, „Verfügbar" an Alle Geräte.
  Alles andere prüft Intune selbst (z. B. „Verfügbar" an eine Gerätegruppe) – die Fehlermeldung von
  Graph wird pro App angezeigt.
- **Neue Ausschlüsse** bekommen den Modus „Erforderlich"; im Grid änderbar.
- Ungespeicherte Änderungen: Rückfrage beim Schließen, Neuladen und Gruppenwechsel.

## Grenzen / Annahmen

- Es zählt nur die **direkte** Zuweisung an die Gruppe. Verschachtelte Gruppen (die Gruppe ist Mitglied
  einer zugewiesenen Gruppe) werden **nicht** aufgelöst.
- Graph **beta** (`/deviceAppManagement/mobileApps`). `$expand=assignments` auf der App-Liste steht nicht
  in den dokumentierten Abfrageoptionen; fehlt die Erweiterung in der Antwort, liest das Tool die
  Zuweisungen App für App (langsamer, aber korrekt).
- Pfade, `intent`-Werte, Ziel-Typen (`groupAssignmentTarget`, `exclusionGroupAssignmentTarget`,
  `allLicensedUsersAssignmentTarget`, `allDevicesAssignmentTarget`), `source` und `useDeviceLicensing`
  sind gegen die Graph-beta-Doku (Quelle: `microsoftgraph/microsoft-graph-docs-contrib`) geprüft.
  **Nicht** gegen einen echten Tenant getestet – die GUI lief in dieser Umgebung nicht (kein Windows).

## Tests

```powershell
.\Test-GroupAppAssignment.ps1     # Exit-Code 0 = alles grün; kein Graph, keine GUI, kein Pester
```

Prüft: UTF-8-BOM jeder `.ps1`, keine PS-7-only-Operatoren (`??`, `?.`, `?:`, `&&`, `||`),
angeforderte Graph-Rechte (Standard genau die zwei ohne Filter-Recht), `AddRange(@(...))` nur auf
`.Controls`, Paging und Zurücklesen mit nachgebildetem `Invoke-MgGraphRequest` (0/1/2 Zuweisungen),
Parsbarkeit, Ziel-Zuordnung inkl. Policy-Set-Vorrang, Request-Bodies (Ein-/Ausschluss, VPP-Lizenz,
Filter/Settings-Übernahme), Zielregeln und den Hinzufügen/Ändern/Entfernen-Plan. Das Skript lädt nur
den GUI-freien Teil von `Manage-GroupAppAssignment.ps1` bis zur Markerzeile
`# ---- end of the GUI-free part`.

Alle `.ps1` sind UTF-8 mit BOM, CRLF per `.gitattributes` im Repo-Wurzelverzeichnis.
