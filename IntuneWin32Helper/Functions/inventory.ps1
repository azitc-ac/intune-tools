# ============================================================================
#  Inventar: eine Zeile je App aus Definition, Paketordner und Tenant.
# ============================================================================

function Test-IntuneAppHasContent {
    <#
        Hat ein Win32-App-Eintrag Inhalt? Ein fehlgeschlagener Upload hinterlaesst
        einen Eintrag mit publishingState "notPublished" und ohne
        committedContentVersion (im Feld 2026-09-28: uploadState 0, size 0).
        Beide Felder liefert schon die Liste von Get-IntuneWin32App mit.
    #>
    param([Parameter(Mandatory = $true)]$App)
    if ([string]::IsNullOrEmpty([string]$App.committedContentVersion)) { return $false }
    if ($App.publishingState -and [string]$App.publishingState -ne 'published') { return $false }
    return $true
}

function Test-IntuneAppCreatedByTool {
    <#
        Hat dieses Werkzeug die App angelegt? deploy.ps1 setzt beim Anlegen den Vermerk
        "Created by IntuneWin32Helper <Version>" (Add-IntuneWin32App -Notes). Eine App ohne diesen
        Vermerk ist "fremd": von Hand, von einem anderen Werkzeug oder aus dem Enterprise App Catalog.
    #>
    param([Parameter(Mandatory = $true)]$App)
    return ([string]$App.notes -like 'Created by IntuneWin32Helper*')
}

function Get-AppInventory {
    <#
        .SYNOPSIS
        Eine Zeile pro App, mit dem Zustand aller drei Dinge, die es zu einer App gibt.

        .DESCRIPTION
        Muster aus SCCMAppHelper. Drei Dinge existieren pro App, und die Aufgabe
        des Werkzeugs ist es, sie in Deckung zu halten:

            Definition   eine Zeile in Apps.csv
            Paket        "<Name> - <Version>\" unter packetRoot, mit deploy.ps1
            App          ein Win32-App-Eintrag im Tenant

        Bisher war nichts davon sichtbar: deployApps listete Ordner, die zufaellig
        ein deploy.ps1 enthielten. Welche Definition kein Paket hat, welches Paket
        nicht veroeffentlicht ist, welches aus einer aelteren Vorlage stammt und wo
        dieselbe App mehrfach in Intune liegt - alles nicht erkennbar. Die
        Geister-App nach einem fehlgeschlagenen Upload fiel deshalb nur im
        Transcript auf.

        Reine Funktion ueber ihre Eingaben: der Tenant-Zustand wird
        hineingegeben, nicht hier geholt. Damit pruefbar ohne Tenant.

        $IntuneApps = $null bedeutet "nicht abgefragt" und ist ein anderer
        Zustand als "keine gefunden".
    #>
    [CmdletBinding()]
    param(
        $Definitions = @(),
        [Parameter(Mandatory = $true)][string]$PacketRoot,
        [Parameter(Mandatory = $true)][string]$RootDir,
        $IntuneApps = $null
    )

    $currentFingerprint = Get-TemplateFingerprint -RootDir $RootDir

    # Pakete ueber Get-DeployScripts - eine Quelle fuer "welche Pakete gibt es".
    $packages = @()
    if (Test-Path -LiteralPath $PacketRoot) {
        try { $packages = @(Get-DeployScripts -PacketRoot $PacketRoot) } catch { $packages = @() }
    }

    # Intune-Apps nach Anzeigenamen gruppieren. Ob eine Zeile "in Intune" ist, entscheiden Name UND
    # Version (displayVersion): dieselbe App in zwei Versionen sind zwei Zeilen und keine Dublette -
    # das Tool legt jede Version als eigene App an. Mehr als eine App mit Name und Version ist
    # bemerkenswert: so sehen Dubletten aus. Getrennt gezaehlt werden Eintraege OHNE Inhalt - das
    # hinterlaesst ein fehlgeschlagener Upload (Geister-App). Frueher zaehlten sie einfach als
    # "yes", und das Inventar meldete im Feld "up to date" fuer eine App, die nie verteilt werden kann.
    $intuneByName = @{}
    $intuneChecked = ($null -ne $IntuneApps)
    if ($intuneChecked) {
        foreach ($app in @($IntuneApps)) {
            $name = [string]$app.displayName
            if (-not $name) { continue }
            if (-not $intuneByName.ContainsKey($name)) { $intuneByName[$name] = New-Object System.Collections.ArrayList }
            $null = $intuneByName[$name].Add($app)
        }
    }
    # Schluessel ist "<Name> - <Version>", genau wie der Paketordner heisst.
    $rows = @{}
    $order = New-Object System.Collections.ArrayList

    $touch = {
        param([string]$name, [string]$version)
        $key = ('{0} - {1}' -f $name, $version)
        if (-not $rows.ContainsKey($key)) {
            $rows[$key] = [pscustomobject]@{
                Key         = $key
                AppName     = $name
                AppVersion  = $version
                Publisher   = ''
                Definition  = '-'
                Package     = '-'
                Template    = '-'
                Status      = ''
                Intune      = $(if ($intuneChecked) { '-' } else { 'not checked' })
                Next        = ''
                FullPath    = ''
                # Fuer das Hauptfenster: dieselben Zustaende als Wahrheitswerte, der
                # Datensatz aus Apps.csv (zum Bearbeiten) und der Tooltip.
                HasDefinition    = $false
                HasPackage       = $false
                DefinitionRecord = $null
                Detail           = ''
                # Die Intune-Apps gleichen Namens: IntuneSame = auch gleiche Version,
                # IntuneOther = andere Version. Daraus entscheidet Get-DeployPlan.
                IntuneSame       = @()
                IntuneOther      = @()
                # Eine App, die nur in Intune liegt (keine Definition, kein Paket hier). Origin sagt dann,
                # ob dieses Werkzeug sie angelegt hat ('tool') oder nicht ('foreign'); sonst leer.
                IntuneOnly       = $false
                Origin           = ''
            }
            $null = $order.Add($key)
        }
        return $rows[$key]
    }

    foreach ($definition in @($Definitions)) {
        $name = [string]$definition.DisplayName
        if (-not $name) { continue }
        $row = & $touch $name ([string]$definition.Version)
        $row.Definition = 'yes'
        $row.Publisher = [string]$definition.Publisher
        $row.HasDefinition = $true
        $row.DefinitionRecord = $definition
    }

    foreach ($package in $packages) {
        $row = & $touch ([string]$package.AppName) ([string]$package.AppVersion)
        $row.Package  = 'yes'
        $row.HasPackage = $true
        $row.FullPath = [string]$package.FullPath

        $stamp = Get-PackageTemplateFingerprint -DeployScriptPath $package.FullPath
        if (-not $stamp)                            { $row.Template = 'unstamped' }
        elseif ($stamp -eq $currentFingerprint)     { $row.Template = 'current' }
        else                                        { $row.Template = 'outdated' }
    }

    # Apps, die nur in Intune liegen, bekommen eine eigene Zeile (Name - Version wie sonst auch). Ob sie
    # von diesem Werkzeug stammen, sagt der Vermerk; ohne ihn sind sie "fremd" und werden im Fenster
    # standardmaessig ausgeblendet und nie von hier aus geloescht (Get-RetirePlan).
    if ($intuneChecked) {
        $intuneOnlyKeys = @{}
        foreach ($app in @($IntuneApps)) {
            $name = [string]$app.displayName
            if (-not $name) { continue }
            $key = ('{0} - {1}' -f $name, [string]$app.displayVersion)
            if ($rows.ContainsKey($key) -and -not $intuneOnlyKeys.ContainsKey($key)) { continue }
            $row = & $touch $name ([string]$app.displayVersion)
            $row.IntuneOnly = $true
            $intuneOnlyKeys[$key] = $true
            # Eine Dublette gilt als "tool", sobald EINE der Apps den Vermerk traegt.
            if ((Test-IntuneAppCreatedByTool -App $app) -or $row.Origin -eq 'tool') { $row.Origin = 'tool' } else { $row.Origin = 'foreign' }
        }
    }

    foreach ($key in $order) {
        $row = $rows[$key]
        $emptyCount = 0
        $count      = 0
        if ($intuneChecked -and $intuneByName.ContainsKey($row.AppName)) {
            $byName = @($intuneByName[$row.AppName])
            $same   = @($byName | Where-Object { ([string]$_.displayVersion) -eq $row.AppVersion })
            $other  = @($byName | Where-Object { ([string]$_.displayVersion) -ne $row.AppVersion })
            $row.IntuneSame  = $same
            $row.IntuneOther = $other
            $count      = $same.Count
            $emptyCount = @($same | Where-Object { -not (Test-IntuneAppHasContent -App $_) }).Count
            if ($count -eq 0) {
                $versions = @($other | ForEach-Object { $(if ([string]$_.displayVersion) { [string]$_.displayVersion } else { '(none)' }) } | Select-Object -Unique)
                $row.Intune = ('other version: {0}' -f ($versions -join ', '))
            }
            elseif ($count -eq 1 -and $emptyCount -eq 1) { $row.Intune = 'no content' }
            elseif ($count -eq 1)                        { $row.Intune = 'yes' }
            elseif ($emptyCount -gt 0)                   { $row.Intune = ('yes ({0}x, {1} without content)' -f $count, $emptyCount) }
            else                                         { $row.Intune = ('yes ({0}x)' -f $count) }
        }
        # Der naechste sinnvolle Schritt folgt aus dem Zustand der Zeile.
        if ($row.IntuneOnly -and $row.Origin -eq 'foreign') {
            $row.Next = 'not created by this tool'
        }
        elseif ($emptyCount -gt 0) {
            # Zuerst: ein inhaltsloser Eintrag verdeckt sonst jeden anderen Befund.
            $row.Next = 'remove the entry without content in Intune'
        }
        elseif ($row.IntuneOnly) {
            $row.Next = $(if ($row.Intune -like 'yes (*') { 'check duplicates in Intune' } else { 'in Intune only - no definition or package here' })
        }
        elseif ($row.Package -ne 'yes') {
            $row.Next = 'create package'
        }
        elseif ($row.Definition -ne 'yes') {
            $row.Next = 'package without a row in Apps.csv'
        }
        elseif ($row.Intune -like 'yes (*') {
            $row.Next = 'check duplicates in Intune'
        }
        elseif ($row.Intune -eq '-') {
            $row.Next = 'deploy'
        }
        elseif ($row.Intune -like 'other version*') {
            # Name vorhanden, Version nicht: ein Deploy legt diese Version neu an,
            # die andere bleibt (sie hat ihre eigene Zeile oder wird von Hand entfernt).
            $row.Next = 'deploy (new version)'
        }
        elseif ($row.Template -eq 'outdated' -or $row.Template -eq 'unstamped') {
            $row.Next = 'renew from template, then deploy'
        }
        elseif ($intuneChecked) {
            $row.Next = 'up to date'
        }
        else {
            # Ohne Tenant-Abfrage ist "up to date" eine Behauptung ueber etwas,
            # das niemand nachgesehen hat - dann bleibt nur der Vorschlag.
            $row.Next = 'deploy'
        }

        # Zustand von Definition und Paket in einem Wort (linke Seite des Fensters).
        if ($row.IntuneOnly)               { $row.Status = $(if ($row.Origin -eq 'foreign') { 'Foreign app' } else { 'Intune only' }) }
        elseif (-not $row.HasDefinition)   { $row.Status = 'No definition' }
        elseif (-not $row.HasPackage)      { $row.Status = 'Definition only' }
        elseif ($row.Template -eq 'outdated')  { $row.Status = 'Package, template outdated' }
        elseif ($row.Template -eq 'unstamped') { $row.Status = 'Package, template unstamped' }
        else                               { $row.Status = 'Package' }

        $packageFolder = '-'
        if ($row.FullPath) { $packageFolder = Split-Path -Parent $row.FullPath }
        $row.Detail = (@(
            ('Definition: {0}' -f $row.Definition),
            ('Package: {0}' -f $packageFolder),
            ('Template: {0}' -f $row.Template),
            ('Intune: {0}' -f $row.Intune),
            ('Next: {0}' -f $row.Next)
        ) -join "`n")
    }

    return @($order | ForEach-Object { $rows[$_] })
}

function Get-InventoryRowInfo {
    <# Die Fakten einer Inventarzeile fuer den Kopf des Bearbeitungsdialogs (nur lesen). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Row)

    $folder = '- (not built yet)'
    if ($Row.FullPath) { $folder = Split-Path -Parent $Row.FullPath }
    return [ordered]@{
        'Package'   = $folder
        'Template'  = [string]$Row.Template
        'Intune'    = [string]$Row.Intune
        'Next step' = [string]$Row.Next
    }
}
