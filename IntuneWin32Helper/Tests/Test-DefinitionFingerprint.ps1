<#
    .SYNOPSIS
    Verhaltenstest: der Stempel der Definition im Paket (Get-DefinitionFingerprint, Get-PackageDefinitionFingerprint).

    .DESCRIPTION
    Er sagt dem Inventar, ob ein Paket aus der Definition von heute gebaut wurde. Geprueft wird:

      1. Jedes Feld, das in Paket oder App eingeht, aendert den Stempel - sonst bliebe eine geaenderte Definition
         unbemerkt ("Ready" statt "Outdated, rebuild: definition changed") und ginge mit dem alten Paket nach Intune.
      2. Was nicht eingeht, aendert ihn nicht: eigene Spalten, die Reihenfolge der Spalten, Gross-/Kleinschreibung
         von true/false, Leerzeichen am Rand.
      3. Der Stempel steht im erzeugten deploy.ps1 und wird von Get-PackageDefinitionFingerprint gelesen; ein
         Skript ohne Stempel oder mit dem unersetzten Platzhalter liefert leer (= unbekannt).
      4. Inventar: derselbe Datensatz = current, ein geaendertes Feld = changed, kein Stempel = unknown, keine
         Definition = n/a, kein Paket = '-'.
#>
$ErrorActionPreference = 'Stop'

$rootDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Get-ToolFunctionsAst.ps1')
$ast = Get-ToolFunctionsAst (Join-Path $rootDir 'Functions')
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}

$problems = @()
function Test-That([bool]$condition, [string]$what) { if (-not $condition) { $script:problems += $what } }

$base = [ordered]@{
    DisplayName = 'App'; Version = '1.0'; Publisher = 'Pub'; ProgramID = 'Pub.App'; WinGetParams = '--scope=machine'
    SingleMSI = ''; MsiProductCode = ''; logoURL = 'https://x/y.png'; InstallCmd = 'Start-ADTProcess -FilePath a.exe'
    UninstallCmd = 'Uninstall-ADTApplication -Name App'; Interactive = ''; Architecture = 'x64'; MinimumOS = 'W10_20H2'; ArpName = ''; DetectionScript = ''
}
function New-Record([hashtable]$change = @{}) {
    $copy = [ordered]@{}
    foreach ($k in $base.Keys) { $copy[$k] = $base[$k] }
    foreach ($k in $change.Keys) { $copy[$k] = $change[$k] }
    [pscustomobject]$copy
}
$reference = Get-DefinitionFingerprint -Record (New-Record) -RootDir $rootDir
Test-That ($reference -match '^[0-9a-f]{12}$') "fingerprint is '$reference', expected 12 hex characters"

# 1) jedes Feld zaehlt
foreach ($field in $base.Keys) {
    $changed = Get-DefinitionFingerprint -Record (New-Record @{ $field = ([string]$base[$field] + 'x') }) -RootDir $rootDir
    Test-That ($changed -ne $reference) "changing $field does not change the fingerprint - a package built before that edit would pass as current"
}

# 2) was nicht zaehlt
$withCustom = New-Record; $withCustom | Add-Member -NotePropertyName MyColumn -NotePropertyValue 'anything'
Test-That ((Get-DefinitionFingerprint -Record $withCustom -RootDir $rootDir) -eq $reference) 'a custom column changed the fingerprint'
$reordered = [pscustomobject][ordered]@{ ArpName = ''; MinimumOS = 'W10_20H2'; Architecture = 'x64'; Interactive = ''; UninstallCmd = $base.UninstallCmd; InstallCmd = $base.InstallCmd; logoURL = $base.logoURL; MsiProductCode = ''; SingleMSI = ''; WinGetParams = $base.WinGetParams; ProgramID = 'Pub.App'; Publisher = 'Pub'; Version = '1.0'; DisplayName = 'App' }
Test-That ((Get-DefinitionFingerprint -Record $reordered -RootDir $rootDir) -eq $reference) 'the column order changed the fingerprint'
Test-That ((Get-DefinitionFingerprint -Record (New-Record @{ DisplayName = '  App  ' }) -RootDir $rootDir) -eq $reference) 'spaces around a value changed the fingerprint'
$lower = Get-DefinitionFingerprint -Record (New-Record @{ Interactive = 'true'; SingleMSI = 'true' }) -RootDir $rootDir
Test-That ((Get-DefinitionFingerprint -Record (New-Record @{ Interactive = 'TRUE'; SingleMSI = 'True' }) -RootDir $rootDir) -eq $lower) 'true/TRUE/True are not the same statement for Interactive and SingleMSI'
Test-That ($lower -ne $reference) 'Interactive/SingleMSI = true is the same as empty'
$sparse = [pscustomobject]@{ DisplayName = 'App'; Version = '1.0' }
Test-That ((Get-DefinitionFingerprint -Record $sparse -RootDir $rootDir) -match '^[0-9a-f]{12}$') 'a record with only name and version has no fingerprint'

# 2b) DetectionScript: leer aendert den Stempel NICHT (jedes vorhandene Paket bliebe sonst auf einmal "definition changed"),
#     gesetzt zaehlen Pfad UND Inhalt des Skripts (sonst bliebe ein geaendertes Erkennungsskript unbemerkt).
#     Der feste Wert ist der Stempel des Basisdatensatzes, berechnet mit der Fassung VOR der Spalte DetectionScript.
Test-That ($reference -eq '760eac61ad07') "an empty DetectionScript changes the fingerprint of existing definitions: '$reference' (was 760eac61ad07)"
Test-That ((Get-DefinitionFingerprint -Record ([pscustomobject]@{ DisplayName = 'App'; Version = '1.0' }) -RootDir $rootDir) -eq (Get-DefinitionFingerprint -Record ([pscustomobject]@{ DisplayName = 'App'; Version = '1.0'; DetectionScript = '  ' }) -RootDir $rootDir)) 'a blank DetectionScript differs from none'
$detWork = Join-Path ([System.IO.Path]::GetTempPath()) ('iw32h-detstamp-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $detWork
try {
    $detFile = Join-Path $detWork 'detect.ps1'
    [IO.File]::WriteAllText($detFile, "exit 0`r`n")
    $withScript = Get-DefinitionFingerprint -Record (New-Record @{ DetectionScript = $detFile }) -RootDir $rootDir
    Test-That ($withScript -ne $reference) 'a DetectionScript did not change the fingerprint'
    Test-That ($withScript -eq (Get-DefinitionFingerprint -Record (New-Record @{ DetectionScript = "  $detFile  " }) -RootDir $rootDir)) 'spaces around the DetectionScript path changed the fingerprint'
    [IO.File]::WriteAllText($detFile, "exit 1`r`n")
    $edited = Get-DefinitionFingerprint -Record (New-Record @{ DetectionScript = $detFile }) -RootDir $rootDir
    Test-That ($edited -ne $withScript) 'editing the detection script did not change the fingerprint - the package would keep the old detection.ps1 as "Ready"'
    [IO.File]::WriteAllText($detFile, "exit 0`r`n")
    Test-That ((Get-DefinitionFingerprint -Record (New-Record @{ DetectionScript = $detFile }) -RootDir $rootDir) -eq $withScript) 'the same content gives another fingerprint'
    $missing = Get-DefinitionFingerprint -Record (New-Record @{ DetectionScript = (Join-Path $detWork 'gone.ps1') }) -RootDir $rootDir
    Test-That ($missing -match '^[0-9a-f]{12}$' -and $missing -ne $reference) 'a missing script has no fingerprint of its own (the build, not the inventory, reports it)'
    # relativer Pfad: wird gegen den Tool-Ordner aufgeloest, der Inhalt geht ein
    $relBefore = Get-DefinitionFingerprint -Record (New-Record @{ DetectionScript = 'detect.ps1' }) -RootDir $detWork
    [IO.File]::WriteAllText($detFile, "exit 2`r`n")
    Test-That ((Get-DefinitionFingerprint -Record (New-Record @{ DetectionScript = 'detect.ps1' }) -RootDir $detWork) -ne $relBefore) 'a relative DetectionScript is not resolved against RootDir'
}
finally {
    Get-ChildItem -LiteralPath $detWork -File -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    Remove-Item -LiteralPath $detWork -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $detWork) { $problems += "cleanup: $detWork is not empty" }
}

# 3) im deploy.ps1
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('iw32h-defstamp-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $work
try {
    function New-Pkg([string]$name, [string]$stamp) {
        $folder = Join-Path $work "$name - 1.0"
        $null = New-Item -ItemType Directory -Force -Path $folder
        Write-DeployScript -AppFolder $folder -AppName $name -AppVersion '1.0' -Publisher 'Pub' -Description 'd' -RootDir $rootDir -ToolVersion '0.0.1' -DefinitionFingerprint $stamp 6>$null
        return (Join-Path $folder 'deploy.ps1')
    }
    $withStamp = New-Pkg 'Stamped' $reference
    Test-That ((Get-PackageDefinitionFingerprint -DeployScriptPath $withStamp) -eq $reference) 'the stamp written into deploy.ps1 is not read back'
    Test-That (-not ([IO.File]::ReadAllText($withStamp)).Contains('#DEFFP#')) 'the placeholder #DEFFP# is left in deploy.ps1'
    $noStamp = New-Pkg 'Unstamped' ''
    Test-That ((Get-PackageDefinitionFingerprint -DeployScriptPath $noStamp) -eq '') 'an empty stamp is read as a value (must be empty = unknown)'
    $placeholder = Join-Path $work 'placeholder.ps1'
    [IO.File]::WriteAllText($placeholder, "# ToolDefinitionFingerprint: #DEFFP#`r`n", (New-Object System.Text.UTF8Encoding $true))
    Test-That ((Get-PackageDefinitionFingerprint -DeployScriptPath $placeholder) -eq '') 'the unreplaced placeholder is read as a fingerprint'
    $other = Join-Path $work 'noline.ps1'
    [IO.File]::WriteAllText($other, "param()`r`n", (New-Object System.Text.UTF8Encoding $true))
    Test-That ((Get-PackageDefinitionFingerprint -DeployScriptPath $other) -eq '') 'a script without the line has a stamp'
    Test-That ((Get-PackageDefinitionFingerprint -DeployScriptPath (Join-Path $work 'missing.ps1')) -eq '') 'a missing file has a stamp'
    # Eine leere Stempelzeile darf nicht die naechste Zeile als Wert lesen
    $emptyThenNext = Join-Path $work 'next.ps1'
    [IO.File]::WriteAllText($emptyThenNext, "# ToolDefinitionFingerprint: `r`n`$x = 1`r`n", (New-Object System.Text.UTF8Encoding $true))
    Test-That ((Get-PackageDefinitionFingerprint -DeployScriptPath $emptyThenNext) -eq '') 'an empty stamp line swallowed the next line as its value'

    # 4) Inventar
    foreach ($n in 'Same', 'Changed', 'None') {
        $null = New-Pkg $n $(switch ($n) { 'Same' { Get-DefinitionFingerprint -Record ([pscustomobject]@{ DisplayName = 'Same'; Version = '1.0' }) -RootDir $rootDir } 'Changed' { 'aaaaaaaaaaaa' } default { '' } })
    }
    $null = New-Pkg 'Orphan' $reference
    $defs = @('Same', 'Changed', 'None', 'DefOnly') | ForEach-Object { [pscustomobject]@{ DisplayName = $_; Version = '1.0' } }
    $rows = @{}
    foreach ($row in @(Get-AppInventory -Definitions $defs -PacketRoot $work -RootDir $rootDir -IntuneApps $null 6>$null)) { $rows[$row.AppName] = $row }
    Test-That ($rows['Same'].PackageDefinition -eq 'current')    "inventory Same: '$($rows['Same'].PackageDefinition)'"
    Test-That ($rows['Changed'].PackageDefinition -eq 'changed') "inventory Changed: '$($rows['Changed'].PackageDefinition)'"
    Test-That ($rows['None'].PackageDefinition -eq 'unknown')    "inventory None: '$($rows['None'].PackageDefinition)'"
    Test-That ($rows['Orphan'].PackageDefinition -eq 'n/a')      "inventory Orphan: '$($rows['Orphan'].PackageDefinition)'"
    Test-That ($rows['DefOnly'].PackageDefinition -eq '-')       "inventory DefOnly: '$($rows['DefOnly'].PackageDefinition)'"
}
finally {
    foreach ($pkg in @(Get-ChildItem -LiteralPath $work -Directory -ErrorAction SilentlyContinue)) {
        try { $null = Remove-PackageFolder -Path $pkg.FullName -PacketRoot $work } catch { $problems += "cleanup: $($_.Exception.Message)" }
    }
    Get-ChildItem -LiteralPath $work -File -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $work) { $problems += "cleanup: $work is not empty" }
}

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { [Console]::WriteLine("FAIL: $p") }
    exit 1
}
[Console]::WriteLine('Definition fingerprint: every field that goes into the package changes it, custom columns and spelling of true do not, it is stamped into deploy.ps1 and read back, the inventory tells current / changed / unknown. PASS')
exit 0
