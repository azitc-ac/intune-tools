<#
    .SYNOPSIS
    Verhaltenstest: Installationsbefehl mit und ohne ServiceUI (Apps.csv "Interactive").

    .DESCRIPTION
    Im Feld (2026-09-28/29) lief jede App ueber ServiceUI mit -DeployMode Silent.
    PSADT zeigte so nie einen Dialog, aber Greenshots Setup startete die App
    danach als SYSTEM auf dem Desktop des Benutzers.

    Erwartet:
      Standard (leer)      -> kein ServiceUI, -DeployMode Silent
      Interactive = true   -> ServiceUI, KEIN Silent (sonst gaebe es keinen Dialog)
      Erneuern             -> ein interaktives Paket bleibt interaktiv, ein
                              Standard-Paket bleibt ohne ServiceUI

    Laeuft ohne Netz, ohne GUI und ohne Tenant; schreibt nur in %TEMP%.
#>
$ErrorActionPreference = 'Stop'

$rootDir = Split-Path -Parent $PSScriptRoot
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $rootDir 'Functions\functions.ps1'), [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}

$problems = @()

foreach ($value in @('', $null, 'false', 'nein')) {
    $c = Get-DeployCommandLine -Interactive $value
    if ($c.NeedsServiceUI)                           { $problems += "default '$value': NeedsServiceUI is true" }
    if ($c.Install -match 'ServiceUi' -or $c.Uninstall -match 'ServiceUi') { $problems += "default '$value': ServiceUI in the command" }
    if ($c.Install -notmatch '-DeployMode Silent' -or $c.Uninstall -notmatch '-DeployMode Silent') { $problems += "default '$value': not silent" }
}
foreach ($value in @('true', 'TRUE', 'ja', '1')) {
    $c = Get-DeployCommandLine -Interactive $value
    if (-not $c.NeedsServiceUI)                      { $problems += "interactive '$value': NeedsServiceUI is false" }
    if ($c.Install -notmatch '^ServiceUi\.exe ')     { $problems += "interactive '$value': no ServiceUI" }
    if ($c.Install -match 'Silent' -or $c.Uninstall -match 'Silent') { $problems += "interactive '$value': -DeployMode Silent suppresses every dialog" }
}

# Anlegen und Erneuern tragen den Wert weiter
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('iw32h-cmdline-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $work
try {
    foreach ($case in @(@{ Name = 'Dialog'; Value = 'true' }, @{ Name = 'Still'; Value = '' })) {
        $folder = Join-Path $work ("{0} - 1.0" -f $case.Name)
        $null = New-Item -ItemType Directory -Force -Path $folder
        Write-DeployScript -AppFolder $folder -AppName $case.Name -AppVersion '1.0' -Publisher 'Test' -Description 'x' `
            -RootDir $rootDir -ToolVersion '0.0.1' -Interactive $case.Value
        $path = Join-Path $folder 'deploy.ps1'
        $expected = ('$Interactive = "{0}"' -f $case.Value)
        if (-not ([IO.File]::ReadAllText($path)).Contains($expected)) { $problems += "$($case.Name): written script lacks $expected" }
        # veralteter Stempel -> Erneuern muss den Wert behalten
        $t = [regex]::Replace([IO.File]::ReadAllText($path), '(?m)^#\s*ToolTemplateFingerprint:.*$', '# ToolTemplateFingerprint: 000000000000')
        [IO.File]::WriteAllText($path, $t, (New-Object System.Text.UTF8Encoding $true))
        $renewed = Update-DeployScript -DeployScriptPath $path -RootDir $rootDir -ToolVersion '0.0.2' 6>$null
        if ($renewed -ne $true) { $problems += "$($case.Name): not renewed" }
        if (-not ([IO.File]::ReadAllText($path)).Contains($expected)) { $problems += "$($case.Name): renewal lost $expected" }
    }
}
finally {
    foreach ($pkg in @(Get-ChildItem -LiteralPath $work -Directory -ErrorAction SilentlyContinue)) {
        try { $null = Remove-PackageFolder -Path $pkg.FullName -PacketRoot $work 6>$null } catch { $problems += "cleanup: $($_.Exception.Message)" }
    }
    Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue
}

if ($problems.Count -gt 0) {
    foreach ($pr in $problems) { Write-Host "FAIL: $pr" }
    exit 1
}
Write-Host "Deploy command line: default silent without ServiceUI, Interactive=true with ServiceUI and without Silent, value survives renewal. PASS"
exit 0
