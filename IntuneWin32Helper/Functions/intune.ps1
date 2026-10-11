# ============================================================================
#  Intune: den Tenant lesen, Deploy planen und ausfuehren.
# ============================================================================

function Read-TenantWin32Apps {
    <#
        Liest die Win32-Apps des Tenants. $null heisst "nicht abgefragt" und ist
        ein anderer Zustand als "keine gefunden" (leeres Array) - das Inventar
        unterscheidet beides. Scheitert die Abfrage, bleibt die Intune-Spalte
        leer; das Inventar ist auch ohne Tenant brauchbar.

        Direkt ueber Graph, NICHT ueber Get-IntuneWin32App: dessen Liste (Filter isof(win32LobApp))
        fuehrte im Feldtest (2026-10-10) eine gerade angelegte App erst nach 40 bis 120 Sekunden -
        die einfache Liste (ohne Filter) schon nach wenigen. In dieser Luecke sah ein zweiter Deploy
        "nicht in Intune" und haette eine Dublette angelegt. Die Objekte haben dieselben Eigenschaften
        wie die des Moduls (Graph-Namen: id, displayName, displayVersion, committedContentVersion, ...).
        Das Token ist das des Moduls ($global:AuthenticationHeader).
    #>
    [CmdletBinding()]
    param()

    try {
        Write-Host "Reading the Win32 apps of the tenant..."
        $header = $global:AuthenticationHeader
        if (-not $header) { throw 'not signed in to Intune Graph' }
        # Wie der Filter isof(win32LobApp) des Moduls: auch abgeleitete Typen (win32CatalogApp = Enterprise App Catalog;
        # Feldfund 2026-10-10: ein reiner Vergleich auf win32LobApp liess dort 'Remote Help' aus der Liste fallen).
        $win32Types = @('#microsoft.graph.win32LobApp', '#microsoft.graph.win32CatalogApp')
        $apps = @()
        $uri = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?$top=500'
        $pages = 0
        while ($uri) {
            $pages++
            if ($pages -gt 100) { throw 'the app list has more than 100 pages - stopped' }
            $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $header -ErrorAction Stop
            $apps += @(@($response.value) | Where-Object { $_.'@odata.type' -in $win32Types })
            $uri = [string]$response.'@odata.nextLink'
        }
        Write-Host ("{0} Win32 app(s) in the tenant." -f $apps.Count)
        return , $apps
    }
    catch {
        Write-Host ("Tenant state could not be read ({0}) - the Intune column stays empty." -f (Format-ErrorDetail $_)) -ForegroundColor Yellow
        return $null
    }
}

function Connect-InventoryTenant {
    <#
        Tenant waehlen und anmelden - ueber Initialize-IntuneConnection, den
        einzigen Pfad dafuer. Scheitert das (Abbruch, Anmeldung), geht das Tool
        offline weiter: die Intune-Spalte bleibt leer, der Rest funktioniert.

        -Force ist beim WECHSEL des Tenants noetig: Initialize-IntuneConnection
        prueft ohne -Force nur, ob IRGENDEIN Token noch gilt - nicht, fuer
        welchen Tenant. Das Token des alten Tenants wuerde sonst weiterbenutzt
        und die Liste zeigte still den falschen Tenant.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Tenants,
        $Tenant,
        [switch]$Force
    )

    try {
        return (Initialize-IntuneConnection -Tenant $Tenant -Tenants $Tenants -Force:$Force)
    }
    catch {
        Write-Host ("No connection to a tenant ({0}) - the Intune column stays empty." -f (Format-ErrorDetail $_)) -ForegroundColor Yellow
        return $null
    }
}

function Invoke-PackageDeploy {
    <#
        Verteilt Pakete nach Intune: erneuert das deploy.ps1 bei Bedarf und ruft es
        mit dem Tenant auf. Stand frueher als Rumpf in deployApps.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Packages,
        [Parameter(Mandatory = $true)]$Tenant,
        [Parameter(Mandatory = $true)][string]$RootDir,
        [Parameter(Mandatory = $true)][string]$ToolVersion,
        [string[]]$Skipped = @()
    )

    $appsToDeploy = @(@($Packages) | Where-Object { $_.FullPath })
    if ($appsToDeploy.Count -eq 0) { return }

    # Jedes Paket kommt mit der Entscheidung des Plans (Get-DeployPlan): New oder Update.
    # Ohne sie wuerde das deploy.ps1 selbst entscheiden - und im Bulk-Lauf immer eine neue App
    # anlegen. Das ist ein Programmierfehler und bricht VOR dem ersten Upload ab.
    foreach ($app in $appsToDeploy) {
        $mode = [string]$app.Mode
        if ($mode -ne 'New' -and $mode -ne 'Update') {
            throw ("Deploy of '{0} - {1}' has no decision (Mode '{2}'): the plan from Get-DeployPlan is missing." -f $app.AppName, $app.AppVersion, $mode)
        }
        if ($mode -eq 'Update' -and [string]::IsNullOrWhiteSpace([string]$app.UpdateAppId)) {
            throw ("Deploy of '{0} - {1}': Mode Update needs an UpdateAppId." -f $app.AppName, $app.AppVersion)
        }
    }

    $succeeded = @()
    $failed    = @()

    foreach($app in $appsToDeploy){
        $appLabel = "$($app.AppName) - $($app.AppVersion)"
        Write-Host ("Deploy Application: {0} ({1})" -f $appLabel, $app.Mode) -ForegroundColor Cyan

        try {
            # Aeltere deploy.ps1 kennen -Tenant und -Mode nicht: aus der aktuellen
            # Vorlage nachziehen (Sicherung wird angelegt).
            $null = Update-DeployScript -DeployScriptPath $app.FullPath -RootDir $RootDir -ToolVersion $ToolVersion

            & $app.FullPath -Tenant $Tenant -Mode ([string]$app.Mode) -UpdateAppId ([string]$app.UpdateAppId)
            $succeeded += $appLabel
        }
        catch {
            # Den Lauf nicht abbrechen: die restlichen Apps sollen noch durchlaufen.
            Write-Host ("FAILED: {0} - {1}" -f $appLabel, (Format-ErrorDetail $_)) -ForegroundColor Red
            $failed += $appLabel
        }
    }
    Write-DeploymentSummary -Succeeded $succeeded -Failed $failed -Skipped @($Skipped)
}

function Get-DeployPlan {
    <#
        .SYNOPSIS
        Entscheidet pro Zeile, was ein Deploy tut: Create, Skip oder Update.

        .DESCRIPTION
        Reine Funktion ueber den Zustand der Inventarzeilen (IntuneSame/IntuneOther) -
        pruefbar ohne Tenant.

        Wozu: das erzeugte deploy.ps1 legte im Bulk-Lauf IMMER eine neue App an, auch
        wenn dieselbe App in derselben Version schon in Intune lag - jeder zweite Lauf
        erzeugte Dubletten. Jetzt entscheidet das Tool vorher, und das deploy.ps1
        bekommt die Entscheidung mit (-Mode).

          Create  keine App mit Name UND Version in Intune
          Skip    gibt es schon oder ist nicht eindeutig; Reason sagt warum
          Update  nur mit -ReplaceExisting: genau eine App mit Inhalt, deren Paketinhalt
                  ersetzt wird. Erkennungsregel, Befehlszeilen, Anforderungen und
                  Zuweisungen bleiben, wie sie in Intune sind: Update-IntuneWin32AppPackageFile
                  aendert nur committedContentVersion und das Icon (Modulquelle 1.5.0).

        Eine Zeile, deren Intune-Zustand nicht gelesen wurde, wird nicht geplant -
        "nicht nachgesehen" darf nicht wie "gibt es nicht" aussehen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Rows,
        [switch]$ReplaceExisting
    )

    foreach ($row in @($Rows)) {
        if ([string]$row.Intune -eq 'not checked') {
            throw ("The Intune state of '{0}' was not read - a deploy cannot be planned without it." -f $row.Key)
        }
        $same  = @(@($row.IntuneSame)  | Where-Object { $_ })
        $other = @(@($row.IntuneOther) | Where-Object { $_ })

        $action = 'Create'; $reason = ''; $appId = ''; $replaceable = $false
        if ($same.Count -eq 0) {
            $reason = 'not in Intune yet'
            if ($other.Count -gt 0) {
                $versions = @($other | ForEach-Object { $(if ([string]$_.displayVersion) { [string]$_.displayVersion } else { '(none)' }) } | Select-Object -Unique)
                $reason = 'new version - Intune has {0}' -f ($versions -join ', ')
            }
        }
        elseif ($same.Count -gt 1) {
            $action = 'Skip'; $reason = ('{0} apps with this name and version in Intune - remove the duplicates first' -f $same.Count)
        }
        elseif (-not (Test-IntuneAppHasContent -App $same[0])) {
            $action = 'Skip'; $reason = 'the entry in Intune has no content - remove it in Intune first'
        }
        elseif ($ReplaceExisting) {
            $action = 'Update'; $appId = [string]$same[0].id; $reason = 'replace the package content of the app in Intune'
        }
        else {
            $action = 'Skip'; $reason = 'already in Intune'; $replaceable = $true
        }

        [pscustomobject]@{
            Key         = [string]$row.Key
            Row         = $row
            Action      = $action
            Reason      = $reason
            UpdateAppId = $appId
            Replaceable = $replaceable
        }
    }
}

function Invoke-InventoryDeploy {
    <#
        .SYNOPSIS
        Deploy aus dem Hauptfenster: Intune frisch lesen, planen, fragen, bauen, verteilen.

        .DESCRIPTION
        Ein Pfad fuer jedes Deploy. Reihenfolge, mit Absicht:
          1. Intune NEU lesen. Der Stand des Fensters kann veraltet sein (ein anderer
             Administrator, ein vorheriger Lauf); wer auf Grundlage von gestern entscheidet,
             legt Dubletten an. Scheitert das Lesen, wird nichts verteilt.
          2. Get-DeployPlan: pro Zeile Create / Skip.
          3. Rueckfrage mit dem Plan. Ja = wie geplant, Nein = zusaetzlich den Inhalt
             schon vorhandener Apps ersetzen, Abbrechen = nichts tun.
          4. Nur fuer Zeilen, die nicht uebersprungen werden und noch kein Paket haben: bauen.
          5. Invoke-PackageDeploy mit der Entscheidung je Paket.

        -Ask ist die Rueckfrage (Text, Tasten) -> 'Yes' | 'No' | 'Cancel'; Tests ersetzen sie.
        Gibt $null zurueck, wenn nichts verteilt wurde, sonst den Plan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Selection,
        [Parameter(Mandatory = $true)]$Tenant,
        [Parameter(Mandatory = $true)][string]$RootDir,
        [Parameter(Mandatory = $true)][string]$PacketRoot,
        [Parameter(Mandatory = $true)][string]$ToolVersion,
        [bool]$RemoveExisting = $false,
        [scriptblock]$Ask = { param($Text, $Buttons) Show-ConfirmDialog -Text $Text -Title 'Deploy' -Buttons $Buttons -Icon Question -Default $(if ($Buttons -eq 'OK') { 'OK' } else { 'Yes' }) }
    )

    $keys = @(@($Selection) | ForEach-Object { [string]$_.Key })

    $fresh = Read-TenantWin32Apps
    if ($null -eq $fresh) {
        Write-Host "The apps in the tenant could not be read - nothing was deployed (without that state a deploy could create duplicates)." -ForegroundColor Yellow
        return $null
    }

    $definitions = @(Read-AppsCsv -RootDir $RootDir)
    $inventory   = @(Get-AppInventory -Definitions $definitions -PacketRoot $PacketRoot -RootDir $RootDir -IntuneApps $fresh)
    $rows = @($inventory | Where-Object { $keys -contains $_.Key -and ($_.HasDefinition -or $_.HasPackage) })
    if ($rows.Count -eq 0) { return $null }

    $plan = @(Get-DeployPlan -Rows $rows)

    $describe = {
        param($items)
        (@($items) | ForEach-Object { '  {0}  ({1})' -f $_.Key, $_.Reason }) -join "`n"
    }
    $create = @($plan | Where-Object { $_.Action -eq 'Create' })
    $skip   = @($plan | Where-Object { $_.Action -eq 'Skip' })
    $replaceable = @($skip | Where-Object { $_.Replaceable })

    $textParts = @()
    if ($create.Count -gt 0) { $textParts += ("Create in Intune ({0}):`n{1}" -f $create.Count, (& $describe $create)) }
    if ($skip.Count -gt 0)   { $textParts += ("Skip ({0}):`n{1}" -f $skip.Count, (& $describe $skip)) }
    if ($create.Count -eq 0 -and $replaceable.Count -eq 0) {
        $textParts += 'Nothing to deploy.'
    }
    if ($replaceable.Count -gt 0) {
        $textParts += ("Yes = deploy as planned.`nNo = also replace the package content of the {0} app(s) already in Intune. Their detection rule, commands, requirements and assignments stay as they are in Intune.`nCancel = do nothing." -f $replaceable.Count)
        $buttons = 'YesNoCancel'
    }
    else {
        $textParts += $(if ($create.Count -gt 0) { 'Continue?' } else { 'Nothing will be changed.' })
        $buttons = $(if ($create.Count -gt 0) { 'YesNo' } else { 'OK' })
    }

    $answer = [string](& $Ask ($textParts -join "`n`n") $buttons)
    if ($answer -eq 'Cancel' -or $answer -eq 'None' -or ($buttons -eq 'YesNo' -and $answer -ne 'Yes')) {
        Write-Host "Deploy cancelled - nothing was changed." -ForegroundColor Yellow
        return $null
    }
    if ($buttons -eq 'OK') { return $null }

    if ($answer -eq 'No' -and $replaceable.Count -gt 0) {
        $plan = @(Get-DeployPlan -Rows $rows -ReplaceExisting)
    }

    $todo    = @($plan | Where-Object { $_.Action -ne 'Skip' })
    $skipped = @($plan | Where-Object { $_.Action -eq 'Skip' } | ForEach-Object { '{0}: {1}' -f $_.Key, $_.Reason })

    # Bauen nur, was verteilt wird und noch kein Paket hat.
    $builtByKey = @{}
    $toBuild = @($todo | Where-Object { -not $_.Row.HasPackage -and $_.Row.HasDefinition } | ForEach-Object { $_.Row })
    if ($toBuild.Count -gt 0) {
        $built = Invoke-PackageBuild -Rows $toBuild -PacketRoot $PacketRoot -RootDir $RootDir -ToolVersion $ToolVersion -RemoveExisting $RemoveExisting
        foreach ($b in @($built.Built)) { $builtByKey[('{0} - {1}' -f $b.AppName, $b.AppVersion)] = $b }
    }

    $packages = @()
    foreach ($item in $todo) {
        $path = [string]$item.Row.FullPath
        if (-not $path -and $builtByKey.ContainsKey($item.Key)) { $path = [string]$builtByKey[$item.Key].FullPath }
        if (-not $path) { continue }   # Bau gescheitert - Invoke-PackageBuild hat es gemeldet
        $mode = $(if ($item.Action -eq 'Update') { 'Update' } else { 'New' })
        $packages += [pscustomobject]@{
            AppName     = $item.Row.AppName
            AppVersion  = $item.Row.AppVersion
            FullPath    = $path
            Mode        = $mode
            UpdateAppId = $item.UpdateAppId
        }
    }

    if ($packages.Count -gt 0) {
        Invoke-PackageDeploy -Packages $packages -Tenant $Tenant -RootDir $RootDir -ToolVersion $ToolVersion -Skipped $skipped
    }
    else {
        Write-DeploymentSummary -Succeeded @() -Failed @() -Skipped $skipped
    }
    return $plan
}
