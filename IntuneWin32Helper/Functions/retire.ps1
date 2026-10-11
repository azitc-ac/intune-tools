# ============================================================================
#  Retire und Rebuild: Apps in Intune loeschen (Plan, Zuweisungen, Loeschen mit Nachlesen, Neuaufbau).
# ============================================================================

function Get-RetirePlan {
    <#
        .SYNOPSIS
        Welche Apps in Intune gehoeren zu den Zeilen: Name UND Version.

        .DESCRIPTION
        Reine Funktion ueber den Zustand der Inventarzeilen (IntuneSame) - pruefbar ohne
        Tenant. Die Ids, die spaeter geloescht werden, kommen NUR von hier: aus dem
        frisch gelesenen Tenant-Stand, ueber Name und Version der Zeile. Eine andere Version
        derselben App ist nie dabei. Mehrere Treffer (Dubletten) sind alle dabei und werden
        in der Rueckfrage einzeln genannt.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Rows)

    foreach ($row in @($Rows)) {
        if ([string]$row.Intune -eq 'not checked') {
            throw ("The Intune state of '{0}' was not read - nothing can be retired without it." -f $row.Key)
        }
        # Fremde Apps (nur in Intune, ohne den Vermerk dieses Werkzeugs) loescht dieser Weg nie: es gibt
        # keine Definition, die sagt, dass das Werkzeug fuer sie zustaendig ist.
        $protected = ($row.IntuneOnly -and [string]$row.Origin -eq 'foreign')
        $apps = @(@($(if ($protected) { @() } else { $row.IntuneSame })) | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.id) } | ForEach-Object {
            [pscustomobject]@{
                Id         = [string]$_.id
                Name       = [string]$_.displayName
                Version    = [string]$_.displayVersion
                Created    = [string]$_.createdDateTime
                HasContent = (Test-IntuneAppHasContent -App $_)
            }
        })
        [pscustomobject]@{
            Key    = [string]$row.Key
            Row    = $row
            Apps   = $apps
            Reason = $(if ($protected) { 'not created by this tool - not retired from here' } elseif ($apps.Count -eq 0) { 'no app with this name and version in Intune' } else { '' })
        }
    }
}

function Get-TenantAppAssignmentInfo {
    <#
        Zuweisungen einer App - fuer die Rueckfrage vor dem Loeschen. Known = $false heisst: nicht
        sicher (kein Token, Graph-Fehler) - die Rueckfrage sagt dann "could not be read" statt "0".

        Direkt ueber Graph, NICHT ueber Get-IntuneWin32AppAssignment: das Modul (1.5.0) meldete im
        Feldtest (2026-10-10) fuer eine App mit einer "alle Benutzer"-Zuweisung KEINE Zuweisung,
        waehrend Graph sie lieferte. Eine Rueckfrage vor dem Loeschen, die "0" sagt, obwohl es eine
        gibt, ist schlimmer als keine Zahl. Das Token ist das des Moduls ($global:AuthenticationHeader,
        gesetzt von Connect-MSIntuneGraph).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Id)

    $header = $global:AuthenticationHeader
    if (-not $header) { return [pscustomobject]@{ Count = 0; Known = $false } }

    try {
        $count = 0
        $uri = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/{0}/assignments' -f $Id
        $pages = 0
        while ($uri -and $pages -lt 20) {
            $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $header -ErrorAction Stop
            $count += @($response.value).Count
            $uri = [string]$response.'@odata.nextLink'
            $pages++
        }
        return [pscustomobject]@{ Count = $count; Known = ($pages -lt 20) }
    }
    catch {
        return [pscustomobject]@{ Count = 0; Known = $false }
    }
}

function Format-RetireTargets {
    <# Der Text der Rueckfrage: je Zeile die Apps in Intune mit Id, Datum, Inhalt und Zuweisungen. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Targets)

    $lines = @()
    foreach ($target in @($Targets)) {
        $head = [string]$target.Key
        if ($target.Apps.Count -gt 1) { $head += ('   <- {0} apps with this name and version, ALL are deleted' -f $target.Apps.Count) }
        $lines += $head
        foreach ($app in $target.Apps) {
            $info   = Get-TenantAppAssignmentInfo -Id $app.Id
            $assign = $(if ($info.Known) { 'assignments: {0}' -f $info.Count } else { 'assignments: could not be read' })
            $lines += ('    {0}   created {1}   {2}   {3}' -f $app.Id, $(if ($app.Created) { $app.Created } else { '?' }), $(if ($app.HasContent) { 'with content' } else { 'NO CONTENT' }), $assign)
        }
    }
    return ($lines -join "`n")
}

function Remove-TenantWin32Apps {
    <#
        .SYNOPSIS
        Loescht Apps in Intune und PRUEFT, dass sie weg sind.

        .DESCRIPTION
        Remove-IntuneWin32App wirft bei einem Fehler nicht, sondern warnt nur (Modulquelle 1.5.0:
        catch -> Write-Warning). "Kommando lief durch" heisst also nicht "App ist weg" - im Feld
        meldete ein erster Loeschversuch trotz 403 "gesendet". Darum liest diese Funktion die
        Tenant-Liste danach neu und meldet je App:
          Removed      die Id steht nicht mehr in der Liste
          StillListed  die Id steht noch drin (Detail: die Warnung des Moduls)
          Failed       der Aufruf selbst scheiterte
          Unverified   die Liste liess sich danach nicht lesen
        Der EINZIGE Ort, an dem Apps in Intune geloescht werden.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Apps)   # Objekte mit Id und Key

    $results   = @()
    $attempted = @()
    foreach ($app in @($Apps)) {
        $id = [string]$app.Id
        if ([string]::IsNullOrWhiteSpace($id)) {
            $results += [pscustomobject]@{ Id = $id; Key = [string]$app.Key; State = 'Failed'; Detail = 'no app id' }
            continue
        }
        try {
            $warnings = Invoke-IntuneModuleCall -Label 'Remove-IntuneWin32App' -Operation {
                $removeWarning = $null
                $null = Remove-IntuneWin32App -ID $id -WarningAction SilentlyContinue -WarningVariable removeWarning
                @($removeWarning)
            }
            $attempted += [pscustomobject]@{ Id = $id; Key = [string]$app.Key; Detail = (@(@($warnings) | Where-Object { $_ }) -join ' ') }
        }
        catch {
            $results += [pscustomobject]@{ Id = $id; Key = [string]$app.Key; State = 'Failed'; Detail = (Format-ErrorDetail $_) }
        }
    }

    if ($attempted.Count -gt 0) {
        $after = Read-TenantWin32Apps
        foreach ($item in $attempted) {
            if ($null -eq $after) {
                $results += [pscustomobject]@{ Id = $item.Id; Key = $item.Key; State = 'Unverified'; Detail = 'the tenant could not be read afterwards' }
            }
            elseif (@(@($after) | Where-Object { [string]$_.id -eq $item.Id }).Count -gt 0) {
                $results += [pscustomobject]@{ Id = $item.Id; Key = $item.Key; State = 'StillListed'; Detail = $item.Detail }
            }
            else {
                $results += [pscustomobject]@{ Id = $item.Id; Key = $item.Key; State = 'Removed'; Detail = '' }
            }
        }
    }
    return @($results)
}

function Write-RetireSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Results)
    $removed = @(@($Results) | Where-Object { $_.State -eq 'Removed' })
    $other   = @(@($Results) | Where-Object { $_.State -ne 'Removed' })
    Write-Host ""
    Write-Host ("Retire summary: {0} removed, {1} not removed." -f $removed.Count, $other.Count) -ForegroundColor Cyan
    foreach ($x in $removed) { Write-Host ("  REMOVED      {0}  {1}" -f $x.Key, $x.Id) -ForegroundColor Green }
    foreach ($x in $other)   { Write-Host ("  {0,-12} {1}  {2}  {3}" -f $x.State.ToUpper(), $x.Key, $x.Id, $x.Detail) -ForegroundColor Red }
    if ($other.Count -gt 0) { Write-Host "Check the apps that were not removed in the Intune portal." -ForegroundColor Yellow }
}

function Invoke-InventoryRetire {
    <#
        .SYNOPSIS
        Retire aus dem Hauptfenster: die Apps der gewaehlten Zeilen in Intune loeschen.

        .DESCRIPTION
        Loescht in Intune, nichts sonst: Definition (Apps.csv) und Paketordner bleiben. Die Ids
        kommen aus dem FRISCH gelesenen Tenant-Stand (Name und Version der Zeile), nie aus dem
        Fenster. Vor dem Loeschen steht die Rueckfrage mit jeder einzelnen App (Id, Datum, Inhalt,
        Zuweisungen); die Zuweisungen werden mit geloescht, das ist beschlossen. Standardantwort der
        Rueckfrage ist Nein. Scheitert das Lesen des Tenants, passiert nichts.
        -Ask ist die Rueckfrage (Text, Tasten) -> 'Yes' | 'No'; Tests ersetzen sie.
        Gibt $null zurueck, wenn nichts geloescht wurde, sonst die Ergebnisse je App.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Selection,
        [Parameter(Mandatory = $true)][string]$RootDir,
        [Parameter(Mandatory = $true)][string]$PacketRoot,
        [scriptblock]$Ask = { param($Text, $Buttons) Show-ConfirmDialog -Text $Text -Title 'Retire from Intune' -Buttons $Buttons -Icon Warning -Default $(if ($Buttons -eq 'YesNo') { 'No' } else { 'OK' }) }
    )

    $keys = @(@($Selection) | ForEach-Object { [string]$_.Key })

    $fresh = Read-TenantWin32Apps
    if ($null -eq $fresh) {
        Write-Host "The apps in the tenant could not be read - nothing was retired." -ForegroundColor Yellow
        return $null
    }
    $definitions = @(Read-AppsCsv -RootDir $RootDir)
    $inventory   = @(Get-AppInventory -Definitions $definitions -PacketRoot $PacketRoot -RootDir $RootDir -IntuneApps $fresh)
    $rows    = @($inventory | Where-Object { $keys -contains $_.Key })
    $targets = @(Get-RetirePlan -Rows $rows | Where-Object { $_.Apps.Count -gt 0 })
    if ($targets.Count -eq 0) {
        $null = & $Ask 'None of the selected rows has an app with this name and version in Intune.' 'OK'
        return $null
    }

    $count = (@($targets | ForEach-Object { $_.Apps.Count }) | Measure-Object -Sum).Sum
    $text = ("Delete {0} app(s) in Intune?`n`n{1}`n`nThe apps AND their assignments are deleted in Intune. This cannot be undone.`nThe definition in Apps.csv and the package folder stay, so the app can be deployed again - without its assignments." -f $count, (Format-RetireTargets -Targets $targets))
    if ([string](& $Ask $text 'YesNo') -ne 'Yes') {
        Write-Host "Retire cancelled - nothing was changed." -ForegroundColor Yellow
        return $null
    }

    $apps = @($targets | ForEach-Object { $key = $_.Key; $_.Apps | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Key = $key } } })
    $results = @(Remove-TenantWin32Apps -Apps $apps)
    Write-RetireSummary -Results $results
    return $results
}

function Invoke-InventoryRebuild {
    <#
        .SYNOPSIS
        Rebuild aus dem Hauptfenster: Paket neu bauen, die App in Intune ersetzen.

        .DESCRIPTION
        Fuer Zeilen mit Definition. Die Reihenfolge ist Absicht, jeder Schritt sichert den naechsten:
          1. Intune frisch lesen, Rueckfrage mit dem Plan (Standardantwort Nein).
          2. Paket neu bauen. Scheitert der Bau, bleibt Intune unangetastet - die App laeuft weiter.
          3. Erst dann die Apps der Zeile in Intune loeschen (Remove-TenantWin32Apps prueft nach).
          4. Nur wo alles geloescht ist, eine neue App anlegen (-Mode New). Ein Rest in Intune
             haette sonst eine Dublette zur Folge.
        Die Zuweisungen der alten App gehen verloren (beschlossen) und werden nicht wiederhergestellt;
        die Rueckfrage nennt ihre Zahl. Wer sie behalten will, nimmt Deploy mit "Nein" (Update).
        Gibt $null zurueck, wenn nichts getan wurde.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Selection,
        [Parameter(Mandatory = $true)]$Tenant,
        [Parameter(Mandatory = $true)][string]$RootDir,
        [Parameter(Mandatory = $true)][string]$PacketRoot,
        [Parameter(Mandatory = $true)][string]$ToolVersion,
        [scriptblock]$Ask = { param($Text, $Buttons) Show-ConfirmDialog -Text $Text -Title 'Rebuild in Intune' -Buttons $Buttons -Icon Warning -Default $(if ($Buttons -eq 'YesNo') { 'No' } else { 'OK' }) }
    )

    $keys = @(@($Selection) | ForEach-Object { [string]$_.Key })

    $fresh = Read-TenantWin32Apps
    if ($null -eq $fresh) {
        Write-Host "The apps in the tenant could not be read - nothing was rebuilt." -ForegroundColor Yellow
        return $null
    }
    $definitions = @(Read-AppsCsv -RootDir $RootDir)
    $inventory   = @(Get-AppInventory -Definitions $definitions -PacketRoot $PacketRoot -RootDir $RootDir -IntuneApps $fresh)
    $rows = @($inventory | Where-Object { $keys -contains $_.Key -and $_.HasDefinition })
    if ($rows.Count -eq 0) {
        $null = & $Ask 'None of the selected rows has a definition in Apps.csv - a package is rebuilt from the definition.' 'OK'
        return $null
    }
    $plan    = @(Get-RetirePlan -Rows $rows)
    $targets = @($plan | Where-Object { $_.Apps.Count -gt 0 })
    $fresh1  = @($plan | Where-Object { $_.Apps.Count -eq 0 })

    $parts = @("Rebuild {0} row(s):" -f $rows.Count)
    $parts += "1. Each package is built again from its definition; changes made by hand inside the package folder are lost."
    $parts += "2. Only after the build worked, the app(s) in Intune are deleted - with their assignments (not restored)."
    $parts += "3. Only after the deletion was verified, a new app is created."
    if ($targets.Count -gt 0) { $parts += ("In Intune now:`n{0}" -f (Format-RetireTargets -Targets $targets)) }
    if ($fresh1.Count -gt 0)  { $parts += ("Not in Intune yet (built and created):`n{0}" -f (($fresh1 | ForEach-Object { '    ' + $_.Key }) -join "`n")) }
    $parts += "Continue?"
    if ([string](& $Ask ($parts -join "`n`n") 'YesNo') -ne 'Yes') {
        Write-Host "Rebuild cancelled - nothing was changed." -ForegroundColor Yellow
        return $null
    }

    # 2. bauen - Intune bleibt unangetastet
    $built = Invoke-PackageBuild -Rows $rows -PacketRoot $PacketRoot -RootDir $RootDir -ToolVersion $ToolVersion -RemoveExisting $true
    $builtByKey = @{}
    foreach ($b in @($built.Built)) { $builtByKey[('{0} - {1}' -f $b.AppName, $b.AppVersion)] = $b }
    $skipped = @()
    $ready   = @()
    foreach ($item in $plan) {
        if ($builtByKey.ContainsKey($item.Key)) { $ready += $item }
        else { $skipped += ('{0}: the build failed - Intune was not touched' -f $item.Key) }
    }

    # 3. loeschen - nur fuer gebaute Zeilen
    $toRemove = @($ready | Where-Object { $_.Apps.Count -gt 0 })
    $removeResults = @()
    if ($toRemove.Count -gt 0) {
        $apps = @($toRemove | ForEach-Object { $key = $_.Key; $_.Apps | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Key = $key } } })
        $removeResults = @(Remove-TenantWin32Apps -Apps $apps)
        Write-RetireSummary -Results $removeResults
    }

    # 4. neu anlegen - nur wo nichts mehr uebrig ist
    $packages = @()
    foreach ($item in $ready) {
        $left = @($removeResults | Where-Object { $_.Key -eq $item.Key -and $_.State -ne 'Removed' })
        if ($left.Count -gt 0) {
            $skipped += ('{0}: the old app could not be removed ({1}) - not created, that would make a duplicate' -f $item.Key, $left[0].State)
            continue
        }
        $package = $builtByKey[$item.Key]
        $packages += [pscustomobject]@{
            AppName     = $package.AppName
            AppVersion  = $package.AppVersion
            FullPath    = $package.FullPath
            Mode        = 'New'
            UpdateAppId = ''
        }
    }

    if ($packages.Count -gt 0) {
        Invoke-PackageDeploy -Packages $packages -Tenant $Tenant -RootDir $RootDir -ToolVersion $ToolVersion -Skipped $skipped
    }
    else {
        Write-DeploymentSummary -Succeeded @() -Failed @() -Skipped $skipped
    }
    return [pscustomobject]@{ Created = @($packages | ForEach-Object { '{0} - {1}' -f $_.AppName, $_.AppVersion }); Skipped = @($skipped); Removed = @($removeResults) }
}
