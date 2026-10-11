<#
    .SYNOPSIS
    Verhaltenstest: Suchname (Apps.csv "ArpName"), Deinstallation mit derselben
    Regel wie die Erkennung (detection.ps1 wird nur beim Bau geschrieben).

    .DESCRIPTION
    Befunde (2026-09-29):
      - Uninstall-ADTApplication -Name '<Name>' vergleicht in PSADT 4 per
        'Contains' und entfernt JEDEN Treffer; die Erkennung prueft "beginnt mit".
      - Intune-Name und Name in der Programmliste weichen ab (Feldtest-Namen,
        VC++ "v14"). Die Erkennung musste von Hand angepasst werden.
      - Ein Paket aus einer aelteren Vorlage wird nicht mehr an Ort und Stelle erneuert (Update-DeployScript ist
        weg): Build package baut es neu, detection.ps1 inklusive.

    Laeuft ohne Netz, ohne GUI und ohne Tenant; schreibt nur in %TEMP%.
#>
$ErrorActionPreference = 'Stop'

$rootDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Get-ToolFunctionsAst.ps1')
$ast = Get-ToolFunctionsAst (Join-Path $rootDir 'Functions')
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
$utf8Bom = New-Object System.Text.UTF8Encoding $true
$problems = @()

# 1) Suchname
if ((Get-ArpSearchName -DisplayName 'Greenshot' -ArpName '') -ne 'Greenshot') { $problems += "ArpName empty: not the DisplayName" }
if ((Get-ArpSearchName -DisplayName 'IW32H Test' -ArpName '  Greenshot ') -ne 'Greenshot') { $problems += "ArpName set: not used / not trimmed" }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('iw32h-arp-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $work
try {
    # 2) Deinstallation: Praefix-Regel wie die Erkennung, nicht 'Contains'
    $content = Join-Path $work 'Content - 1.0\in'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $content 'Files')
    [IO.File]::WriteAllBytes((Join-Path $content 'Files\setup.exe'), [Text.Encoding]::ASCII.GetBytes('MZ fake Nullsoft Install System'))
    $d = Get-DerivedInstallCommands -ContentPath $content -AppName 'Greenshot'
    if ($d.Engine -ne 'nsis') { $problems += "setup: fake installer not detected as nsis ($($d.Engine))" }
    if ($d.Uninstall -notmatch "-Name 'Greenshot\*'")          { $problems += "uninstall: no prefix pattern 'Greenshot*' - $($d.Uninstall)" }
    if ($d.Uninstall -notmatch "-NameMatch 'Wildcard'")        { $problems += "uninstall: without -NameMatch 'Wildcard' PSADT uses 'Contains' and removes every match" }
    $tpl = [IO.File]::ReadAllText((Join-Path $rootDir 'Templates\detection_template.ps1'))
    if ($tpl -notmatch '\$searchPattern\s*=\s*\$AppName\s*\+\s*"\*"' -or $tpl -notmatch '-like \$searchPattern') {
        $problems += "detection template no longer uses the prefix rule - uninstall and detection would drift apart"
    }

    # 3) Anlegen: Suchname landet im Skript
    $pkg = Join-Path $work 'IW32H Test - 1.3.315'
    $null = New-Item -ItemType Directory -Force -Path $pkg
    Write-DetectionScript -AppFolder $pkg -AppName 'IW32H Test' -AppVersion '1.3.315' -RootDir $rootDir -ArpName 'Greenshot'
    $det = [IO.File]::ReadAllText((Join-Path $pkg 'detection.ps1'))
    if (-not $det.Contains('$ArpName = "Greenshot"'))   { $problems += "write: ArpName not in detection.ps1" }
    if (-not $det.Contains('$PackageID = "IW32H Test"')) { $problems += "write: PackageID (log name) is not the Intune name" }

}
finally {
    foreach ($p in @(Get-ChildItem -LiteralPath $work -Directory -ErrorAction SilentlyContinue)) {
        try { $null = Remove-PackageFolder -Path $p.FullName -PacketRoot $work 6>$null } catch { $problems += "cleanup: $($_.Exception.Message)" }
    }
    Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue
}

if ($problems.Count -gt 0) {
    foreach ($pr in $problems) { Write-Host "FAIL: $pr" }
    exit 1
}
Write-Host "ArpName: search name used by detection and uninstall with one prefix rule, written into detection.ps1 at build time. PASS"
exit 0
