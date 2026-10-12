# ============================================================================
#  Pakete: bauen, Paketordner entfernen, verwaiste Ordner.
# ============================================================================

function Remove-PackageFolder {
    <#
        .SYNOPSIS
        Loescht einen Paketordner, aber nur wenn er plausibel ist.

        .DESCRIPTION
        Der Pfad wird aus CSV-Feldern zusammengesetzt ("<Name> - <Version>").
        Sind die Felder leer, entsteht "<packetRoot>\ - " oder die Wurzel selbst -
        ein rekursives Loeschen wuerde dann den gesamten Paketbestand treffen.
        Geprueft wird daher: der Ordner muss echt UNTERHALB der Wurzel liegen,
        einen Namen mit Substanz haben und existieren.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)][string]$PacketRoot
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Refusing to delete: the package folder path is empty."
    }

    $full = [System.IO.Path]::GetFullPath($Path.TrimEnd('\','/'))
    $root = [System.IO.Path]::GetFullPath($PacketRoot.TrimEnd('\','/'))
    $sep  = [System.IO.Path]::DirectorySeparatorChar

    if ($full -eq $root) {
        throw ("Refusing to delete: the path IS the package root ({0}). Check DisplayName/Version in Apps.csv." -f $root)
    }
    if (-not $full.ToLower().StartsWith($root.ToLower() + $sep)) {
        throw ("Refusing to delete: {0} is not below the package root {1}." -f $full, $root)
    }

    $leaf = Split-Path -Leaf $full
    if ([string]::IsNullOrWhiteSpace(($leaf -replace '[-\s]', ''))) {
        throw ("Refusing to delete: the folder name '{0}' carries no app name or version. Check Apps.csv." -f $leaf)
    }
    if (-not (Test-Path -LiteralPath $full)) { return $false }

    Write-Host ("Removing existing package folder: {0}" -f $full) -ForegroundColor Yellow
    Remove-Item -LiteralPath $full -Recurse -Force
    return $true
}

function Set-PsadtLogPath {
    <#
        Legt das PSADT-Log in den Ordner der Intune Management Extension (neben deren eigene Logs), statt
        nach %windir%\Logs\Software. Das Muster steht so im Template von PSAppDeployToolkit 4.1.8
        (Config\config.psd1, Toolkit.LogPath). Findet es sich nicht (neues Template), bleibt die Datei
        unveraendert und die Funktion gibt $false zurueck - still im falschen Ordner zu loggen waere schlechter.
    #>
    param([Parameter(Mandatory = $true)][string]$ConfigFile)

    $text = [IO.File]::ReadAllText($ConfigFile)
    $old = 'envWinDir\Logs\Software'
    if (-not $text.Contains($old)) { return $false }
    $text = $text.Replace($old, 'envProgramData\Microsoft\IntuneManagementExtension\Logs')
    $file = Get-Item -LiteralPath $ConfigFile
    $file.Attributes = ($file.Attributes -band -bnot [System.IO.FileAttributes]::ReadOnly)
    $folder = $file.Directory
    $folder.Attributes = ($folder.Attributes -band -bnot [System.IO.FileAttributes]::ReadOnly)
    [IO.File]::WriteAllText($ConfigFile, $text, (New-Object System.Text.UTF8Encoding $true))
    return $true
}

function Build-AppPackage {
    <#
        .SYNOPSIS
        Baut das Paket zu einer Definition aus Apps.csv.

        .DESCRIPTION
        Der einzige Weg, ein Paket anzulegen. Stand frueher als Schleifenrumpf in
        createApps; jetzt von "Build" und von "Deploy" (fuer Zeilen ohne Paket)
        gemeinsam benutzt. Gibt den Paketordner zurueck.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$App,
        [Parameter(Mandatory = $true)][string]$PacketRoot,
        [Parameter(Mandatory = $true)][string]$RootDir,
        [Parameter(Mandatory = $true)][string]$ToolVersion,
        [bool]$RemoveExisting = $true
    )

    $AppName = $App.DisplayName
    $AppVersion = $App.Version
    $AppPublisher = $App.Publisher
    $AppNameCombined = $AppName + " - " + $AppVersion
    $SourcePath = "$PacketRoot\$AppNameCombined"
    $ProgramId = $App.ProgramID
    $InstallCmdInternal = $App.InstallCmd
    $UninstallCmdInternal = $App.UninstallCmd
    $winGetParams = $App.WinGetParams -replace "`"",""

    Write-Host "Creating PSADT application: $AppNameCombined" -ForegroundColor Cyan
    if($RemoveExisting -eq $true){
        $null = Remove-PackageFolder -Path $SourcePath -PacketRoot $PacketRoot
    }
    $null = New-ADTTemplate -Destination $PacketRoot -Name $AppNameCombined

    # Auf die Vorlagen-Dateien warten, die gleich gebraucht werden - nicht pauschal 5 Sekunden
    # (Messung 2026-10-11: 15 s bei drei Paketen, in denen nichts gewartet wurde).
    $templateReady = $false
    foreach ($attempt in 1..150) {
        if ((Test-Path -LiteralPath "$SourcePath\Invoke-AppDeployToolkit.ps1") -and (Test-Path -LiteralPath "$SourcePath\Config\config.psd1")) { $templateReady = $true; break }
        Start-Sleep -Milliseconds 200
    }
    if (-not $templateReady) { throw "The PSADT template was not created in '$SourcePath' (30 seconds)." }

    # erstellen von \in und \out, move eine ebene tiefer nach \in,
    Write-Host "Moving data to .\in"
    $psadtdirs = Get-ChildItem $SourcePath
    $null = New-Item -ItemType Directory -Path "$SourcePath\in"
    $null = New-Item -ItemType Directory -Path "$SourcePath\out"
    $psadtdirs | ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination "$SourcePath\in" }

    # PSADT soll in die IME-Logs schreiben
    if (-not (Set-PsadtLogPath -ConfigFile "$SourcePath\in\Config\config.psd1")) {
        Write-Warning "PSADT log path not changed in '$SourcePath\in\Config\config.psd1' (the template looks different than expected) - the PSADT log lands in the default folder, not in the IME logs."
    }

    # für normale Pakete
    # kopieren von detect.ps1 und anpassen
    # Einziger Aufrufer von Write-DetectionScript.
    Write-Host "Writing detection.ps1 from template"
    $arpSearchName = Get-ArpSearchName -DisplayName $AppName -ArpName ([string]$App.ArpName)
    $null = Write-DetectionScript -AppFolder $SourcePath -AppName $AppName -AppVersion $AppVersion -RootDir $RootDir `
        -ProgramId $ProgramId -ArpName $arpSearchName
    # ServiceUI.exe nur fuer Pakete, die Dialoge zeigen sollen (Apps.csv
    # "Interactive"). Dieselbe Entscheidung wie im Installationsbefehl.
    if ((Get-DeployCommandLine -Interactive ([string]$App.Interactive)).NeedsServiceUI) {
        Write-Host "Copying: ServiceUI.exe (Interactive)"
        Copy-Item -LiteralPath "$RootDir\ServiceUI.exe" -Destination "$SourcePath\in"
    }

    # einpflegen von publisher, appname, version ins invoke-AppDeployToolkit.ps1
    # Update der Invoke-AppDeployToolkit.ps1, außer im Fall des Zero-Config Deployment mit 1 single MSI, dann darf hier nichts angepasst werden
    if(-not $App.SingleMSI){
        Write-Host "Copying and customizing: Invoke-AppDeployToolkit.ps1"
        $creationdate = Get-Date -Format "yyyy-MM-dd"
        $psadtscript = Get-Content "$SourcePath\in\Invoke-AppDeployToolkit.ps1"
        $psadtscript -replace "AppVendor = ''","AppVendor = '$AppPublisher'" -replace "AppName = ''", "AppName = '$AppName'" -replace "AppVersion = ''", "AppVersion = '$AppVersion'" `
            -replace "AppScriptDate = '2000-12-31'", "AppScriptDate = '$creationdate'" -replace "AppScriptAuthor = '<author name>'", "AppScriptAuthor = 'alexander@zarenko.net'" `
            | Out-File "$SourcePath\in\Invoke-AppDeployToolkit.ps1" -Encoding utf8 -Force
    }
    if($InstallCmdInternal){
        $null = Insert-Commands -Install $InstallCmdInternal -FilePath "$SourcePath\in\Invoke-AppDeployToolkit.ps1"
    }
    if($UninstallCmdInternal){
        $null = Insert-Commands -Uninstall $UninstallCmdInternal -FilePath "$SourcePath\in\Invoke-AppDeployToolkit.ps1"
    }
    if($AppVersion -eq "LatestAvailable"){
        $InstallCmdInternal = Get-WinGetCommands -type Install -id $ProgramId -wgparams $winGetParams
        $UninstallCmdInternal= Get-WinGetCommands -type Uninstall -id $ProgramId -wgparams $winGetParams
        $null = Insert-Commands -Install $InstallCmdInternal -FilePath "$SourcePath\in\Invoke-AppDeployToolkit.ps1"
        $null = Insert-Commands -Uninstall $UninstallCmdInternal -FilePath "$SourcePath\in\Invoke-AppDeployToolkit.ps1"
    }

    #App version setzen
    if($AppVersion -eq "LatestAvailable"){
        $desc = "Installed using PSADT and WinGet"
    }
    else{
        $desc = "Installed using PSADT"
    }

    # Logo: ein Pfad, der nie abbricht und nichts zu Dritten hochlaedt.
    $null = Resolve-PackageLogo -AppFolder $SourcePath -AppName $AppName -LogoUrl $App.logoURL -RootDir $RootDir

    #deploy template an App anpassen und kopieren
    # Einziger Aufrufer von Write-DeployScript: ein Paket entsteht nur beim Bauen.
    $null = Write-DeployScript -AppFolder $SourcePath -AppName $AppName -AppVersion $AppVersion `
        -Publisher $AppPublisher -Description $desc -RootDir $RootDir -ToolVersion $ToolVersion `
        -Architecture ([string]$App.Architecture) -MinimumOS ([string]$App.MinimumOS) `
        -MsiProductCode ([string]$App.MsiProductCode) -Interactive ([string]$App.Interactive) `
        -DefinitionFingerprint (Get-DefinitionFingerprint -Record $App)

    # Dateien muss weiterhin ein Mensch bereitstellen - fuer eine
    # Nicht-WinGet-App gibt es keine Quelle, aus der das Tool sie holen
    # koennte. Die Befehle dagegen leitet es jetzt selbst ab.
    if($AppVersion -ne "LatestAvailable"){
        Write-Host "ToDo: now add/copy all required files for setup, then press ENTER" -ForegroundColor Cyan
        explorer "$SourcePath\in\Files"
        pause

        $needsEditor = $true
        if(-not $InstallCmdInternal -and -not $UninstallCmdInternal){
            $derived = Get-DerivedInstallCommands -ContentPath "$SourcePath\in" -AppName $arpSearchName
            if($derived){
                Write-Host ("Derived from {0} (engine: {1}):" -f $derived.FileName, $derived.Engine) -ForegroundColor Green
                Write-Host ("  Install:   {0}" -f $derived.Install)
                Write-Host ("  Uninstall: {0}" -f $derived.Uninstall)
                $null = Insert-Commands -Install $derived.Install -FilePath "$SourcePath\in\Invoke-AppDeployToolkit.ps1"
                $null = Insert-Commands -Uninstall $derived.Uninstall -FilePath "$SourcePath\in\Invoke-AppDeployToolkit.ps1"
                # Nur wenn geraten wurde, muss noch jemand draufschauen.
                $needsEditor = -not $derived.Certain
                if($derived.Note){ Write-Host ("  Note: {0}" -f $derived.Note) -ForegroundColor Yellow }
            }
            else{
                Write-Host "No single installer found in Files\ - fill the Install and Uninstall sections by hand." -ForegroundColor Yellow
            }
        }
        else{
            # Apps.csv gibt die Befehle vor, die stehen schon im Skript.
            $needsEditor = $false
        }

        if($needsEditor){
            Write-Host "ToDo: check the Install & Uninstall sections, then press ENTER." -ForegroundColor Cyan
            Open-ScriptForEditing -Path "$SourcePath\in\Invoke-AppDeployToolkit.ps1"
            pause
        }
    }

    return $SourcePath
}

function Invoke-PackageBuild {
    <#
        Baut die Pakete der uebergebenen Inventarzeilen. Eine Zeile, die scheitert,
        haelt die uebrigen nicht auf. Liefert die gebauten Pakete (AppName,
        AppVersion, FullPath des deploy.ps1) und die Namen der gescheiterten.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Rows,
        [Parameter(Mandatory = $true)][string]$PacketRoot,
        [Parameter(Mandatory = $true)][string]$RootDir,
        [Parameter(Mandatory = $true)][string]$ToolVersion,
        [bool]$RemoveExisting = $true
    )

    $built  = @()
    $failed = @()
    foreach ($row in @($Rows)) {
        try {
            $folder = @(Build-AppPackage -App $row.DefinitionRecord -PacketRoot $PacketRoot -RootDir $RootDir `
                -ToolVersion $ToolVersion -RemoveExisting $RemoveExisting) | Select-Object -Last 1
            $built += [pscustomobject]@{
                AppName    = [string]$row.AppName
                AppVersion = [string]$row.AppVersion
                FullPath   = (Join-Path $folder 'deploy.ps1')
            }
        }
        catch {
            Write-Host ("FAILED: {0} - {1}" -f $row.Key, (Format-ErrorDetail $_)) -ForegroundColor Red
            $failed += [string]$row.Key
        }
    }

    Write-Host ""
    Write-Host ("Build summary: {0} built, {1} failed." -f $built.Count, $failed.Count) -ForegroundColor Cyan
    foreach ($package in $built) { Write-Host ("  OK      {0} - {1}" -f $package.AppName, $package.AppVersion) -ForegroundColor Green }
    foreach ($name in $failed)   { Write-Host ("  FAILED  {0}" -f $name) -ForegroundColor Red }

    return [pscustomobject]@{ Built = @($built); Failed = @($failed) }
}

function Get-PackageFolderSummary {
    <# Dateien und Groesse eines Ordners - fuer die Rueckfrage vor dem Loeschen. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
    $bytes = 0
    foreach ($file in $files) { $bytes += $file.Length }
    return [pscustomobject]@{ Files = $files.Count; Bytes = [long]$bytes }
}

function Remove-AppPackages {
    <#
        .SYNOPSIS
        Loescht die Paketordner der uebergebenen Zeilen (Delete package).

        .DESCRIPTION
        Der einzige Weg dafuer. Ein Paket ist loeschbar, sobald es da ist - mit oder ohne
        Definition (Definition und App in Intune bleiben). Er verweigert, was das Tool nicht
        angelegt hat - der Schutz liegt hier und nicht im Knopf:
          - eine Zeile ohne Paketordner wird uebersprungen,
          - ein Ordner, dessen Name nicht "<Name> - <Version>" ist, wird uebersprungen
            (das hat das Tool nicht angelegt),
          - ein Ordner ohne deploy.ps1 wird uebersprungen,
          - das Loeschen selbst macht Remove-PackageFolder (Ordner muss UNTER der
            Wurzel liegen).
        Die App in Intune bleibt unberuehrt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Rows,
        [Parameter(Mandatory = $true)][string]$PacketRoot
    )

    $removed = @(); $skipped = @(); $failed = @()
    foreach ($row in @($Rows)) {
        $key = [string]$row.Key
        if (-not $row.HasPackage -or -not $row.FullPath)     { $skipped += ("{0}: no package folder" -f $key); continue }

        $folder = Split-Path -Parent ([string]$row.FullPath)
        if ((Split-Path -Leaf $folder) -ne $key)             { $skipped += ("{0}: folder name '{1}' is not '<Name> - <Version>' - not made by this tool" -f $key, (Split-Path -Leaf $folder)); continue }
        if (-not (Test-Path -LiteralPath (Join-Path $folder 'deploy.ps1'))) { $skipped += ("{0}: no deploy.ps1 in the folder" -f $key); continue }

        try {
            if (Remove-PackageFolder -Path $folder -PacketRoot $PacketRoot) { $removed += $key }
            else { $skipped += ("{0}: folder already gone" -f $key) }
        }
        catch { $failed += ("{0}: {1}" -f $key, (Format-ErrorDetail $_)) }
    }
    return [pscustomobject]@{ Removed = @($removed); Skipped = @($skipped); Failed = @($failed) }
}
