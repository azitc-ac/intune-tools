# ============================================================================
#  Installer: Pfadlaenge, Installer-Engine erkennen, Install-Befehle ableiten, MSI-Eigenschaften, WinGet-Befehle.
# ============================================================================

function Measure-PackageContentPath {
    <#
        .SYNOPSIS
        Der laengste Pfad, den dieses Paket auf dem Client erzeugt.

        .DESCRIPTION
        Muster aus SCCMAppHelper, auf Intune uebertragen. Windows bricht bei 260
        Zeichen ab, 259 sind nutzbar. Beim Packen faellt das nicht auf, weil das
        Quellverzeichnis per subst an einem Laufwerksbuchstaben haengt und
        dadurch kurz ist. Auf dem Client entpackt die Intune Management Extension
        nach C:\Windows\IMECache\<guid>\ - erst dort entscheidet die Laenge, und
        der Fehler lautet dann "Datei nicht gefunden", nicht "Pfad zu lang".

        AssumedPrefixLength ist eine ANNAHME, nicht gemessen:
        "C:\Windows\IMECache\" sind 20 Zeichen, eine GUID 36, plus ein
        Trennzeichen - 57. Weicht das auf einem Geraet ab, verschiebt sich die
        Grenze; die Ausgabe nennt die Annahme deshalb mit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ContentPath,
        [int]$Limit = 259,
        [int]$AssumedPrefixLength = 57
    )

    $root = (Resolve-Path -LiteralPath $ContentPath).Path.TrimEnd('\', '/')
    $longest = 0
    $offenders = @()

    foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $relative = $item.FullName.Substring($root.Length).TrimStart('\', '/')
        $total = $AssumedPrefixLength + $relative.Length
        if ($total -gt $longest) { $longest = $total }
        if ($total -gt $Limit) { $offenders += [pscustomobject]@{ Relative = $relative; Length = $total } }
    }

    return [pscustomobject]@{
        Longest             = $longest
        Limit               = $Limit
        AssumedPrefixLength = $AssumedPrefixLength
        Offenders           = @($offenders)
    }
}

function Write-PackagePathWarning {
    <#
        Meldet das Ergebnis von Measure-PackageContentPath. Nur eine Warnung,
        kein Abbruch: die Annahme ueber den IMECache-Pfad kann abweichen, und
        eine Fehlmeldung darf kein Paket verhindern.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ContentPath)

    try { $scan = Measure-PackageContentPath -ContentPath $ContentPath }
    catch {
        Write-Host ("Path length could not be measured ({0})." -f $_.Exception.Message) -ForegroundColor DarkGray
        return
    }

    Write-Host ("Longest client-side path: {0} of {1} characters (assuming a {2}-character IMECache prefix)." -f `
        $scan.Longest, $scan.Limit, $scan.AssumedPrefixLength) -ForegroundColor DarkGray

    if ($scan.Offenders.Count -eq 0) { return }

    Write-Host ("{0} file(s) exceed the limit. On the client this surfaces as 'file not found', not as a path length problem:" -f `
        $scan.Offenders.Count) -ForegroundColor Yellow
    foreach ($o in @($scan.Offenders | Sort-Object Length -Descending | Select-Object -First 5)) {
        Write-Host ("  {0} chars  {1}" -f $o.Length, $o.Relative) -ForegroundColor Yellow
    }
}

function Get-InstallerEngineSwitch {
    <#
        Die Silent-Schalter je Installer-Engine. Uebernommen aus SCCMAppHelper.
        'unknown' bekommt /S - den NSIS-Schalter - und einen Vermerk, dass das
        geraten ist. Der Vermerk landet als Kommentar im erzeugten Befehl, damit
        beim Nachlesen niemand eine Sicherheit unterstellt, die es nicht gibt.
    #>
    param([Parameter(Mandatory = $true)][string]$Engine)

    switch ($Engine.ToLower()) {
        # /ALLUSERS: Intune installiert als SYSTEM. Ein Inno-Setup, das beide
        # Modi erlaubt, installiert sonst benutzerbezogen - ins Profil von
        # SYSTEM. Im Feld (2026-09-28, Greenshot 1.3.315) landete die App so in
        # C:\Windows\system32\config\systemprofile\AppData\Local\Programs\ und
        # war fuer den Benutzer nicht vorhanden. Setups mit nur einem Modus
        # ignorieren den Schalter.
        'inno'           { return [pscustomobject]@{ Engine = 'inno';           Install = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /ALLUSERS'; Uninstall = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'; Note = '' } }
        'nsis'           { return [pscustomobject]@{ Engine = 'nsis';           Install = '/S';                                       Uninstall = '/S';                                       Note = '' } }
        '7zip'           { return [pscustomobject]@{ Engine = '7zip';           Install = '/S';                                       Uninstall = '/S';                                       Note = '' } }
        'burn'           { return [pscustomobject]@{ Engine = 'burn';           Install = '/quiet /norestart';                        Uninstall = '/quiet /norestart';                        Note = '' } }
        'installshield'  { return [pscustomobject]@{ Engine = 'installshield';  Install = '/s /v"/qn REBOOT=ReallySuppress"';         Uninstall = '/s';                                       Note = 'InstallShield: /s /v"/qn" bei MSI-basierten Setups, /s bei InstallScript - Herstellerdoku pruefen' } }
        'vsbootstrapper' { return [pscustomobject]@{ Engine = 'vsbootstrapper'; Install = '--quiet --norestart --wait';               Uninstall = '--quiet --norestart --wait';               Note = 'Visual-Studio-Bootstrapper: --wait ist noetig, sonst kehrt der Installer vor dem Ende zurueck' } }
        default          { return [pscustomobject]@{ Engine = 'unknown';        Install = '/S';                                       Uninstall = '/S';                                       Note = 'Engine nicht erkannt - /S ist der NSIS-Schalter, vor dem Verteilen pruefen' } }
    }
}

function Get-InstallerEngine {
    <#
        Erkennt die Installer-Engine an der Datei selbst: Versionsressource plus
        die ersten 6 MB als ASCII und als Unicode. Uebernommen aus SCCMAppHelper.

        Der Sinn: die Silent-Schalter muessen nicht mehr von Hand in Apps.csv
        getippt werden. Was nicht erkannt wird, ist ausdruecklich geraten und
        sagt das auch.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $engine = 'unknown'
    try {
        $info = (Get-Item -LiteralPath $Path).VersionInfo
        $description = [string]$info.FileDescription + ' ' + [string]$info.InternalName + ' ' + [string]$info.ProductName

        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $length = [int][Math]::Min($stream.Length, 6MB)
            $buffer = New-Object byte[] $length
            $null = $stream.Read($buffer, 0, $length)
        }
        finally { $stream.Close() }

        $ascii   = [System.Text.Encoding]::ASCII.GetString($buffer)
        $unicode = [System.Text.Encoding]::Unicode.GetString($buffer)

        if     ($ascii -match 'Inno Setup'    -or $unicode -match 'Inno Setup')    { $engine = 'inno' }
        elseif ($ascii -match 'Nullsoft'      -or $unicode -match 'Nullsoft')      { $engine = 'nsis' }
        elseif ($ascii -match '\.wixburn')                                         { $engine = 'burn' }
        elseif ($ascii -match 'InstallShield' -or $unicode -match 'InstallShield') { $engine = 'installshield' }
        elseif ($description -match '7-Zip Installer')                             { $engine = '7zip' }
        elseif ($description -match '^vs_|SSMS Installer|Visual Studio Installer') { $engine = 'vsbootstrapper' }
    }
    catch { $engine = 'unknown' }

    return (Get-InstallerEngineSwitch -Engine $engine)
}

function Find-PackageInstaller {
    <#
        Der Installer eines Pakets: genau ein MSI oder genau eine EXE in Files\.
        Sind es mehrere, wird nichts geliefert - ein geratener Installer haette
        die falsche Engine und damit die falschen Schalter.
    #>
    param([Parameter(Mandatory = $true)][string]$ContentPath)

    $files = Join-Path $ContentPath 'Files'
    if (-not (Test-Path -LiteralPath $files)) { return $null }

    $msi = @(Get-ChildItem -LiteralPath $files -Filter '*.msi' -File -ErrorAction SilentlyContinue)
    if ($msi.Count -eq 1) { return [pscustomobject]@{ Kind = 'msi'; File = $msi[0] } }
    if ($msi.Count -gt 1) { return $null }

    $exe = @(Get-ChildItem -LiteralPath $files -Filter '*.exe' -File -ErrorAction SilentlyContinue)
    if ($exe.Count -eq 1) { return [pscustomobject]@{ Kind = 'exe'; File = $exe[0] } }
    return $null
}

function Get-DerivedInstallCommands {
    <#
        .SYNOPSIS
        Leitet Install- und Uninstall-Befehl aus dem Installer im Paket ab.

        .DESCRIPTION
        Bisher musste der Benutzer sie von Hand in Apps.csv tippen oder in der
        ISE ins PSADT-Skript schreiben - mit zwei "pause" im Ablauf. Damit war
        Massenerstellung fuer Nicht-WinGet-Apps konstruktiv unmoeglich.

        Die Befehlsformen sind die des Schwester-Tools SCCMAppHelper:
        MSI ueber Start-ADTMsiProcess, EXE ueber Start-ADTProcess und
        Uninstall-ADTApplication.

        .OUTPUTS
        Objekt mit Install, Uninstall, Engine, FileName und Note - oder $null,
        wenn kein eindeutiger Installer gefunden wurde.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ContentPath,
        [Parameter(Mandatory = $true)][string]$AppName
    )

    $installer = Find-PackageInstaller -ContentPath $ContentPath
    if (-not $installer) { return $null }

    return (Get-InstallCommandsForFile -Path $installer.File.FullName -AppName $AppName)
}

function Get-InstallCommandsForFile {
    <#
        Install- und Uninstall-Befehl fuer EINE Installer-Datei (MSI oder EXE). Der gemeinsame Weg des Paketbaus
        (Get-DerivedInstallCommands, Installer aus Files\) und des Editors ("From installer...", beliebige Datei):
        derselbe Vorschlag, den der Bau spaeter ohnehin einsetzt. Der Dateiname im Befehl ist der Name in Files\.
        $AppName ist der Suchname der Programmliste (Get-ArpSearchName).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AppName
    )

    $installer = [pscustomobject]@{
        Kind = $(if ([IO.Path]::GetExtension($Path) -eq '.msi') { 'msi' } else { 'exe' })
        File = (Get-Item -LiteralPath $Path)
    }
    $name = $installer.File.Name

    if ($installer.Kind -eq 'msi') {
        return [pscustomobject]@{
            Engine    = 'msi'
            FileName  = $name
            Install   = "Start-ADTMsiProcess -Action Install -FilePath '$name'"
            Uninstall = "Start-ADTMsiProcess -Action Uninstall -FilePath '$name'"
            Note      = ''
            Certain   = $true
        }
    }

    $engine = Get-InstallerEngine -Path $installer.File.FullName
    # $AppName ist hier der Suchname in der Programmliste (Get-ArpSearchName),
    # nicht zwingend der Intune-Name.
    $searchName = $AppName.Replace("'", "''")

    # Dieselbe Regel wie die Erkennung (detection_template.ps1: DisplayName -like
    # "<Name>*"). Ohne -NameMatch vergleicht PSADT 4 mit 'Contains' und
    # deinstalliert JEDEN Treffer (Uninstall-ADTApplication: foreach) - "Git"
    # haette auch "GitHub Desktop" entfernt, und Erkennung und Deinstallation
    # konnten verschiedene Eintraege treffen.
    $install   = "Start-ADTProcess -FilePath '$name' -ArgumentList '$($engine.Install)'"
    $uninstall = "Uninstall-ADTApplication -Name '$searchName*' -NameMatch 'Wildcard' -ApplicationType EXE -AdditionalArgumentList '$($engine.Uninstall)'"
    if ($engine.Note) {
        $install   += "   # " + $engine.Note
        $uninstall += "   # " + $engine.Note
    }

    return [pscustomobject]@{
        Engine    = $engine.Engine
        FileName  = $name
        Install   = $install
        Uninstall = $uninstall
        Note      = $engine.Note
        Certain   = ($engine.Engine -ne 'unknown')
    }
}

# --- Hilfsfunktion: MSI-Eigenschaften lesen (ProductName/Version/Manufacturer) ---
function Get-MsiProperties {
    param([Parameter(Mandatory=$true)][string]$Path)

    $props = @{}
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database  = $installer.GetType().InvokeMember('OpenDatabase','InvokeMethod',$null,$installer,@($Path,0))

        foreach ($p in 'ProductName','ProductVersion','Manufacturer','ProductCode') {
            $view   = $database.GetType().InvokeMember('OpenView','InvokeMethod',$null,$database,@("SELECT `Value` FROM `Property` WHERE `Property`='$p'"))
            $null   = $view.GetType().InvokeMember('Execute','InvokeMethod',$null,$view,$null)
            $record = $view.GetType().InvokeMember('Fetch','InvokeMethod',$null,$view,$null)
            if ($record) {
                $val = $record.GetType().InvokeMember('StringData','GetProperty',$null,$record,1)
                if ($val) { $props[$p] = $val }
            }
            $null = $view.GetType().InvokeMember('Close','InvokeMethod',$null,$view,$null)
        }
    } catch { }
    return $props
}

function Get-FirstFreeDriveLetter {
    $used = (Get-PSDrive -PSProvider 'FileSystem').Name
    $all = [char[]]([byte][char]'C'..[byte][char]'Z')
    foreach ($letter in $all) {
        if ($letter -notin $used) {
            return "$letter" + ":"
        }
    }
}

function Insert-Commands {
    param (
        [string]$FilePath,
        [string[]]$Install,
        [string[]]$Uninstall
    )

    if (!(Test-Path $FilePath)) {
        Write-Error "File '$FilePath' was not found."
        return
    }

    $content = Get-Content $FilePath
    $newContent = @()
    $insertedMarkers = @{}

    if($Install){
        $markers = @{
                '## <Perform Installation tasks here>' = $Install
            }
    }
    elseif($Uninstall){
        $markers = @{
                '## <Perform Uninstallation tasks here>' = $Uninstall
            }
    }
    for ($i = 0; $i -lt $content.Count; $i++) {
        $line = $content[$i]
        $newContent += $line

        foreach ($marker in $markers.Keys) {
            if ($line -like "*$marker*" -and -not $insertedMarkers.ContainsKey($marker)) {
                $newContent += $markers[$marker]
                $insertedMarkers[$marker] = $true
            }
        }
    }

    Set-Content -Path $FilePath -Value $newContent
    Write-Host "Code successfully added after: $($insertedMarkers.Keys -join ', ')"
}

function get-WinGetCommands{
    param(
        [ValidateSet("Install", "Uninstall")]
        [string]$type,
        [string]$id,
        [string]$wgparams
    )

$WingetDefaultCmdsPart1= @'
$logFile = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\<WINGETPROGRAMID>_<ACT>.log"
Write-ADTLogEntry "Action: [<ACT>], PackageID: [<WINGETPROGRAMID>]"
Write-ADTLogEntry "Resolving winget_exe"
try {
    $wingetPaths = Resolve-Path "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller*\winget.exe" -ErrorAction Stop
} catch {
    Write-ADTLogEntry "Winget not installed or path resolution failed: $_"
    exit 1
}
if ($wingetPaths.Count -gt 1) {
    $wingetPaths = $wingetPaths | Sort-Object { (Get-Item $_.Path).CreationTime } -Descending
    $wingetPath = $wingetPaths[0].Path
} elseif ($wingetPaths.Count -eq 1) {
    $wingetPath = $wingetPaths[0].Path
} else {
    Write-ADTLogEntry "Winget executable not found."
    exit 1
}
Write-ADTLogEntry "Using winget path: $wingetPath"
$accpackagree = "--accept-package-agreements"
'@
$WinGetInstallArgs = @'
$arguments = @(
    "<ACT>"
    "--exact"
    "--id", "<WINGETPROGRAMID>"
    "--silent"
    "--accept-source-agreements"
    $accpackagree    
) + "<WINGETPARAMS>"
'@
$WinGetUninstallArgs = @'
$arguments = @(
    "<ACT>"
    "--exact"
    "--id", "<WINGETPROGRAMID>"
    "--silent"
    "--accept-source-agreements"    
) + "<WINGETPARAMS>"
'@
$WingetDefaultCmdsPart3= @'
$ArgumentList = $($arguments -join ' ').trim()
$result=Start-ADTProcess -FilePath $wingetPath -ArgumentList "$ArgumentList" -PassThru
$result = $result -replace 'Ôûê', '░' -replace 'ÔûÆ', '█' -replace 'Γûê', '█'
Write-ADTLogEntry "WinGet output:"
Write-ADTLogEntry $result
'@

    $WingetDefaultCmdsPart1 = $WingetDefaultCmdsPart1 -replace "<ACT>", $type -replace "<WINGETPROGRAMID>", $id
    $WinGetInstallArgs = $WinGetInstallArgs -replace "<WINGETPARAMS>", $wgparams -replace "<WINGETPROGRAMID>", $id -replace "<ACT>", $type
    $WinGetUninstallArgs = $WinGetUninstallArgs -replace "<WINGETPARAMS>", $wgparams -replace "<WINGETPROGRAMID>", $id -replace "<ACT>", $type

    switch ($type) {
        "install" {
            $WingetDefaultCmdsPart2 = $WinGetInstallArgs
        }
        "uninstall" {
            $WingetDefaultCmdsPart2 = $WinGetUninstallArgs        
        }
    }
    
    $WingetDefaultCmds = @(
        $WingetDefaultCmdsPart1
        $WingetDefaultCmdsPart2
        $WingetDefaultCmdsPart3
    ) -join "`n"

    return $WingetDefaultCmds

}
