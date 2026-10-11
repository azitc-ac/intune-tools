<#
    .SYNOPSIS
    Verhaltenstest: welcher Knopf des Hauptfensters wann moeglich ist (Get-InventoryActionState).

    .DESCRIPTION
    Die Knoepfe folgen den drei Dingen einer App - Definition, Paket, Intune. "Was ist wann ausgegraut" ist hier
    eine Tabelle, kein Eindruck: je Zustand einer Zeile (und je Auswahl mehrerer Zeilen) die erwarteten
    Zustaende aller Knoepfe, und dass jeder ausgegraute Publish/Remove einen Grund nennt (Tooltip) und ein
    aktiver keinen. Ohne Fenster und ohne Tenant; das Fenster liest nur das Ergebnis (Test-MainWindowUi.ps1
    prueft, dass es das tut, Pruefung 46 in Invoke-RepoChecks.ps1, dass es keine eigene Regel danebenstellt).
#>
$ErrorActionPreference = 'Stop'

$rootDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Get-ToolFunctionsAst.ps1')
$ast = Get-ToolFunctionsAst (Join-Path $rootDir 'Functions')
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-InventoryActionState' }, $true)
if (-not $fn) { throw 'Get-InventoryActionState nicht gefunden' }
. ([scriptblock]::Create($fn.Extent.Text))

$problems = @()
function Test-That([bool]$condition, [string]$what) { if (-not $condition) { $script:problems += $what } }

function New-Row([string]$name, [bool]$def, [bool]$pkg, [string]$pkgDef, [string]$intune, [string]$origin = '') {
    [pscustomobject]@{ Key = "$name - 1.0"; HasDefinition = $def; HasPackage = $pkg; PackageDefinition = $pkgDef; Intune = $intune; Origin = $origin }
}

# Spalten: Edit NewVersion Delete Build Publish Remove RemoveFolder (T = moeglich)
$cases = @(
    @{ Name = 'definition only (no package, not in Intune)';        Rows = @(New-Row 'a' $true  $false '-'       '-');                 Want = 'T T T T T F F' }
    @{ Name = 'package current, not in Intune';                     Rows = @(New-Row 'a' $true  $true  'current' '-');                 Want = 'T T T T T F F' }
    @{ Name = 'package current, in Intune once';                    Rows = @(New-Row 'a' $true  $true  'current' 'yes');               Want = 'T T T T T T F' }
    @{ Name = 'package current, other version in Intune';           Rows = @(New-Row 'a' $true  $true  'current' 'other version: 0.9'); Want = 'T T T T T F F' }
    @{ Name = 'package older than the definition (changed)';        Rows = @(New-Row 'a' $true  $true  'changed' 'yes');               Want = 'T T T T F T F' }
    @{ Name = 'package without a definition stamp (unknown)';       Rows = @(New-Row 'a' $true  $true  'unknown' '-');                 Want = 'T T T T F F F' }
    @{ Name = 'in Intune more than once';                           Rows = @(New-Row 'a' $true  $true  'current' 'yes (2x)');          Want = 'T T T T F T F' }
    @{ Name = 'entry in Intune without content';                    Rows = @(New-Row 'a' $true  $true  'current' 'no content');        Want = 'T T T T F T F' }
    @{ Name = 'package without a definition (orphan)';              Rows = @(New-Row 'a' $false $true  'n/a'     '-');                 Want = 'F F F F T F T' }
    @{ Name = 'orphan that is in Intune too';                       Rows = @(New-Row 'a' $false $true  'n/a'     'yes' 'tool');        Want = 'F F F F T T T' }
    @{ Name = 'only in Intune, created by the tool';                Rows = @(New-Row 'a' $false $false '-'       'yes' 'tool');        Want = 'F F F F F T F' }
    @{ Name = 'only in Intune, foreign app';                        Rows = @(New-Row 'a' $false $false '-'       'yes' 'foreign');     Want = 'F F F F F F F' }
    @{ Name = 'nothing selected';                                   Rows = @();                                                        Want = 'F F F F F F F' }
    @{ Name = 'two rows: one publishable, one stale';               Rows = @((New-Row 'a' $true $true 'current' '-'), (New-Row 'b' $true $true 'changed' 'yes')); Want = 'F F T T T T F' }
    @{ Name = 'two rows: both stale';                               Rows = @((New-Row 'a' $true $true 'changed' '-'), (New-Row 'b' $true $true 'unknown' '-'));   Want = 'F F T T F F F' }
    @{ Name = 'two rows: definition and orphan';                    Rows = @((New-Row 'a' $true $false '-' '-'), (New-Row 'b' $false $true 'n/a' '-'));           Want = 'F F T T T F T' }
)
$labels = 'Edit', 'NewVersion', 'Delete', 'Build', 'Publish', 'Remove', 'RemoveFolder'
foreach ($case in $cases) {
    $state = Get-InventoryActionState -Rows $case.Rows
    $got = ($labels | ForEach-Object { if ($state.$_) { 'T' } else { 'F' } }) -join ' '
    Test-That ($got -eq $case.Want) "$($case.Name): expected [$($case.Want)] got [$got]  (columns: $($labels -join ' '))"
    # Ein ausgegrauter Publish/Remove nennt den Grund, ein aktiver keinen.
    Test-That ($state.Publish -eq [string]::IsNullOrEmpty($state.PublishWhy)) "$($case.Name): Publish=$($state.Publish) but PublishWhy='$($state.PublishWhy)'"
    Test-That ($state.Remove -eq [string]::IsNullOrEmpty($state.RemoveWhy)) "$($case.Name): Remove=$($state.Remove) but RemoveWhy='$($state.RemoveWhy)'"
}

# Die Gruende sind die richtigen (nicht irgendein Text)
$why = { param($rows) (Get-InventoryActionState -Rows $rows).PublishWhy }
Test-That ((& $why @(New-Row 'a' $true $true 'changed' 'yes')) -match 'older than the definition') 'reason for a changed package'
Test-That ((& $why @(New-Row 'a' $true $true 'unknown' '-')) -match 'older version of the tool') 'reason for an unstamped package'
Test-That ((& $why @(New-Row 'a' $true $true 'current' 'yes (2x)')) -match 'more than once') 'reason for duplicates'
Test-That ((& $why @(New-Row 'a' $true $true 'current' 'no content')) -match 'no content') 'reason for an entry without content'
Test-That ((& $why @(New-Row 'a' $false $false '-' 'yes' 'tool')) -match 'no definition and no package') 'reason for an app that exists only in Intune'
Test-That ((& $why @()) -match 'select an app') 'reason when nothing is selected'
Test-That ((Get-InventoryActionState -Rows @(New-Row 'a' $false $false '-' 'yes' 'foreign')).RemoveWhy -match 'may remove') 'reason for a foreign app'

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { [Console]::WriteLine("FAIL: $p") }
    exit 1
}
[Console]::WriteLine("Button states: $($cases.Count) row/selection states give the expected buttons, a disabled Publish or Remove says why. PASS")
exit 0
