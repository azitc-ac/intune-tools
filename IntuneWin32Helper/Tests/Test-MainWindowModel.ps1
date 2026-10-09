<#
    .SYNOPSIS
    Verhaltenstest: das Modell hinter dem Hauptfenster - Inventarzeilen und
    Apps.csv - ohne GUI, ohne Tenant, ohne Netz.

    .DESCRIPTION
    Das Hauptfenster zeigt pro App eine Zeile und bietet Aktionen an, die vom
    Zustand der Zeile abhaengen. Das gilt nur, wenn die Zeile den Zustand richtig
    traegt, und wenn Apps.csv beim Bearbeiten nichts verliert. Beides wird hier
    gegen echte Dateien in %TEMP% geprueft:

      1. Status, Schluessel und Wahrheitswerte jeder Zeile (Definition ohne Paket,
         Paket aktuell, Paket mit veralteter Vorlage, Paket ohne Definition);
         der Datensatz in der Zeile ist derselbe Verweis wie in der Eingabe -
         Bearbeiten und Loeschen finden die Zeile darueber wieder.
      2. Apps.csv: lesen -> speichern -> lesen verliert keinen Wert, keine Spalte
         (auch keine eigene) und nicht das Format (BOM, Kopfzeile). Werte mit
         Semikolon, Anfuehrungszeichen und Umlauten ueberleben.
      3. Test-AppRecord lehnt leeren Namen, leere Version und doppelte Schluessel ab.

    Das ist ein Modelltest. Dass das Fenster diese Zeilen richtig zeigt, prueft
    Test-MainWindowUi.ps1.
#>
$ErrorActionPreference = 'Stop'

$rootDir = Split-Path -Parent $PSScriptRoot
$functionsPath = Join-Path $rootDir 'Functions\functions.ps1'

# Alle Funktionsdefinitionen laden, aber keinen Code auf oberster Ebene.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($functionsPath, [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}

$problems = @()
$current = Get-TemplateFingerprint -RootDir $rootDir
if (-not $current) { $problems += "setup: no template fingerprint for $rootDir" }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('iw32h-model-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $work
try {
    # ------------------------------------------------------------------ 1) Zeilen
    $packets = Join-Path $work 'packets'
    $null = New-Item -ItemType Directory -Force -Path $packets

    function New-TestPackage([string]$name, [string]$stampLine) {
        $folder = Join-Path $packets "$name - 1.0"
        $null = New-Item -ItemType Directory -Force -Path $folder
        Write-DeployScript -AppFolder $folder -AppName $name -AppVersion '1.0' -Publisher 'Test' -Description 'Installed using PSADT' `
            -RootDir $rootDir -ToolVersion '0.0.1' -Architecture 'x64' -MinimumOS 'W10_20H2' -MsiProductCode '' 6>$null
        $path = Join-Path $folder 'deploy.ps1'
        $text = [IO.File]::ReadAllText($path)
        $text = [regex]::Replace($text, '(?m)^#\s*ToolTemplateFingerprint:.*$', $stampLine)
        [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $true))
    }
    New-TestPackage 'WithPkg' ("# ToolTemplateFingerprint: $current")
    New-TestPackage 'Old'     '# ToolTemplateFingerprint: 000000000000'
    New-TestPackage 'Orphan'  ("# ToolTemplateFingerprint: $current")

    $defs = @(
        [pscustomobject]@{ DisplayName = 'DefOnly'; Version = '1.0'; Publisher = 'P1' },
        [pscustomobject]@{ DisplayName = 'WithPkg'; Version = '1.0'; Publisher = 'P2' },
        [pscustomobject]@{ DisplayName = 'Old';     Version = '1.0'; Publisher = 'P3' }
    )
    $tenantApps = @([pscustomobject]@{ displayName = 'WithPkg'; publishingState = 'published'; committedContentVersion = '1' })

    $inv = @(Get-AppInventory -Definitions $defs -PacketRoot $packets -RootDir $rootDir -IntuneApps $tenantApps 6>$null)
    $row = @{}; foreach ($x in $inv) { $row[$x.AppName] = $x }

    foreach ($name in 'DefOnly', 'WithPkg', 'Old', 'Orphan') {
        if (-not $row.ContainsKey($name)) { $problems += "row $name is missing from the inventory"; continue }
        if ($row[$name].Key -ne "$name - 1.0") { $problems += "row $name : Key '$($row[$name].Key)'" }
    }
    if ($problems.Count -eq 0) {
        $d = $row['DefOnly']
        if ($d.Status -ne 'Definition only')       { $problems += "DefOnly: Status '$($d.Status)'" }
        if (-not $d.HasDefinition -or $d.HasPackage) { $problems += "DefOnly: HasDefinition=$($d.HasDefinition) HasPackage=$($d.HasPackage)" }
        if ($d.Publisher -ne 'P1')                 { $problems += "DefOnly: Publisher '$($d.Publisher)'" }
        if ($d.Next -ne 'create package')          { $problems += "DefOnly: Next '$($d.Next)'" }
        if (-not [object]::ReferenceEquals($d.DefinitionRecord, $defs[0])) { $problems += "DefOnly: DefinitionRecord is not the input record (edit/delete could not find the row again)" }

        $w = $row['WithPkg']
        if ($w.Status -ne 'Package')               { $problems += "WithPkg: Status '$($w.Status)'" }
        if (-not $w.HasDefinition -or -not $w.HasPackage) { $problems += "WithPkg: flags HasDefinition=$($w.HasDefinition) HasPackage=$($w.HasPackage)" }
        if ($w.FullPath -notmatch 'deploy\.ps1$')  { $problems += "WithPkg: FullPath '$($w.FullPath)'" }
        if ($w.Intune -ne 'yes')                   { $problems += "WithPkg: Intune '$($w.Intune)'" }

        $o = $row['Old']
        if ($o.Status -ne 'Package, template outdated') { $problems += "Old: Status '$($o.Status)'" }

        $x = $row['Orphan']
        if ($x.Status -ne 'No definition')         { $problems += "Orphan: Status '$($x.Status)'" }
        if ($x.HasDefinition -or -not $x.HasPackage) { $problems += "Orphan: flags HasDefinition=$($x.HasDefinition) HasPackage=$($x.HasPackage)" }
        if ($null -ne $x.DefinitionRecord)         { $problems += "Orphan: DefinitionRecord should be null" }
        if ($x.Next -notmatch 'without a row in Apps\.csv') { $problems += "Orphan: Next '$($x.Next)'" }

        foreach ($label in 'Definition:', 'Package:', 'Template:', 'Intune:', 'Next:') {
            if ($w.Detail -notmatch [regex]::Escape($label)) { $problems += "WithPkg: tooltip lacks '$label'" }
        }
    }

    # Tenant nicht gelesen ist etwas anderes als "nicht vorhanden".
    $offline = @(Get-AppInventory -Definitions $defs -PacketRoot $packets -RootDir $rootDir -IntuneApps $null 6>$null)
    if (@($offline | Where-Object { $_.Intune -ne 'not checked' }).Count -gt 0) { $problems += "offline: Intune column should read 'not checked' when the tenant was not read" }

    # ------------------------------------------------------------------ 2) Apps.csv
    $realCsv = Join-Path $rootDir 'Apps.csv'
    $rootA = Join-Path $work 'rootA'; $rootB = Join-Path $work 'rootB'
    $null = New-Item -ItemType Directory -Force -Path $rootA, $rootB
    Copy-Item -LiteralPath $realCsv -Destination (Join-Path $rootA 'Apps.csv')

    $original = @(Read-AppsCsv -RootDir $rootA)
    if ($original.Count -eq 0) { $problems += "setup: the real Apps.csv has no rows" }
    Save-AppsCsv -RootDir $rootB -Rows $original
    $again = @(Read-AppsCsv -RootDir $rootB)
    if ($again.Count -ne $original.Count) { $problems += "Apps.csv roundtrip: $($original.Count) rows in, $($again.Count) out" }

    $byKey = @{}; foreach ($r in $again) { $byKey['{0}|{1}' -f $r.DisplayName, $r.Version] = $r }
    foreach ($r in $original) {
        $k = '{0}|{1}' -f $r.DisplayName, $r.Version
        if (-not $byKey.ContainsKey($k)) { $problems += "Apps.csv roundtrip: row lost: $k"; continue }
        foreach ($col in $r.PSObject.Properties.Name) {
            if ([string]$r.$col -ne [string]$byKey[$k].$col) { $problems += "Apps.csv roundtrip: $k column $col changed: '$($r.$col)' -> '$($byKey[$k].$col)'" }
        }
    }

    $bytes = [IO.File]::ReadAllBytes((Join-Path $rootB 'Apps.csv'))
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) { $problems += "Apps.csv: saved without UTF-8 BOM" }
    $headerOld = ([IO.File]::ReadAllLines((Join-Path $rootA 'Apps.csv'), [Text.Encoding]::UTF8))[0].TrimStart([char]0xFEFF)
    $headerNew = ([IO.File]::ReadAllLines((Join-Path $rootB 'Apps.csv'), [Text.Encoding]::UTF8))[0].TrimStart([char]0xFEFF)
    if ($headerOld -ne $headerNew) { $problems += "Apps.csv: header changed on save: '$headerOld' -> '$headerNew'" }

    # Werte mit Trennzeichen, Anfuehrungszeichen, Umlauten; eigene Spalte.
    $nasty = [pscustomobject]@{ DisplayName = 'Zett;Ae "x" Aerger'; Version = '1.0'; InstallCmd = 'a;b "c" Pr' + [char]0xFC + 'fung'; MyColumn = 'keep me' }
    Save-AppsCsv -RootDir $rootB -Rows @($nasty)
    $back = @(Read-AppsCsv -RootDir $rootB)
    if ($back.Count -ne 1)                        { $problems += "special values: $($back.Count) rows back" }
    elseif ($back[0].DisplayName -ne $nasty.DisplayName -or $back[0].InstallCmd -ne $nasty.InstallCmd) { $problems += "special values changed: '$($back[0].DisplayName)' / '$($back[0].InstallCmd)'" }
    elseif ($back[0].MyColumn -ne 'keep me')      { $problems += "own column MyColumn lost on save" }
    if ((Get-AppsCsvColumns -Definitions @($nasty)) -notcontains 'MyColumn') { $problems += "Get-AppsCsvColumns: own column not offered to the editor" }

    # Reihenfolge: nach Name sortiert, gleiche Namen behalten ihre Eingabereihenfolge. Ein zweiter
    # Sortierschluessel (Version) vertauschte frueher zwei Zeilen gleichen Namens bei jedem Speichern
    # ("LatestAvailable" vor "140.0" wurde zu "140.0" vor "LatestAvailable") - Rauschen im git diff.
    $orderRows = @(
        [pscustomobject]@{ DisplayName = 'Zed';   Version = 'LatestAvailable' },
        [pscustomobject]@{ DisplayName = 'Alpha'; Version = '1.0' },
        [pscustomobject]@{ DisplayName = 'Zed';   Version = '140.0' }
    )
    Save-AppsCsv -RootDir $rootB -Rows $orderRows
    $sorted = @(Read-AppsCsv -RootDir $rootB | ForEach-Object { '{0}|{1}' -f $_.DisplayName, $_.Version })
    if (($sorted -join ';') -ne 'Alpha|1.0;Zed|LatestAvailable;Zed|140.0') { $problems += "Apps.csv order: expected 'Alpha|1.0;Zed|LatestAvailable;Zed|140.0', got '$($sorted -join ';')'" }
    Save-AppsCsv -RootDir $rootB -Rows @(Read-AppsCsv -RootDir $rootB)
    $sortedAgain = @(Read-AppsCsv -RootDir $rootB | ForEach-Object { '{0}|{1}' -f $_.DisplayName, $_.Version })
    if (($sortedAgain -join ';') -ne ($sorted -join ';')) { $problems += "Apps.csv order changes when saved again unchanged: '$($sortedAgain -join ';')'" }

    # Leere Liste: die Datei behaelt ihre Kopfzeile, sonst waere sie nicht mehr lesbar/erweiterbar.
    Save-AppsCsv -RootDir $rootB -Rows @()
    $line = ([IO.File]::ReadAllLines((Join-Path $rootB 'Apps.csv'), [Text.Encoding]::UTF8))[0]
    if ($line -notmatch 'DisplayName')            { $problems += "empty Apps.csv lost its header line: '$line'" }
    if (@(Read-AppsCsv -RootDir $rootB).Count -ne 0) { $problems += "empty Apps.csv reads back with rows" }

    # ------------------------------------------------------------------ 3) Test-AppRecord
    $others = @([pscustomobject]@{ DisplayName = 'Taken'; Version = '2.0' })
    if (-not (Test-AppRecord -Record ([pscustomobject]@{ DisplayName = '';      Version = '1.0' }) -Others $others)) { $problems += "Test-AppRecord accepts an empty name" }
    if (-not (Test-AppRecord -Record ([pscustomobject]@{ DisplayName = 'X';     Version = '  ' }) -Others $others)) { $problems += "Test-AppRecord accepts an empty version" }
    if (-not (Test-AppRecord -Record ([pscustomobject]@{ DisplayName = 'Taken'; Version = '2.0' }) -Others $others)) { $problems += "Test-AppRecord accepts a duplicate Name+Version" }
    if (Test-AppRecord -Record ([pscustomobject]@{ DisplayName = 'Taken'; Version = '3.0' }) -Others $others)       { $problems += "Test-AppRecord rejects a new version of an existing app" }

    # ------------------------------------------------------------------ 4) verwaiste Ordner
    # Frisches Inventar: DefOnly (nur Definition), WithPkg und Old (Definition + Paket), Orphan (Paket ohne Definition).
    $inv2 = @(Get-AppInventory -Definitions $defs -PacketRoot $packets -RootDir $rootDir -IntuneApps $null 6>$null)

    # Zusaetzliche Zeilen, an denen die Schutzregeln greifen muessen.
    $weird = Join-Path $packets 'weird-folder'                       # Name ist nicht "<Name> - <Version>"
    $noScript = Join-Path $packets 'NoScript - 1.0'                  # kein deploy.ps1
    $outside = Join-Path $work 'outside\Outside - 1.0'               # ausserhalb der Wurzel
    foreach ($dir in $weird, $noScript, $outside) { $null = New-Item -ItemType Directory -Force -Path $dir }
    foreach ($file in (Join-Path $weird 'deploy.ps1'), (Join-Path $outside 'deploy.ps1')) { Set-Content -LiteralPath $file -Value '# test' }
    function New-FakeRow([string]$key, [string]$folder, [bool]$hasScript) {
        [pscustomobject]@{ Key = $key; HasDefinition = $false; HasPackage = $true; FullPath = (Join-Path $folder 'deploy.ps1') }
    }
    $extra = @(
        (New-FakeRow 'weird - 1'          $weird    $true),
        (New-FakeRow 'NoScript - 1.0'     $noScript $false),
        (New-FakeRow 'Outside - 1.0'      $outside  $true)
    )

    # ALLE Zeilen uebergeben, auch die mit Definition: der Schutz liegt in der Funktion, nicht im Knopf.
    $outcome = Remove-OrphanPackages -Rows (@($inv2) + $extra) -PacketRoot $packets 6>$null
    $orphanFolder = Join-Path $packets 'Orphan - 1.0'
    if (Test-Path -LiteralPath $orphanFolder)                 { $problems += "orphans: the orphan folder 'Orphan - 1.0' was not removed" }
    if (@($outcome.Removed) -notcontains 'Orphan - 1.0')      { $problems += "orphans: Removed does not list 'Orphan - 1.0': $(@($outcome.Removed) -join ', ')" }
    if (@($outcome.Removed).Count -ne 1)                      { $problems += "orphans: expected exactly 1 removed, got $(@($outcome.Removed).Count): $(@($outcome.Removed) -join ', ')" }
    foreach ($keep in 'WithPkg - 1.0', 'Old - 1.0') {
        if (-not (Test-Path -LiteralPath (Join-Path $packets $keep))) { $problems += "orphans: '$keep' HAS a definition and was deleted" }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $packets 'WithPkg - 1.0\deploy.ps1'))) { $problems += "orphans: deploy.ps1 of a defined package is gone" }
    if (-not (Test-Path -LiteralPath $weird))                 { $problems += "orphans: folder not named '<Name> - <Version>' was deleted" }
    if (-not (Test-Path -LiteralPath $noScript))              { $problems += "orphans: folder without deploy.ps1 was deleted" }
    if (-not (Test-Path -LiteralPath $outside))               { $problems += "orphans: folder OUTSIDE the package root was deleted" }
    if (@($outcome.Failed | Where-Object { $_ -match 'Outside - 1.0' }).Count -ne 1) { $problems += "orphans: the outside folder should be reported as failed: $(@($outcome.Failed) -join ' | ')" }
    if (-not (Test-Path -LiteralPath $packets))               { $problems += "orphans: the package root itself is gone" }
    if (@($outcome.Skipped | Where-Object { $_ -match 'has a definition' }).Count -ne 3) { $problems += "orphans: expected 3 skipped for 'has a definition' (DefOnly, WithPkg, Old), got: $(@($outcome.Skipped) -join ' | ')" }

    # Zeileninfo fuer den Dialogkopf
    $info = Get-InventoryRowInfo -Row $row['WithPkg']
    foreach ($label in 'Package', 'Template', 'Intune', 'Next step') {
        if (-not $info.Contains($label)) { $problems += "row info lacks '$label'" }
    }
    if ($info['Package'] -notmatch 'WithPkg - 1\.0$') { $problems += "row info Package is '$($info['Package'])'" }
    if ((Get-InventoryRowInfo -Row $row['DefOnly'])['Package'] -notmatch 'not built') { $problems += "row info for a definition without package should say it is not built" }

    # Auswahllisten kommen aus dem Modul und enthalten die Vorgaben der Vorlage - und jeden
    # Wert, der in der echten Apps.csv steht (ein unbekannter scheitert erst beim Upload).
    $rule = Get-RequirementRuleChoices
    if ($rule.Architecture -notcontains 'x64')       { $problems += "requirement choices: x64 (the default) is not a valid Architecture" }
    if ($rule.MinimumOS -notcontains 'W10_20H2')     { $problems += "requirement choices: W10_20H2 (the default) is not a valid MinimumOS" }
    foreach ($r in $original) {
        if ($r.Architecture -and ($rule.Architecture -notcontains $r.Architecture)) { $problems += "Apps.csv '$($r.DisplayName)': Architecture '$($r.Architecture)' is not accepted by the module" }
        if ($r.MinimumOS -and ($rule.MinimumOS -notcontains $r.MinimumOS))          { $problems += "Apps.csv '$($r.DisplayName)': MinimumOS '$($r.MinimumOS)' is not accepted by the module" }
    }
}
finally {
    foreach ($pkg in @(Get-ChildItem -LiteralPath (Join-Path $work 'packets') -Directory -ErrorAction SilentlyContinue)) {
        try { $null = Remove-PackageFolder -Path $pkg.FullName -PacketRoot (Join-Path $work 'packets') 6>$null } catch { $problems += "cleanup: $($_.Exception.Message)" }
    }
    # Ohne -Recurse (Pruefung 13): erst die Dateien, dann die leeren Ordner, tief zuerst.
    foreach ($f in @(Get-ChildItem -LiteralPath $work -Recurse -File -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $f.FullName -Force }
    foreach ($d in @(Get-ChildItem -LiteralPath $work -Recurse -Directory -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)) { Remove-Item -LiteralPath $d.FullName -Force }
    Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $work) { $problems += "cleanup: $work is not empty" }
}

if ($problems.Count -gt 0) {
    foreach ($pr in $problems) { [Console]::WriteLine("FAIL: $pr") }
    exit 1
}
[Console]::WriteLine("Main window model: row states and flags, Apps.csv roundtrip (values, own columns, BOM, header), record validation, orphan folder removal with its guards, requirement choices. PASS")
exit 0
