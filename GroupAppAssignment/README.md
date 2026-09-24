# GroupAppAssignment – Intune-Zuweisungen aus Sicht der Gruppe

Gegenstück zum [Intune Bulk App Assignment Tool](https://github.com/TheJamberry/Intune-Bulk-App-Assignment-Tool):
Das geht von den **Apps** aus („diese Apps an diese Gruppen"). Dieses Tool geht von der **Gruppe**
aus – wie `CollectionMembership` in den [SCCM-RightClickTools](https://github.com/azitc-ac/SCCM-RightClickTools/tree/main/CollectionMembership) –
und zeigt nicht nur Apps, sondern alles, was man einer (z. B. iOS-)Gruppe typischerweise zuweist.

```
┌ Kategorie ──────────┬ Nicht zugewiesen ─────┬──────────┬ Zugewiesen ─────────────────────────────┐
│ Alle          23/410│                       │Zuweisen >│ Name | Kategorie | Typ | Modus | Ausschl.│
│ Apps          12/140│                       │Ausschl. >│ …                                       │
│ Konfiguration  6/85 │                       │          │                                         │
│ Compliance     1/9  │                       │<Entfernen│                                         │
│ …                   │                       │          │                                         │
└─────────────────────┴───────────────────────┴──────────┴─────────────────────────────────────────┘
```

- Gruppe wählen (Suche in Entra ID) – oder **Alle Benutzer** / **Alle Geräte**.
- **Kategorie links** bestimmt, was in der Mitte und rechts steht; dahinter „zugewiesen / gesamt" für die
  gewählte Plattform, `(...)` = noch nicht geladen. Eine Kategorie wird beim ersten Öffnen geladen.
- **Mitte:** alle Objekte der Kategorie, die dem Ziel *nicht* zugewiesen sind.
- **Rechts:** alle, die ihm zugewiesen sind – bei Apps mit **Modus** (Erforderlich / Verfügbar /
  Deinstallieren / Verfügbar ohne Registrierung), bei allen mit **Ausschluss** und **Filter**.
- **Buttons** passen sich an: Apps `Erforderlich >` `Verfügbar >` `Deinstallieren >` `Ausschließen >`,
  alle anderen Kategorien `Zuweisen >` `Ausschließen >`, dazu `< Entfernen`. Doppelklick in der Mitte =
  Erforderlich bzw. Zuweisen. In **„Alle"** nur ansehen und entfernen (Spalte *Kategorie* kommt dazu).
- **Plattform** oben (Standard iOS/iPadOS) grenzt alle Kategorien ein; Objekte ohne eigene Plattform
  (Web-Apps, …) erscheinen immer. Suche und Typ-Filter wirken auf Mitte und rechts.
- Klick auf eine Spaltenüberschrift rechts sortiert danach (erneut: absteigend), bei gleichem Wert nach Name.
- Farben rechts: grün = neu, gelb = geändert; in der Mitte `(wird entfernt)` = Zuweisung wird gelöscht.
- **Speichern** zeigt alle Änderungen über alle Kategorien, schreibt sie und **liest danach jedes
  berührte Objekt aus Intune zurück** – die Anzeige zeigt den echten Ist-Stand, Abweichungen werden gemeldet.

Es wird nur die Zuweisung **für das gewählte Ziel** angefasst; alle anderen Zuweisungen eines Objekts
bleiben unverändert. Oberfläche zweisprachig (Deutsch/Englisch nach UI-Kultur).

## Kategorien

| Kategorie | Graph (beta) | Schreiben |
|---|---|---|
| Apps | `deviceAppManagement/mobileApps` | einzeln (`POST`/`DELETE …/assignments`) |
| Konfigurationsprofile – Vorlagen (Geräteeinschränkungen, WLAN, VPN, Zertifikate, iOS-Update, …) | `deviceManagement/deviceConfigurations` | einzeln |
| Konfigurationsprofile – Einstellungskatalog (inkl. Declarative Software Update) | `deviceManagement/configurationPolicies` | Gesamtliste (`/assign`) |
| Compliance | `deviceManagement/deviceCompliancePolicies` | einzeln |
| App-Konfiguration (verwaltete Geräte) | `deviceAppManagement/mobileAppConfigurations` | einzeln |
| App-Konfiguration (verwaltete Apps, MAM) – nur Benutzer | `deviceAppManagement/targetedManagedAppConfigurations` | Gesamtliste (`…/assign`) |
| App-Schutz (iOS, Android, Windows) – nur Benutzer | `deviceAppManagement/{ios,android,windows}ManagedAppProtections` | Gesamtliste (`managedAppPolicies/{id}/assign`) |

**Gesamtliste** heißt: Das Tool liest die Zuweisungsliste des Objekts unmittelbar vor dem Schreiben frisch,
ändert nur den Eintrag des gewählten Ziels und schickt die Liste zurück. Alle anderen Ziele gehen mit
ihrem Filter unverändert mit; das prüft das Testskript ausdrücklich.

## Voraussetzungen

| | |
|---|---|
| OS / PowerShell | Windows, Windows PowerShell 5.1 (oder 7.x) – WinForms |
| Modul | `Microsoft.Graph.Authentication` (`Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`) |
| Graph-Rechte (delegiert) | Apps: `DeviceManagementApps.ReadWrite.All`, `Group.Read.All` – dieselben wie beim Bulk App Assignment Tool, also kein neuer Zustimmungsdialog. Jede andere Kategorie: zusätzlich `DeviceManagementConfiguration.ReadWrite.All`, angefordert erst beim ersten Öffnen einer solchen Kategorie (einmaliger Zustimmungsdialog). „Filternamen laden" ohne weitere Kategorie: `DeviceManagementConfiguration.Read.All` |

Anmeldung interaktiv mit dem eigenen Konto (`Connect-MgGraph`), keine App-Registrierung.

## Start

```powershell
Unblock-File .\Manage-GroupAppAssignment.ps1
.\Manage-GroupAppAssignment.ps1                                # Ziel im Fenster wählen
.\Manage-GroupAppAssignment.ps1 -GroupId <Objekt-ID>           # direkt diese Gruppe
.\Manage-GroupAppAssignment.ps1 -GroupId AllUsers              # oder AllDevices
.\Manage-GroupAppAssignment.ps1 -Platform All                  # alle Plattformen statt iOS
```

oder `Start-GroupAppAssignment.bat` doppelklicken (Parameter werden durchgereicht).

| Parameter | Standard | Bedeutung | im Fenster |
|---|---|---|---|
| `-GroupId` | – | Gruppen-Objekt-ID, `AllUsers` oder `AllDevices` | `...`-Button |
| `-TenantId` | – | Tenant für `Connect-MgGraph` | – (Anmeldedialog) |
| `-Platform` | `iOS` | `iOS` \| `macOS` \| `Android` \| `Windows` \| `All` | Liste „Plattform" |
| `-VppDeviceLicensing` | `$true` | Lizenztyp für **neue** VPP-Zuweisungen (`iosVppApp`, `macOsVppApp`): Gerät / Benutzer | Checkbox „VPP neu: Gerätelizenz" |
| `-LoadFilterNames` | aus | Namen der Zuweisungsfilter statt ihrer IDs anzeigen (Recht siehe oben); ist das Häkchen beim Verbinden noch nicht gesetzt, wird beim Anhaken neu verbunden | Checkbox „Filternamen laden" |
| `-Language` | `auto` | `auto` \| `de` \| `en` | – |

## Verhalten im Detail

- **Einzeln schreiben:** neu `POST …/assignments`, entfernen `DELETE …/assignments/{id}`.
  **Modus/Ausschluss ändern:** `DELETE` + `POST` (ein Ziel kann pro Objekt nur einmal zugewiesen sein).
  Filter und Einstellungen (z. B. Win32-Benachrichtigungen, VPP-Lizenztyp; bei Konfigurationsprofilen
  `apply`/`remove`) der alten Zuweisung werden übernommen, solange es ein Einschluss bleibt; ein Ausschluss
  hat beides nicht. Scheitert das `POST`, wird die alte Zuweisung wiederhergestellt – und gemeldet, falls
  auch das scheitert.
- **Richtliniensätze (Policy Sets):** Zuweisungen mit `source = policySets` werden grau und
  schreibgeschützt angezeigt („Richtliniensatz"); das Tool ändert oder löscht sie nicht und schickt sie bei
  einer Gesamtliste auch nicht mit. Gibt es für dasselbe Ziel eine direkte und eine Policy-Set-Zuweisung,
  zeigt es die direkte.
- **Vorab abgelehnt:** Ausschluss für Alle Benutzer/Alle Geräte, „Verfügbar" an Alle Geräte,
  App-Schutz und MAM-App-Konfiguration an Alle Geräte (gelten nur für Benutzer; ob eine *Gruppe* Benutzer
  oder Geräte enthält, prüft Intune beim Speichern).
  Alles andere prüft Intune selbst (z. B. „Verfügbar" an eine Gerätegruppe) – die Fehlermeldung von
  Graph wird pro Objekt angezeigt.
- **Neue App-Ausschlüsse** bekommen den Modus „Erforderlich"; im Grid änderbar.
- **Laden** lädt Apps und jede schon geöffnete Kategorie neu.
- Ungespeicherte Änderungen: Rückfrage beim Schließen, Neuladen und Gruppenwechsel.

## Grenzen / Annahmen

- Es zählt nur die **direkte** Zuweisung an die Gruppe. Verschachtelte Gruppen (die Gruppe ist Mitglied
  einer zugewiesenen Gruppe) werden **nicht** aufgelöst.
- `$expand=assignments` auf den Listen steht nicht in den dokumentierten Abfrageoptionen; fehlt die
  Erweiterung in der Antwort, liest das Tool die Zuweisungen Objekt für Objekt (langsamer, aber korrekt).
- **Einstellungskatalog:** Die Ressourcenseite nennt Einzel-Anlegen/-Löschen und `/assign`, die
  Methodenseiten dazu fehlen in der Doku. Das Tool nutzt `/assign` (Gesamtliste, wie das Portal) – Annahme.
- Pfade, Zuweisungstypen, `intent`-Werte, Ziel-Typen, `source` und `useDeviceLicensing` sind gegen die
  Graph-beta-Doku (Quelle: `microsoftgraph/microsoft-graph-docs-contrib`) geprüft. Die Oberfläche lief bei
  der Entwicklung nicht (kein Windows); geprüft ist die Logik über das Testskript.

## Tests

```powershell
.\Test-GroupAppAssignment.ps1     # Exit-Code 0 = alles grün; kein Graph, keine GUI, kein Pester
```

Prüft:
- **statisch:** UTF-8-BOM jeder `.ps1`, Parsbarkeit, keine PS-7-only-Operatoren (`??`, `?.`, `?:`, `&&`,
  `||`), `AddRange(@(...))` nur auf `.Controls`;
- **Logik:** Kategorien-Tabelle vollständig (Pfade, Schreibweg, Zuweisungstyp, Modus nur bei Apps),
  Plattform-Erkennung, angeforderte Graph-Rechte, Ziel-Zuordnung inkl. Policy-Set-Vorrang, Request-Bodies
  (Ein-/Ausschluss, VPP-Lizenz, Filter/Settings-Übernahme, `apply`/`remove`), Zielregeln, Plan, Sortierung;
- **Graph mit nachgebildetem `Invoke-MgGraphRequest`:** Laden mit und ohne `$expand`, Paging, Zurücklesen
  (0/1/2 Zuweisungen), Schreiben einzeln (`DELETE` + `POST`, Wiederherstellung bei Fehler) und als
  Gesamtliste (frisch gelesen, andere Ziele samt Filter bleiben, Policy-Set-Einträge nicht mitgeschickt).

Das Skript lädt nur den GUI-freien Teil von `Manage-GroupAppAssignment.ps1` bis zur Markerzeile
`# ---- end of the GUI-free part`.

Alle `.ps1` sind UTF-8 mit BOM, CRLF per `.gitattributes` im Repo-Wurzelverzeichnis.
