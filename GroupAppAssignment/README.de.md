# GroupAppAssignment – Intune-Zuweisungen aus Sicht der Gruppe

*[English](README.md) · Deutsch*

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
- **Kategorie links** (Icons wie im Intune-Portal, darunter „zugewiesen / gesamt" für die gewählte
  Plattform, `(...)` = noch nicht geladen) bestimmt, was in der Mitte und rechts steht. Eine Kategorie wird
  beim ersten Öffnen geladen.
- **Mitte:** alle Objekte der Kategorie, die dem Ziel *nicht* zugewiesen sind – als sortierbare Tabelle wie
  rechts.
- **Rechts:** alle, die ihm zugewiesen sind – bei Apps mit **Modus** (Erforderlich / Verfügbar /
  Deinstallieren / Verfügbar ohne Registrierung), bei allen mit **Ausschluss** und **Filter**.
- **Buttons** passen sich an: Apps `Erforderlich >` `Verfügbar >` `Deinstallieren >` `Ausschließen >`,
  alle anderen Kategorien `Zuweisen >` `Ausschließen >`, dazu `< Entfernen`. Doppelklick in der Mitte =
  Erforderlich bzw. Zuweisen. In **„Alle"** nur ansehen und entfernen (Spalte *Kategorie* kommt dazu).
- **Plattform** oben (Standard iOS/iPadOS) grenzt alle Kategorien ein; Objekte ohne eigene Plattform
  (Web-Apps, …) erscheinen immer. Suche und Typ-Filter wirken auf Mitte und rechts.
- Klick auf eine Spaltenüberschrift rechts sortiert danach (erneut: absteigend), bei gleichem Wert nach Name.
- Bei Apps (und „Alle") zeigen beide Seiten eine Spalte **Herausgeber**, bei Plattform Windows (oder Alle)
  zusätzlich **Version** (`displayVersion` bei Win32, `productVersion` bei MSI, `identityVersion` bei
  AppX/MSIX; Store-, WinGet-, Office- und Edge-Apps haben keine).
- Lange Namen: Mitte und rechts lassen sich waagerecht scrollen; die Namensspalte rechts wächst mit dem
  längsten Namen. „Nicht zugewiesen" und „Zugewiesen" sind gleich breit.
- Farben: rechts grün = neu, gelb = geändert; in der Mitte rot mit „wird entfernt" = Zuweisung wird gelöscht.
- Ein grüner Haken neben „Verbunden: …" zeigt, dass die Anmeldung geklappt hat.
- **Speichern** zeigt alle Änderungen über alle Kategorien, schreibt sie und **liest danach jedes
  berührte Objekt aus Intune zurück** – die Anzeige zeigt den echten Ist-Stand, Abweichungen werden gemeldet.

Es wird nur die Zuweisung **für das gewählte Ziel** angefasst; alle anderen Zuweisungen eines Objekts
bleiben unverändert. Oberfläche zweisprachig: **Englisch** als Standard, **Deutsch** automatisch bei deutscher
Windows-Anzeigesprache (`de-*`); `-Language en|de` erzwingt eine Sprache.

Die Kategorie-Icons stammen aus [IntuneManagement](https://github.com/Micke-K/IntuneManagement) (MIT) und
zeigen die Intune-Portal-Icons von Microsoft – siehe `THIRD-PARTY-NOTICES.md`.

## Kategorien

| Kategorie | Graph (beta) | Schreiben |
|---|---|---|
| Apps | `deviceAppManagement/mobileApps` | einzeln (`POST`/`DELETE …/assignments`) |
| Konfigurationsprofile – Vorlagen (Geräteeinschränkungen, WLAN, VPN, Zertifikate, iOS-Update, …) | `deviceManagement/deviceConfigurations` | einzeln |
| Konfigurationsprofile – Einstellungskatalog (inkl. Declarative Software Update) | `deviceManagement/configurationPolicies` | Gesamtliste (`…/assign`) |
| Compliance | `deviceManagement/deviceCompliancePolicies` | Gesamtliste (`…/assign`) |
| App-Konfiguration (verwaltete Geräte) | `deviceAppManagement/mobileAppConfigurations` | Gesamtliste (`…/assign`) |
| App-Konfiguration (verwaltete Apps, MAM) – nur Benutzer | `deviceAppManagement/targetedManagedAppConfigurations` | Gesamtliste (`…/assign`) |
| App-Schutz (iOS, Android, Windows) – nur Benutzer | `deviceAppManagement/{ios,android,windows}ManagedAppProtections` | Gesamtliste (`…/{id}/assign`) |
| Richtliniensätze (der Satz selbst; sein Inhalt erscheint schreibgeschützt in den anderen Kategorien) | `deviceAppManagement/policySets` | Gesamtliste (`…/update`), gelesen per `?$expand=assignments` |

**Gesamtliste** heißt: Das Tool liest die Zuweisungsliste des Objekts unmittelbar vor dem Schreiben frisch,
ändert nur den Eintrag des gewählten Ziels und schickt die Liste zurück. Alle anderen Ziele gehen mit
ihrem Filter unverändert mit; das prüft das Testskript ausdrücklich und es ist live bestätigt (siehe unten).

**Live geprüft** (Test-Tenant, 2026-09) – und dabei von der Graph-Doku abweichend:
- Compliance und App-Konfiguration (Geräte): das dokumentierte `POST …/assignments` hat im Dienst keine
  Route („No OData route exists“) – nur `/assign` funktioniert.
- App-Schutz: das dokumentierte `managedAppPolicies/{id}/assign` antwortet „Resource not found for the
  segment 'assign'“ – `iosManagedAppProtections/{id}/assign` (bzw. android/windows) funktioniert.
- Richtliniensätze: weder `GET` noch `POST …/assignments` existieren, die Liste erlaubt kein `$expand` –
  gelesen wird je Satz über `?$expand=assignments`, geschrieben über `/update`.
- App-Schutz und Richtliniensätze: Mit `$select` liefert Graph bei diesen Listen kein `@odata.type` – Typ und
  Plattform kommen aus der Liste, aus der das Objekt gelesen wurde.
- **MAM (App-Schutz, MAM-App-Konfiguration) ist nur verzögert konsistent:** Nach `/assign` erscheinen
  Einschlüsse sofort, **Ausschlüsse aber minutenlang nur zeitweise** – gemessen: nach dem Setzen eines
  Ausschlusses zeigten 11 von 13 Lesungen über 2 Minuten ihn nicht an, auch zwei Lesungen hintereinander waren
  veraltet. Ein Gesamtlisten-Schreibvorgang auf Basis einer solchen Lesung hat im Test den Ausschluss
  gelöscht. Ein Schreiben kurz nach einer Änderung scheitert außerdem vorübergehend mit
  `ConditionNotMet`/`ResourceNotFound`. Das Tool deshalb bei MAM-Objekten:
  - merkt sich die zuletzt **selbst gesendete** Liste 10 Minuten lang und baut den nächsten Schreibvorgang
    darauf auf statt auf einer Lesung; Laden und Zurücklesen zeigen in dieser Zeit ebenfalls den gesendeten Stand;
  - liest sonst erst, wenn zwei Lesungen im Abstand von 5 s übereinstimmen;
  - wiederholt den Gesamtlisten-Schreibvorgang bei den genannten Fehlern (bis zu 5 Versuche);
  - wartet beim Zurücklesen bis zu 60 s; zeigt Intune den Stand dann noch nicht, meldet es das als Hinweis
    („noch nicht überall sichtbar"), nicht als Fehler.

  **Grenze:** Ändert *jemand anderes* (Portal, anderes Tool) Ausschlüsse desselben MAM-Objekts, kann das Tool
  das in den ersten Minuten danach nicht zuverlässig sehen – und dieselbe Lücke hat jeder Gesamtlisten-Schreiber,
  auch ein Skript. Zwischen zwei Bearbeitern desselben MAM-Objekts ein paar Minuten Abstand lassen.

## Voraussetzungen

| | |
|---|---|
| OS / PowerShell | Windows, Windows PowerShell 5.1 (oder 7.x) – WinForms |
| Modul | `Microsoft.Graph.Authentication` (`Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`) |
| Graph-Rechte (delegiert) | Apps: `DeviceManagementApps.ReadWrite.All`, `Group.Read.All` – dieselben wie beim Bulk App Assignment Tool, also kein neuer Zustimmungsdialog. Jede andere Kategorie: zusätzlich `DeviceManagementConfiguration.ReadWrite.All`, angefordert erst beim ersten Öffnen einer solchen Kategorie (einmaliger Zustimmungsdialog). „Filternamen laden" ohne weitere Kategorie: `DeviceManagementConfiguration.Read.All` |

Anmeldung interaktiv mit dem eigenen Konto (`Connect-MgGraph`), keine App-Registrierung.
**Konto wechseln:** `Connect-MgGraph` merkt sich die Anmeldung pro Windows-Benutzer und meldet beim nächsten Mal
ohne Rückfrage mit demselben Konto an – „Neu verbinden" bleibt daher beim selben Konto. **„Abmelden"** ruft
`Disconnect-MgGraph` auf (löscht diese gespeicherte Anmeldung und den Token-Cache) und verwirft alle geladenen
Daten; beim nächsten „Verbinden" lässt sich ein anderes Konto wählen. Andere Anwendungen, die das Windows-Konto
nutzen, bleiben angemeldet (kein `-SignOutFromBroker`).

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
- **Einstellungskatalog:** `/assign` (Gesamtliste, wie das Portal) – live bestätigt.
- **Gesamtliste ohne Richtliniensatz-Einträge:** Dass `/assign` Zuweisungen aus Richtliniensätzen unberührt
  lässt, wenn sie nicht mitgeschickt werden, ist eine Annahme (die Doku sagt dazu nichts).
- **Richtliniensätze:** Ausschlüsse nimmt Intune an – live bestätigt.
- Pfade, Zuweisungstypen, `intent`-Werte, Ziel-Typen, `source` und `useDeviceLicensing` sind gegen die
  Graph-beta-Doku (Quelle: `microsoftgraph/microsoft-graph-docs-contrib`) geprüft und – wo sie abweicht –
  nach dem Live-Test korrigiert. Die Graph-Logik (Laden, Schreiben einzeln und als Gesamtliste, Zurücklesen)
  lief live gegen einen Test-Tenant; die WinForms-Oberfläche selbst lief bei der Entwicklung nicht (kein Windows).

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
  Gesamtliste (frisch gelesen, andere Ziele samt Filter bleiben, Policy-Set-Einträge nicht mitgeschickt);
- **MAM:** stabiles Lesen, Wiederholen bei `ConditionNotMet`, Warten beim Zurücklesen, zuletzt gesendete
  Liste statt veralteter Lesung;
- **Oberfläche ohne Ausführung:** jeder sichtbare Text kommt aus den de/en-Tabellen (beide vollständig, kein
  fest verdrahteter Text), Sprachwahl, ein 48-px-Icon je Kategorie, kein Funktionsname kollidiert mit einem
  Befehl oder Alias von `Microsoft.Graph.Authentication`, Abmelden ruft `Disconnect-MgGraph`.

Das Skript lädt nur den GUI-freien Teil von `Manage-GroupAppAssignment.ps1` bis zur Markerzeile
`# ---- end of the GUI-free part`.

Alle `.ps1` sind UTF-8 mit BOM, CRLF per `.gitattributes` im Repo-Wurzelverzeichnis.

## Ausblick: plattformübergreifende Oberfläche (Idee, noch nicht umgesetzt)

Die Oberfläche ist WinForms und läuft daher nur unter Windows. Alles oberhalb der Markerzeile ist frei von
WinForms und lief bereits unter PowerShell 7 auf Linux live gegen einen Tenant.

**Vorschlag:** eine lokale Web-Oberfläche statt WinForms.
- Das Skript startet einen kleinen HTTP-Server nur auf `127.0.0.1` mit zufälligem Port und öffnet den Browser.
  Das funktioniert unter Windows, macOS und Linux.
- Die Seite hat denselben Aufbau wie jetzt und ruft nur wenige JSON-Endpunkte auf, die direkt die vorhandenen
  Funktionen nutzen. Die Intune-Logik bleibt in PowerShell, nichts davon wird in JavaScript nachgebaut.
- Die Anmeldung läuft wie bisher über `Connect-MgGraph`, ohne Desktop-Browser über den Gerätecode.
  Das Graph-Token bleibt im PowerShell-Prozess.
- Absicherung: Einmal-Token in der Start-URL, Anfragen ohne Token oder von fremdem Origin werden abgelehnt.
- Für Windows PowerShell 5.1 ohne Adminrechte einen einfachen TCP-Listener statt `HttpListener` nehmen.
  Ob `HttpListener` unter 5.1 ohne URL-Reservierung läuft, ist ungeprüft.
- Den Kern in eine gemeinsame Datei auslagern, die WinForms- und Web-Oberfläche beide nutzen. So gibt es nur
  einen Schreibweg. WinForms behalten, bis die Web-Oberfläche erprobt ist.

**Warum:** Neben der Plattformfrage lässt sich eine Web-Oberfläche automatisch mit Playwright durchklicken,
mit nachgebildetem Graph oder live. Die bisherigen Laufzeitfehler (`Columns.AddRange` unter 5.1, `@()` auf
`List[object]`, Alias `Connect-Graph`) saßen genau in der Oberfläche, die sich bisher nicht automatisch testen ließ.

**Verworfen:** Avalonia für PowerShell (Anbindung zu unreif), Konsolen-Oberfläche mit Terminal.Gui (zu eng für
vier Listen mit Grid), reine Browser-App mit MSAL.js (bräuchte eine eigene App-Registrierung, und die Logik
müsste in JavaScript ohne die vorhandenen Tests neu entstehen).
