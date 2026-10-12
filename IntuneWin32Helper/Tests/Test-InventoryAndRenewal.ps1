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
. (Join-Path $PSScriptRoot 'Get-ToolFunctionsAst.ps1')
$ast = Get-ToolFunctionsAst (Split-Path -Parent $functionsPath)
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
            -RootDir $rootDir -ToolVersion '0.0.1' -Architecture 'arm64' -MinimumOS 'W11_22H2' -MsiProductCode '{11111111-2222-3333-4444-555555555555}' `
            -DefinitionFingerprint (Get-DefinitionFingerprint -Record ([pscustomobject]@{ DisplayName = $name; Version = '1.0' }))
        $path = Join-Path $folder 'deploy.ps1'
        # Stempel wie bei einem Paket aus einer anderen Vorlage setzen/entfernen.
        # Das Skript kennt -Tenant (wie jede Vorlage seit 2.0.0).
        $text = [IO.File]::ReadAllText($path)
        $text = [regex]::Replace($text, '(?m)^#\s*ToolTemplateFingerprint:.*$', $stampLine)
        [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $true))
        return $path
    }

    # 1-3) Die Vorlage eines Pakets: veralteter Stempel, kein Stempel, aktueller Stempel. Ein Paket, dessen Vorlage nicht
    #      die aktuelle ist, wird nicht an Ort und Stelle erneuert (Update-DeployScript ist weg), sondern mit Build package
    #      neu gebaut: das Inventar nennt den Grund (BuildReason) und Next, die Knoepfe rechts davon sind gesperrt.
    $old  = New-Package 'Outdated' '# ToolTemplateFingerprint: 000000000000'
    $unst = New-Package 'Unstamped' ''
    $cur  = New-Package 'Current' ("# ToolTemplateFingerprint: $current")
    if (-not ([IO.File]::ReadAllText($old) -match '\$Tenant')) { $problems += "setup: package does not know -Tenant, test would prove nothing" }
    if (Get-Command -Name Update-DeployScript -ErrorAction SilentlyContinue) { $problems += 'Update-DeployScript exists again: a package is only made by Build package' }
    $tplDefs = @('Outdated', 'Unstamped', 'Current') | ForEach-Object { [pscustomobject]@{ DisplayName = $_; Version = '1.0' } }
    $tplInv = @(Get-AppInventory -Definitions $tplDefs -PacketRoot $work -RootDir $rootDir -IntuneApps @() 6>$null)
    $tplRow = @{}; foreach ($x in $tplInv) { $tplRow[$x.AppName] = $x }
    if ($tplRow['Outdated'].Template -ne 'outdated' -or $tplRow['Outdated'].Status -ne 'Outdated, rebuild: template changed') { $problems += "outdated: Template '$($tplRow['Outdated'].Template)' Status '$($tplRow['Outdated'].Status)'" }
    if ($tplRow['Unstamped'].Template -ne 'unstamped' -or $tplRow['Unstamped'].Status -ne 'Outdated, rebuild: template unstamped') { $problems += "unstamped: Template '$($tplRow['Unstamped'].Template)' Status '$($tplRow['Unstamped'].Status)'" }
    foreach ($n in 'Outdated', 'Unstamped') {
        if ($tplRow[$n].Next -ne 'build package, then publish' -or -not $tplRow[$n].BuildReason) { $problems += "$n : Next '$($tplRow[$n].Next)' BuildReason '$($tplRow[$n].BuildReason)', expected a build first" }
        $st = Get-InventoryActionState -Rows @($tplRow[$n])
        if (-not $st.Build -or $st.Publish -or $st.Remove) { $problems += "$n : Build=$($st.Build) Publish=$($st.Publish) Remove=$($st.Remove), expected only Build" }
    }
    if ($tplRow['Current'].Template -ne 'current' -or $tplRow['Current'].BuildReason) { $problems += "current: Template '$($tplRow['Current'].Template)' BuildReason '$($tplRow['Current'].BuildReason)'" }
    $stCur = Get-InventoryActionState -Rows @($tplRow['Current'])
    if ($stCur.Build -or -not $stCur.Publish) { $problems += "current: Build=$($stCur.Build) Publish=$($stCur.Publish), expected Publish only" }
    # 4) Inventar: Inhaltsloser Eintrag faellt auf
    # Was die Zeile "up to date" nennen darf: nur eine App, deren Vermerk den Stempel der Definition von heute traegt.
    # Eine App ohne Stempel (vom alten Werkzeug, von Hand) oder mit dem Stempel einer anderen Definition ist es nicht.
    $stampOf = { param($name) Get-DefinitionFingerprint -Record ([pscustomobject]@{ DisplayName = $name; Version = '1.0' }) }
    $null = New-Package 'IntNoStamp' ("# ToolTemplateFingerprint: $current")
    $null = New-Package 'IntOldStamp' ("# ToolTemplateFingerprint: $current")
    $null = New-Package 'IntForeignNote' ("# ToolTemplateFingerprint: $current")
    $null = New-Package 'Ghost' ("# ToolTemplateFingerprint: $current")
    $null = New-Package 'Twice' ("# ToolTemplateFingerprint: $current")
    $apps = @(
        [pscustomobject]@{ displayName = 'Current';  displayVersion = '1.0'; publishingState = 'published';    committedContentVersion = '1'; notes = (Format-IntuneAppNotes -ToolVersion '2.1.1' -DefinitionFingerprint (& $stampOf 'Current')) }
        [pscustomobject]@{ displayName = 'IntNoStamp';     displayVersion = '1.0'; publishingState = 'published'; committedContentVersion = '1'; notes = 'Created by IntuneWin32Helper 2.0.9' }
        [pscustomobject]@{ displayName = 'IntOldStamp';    displayVersion = '1.0'; publishingState = 'published'; committedContentVersion = '1'; notes = (Format-IntuneAppNotes -ToolVersion '2.1.1' -DefinitionFingerprint (& $stampOf 'Somebody else')) }
        [pscustomobject]@{ displayName = 'IntForeignNote'; displayVersion = '1.0'; publishingState = 'published'; committedContentVersion = '1'; notes = 'imported by hand' }
        [pscustomobject]@{ displayName = 'Ghost';    displayVersion = '1.0'; publishingState = 'notPublished'; committedContentVersion = ''  }
        [pscustomobject]@{ displayName = 'Twice';    displayVersion = '1.0'; publishingState = 'published';    committedContentVersion = '1' }
        [pscustomobject]@{ displayName = 'Twice';    displayVersion = '1.0'; publishingState = 'notPublished'; committedContentVersion = ''  }
    )
    $defs = @('Current', 'Ghost', 'Twice', 'IntNoStamp', 'IntOldStamp', 'IntForeignNote') | ForEach-Object { [pscustomobject]@{ DisplayName = $_; Version = '1.0' } }
    $inv = @(Get-AppInventory -Definitions $defs -PacketRoot $work -RootDir $rootDir -IntuneApps $apps 6>$null)
    $row = @{}; foreach ($x in $inv) { $row[$x.AppName] = $x }
    if ($row['Current'].Intune -ne 'yes' -or $row['Current'].Next -ne 'up to date') { $problems += "inventory Current: '$($row['Current'].Intune)' / '$($row['Current'].Next)'" }
    if ($row['Current'].IntuneDefinition -ne 'current') { $problems += "inventory Current: IntuneDefinition '$($row['Current'].IntuneDefinition)'" }
    foreach ($case in @(@('IntNoStamp', 'unknown'), @('IntOldStamp', 'changed'), @('IntForeignNote', 'unknown'))) {
        $r2 = $row[$case[0]]
        if ($r2.IntuneDefinition -ne $case[1])                       { $problems += "inventory $($case[0]): IntuneDefinition '$($r2.IntuneDefinition)', expected '$($case[1])'" }
        if ($r2.Next -ne 'publish (updates the app in Intune)')      { $problems += "inventory $($case[0]): Next '$($r2.Next)' - 'up to date' without proof, or no way to the update" }
    }
    if ($row['Ghost'].Intune -ne 'no content')                                     { $problems += "inventory Ghost: Intune '$($row['Ghost'].Intune)', expected 'no content'" }
    if ($row['Ghost'].Next -notmatch 'without content')                             { $problems += "inventory Ghost: Next '$($row['Ghost'].Next)'" }
    if ($row['Twice'].Intune -ne 'yes (2x, 1 without content)')                     { $problems += "inventory Twice: Intune '$($row['Twice'].Intune)'" }

    # 5) Der Vermerk der App: schreiben und zuruecklesen; der Anfang bleibt das Kennzeichen "von diesem Werkzeug".
    $fp = Get-DefinitionFingerprint -Record ([pscustomobject]@{ DisplayName = 'X'; Version = '1' })
    $notes = Format-IntuneAppNotes -ToolVersion '2.1.1' -DefinitionFingerprint $fp
    if ($notes -notlike 'Created by IntuneWin32Helper 2.1.1*')                                  { $problems += "notes: '$notes' does not start with the tool marker" }
    if ((Get-IntuneAppDefinitionFingerprint -App ([pscustomobject]@{ notes = $notes })) -ne $fp) { $problems += "notes: stamp not read back from '$notes'" }
    if (-not (Test-IntuneAppCreatedByTool -App ([pscustomobject]@{ notes = $notes })))           { $problems += "notes: Test-IntuneAppCreatedByTool rejects '$notes'" }
    $bare = Format-IntuneAppNotes -ToolVersion '2.1.1' -DefinitionFingerprint ''
    if ($bare -ne 'Created by IntuneWin32Helper 2.1.1' -or (Get-IntuneAppDefinitionFingerprint -App ([pscustomobject]@{ notes = $bare }))) { $problems += "notes: without a stamp: '$bare'" }
    if (Get-IntuneAppDefinitionFingerprint -App ([pscustomobject]@{ notes = 'imported; definition 0123456789ab' })) { $problems += 'notes: a foreign note with the same words counts as a stamp' }
    # Das erzeugte deploy.ps1 setzt den Vermerk (beim Anlegen und beim Update) mit dem Stempel des Pakets.
    $cmdText = [IO.File]::ReadAllText($cur)
    if ($cmdText -notmatch 'Format-IntuneAppNotes -ToolVersion "0\.0\.1" -DefinitionFingerprint "[0-9a-f]{12}"') { $problems += 'notes: deploy.ps1 does not build the note with the stamp of the package' }
    if (([regex]::Matches($cmdText, '-Notes \$AppNotes')).Count -ne 2)                           { $problems += 'notes: deploy.ps1 must pass -Notes $AppNotes to Add-IntuneWin32App AND Set-IntuneWin32App' }
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
[Console]::WriteLine("Inventory: a package from an older template must be built again, a current one is publishable, an app in Intune is up to date only with the stamp of the definition, content-less entry flagged. PASS")
exit 0
