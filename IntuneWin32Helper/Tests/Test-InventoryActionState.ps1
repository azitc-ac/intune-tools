<#
    .SYNOPSIS
    Verhaltenstest: welcher Knopf des Hauptfensters wann moeglich ist (Get-InventoryActionState).

    .DESCRIPTION
    Die Knoepfe folgen den drei Dingen einer App - Definition, Paket, Intune - von links nach rechts. Was dazwischen
    gilt: braucht das Paket einen Bau (BuildReason: kein Paket, Definition geaendert, Paket aus aelterer Vorlage), ist
    ausser Build package alles rechts davon gesperrt (Publish, Remove from Intune); ist das Paket auf dem Stand, ist
    Build package gesperrt und Publish der naechste Schritt (ausser die App in Intune ist schon auf dem Stand).
    "Was ist wann ausgegraut" ist hier eine Tabelle, kein Eindruck: je Zustand einer Zeile (und je Auswahl mehrerer
    Zeilen) die erwarteten Zustaende aller Knoepfe, und dass jeder ausgegraute Build/Publish/Remove einen Grund nennt
    (Tooltip) und ein aktiver keinen. Ohne Fenster und ohne Tenant; das Fenster liest nur das Ergebnis
    (Test-MainWindowUi.ps1 prueft, dass es das tut, Pruefung 46 in Invoke-RepoChecks.ps1, dass es keine eigene Regel
    danebenstellt). Dass die Inventarzeilen den BuildReason aus echten Paketen richtig setzen, prueft
    Test-InventoryAndRenewal.ps1.
#>
$ErrorActionPreference = 'Stop'

$rootDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Get-ToolFunctionsAst.ps1')
$ast = Get-ToolFunctionsAst (Join-Path $rootDir 'Functions')
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-InventoryActionState' }, $true)
if (-not $fn) { throw 'Get-InventoryActionState nicht gefunden' }
. ([scriptblock]::Create($fn.Extent.Text))
$fnTargets = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-BuildTargets' }, $true)
if (-not $fnTargets) { throw 'Get-BuildTargets nicht gefunden' }
. ([scriptblock]::Create($fnTargets.Extent.Text))

$problems = @()
function Test-That([bool]$condition, [string]$what) { if (-not $condition) { $script:problems += $what } }

$noPkg   = 'there is no package yet'
$changed = 'the definition was changed after the package was built'
$unknown = 'the package was built before definitions were stamped'
$oldTpl  = 'the package was built from an older template'

function New-Row([string]$name, [bool]$def, [bool]$pkg, [string]$buildReason, [string]$intune, [string]$intuneDef = '-', [string]$origin = '') {
    [pscustomobject]@{ Key = "$name - 1.0"; HasDefinition = $def; HasPackage = $pkg; BuildReason = $buildReason; Intune = $intune; IntuneDefinition = $intuneDef; Origin = $origin }
}

# Spalten: Edit NewVersion Delete Build Publish Remove RemoveFolder (T = moeglich)
$cases = @(
    @{ Name = 'definition only (no package, not in Intune)';        Rows = @(New-Row 'a' $true  $false $noPkg   '-');                         Want = 'T T T T F F F' }
    @{ Name = 'definition only, but the app is in Intune';          Rows = @(New-Row 'a' $true  $false $noPkg   'yes');                       Want = 'T T T T F F F' }
    @{ Name = 'package current, not in Intune';                     Rows = @(New-Row 'a' $true  $true  ''       '-');                         Want = 'T T T F T F F' }
    @{ Name = 'package current, in Intune once, state unknown';     Rows = @(New-Row 'a' $true  $true  ''       'yes' 'unknown');             Want = 'T T T F T T F' }
    @{ Name = 'package current, in Intune once, differs';           Rows = @(New-Row 'a' $true  $true  ''       'yes' 'changed');             Want = 'T T T F T T F' }
    @{ Name = 'package current, in Intune once, up to date';        Rows = @(New-Row 'a' $true  $true  ''       'yes' 'current');             Want = 'T T T F F T F' }
    @{ Name = 'package current, other version in Intune';           Rows = @(New-Row 'a' $true  $true  ''       'other version: 0.9');        Want = 'T T T F T F F' }
    @{ Name = 'package older than the definition (changed)';        Rows = @(New-Row 'a' $true  $true  $changed 'yes' 'current');             Want = 'T T T T F F F' }
    @{ Name = 'package without a definition stamp (unknown)';       Rows = @(New-Row 'a' $true  $true  $unknown '-');                         Want = 'T T T T F F F' }
    @{ Name = 'package from an older template';                     Rows = @(New-Row 'a' $true  $true  $oldTpl  'yes' 'unknown');             Want = 'T T T T F F F' }
    @{ Name = 'in Intune more than once (package current)';         Rows = @(New-Row 'a' $true  $true  ''       'yes (2x)');                  Want = 'T T T F F T F' }
    @{ Name = 'entry in Intune without content (package current)';  Rows = @(New-Row 'a' $true  $true  ''       'no content');                Want = 'T T T F F T F' }
    @{ Name = 'package without a definition (orphan)';              Rows = @(New-Row 'a' $false $true  ''       '-');                         Want = 'F F F F T F T' }
    @{ Name = 'orphan that is in Intune too';                       Rows = @(New-Row 'a' $false $true  ''       'yes' '-' 'tool');            Want = 'F F F F T T T' }
    @{ Name = 'only in Intune, created by the tool';                Rows = @(New-Row 'a' $false $false ''       'yes' '-' 'tool');            Want = 'F F F F F T F' }
    @{ Name = 'only in Intune, foreign app';                        Rows = @(New-Row 'a' $false $false ''       'yes' '-' 'foreign');         Want = 'F F F F F F F' }
    @{ Name = 'nothing selected';                                   Rows = @();                                                                Want = 'F F F F F F F' }
    @{ Name = 'two rows: one ready to publish, one to build';       Rows = @((New-Row 'a' $true $true '' '-'), (New-Row 'b' $true $true $changed 'yes')); Want = 'F F T T T F F' }
    @{ Name = 'two rows: both to build';                            Rows = @((New-Row 'a' $true $true $changed '-'), (New-Row 'b' $true $true $unknown '-')); Want = 'F F T T F F F' }
    @{ Name = 'two rows: definition only and orphan';               Rows = @((New-Row 'a' $true $false $noPkg '-'), (New-Row 'b' $false $true '' '-'));       Want = 'F F T T T F T' }
)
$labels = 'Edit', 'NewVersion', 'Delete', 'Build', 'Publish', 'Remove', 'RemoveFolder'
foreach ($case in $cases) {
    $state = Get-InventoryActionState -Rows $case.Rows
    $got = ($labels | ForEach-Object { if ($state.$_) { 'T' } else { 'F' } }) -join ' '
    Test-That ($got -eq $case.Want) "$($case.Name): expected [$($case.Want)] got [$got]  (columns: $($labels -join ' '))"
    # Ein ausgegrauter Build/Publish/Remove nennt den Grund, ein aktiver keinen.
    Test-That ($state.Publish -eq [string]::IsNullOrEmpty($state.PublishWhy)) "$($case.Name): Publish=$($state.Publish) but PublishWhy='$($state.PublishWhy)'"
    Test-That ($state.Remove -eq [string]::IsNullOrEmpty($state.RemoveWhy)) "$($case.Name): Remove=$($state.Remove) but RemoveWhy='$($state.RemoveWhy)'"
    Test-That ($state.Build -eq [string]::IsNullOrEmpty($state.BuildWhy)) "$($case.Name): Build=$($state.Build) but BuildWhy='$($state.BuildWhy)'"
}

# Die Gruende sind die richtigen (nicht irgendein Text)
$why = { param($rows) (Get-InventoryActionState -Rows $rows).PublishWhy }
Test-That ((& $why @(New-Row 'a' $true $true $changed 'yes')) -match 'run Build package first - the definition was changed') 'reason for a changed package'
Test-That ((& $why @(New-Row 'a' $true $false $noPkg '-')) -match 'run Build package first - there is no package yet') 'reason for a definition without a package'
Test-That ((& $why @(New-Row 'a' $true $true $oldTpl 'yes')) -match 'older template') 'reason for a package from an older template'
Test-That ((& $why @(New-Row 'a' $true $true '' 'yes' 'current')) -match 'already up to date') 'reason for an app that is up to date'
Test-That ((& $why @(New-Row 'a' $true $true '' 'yes (2x)')) -match 'more than once') 'reason for duplicates'
Test-That ((& $why @(New-Row 'a' $true $true '' 'no content')) -match 'no content') 'reason for an entry without content'
Test-That ((& $why @(New-Row 'a' $false $false '' 'yes' '-' 'tool')) -match 'no definition and no package') 'reason for an app that exists only in Intune'
Test-That ((& $why @()) -match 'select an app') 'reason when nothing is selected'
Test-That ((Get-InventoryActionState -Rows @(New-Row 'a' $false $false '' 'yes' '-' 'foreign')).RemoveWhy -match 'may remove') 'reason for a foreign app'
Test-That ((Get-InventoryActionState -Rows @(New-Row 'a' $true $true $changed 'yes')).RemoveWhy -match 'run Build package first') 'reason for Remove while the package must be built'
Test-That ((Get-InventoryActionState -Rows @(New-Row 'a' $true $true '' 'yes' 'unknown')).BuildWhy -match 'already built') 'reason for Build when the package is current'
Test-That ((Get-InventoryActionState -Rows @(New-Row 'a' $false $true '' '-')).BuildWhy -match 'no definition') 'reason for Build without a definition'

# Build package baut nur, was gebaut werden muss - ein Paket auf dem Stand bleibt, wie es ist (auch bei mehreren markierten Zeilen).
$mixed = @((New-Row 'current' $true $true '' 'yes'), (New-Row 'stale' $true $true $changed 'yes'), (New-Row 'nopkg' $true $false $noPkg '-'), (New-Row 'orphan' $false $true '' '-'))
$targets = @(Get-BuildTargets -Rows $mixed | ForEach-Object { $_.Key })
Test-That (($targets -join ',') -eq 'stale - 1.0,nopkg - 1.0') "Get-BuildTargets: [$($targets -join ', ')], expected [stale - 1.0, nopkg - 1.0] (not the current package, not the orphan)"
Test-That (@(Get-BuildTargets -Rows @()).Count -eq 0) 'Get-BuildTargets: an empty selection builds nothing'

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { [Console]::WriteLine("FAIL: $p") }
    exit 1
}
[Console]::WriteLine("Button states: $($cases.Count) row/selection states give the expected buttons (left to right: a package to build locks everything right of Build package, a current package locks Build package), a disabled Build, Publish or Remove says why. PASS")
exit 0
