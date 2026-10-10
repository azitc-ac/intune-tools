<#
    .SYNOPSIS
    Verhaltenstest: Apps, die nur in Intune liegen, haben eine eigene Zeile - und fremde sind erkennbar.

    .DESCRIPTION
    Stufe 5. Das Inventar kannte nur Definitionen und Pakete; was im Tenant liegt, ohne dass das Tool
    davon weiss, war unsichtbar. Geprueft wird, ohne Tenant:

      1. Eine App im Tenant ohne Definition und ohne Paket bekommt eine Zeile (IntuneOnly), Schluessel
         "<Name> - <Version>" wie sonst.
      2. Der Vermerk "Created by IntuneWin32Helper ..." (Add-IntuneWin32App -Notes) macht sie zu
         Origin 'tool'; ohne Vermerk ist sie 'foreign'. Bei Dubletten reicht ein Vermerk.
      3. Fremde Zeilen sagen "not created by this tool"; Zeilen mit Definition oder Paket werden nie
         zu Intune-only-Zeilen, auch wenn eine App mit gleichem Namen und gleicher Version im Tenant
         liegt (keine doppelte Zeile).
      4. Eine andere Version einer definierten App ist eine eigene Zeile; die Definitionszeile
         sagt weiter "other version".
      5. Ohne Tenant-Abfrage ($null) entstehen keine solchen Zeilen.
      6. Get-RetirePlan nimmt fremde Zeilen nie auf, Zeilen mit Vermerk schon.
#>
$ErrorActionPreference = 'Stop'

$rootDir = Split-Path -Parent $PSScriptRoot
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $rootDir 'Functions\functions.ps1'), [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}

$problems = @()
function Test-That([bool]$condition, [string]$what) { if (-not $condition) { $script:problems += $what } }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('iw32h-intuneonly-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path (Join-Path $work 'packets')

function New-App([string]$name, [string]$version, [string]$notes = '', [string]$id = '') {
    [pscustomobject]@{ id = $(if ($id) { $id } else { "id-$name-$version" }); displayName = $name; displayVersion = $version
                       notes = $notes; publishingState = 'published'; committedContentVersion = '1'; createdDateTime = '2026-10-01T10:00:00Z' }
}
$marker = 'Created by IntuneWin32Helper 2.0.9'

try {
    $defs = @(
        [pscustomobject]@{ DisplayName = 'Defined'; Version = '1.0'; Publisher = 'P' },
        [pscustomobject]@{ DisplayName = 'Versioned'; Version = '2.0'; Publisher = 'P' }
    )
    $apps = @(
        (New-App 'Defined' '1.0' $marker),                       # gleiche Zeile wie die Definition
        (New-App 'Versioned' '1.0' $marker),                     # andere Version einer definierten App
        (New-App 'Ours' '5.0' $marker),                          # nur in Intune, vom Tool
        (New-App 'Ours Bare' '5.0' 'Created by IntuneWin32Helper'),   # Vermerk ohne Version
        (New-App 'Theirs' '6.0' ''),                             # fremd: kein Vermerk
        (New-App 'Theirs Notes' '6.0' 'imported by hand'),       # fremd: anderer Vermerk
        (New-App 'Mixed' '7.0' '' 'mixed-a'), (New-App 'Mixed' '7.0' $marker 'mixed-b'),   # Dublette, einer mit Vermerk
        (New-App 'Twin' '8.0' $marker 'twin-a'), (New-App 'Twin' '8.0' $marker 'twin-b'),   # Dublette vom Tool
        (New-App 'Noversion' '' '')
    )
    $inv = @(Get-AppInventory -Definitions $defs -PacketRoot (Join-Path $work 'packets') -RootDir $rootDir -IntuneApps $apps 6>$null)
    $row = { param([string]$key) , @($inv | Where-Object { $_.Key -eq $key }) }

    # 1 + 2
    $ours = & $row 'Ours - 5.0'
    Test-That ($ours.Count -eq 1) "Ours: expected one row, got $($ours.Count)"
    Test-That ($ours[0].IntuneOnly -and $ours[0].Origin -eq 'tool' -and $ours[0].Intune -eq 'yes') "Ours: IntuneOnly=$($ours[0].IntuneOnly) Origin=$($ours[0].Origin) Intune=$($ours[0].Intune)"
    Test-That ($ours[0].Status -eq 'Intune only' -and $ours[0].Next -like 'in Intune only*') "Ours: Status '$($ours[0].Status)' Next '$($ours[0].Next)'"
    Test-That ((& $row 'Ours Bare - 5.0')[0].Origin -eq 'tool') 'a note without a version is not recognised as created by the tool'
    foreach ($key in 'Theirs - 6.0', 'Theirs Notes - 6.0', 'Noversion - ') {
        $r = & $row $key
        Test-That ($r.Count -eq 1 -and $r[0].IntuneOnly -and $r[0].Origin -eq 'foreign') "$key : expected a foreign intune-only row"
        Test-That ($r.Count -eq 1 -and $r[0].Status -eq 'Foreign app' -and $r[0].Next -eq 'not created by this tool') "$key : Status '$($r[0].Status)' Next '$($r[0].Next)'"
    }
    Test-That ((& $row 'Mixed - 7.0').Count -eq 1 -and (& $row 'Mixed - 7.0')[0].Origin -eq 'tool') 'a duplicate where one app has the note must count as created by the tool, as ONE row'
    Test-That ((& $row 'Mixed - 7.0')[0].Intune -eq 'yes (2x)') "duplicate row: Intune '$((& $row 'Mixed - 7.0')[0].Intune)'"
    Test-That ((& $row 'Twin - 8.0')[0].Next -eq 'check duplicates in Intune') "tool duplicate: Next '$((& $row 'Twin - 8.0')[0].Next)', expected the duplicate hint"

    # 3: keine doppelte Zeile fuer eine definierte App
    $defined = & $row 'Defined - 1.0'
    Test-That ($defined.Count -eq 1 -and -not $defined[0].IntuneOnly -and $defined[0].Origin -eq '') 'a defined app became an intune-only row'

    # 4: andere Version
    Test-That ((& $row 'Versioned - 2.0')[0].Intune -like 'other version*') "defined app with only another version in Intune: '$((& $row 'Versioned - 2.0')[0].Intune)'"
    Test-That ((& $row 'Versioned - 1.0')[0].IntuneOnly) 'the other version of a defined app has no row of its own'
    Test-That (@($inv).Count -eq 10) "expected 10 rows (2 defined + 8 intune-only keys), got $(@($inv).Count)"

    # 5: ohne Abfrage keine Zeilen
    $offline = @(Get-AppInventory -Definitions $defs -PacketRoot (Join-Path $work 'packets') -RootDir $rootDir -IntuneApps $null 6>$null)
    Test-That ($offline.Count -eq 2 -and @($offline | Where-Object { $_.IntuneOnly }).Count -eq 0) "not checked: $($offline.Count) rows, expected the 2 definitions only"

    # 6: Retire-Plan
    $plan = @(Get-RetirePlan -Rows $inv)
    $planFor = { param([string]$key) @($plan | Where-Object { $_.Key -eq $key })[0] }
    Test-That ((& $planFor 'Theirs - 6.0').Apps.Count -eq 0 -and (& $planFor 'Theirs - 6.0').Reason -match 'not created by this tool') 'retire plan: a foreign app was planned'
    Test-That ((& $planFor 'Ours - 5.0').Apps.Count -eq 1) 'retire plan: an app created by the tool was not planned'
    Test-That ((& $planFor 'Mixed - 7.0').Apps.Count -eq 2) 'retire plan: the duplicate with a note was not planned completely'
    Test-That ((& $planFor 'Defined - 1.0').Apps.Count -eq 1) 'retire plan: the defined app was not planned'
}
finally {
    foreach ($f in @(Get-ChildItem -LiteralPath $work -Recurse -File -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $f.FullName -Force }
    foreach ($d in @(Get-ChildItem -LiteralPath $work -Recurse -Directory -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)) { Remove-Item -LiteralPath $d.FullName -Force }
    Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue
}

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { [Console]::WriteLine("FAIL: $p") }
    exit 1
}
[Console]::WriteLine('Intune-only rows: apps only in Intune get a row, the tool note tells ours from foreign, foreign apps are never planned for Retire. PASS')
exit 0
