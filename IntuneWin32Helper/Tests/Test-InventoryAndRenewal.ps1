<#
    .SYNOPSIS
    Verhaltenstest: Inventar und Erneuern entscheiden nach demselben Merkmal,
    und ein inhaltsloser Intune-Eintrag faellt im Inventar auf.

    .DESCRIPTION
    Zwei Befunde aus dem Feld (2026-09-28, Test-Tenant):
      1. Update-DeployScript erneuerte nur Skripte OHNE $Tenant - das kennt schon
         die Vorlage von 2.0.0. Das Inventar zeigte "outdated"/"unstamped", beim
         Verteilen blieb trotzdem das alte Skript. Vorlagen-Korrekturen kamen bei
         bestehenden Paketen nie an.
      2. Eine App ohne Inhalt (fehlgeschlagener Upload) stand im Inventar als
         Intune "yes" und Next "up to date".

    Laeuft ohne Netz, ohne GUI und ohne Tenant; schreibt nur in %TEMP%.
#>
$ErrorActionPreference = 'Stop'

$rootDir = Split-Path -Parent $PSScriptRoot
$functionsPath = Join-Path $rootDir 'Functions\functions.ps1'

# Alle Funktionsdefinitionen laden, aber keinen Code auf oberster Ebene.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($functionsPath, [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}

$problems = @()
$current = Get-TemplateFingerprint -RootDir $rootDir
if (-not $current) { $problems += "setup: no template fingerprint for $rootDir" }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('iw32h-renewal-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $work
try {
    function New-Package([string]$name, [string]$stampLine) {
        $folder = Join-Path $work "$name - 1.0"
        $null = New-Item -ItemType Directory -Force -Path $folder
        Write-DeployScript -AppFolder $folder -AppName $name -AppVersion '1.0' -Publisher 'Test' -Description 'Installed using PSADT' `
            -RootDir $rootDir -ToolVersion '0.0.1' -Architecture 'arm64' -MinimumOS 'W11_22H2' -MsiProductCode '{11111111-2222-3333-4444-555555555555}'
        $path = Join-Path $folder 'deploy.ps1'
        # Stempel wie bei einem Paket aus einer anderen Vorlage setzen/entfernen.
        # Das Skript kennt -Tenant (wie jede Vorlage seit 2.0.0).
        $text = [IO.File]::ReadAllText($path)
        $text = [regex]::Replace($text, '(?m)^#\s*ToolTemplateFingerprint:.*$', $stampLine)
        [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $true))
        return $path
    }

    # 1) Veralteter Stempel -> wird erneuert, Werte bleiben, .bak entsteht
    $old = New-Package 'Outdated' '# ToolTemplateFingerprint: 000000000000'
    if (-not ([IO.File]::ReadAllText($old) -match '\$Tenant')) { $problems += "setup: package does not know -Tenant, test would prove nothing" }
    $r = Update-DeployScript -DeployScriptPath $old -RootDir $rootDir -ToolVersion '0.0.2' 6>$null
    $t = [IO.File]::ReadAllText($old)
    if ($r -ne $true)                                 { $problems += "outdated: Update-DeployScript returned '$r', expected True" }
    if (-not (Test-Path -LiteralPath "$old.bak"))     { $problems += "outdated: no deploy.ps1.bak" }
    if ((Get-PackageTemplateFingerprint -DeployScriptPath $old) -ne $current) { $problems += "outdated: stamp after renewal is not the current one" }
    if ($t.Contains('#TPLFP#'))                       { $problems += "outdated: placeholder #TPLFP# left in the script" }
    foreach ($kept in '$Architecture = "arm64"', '"W11_22H2"', '{11111111-2222-3333-4444-555555555555}', '$PackageName = "Outdated"') {
        if (-not $t.Contains($kept)) { $problems += "outdated: value lost on renewal: $kept" }
    }

    # 2) Ohne Stempel -> wird erneuert
    $unst = New-Package 'Unstamped' ''
    $r = Update-DeployScript -DeployScriptPath $unst -RootDir $rootDir -ToolVersion '0.0.2' 6>$null
    if ($r -ne $true) { $problems += "unstamped: Update-DeployScript returned '$r', expected True" }

    # 3) Aktueller Stempel -> unberuehrt (auch von Hand angepasst)
    $cur = New-Package 'Current' ("# ToolTemplateFingerprint: $current")
    Add-Content -LiteralPath $cur -Value '# von Hand angepasst'
    $before = [IO.File]::ReadAllBytes($cur)
    $r = Update-DeployScript -DeployScriptPath $cur -RootDir $rootDir -ToolVersion '0.0.2' 6>$null
    $after = [IO.File]::ReadAllBytes($cur)
    if ($r -ne $false) { $problems += "current: Update-DeployScript returned '$r', expected False" }
    if ([Convert]::ToBase64String($before) -ne [Convert]::ToBase64String($after)) { $problems += "current: script was changed" }
    if (Test-Path -LiteralPath "$cur.bak") { $problems += "current: a .bak was written" }

    # 4) Inventar: Inhaltsloser Eintrag faellt auf
    $apps = @(
        [pscustomobject]@{ displayName = 'Current';  displayVersion = '1.0'; publishingState = 'published';    committedContentVersion = '1' }
        [pscustomobject]@{ displayName = 'Ghost';    displayVersion = '1.0'; publishingState = 'notPublished'; committedContentVersion = ''  }
        [pscustomobject]@{ displayName = 'Twice';    displayVersion = '1.0'; publishingState = 'published';    committedContentVersion = '1' }
        [pscustomobject]@{ displayName = 'Twice';    displayVersion = '1.0'; publishingState = 'notPublished'; committedContentVersion = ''  }
    )
    $defs = @('Current', 'Ghost', 'Twice') | ForEach-Object { [pscustomobject]@{ DisplayName = $_; Version = '1.0' } }
    $inv = @(Get-AppInventory -Definitions $defs -PacketRoot $work -RootDir $rootDir -IntuneApps $apps 6>$null)
    $row = @{}; foreach ($x in $inv) { $row[$x.AppName] = $x }
    if ($row['Current'].Intune -ne 'yes' -or $row['Current'].Next -ne 'up to date') { $problems += "inventory Current: '$($row['Current'].Intune)' / '$($row['Current'].Next)'" }
    if ($row['Ghost'].Intune -ne 'no content')                                      { $problems += "inventory Ghost: Intune '$($row['Ghost'].Intune)', expected 'no content'" }
    if ($row['Ghost'].Next -notmatch 'without content')                             { $problems += "inventory Ghost: Next '$($row['Ghost'].Next)'" }
    if ($row['Twice'].Intune -ne 'yes (2x, 1 without content)')                     { $problems += "inventory Twice: Intune '$($row['Twice'].Intune)'" }
}
finally {
    # Aufraeumen ueber den einzigen erlaubten Weg fuer rekursives Loeschen
    # (Pruefung 13), danach nur noch der leere Ordner.
    foreach ($pkg in @(Get-ChildItem -LiteralPath $work -Directory -ErrorAction SilentlyContinue)) {
        try { $null = Remove-PackageFolder -Path $pkg.FullName -PacketRoot $work } catch { $problems += "cleanup: $($_.Exception.Message)" }
    }
    Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $work) { $problems += "cleanup: $work is not empty" }
}

if ($problems.Count -gt 0) {
    foreach ($pr in $problems) { [Console]::WriteLine("FAIL: $pr") }
    exit 1
}
[Console]::WriteLine("Inventory and renewal: outdated/unstamped renewed with values kept, current untouched, content-less entry flagged. PASS")
exit 0
