# ============================================================================
#  Kern: Dialog-Rueckgaben, Aufruf von Modulfunktionen, Konfiguration, Protokoll, Fehlermeldungen,
#  Tenant-Anmeldung und die Voraussetzungspruefung. Alles, was fast jede andere Datei braucht.
# ============================================================================

function Get-DialogSelection {
    <#
        .SYNOPSIS
        Liefert nur die echten Datensaetze einer Dialog-Rueckgabe.

        .DESCRIPTION
        WPF-Methoden wie UIElementCollection.Add() geben den Einfuege-Index (int)
        zurueck. Wird dieser Wert in einer Funktion nicht unterdrueckt, landet er
        im Ausgabestrom und vermischt sich mit dem eigentlichen Ergebnis - daher
        die frueheren "$_ -isnot [int]"-Filter an den Aufrufstellen. Die Ursache
        ist jetzt in den Dialogen selbst behoben ([void] vor jedem .Add());
        diese Funktion ist die einzige Stelle, die das Ergebnis zusaetzlich
        absichert, statt an jeder Aufrufstelle eigene Filter zu pflegen.
    #>
    param($Value)

    if ($null -eq $Value) { return @() }
    return @($Value | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] })
}

function Get-SingleDialogSelection {
    <#
        Wie Get-DialogSelection, liefert aber hoechstens einen Datensatz - fuer
        Dialoge, bei denen genau eine Auswahl gemeint ist (z.B. der Tenant).
    #>
    param($Value)
    return (Get-DialogSelection -Value $Value | Select-Object -First 1)
}

function Test-IntuneAccessToken {
    <#
        Kapselt Test-AccessToken aus dem Modul IntuneWin32App. Fehlt das Cmdlet
        oder wirft es, gilt "kein gueltiger Token" - dann wird neu angemeldet,
        statt den Lauf abzubrechen.
    #>
    if (-not (Get-Command -Name Test-AccessToken -ErrorAction SilentlyContinue)) { return $false }
    try   { return [bool](Invoke-IntuneModuleCall -Label 'Test-AccessToken' -Operation { Test-AccessToken }) }
    catch { return $false }
}

function Invoke-IntuneModuleCall {
    <#
        .SYNOPSIS
        Einziger Weg, ein Cmdlet des Moduls IntuneWin32App aufzurufen.

        .DESCRIPTION
        Das Modul beendet mehrere Fehlerpfade mit "Write-Warning ...; break"
        statt mit throw (1.5.0: Add-IntuneWin32App kein Token / Body abgelehnt,
        Get-IntuneWin32App und Update-IntuneWin32AppPackageFile kein Token,
        Get-IntuneWin32AppMetaData). Ein break ohne umschliessende Schleife sucht
        sich die naechste Schleife beim AUFRUFER - try/catch faengt es nicht:
          - im deploy.ps1 lief der Guard "Upload FAILED" dadurch nie, und die
            foreach-Schleife in createApps/deployApps endete stillschweigend -
            die restlichen Apps des Stapels wurden nicht versucht, die
            Zusammenfassung meldete "0 succeeded, 0 failed";
          - in deployApps haette es die while-Schleife des Startskripts beendet
            und damit das ganze Tool geschlossen.
        Die do/while($false)-Huelle hier faengt das break ab; ein so beendeter
        Aufruf wird zur Exception, die die Aufrufer schon behandeln.

        Zweitens laeuft der Aufruf unter der InvariantCulture. IntuneWin32App
        1.5.0 liest das Token-Ablaufdatum per
        [DateTimeOffset]::Parse($Global:AccessToken.ExpiresOn.ToString(), InvariantCulture, ...)
        - ToString() formatiert aber in der Kultur des Rechners. Unter de-DE
        ("28.09.2026 10:20:17 +00:00") wirft das ab dem 13. eines Monats, bis zum
        12. vertauscht es still Tag und Monat. Da Invoke-MSGraphOperation vor
        JEDEM Graph-Aufruf Test-AccessToken ruft, scheiterte im Feld (2026-09-28,
        Windows 11 de-DE) jeder Upload schon an der Abfrage vorhandener Apps.
        1.4.4 rechnete kulturunabhaengig; check-prereqs installiert aber die
        neueste Version.

        .PARAMETER Operation
        Der Aufruf als Scriptblock, z.B. { Get-IntuneWin32App -DisplayName $n }.

        .PARAMETER Label
        Name fuer die Fehlermeldung, ueblicherweise das Cmdlet.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        [Parameter(Mandatory = $true)][string]$Label
    )

    # Eigene, unverwechselbare Namen: der Scriptblock sieht die Variablen dieser
    # Funktion (dynamischer Gueltigkeitsbereich) und darf keine davon verdecken.
    $intuneModuleCallDone    = $false
    $intuneModuleCallResult  = $null
    $intuneModuleCallCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
    do {
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
            $intuneModuleCallResult = & $Operation
            $intuneModuleCallDone   = $true
        }
        finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $intuneModuleCallCulture
        }
    } while ($false)

    if (-not $intuneModuleCallDone) {
        throw ("{0} was aborted inside the IntuneWin32App module (see the warning above) - no result." -f $Label)
    }
    return $intuneModuleCallResult
}

function Get-ToolConfigPath {
    <#
        .SYNOPSIS
        Liefert den Pfad zur config.json und legt sie beim ersten Start an.

        .DESCRIPTION
        Config\config.json ist nicht versioniert, weil sie clientSecret im
        Klartext aufnimmt. In einem frischen Clone fehlt sie deshalb und wird
        hier einmalig aus Config\config.sample.json erzeugt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RootDir
    )

    $configPath = Join-Path (Join-Path $RootDir "Config") "config.json"
    if (Test-Path -LiteralPath $configPath) { return $configPath }

    $samplePath = Join-Path (Join-Path $RootDir "Config") "config.sample.json"
    if (-not (Test-Path -LiteralPath $samplePath)) {
        throw "Neither Config\config.json nor Config\config.sample.json found under $RootDir"
    }

    Write-Host "Config\config.json not found - creating it from Config\config.sample.json." -ForegroundColor Yellow
    Copy-Item -LiteralPath $samplePath -Destination $configPath
    Write-Host "Fill in tenants and packetRoot before deploying (gear icon in the start dialog)." -ForegroundColor Yellow

    return $configPath
}

function Get-ToolConfig {
    <#
        Einziger Lesepfad fuer die Konfiguration. start-IntuneWin32Helper.ps1,
        createApps und das erzeugte deploy.ps1 benutzen ausschliesslich diese
        Funktion - sonst driften Pfad, Kodierung und das Anlegen der Datei.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RootDir
    )

    $configPath = Get-ToolConfigPath -RootDir $RootDir
    return (Get-Content -Raw -Path $configPath -Encoding UTF8 | ConvertFrom-Json)
}

function Start-ToolTranscript {
    <#
        .SYNOPSIS
        Startet das Sitzungsprotokoll und stellt das Logs-Verzeichnis sicher.

        .DESCRIPTION
        Logs\ ist nicht versioniert und existiert in einem frischen Clone nicht.
        Ob Start-Transcript ein fehlendes Verzeichnis selbst anlegt, haengt von
        der PowerShell-Version ab (7.4 legt es an) - hier wird es ausdruecklich
        angelegt, damit das Verhalten nicht davon abhaengt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RootDir
    )

    $logDir = Join-Path $RootDir "Logs"
    if (-not (Test-Path -LiteralPath $logDir)) {
        $null = New-Item -Path $logDir -ItemType Directory -Force
    }

    $logPath = Join-Path $logDir ((Get-Date -Format "yyyy-MM-dd_HH-mm-ss") + ".log")
    Start-Transcript -Path $logPath | Out-Null
    return $logPath
}

# Eine Fehlermeldung mit der Stelle, von der sie kommt. "Cannot validate argument" sagt nicht, welcher der vielen
# Aufrufe eines Laufs sie ausgeloest hat; Datei und Zeile stehen im ErrorRecord und kosten nichts (Muster aus
# SCCMAppHelper). Fehler aus dem Intune-Modul bleiben sonst anonym.
function Format-ErrorDetail {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $message = [string]$ErrorRecord.Exception.Message
    $info    = $ErrorRecord.InvocationInfo
    if ($info -and $info.ScriptName) {
        return ('{0} ({1}:{2})' -f $message, (Split-Path -Leaf $info.ScriptName), $info.ScriptLineNumber)
    }
    return $message
}

function Write-DeploymentSummary {
    <#
        .SYNOPSIS
        Fasst das Ergebnis eines Deploy-Laufs zusammen.

        .DESCRIPTION
        Add-IntuneWin32App wirft bei einem fehlgeschlagenen Upload keine Exception,
        sondern warnt nur. Das erzeugte deploy.ps1 prueft das Ergebnis und wirft
        deshalb selbst; hier wird der Fehlschlag aufgefangen, damit ein Bulk-Lauf
        weiterlaeuft, und am Ende sichtbar aufgelistet. Ohne diese Ausgabe geht ein
        Fehlschlag zwischen hunderten Zeilen Verbose-Ausgabe unter.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Succeeded = @(),
        [string[]]$Failed = @(),
        # "<Name> - <Version>: <Grund>" - Apps, die der Plan bewusst nicht angefasst hat.
        [string[]]$Skipped = @()
    )

    $okCount   = @($Succeeded).Count
    $failCount = @($Failed).Count
    $skipCount = @($Skipped).Count

    Write-Host ""
    Write-Host ("Deployment summary: {0} succeeded, {1} failed, {2} skipped." -f $okCount, $failCount, $skipCount) -ForegroundColor Cyan
    foreach ($name in $Succeeded) { Write-Host ("  OK      {0}" -f $name) -ForegroundColor Green }
    foreach ($name in $Failed)    { Write-Host ("  FAILED  {0}" -f $name) -ForegroundColor Red }
    foreach ($name in $Skipped)   { Write-Host ("  SKIPPED {0}" -f $name) -ForegroundColor Yellow }

    if ($failCount -gt 0) {
        Write-Host "A failed upload can leave an app without content in Intune - remove those entries." -ForegroundColor Yellow
    }
}

function Initialize-IntuneConnection {
    <#
        .SYNOPSIS
        Waehlt den Ziel-Tenant und stellt die Anmeldung an Intune Graph sicher.

        .DESCRIPTION
        Der EINZIGE Pfad fuer Tenant-Auswahl und Anmeldung: deployApps,
        createApps und das erzeugte deploy.ps1 rufen ausschliesslich diese
        Funktion. Ein Auswahldialog erscheint nur, wenn noch kein Tenant bekannt
        ist. Wird ein bereits gewaehlter Tenant uebergeben, laeuft auch eine
        noetige Neuanmeldung (abgelaufener Token) ohne Rueckfrage durch.
    #>
    [CmdletBinding()]
    param(
        # Bereits gewaehlter Tenant. Fehlt er, wird genau einmal gefragt.
        $Tenant,

        # Auswahlliste, ueblicherweise $config.tenants
        [Parameter(Mandatory = $true)]
        $Tenants,

        # Erzwingt eine Neuanmeldung, auch bei noch gueltigem Token
        [switch]$Force
    )

    $Tenant = Get-SingleDialogSelection -Value $Tenant

    if (-not $Tenant) {
        Write-Host "Show tenant selection dialog"
        $Tenant = Get-SingleDialogSelection -Value (Open-SelectDialog -data @($Tenants) -title "Select Tenant" -size small)
    }

    if (-not $Tenant) {
        throw "No tenant selected - aborting."
    }

    if ($Force -or (-not (Test-IntuneAccessToken))) {
        Write-Host ("Authenticating against tenant [{0}]" -f $Tenant.name)
        $null = Invoke-IntuneModuleCall -Label 'Connect-MSIntuneGraph' -Operation {
            Connect-MSIntuneGraph -TenantID $Tenant.name -ClientId $Tenant.appid -ClientSecret $Tenant.clientSecret -Verbose
        }
    }
    else {
        Write-Host ("Access token still valid for tenant [{0}]." -f $Tenant.name)
    }

    return $Tenant
}

function Test-ModuleFolderPresent {
    <#
        Ob ein Modul in einem Ordner von $env:PSModulePath liegt (Ordner mit dem Modulnamen, darin eine
        .psd1 - direkt oder in einem Versionsordner). Ein paar Dateizugriffe statt einer Abfrage der
        PowerShellGet-Registrierung: Get-InstalledModule brauchte im Messlauf 2,9 s, Get-Module
        -ListAvailable 1,7 s, das hier wenige Millisekunden.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)

    foreach ($path in @($env:PSModulePath -split ';' | Where-Object { $_ })) {
        $folder = Join-Path $path $Name
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
        if (Get-ChildItem -LiteralPath $folder -Filter '*.psd1' -Recurse -Depth 1 -File -ErrorAction SilentlyContinue | Select-Object -First 1) { return $true }
    }
    return $false
}

function check-prereqs{
    # Einmal je Prozess: das Hauptprogramm prueft beim Start, jedes deploy.ps1 (laeuft im selben
    # Prozess) rief es noch einmal auf - 1 bis 5 s je App ohne neuen Befund.
    if ($global:IntuneWin32HelperPrereqsChecked) { return }

    Write-Host "Checking required PowerShell modules"
    $requiredmodules=@(
        "IntuneWin32App"
        "Microsoft.WinGet.Client"
        "PSAppDeployToolkit"
    )
    $installedmodules = $null
    foreach($requiredmodule in $requiredmodules){
        if (Test-ModuleFolderPresent -Name $requiredmodule){
            Write-Host "Required module [$requiredmodule] detected." -ForegroundColor Green
            continue
        }
        # Nicht im Modulpfad gefunden: die genaue (langsame) Abfrage entscheidet.
        if ($null -eq $installedmodules) { $installedmodules = @((Get-InstalledModule -ErrorAction SilentlyContinue).Name) }
        if ($installedmodules -notcontains $requiredmodule){
            Write-Host "Required module [$requiredmodule] not detected - installing..." -ForegroundColor Yellow
            Install-Module $requiredmodule -Force -Scope CurrentUser
        }
        else{
            Write-Host "Required module [$requiredmodule] detected." -ForegroundColor Green
        }
    }
    $global:IntuneWin32HelperPrereqsChecked = $true
    #end function
}
