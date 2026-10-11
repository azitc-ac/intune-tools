# ============================================================================
#  Vorlagen und Skripte im Paket: Fingerabdruck der Vorlagen, detection.ps1 und deploy.ps1 schreiben und erneuern,
#  Paketordner lesen.
# ============================================================================

function Open-ScriptForEditing {
    <#
        Oeffnet ein Skript zum Nachbessern. powershell_ise ist abgekuendigt und
        auf Server Core nicht vorhanden - deshalb erst ISE, sonst Notepad.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Get-Command -Name 'powershell_ise.exe' -ErrorAction SilentlyContinue) {
        Start-Process -FilePath 'powershell_ise.exe' -ArgumentList $Path
        return
    }
    Start-Process -FilePath 'notepad.exe' -ArgumentList $Path
}

function Get-TemplateFingerprint {
    <#
        .SYNOPSIS
        Kurz-Hash ueber die Vorlagen, aus denen ein Paket erzeugt wird.

        .DESCRIPTION
        Wird beim Erstellen in das erzeugte deploy.ps1 gestempelt. Das Inventar
        vergleicht den Stempel gegen den aktuellen Stand und zeigt damit, welches
        Paket aus einer aelteren Vorlage stammt.

        Ohne das ist "veraltet" nicht sichtbar. Genau daran hing die Entscheidung,
        die Artefakte weiter im Paket zu lassen: unveraenderliche Pakete sind gut,
        aber nur wenn man sieht, welche nachgezogen werden sollten.

        Gehasht wird der INHALT, nicht der Zeitstempel - ein Kopieren des Repos
        darf den Fingerprint nicht veraendern.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RootDir)

    $templateDir = Join-Path $RootDir 'Templates'
    $names = @('deploy_template.ps1', 'detection_template.ps1', 'detection_template-WinGetApp.ps1') | Sort-Object

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $builder = New-Object System.Text.StringBuilder
        foreach ($name in $names) {
            $path = Join-Path $templateDir $name
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $hash = $sha.ComputeHash([System.IO.File]::ReadAllBytes($path))
            $null = $builder.Append($name).Append(':').Append([BitConverter]::ToString($hash).Replace('-', '')).Append(';')
        }
        if ($builder.Length -eq 0) { return '' }
        $final = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($builder.ToString()))
        return ([BitConverter]::ToString($final).Replace('-', '').Substring(0, 12).ToLowerInvariant())
    }
    finally { $sha.Dispose() }
}

function Get-PackageTemplateFingerprint {
    <#
        Liest den Vorlagen-Stempel aus einem erzeugten deploy.ps1. Leer heisst:
        das Paket stammt aus einer Zeit vor dem Stempel - das ist ein anderer
        Zustand als "veraltet" und wird im Inventar auch anders angezeigt.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$DeployScriptPath)

    if ([string]::IsNullOrWhiteSpace($DeployScriptPath)) { return '' }
    if (-not (Test-Path -LiteralPath $DeployScriptPath)) { return '' }

    $raw = Get-Content -LiteralPath $DeployScriptPath -Raw
    $match = [regex]::Match($raw, '(?m)^#\s*ToolTemplateFingerprint:\s*(\S+)')
    if (-not $match.Success) { return '' }

    $value = $match.Groups[1].Value
    # Der unersetzte Platzhalter ist kein Fingerprint.
    if ($value -eq '#TPLFP#') { return '' }
    return $value
}

function Get-DefinitionFingerprint {
    <#
        Kurz-Hash ueber die Felder einer Definition (Apps.csv-Zeile), die in ein Paket und in die App in Intune
        eingehen. Wird beim Bauen in deploy.ps1 gestempelt (# ToolDefinitionFingerprint:). Das Inventar vergleicht
        ihn mit der Zeile von heute: weicht er ab, wurde die Definition nach dem Bau geaendert und das Paket
        spiegelt sie nicht mehr. Eigene Spalten und die Reihenfolge der Spalten zaehlen nicht.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Record)

    $fields = @('DisplayName', 'Version', 'Publisher', 'ProgramID', 'WinGetParams', 'SingleMSI', 'MsiProductCode', 'logoURL',
                'InstallCmd', 'UninstallCmd', 'Interactive', 'Architecture', 'MinimumOS', 'ArpName')
    $builder = New-Object System.Text.StringBuilder
    foreach ($field in $fields) {
        $value = ([string]$Record.$field).Trim()
        # Wahrheitswerte: "true", "TRUE" und "True" sind dieselbe Aussage
        if ($field -in 'SingleMSI', 'Interactive') { $value = $value.ToLowerInvariant() }
        $null = $builder.Append($field).Append('=').Append($value).Append("`n")
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($builder.ToString()))
        return ([BitConverter]::ToString($hash).Replace('-', '').Substring(0, 12).ToLowerInvariant())
    }
    finally { $sha.Dispose() }
}

function Get-PackageDefinitionFingerprint {
    <# Liest den Definitions-Stempel aus einem deploy.ps1. Leer: das Paket wurde ohne ihn gebaut (aelter als der Stempel). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$DeployScriptPath)

    if ([string]::IsNullOrWhiteSpace($DeployScriptPath)) { return '' }
    if (-not (Test-Path -LiteralPath $DeployScriptPath)) { return '' }
    $match = [regex]::Match((Get-Content -LiteralPath $DeployScriptPath -Raw), '(?m)^#\s*ToolDefinitionFingerprint:[ \t]*(\S*)')
    if (-not $match.Success) { return '' }
    $value = $match.Groups[1].Value
    if ($value -eq '#DEFFP#') { return '' }
    return $value
}

function Format-IntuneAppNotes {
    <#
        Der Vermerk, den deploy.ps1 beim Anlegen UND beim Update in die App schreibt:
        "Created by IntuneWin32Helper <Version>; definition <Stempel>". Der Anfang zeigt, dass die App von diesem
        Werkzeug stammt (Test-IntuneAppCreatedByTool); der Stempel ist der Stand der Definition, aus der das Paket
        gebaut wurde (Get-DefinitionFingerprint). Ohne Stempel (Paket aus der Zeit davor) bleibt nur der Anfang.
    #>
    param(
        [AllowEmptyString()][string]$ToolVersion = '',
        [AllowEmptyString()][string]$DefinitionFingerprint = ''
    )
    $text = ('Created by IntuneWin32Helper {0}' -f $ToolVersion).TrimEnd()
    if ($DefinitionFingerprint -match '^[0-9a-f]{12}$') { $text += ('; definition {0}' -f $DefinitionFingerprint) }
    return $text
}

function Get-IntuneAppDefinitionFingerprint {
    <# Liest den Definitions-Stempel aus dem Vermerk einer Intune-App. Leer: die App hat keinen (angelegt vor dem Stempel, von Hand oder fremd). #>
    param([Parameter(Mandatory = $true)]$App)
    $match = [regex]::Match([string]$App.notes, '^Created by IntuneWin32Helper[^;]*;\s*definition\s+([0-9a-f]{12})\s*$')
    if ($match.Success) { return $match.Groups[1].Value }
    return ''
}

function Get-ArpSearchName {
    <#
        Der Name, unter dem die App in der Programmliste (Uninstall-Schluessel)
        gesucht wird - fuer Erkennung UND Deinstallation. Apps.csv-Spalte
        "ArpName"; leer heisst: wie DisplayName (das bisherige Verhalten).

        Im Feld (2026-09-28/29) stimmten die beiden nicht immer ueberein: die
        Test-Apps hiessen "IW32H-Feldtest ...", und VC++ heisst seit 14.50 in der
        Programmliste "... v14 Redistributable" statt "2015-2022". Die Erkennung
        musste von Hand angepasst werden.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$DisplayName,
        [AllowEmptyString()][AllowNull()][string]$ArpName
    )
    if (-not [string]::IsNullOrWhiteSpace($ArpName)) { return $ArpName.Trim() }
    return $DisplayName
}

function Write-DetectionScript {
    <#
        .SYNOPSIS
        Erzeugt detection.ps1 eines App-Ordners aus der aktuellen Vorlage.

        .DESCRIPTION
        Anlegen (createApps) und Erneuern (Update-DeployScript) teilen diesen
        einen Pfad - wie Write-DeployScript fuer deploy.ps1. Frueher wurde
        detection.ps1 nur in createApps gerendert, Update-DeployScript fasste es
        nicht an: der Vorlagen-Stempel (ueber ALLE Vorlagen) stand nach dem
        Erneuern auf "current", die Erkennung im Paket blieb aber die alte -
        eine Korrektur wie "kein HKCU" erreichte kein bestehendes Paket.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AppFolder,
        [Parameter(Mandatory = $true)][string]$AppName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$AppVersion,
        [Parameter(Mandatory = $true)][string]$RootDir,
        [AllowEmptyString()][string]$ProgramId = '',
        [AllowEmptyString()][string]$ArpName = ''
    )

    $target = Join-Path $AppFolder 'detection.ps1'
    if ($AppVersion -eq 'LatestAvailable') {
        if ([string]::IsNullOrWhiteSpace($ProgramId)) { throw "Write-DetectionScript: WinGet app '$AppName' without ProgramID" }
        $template = Get-Content -LiteralPath (Join-Path $RootDir 'Templates\detection_template-WinGetApp.ps1')
        $template -replace "WINGETPROGRAMID", $ProgramId | Out-File $target -Encoding utf8 -Force
    }
    else {
        $template = Get-Content -LiteralPath (Join-Path $RootDir 'Templates\detection_template.ps1')
        $template -replace "#DN#", $AppName -replace "#VER#", $AppVersion `
            -replace "#ARPNAME#", (Get-ArpSearchName -DisplayName $AppName -ArpName $ArpName) |
            Out-File $target -Encoding utf8 -Force
    }
}

function ConvertTo-InteractiveFlag {
    <#
        Normalisiert die Apps.csv-Spalte "Interactive" auf 'true' oder ''.
        Leer (und alles andere) heisst: Standard, ohne Dialog und ohne ServiceUI.
    #>
    param([AllowEmptyString()][AllowNull()][string]$Value)
    if ($Value -match '^\s*(?i)(true|1|yes|ja|x)\s*$') { return 'true' }
    return ''
}

function Get-DeployCommandLine {
    <#
        .SYNOPSIS
        Install- und Uninstall-Befehl fuer Intune - die EINZIGE Stelle, die
        ueber ServiceUI entscheidet.

        .DESCRIPTION
        Standard (Apps.csv-Spalte "Interactive" leer): PSADT still in Session 0,
        OHNE ServiceUI. Frueher lief JEDE App ueber
          ServiceUi.exe -Process:Explorer.exe Invoke-AppDeployToolkit.exe ... -DeployMode Silent
        ServiceUI holt den Prozess als SYSTEM in die Sitzung des Benutzers; mit
        -DeployMode Silent zeigte PSADT dort aber ohnehin keinen Dialog. Uebrig
        blieb nur das Risiko: Greenshots Setup startete die App nach der
        Installation selbst - im Feld (2026-09-28/29) lief Greenshot.exe danach
        als SYSTEM auf dem Desktop des Benutzers (Besitzer SYSTEM, Session 2,
        von einer Admin-Sitzung bestaetigt). Ein SYSTEM-Prozess mit Dateidialogen
        ist ein Weg zur Rechteausweitung.

        Interactive = true: ServiceUI plus PSADT ohne "Silent" (DeployMode Auto),
        damit Dialoge wie "App bitte schliessen" wirklich erscheinen. Das
        Restrisiko bleibt fuer genau diese Pakete: startet ihr Setup die App
        selbst, laeuft sie als SYSTEM beim Benutzer.

        .OUTPUTS
        Objekt mit Install, Uninstall und NeedsServiceUI.
    #>
    param([AllowEmptyString()][AllowNull()][string]$Interactive)

    if ((ConvertTo-InteractiveFlag -Value $Interactive) -eq 'true') {
        return [pscustomobject]@{
            Install        = 'ServiceUi.exe -Process:Explorer.exe Invoke-AppDeployToolkit.exe -DeploymentType Install'
            Uninstall      = 'ServiceUi.exe -Process:Explorer.exe Invoke-AppDeployToolkit.exe -DeploymentType Uninstall'
            NeedsServiceUI = $true
        }
    }
    return [pscustomobject]@{
        Install        = 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent'
        Uninstall      = 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent'
        NeedsServiceUI = $false
    }
}

function Write-DeployScript {
    <#
        .SYNOPSIS
        Erzeugt das deploy.ps1 eines App-Ordners aus der aktuellen Vorlage.

        .DESCRIPTION
        Anlegen (createApps) und Erneuern (Update-DeployScript) teilen diesen
        einen Pfad. Ohne das wirkt eine Vorlagenaenderung nur auf neu erstellte
        Apps, waehrend bereits erstellte Ordner ihre alte Kopie behalten.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AppFolder,
        [Parameter(Mandatory = $true)][string]$AppName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$AppVersion,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Publisher,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Description,
        [Parameter(Mandatory = $true)][string]$RootDir,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ToolVersion,

        # Requirement Rule je App. Leer bedeutet die bisherigen Vorgaben
        # x64 / W10_20H2 - bestehende Apps.csv-Zeilen ohne diese Spalten
        # verhalten sich also unveraendert.
        [AllowEmptyString()][string]$Architecture = '',
        [AllowEmptyString()][string]$MinimumOS = '',

        # MSI-ProductCode aus Apps.csv. Ist er gesetzt, erkennt Intune die App
        # nativ ueber den ProductCode statt ueber ein Skript.
        [AllowEmptyString()][string]$MsiProductCode = '',

        # Apps.csv-Spalte "Interactive": 'true' = PSADT-Dialoge ueber ServiceUI,
        # leer = still und ohne ServiceUI (siehe Get-DeployCommandLine).
        [AllowEmptyString()][string]$Interactive = '',

        # Stand der Definition, aus der gebaut wird (Get-DefinitionFingerprint). Leer = unbekannt: beim Erneuern
        # aus der Vorlage gibt Update-DeployScript den Stempel des alten Skripts weiter.
        [AllowEmptyString()][string]$DefinitionFingerprint = ''
    )

    $templatePath = Join-Path (Join-Path $RootDir "Templates") "deploy_template.ps1"
    if (-not (Test-Path -LiteralPath $templatePath)) {
        throw "Deploy template not found: $templatePath"
    }

    $template = Get-Content -LiteralPath $templatePath
    $template -replace "#ROOT#", $RootDir -replace "#DN#", $AppName -replace "#PN#", $AppName `
        -replace "#PUB#", $Publisher -replace "#DM#", "DetectionScript" -replace "#VER#", $AppVersion `
        -replace "#DESC#", $Description -replace "#TOOLVER#", $ToolVersion `
        -replace "#ARCH#", $Architecture -replace "#MINOS#", $MinimumOS `
        -replace "#MSIPRODUCTCODE#", $MsiProductCode `
        -replace "#INTERACTIVE#", (ConvertTo-InteractiveFlag -Value $Interactive) `
        -replace "#TPLFP#", (Get-TemplateFingerprint -RootDir $RootDir) `
        -replace "#DEFFP#", $DefinitionFingerprint |
        Out-File (Join-Path $AppFolder "deploy.ps1") -Encoding utf8 -Force
}

function Update-DeployScript {
    <#
        .SYNOPSIS
        Zieht ein vorhandenes deploy.ps1 auf die aktuelle Vorlage nach.

        .DESCRIPTION
        Erneuert wird, was das Inventar als "outdated" oder "unstamped" fuehrt:
        der Vorlagen-Stempel im Skript weicht vom aktuellen Stand ab oder fehlt.
        Die app-spezifischen Werte werden aus dem alten Skript uebernommen, das
        alte als deploy.ps1.bak gesichert. Ein Skript mit aktuellem Stempel
        bleibt unberuehrt - auch wenn es von Hand angepasst wurde.

        Frueher entschied hier ein anderes Merkmal als im Inventar: erneuert
        wurde nur ein Skript OHNE $Tenant/Initialize-IntuneConnection. Das kennt
        aber schon die Vorlage von 2.0.0 - im Feld (2026-09-28) wurde dadurch
        weder ein Paket aus 2.0.0 noch eines mit veraltetem Stempel erneuert,
        obwohl das Inventar "renew from template" anzeigte. Vorlagen-Korrekturen
        erreichten bestehende Pakete nie.

        .OUTPUTS
        [bool] $true, wenn erneuert wurde.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DeployScriptPath,
        [Parameter(Mandatory = $true)][string]$RootDir,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ToolVersion
    )

    if (-not (Test-Path -LiteralPath $DeployScriptPath)) { return $false }

    # Schon aktuell? Dann nichts anfassen. Dasselbe Merkmal wie im Inventar
    # (Get-AppInventory, Spalte Template) - sonst zeigt das eine "outdated" und
    # das andere erneuert trotzdem nicht.
    $stamp = Get-PackageTemplateFingerprint -DeployScriptPath $DeployScriptPath
    if ($stamp -and $stamp -eq (Get-TemplateFingerprint -RootDir $RootDir)) { return $false }

    $raw = Get-Content -LiteralPath $DeployScriptPath -Raw

    $readValue = {
        param($text, $name)
        $m = [regex]::Match($text, ('(?m)^\s*\$' + $name + '\s*=\s*"(.*?)"\s*$'))
        if ($m.Success) { return $m.Groups[1].Value }
        return ""
    }

    $appFolder   = Split-Path -Parent $DeployScriptPath
    $appName     = & $readValue $raw "PackageName"
    $appVersion  = & $readValue $raw "AppVersion"
    $publisher   = & $readValue $raw "Publisher"
    $description = & $readValue $raw "Description"
    # In aelteren Skripten gibt es diese beiden nicht - dann bleiben sie leer
    # und Write-DeployScript setzt die Vorgaben.
    $architecture   = & $readValue $raw "Architecture"
    $minimumOS      = & $readValue $raw "MinimumOS"
    $msiProductCode = & $readValue $raw "MsiProductCode"
    # Aeltere Skripte kennen die Spalte nicht - leer heisst Standard (ohne
    # ServiceUI). Ein als interaktiv gebautes Paket bleibt beim Erneuern interaktiv.
    $interactive    = & $readValue $raw "Interactive"

    # Fallback: Werte aus dem Ordnernamen ableiten - ueber dieselbe Funktion, die
    # auch Get-DeployScripts benutzt, statt einer zweiten Zerlegung.
    if (-not $appName) {
        $parsed = Parse-AppFolderName -FolderName (Split-Path -Leaf $appFolder)
        $appName = $parsed.AppName
        if (-not $appVersion) { $appVersion = $parsed.AppVersion }
    }

    Copy-Item -LiteralPath $DeployScriptPath -Destination ($DeployScriptPath + ".bak") -Force
    Write-Host ("Updating outdated deploy.ps1 from template: {0} (backup: deploy.ps1.bak)" -f $DeployScriptPath) -ForegroundColor Yellow

    # Erneuert wird aus den Werten des alten Skripts, nicht aus Apps.csv: der Definitions-Stempel bleibt, wie er war
    # (zeigte er "Definition geaendert", bleibt er es - das Erneuern aus der Vorlage holt keine Aenderung der Definition nach).
    Write-DeployScript -AppFolder $appFolder -AppName $appName -AppVersion $appVersion `
        -Publisher $publisher -Description $description -RootDir $RootDir -ToolVersion $ToolVersion `
        -Architecture $architecture -MinimumOS $minimumOS -MsiProductCode $msiProductCode `
        -Interactive $interactive -DefinitionFingerprint (Get-PackageDefinitionFingerprint -DeployScriptPath $DeployScriptPath)

    # detection.ps1 gehoert zum selben Stempel - mit erneuern. Suchname und
    # WinGet-ID kommen aus dem alten Skript: $ArpName, sonst $PackageID (dort
    # stand in aelteren Paketen der Suchname, ggf. von Hand angepasst).
    $detectionPath = Join-Path $appFolder 'detection.ps1'
    if (Test-Path -LiteralPath $detectionPath) {
        $oldDetection = Get-Content -LiteralPath $detectionPath -Raw
        $oldArpName   = & $readValue $oldDetection "ArpName"
        $oldPackageId = & $readValue $oldDetection "PackageID"
        if (-not $oldArpName -and $appVersion -ne 'LatestAvailable') { $oldArpName = $oldPackageId }
        Copy-Item -LiteralPath $detectionPath -Destination ($detectionPath + ".bak") -Force
        Write-DetectionScript -AppFolder $appFolder -AppName $appName -AppVersion $appVersion -RootDir $RootDir `
            -ProgramId $oldPackageId -ArpName $oldArpName
        Write-Host ("Updated detection.ps1 from template (backup: detection.ps1.bak)") -ForegroundColor Yellow
    }

    return $true
}

# ============================================================================
#  Paketordner lesen
#  Diese beiden Funktionen lagen INNERHALB von deployApps und waren dadurch
#  nirgends sonst aufrufbar - Update-DeployScript musste das Zerlegen des
#  Ordnernamens eigenstaendig nachbauen. Jetzt auf oberster Ebene, eine Quelle.
# ============================================================================
function Parse-AppFolderName {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FolderName,
        [Parameter(Mandatory=$false)]
        [string]$Delimiter = ' - '
    )

    # Standardwerte
    $appName = $FolderName
    $appVersion = ''

    if ($FolderName -and $Delimiter -and $FolderName.Contains($Delimiter)) {
        $lastIndex = $FolderName.LastIndexOf($Delimiter)
        if ($lastIndex -ge 0) {
            $left  = $FolderName.Substring(0, $lastIndex)
            $right = $FolderName.Substring($lastIndex + $Delimiter.Length)
            if ($left)  { $appName    = $left.Trim() }
            if ($right) { $appVersion = $right.Trim() }
        }
    }

    # Rückgabe als Objekt
    return [pscustomobject]@{
        AppName    = $appName
        AppVersion = $appVersion
    }
}

function Get-DeployScripts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PacketRoot,

        [Parameter(Mandatory = $false)]
        [string]$Delimiter = ' - ',

        [Parameter(Mandatory = $false)]
        [switch]$Recurse,

        [Parameter(Mandatory = $false)]
        [string]$ExportCsvPath
    )

    if (-not (Test-Path -LiteralPath $PacketRoot)) {
        throw "PacketRoot does not exist: $PacketRoot"
    }

    # Unterverzeichnisse holen (optional rekursiv)
    if ($Recurse) {
        $dirs = Get-ChildItem -LiteralPath $PacketRoot -Directory -Recurse
    } else {
        $dirs = Get-ChildItem -LiteralPath $PacketRoot -Directory
    }

    $results = @()

    foreach ($dir in $dirs) {
        $deployPath = Join-Path -Path $dir.FullName -ChildPath 'deploy.ps1'

        if (Test-Path -LiteralPath $deployPath) {
            $parsed = Parse-AppFolderName -FolderName $dir.Name -Delimiter $Delimiter

            $fi = Get-Item -LiteralPath $deployPath
            $obj = [pscustomobject]@{
                AppName      = $parsed.AppName
                AppVersion   = $parsed.AppVersion
                LastModified = $fi.LastWriteTime
                FullPath     = $fi.FullName
            }

            $results += $obj
        }
    }

    # Optional: CSV exportieren
    if ($ExportCsvPath -and $ExportCsvPath.Trim().Length -gt 0) {
        try {
            $results | Export-Csv -Path $ExportCsvPath -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        } catch {
            Write-Warning ("Konnte CSV nicht schreiben: {0}" -f (Format-ErrorDetail $_))
        }
    }

    return $results
}
