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
                # Stand der Definition im Paket: current | changed | unknown (Paket ohne Stempel) | n/a (keine
                # Definition zum Vergleichen) | - (kein Paket)
                PackageDefinition = '-'
                # Stand der Definition in der App in Intune (Stempel im Vermerk): current | changed | unknown (App ohne
                # Stempel, z. B. vom alten Werkzeug) | - (keine einzelne App mit Inhalt, oder nicht abgefragt)
                IntuneDefinition  = '-'
                # Warum das Paket gebaut werden muss, bevor es weitergeht (leer: es muss nicht). Der Weg geht von links
                # nach rechts - Definition, Paket, Intune: ist das Paket nicht auf dem Stand von Definition und Vorlage,
                # ist alles rechts davon (Publish, Remove from Intune) gesperrt, bis Build package gelaufen ist.
                BuildReason       = ''
                Status    = ''
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

        # Spiegelt das Paket die Definition von heute? Der Stempel steht seit dem Bau im deploy.ps1.
        if (-not $row.HasDefinition) { $row.PackageDefinition = 'n/a' }
        else {
            $definitionStamp = Get-PackageDefinitionFingerprint -DeployScriptPath $package.FullPath
            if (-not $definitionStamp)                                                       { $row.PackageDefinition = 'unknown' }
            elseif ($definitionStamp -eq (Get-DefinitionFingerprint -Record $row.DefinitionRecord)) { $row.PackageDefinition = 'current' }
            else                                                                             { $row.PackageDefinition = 'changed' }
        }
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

            # Spiegelt die App in Intune die Definition von heute? Das sagt nur der Stempel im Vermerk der App;
            # ohne ihn ist es unbekannt - und "up to date" gibt es dann nicht (die App kann vom alten Werkzeug
            # stammen, mit alter Erkennung und alten Befehlen).
            if ($row.HasDefinition -and $count -eq 1 -and $emptyCount -eq 0) {
                $appStamp = Get-IntuneAppDefinitionFingerprint -App $same[0]
                if (-not $appStamp)                                                            { $row.IntuneDefinition = 'unknown' }
                elseif ($appStamp -eq (Get-DefinitionFingerprint -Record $row.DefinitionRecord)) { $row.IntuneDefinition = 'current' }
                else                                                                           { $row.IntuneDefinition = 'changed' }
            }
        }
        # Muss das Paket neu gebaut werden? Nur eine Zeile mit Definition kann gebaut werden. Build package erzeugt den
        # ganzen Ordner neu aus Definition und Vorlage - deploy.ps1 inklusive; Publish fasst das Paket nie an.
        if ($row.HasDefinition) {
            if (-not $row.HasPackage)                          { $row.BuildReason = 'there is no package yet' }
            elseif ($row.PackageDefinition -eq 'changed')      { $row.BuildReason = 'the definition was changed after the package was built' }
            elseif ($row.PackageDefinition -eq 'unknown')      { $row.BuildReason = 'the package was built before definitions were stamped' }
            elseif ($row.Template -eq 'outdated')              { $row.BuildReason = 'the package was built from an older template' }
            elseif ($row.Template -eq 'unstamped')             { $row.BuildReason = 'the package was built before templates were stamped' }
        }

        # Der naechste sinnvolle Schritt folgt aus dem Zustand der Zeile.
        if ($row.IntuneOnly -and $row.Origin -eq 'foreign') {
            $row.Next = 'not created by this tool'
        }
        elseif ($row.BuildReason) {
            $row.Next = 'build package, then publish'
        }
        elseif ($emptyCount -gt 0) {
            # Zuerst: ein inhaltsloser Eintrag verdeckt sonst jeden anderen Befund.
            $row.Next = 'remove the entry without content in Intune'
        }
        elseif ($row.IntuneOnly) {
            $row.Next = $(if ($row.Intune -like 'yes (*') { 'check duplicates in Intune' } else { 'in Intune only - no definition or package here' })
        }
        elseif ($row.Definition -ne 'yes') {
            $row.Next = 'package without a row in Apps.csv'
        }
        elseif ($row.Intune -like 'yes (*') {
            $row.Next = 'check duplicates in Intune'
        }
        elseif ($row.Intune -eq '-') {
            $row.Next = 'publish'
        }
        elseif ($row.Intune -like 'other version*') {
            # Name vorhanden, Version nicht: Publish legt diese Version neu an,
            # die andere bleibt (sie hat ihre eigene Zeile oder wird von Hand entfernt).
            $row.Next = 'publish (new version)'
        }
        elseif ($row.IntuneDefinition -eq 'changed' -or $row.IntuneDefinition -eq 'unknown') {
            # Paket und Definition passen, die App in Intune nicht (oder es ist nicht zu sagen): Publish aktualisiert sie.
            $row.Next = 'publish (updates the app in Intune)'
        }
        elseif ($row.IntuneDefinition -eq 'current') {
            $row.Next = 'up to date'
        }
        elseif ($intuneChecked) {
            # Eine App in Intune, aber keine Aussage moeglich (z. B. keine Definition): nie "up to date".
            $row.Next = 'publish'
        }
        else {
            # Ohne Tenant-Abfrage ist "up to date" eine Behauptung ueber etwas,
            # das niemand nachgesehen hat - dann bleibt nur der Vorschlag.
            $row.Next = 'publish'
        }

        # Zustand von Definition und Paket in einem Wort (linke Seite des Fensters).
        if ($row.IntuneOnly)               { $row.Status = $(if ($row.Origin -eq 'foreign') { 'Foreign app' } else { 'Intune only' }) }
        elseif (-not $row.HasDefinition)   { $row.Status = 'No definition' }
        elseif (-not $row.HasPackage)      { $row.Status = 'Definition only' }
        elseif ($row.PackageDefinition -eq 'changed') { $row.Status = 'Package, definition changed' }
        elseif ($row.PackageDefinition -eq 'unknown') { $row.Status = 'Package, built before the definition stamp' }
        elseif ($row.Template -eq 'outdated')  { $row.Status = 'Package, template outdated' }
        elseif ($row.Template -eq 'unstamped') { $row.Status = 'Package, template unstamped' }
        else                               { $row.Status = 'Package' }

        $packageFolder = '-'
        if ($row.FullPath) { $packageFolder = Split-Path -Parent $row.FullPath }
        $row.Detail = (@(
            ('Definition: {0}' -f $row.Definition),
            ('Package: {0}' -f $packageFolder),
            ('Template: {0}' -f $row.Template),
            ('Package built from this definition: {0}' -f $row.PackageDefinition),
            ('Intune: {0}' -f $row.Intune),
            ('App in Intune built from this definition: {0}' -f $row.IntuneDefinition),
            ('Next: {0}' -f $row.Next)
        ) -join "`n")
    }

    return @($order | ForEach-Object { $rows[$_] })
}

function Get-BuildTargets {
    <#
        Welche der markierten Zeilen Build package baut: die mit Definition, deren Paket fehlt oder nicht mehr zu
        Definition und Vorlage passt (BuildReason). Ein Paket auf dem Stand bleibt, wie es ist. Der Knopf
        (Get-InventoryActionState) und die Aktion im Hauptfenster fragen dieselbe Funktion.
    #>
    param($Rows = @())
    return @(@($Rows) | Where-Object { $_ -and $_.HasDefinition -and [string]$_.BuildReason })
}

function Get-InventoryActionState {
    <#
        .SYNOPSIS
        Welche Knoepfe des Hauptfensters fuer die markierten Zeilen moeglich sind - und warum nicht.

        .DESCRIPTION
        Reine Funktion ueber Inventarzeilen (kein Fenster, kein Tenant), damit "was ist wann ausgegraut" ein
        Test ist und keine Gewohnheit. Das Fenster liest nur das Ergebnis.

        Die drei Dinge einer App und ihre Knoepfe, links nach rechts:
          Definition  Add / New version / Edit / Delete definition
          Paket       Build package
          Intune      Publish to Intune / Remove from Intune
        und Delete package (Paket), das jedes vorhandene Paket entfernt.
        Bauen und Veroeffentlichen haengen von links nach rechts zusammen; LOESCHEN nicht: was es gibt, kann man
        stets entfernen (Delete definition, Remove from Intune), auch wenn das Paket erst gebaut werden muss.

        Publish ist moeglich, wenn mindestens eine markierte Zeile veroeffentlicht werden kann; was nicht geht,
        meldet der Plan beim Klick (Skip mit Grund). PublishWhy sagt, warum NICHTS davon geht (leer, wenn es
        geht) und steht im Tooltip des ausgegrauten Knopfes.
    #>
    [CmdletBinding()]
    param($Rows = @())

    $rows = @(@($Rows) | Where-Object { $_ })
    $withDefinition = @($rows | Where-Object { $_.HasDefinition })
    $one = ($rows.Count -eq 1)

    # Der Weg geht von links nach rechts. Braucht das Paket einen Bau (BuildReason), ist alles rechts von
    # Build package gesperrt; ist das Paket auf dem Stand, ist Build package gesperrt.
    $needsBuild = @(Get-BuildTargets -Rows $rows)

    # Publish: je Zeile ein Grund, warum nicht (leer = geht)
    $whyNot = {
        param($row)
        if (-not ($row.HasDefinition -or $row.HasPackage)) { return 'there is no definition and no package here to publish' }
        if ($row.HasDefinition -and [string]$row.BuildReason) { return ('run Build package first - {0}' -f $row.BuildReason) }
        if ($row.HasDefinition -and [string]$row.IntuneDefinition -eq 'current') { return 'the app in Intune is already up to date with the definition and the package' }
        if ([string]$row.Intune -like 'yes (*') { return 'the app is in Intune more than once - remove the duplicates first (Remove from Intune)' }
        if ([string]$row.Intune -eq 'no content') { return 'the entry in Intune has no content - remove it first (Remove from Intune)' }
        return ''
    }
    $publishReasons = @($rows | ForEach-Object { & $whyNot $_ })
    $publishable = @($publishReasons | Where-Object { -not $_ })
    $publishWhy = ''
    if ($rows.Count -eq 0) { $publishWhy = 'select an app first' }
    elseif ($publishable.Count -eq 0) { $publishWhy = [string](@($publishReasons | Where-Object { $_ })[0]) }

    # Was es gibt, laesst sich loeschen - unabhaengig vom Stand des Pakets (ein Bauzwang sperrt nur das Anlegen
    # und Aendern, nie das Entfernen). Fremde Apps schuetzt die Herkunft.
    $removable = @($rows | Where-Object { ([string]$_.Intune -like 'yes*' -or [string]$_.Intune -eq 'no content') -and [string]$_.Origin -ne 'foreign' })
    $withPackage = @($rows | Where-Object { $_.HasPackage })

    $buildWhy = ''
    if ($rows.Count -eq 0) { $buildWhy = 'select an app first' }
    elseif ($withDefinition.Count -eq 0) { $buildWhy = 'there is no definition to build from' }
    elseif ($needsBuild.Count -eq 0) { $buildWhy = 'the package is already built from this definition and the current template - change the definition first if it should be built again' }

    $removeWhy = ''
    if ($rows.Count -eq 0) { $removeWhy = 'select an app first' }
    elseif ($removable.Count -eq 0) { $removeWhy = 'no app of this name and version in Intune that this tool may remove' }

    [pscustomobject]@{
        Edit         = ($one -and $withDefinition.Count -eq 1)
        NewVersion   = ($one -and $withDefinition.Count -eq 1)
        Delete       = ($withDefinition.Count -gt 0)
        Build        = ($needsBuild.Count -gt 0)
        BuildWhy     = $buildWhy
        Publish      = ($publishable.Count -gt 0)
        PublishWhy   = $publishWhy
        Remove       = ($removable.Count -gt 0)
        RemoveWhy    = $removeWhy
        RemoveFolder = ($withPackage.Count -gt 0)
        RemoveFolderWhy = $(if ($rows.Count -eq 0) { 'select an app first' } elseif ($withPackage.Count -eq 0) { 'there is no package folder to delete' } else { '' })
    }
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
