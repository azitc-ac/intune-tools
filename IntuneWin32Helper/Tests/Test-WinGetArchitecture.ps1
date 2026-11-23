<#
    .SYNOPSIS
    Verhaltenstest: Spalte Architecture -> "--architecture" NUR beim winget install.

    .DESCRIPTION
    Fuer PDF24 Creator auf ARM64 (2026-11-23) sollte winget den arm64-Installer
    nehmen. Die Spalte Architecture setzte bis dahin nur die Intune-Anforderung;
    WinGetParams gilt fuer Install UND Uninstall, und winget uninstall kennt
    --architecture nicht (MS-Doku uninstall.md) - ueber WinGetParams waere der
    Uninstall gebrochen.

    Erwartet (erzeugte Argumente, so wie sie im Paket ausgewertet werden):
      arm64 / x64 / x86           -> Install hat "--architecture <wert>"
      leer / x64x86 / AllWithARM64 -> Install ohne --architecture
      jeder Wert                   -> Uninstall NIE mit --architecture
      WinGetParams                 -> bleibt in Install und Uninstall erhalten

    Laeuft ohne Netz, ohne GUI und ohne Tenant.
#>
$ErrorActionPreference = 'Stop'

$rootDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Get-ToolFunctionsAst.ps1')
$ast = Get-ToolFunctionsAst (Join-Path $rootDir 'Functions')
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}

$problems = @()

# Den erzeugten Code so auswerten, wie er im Paket laeuft: $arguments bauen
# (ohne winget zu starten) und die fertige Argumentzeile zurueckgeben.
function Get-GeneratedArgumentLine([string]$Type, [string]$Architecture) {
    $code = Get-WinGetCommands -type $Type -id 'Pub.App' -wgparams '--scope=machine' -Architecture $Architecture
    $start = $code.IndexOf('$arguments = @(')
    $end = $code.IndexOf('$ArgumentList')
    if ($start -lt 0 -or $end -lt $start) { throw "generated $Type code has no `$arguments block" }
    $block = $code.Substring($start, $end - $start)
    $accpackagree = '--accept-package-agreements'
    $arguments = $null
    . ([scriptblock]::Create($block))
    return ($arguments -join ' ').Trim()
}

$expected = @{ 'arm64' = 'arm64'; 'x64' = 'x64'; 'x86' = 'x86' }   # Hashtable-Schluessel sind case-insensitiv: 'ARM64' trifft 'arm64'
foreach ($value in @('arm64', 'ARM64', 'x64', 'x86', '', 'x64x86', 'AllWithARM64')) {
    $install   = Get-GeneratedArgumentLine -Type 'Install' -Architecture $value
    $uninstall = Get-GeneratedArgumentLine -Type 'Uninstall' -Architecture $value

    if ($expected.ContainsKey($value)) {
        if ($install -notmatch ('(^| )--architecture ' + $expected[$value] + '( |$)')) {
            $problems += "Architecture '$value': install has no '--architecture $($expected[$value])': $install"
        }
    }
    elseif ($install -match '--architecture') {
        $problems += "Architecture '$value': install must not pin an architecture: $install"
    }
    if ($uninstall -match '--architecture') {
        $problems += "Architecture '$value': uninstall has --architecture (winget uninstall does not accept it): $uninstall"
    }
    if ($install -notmatch '--scope=machine' -or $uninstall -notmatch '--scope=machine') {
        $problems += "Architecture '$value': WinGetParams lost"
    }
    if ($install -notmatch '^install --exact --id Pub\.App ' -or $uninstall -notmatch '^uninstall --exact --id Pub\.App ') {
        $problems += "Architecture '$value': command head changed: [$install] [$uninstall]"
    }
}

# Der Bau des Pakets muss die Spalte auch wirklich durchreichen (einziger Aufrufer).
$packageSource = Get-Content -LiteralPath (Join-Path $rootDir 'Functions\package.ps1') -Raw
if ($packageSource -notmatch 'Get-WinGetCommands -type Install [^\r\n]*-Architecture \(\[string\]\$App\.Architecture\)') {
    $problems += 'package.ps1: Build-AppPackage does not pass Apps.csv Architecture to the install command'
}

if ($problems.Count -gt 0) {
    foreach ($pr in $problems) { Write-Host "FAIL: $pr" }
    exit 1
}
Write-Host "WinGet architecture: arm64/x64/x86 pin --architecture on install only, empty and mixed values do not, uninstall never, WinGetParams kept, build passes the column. PASS"
exit 0
