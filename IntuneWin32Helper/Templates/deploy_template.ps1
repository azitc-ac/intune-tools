param(
    [switch]$bulk,

    # Ziel-Tenant, uebergeben vom aufrufenden Lauf (deployApps / createApps).
    # Ist er gesetzt, erscheint in diesem Skript kein Auswahldialog mehr.
    $Tenant,

    # Entscheidung des aufrufenden Laufs (Invoke-InventoryDeploy -> Get-DeployPlan):
    #   New    - eine neue App anlegen
    #   Update - die App -UpdateAppId auf den Stand dieses Pakets bringen: Paketinhalt, Icon, Erkennungsregel,
    #            Befehlszeilen, Anforderung, Herausgeber und Beschreibung. Name, Version und Zuweisungen bleiben.
    #   Ask    - nur beim direkten Aufruf dieses Skripts: nach einer gleichnamigen App suchen
    #            und fragen (mit -bulk: immer neu anlegen).
    # Das Tool uebergibt immer New oder Update: so legt ein Lauf keine Dublette an, nur weil das
    # Skript die App in Intune nicht selbst gesucht hat.
    [ValidateSet('Ask', 'New', 'Update')]
    [string]$Mode = 'Ask',
    [string]$UpdateAppId = ''
)
# Vorlagen-Stempel, gesetzt beim Erzeugen. Das Inventar vergleicht ihn gegen den
# aktuellen Vorlagenstand und zeigt so, welches Paket nachgezogen werden sollte.
# ToolTemplateFingerprint: #TPLFP#
# Stand der Definition (Apps.csv-Zeile), aus der das Paket gebaut wurde. Das Inventar vergleicht ihn mit der
# Zeile von heute und zeigt so, dass das Paket vor einer Aenderung der Definition gebaut wurde.
# ToolDefinitionFingerprint: #DEFFP#

$rootDir = "#ROOT#"

# Funktionen zuerst laden: die Konfiguration kommt ueber Get-ToolConfig.
. $rootDir\functions\functions.ps1

$config = Get-ToolConfig -RootDir $rootDir

$packetRoot = $config.packetRoot
if(-not (Test-Path $packetRoot)){md $packetRoot}

check-prereqs

# Tenant-Auswahl und Anmeldung laufen ueber EINEN Pfad (Initialize-IntuneConnection).
# Wurde der Tenant vom aufrufenden Lauf uebergeben, erscheint hier kein Dialog -
# auch dann nicht, wenn der Token abgelaufen ist und neu geholt werden muss.
# Fehlt er (direkter Aufruf dieses Skripts), wird genau einmal gefragt.
$Tenant = Initialize-IntuneConnection -Tenant $Tenant -Tenants $config.tenants
Write-Host "Tenant: $($Tenant.name)"

# Names Application, description and publisher info
$PackageName = "#PN#"
$Displayname = "#DN#"
$Description = "#DESC#"
$Publisher = "#PUB#"
$AppVersion = "#VER#"

# Create working direcotry for the Application, set download location, and download installer
$appname=$PackageName
$apppath=$PSScriptRoot
$inpath=$apppath + "\in"
$outpath=$apppath + "\out"

# create a temporary short source path to prevent problems with long fullnames
$drive = Get-FirstFreeDriveLetter
subst $drive $inpath
$shortsourcepath = $drive + "\"
# Pfadlaengen melden, BEVOR gepackt wird: beim Packen faellt nichts auf, weil
# die Quelle per subst kurz ist - auf dem Client entscheidet der IMECache-Pfad.
Write-PackagePathWarning -ContentPath $inpath

try {
    # Create the intunewin file from source and destination variables
    $installer="Invoke-AppDeployToolkit.ps1"
    $SetupFile = $installer
    $Destination = $outpath
    # Jedes Cmdlet des Moduls ueber Invoke-IntuneModuleCall: das Modul beendet
    # Fehlerpfade mit "break" statt throw - ohne Huelle liefe hier kein Guard.
    $CreateAppPackage = Invoke-IntuneModuleCall -Label 'New-IntuneWin32AppPackage' -Operation {
        New-IntuneWin32AppPackage -SourceFolder $shortsourcepath -SetupFile $SetupFile -OutputFolder $Destination -Force -Verbose
    }
    # Get intunewin file Meta data and assign intunewin file location variable
    $IntuneWinFile = $CreateAppPackage.Path
    $IntuneWinMetaData = Invoke-IntuneModuleCall -Label 'Get-IntuneWin32AppMetaData' -Operation {
        Get-IntuneWin32AppMetaData -FilePath $IntuneWinFile
    }
}
finally {
    # Immer freigeben: bricht das Packen ab, blieb der Laufwerksbuchstabe sonst
    # bis zum Abmelden belegt und der naechste Lauf griff zum naechsten Buchstaben.
    subst $drive /d
}

# Create Detection Rule
# Erkennung: bei einem MSI nativ ueber den ProductCode, sonst per Skript.
# Nativ heisst: der Intune-Client prueft selbst - kein PowerShell-Host, kein
# Timeout, kein Skript, das bei einem Fehler "nicht installiert" meldet.
# Die Version wird mitgeprueft, sonst gilt eine aeltere Fassung als aktuell -
# genau der Fehler, den die WinGet-Erkennung hatte.
$MsiProductCode = "#MSIPRODUCTCODE#"
if ($MsiProductCode) {
    if ($AppVersion -and $AppVersion -ne "LatestAvailable") {
        Write-Host "Detection rule: native MSI product code [$MsiProductCode], version >= [$AppVersion]"
        $DetectionRule = Invoke-IntuneModuleCall -Label 'New-IntuneWin32AppDetectionRuleMSI' -Operation {
            New-IntuneWin32AppDetectionRuleMSI -ProductCode $MsiProductCode -ProductVersionOperator greaterThanOrEqual -ProductVersion $AppVersion
        }
    }
    else {
        Write-Host "Detection rule: native MSI product code [$MsiProductCode] (no version to compare)"
        $DetectionRule = Invoke-IntuneModuleCall -Label 'New-IntuneWin32AppDetectionRuleMSI' -Operation {
            New-IntuneWin32AppDetectionRuleMSI -ProductCode $MsiProductCode
        }
    }
}
else {
    Write-Host "Detection rule: script (detection.ps1)"
    $DetectionRule = Invoke-IntuneModuleCall -Label 'New-IntuneWin32AppDetectionRuleScript' -Operation {
        New-IntuneWin32AppDetectionRuleScript -ScriptFile ($apppath + "\detection.ps1")
    }
}

# Create Requirement Rule
# Requirement Rule aus Apps.csv statt fuer alle gleich. Bisher bekam JEDE App
# x64 und W10_20H2 - auf einem ARM64-Geraet kam damit nichts an, und eine App,
# die ein neueres Windows braucht, wurde trotzdem angeboten.
$Architecture = "#ARCH#"
$MinimumOS    = "#MINOS#"
if (-not $Architecture) { $Architecture = "x64" }
if (-not $MinimumOS)    { $MinimumOS    = "W10_20H2" }
Write-Host "Requirement rule: architecture [$Architecture], minimum OS [$MinimumOS]"
$RequirementRule = Invoke-IntuneModuleCall -Label 'New-IntuneWin32AppRequirementRule' -Operation {
    New-IntuneWin32AppRequirementRule -Architecture $Architecture -MinimumSupportedOperatingSystem $MinimumOS
}

# Create a Icon from an image file
if(Test-Path "$apppath\$appname.png"){$ImageFile = "$apppath\$appname.png"}else{$ImageFile = "$apppath\defaultLogo.png"}
$Icon = Invoke-IntuneModuleCall -Label 'New-IntuneWin32AppIcon' -Operation { New-IntuneWin32AppIcon -FilePath $ImageFile }

#Install and Uninstall Commands
# Standard still und ohne ServiceUI; "true" = PSADT-Dialoge ueber ServiceUI.
# Entschieden wird nur in Get-DeployCommandLine.
$Interactive = "#INTERACTIVE#"
$commandLines = Get-DeployCommandLine -Interactive $Interactive
Write-Host ("Install command: {0}" -f $commandLines.Install)
$InstallCommandLine = $commandLines.Install
$UninstallCommandLine = $commandLines.Uninstall

# Vermerk in der App: "Created by IntuneWin32Helper <Version>; definition <Stempel>". Der Stempel ist der Stand der
# Definition, aus der dieses Paket gebaut wurde; das Inventar liest ihn aus Intune zurueck und kann so sagen, ob die
# App dort der Definition von heute entspricht (Format-IntuneAppNotes / Get-IntuneAppDefinitionFingerprint).
$AppNotes = Format-IntuneAppNotes -ToolVersion "#TOOLVER#" -DefinitionFingerprint "#DEFFP#"

# Ergebnis des Uploads. Add-IntuneWin32App wirft bei einem fehlgeschlagenen Upload
# oder Commit KEINE Exception, sondern schreibt nur eine Warnung und gibt $null zurueck
# (siehe Modulquelle). Ohne diese Pruefung meldet das Skript "Finished." obwohl die App
# ohne Inhalt in Intune liegt - in einem Bulk-Lauf faellt das niemandem auf.
$uploadResult = $null

# Der Upload einer neuen App - an EINER Stelle, drei Wege fuehren hierher.
$addNewApp = {
    Invoke-IntuneModuleCall -Label 'Add-IntuneWin32App' -Operation {
        Add-IntuneWin32App -FilePath $IntuneWinFile -DisplayName $DisplayName -Description $Description -Publisher $Publisher -AppVersion $AppVersion -InstallExperience "system" -RestartBehavior "suppress" -DetectionRule $DetectionRule -RequirementRule $RequirementRule -InstallCommandLine $InstallCommandLine -UninstallCommandLine $UninstallCommandLine -Icon $Icon -Notes $AppNotes -Verbose
    }
}

# Die Entscheidung kommt vom aufrufenden Lauf (-Mode). Nur der direkte Aufruf dieses
# Skripts (Mode Ask) sucht selbst nach einer gleichnamigen App und fragt.
if ($Mode -eq 'New') {
    Write-Host "Decision of the calling run: create a new app"
    $uploadResult = & $addNewApp
}
elseif ($Mode -eq 'Update') {
    if ([string]::IsNullOrWhiteSpace($UpdateAppId)) { throw "Mode Update needs -UpdateAppId." }
    Write-Host "Decision of the calling run: update app $UpdateAppId (package content and definition; assignments stay)"
    # Das Ergebnis wird geprueft: bei einem Fehler schreibt das Modul nur eine Warnung und
    # gibt nichts zurueck (siehe Modulquelle) - ohne die Pruefung meldete das Skript "Finished.".
    $uploadResult = Invoke-IntuneModuleCall -Label 'Update-IntuneWin32AppPackageFile' -Operation {
        Update-IntuneWin32AppPackageFile -ID $UpdateAppId -FilePath $IntuneWinFile
    }
    if ($uploadResult) {
        # Update-IntuneWin32AppPackageFile aendert nur den Inhalt und das Icon. Erkennungsregel, Befehlszeilen,
        # Anforderung, Herausgeber und Beschreibung kommen aus der Definition und werden jetzt nachgezogen
        # (Set-IntuneWin32App aendert nur, was uebergeben wird - die Zuweisungen bleiben). Name und Version
        # bleiben: danach wird die App gefunden.
        Write-Host "Updating detection rule, requirement rule, commands, icon, publisher and description of app $UpdateAppId"
        $null = Invoke-IntuneModuleCall -Label 'Set-IntuneWin32App' -Operation {
            Set-IntuneWin32App -ID $UpdateAppId -Publisher $Publisher -Description $Description -DetectionRule $DetectionRule -InstallCommandLine $InstallCommandLine -UninstallCommandLine $UninstallCommandLine -Icon $Icon -Notes $AppNotes -Verbose
        }
        # Die Anforderung nimmt Set-IntuneWin32App nicht an (siehe Set-TenantAppRequirement).
        Set-TenantAppRequirement -Id $UpdateAppId -RequirementRule $RequirementRule
        # Das Modul meldet einen Fehler mitunter nur als Warnung: nachlesen, ob die Befehlszeile angekommen ist.
        $readBack = Invoke-IntuneModuleCall -Label 'Get-IntuneWin32App' -Operation { Get-IntuneWin32App -ID $UpdateAppId }
        if (-not $readBack -or [string]$readBack.installCommandLine -ne [string]$InstallCommandLine) {
            throw ("The package content of '{0}' was replaced, but its definition (detection rule, commands) could not be updated in Intune - see the warnings above." -f $Displayname)
        }
        Write-Host "Definition of the app is up to date in Intune."
    }
}
else {
    # check if there is an app with the same name already which could be updated
    $existingapps = $null
    $existingapps = Invoke-IntuneModuleCall -Label 'Get-IntuneWin32App' -Operation { Get-IntuneWin32App -DisplayName $Displayname }

    if($existingapps){
        Add-Type -AssemblyName Microsoft.VisualBasic
        # if the parameter bulk is not set, ask if a new app should be created
        if($bulk -ne $true){

            $result = [Microsoft.VisualBasic.Interaction]::MsgBox('An existing application with the same name has been detected. Create a new application? Select "No" to update an existing one. ','YesNoCancel,SystemModal,Information', 'Create or update an application')
            if($result -eq "Yes"){
                #BULK IS NOT SET
                #ANSWER WAS "YES, CREATE A NEW APP"
                #Builds the App and Uploads to Intune
                $uploadResult = & $addNewApp
            }
            if($result -eq "No"){
                #BULK IS NOT SET
                #ANSWER WAS "NO, UPDATE an existing APP"
                #Builds the App and Uploads to Intune
                #Updates the App
                # Auswahl ueber den Dialog des Tools statt Out-GridView (ogv):
                # ogv braucht einen STA-Host und fehlt in PowerShell 7 ohne Zusatzmodul.
                $updateCandidates = Invoke-IntuneModuleCall -Label 'Get-IntuneWin32App' -Operation { Get-IntuneWin32App -DisplayName $Displayname } |
                    Select-Object id, displayName, displayVersion, createdDateTime
                $app = Get-SingleDialogSelection -Value (Open-SelectDialog -data @($updateCandidates) -title "Select the app to update" -size medium)
                if (-not $app) { throw "No application selected for update - aborting." }
                # Bricht das Modul hier per break ab (kein Token, contentVersions nicht
                # angelegt), wirft Invoke-IntuneModuleCall. Bei einem fehlgeschlagenen Commit
                # gibt das Modul nichts zurueck - dann bleibt $uploadResult leer und unten wird geworfen.
                $uploadResult = Invoke-IntuneModuleCall -Label 'Update-IntuneWin32AppPackageFile' -Operation {
                    Update-IntuneWin32AppPackageFile -ID $app.id -FilePath $IntuneWinFile
                }
            }
        }
        else{
            #BULK IS SET, always build a NEW App without asking
            $uploadResult = & $addNewApp
        }
    }
    else{
        $uploadResult = & $addNewApp
    }
}
if (-not $uploadResult) {
    throw ("Upload to Intune FAILED for '{0}' - see the warnings above. An app entry may exist in Intune without content and should be removed." -f $Displayname)
}

Write-Host "Finished." -ForegroundColor Green
#if($bulk -ne $true){pause}else{Start-Sleep -Seconds 3}