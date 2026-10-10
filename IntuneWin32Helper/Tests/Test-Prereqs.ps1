<#
    .SYNOPSIS
    Verhaltenstest: check-prereqs prueft schnell und nur einmal je Prozess.

    .DESCRIPTION
    check-prereqs lief mit Get-InstalledModule (Messung 2026-10-11: 2,9 s) beim Start UND in jedem
    deploy.ps1 (1 bis 5 s je App), ohne neuen Befund. Geprueft wird, ohne Netz und ohne etwas zu
    installieren (Install-Module und Get-InstalledModule sind nachgebaut):

      1. Liegen alle drei Module im Modulpfad, wird weder Get-InstalledModule noch Install-Module
         aufgerufen - das ist der schnelle Weg.
      2. Der zweite Aufruf im selben Prozess macht nichts (auch nicht, wenn ein Modul inzwischen fehlt).
      3. Fehlt ein Modul im Modulpfad, entscheidet Get-InstalledModule; ist es dort nicht
         registriert, wird genau dieses Modul installiert, die anderen nicht.
      4. Ein Ordner mit dem Modulnamen ohne .psd1 zaehlt nicht als vorhanden.
      5. Wurde installiert und der Aufruf lief durch, gilt die Pruefung als erledigt.
#>
$ErrorActionPreference = 'Stop'

$rootDir = Split-Path -Parent $PSScriptRoot
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $rootDir 'Functions\functions.ps1'), [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}

$problems = @()
function Test-That([bool]$condition, [string]$what) { if (-not $condition) { $script:problems += $what } }

$script:installed = @(); $script:registryQueries = 0; $script:registered = @()
function Install-Module { [CmdletBinding()] param([string]$Name, [switch]$Force, [string]$Scope) $script:installed += $Name }
function Get-InstalledModule { [CmdletBinding()] param() $script:registryQueries++; foreach ($n in $script:registered) { [pscustomobject]@{ Name = $n } } }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('iw32h-prereq-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$modules = Join-Path $work 'Modules'
$savedPath = $env:PSModulePath
$names = 'IntuneWin32App', 'Microsoft.WinGet.Client', 'PSAppDeployToolkit'

function New-FakeModule([string]$name, [bool]$withManifest = $true) {
    $folder = Join-Path $modules "$name\1.0.0"
    $null = New-Item -ItemType Directory -Force -Path $folder
    if ($withManifest) { Set-Content -LiteralPath (Join-Path $folder "$name.psd1") -Value '@{}' }
}
function Remove-FakeModule([string]$name) {
    # Ohne -Recurse (Pruefung 13): erst die Dateien, dann die leeren Ordner, tief zuerst.
    $folder = Join-Path $modules $name
    foreach ($x in @(Get-ChildItem -LiteralPath $folder -Recurse -File)) { Remove-Item -LiteralPath $x.FullName -Force }
    foreach ($x in @(Get-ChildItem -LiteralPath $folder -Recurse -Directory | Sort-Object FullName -Descending)) { Remove-Item -LiteralPath $x.FullName -Force }
    Remove-Item -LiteralPath $folder -Force
}
function Reset-Run { $script:installed = @(); $script:registryQueries = 0; $script:registered = @(); $global:IntuneWin32HelperPrereqsChecked = $false }

try {
    $null = New-Item -ItemType Directory -Force -Path $modules
    $env:PSModulePath = $modules

    # 1 + 2: alles da -> schnell; zweiter Aufruf tut nichts
    foreach ($n in $names) { New-FakeModule $n }
    Reset-Run
    check-prereqs 6>$null
    Test-That ($script:registryQueries -eq 0) "all modules present: Get-InstalledModule was queried $($script:registryQueries)x (the slow path)"
    Test-That ($script:installed.Count -eq 0) "all modules present: installed [$($script:installed -join ',')]"
    Test-That ($global:IntuneWin32HelperPrereqsChecked -eq $true) 'all modules present: the check was not marked as done'
    Remove-FakeModule 'PSAppDeployToolkit'
    check-prereqs 6>$null
    Test-That ($script:installed.Count -eq 0 -and $script:registryQueries -eq 0) 'second call: checked again in the same process'

    # 3: ein Modul fehlt und ist auch nicht registriert -> genau dieses wird installiert
    Reset-Run
    check-prereqs 6>$null
    Test-That (($script:installed -join ',') -eq 'PSAppDeployToolkit') "one module missing: installed [$($script:installed -join ',')], expected only PSAppDeployToolkit"
    Test-That ($script:registryQueries -eq 1) "one module missing: registry queried $($script:registryQueries)x, expected once"
    Test-That ($global:IntuneWin32HelperPrereqsChecked -eq $true) 'after installing: the check was not marked as done'

    # 3b: fehlt im Modulpfad, ist aber registriert -> nichts installieren
    Reset-Run; $script:registered = @('PSAppDeployToolkit')
    check-prereqs 6>$null
    Test-That ($script:installed.Count -eq 0) "missing in path but registered: installed [$($script:installed -join ',')]"

    # 4: Ordner ohne Manifest zaehlt nicht
    Remove-FakeModule 'IntuneWin32App'
    New-FakeModule 'IntuneWin32App' $false
    Reset-Run
    check-prereqs 6>$null
    Test-That ($script:installed -contains 'IntuneWin32App') 'a folder without a .psd1 counted as the installed module'
}
finally {
    $env:PSModulePath = $savedPath
    $global:IntuneWin32HelperPrereqsChecked = $null
    foreach ($f in @(Get-ChildItem -LiteralPath $work -Recurse -File -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $f.FullName -Force }
    foreach ($d in @(Get-ChildItem -LiteralPath $work -Recurse -Directory -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)) { Remove-Item -LiteralPath $d.FullName -Force }
    Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue
}

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { [Console]::WriteLine("FAIL: $p") }
    exit 1
}
[Console]::WriteLine('Prereqs: modules found in the module path without the slow registry query, checked once per process, missing ones installed one by one. PASS')
exit 0
