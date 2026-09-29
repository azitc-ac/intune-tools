<#
    .SYNOPSIS
    Verhaltenstest: Suchname (Apps.csv "ArpName"), Deinstallation mit derselben
    Regel wie die Erkennung, und Erneuern von detection.ps1.

    .DESCRIPTION
    Befunde (2026-09-29):
      - Uninstall-ADTApplication -Name '<Name>' vergleicht in PSADT 4 per
        'Contains' und entfernt JEDEN Treffer; die Erkennung prueft "beginnt mit".
      - Intune-Name und Name in der Programmliste weichen ab (Feldtest-Namen,
        VC++ "v14"). Die Erkennung musste von Hand angepasst werden.
      - Update-DeployScript erneuerte detection.ps1 nicht. Der Stempel stand
        danach auf "current", die alte Erkennung (z.B. mit HKCU) blieb.

    Laeuft ohne Netz, ohne GUI und ohne Tenant; schreibt nur in %TEMP%.
#>
$ErrorActionPreference = 'Stop'

$rootDir = Split-Path -Parent $PSScriptRoot
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $rootDir 'Functions\functions.ps1'), [ref]$null, [ref]$null)
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

    # 4) Erneuern: altes Skript-Paket (Suchname von Hand in $PackageID, mit HKCU)
    Write-DeployScript -AppFolder $pkg -AppName 'IW32H Test' -AppVersion '1.3.315' -Publisher 'T' -Description 'x' -RootDir $rootDir -ToolVersion '0.0.1' 6>$null
    $deploy = Join-Path $pkg 'deploy.ps1'
    [IO.File]::WriteAllText($deploy, [regex]::Replace([IO.File]::ReadAllText($deploy), '(?m)^#\s*ToolTemplateFingerprint:.*$', '# ToolTemplateFingerprint: 000000000000'), $utf8Bom)
    $old = $tpl.Replace('#DN#', 'Greenshot').Replace('#VER#', '1.3.315')
    $old = [regex]::Replace($old, '(?m)^\$ArpName = .*\r?\n', '').Replace('Test-AppInstallation -AppName $ArpName', 'Test-AppInstallation -AppName $PackageID')
    $old = $old.Replace('"HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"', '"HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall", "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"')
    [IO.File]::WriteAllText((Join-Path $pkg 'detection.ps1'), $old, $utf8Bom)
    $r = Update-DeployScript -DeployScriptPath $deploy -RootDir $rootDir -ToolVersion '0.0.2' 6>$null
    $det = [IO.File]::ReadAllText((Join-Path $pkg 'detection.ps1'))
    if ($r -ne $true)                                   { $problems += "renew: Update-DeployScript returned '$r'" }
    if (-not (Test-Path -LiteralPath (Join-Path $pkg 'detection.ps1.bak'))) { $problems += "renew: no detection.ps1.bak" }
    # Der Registry-Pfad, nicht das Wort: die Vorlage erwaehnt HKCU im Kommentar.
    if ($det.Contains('"HKCU:\'))                       { $problems += "renew: detection.ps1 still searches HKCU - not renewed" }
    if (-not $old.Contains('"HKCU:\'))                  { $problems += "setup: old detection has no HKCU path - renewal check would prove nothing" }
    if (-not $det.Contains('$ArpName = "Greenshot"'))   { $problems += "renew: hand-set search name 'Greenshot' lost" }

    # 5) Erneuern: WinGet-Paket behaelt seine ID und bekommt die aktuelle Pruefung
    $wg = Join-Path $work 'IW32H WinGet - LatestAvailable'
    $null = New-Item -ItemType Directory -Force -Path $wg
    Write-DeployScript -AppFolder $wg -AppName 'IW32H WinGet' -AppVersion 'LatestAvailable' -Publisher 'T' -Description 'x' -RootDir $rootDir -ToolVersion '0.0.1' 6>$null
    $wgDeploy = Join-Path $wg 'deploy.ps1'
    [IO.File]::WriteAllText($wgDeploy, [regex]::Replace([IO.File]::ReadAllText($wgDeploy), '(?m)^#\s*ToolTemplateFingerprint:.*$', '# ToolTemplateFingerprint: 000000000000'), $utf8Bom)
    [IO.File]::WriteAllText((Join-Path $wg 'detection.ps1'), "`$PackageID = `"Vendor.SampleApp`"`r`nif (`$wingetPrg_Existing -notlike `"*`$PackageID*`"){ exit 1 }`r`n", $utf8Bom)
    $r = Update-DeployScript -DeployScriptPath $wgDeploy -RootDir $rootDir -ToolVersion '0.0.2' 6>$null
    $det = [IO.File]::ReadAllText((Join-Path $wg 'detection.ps1'))
    if (-not $det.Contains('$PackageID = "Vendor.SampleApp"')) { $problems += "renew winget: WinGet id lost" }
    if ($det.Contains('-notlike "*$PackageID*"'))              { $problems += "renew winget: old detection kept" }
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
Write-Host "ArpName: search name used by detection and uninstall with one prefix rule; renewal rewrites detection.ps1 and keeps search name / WinGet id. PASS"
exit 0
