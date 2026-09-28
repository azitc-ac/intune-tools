# intune-tools

Zwei handgeschriebene PowerShell-Werkzeuge für Microsoft Intune:

- **IntuneWin32Helper** — schnürt Win32-Pakete (PSADT 4 oder WinGet) und lädt sie nach Intune.
- **GroupAppAssignment** — weist Apps Gruppen zu.

Antworten auf Deutsch (echte Umlaute), Fachbegriffe und Cmdlets bleiben englisch.
Die allgemeinen Arbeitsprinzipien liegen im Repo `azitc-ac/cloud-sessions`
(`.claude/principles.md`) — sie sind hier absichtlich nicht kopiert, damit es keine
zweite, driftende Fassung gibt.

## Harte Regeln

- **Jede `.ps1` als UTF-8 *mit* BOM speichern.** Ohne BOM zerlegt Windows PowerShell 5.1
  Umlaute. `.githooks/*` und `*.sh` dagegen **ohne** BOM — dort zerstört ein BOM den
  Shebang. Beides erzwingt `Tests/Invoke-RepoChecks.ps1`.
- **Alles muss unter Windows PowerShell 5.1 laufen.** Keine PS7-Syntax (`??`, `?.`,
  ternäres `? :`, `-Parallel`). Auch das ist ein Check.
- **Vor jedem Commit `IntuneWin32Helper/Tests/Invoke-RepoChecks.ps1` laufen lassen.**
  Der pre-commit-Hook tut das selbst, sobald die Hooks aktiv sind — einmal pro Clone:
  `git config core.hooksPath .githooks`
- **`Config/config.json` gehört nicht ins Repo** — enthält `clientSecret` im Klartext.
  Versioniert ist nur `Config/config.sample.json`.

Weitere Konventionen (VERSION pro Tool, CRLF, Hook-Verhalten) stehen im `README.md`.

## Zum Zustand — wichtig für jede neue Session

`main` ist **strukturell grün, aber nicht im Feld belegt.** Die 105 Prüfungen in
`Invoke-RepoChecks.ps1` beweisen, dass geparst wird und die Struktur stimmt — **nicht**,
dass Intune einen Aufruf annimmt oder ein Paket auf einem Client installiert.

Der letzte Stand mit Transcript-Beleg ist der Tag `IntuneWin32Helper-v2.0.0`.
Was dort belegt ist, was seither dazukam und was noch gegen echte Hardware zu prüfen
ist, steht in [RELEASES.md](RELEASES.md) — mit der Liste der offenen Feldprüfungen.

Ein grüner Prüflauf ist **kein** Feldbeleg. Belegt ist, was ein Transcript, ein
IME-Log oder das Intune-Portal zeigt.

## Neue Regel, neuer Check

Jede Lektion, die sich wiederholen könnte, gehört als Prüfung nach
`Tests/Invoke-RepoChecks.ps1` — und die Prüfung ist erst fertig, wenn sie beim
**Rückbau des Fehlers fehlschlägt**. Ein grüner Lauf nach einer Mutation, die nie
stattfand, beweist das Gegenteil.
