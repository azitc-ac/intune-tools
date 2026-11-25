<#
    .SYNOPSIS
    Verhaltenstest: Move-IntoFolder (Functions\package.ps1) verschiebt ganz oder gar nicht.

    .DESCRIPTION
    Build-AppPackage legt die frische PSADT-Vorlage eine Ebene tiefer nach \in. Mit Move-Item war das
    unter Windows PowerShell 5.1 nicht atomar: eine offene Datei in einem Vorlagenordner (FileShare
    Read, ohne Delete) -> Fehler, aber ein Teil schon verschoben, und der Bau lief weiter. Ein
    Arbeitsverzeichnis im Ordner findet das NICHT - es braucht eine offene Datei.

      1. Ohne Sperre: alle Eintraege (Ordner und Datei) liegen danach in \in.
      2. Offene Datei im zweiten Ordner: es wird geworfen, der erste (schon bewegte) Ordner ist
         zurueckgelegt, der gesperrte Ordner ist vollstaendig am alten Platz, \in ist leer.
      3. Ziel existiert schon: es wird geworfen, nichts landet DARIN.
      4. Gegenprobe (nur PS 5.1): Move-Item verschiebt im selben Aufbau nur einen Teil - sonst waere
         Fall 2 nicht trennscharf.
      5. Rueckbau-Mutante (nur PS 5.1): Move-IntoFolder mit Move-Item statt [System.IO.Directory]::Move
         muss an Fall 2 scheitern.
#>
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$problems = @()
function Test-That([bool]$condition, [string]$what) { if (-not $condition) { $script:problems += $what } }

$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Functions\package.ps1'), [ref]$null, [ref]$null)
$fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Move-IntoFolder' }, $true) | Select-Object -First 1
if (-not $fn) { [Console]::WriteLine('FAIL: Move-IntoFolder fehlt in Functions\package.ps1'); exit 1 }

$work = Join-Path $env:TEMP ('iwh-moveinto-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
function Count([string]$Dir) { @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue).Count }
function New-Template([string]$Name) {
    $root = Join-Path $work $Name
    foreach ($sub in 'Assets', 'Config', 'PSAppDeployToolkit') {
        $d = Join-Path $root $sub
        $null = New-Item -ItemType Directory -Force -Path $d
        0..99 | ForEach-Object { Set-Content -LiteralPath (Join-Path $d ('f{0:D3}.txt' -f $_)) 'x' }
    }
    Set-Content -LiteralPath (Join-Path $root 'Invoke-AppDeployToolkit.ps1') 'x'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'in')
    $root
}
# Fall 2 gegen einen gegebenen Funktionstext; $true = kein halber Zustand.
function Test-OpenFileCase([string]$FnText, [string]$Tag) {
    . ([scriptblock]::Create($FnText))
    $root = New-Template "open-$Tag"
    $items = @(Get-ChildItem -LiteralPath $root | Where-Object { $_.Name -ne 'in' } | Sort-Object Name)
    $fs = [System.IO.File]::Open((Join-Path $root 'Config\f050.txt'), 'Open', 'Read', 'Read')
    $threw = $false
    try { Move-IntoFolder -Items $items -Destination (Join-Path $root 'in') } catch { $threw = $true } finally { $fs.Dispose() }
    $inCount = Count (Join-Path $root 'in')
    $script:lastDetail = "threw=$threw, Assets $(Count (Join-Path $root 'Assets'))/100, Config $(Count (Join-Path $root 'Config'))/100, in $inCount"
    $threw -and (Count (Join-Path $root 'Assets')) -eq 100 -and (Count (Join-Path $root 'Config')) -eq 100 -and $inCount -eq 0
}

try {
    $null = New-Item -ItemType Directory -Force -Path $work
    . ([scriptblock]::Create($fn.Extent.Text))

    # 1
    $r1 = New-Template 'plain'
    Move-IntoFolder -Items @(Get-ChildItem -LiteralPath $r1 | Where-Object { $_.Name -ne 'in' }) -Destination (Join-Path $r1 'in')
    Test-That ((Count (Join-Path $r1 'in')) -eq 301 -and @(Get-ChildItem -LiteralPath $r1).Count -eq 1) "ohne Sperre: nicht alles in \in ($(Count (Join-Path $r1 'in')) von 301)"

    # 2
    Test-That (Test-OpenFileCase $fn.Extent.Text 'fix') "offene Datei: halber Zustand ($script:lastDetail)"

    # 3
    $r3 = New-Template 'exists'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $r3 'in\Config')
    $threw3 = $false
    try { Move-IntoFolder -Items @(Get-Item -LiteralPath (Join-Path $r3 'Config')) -Destination (Join-Path $r3 'in') } catch { $threw3 = $true }
    Test-That ($threw3 -and (Count (Join-Path $r3 'Config')) -eq 100 -and (Count (Join-Path $r3 'in\Config')) -eq 0) 'Ziel existiert: nicht geworfen oder hineinverschoben'

    if ($PSVersionTable.PSVersion.Major -eq 5) {
        # 4
        $r4 = New-Template 'counter'
        $fs = [System.IO.File]::Open((Join-Path $r4 'Config\f050.txt'), 'Open', 'Read', 'Read')
        try { Move-Item -LiteralPath (Join-Path $r4 'Config') -Destination (Join-Path $r4 'in') -ErrorAction Stop } catch { } finally { $fs.Dispose() }
        $moved = Count (Join-Path $r4 'in')
        Test-That ($moved -gt 0 -and $moved -lt 100) "Gegenprobe: Move-Item verschob $moved von 100 - erwartet ein Teil, sonst ist Fall 2 nicht trennscharf"
        # 5
        $needle = '[System.IO.Directory]::Move($item.FullName, $target)'
        Test-That ($fn.Extent.Text.Contains($needle)) 'Mutante: Zeile mit [System.IO.Directory]::Move nicht gefunden'
        $mutant = $fn.Extent.Text.Replace($needle, 'Move-Item -LiteralPath $item.FullName -Destination $target -ErrorAction Stop')
        Test-That (-not (Test-OpenFileCase $mutant 'mutant')) "Mutante mit Move-Item blieb unentdeckt ($script:lastDetail)"
    } else {
        [Console]::WriteLine("SKIP Gegenprobe und Mutante (PS $($PSVersionTable.PSVersion), gemessen nur 5.1)")
    }
}
finally {
    foreach ($f in @(Get-ChildItem -LiteralPath $work -Recurse -File -Force -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    foreach ($d in @(Get-ChildItem -LiteralPath $work -Recurse -Directory -Force -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)) { Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue
}

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { [Console]::WriteLine("FAIL: $p") }
    exit 1
}
[Console]::WriteLine('Move-IntoFolder: ganz oder gar nicht (ohne Sperre, offene Datei mit Ruecklage, Ziel existiert, Gegenprobe, Mutante). PASS')
exit 0
