# ============================================================================
#  Gemeinsame Helfer
#  Ein Pfad fuer Dialog-Rueckgaben, Tenant-Auswahl und Graph-Anmeldung.
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

function Get-ImageExtensionFromUrl {
    <#
        Die Endung einer Logo-URL, ohne Query und Fragment. Bisher galt
        "endet nicht auf .png" als "ist webp" - ein .jpg oder eine URL mit ?v=2
        landete dadurch im webp-Zweig und damit in einem Upload zu einem
        Drittanbieter.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }
    $withoutQuery = ($Url -split '[?#]')[0]
    $ext = [System.IO.Path]::GetExtension($withoutQuery)
    if (-not $ext) { return '' }
    return $ext.ToLowerInvariant()
}

function Resize-IconFile {
    <#
        .SYNOPSIS
        Normalisiert ein Logo auf ein Quadrat und schreibt es als PNG.

        .DESCRIPTION
        Muster aus SCCMAppHelper. Ohne Normalisierung wanderten Logos in
        Originalgroesse ins Paket - defaultlogo.png allein war 632 KB, und das
        fuer jede App ohne eigenes Logo. Das Seitenverhaeltnis bleibt erhalten,
        der Rest ist transparent.

        Laesst sich die Datei nicht oeffnen (fehlender Codec bei webp, svg,
        kaputte Datei), gibt die Funktion $false zurueck. Ist System.Drawing auf
        der Maschine selbst unbenutzbar (PowerShell 7 unter Linux), kann die
        .NET-Typinitialisierung eine Ausnahme werfen, die sich hier nicht fangen
        laesst - Aufrufer kapseln den Aufruf deshalb. Resolve-PackageLogo tut das.
        Mit -CopyOnFailure wird die Quelle unveraendert kopiert - das ist nur
        sinnvoll, wenn sie schon ein brauchbares PNG ist.

        .OUTPUTS
        [bool] $true, wenn wirklich umgerechnet wurde.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Destination,
        [int]$Size = 256,
        [switch]$CopyOnFailure
    )

    # Nicht-terminierende Fehler hier terminierend machen, sonst laeuft ein
    # fehlgeschlagenes New-Object ungefangen weiter und die Ausnahme entkommt
    # dem catch - genau so kam "The type initializer for '<Module>' threw an
    # exception" aus dieser Funktion heraus.
    $ErrorActionPreference = 'Stop'

    $temp = $Destination + '.resize.tmp'

    # Probe in eigenem try: auf einer Maschine ohne benutzbares System.Drawing
    # (PowerShell 7 unter Linux) scheitert erst die Typinitialisierung, und dieser
    # Fehler entkam einem catch weiter unten. Deshalb hier ein echter Mini-Aufruf.
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $probe = New-Object System.Drawing.Bitmap 1, 1
        $probe.Dispose()
    }
    catch {
        Write-Host ("System.Drawing is not usable here ({0}) - icon left unchanged." -f $_.Exception.Message) -ForegroundColor Yellow
        if ($CopyOnFailure -and $Path -ne $Destination) {
            Copy-Item -LiteralPath $Path -Destination $Destination -Force
        }
        return $false
    }

    try {
        $sourcePath = (Resolve-Path -LiteralPath $Path).Path
        $source = [System.Drawing.Image]::FromFile($sourcePath)
        try {
            $bitmap = New-Object System.Drawing.Bitmap $Size, $Size
            try {
                $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
                try {
                    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $graphics.Clear([System.Drawing.Color]::Transparent)
                    $scale = [Math]::Min($Size / $source.Width, $Size / $source.Height)
                    $w = [int][Math]::Round($source.Width * $scale)
                    $h = [int][Math]::Round($source.Height * $scale)
                    $graphics.DrawImage($source, [int](($Size - $w) / 2), [int](($Size - $h) / 2), $w, $h)
                }
                finally { $graphics.Dispose() }
                # Erst in eine temporaere Datei: Quelle und Ziel duerfen derselbe
                # Pfad sein, und die Quelle ist noch geoeffnet.
                $bitmap.Save($temp, [System.Drawing.Imaging.ImageFormat]::Png)
            }
            finally { $bitmap.Dispose() }
        }
        finally { $source.Dispose() }

        Move-Item -LiteralPath $temp -Destination $Destination -Force
        Write-Host ("Icon normalised to {0}x{0}." -f $Size) -ForegroundColor DarkGray
        return $true
    }
    catch {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        Write-Host ("Icon could not be resized ({0})." -f $_.Exception.Message) -ForegroundColor Yellow
        if ($CopyOnFailure -and $Path -ne $Destination) {
            Copy-Item -LiteralPath $Path -Destination $Destination -Force
        }
        return $false
    }
}

function Resolve-PackageLogo {
    <#
        .SYNOPSIS
        Legt das Logo einer App im Paketordner als <AppName>.png ab.

        .DESCRIPTION
        EIN Pfad fuer den ganzen Weg: vorhandenes Logo, Download, Normalisierung,
        Rueckfall. Vorher lag das offen im Ablauf von createApps und konnte den
        Paketbau abbrechen - eine Logo-URL, die nicht auf .png endete, ging in
        einen Upload zu Cloudinary, und mit leeren Zugangsdaten (so wie in
        config.sample.json) wirft PowerShell dort "Cannot bind argument ...
        because it is an empty string".

        Es wird nichts mehr zu Dritten hochgeladen. Ein Format, das sich lokal
        nicht oeffnen laesst, fuehrt zum Standardlogo - ohne Logo ist eine App
        verteilbar, ohne Paket nicht.

        .OUTPUTS
        [string] Dateiname des Logos im Paketordner, '' wenn selbst das
        Standardlogo nicht ablegbar war.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AppFolder,
        [Parameter(Mandatory = $true)][string]$AppName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$LogoUrl,
        [Parameter(Mandatory = $true)][string]$RootDir
    )

    $logoDir     = Join-Path $RootDir 'Logos'
    $defaultLogo = Join-Path $logoDir 'defaultlogo.png'
    $target      = Join-Path $AppFolder ($AppName + '.png')

    # Erst kopieren, dann normalisieren - in dieser Reihenfolge. Das Template
    # braucht die Datei; ob sie auch auf 256x256 gebracht werden konnte, ist
    # zweitrangig. Vorher hing die Existenz am Umrechnen, und auf einer Maschine
    # ohne benutzbares System.Drawing landete gar kein Logo im Paket - womit
    # New-IntuneWin32AppIcon und damit das ganze Deployment gescheitert waere.
    $copyThenResize = {
        param([string]$Source)
        Copy-Item -LiteralPath $Source -Destination $target -Force
        # Das Normalisieren darf das Ergebnis nicht gefaehrden: die Datei liegt
        # schon richtig, der Rest ist Kosmetik.
        try { $null = Resize-IconFile -Path $target -Destination $target } catch { }
        return (Split-Path -Leaf $target)
    }

    $useDefault = {
        if (-not (Test-Path -LiteralPath $defaultLogo)) {
            Write-Host ("Default logo missing ({0})." -f $defaultLogo) -ForegroundColor Yellow
            return ''
        }
        return (& $copyThenResize $defaultLogo)
    }

    try {
        $existing = Join-Path $logoDir ($AppName + '.png')
        if (Test-Path -LiteralPath $existing) {
            Write-Host ("Using existing logo [{0}]" -f $existing)
            return (& $copyThenResize $existing)
        }

        if ([string]::IsNullOrWhiteSpace($LogoUrl)) {
            Write-Host "No logo URL specified. Taking default logo."
            return (& $useDefault)
        }

        $ext = Get-ImageExtensionFromUrl -Url $LogoUrl
        if (-not $ext) { $ext = '.img' }
        $download = Join-Path $AppFolder ($AppName + '.download' + $ext)

        Write-Host ("Trying logo download ({0})..." -f $ext)
        Invoke-WebRequest -Uri $LogoUrl -OutFile $download -UseBasicParsing -ErrorAction Stop

        if (Resize-IconFile -Path $download -Destination $target) {
            Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
            # Ins Logos-Verzeichnis uebernehmen, damit der naechste Lauf nicht
            # erneut herunterlaedt.
            Copy-Item -LiteralPath $target -Destination $logoDir -Force
            return (Split-Path -Leaf $target)
        }

        Write-Host ("Logo format {0} cannot be read on this machine - taking the default logo." -f $ext) -ForegroundColor Yellow
        Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
        return (& $useDefault)
    }
    catch {
        Write-Host ("Logo handling failed ({0}) - taking the default logo." -f $_.Exception.Message) -ForegroundColor Yellow
        try { return (& $useDefault) } catch { return '' }
    }
}

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
        [AllowEmptyString()][string]$Interactive = ''
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
        -replace "#TPLFP#", (Get-TemplateFingerprint -RootDir $RootDir) |
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

    Write-DeployScript -AppFolder $appFolder -AppName $appName -AppVersion $appVersion `
        -Publisher $publisher -Description $description -RootDir $RootDir -ToolVersion $ToolVersion `
        -Architecture $architecture -MinimumOS $minimumOS -MsiProductCode $msiProductCode `
        -Interactive $interactive

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
            Write-Warning ("Konnte CSV nicht schreiben: {0}" -f $_.Exception.Message)
        }
    }

    return $results
}


# ============================================================================
#  Hauptfenster: das Inventar ist der Ausgangspunkt
#
#  Muster aus SCCMAppHelper (Show-InventoryDialog). Pro App eine Zeile; links
#  Definition und Paket, rechts die App im Tenant. Jede Aktion geht von dieser
#  Liste aus - anlegen, bauen, verteilen. Die Kacheln "Create / Create and
#  deploy / Deploy" und die beiden Auswahldialoge dahinter gibt es nicht mehr:
#  sie zeigten je einen Ausschnitt desselben Zustands.
#
#  Das Fenster fuehrt nichts aus. Es gibt die Aktion und die markierten Zeilen
#  zurueck (Start-InventoryLoop arbeitet sie ab), damit die Konsole dort bleibt,
#  wo gearbeitet wird, und das Fenster nach jeder Aktion neu aufgebaut wird.
# ============================================================================

function Get-AppsCsvColumns {
    <#
        Die Spalten von Apps.csv: die bekannten in fester Reihenfolge, danach
        alles, was Zeilen sonst noch mitbringen (eine eigene Spalte darf beim
        Speichern nicht verschwinden). EINE Quelle fuer Lesen, Bearbeiten und
        Speichern - der Bearbeitungsdialog zeigt genau diese Spalten.
    #>
    [CmdletBinding()]
    param($Definitions = @())

    # Aufgegebene Spalten: aeltere Apps.csv tragen sie noch. Sie werden nicht mehr als eigene Spalte
    # behandelt, sondern fallen beim naechsten Speichern weg (PackageName las kein Code - der Paketname
    # kommt aus DisplayName).
    $retired = @('PackageName')
    $columns = New-Object System.Collections.ArrayList
    foreach ($name in @('ProgramID', 'Publisher', 'DisplayName', 'Version', 'WinGetParams', 'SingleMSI',
                        'InstallCmd', 'UninstallCmd', 'logoURL', 'Architecture', 'MinimumOS', 'MsiProductCode', 'Interactive', 'ArpName')) {
        $null = $columns.Add($name)
    }
    foreach ($definition in @($Definitions)) {
        if ($null -eq $definition) { continue }
        foreach ($name in $definition.PSObject.Properties.Name) {
            if ($name -ne '__InternalId' -and $retired -notcontains $name -and ($columns -notcontains $name)) { $null = $columns.Add($name) }
        }
    }
    return @($columns)
}

function Get-AppsCsvPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RootDir)
    return (Join-Path $RootDir 'Apps.csv')
}

function Read-AppsCsv {
    <# Einziger Lesepfad fuer Apps.csv. Fehlt die Datei, gibt es keine Definitionen. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RootDir)

    $path = Get-AppsCsvPath -RootDir $RootDir
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Import-Csv -LiteralPath $path -Delimiter ';')
}

function Save-AppsCsv {
    <#
        Einziger Schreibpfad fuer Apps.csv. Sortiert nach Name und Version,
        schreibt alle Spalten (auch eigene) und behaelt das Format bei:
        Semikolon, alles in Anfuehrungszeichen, UTF-8 mit BOM.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RootDir,
        [AllowEmptyCollection()]$Rows = @()
    )

    $path    = Get-AppsCsvPath -RootDir $RootDir
    $columns = @(Get-AppsCsvColumns -Definitions $Rows)

    # Stabil sortieren: Sort-Object ist unter 5.1 nicht stabil, und ein zweiter Sortierschluessel
    # (Version) vertauschte Zeilen gleichen Namens bei jedem Speichern - die Datei zeigte
    # Aenderungen, die keine sind. Gleiche Namen behalten ihre Reihenfolge.
    $position = 0
    $ordered = @(@($Rows) | ForEach-Object { [pscustomobject]@{ Row = $_; Position = $position++ } } | Sort-Object { [string]$_.Row.DisplayName }, Position | ForEach-Object {
        $row = $_.Row
        $copy = [ordered]@{}
        foreach ($column in $columns) { $copy[$column] = [string]$row.$column }
        [pscustomobject]$copy
    })

    if ($ordered.Count -gt 0) {
        $ordered | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    }
    else {
        # Export-Csv schreibt ohne Zeilen auch keine Kopfzeile - dann waere die Datei leer.
        ('"' + ($columns -join '";"') + '"') | Set-Content -LiteralPath $path -Encoding UTF8
    }
}

function Test-AppRecord {
    <# Liefert den Grund, warum ein Datensatz so nicht gespeichert werden soll, sonst $null. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Record,
        $Others = @()
    )

    $name    = ([string]$Record.DisplayName).Trim()
    $version = ([string]$Record.Version).Trim()
    if (-not $name)    { return 'DisplayName is empty - the application name and the package folder come from it.' }
    if (-not $version) { return 'Version is empty - use LatestAvailable for a WinGet app.' }

    $clash = @(@($Others) | Where-Object { ([string]$_.DisplayName).Trim() -eq $name -and ([string]$_.Version).Trim() -eq $version })
    if ($clash.Count -gt 0) {
        return ("'{0} - {1}' already exists. Name and version make the package folder name and must be unique." -f $name, $version)
    }
    return $null
}

function Edit-AppRecord {
    <#
        Oeffnet den Bearbeitungsdialog fuer einen Datensatz (oder einen leeren) und
        gibt das Ergebnis als Objekt zurueck - $null bei Abbruch.
    #>
    [CmdletBinding()]
    param(
        $Record,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string[]]$ColumnOrder,
        [System.Collections.IDictionary]$Info,
        $Others = @()
    )

    $hash = @{}
    foreach ($column in $ColumnOrder) {
        if ($Record) { $hash[$column] = [string]$Record.$column } else { $hash[$column] = '' }
    }

    $edited = Open-EditDialog -item $hash -title $Title -PropertyOrder $ColumnOrder -Info $Info -Others $Others
    $edited = @($edited | Where-Object { $_ -is [System.Collections.IDictionary] }) | Select-Object -First 1
    if (-not $edited) { return $null }

    $result = [ordered]@{}
    foreach ($column in $ColumnOrder) { $result[$column] = [string]$edited[$column] }
    return [pscustomobject]$result
}

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
        Write-Host ("Tenant state could not be read ({0}) - the Intune column stays empty." -f $_.Exception.Message) -ForegroundColor Yellow
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
        Write-Host ("No connection to a tenant ({0}) - the Intune column stays empty." -f $_.Exception.Message) -ForegroundColor Yellow
        return $null
    }
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

    # log path ändern
    $psadtconfigfilepath = "$SourcePath\in\Config\config.psd1"
    $psadtconfig= Get-Content $psadtconfigfilepath
    $psadtconfig= $psadtconfig.Replace("envWinDir\Logs\Software", "envProgramData\Microsoft\IntuneManagementExtension\Logs")
    $psadtconfigfolderPath = Get-Item "$SourcePath\in\Config"
    (Get-Item $psadtconfigfolderPath).Attributes = ((Get-Item $psadtconfigfolderPath).Attributes -band -bnot [System.IO.FileAttributes]::ReadOnly)
    $psadtconfig | Out-File $psadtconfigfilepath -Encoding utf8 -Force

    # für normale Pakete
    # kopieren von detect.ps1 und anpassen
    # Gemeinsamer Pfad mit Update-DeployScript (Write-DetectionScript).
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
    # Gemeinsamer Pfad mit Update-DeployScript - Anlegen und Erneuern nutzen EINE Quelle.
    $null = Write-DeployScript -AppFolder $SourcePath -AppName $AppName -AppVersion $AppVersion `
        -Publisher $AppPublisher -Description $desc -RootDir $RootDir -ToolVersion $ToolVersion `
        -Architecture ([string]$App.Architecture) -MinimumOS ([string]$App.MinimumOS) `
        -MsiProductCode ([string]$App.MsiProductCode) -Interactive ([string]$App.Interactive)

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
            Write-Host ("FAILED: {0} - {1}" -f $row.Key, $_.Exception.Message) -ForegroundColor Red
            $failed += [string]$row.Key
        }
    }

    Write-Host ""
    Write-Host ("Build summary: {0} built, {1} failed." -f $built.Count, $failed.Count) -ForegroundColor Cyan
    foreach ($package in $built) { Write-Host ("  OK      {0} - {1}" -f $package.AppName, $package.AppVersion) -ForegroundColor Green }
    foreach ($name in $failed)   { Write-Host ("  FAILED  {0}" -f $name) -ForegroundColor Red }

    return [pscustomobject]@{ Built = @($built); Failed = @($failed) }
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
            Write-Host ("FAILED: {0} - {1}" -f $appLabel, $_.Exception.Message) -ForegroundColor Red
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
            $results += [pscustomobject]@{ Id = $id; Key = [string]$app.Key; State = 'Failed'; Detail = $_.Exception.Message }
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
function Show-ConfirmDialog {
    <#
        .SYNOPSIS
        Eine Rueckfrage als eigenes Fenster - Ersatz fuer MessageBox, der sich per UI Automation bedienen laesst.

        .DESCRIPTION
        Gibt 'Yes' | 'No' | 'Cancel' | 'OK' zurueck, wie [MessageBox]::Show. Die Taste -Default ist die
        Standardtaste (Enter) und hat den Fokus; Esc und das Schliessen des Fensters antworten mit der
        "sicheren" Antwort (OK, No bzw. Cancel) - nie mit Yes. AutomationIds: ConfirmDialog, ConfirmText,
        ConfirmYes, ConfirmNo, ConfirmCancel, ConfirmOK.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Title = 'IntuneWin32Helper',
        [ValidateSet('OK', 'YesNo', 'YesNoCancel')][string]$Buttons = 'OK',
        [ValidateSet('Yes', 'No', 'Cancel', 'OK')][string]$Default = 'OK',
        [ValidateSet('None', 'Question', 'Warning', 'Information')][string]$Icon = 'None'
    )

    Add-Type -AssemblyName PresentationCore      -ErrorAction SilentlyContinue | Out-Null
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue | Out-Null

    $names = switch ($Buttons) {
        'YesNo'       { @('Yes', 'No') }
        'YesNoCancel' { @('Yes', 'No', 'Cancel') }
        default       { @('OK') }
    }
    if ($names -notcontains $Default) { $Default = $names[0] }
    $safe = $names[-1]

    $window = New-Object Windows.Window
    $window.Title = $Title
    $window.Width = 760
    $window.SizeToContent = 'Height'
    $window.MaxHeight = 720
    $window.WindowStartupLocation = 'CenterScreen'
    $window.ResizeMode = 'NoResize'
    $window.Tag = $safe
    [Windows.Automation.AutomationProperties]::SetAutomationId($window, 'ConfirmDialog')

    $grid = New-Object Windows.Controls.Grid
    $grid.Margin = '16'
    foreach ($height in 'Auto', 'Auto') {
        $rowDefinition = New-Object Windows.Controls.RowDefinition
        $rowDefinition.Height = [Windows.GridLength]::Auto
        $null = $grid.RowDefinitions.Add($rowDefinition)
    }

    $body = New-Object Windows.Controls.DockPanel
    $body.LastChildFill = $true
    $glyph = switch ($Icon) { 'Warning' { [string][char]0x26A0 } 'Question' { '?' } 'Information' { 'i' } default { '' } }
    if ($glyph) {
        $iconBlock = New-Object Windows.Controls.TextBlock
        $iconBlock.Text = $glyph
        $iconBlock.FontSize = 32
        $iconBlock.Margin = '0,0,14,0'
        $iconBlock.VerticalAlignment = 'Top'
        $iconBlock.Foreground = $(if ($Icon -eq 'Warning') { 'DarkOrange' } else { 'SteelBlue' })
        [Windows.Controls.DockPanel]::SetDock($iconBlock, 'Left')
        $null = $body.Children.Add($iconBlock)
    }
    $scroll = New-Object Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $scroll.MaxHeight = 560
    $textBlock = New-Object Windows.Controls.TextBlock
    $textBlock.Text = $Text
    $textBlock.TextWrapping = 'Wrap'
    [Windows.Automation.AutomationProperties]::SetAutomationId($textBlock, 'ConfirmText')
    $scroll.Content = $textBlock
    $null = $body.Children.Add($scroll)
    [Windows.Controls.Grid]::SetRow($body, 0)
    $null = $grid.Children.Add($body)

    $panel = New-Object Windows.Controls.StackPanel
    $panel.Orientation = 'Horizontal'
    $panel.HorizontalAlignment = 'Right'
    $panel.Margin = '0,16,0,0'
    $defaultButton = $null
    foreach ($name in $names) {
        $button = New-Object Windows.Controls.Button
        $button.Content = $name
        $button.MinWidth = 84
        $button.Padding = '14,4'
        $button.Margin = '8,0,0,0'
        $button.IsDefault = ($name -eq $Default)
        $button.IsCancel  = ($name -eq $safe)
        [Windows.Automation.AutomationProperties]::SetAutomationId($button, "Confirm$name")
        $answer = $name
        $button.Add_Click({ $window.Tag = $answer; $window.Close() }.GetNewClosure())
        if ($name -eq $Default) { $defaultButton = $button }
        $null = $panel.Children.Add($button)
    }
    [Windows.Controls.Grid]::SetRow($panel, 1)
    $null = $grid.Children.Add($panel)

    $window.Content = $grid
    $window.Add_ContentRendered({ $null = $defaultButton.Focus() }.GetNewClosure())
    $null = $window.ShowDialog()
    return [string]$window.Tag
}
function Show-InventoryDialog {
    <#
        .SYNOPSIS
        Das Hauptfenster. Gibt { Action, Selection, TenantName } zurueck.

        .DESCRIPTION
        Action: Add | NewVersion | Edit | Delete | Build | Deploy | Rebuild | Retire |
                OpenFolder | RemoveFolder | Refresh | SwitchTenant | Cancel | Closed
        Jede Aktion hier hat in Start-InventoryLoop einen Zweig - das prueft
        Tests\Invoke-RepoChecks.ps1 (kein Knopf ohne Gegenstueck).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Inventory,
        [string]$Title = 'IntuneWin32Helper',
        [string]$PacketRoot = '',
        [string[]]$TenantNames = @(),
        [string]$TenantName = '',
        [bool]$IntuneRead = $true,
        [string]$ConfigPath = '',
        # Schluessel ("<Name> - <Version>") der Zeilen, die beim Oeffnen markiert
        # sein sollen. Das Fenster wird nach jeder Aktion neu gebaut; die Zeile,
        # an der gerade gearbeitet wurde, soll nicht neu gesucht werden muessen.
        [string[]]$Select = @()
    )

    Add-Type -AssemblyName PresentationCore      -ErrorAction SilentlyContinue | Out-Null
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue | Out-Null

    $rows = @($Inventory)

    $window = New-Object Windows.Window
    $window.Title = $Title
    $window.Width = 1280
    $window.Height = 720
    $window.MinWidth = 960
    $window.MinHeight = 480
    $window.WindowStartupLocation = 'CenterScreen'
    [Windows.Automation.AutomationProperties]::SetAutomationId($window, 'MainDialog')

    $grid = New-Object Windows.Controls.Grid
    $grid.Margin = '12'
    foreach ($height in 'Auto', '*', 'Auto', 'Auto') {
        $rowDefinition = New-Object Windows.Controls.RowDefinition
        $rowDefinition.Height = $(if ($height -eq '*') { New-Object Windows.GridLength -ArgumentList 1, ([Windows.GridUnitType]::Star) } else { [Windows.GridLength]::Auto })
        $null = $grid.RowDefinitions.Add($rowDefinition)
    }

    # --- obere Leiste: Tenant, Ansicht, Filter, Refresh ---
    $top = New-Object Windows.Controls.DockPanel
    $top.Margin = '0,0,0,8'

    $refreshButton = New-Object Windows.Controls.Button
    $refreshButton.Content = 'Refresh'
    $refreshButton.Padding = '14,4'
    $refreshButton.Margin = '8,0,0,0'
    $refreshButton.ToolTip = 'Read Apps.csv, the package folders and the tenant again'
    [Windows.Automation.AutomationProperties]::SetAutomationId($refreshButton, 'Refresh')
    [Windows.Controls.DockPanel]::SetDock($refreshButton, 'Right')
    $null = $top.Children.Add($refreshButton)

    $tenantLabel = New-Object Windows.Controls.TextBlock
    $tenantLabel.Text = 'Tenant:'
    $tenantLabel.VerticalAlignment = 'Center'
    $tenantLabel.Margin = '0,0,6,0'
    [Windows.Controls.DockPanel]::SetDock($tenantLabel, 'Left')
    $null = $top.Children.Add($tenantLabel)

    $tenantItems = @('(not connected)') + @($TenantNames)
    $initialTenantIndex = 0
    if ($TenantName) {
        $found = [array]::IndexOf($tenantItems, $TenantName)
        if ($found -ge 0) { $initialTenantIndex = $found }
    }
    $tenantBox = New-Object Windows.Controls.ComboBox
    $tenantBox.ItemsSource = $tenantItems
    $tenantBox.SelectedIndex = $initialTenantIndex
    $tenantBox.MinWidth = 200
    $tenantBox.Margin = '0,0,12,0'
    $tenantBox.VerticalContentAlignment = 'Center'
    $tenantBox.ToolTip = 'The tenant whose apps the Intune column shows - and where Deploy uploads to'
    [Windows.Automation.AutomationProperties]::SetAutomationId($tenantBox, 'Tenant')
    [Windows.Controls.DockPanel]::SetDock($tenantBox, 'Left')
    $null = $top.Children.Add($tenantBox)

    # Die Ansicht: welcher der drei Zustaende einer Zeile interessiert.
    $views = @(
        [pscustomobject]@{ Name = 'All (foreign Intune apps hidden)'; Test = { $_.Origin -ne 'foreign' } },
        [pscustomobject]@{ Name = 'Definition only (no package)';     Test = { $_.Status -eq 'Definition only' } },
        [pscustomobject]@{ Name = 'Package, not in Intune';           Test = { $_.HasPackage -and ($_.Intune -eq '-' -or $_.Intune -like 'other version*') } },
        [pscustomobject]@{ Name = 'In Intune';                        Test = { $_.Intune -like 'yes*' -or $_.Intune -eq 'no content' } },
        [pscustomobject]@{ Name = 'Template outdated';                Test = { $_.Template -eq 'outdated' -or $_.Template -eq 'unstamped' } },
        [pscustomobject]@{ Name = 'Duplicates or empty in Intune';    Test = { $_.Intune -eq 'no content' -or $_.Intune -like 'yes (*' } },
        [pscustomobject]@{ Name = 'Package without definition';       Test = { $_.HasPackage -and -not $_.HasDefinition } },
        [pscustomobject]@{ Name = 'Intune only (created by this tool)'; Test = { $_.IntuneOnly -and $_.Origin -eq 'tool' } },
        [pscustomobject]@{ Name = 'Foreign apps in Intune';           Test = { $_.Origin -eq 'foreign' } },
        [pscustomobject]@{ Name = 'Everything, incl. foreign apps';   Test = { $true } }
    )
    $viewLabel = New-Object Windows.Controls.TextBlock
    $viewLabel.Text = 'Show:'
    $viewLabel.VerticalAlignment = 'Center'
    $viewLabel.Margin = '0,0,6,0'
    [Windows.Controls.DockPanel]::SetDock($viewLabel, 'Left')
    $null = $top.Children.Add($viewLabel)

    $viewBox = New-Object Windows.Controls.ComboBox
    $viewBox.ItemsSource = @($views | ForEach-Object { $_.Name })
    $viewBox.SelectedIndex = 0
    $viewBox.Width = 230
    $viewBox.Margin = '0,0,8,0'
    $viewBox.VerticalContentAlignment = 'Center'
    [Windows.Automation.AutomationProperties]::SetAutomationId($viewBox, 'View')
    [Windows.Controls.DockPanel]::SetDock($viewBox, 'Left')
    $null = $top.Children.Add($viewBox)

    $filterBox = New-Object Windows.Controls.TextBox
    $filterBox.Padding = '4'
    $filterBox.VerticalContentAlignment = 'Center'
    $filterBox.ToolTip = 'Filter - matches name, version, publisher, package state, Intune state and next step'
    [Windows.Automation.AutomationProperties]::SetAutomationId($filterBox, 'Filter')
    $null = $top.Children.Add($filterBox)
    [Windows.Controls.Grid]::SetRow($top, 0)
    $null = $grid.Children.Add($top)

    # --- die Liste ---
    $dataGrid = New-Object Windows.Controls.DataGrid
    $dataGrid.AutoGenerateColumns = $false
    $dataGrid.IsReadOnly = $true
    $dataGrid.CanUserSortColumns = $true
    $dataGrid.SelectionMode = 'Extended'
    $dataGrid.SelectionUnit = 'FullRow'
    $dataGrid.GridLinesVisibility = 'Horizontal'
    $dataGrid.HeadersVisibility = 'Column'
    [Windows.Automation.AutomationProperties]::SetAutomationId($dataGrid, 'InventoryGrid')

    $converter = New-Object Windows.Media.BrushConverter
    $leftHeaderBrush  = $converter.ConvertFromString('#EDEDED')   # Definition und Paket
    $rightHeaderBrush = $converter.ConvertFromString('#D6E6F7')   # Tenant
    $separatorBrush   = $converter.ConvertFromString('#7FA6D1')

    # Farben je Zustand: gruen ist erledigt, blau der naechste Schritt, orange
    # will angesehen werden, rot stimmt nicht, grau fehlt noch.
    $statusColors = @(
        @('Package',                      'DarkGreen'),
        @('Package, template outdated',   'DarkOrange'),
        @('Package, template unstamped',  'DarkOrange'),
        @('Definition only',              'Gray'),
        @('No definition',                'Firebrick')
    )
    $nextColors = @(
        @('up to date',                                       'DarkGreen'),
        @('deploy',                                           'DodgerBlue'),
        @('renew from template, then deploy',                 'DarkOrange'),
        @('check duplicates in Intune',                       'DarkOrange'),
        @('remove the entry without content in Intune',       'Firebrick'),
        @('package without a row in Apps.csv',                'Firebrick'),
        @('create package',                                   'Gray')
    )

    $columnSpecs = @(
        @{ Header = 'Application'; Binding = 'AppName';    Width = 250; Right = $false; Colors = $null },
        @{ Header = 'Version';     Binding = 'AppVersion'; Width = 120; Right = $false; Colors = $null },
        @{ Header = 'Publisher';   Binding = 'Publisher';  Width = 170; Right = $false; Colors = $null },
        @{ Header = 'Package';     Binding = 'Status';     Width = 200; Right = $false; Colors = $statusColors },
        @{ Header = 'Intune';      Binding = 'Intune';     Width = 190; Right = $true;  Colors = $null; Separator = $true },
        @{ Header = 'Next step';   Binding = 'Next';       Width = 0;   Right = $true;  Colors = $nextColors }
    )

    foreach ($spec in $columnSpecs) {
        $column = New-Object Windows.Controls.DataGridTextColumn
        $column.Header = $spec.Header
        $column.Binding = New-Object Windows.Data.Binding($spec.Binding)
        $column.CanUserSort = $true
        if ($spec.Width -gt 0) { $column.Width = $spec.Width }
        else { $column.Width = New-Object Windows.Controls.DataGridLength -ArgumentList 1, ([Windows.Controls.DataGridLengthUnitType]::Star) }

        try {
            # Die Kopfzeile sagt, auf welcher Seite die Spalte steht.
            $headerStyle = New-Object Windows.Style -ArgumentList ([Windows.Controls.Primitives.DataGridColumnHeader])
            $headerBrush = $(if ($spec.Right) { $rightHeaderBrush } else { $leftHeaderBrush })
            $null = $headerStyle.Setters.Add((New-Object Windows.Setter -ArgumentList ([Windows.Controls.Control]::BackgroundProperty), $headerBrush))
            $null = $headerStyle.Setters.Add((New-Object Windows.Setter -ArgumentList ([Windows.Controls.Control]::PaddingProperty), (New-Object Windows.Thickness -ArgumentList 8, 5, 8, 5)))
            $null = $headerStyle.Setters.Add((New-Object Windows.Setter -ArgumentList ([Windows.Controls.Control]::FontWeightProperty), ([Windows.FontWeights]::SemiBold)))
            if ($spec.Separator) {
                $null = $headerStyle.Setters.Add((New-Object Windows.Setter -ArgumentList ([Windows.Controls.Control]::BorderBrushProperty), $separatorBrush))
                $null = $headerStyle.Setters.Add((New-Object Windows.Setter -ArgumentList ([Windows.Controls.Control]::BorderThicknessProperty), (New-Object Windows.Thickness -ArgumentList 2, 0, 0, 0)))
            }
            $column.HeaderStyle = $headerStyle

            $cellStyle = New-Object Windows.Style -ArgumentList ([Windows.Controls.DataGridCell])
            if ($spec.Separator) {
                $null = $cellStyle.Setters.Add((New-Object Windows.Setter -ArgumentList ([Windows.Controls.Control]::BorderBrushProperty), $separatorBrush))
                $null = $cellStyle.Setters.Add((New-Object Windows.Setter -ArgumentList ([Windows.Controls.Control]::BorderThicknessProperty), (New-Object Windows.Thickness -ArgumentList 2, 0, 0, 0)))
            }
            foreach ($pair in @($spec.Colors)) {
                if (-not $pair) { continue }
                $trigger = New-Object Windows.DataTrigger
                $trigger.Binding = New-Object Windows.Data.Binding($spec.Binding)
                $trigger.Value = $pair[0]
                $brush = [System.Windows.Media.Brushes]::($pair[1])
                $null = $trigger.Setters.Add((New-Object Windows.Setter -ArgumentList ([Windows.Controls.Control]::ForegroundProperty), $brush))
                $null = $cellStyle.Triggers.Add($trigger)
            }
            $column.CellStyle = $cellStyle
        }
        catch { }   # Optik - kein Grund, das Fenster nicht zu zeigen
        $null = $dataGrid.Columns.Add($column)
    }

    # Der Tooltip einer Zeile nennt alle drei Zustaende.
    try {
        $rowStyle = New-Object Windows.Style -ArgumentList ([Windows.Controls.DataGridRow])
        $null = $rowStyle.Setters.Add((New-Object Windows.Setter -ArgumentList ([Windows.Controls.DataGridRow]::ToolTipProperty), (New-Object Windows.Data.Binding('Detail'))))
        $dataGrid.RowStyle = $rowStyle
    }
    catch { }

    # Die erste Ansicht (fremde Intune-Apps ausgeblendet) gilt schon beim Oeffnen, nicht erst nach dem ersten Filterwechsel.
    $dataGrid.ItemsSource = @($rows | Where-Object $views[0].Test)
    [Windows.Controls.Grid]::SetRow($dataGrid, 1)
    $null = $grid.Children.Add($dataGrid)

    # --- Statuszeile ---
    $status = New-Object Windows.Controls.TextBlock
    $status.Margin = '0,8,0,0'
    $status.Foreground = [System.Windows.Media.Brushes]::DimGray
    $status.TextWrapping = 'Wrap'
    [Windows.Automation.AutomationProperties]::SetAutomationId($status, 'Status')
    $ownRows     = @($rows | Where-Object { $_.Origin -ne 'foreign' })
    $foreignRows = @($rows | Where-Object { $_.Origin -eq 'foreign' })
    $withPackage = @($ownRows | Where-Object { $_.HasPackage }).Count
    $inIntune    = @($ownRows | Where-Object { $_.Intune -like 'yes*' -or $_.Intune -eq 'no content' }).Count
    $summary = ('{0} application(s) - {1} with a package in {2} - {3} in Intune{4}{5}' -f
                    $ownRows.Count, $withPackage, $PacketRoot, $inIntune,
                    $(if ($foreignRows.Count -gt 0) { (' - {0} foreign Intune app(s) hidden (see Show:)' -f $foreignRows.Count) } else { '' }),
                    $(if (-not $IntuneRead) { ' - the tenant was not read, the Intune column is empty' } else { '' }))
    $status.Text = $summary
    $defaultShownCount = $ownRows.Count
    [Windows.Controls.Grid]::SetRow($status, 2)
    $null = $grid.Children.Add($status)

    # Ansicht und Textfilter gelten zusammen; die Statuszeile sagt, wie viele zu sehen sind.
    $applyFilter = {
        $view   = $views[[Math]::Max(0, $viewBox.SelectedIndex)]
        $needle = $filterBox.Text
        $items  = @($rows | Where-Object $view.Test)
        if (-not [string]::IsNullOrWhiteSpace($needle)) {
            $items = @($items | Where-Object {
                $row = $_
                @(@('AppName', 'AppVersion', 'Publisher', 'Status', 'Intune', 'Next') | Where-Object { [string]$row.$_ -like "*$needle*" }).Count -gt 0
            })
        }
        $dataGrid.ItemsSource = $null
        $dataGrid.ItemsSource = @($items)
        $status.Text = $(if ($items.Count -eq $defaultShownCount -and $viewBox.SelectedIndex -le 0 -and [string]::IsNullOrWhiteSpace($needle)) { $summary } else { '{0} of {1} shown - {2}' -f $items.Count, $rows.Count, $summary })
    }
    $filterBox.Add_TextChanged($applyFilter)
    $viewBox.Add_SelectionChanged($applyFilter)

    # --- Knopfleiste ---
    $bar = New-Object Windows.Controls.DockPanel
    $bar.Margin = '0,12,0,0'
    $bar.LastChildFill = $false
    $left = New-Object Windows.Controls.StackPanel
    $left.Orientation = 'Horizontal'
    [Windows.Controls.DockPanel]::SetDock($left, 'Left')
    $right = New-Object Windows.Controls.StackPanel
    $right.Orientation = 'Horizontal'
    [Windows.Controls.DockPanel]::SetDock($right, 'Right')
    $null = $bar.Children.Add($left)
    $null = $bar.Children.Add($right)
    [Windows.Controls.Grid]::SetRow($bar, 3)
    $null = $grid.Children.Add($bar)

    $window.Tag = $null
    $choose = {
        param([string]$action)
        $selected = @($dataGrid.SelectedItems | Where-Object { $_ -isnot [int] })
        if ($action -in 'NewVersion', 'Edit', 'Delete', 'Build', 'Deploy', 'Rebuild', 'Retire', 'RemoveFolder' -and $selected.Count -eq 0) {
            $null = [System.Windows.MessageBox]::Show($window, 'Select one or more rows first.', 'IntuneWin32Helper', 'OK', 'Information')
            return
        }
        $chosenTenant = ''
        if ($tenantBox.SelectedIndex -gt 0) { $chosenTenant = [string]$tenantBox.SelectedItem }
        $window.Tag = [pscustomobject]@{ Action = $action; Selection = $selected; TenantName = $chosenTenant }
        $window.Close()
    }

    $newButton = {
        param([string]$caption, [string]$id, [string]$tip, $panel)
        $button = New-Object Windows.Controls.Button
        $button.Content = $caption
        $button.Padding = '14,6'
        $button.Margin = '0,0,8,0'
        $button.ToolTip = $tip
        [Windows.Automation.AutomationProperties]::SetAutomationId($button, $id)
        $null = $panel.Children.Add($button)
        return $button
    }

    $settingsButton = New-Object Windows.Controls.Button
    $settingsButton.ToolTip = 'Settings'
    $settingsButton.Padding = '10,4'
    $settingsButton.Margin = '0,0,8,0'
    $settingsButton.MinWidth = 40
    [Windows.Automation.AutomationProperties]::SetAutomationId($settingsButton, 'Settings')
    $settingsIcon = New-Object Windows.Controls.TextBlock
    $settingsIcon.Text = [char]0xE713
    $settingsIcon.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe MDL2 Assets'
    $settingsIcon.FontSize = 16
    $settingsIcon.Foreground = [System.Windows.Media.Brushes]::Gray
    $settingsButton.Content = $settingsIcon
    $null = $left.Children.Add($settingsButton)

    $folderButton  = & $newButton 'Open folder'      'OpenFolder' 'The package folder of the selected row, or the package root' $left
    $orphanButton  = & $newButton 'Remove orphan folder' 'RemoveFolder' 'Delete the package folder of selected rows that have no definition in Apps.csv - the app in Intune stays' $left

    $retireButton = & $newButton 'Retire from Intune' 'Retire' 'Delete the app of the selected row in Intune (name AND version) - with its assignments. The definition and the package folder stay' $left

    $addButton     = & $newButton 'Add...'            'Add'        'Add an application definition (the editor offers WinGet and MSI to prefill)' $right
    $versionButton = & $newButton 'New version...'    'NewVersion' 'Copy the selected definition as a new version' $right
    $editButton    = & $newButton 'Edit'              'Edit'       'Edit the definition of the selected row' $right
    $deleteButton  = & $newButton 'Delete definition' 'Delete'     'Remove the row from Apps.csv - the package folder and the app in Intune stay' $right
    $buildButton   = & $newButton 'Build package'     'Build'      'Create the package on disk from the definition' $right
    $rebuildButton = & $newButton 'Rebuild' 'Rebuild' 'Build the package again, then replace the app in Intune: delete it (with its assignments) and create it new. Intune is touched only after the build worked' $right
    $deployButton  = & $newButton 'Deploy'            'Deploy'     'Upload to the tenant - a row without a package is built first' $right
    $closeButton   = & $newButton 'Close'             'Cancel'     'Close the tool' $right
    $closeButton.Margin = '0'
    $closeButton.IsCancel = $true

    $settingsButton.Add_Click({
        try {
            $null = Edit-SettingsDialog -Owner $window -PreferredPaths @($ConfigPath)
        }
        catch {
            $null = [System.Windows.MessageBox]::Show($window, ("Error while opening the settings: {0}" -f $_.Exception.Message), 'Settings', 'OK', 'Error')
        }
        # Tenants und Paketordner koennen sich geaendert haben: neu lesen.
        & $choose 'Refresh'
    })
    $folderButton.Add_Click({  & $choose 'OpenFolder' })
    $orphanButton.Add_Click({  & $choose 'RemoveFolder' })
    $addButton.Add_Click({     & $choose 'Add' })
    $versionButton.Add_Click({ & $choose 'NewVersion' })
    $editButton.Add_Click({    & $choose 'Edit' })
    $deleteButton.Add_Click({  & $choose 'Delete' })
    $buildButton.Add_Click({   & $choose 'Build' })
    $deployButton.Add_Click({  & $choose 'Deploy' })
    $rebuildButton.Add_Click({ & $choose 'Rebuild' })
    $retireButton.Add_Click({  & $choose 'Retire' })
    $refreshButton.Add_Click({ & $choose 'Refresh' })
    $closeButton.Add_Click({   & $choose 'Cancel' })
    $dataGrid.Add_MouseDoubleClick({
        $row = $dataGrid.SelectedItem
        if ($row -and $row.HasDefinition) { & $choose 'Edit' }
    })

    # Der Tenant-Wechsel wird erst NACH dem Setzen des Anfangswerts gemeldet.
    $tenantBox.Add_SelectionChanged({
        if ($tenantBox.SelectedIndex -ne $initialTenantIndex) { & $choose 'SwitchTenant' }
    })

    # Was moeglich ist, folgt aus dem, was markiert ist.
    $syncButtons = {
        $selected = @($dataGrid.SelectedItems | Where-Object { $_ -isnot [int] })
        $one = ($selected.Count -eq 1)
        $withDefinition = @($selected | Where-Object { $_.HasDefinition })
        $editButton.IsEnabled    = $one -and ($withDefinition.Count -eq 1)
        $versionButton.IsEnabled = $one -and ($withDefinition.Count -eq 1)
        $deleteButton.IsEnabled  = ($withDefinition.Count -gt 0)
        $buildButton.IsEnabled   = ($withDefinition.Count -gt 0)
        $deployButton.IsEnabled  = (@($selected | Where-Object { $_.HasDefinition -or $_.HasPackage }).Count -gt 0)
        # Retire loescht in Intune, was zu Name UND Version der Zeile gehoert - ohne eine solche App gibt es nichts zu tun.
        # Fremde Apps (nur in Intune, nicht von diesem Werkzeug) werden von hier nie geloescht.
        $retireButton.IsEnabled  = (@($selected | Where-Object { ($_.Intune -like 'yes*' -or $_.Intune -eq 'no content') -and $_.Origin -ne 'foreign' }).Count -gt 0)
        # Rebuild baut aus der Definition.
        $rebuildButton.IsEnabled = ($withDefinition.Count -gt 0)
        # Nur ein Ordner ohne Definition ist verwaist - alles andere loescht dieser Weg nie.
        $orphanButton.IsEnabled  = (@($selected | Where-Object { $_.HasPackage -and -not $_.HasDefinition }).Count -gt 0)
    }
    & $syncButtons
    $dataGrid.Add_SelectionChanged($syncButtons)

    $window.Content = $grid
    $window.Add_Closing({
        if ($null -eq $window.Tag) { $window.Tag = [pscustomobject]@{ Action = 'Closed'; Selection = @(); TenantName = '' } }
    })

    # Auswahl wiederherstellen, sobald das Grid seine Zeilen hat. Eine Zeile, die
    # die Ansicht ausblendet oder die es nicht mehr gibt, fehlt einfach.
    if ($Select.Count -gt 0) {
        $window.Add_Loaded({
            try {
                $wanted = @($dataGrid.ItemsSource | Where-Object { $Select -contains $_.Key })
                if ($wanted.Count -eq 0) { return }
                $dataGrid.SelectedItems.Clear()
                foreach ($row in $wanted) { $null = $dataGrid.SelectedItems.Add($row) }
                $dataGrid.ScrollIntoView($wanted[0])
                $null = $dataGrid.Focus()
            }
            catch { }   # eine Auswahl, die sich nicht herstellen laesst, ist keine Meldung wert
        })
    }

    $null = $window.ShowDialog()
    return $window.Tag
}

function Start-InventoryLoop {
    <#
        .SYNOPSIS
        Das Tool: Inventar zeigen, Aktion abarbeiten, Inventar neu zeigen.

        .DESCRIPTION
        Ersetzt die Startkacheln samt createApps und deployApps. Der Tenant wird
        einmal am Anfang gewaehlt (bei genau einem konfigurierten gar nicht
        gefragt) und laesst sich im Fenster wechseln. Ohne Tenant laeuft das Tool
        weiter, die Intune-Spalte bleibt dann leer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RootDir,
        [Parameter(Mandatory = $true)][string]$ToolVersion
    )

    $config  = Get-ToolConfig -RootDir $RootDir
    $tenants = @($config.tenants | Where-Object { $_ })
    $tenant  = $null
    $intuneApps   = $null
    $reloadIntune = $false

    if ($tenants.Count -gt 0) {
        $only = $null
        if ($tenants.Count -eq 1) { $only = $tenants[0] }
        $tenant = Connect-InventoryTenant -Tenants $tenants -Tenant $only
        $reloadIntune = ($null -ne $tenant)
    }
    else {
        Write-Host "No tenant configured - the Intune column stays empty. Add one under Settings (gear icon)." -ForegroundColor Yellow
    }

    $select = @()
    while ($true) {
        # Jede Runde neu lesen: Einstellungen koennen sich geaendert haben.
        $config     = Get-ToolConfig -RootDir $RootDir
        $tenants    = @($config.tenants | Where-Object { $_ })
        $packetRoot = [string]$config.packetRoot
        if ($packetRoot -and -not (Test-Path -LiteralPath $packetRoot)) { $null = New-Item -ItemType Directory -Path $packetRoot -Force }

        if ($reloadIntune) {
            $intuneApps = $null
            if ($tenant) { $intuneApps = Read-TenantWin32Apps }
            $reloadIntune = $false
        }

        $definitions = @(Read-AppsCsv -RootDir $RootDir)
        $columns     = @(Get-AppsCsvColumns -Definitions $definitions)
        $inventory   = @(Get-AppInventory -Definitions $definitions -PacketRoot $packetRoot -RootDir $RootDir -IntuneApps $intuneApps)

        $result = Show-InventoryDialog -Inventory $inventory `
            -Title ("IntuneWin32Helper {0} - https://blog.zarenko.net/" -f $ToolVersion) `
            -PacketRoot $packetRoot `
            -TenantNames @($tenants | ForEach-Object { [string]$_.name }) `
            -TenantName $(if ($tenant) { [string]$tenant.name } else { '' }) `
            -IntuneRead ($null -ne $intuneApps) `
            -ConfigPath (Get-ToolConfigPath -RootDir $RootDir) `
            -Select $select

        $selection = @($result.Selection)
        $select    = @($selection | ForEach-Object { [string]$_.Key })
        $removeExisting = ($config.removeExistingPacketDirOnEachRun -eq $true)

        try {
            switch ($result.Action) {
                'Refresh' { $reloadIntune = $true }

                'SwitchTenant' {
                    if ([string]::IsNullOrEmpty($result.TenantName)) {
                        $tenant = $null
                        $intuneApps = $null
                    }
                    else {
                        $target = $tenants | Where-Object { [string]$_.name -eq $result.TenantName } | Select-Object -First 1
                        $tenant = Connect-InventoryTenant -Tenants $tenants -Tenant $target -Force
                        $reloadIntune = ($null -ne $tenant)
                        if (-not $tenant) { $intuneApps = $null }
                    }
                }

                'Add' {
                    $new = Edit-AppRecord -Record $null -Title 'Add application' -ColumnOrder $columns -Others $definitions
                    if ($new) {
                        $problem = Test-AppRecord -Record $new -Others $definitions
                        if ($problem) {
                            $null = [System.Windows.MessageBox]::Show($problem, 'Add application', 'OK', 'Warning')
                        }
                        else {
                            Save-AppsCsv -RootDir $RootDir -Rows (@($definitions) + $new)
                            $select = @('{0} - {1}' -f $new.DisplayName, $new.Version)
                        }
                    }
                }

                'NewVersion' {
                    $row = $selection | Select-Object -First 1
                    if ($row -and $row.DefinitionRecord) {
                        $copy = $row.DefinitionRecord | Select-Object *
                        $new = Edit-AppRecord -Record $copy -Title ("New version of {0}" -f $row.AppName) -ColumnOrder $columns -Info (Get-InventoryRowInfo -Row $row) -Others $definitions
                        if ($new) {
                            $problem = Test-AppRecord -Record $new -Others $definitions
                            if ($problem) {
                                $null = [System.Windows.MessageBox]::Show($problem, 'New version', 'OK', 'Warning')
                            }
                            else {
                                Save-AppsCsv -RootDir $RootDir -Rows (@($definitions) + $new)
                                $select = @('{0} - {1}' -f $new.DisplayName, $new.Version)
                            }
                        }
                    }
                }

                'Edit' {
                    $row = $selection | Select-Object -First 1
                    if ($row -and $row.DefinitionRecord) {
                        $record = $row.DefinitionRecord
                        $others = @($definitions | Where-Object { -not [object]::ReferenceEquals($_, $record) })
                        $edited = Edit-AppRecord -Record $record -Title ("Edit - {0}" -f $row.Key) -ColumnOrder $columns -Info (Get-InventoryRowInfo -Row $row) -Others $others
                        if ($edited) {
                            $problem = Test-AppRecord -Record $edited -Others $others
                            if ($problem) {
                                $null = [System.Windows.MessageBox]::Show($problem, 'Edit', 'OK', 'Warning')
                            }
                            else {
                                Save-AppsCsv -RootDir $RootDir -Rows (@($others) + $edited)
                                $select = @('{0} - {1}' -f $edited.DisplayName, $edited.Version)
                                if ($row.HasPackage -and $select[0] -ne $row.Key) {
                                    Write-Host ("Renamed {0} -> {1}: the existing package folder keeps its old name until it is built again." -f $row.Key, $select[0]) -ForegroundColor Yellow
                                }
                            }
                        }
                    }
                }

                'Delete' {
                    $victims = @($selection | Where-Object { $_.HasDefinition })
                    if ($victims.Count -gt 0) {
                        $names = ($victims | ForEach-Object { $_.Key }) -join "`n"
                        $answer = [System.Windows.MessageBox]::Show(
                            ("Remove {0} definition(s) from Apps.csv?`n`n{1}`n`nThe package folders and the apps in Intune stay." -f $victims.Count, $names),
                            'Delete definition', 'YesNo', 'Warning')
                        if ($answer -eq 'Yes') {
                            $remove = @($victims | ForEach-Object { $_.DefinitionRecord })
                            Save-AppsCsv -RootDir $RootDir -Rows @($definitions | Where-Object { $remove -notcontains $_ })
                            $select = @()
                        }
                    }
                }

                'Build' {
                    $targets = @($selection | Where-Object { $_.HasDefinition })
                    $existing = @($targets | Where-Object { $_.HasPackage })
                    $go = $true
                    if ($existing.Count -gt 0) {
                        $answer = [System.Windows.MessageBox]::Show(
                            ("{0} of the selected rows already have a package. Building creates it again from the definition; changes made by hand inside the package are lost.`n`nContinue?" -f $existing.Count),
                            'Build package', 'YesNo', 'Warning')
                        $go = ($answer -eq 'Yes')
                    }
                    if ($go -and $targets.Count -gt 0) {
                        $null = Invoke-PackageBuild -Rows $targets -PacketRoot $packetRoot -RootDir $RootDir -ToolVersion $ToolVersion -RemoveExisting $removeExisting
                    }
                }

                'Deploy' {
                    # Zuerst der Tenant: scheitert das, soll nicht vorher gebaut werden. Auch mit
                    # bekanntem Tenant: ein abgelaufener Token wuerde das frische Lesen vereiteln.
                    $tenant = Connect-InventoryTenant -Tenants $tenants -Tenant $tenant
                    $reloadIntune = ($null -ne $tenant)
                    if (-not $tenant) {
                        Write-Host "No tenant - nothing was deployed." -ForegroundColor Yellow
                    }
                    else {
                        # Lesen, planen, fragen, bauen, verteilen: ein Pfad in Invoke-InventoryDeploy.
                        $null = Invoke-InventoryDeploy -Selection $selection -Tenant $tenant -RootDir $RootDir -PacketRoot $packetRoot -ToolVersion $ToolVersion -RemoveExisting $removeExisting
                        $reloadIntune = $true
                    }
                }

                'Rebuild' {
                    $tenant = Connect-InventoryTenant -Tenants $tenants -Tenant $tenant
                    $reloadIntune = ($null -ne $tenant)
                    if (-not $tenant) {
                        Write-Host "No tenant - nothing was rebuilt." -ForegroundColor Yellow
                    }
                    else {
                        $null = Invoke-InventoryRebuild -Selection $selection -Tenant $tenant -RootDir $RootDir -PacketRoot $packetRoot -ToolVersion $ToolVersion
                        $reloadIntune = $true
                    }
                }

                'Retire' {
                    $tenant = Connect-InventoryTenant -Tenants $tenants -Tenant $tenant
                    $reloadIntune = ($null -ne $tenant)
                    if (-not $tenant) {
                        Write-Host "No tenant - nothing was retired." -ForegroundColor Yellow
                    }
                    else {
                        $null = Invoke-InventoryRetire -Selection $selection -RootDir $RootDir -PacketRoot $packetRoot
                        $reloadIntune = $true
                    }
                }

                'OpenFolder' {
                    $path = $packetRoot
                    $row = $selection | Where-Object { $_.FullPath } | Select-Object -First 1
                    if ($row) { $path = Split-Path -Parent $row.FullPath }
                    if ($path -and (Test-Path -LiteralPath $path)) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $path) }
                }

                'RemoveFolder' {
                    # Nur Ordner ohne Definition. Die Auswahl der Zeilen entscheidet der Knopf, die
                    # Verweigerung liegt in Remove-OrphanPackages: ein Ordner MIT Definition wird dort
                    # auch dann nicht angefasst, wenn er hier durchrutschte.
                    $orphans = @($selection | Where-Object { $_.HasPackage -and -not $_.HasDefinition })
                    if ($orphans.Count -eq 0) {
                        $null = [System.Windows.MessageBox]::Show('None of the selected rows is an orphan: only a package folder without a row in Apps.csv can be removed here.', 'Remove orphan folder', 'OK', 'Information')
                    }
                    else {
                        $lines = foreach ($orphan in $orphans) {
                            $folder  = Split-Path -Parent ([string]$orphan.FullPath)
                            $summary = Get-PackageFolderSummary -Path $folder
                            $stays   = $(if ($orphan.Intune -like 'yes*' -or $orphan.Intune -eq 'no content') { '  (the app stays in Intune)' } else { '' })
                            ("{0}`n    {1}  -  {2} file(s), {3:N1} MB{4}" -f $orphan.Key, $folder, $summary.Files, ($summary.Bytes / 1MB), $stays)
                        }
                        $answer = [System.Windows.MessageBox]::Show(
                            ("Delete {0} package folder(s) that have no definition in Apps.csv?`n`n{1}`n`nThis cannot be undone. The apps in Intune are not touched." -f $orphans.Count, ($lines -join "`n`n")),
                            'Remove orphan folder', 'YesNo', 'Warning', 'No')
                        if ($answer -eq 'Yes') {
                            $outcome = Remove-OrphanPackages -Rows $orphans -PacketRoot $packetRoot
                            Write-Host ("Orphan folders: {0} removed, {1} skipped, {2} failed." -f $outcome.Removed.Count, $outcome.Skipped.Count, $outcome.Failed.Count) -ForegroundColor Cyan
                            foreach ($name in $outcome.Removed) { Write-Host ("  REMOVED  {0}" -f $name) -ForegroundColor Green }
                            foreach ($name in $outcome.Skipped) { Write-Host ("  SKIPPED  {0}" -f $name) -ForegroundColor Yellow }
                            foreach ($name in $outcome.Failed)  { Write-Host ("  FAILED   {0}" -f $name) -ForegroundColor Red }
                            $select = @()
                        }
                    }
                }

                'Cancel' { return }
                'Closed' { return }
                default {
                    Write-Host ("Unexpected action: {0}" -f $result.Action) -ForegroundColor Yellow
                    return
                }
            }
        }
        catch {
            # Eine gescheiterte Aktion beendet das Tool nicht.
            Write-Host ("Action [{0}] failed: {1}" -f $result.Action, $_.Exception.Message) -ForegroundColor Red
            $null = [System.Windows.MessageBox]::Show(("Action [{0}] failed:`n`n{1}" -f $result.Action, $_.Exception.Message), 'IntuneWin32Helper', 'OK', 'Error')
        }
    }
}

function Get-RequirementRuleChoices {
    <#
        Zulaessige Werte fuer Architecture und MinimumOS - aus dem Modul gelesen,
        nicht aus einer Kopie: sie gehen in New-IntuneWin32AppRequirementRule, und
        ein Wert, den das Modul nicht kennt, scheitert erst beim Upload. Der Parameter
        heisst im Modul MinimumSupportedWindowsRelease (MinimumSupportedOperatingSystem
        ist sein Alias). Die Rueckfallliste gilt nur, wenn das Modul nicht lesbar ist.
    #>
    [CmdletBinding()]
    param()

    $architecture = @('x64', 'x86', 'arm64', 'x64x86', 'AllWithARM64')
    $minimumOs    = @('W10_1607', 'W10_1703', 'W10_1709', 'W10_1803', 'W10_1809', 'W10_1903', 'W10_1909', 'W10_2004',
                      'W10_20H2', 'W10_21H1', 'W10_21H2', 'W10_22H2', 'W11_21H2', 'W11_22H2')
    try {
        $command = Get-Command -Name New-IntuneWin32AppRequirementRule -ErrorAction Stop
        $set = @($command.Parameters['Architecture'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })
        if ($set.Count -gt 0) { $architecture = @($set[0].ValidValues) }
        $set = @($command.Parameters['MinimumSupportedWindowsRelease'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })
        if ($set.Count -gt 0) { $minimumOs = @($set[0].ValidValues) }
    }
    catch { }
    return [pscustomobject]@{ Architecture = $architecture; MinimumOS = $minimumOs }
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

function Get-PackageFolderSummary {
    <# Dateien und Groesse eines Ordners - fuer die Rueckfrage vor dem Loeschen. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
    $bytes = 0
    foreach ($file in $files) { $bytes += $file.Length }
    return [pscustomobject]@{ Files = $files.Count; Bytes = [long]$bytes }
}

function Remove-OrphanPackages {
    <#
        .SYNOPSIS
        Loescht Paketordner, zu denen es keine Definition in Apps.csv gibt.

        .DESCRIPTION
        Der einzige Weg dafuer. Er verweigert, was nicht eindeutig verwaist ist - der
        Schutz liegt hier und nicht im Knopf, denn ein Fehler beim Aktivieren des
        Knopfes darf keinen Ordner treffen, der eine Definition hat:
          - eine Zeile MIT Definition wird uebersprungen,
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
        if ($row.HasDefinition)                              { $skipped += ("{0}: has a definition in Apps.csv" -f $key); continue }
        if (-not $row.HasPackage -or -not $row.FullPath)     { $skipped += ("{0}: no package folder" -f $key); continue }

        $folder = Split-Path -Parent ([string]$row.FullPath)
        if ((Split-Path -Leaf $folder) -ne $key)             { $skipped += ("{0}: folder name '{1}' is not '<Name> - <Version>' - not made by this tool" -f $key, (Split-Path -Leaf $folder)); continue }
        if (-not (Test-Path -LiteralPath (Join-Path $folder 'deploy.ps1'))) { $skipped += ("{0}: no deploy.ps1 in the folder" -f $key); continue }

        try {
            if (Remove-PackageFolder -Path $folder -PacketRoot $PacketRoot) { $removed += $key }
            else { $skipped += ("{0}: folder already gone" -f $key) }
        }
        catch { $failed += ("{0}: {1}" -f $key, $_.Exception.Message) }
    }
    return [pscustomobject]@{ Removed = @($removed); Skipped = @($skipped); Failed = @($failed) }
}

function Open-EditDialog {
    <#
        .SYNOPSIS
        Bearbeitungsdialog fuer eine Definition aus Apps.csv.

        .DESCRIPTION
        Gibt die Werte als geordnetes Dictionary zurueck, bei Abbruch nichts.
        Aufbau wie im SCCMAppHelper: oben die Fakten zur Zeile (nur lesen), darunter
        die Felder in Gruppen, Beschriftung links und Feld rechts. Jedes Feld hat das
        passende Steuerelement (Auswahlliste, Haken, mehrzeilig) und, wo es etwas zu
        erklaeren gibt, einen Hinweis darunter. Jedes Steuerelement traegt als
        AutomationId den Spaltennamen, damit der Dialog maschinell testbar ist.
        OK prueft Name und Version, auch auf Doppelte (-Others), und bleibt bei einem
        Fehler offen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$item,
        [string]$title,
        [string[]]$PropertyOrder,
        # Nur lesende Fakten oberhalb der Felder (Paket, Vorlage, Intune, naechster Schritt)
        [System.Collections.IDictionary]$Info,
        # Die uebrigen Definitionen: Name + Version muessen eindeutig bleiben
        $Others = @()
    )

    Add-Type -AssemblyName PresentationCore      -ErrorAction SilentlyContinue | Out-Null
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue | Out-Null

    $keys = if ($PropertyOrder) { @($PropertyOrder) } else { @($item.Keys) }
    $choices = Get-RequirementRuleChoices

    # Gruppen und Reihenfolge; unbekannte (eigene) Spalten landen unter "Other".
    $groups = [ordered]@{
        'Application'  = @('DisplayName', 'Publisher', 'Version')
        'Source'       = @('ProgramID', 'WinGetParams', 'SingleMSI', 'MsiProductCode', 'logoURL')
        'Installation' = @('InstallCmd', 'UninstallCmd', 'Interactive')
        'Intune'       = @('Architecture', 'MinimumOS', 'ArpName')
    }
    $known = @($groups.Values | ForEach-Object { $_ })
    $other = @($keys | Where-Object { $known -notcontains $_ })
    if ($other.Count -gt 0) { $groups['Other'] = $other }

    $comboValues = @{ Architecture = $choices.Architecture; MinimumOS = $choices.MinimumOS }
    $checkText = @{
        SingleMSI   = 'Zero-config MSI: the PSADT script is not customised (a package that only holds one MSI)'
        Interactive = 'Show PSADT dialogs through ServiceUI'
    }
    $multiline = @('InstallCmd', 'UninstallCmd')
    $hints = @{
        Version        = 'LatestAvailable makes this a WinGet app: a thin wrapper that installs through winget on the device.'
        ProgramID      = 'WinGet package id. Used only when Version is LatestAvailable.'
        WinGetParams   = 'Extra winget arguments, e.g. "--scope=machine". Used only when Version is LatestAvailable.'
        MsiProductCode = 'Detection by the MSI product code - native in Intune, version included. Empty: detection.ps1 is used.'
        logoURL        = 'Empty: Logos\<DisplayName>.png if it exists, otherwise the default logo. Nothing is uploaded anywhere.'
        InstallCmd     = 'PSADT code for the install section. Empty: derived from the installer in Files\ when the package is built.'
        UninstallCmd   = 'PSADT code for the uninstall section. Empty: derived like the install command.'
        Interactive    = 'Runs the setup AS SYSTEM IN THE USER SESSION. A setup that starts its app when it is done leaves it running as SYSTEM on the desktop. Leave off unless the package must show dialogs.'
        Architecture   = 'Empty means x64.'
        MinimumOS      = 'Empty means W10_20H2.'
    }

    $window = New-Object Windows.Window
    $window.Title = $title
    $window.Width = 780
    $window.MinWidth = 640
    $window.SizeToContent = 'Height'
    $window.MaxHeight = [Math]::Max(480, [System.Windows.SystemParameters]::WorkArea.Height - 40)
    $window.WindowStartupLocation = 'CenterScreen'
    [Windows.Automation.AutomationProperties]::SetAutomationId($window, 'EditDialog')

    $dock = New-Object Windows.Controls.DockPanel

    # --- unten: Fehler und Knoepfe (ausserhalb des Scrollbereichs, immer sichtbar) ---
    $bottom = New-Object Windows.Controls.StackPanel
    $bottom.Margin = '12,0,12,12'
    [Windows.Controls.DockPanel]::SetDock($bottom, 'Bottom')

    $errorText = New-Object Windows.Controls.TextBlock
    $errorText.Foreground = [System.Windows.Media.Brushes]::Firebrick
    $errorText.TextWrapping = 'Wrap'
    $errorText.Margin = '0,6,0,6'
    [Windows.Automation.AutomationProperties]::SetAutomationId($errorText, 'Error')
    $null = $bottom.Children.Add($errorText)

    $buttonBar = New-Object Windows.Controls.DockPanel
    $null = $bottom.Children.Add($buttonBar)

    $newButton = {
        param([string]$caption, [string]$id, [string]$tip, [string]$dock)
        $button = New-Object Windows.Controls.Button
        $button.Content = $caption
        $button.Padding = '14,5'
        $button.Margin = '0,0,8,0'
        $button.ToolTip = $tip
        [Windows.Automation.AutomationProperties]::SetAutomationId($button, $id)
        [Windows.Controls.DockPanel]::SetDock($button, $dock)
        $null = $buttonBar.Children.Add($button)
        return $button
    }
    $okButton     = & $newButton 'OK'       'OK'        'Save the definition' 'Right'
    $cancelButton = & $newButton 'Cancel'   'Cancel'    'Discard the changes' 'Right'
    $wingetButton = & $newButton 'From WinGet...' 'FromWinGet' 'Search WinGet and fill in name, publisher, id and version' 'Left'
    $msiButton    = & $newButton 'From MSI...'    'FromMsi'    'Read name, version, publisher and product code from an MSI file' 'Left'
    $okButton.IsDefault = $true
    $cancelButton.IsCancel = $true
    $okButton.Margin = '8,0,0,0'
    $cancelButton.Margin = '0'
    $null = $dock.Children.Add($bottom)

    # --- Mitte: scrollbar ---
    $scroll = New-Object Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $scroll.HorizontalScrollBarVisibility = 'Disabled'
    $null = $dock.Children.Add($scroll)

    $stack = New-Object Windows.Controls.StackPanel
    $stack.Margin = '12'
    $scroll.Content = $stack

    # Fakten zur Zeile
    if ($Info -and $Info.Count -gt 0) {
        $infoBorder = New-Object Windows.Controls.Border
        $infoBorder.Background = [System.Windows.Media.Brushes]::WhiteSmoke
        $infoBorder.BorderBrush = [System.Windows.Media.Brushes]::LightGray
        $infoBorder.BorderThickness = '1'
        $infoBorder.CornerRadius = '4'
        $infoBorder.Padding = '10,8'
        $infoBorder.Margin = '0,0,0,10'
        [Windows.Automation.AutomationProperties]::SetAutomationId($infoBorder, 'Info')

        $infoGrid = New-Object Windows.Controls.Grid
        $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = New-Object Windows.GridLength -ArgumentList 100
        $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = New-Object Windows.GridLength -ArgumentList 1, ([Windows.GridUnitType]::Star)
        $null = $infoGrid.ColumnDefinitions.Add($c1)
        $null = $infoGrid.ColumnDefinitions.Add($c2)
        $infoRow = 0
        foreach ($infoKey in $Info.Keys) {
            $rd = New-Object Windows.Controls.RowDefinition; $rd.Height = [Windows.GridLength]::Auto
            $null = $infoGrid.RowDefinitions.Add($rd)
            $infoLabel = New-Object Windows.Controls.TextBlock
            $infoLabel.Text = $infoKey
            $infoLabel.Foreground = [System.Windows.Media.Brushes]::DimGray
            $infoLabel.Margin = '0,1,8,1'
            [Windows.Controls.Grid]::SetRow($infoLabel, $infoRow)
            $null = $infoGrid.Children.Add($infoLabel)
            $infoValue = New-Object Windows.Controls.TextBox
            $infoValue.Text = [string]$Info[$infoKey]
            $infoValue.IsReadOnly = $true
            $infoValue.BorderThickness = '0'
            $infoValue.Background = [System.Windows.Media.Brushes]::Transparent
            $infoValue.TextWrapping = 'Wrap'
            $infoValue.Margin = '0,1,0,1'
            [Windows.Automation.AutomationProperties]::SetAutomationId($infoValue, 'Info' + ($infoKey -replace '\W', ''))
            [Windows.Controls.Grid]::SetRow($infoValue, $infoRow)
            [Windows.Controls.Grid]::SetColumn($infoValue, 1)
            $null = $infoGrid.Children.Add($infoValue)
            $infoRow++
        }
        $infoBorder.Child = $infoGrid
        $null = $stack.Children.Add($infoBorder)
    }

    # Felder: eine Gruppe = ein Kopf plus ein Grid mit Beschriftung links, Feld rechts
    $controls = [ordered]@{}
    $hintBlocks = @{}
    foreach ($groupName in $groups.Keys) {
        $groupKeys = @($groups[$groupName] | Where-Object { $keys -contains $_ })
        if ($groupKeys.Count -eq 0) { continue }

        $header = New-Object Windows.Controls.TextBlock
        $header.Text = $groupName
        $header.FontWeight = [Windows.FontWeights]::SemiBold
        $header.FontSize = 14
        $header.Margin = '0,8,0,4'
        $null = $stack.Children.Add($header)

        $fieldGrid = New-Object Windows.Controls.Grid
        $lc = New-Object Windows.Controls.ColumnDefinition; $lc.Width = New-Object Windows.GridLength -ArgumentList 150
        $vc = New-Object Windows.Controls.ColumnDefinition; $vc.Width = New-Object Windows.GridLength -ArgumentList 1, ([Windows.GridUnitType]::Star)
        $null = $fieldGrid.ColumnDefinitions.Add($lc)
        $null = $fieldGrid.ColumnDefinitions.Add($vc)
        $rowIndex = 0

        foreach ($key in $groupKeys) {
            $rd = New-Object Windows.Controls.RowDefinition; $rd.Height = [Windows.GridLength]::Auto
            $null = $fieldGrid.RowDefinitions.Add($rd)

            $value = [string]$item[$key]
            $isMulti = ($multiline -contains $key) -or ($value -match "`n")
            $isCheck = $checkText.ContainsKey($key)
            $isCombo = $comboValues.ContainsKey($key)

            $label = New-Object Windows.Controls.Label
            $label.Content = $key
            $label.Margin = '0,0,8,4'
            $label.VerticalAlignment = $(if ($isMulti) { 'Top' } else { 'Center' })
            [Windows.Controls.Grid]::SetRow($label, $rowIndex)
            $null = $fieldGrid.Children.Add($label)

            if ($isCheck) {
                $control = New-Object Windows.Controls.CheckBox
                $control.Content = $checkText[$key]
                $control.IsChecked = ($value.Trim() -ne '' -and $value -notmatch '^\s*(?i)(false|0|no|nein)\s*$')
                $control.VerticalAlignment = 'Center'
                $control.Margin = '0,5,0,4'
            }
            elseif ($isCombo) {
                $control = New-Object Windows.Controls.ComboBox
                $control.IsEditable = $true            # ein unbekannter Wert in einer alten Zeile ueberlebt das Ansehen
                $control.ItemsSource = @($comboValues[$key])
                $control.Text = $value
                $control.Height = 26
                $control.Margin = '0,0,0,4'
            }
            else {
                $control = New-Object Windows.Controls.TextBox
                $control.Text = $value
                $control.TextWrapping = 'Wrap'
                $control.VerticalContentAlignment = 'Center'
                $control.Margin = '0,0,0,4'
                if ($isMulti) { $control.AcceptsReturn = $true; $control.Height = 78; $control.VerticalScrollBarVisibility = 'Auto'; $control.VerticalContentAlignment = 'Top' }
                else { $control.Height = 26 }
            }
            [Windows.Automation.AutomationProperties]::SetAutomationId($control, $key)
            [Windows.Automation.AutomationProperties]::SetName($control, $key)
            [Windows.Controls.Grid]::SetRow($control, $rowIndex)
            [Windows.Controls.Grid]::SetColumn($control, 1)
            $null = $fieldGrid.Children.Add($control)
            $controls[$key] = $control
            $rowIndex++

            # Hinweis unter dem Feld (bei ArpName ein lebender Text, siehe unten)
            if ($hints.ContainsKey($key) -or $key -eq 'ArpName') {
                $rd2 = New-Object Windows.Controls.RowDefinition; $rd2.Height = [Windows.GridLength]::Auto
                $null = $fieldGrid.RowDefinitions.Add($rd2)
                $hint = New-Object Windows.Controls.TextBlock
                $hint.Foreground = [System.Windows.Media.Brushes]::DimGray
                $hint.TextWrapping = 'Wrap'
                $hint.Margin = '2,0,0,8'
                if ($hints.ContainsKey($key)) { $hint.Text = $hints[$key] }
                [Windows.Automation.AutomationProperties]::SetAutomationId($hint, $key + 'Hint')
                [Windows.Controls.Grid]::SetRow($hint, $rowIndex)
                [Windows.Controls.Grid]::SetColumn($hint, 1)
                $null = $fieldGrid.Children.Add($hint)
                $hintBlocks[$key] = $hint
                $rowIndex++
            }
        }
        $null = $stack.Children.Add($fieldGrid)
    }

    $getValue = {
        param([string]$key)
        $c = $controls[$key]
        if ($c -is [Windows.Controls.CheckBox]) { if ($c.IsChecked) { return 'true' } else { return '' } }
        return [string]$c.Text
    }
    $setValue = {
        param([string]$key, [string]$value)
        if ([string]::IsNullOrWhiteSpace($value)) { return }
        if (-not $controls.Contains($key)) { return }
        $c = $controls[$key]
        if ($c -is [Windows.Controls.CheckBox]) { $c.IsChecked = ($value -notmatch '^\s*(?i)(false|0|no|nein)\s*$') }
        else { $c.Text = $value }
    }

    # WinGet-Felder gelten nur bei Version = LatestAvailable.
    $syncWinGet = {
        if (-not $controls.Contains('Version')) { return }
        $isWinGet = (([string]$controls['Version'].Text).Trim() -eq 'LatestAvailable')
        foreach ($k in 'ProgramID', 'WinGetParams') { if ($controls.Contains($k)) { $controls[$k].IsEnabled = $isWinGet } }
    }
    if ($controls.Contains('Version')) { $controls['Version'].Add_TextChanged($syncWinGet) }
    & $syncWinGet

    # Der Suchname der Programmliste - wie ihn Erkennung und Deinstallation benutzen.
    $syncArp = {
        if (-not $hintBlocks.ContainsKey('ArpName')) { return }
        $name = ''; $arp = ''
        if ($controls.Contains('DisplayName')) { $name = [string]$controls['DisplayName'].Text }
        if ($controls.Contains('ArpName'))     { $arp  = [string]$controls['ArpName'].Text }
        $search = Get-ArpSearchName -DisplayName $name -ArpName $arp
        $hintBlocks['ArpName'].Text = ("Detection and uninstall look for programs whose name STARTS WITH '{0}'. Empty ArpName = DisplayName. Set it when the entry in Apps & features is named differently, or to be more precise - the uninstall removes every match." -f $search)
    }
    foreach ($k in 'DisplayName', 'ArpName') { if ($controls.Contains($k)) { $controls[$k].Add_TextChanged($syncArp) } }
    & $syncArp

    # --- Vorbelegung aus WinGet / MSI (verhalten wie bisher) ---
    $wingetButton.Add_Click({
        try {
            $found = Show-WinGetSearchDialog
            if ($found) {
                & $setValue 'DisplayName' ([string]$found.Name)
                & $setValue 'Version' 'LatestAvailable'
                & $setValue 'Publisher' ([string]$found.Publisher)
                & $setValue 'ProgramID' ([string]$found.Id)
                & $setValue 'InstallCmd' ([string]$found.InstallCmd)
                & $setValue 'WinGetParams' '"--scope=machine"'
            }
        }
        catch { $errorText.Text = ("WinGet search failed: {0}" -f $_.Exception.Message) }
    })
    $msiButton.Add_Click({
        try {
            $dialog = New-Object Microsoft.Win32.OpenFileDialog
            $dialog.Title  = 'Select MSI'
            $dialog.Filter = 'MSI files (*.msi)|*.msi|All files (*.*)|*.*'
            $dialog.Multiselect = $false
            if ($dialog.ShowDialog() -eq $true -and $dialog.FileName) {
                $props = Get-MsiProperties -Path $dialog.FileName
                & $setValue 'DisplayName' ([string]$props.ProductName)
                & $setValue 'Version' ([string]$props.ProductVersion)
                & $setValue 'Publisher' ([string]$props.Manufacturer)
                & $setValue 'MsiProductCode' ([string]$props.ProductCode)
                & $setValue 'SingleMSI' 'true'
            }
        }
        catch { $errorText.Text = ("Reading the MSI failed: {0}" -f $_.Exception.Message) }
    })

    # --- OK: pruefen, bei Fehler offen bleiben ---
    $okButton.Add_Click({
        $values = [ordered]@{}
        foreach ($k in $keys) { $values[$k] = (& $getValue $k) }
        $problem = Test-AppRecord -Record ([pscustomobject]$values) -Others $Others
        if ($problem) {
            $errorText.Text = $problem
            return
        }
        $window.DialogResult = $true
    })

    $window.Content = $dock
    $result = $window.ShowDialog()

    if ($result -eq $true) {
        $newItem = [ordered]@{}
        foreach ($k in $keys) { $newItem[$k] = (& $getValue $k) }
        return $newItem
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

function Show-WinGetSearchDialog {
    # Callback
    $onSearch = {
        param($q)
        if ([string]::IsNullOrWhiteSpace($q)) { return @() }
        $data = Find-WinGetPackage -Query $q -Source "winget"
        return $data #| Select-Object Name, Id, Version, Publisher, Moniker, Source
    }

    # Start mit leerer Liste, Suche über Enter oder Button
    $selectedApp = Open-SelectDialogWithSearch -data @() -title 'WinGet Search' -large -OnSearch $onSearch #-initialQuery 'vscode'
    # Rückgabe bereinigen (bekannter Workaround gegen int-Werte in Collections)
    if ($selectedApp -ne $null) {
        $selectedApp = $selectedApp | Where-Object {$_ -isnot [int]}
        if($selectedApp.Id){$publisher = $selectedApp.Id.split(".")[0]}
        $selectedApp | Add-Member -NotePropertyName Publisher -NotePropertyValue $publisher
    }
    return $selectedApp
}

function Open-SelectDialog {
    param (
        $data,
        [string]$title,
        [switch]$large,
        # Gleiche Bedeutung wie in Open-SelectDialogWithEdit, damit beide Dialoge
        # gleich aufgerufen werden koennen. -large bleibt aus Kompatibilitaet
        # erhalten und entspricht -size large.
        [ValidateSet("small", "medium", "large")]
        [string]$size
    )

    Add-Type -AssemblyName PresentationFramework | Out-Null

    if ($large) { $size = "large" }
    if ([string]::IsNullOrEmpty($size)) { $size = "medium" }

    # Fenster erstellen
    $window = New-Object Windows.Window
    $window.Title = $title
    switch ($size) {
        "small" { $window.Width = 640;  $window.Height = 400 }
        "large" { $window.Width = 1024; $window.Height = 768 }
        default { $window.Width = 800;  $window.Height = 600 }
    }

    # DataGrid erstellen
    $dataGrid = New-Object Windows.Controls.DataGrid
    $dataGrid.CanUserSortColumns = $true
    $dataGrid.SelectionMode = 'Extended'
    $dataGrid.SelectionUnit = 'FullRow'
    $dataGrid.AutoGenerateColumns = $false

    # Spalten manuell erzeugen
    $firstItem = $data | Select-Object -First 1
    foreach ($property in $firstItem.PSObject.Properties.Name) {
        $column = New-Object Windows.Controls.DataGridTextColumn
        $column.Header = $property
        $column.Binding = New-Object Windows.Data.Binding($property)
        $column.CanUserSort = $true
        [void]$dataGrid.Columns.Add($column)
    }

    # ItemsSource setzen
    $dataGrid.ItemsSource = $data

    # OK-Button
    $okButton = New-Object Windows.Controls.Button
    $okButton.Height = 40
    $okButton.Width = 100
    $okButton.Content = "OK"
    $okButton.Margin = "5"
    $okButton.Add_Click({
        $window.DialogResult = $true
    })

    # Cancel-Button
    $cancelButton = New-Object Windows.Controls.Button
    $cancelButton.Height = 40
    $cancelButton.Width = 100
    $cancelButton.Content = "Cancel"
    $cancelButton.Margin = "5"
    $cancelButton.Add_Click({
        $window.DialogResult = $false
    })

    # Button-Panel
    $buttonPanel = New-Object Windows.Controls.StackPanel
    $buttonPanel.Orientation = 'Horizontal'
    $buttonPanel.HorizontalAlignment = 'Right'
    $buttonPanel.Margin = "10"
    [void]$buttonPanel.Children.Add($okButton)
    [void]$buttonPanel.Children.Add($cancelButton)

    # Layout-Grid
    $grid = New-Object Windows.Controls.Grid
    [void]$grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
    [void]$grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
    $grid.RowDefinitions[1].Height = [Windows.GridLength]::Auto

    [void]$grid.Children.Add($dataGrid)
    [Windows.Controls.Grid]::SetRow($dataGrid, 0)
    [void]$grid.Children.Add($buttonPanel)
    [Windows.Controls.Grid]::SetRow($buttonPanel, 1)

    $window.Content = $grid

    # Dialog anzeigen
    $window.WindowStartupLocation = 'CenterScreen'
    $result = $window.ShowDialog()

    if ($result -eq $true) {
        return $dataGrid.SelectedItems
    }
}

function Open-SelectDialogWithSearch {
    param (
        $data,
        [string]$title,
        [switch]$large,
        [ScriptBlock]$OnSearch,
        [string]$initialQuery = '',
        [string]$searchPlaceholder = 'Enter search string and hit "Search"...'
    )

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    # Fenster
    $window = New-Object Windows.Window
    $window.Title = $title
    if ($large) { $window.Width = 1024; $window.Height = 768 } else { $window.Width = 800; $window.Height = 600 }

    # Hauptgrid
    $grid = New-Object Windows.Controls.Grid
    [void]$grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
    $grid.RowDefinitions[0].Height = [Windows.GridLength]::Auto
    [void]$grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
    [void]$grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
    $grid.RowDefinitions[2].Height = [Windows.GridLength]::Auto

    # --- Suchleiste ---
    $searchPanel = New-Object Windows.Controls.StackPanel
    $searchPanel.Orientation = 'Horizontal'
    $searchPanel.Margin = '8'

    $searchBox = New-Object Windows.Controls.TextBox
    $searchBox.Width = 360
    $searchBox.Margin = '0,0,8,0'
    $searchBox.Text = $initialQuery
    $searchBox.ToolTip = $searchPlaceholder

    $searchButton = New-Object Windows.Controls.Button
    $searchButton.Content = 'Search'
    $searchButton.Width = 90
    $searchButton.Margin = '0,0,8,0'

    $spinner = New-Object Windows.Controls.TextBlock
    $spinner.VerticalAlignment = 'Center'
    $spinner.Margin = '8,0,0,0'
    $spinner.Text = ''

    [void]$searchPanel.Children.Add($searchBox)
    [void]$searchPanel.Children.Add($searchButton)
    [void]$searchPanel.Children.Add($spinner)

    # --- DataGrid ---
    $dataGrid = New-Object Windows.Controls.DataGrid
    $dataGrid.CanUserSortColumns = $true
    $dataGrid.SelectionMode = 'Extended'
    $dataGrid.SelectionUnit = 'FullRow'
    $dataGrid.AutoGenerateColumns = $false
    $dataGrid.IsReadOnly = $true

    # PERFORMANCE BOOST
    $dataGrid.EnableRowVirtualization = $true
    $dataGrid.EnableColumnVirtualization = $true
    $dataGrid.SetValue([Windows.Controls.VirtualizingStackPanel]::IsVirtualizingProperty, $true)
    $dataGrid.SetValue(
        [Windows.Controls.VirtualizingStackPanel]::VirtualizationModeProperty,
        [Windows.Controls.VirtualizationMode]::Recycling
    )

    # Spaltenaufbau
    $rebuildColumns = {
        param($sample)
        $dataGrid.Columns.Clear()
        if ($sample) {
            foreach ($property in $sample.PSObject.Properties.Name) {
                $column = New-Object Windows.Controls.DataGridTextColumn
                $column.Header = $property
                $column.Binding = New-Object Windows.Data.Binding($property)
                $column.CanUserSort = $true
                $dataGrid.Columns.Add($column) | Out-Null
            }
        }
    }

    $dataGrid.ItemsSource = $data
    & $rebuildColumns ($data | Select-Object -First 1)

    # --- Buttons ---
    $okButton = New-Object Windows.Controls.Button
    $okButton.Height = 40
    $okButton.Width = 100
    $okButton.Content = "OK"
    $okButton.Margin = "5"
    $okButton.Add_Click({ $window.DialogResult = $true })

    $cancelButton = New-Object Windows.Controls.Button
    $cancelButton.Height = 40
    $cancelButton.Width = 100
    $cancelButton.Content = "Cancel"
    $cancelButton.Margin = "5"
    $cancelButton.Add_Click({ $window.DialogResult = $false })

    $buttonPanel = New-Object Windows.Controls.StackPanel
    $buttonPanel.Orientation = 'Horizontal'
    $buttonPanel.HorizontalAlignment = 'Right'
    $buttonPanel.Margin = "10"
    [void]$buttonPanel.Children.Add($okButton)
    [void]$buttonPanel.Children.Add($cancelButton)

    # Layout
    [void]$grid.Children.Add($searchPanel)
    [Windows.Controls.Grid]::SetRow($searchPanel, 0)
    [void]$grid.Children.Add($dataGrid)
    [Windows.Controls.Grid]::SetRow($dataGrid, 1)
    [void]$grid.Children.Add($buttonPanel)
    [Windows.Controls.Grid]::SetRow($buttonPanel, 2)

    $window.Content = $grid
    $window.WindowStartupLocation = 'CenterScreen'

    # --- Search ---
    $runSearch = {
        if (-not $OnSearch) { return }

        # Busy
        $spinner.Text = 'Searching...'
        $searchButton.IsEnabled = $false
        $searchBox.IsEnabled = $false
        $window.Cursor = [System.Windows.Input.Cursors]::Wait

        # UI sofort aktualisieren
        try { $window.Dispatcher.Invoke([Action]{}, 'Background') } catch { }
        Start-Sleep -Milliseconds 50

        $query = $searchBox.Text
        $newData = @()

        try {
            # *** WICHTIG: Ergebnisse FLACH machen ***
            $raw = & $OnSearch $query
            $newData = foreach ($item in $raw) {
                [pscustomobject]@{
                    Name      = $item.Name
                    Id        = $item.Id
                    Version   = $item.Version
                    #Publisher = $item.Publisher
                    Moniker   = $item.Moniker
                    Source    = $item.Source
                }
            }
        } catch {
            $newData = @()
            [System.Windows.MessageBox]::Show("Error while searching: $($_.Exception.Message)") | Out-Null
        }

        $dataGrid.ItemsSource = $null
        & $rebuildColumns ($newData | Select-Object -First 1)
        $dataGrid.ItemsSource = $newData

        # Ready
        $spinner.Text = ''
        $searchButton.IsEnabled = $true
        $searchBox.IsEnabled = $true
        $window.Cursor = [System.Windows.Input.Cursors]::Arrow

        # Suchfeld wieder aktivieren + Fokus setzen
        $searchBox.IsEnabled = $true
        $searchBox.Focus()
        $searchBox.SelectAll()
    }

    $searchButton.Add_Click({ & $runSearch })
    $searchBox.Add_KeyDown({ if ($_.Key -eq 'Enter') { & $runSearch } })

    $window.Add_SourceInitialized({
        $searchBox.Focus()
        $searchBox.SelectAll()
    })

    $result = $window.ShowDialog()
    if ($result -eq $true) {
        return $dataGrid.SelectedItems
    }
}

function Edit-SettingsDialog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [System.Windows.Window]$Owner,

        [string[]]$PreferredPaths = @(            
            (Join-Path $rootPath "Config\config.json")
        )
    )

    Add-Type -AssemblyName PresentationCore | Out-Null
    Add-Type -AssemblyName PresentationFramework | Out-Null
    Add-Type -AssemblyName System.Windows.Forms | Out-Null

    function Resolve-ConfigPath {
        param([string[]]$Paths)
        $resolved = $null
        foreach ($p in $Paths) { if ($p -and (Test-Path -LiteralPath $p)) { $resolved = $p; break } }
        if ($resolved -eq $null) {
            foreach ($p in $Paths) {
                if ($p) {
                    $dir = Split-Path -Path $p -Parent
                    if ($dir -and (Test-Path -LiteralPath $dir)) { $resolved = $p; break }
                }
            }
        }
        return $resolved
    }

    function Load-ConfigObject {
        param([string]$Path)
        $obj = $null
        if ($Path -and (Test-Path -LiteralPath $Path)) {
            try {
                $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
                $obj = $raw | ConvertFrom-Json -ErrorAction Stop
            } catch {
                [System.Windows.MessageBox]::Show(("JSON could not be loaded: {0}" -f $_.Exception.Message), "Error", "OK", "Error") | Out-Null
            }
        }
        if ($obj -eq $null) {
            $obj = [PSCustomObject]@{
                packetRoot = "$env:TEMP\IntuneWin32Helper\out"
                removeExistingPacketDirOnEachRun = $false
                tenants   = @()
            }
        }
        if ($obj.tenants -eq $null) { $obj.tenants = @() }
        return $obj
    }

    function Save-ConfigObject {
        param([hashtable]$Data, [string]$Path)
        try {
            $dir = Split-Path -Path $Path -Parent
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $json = ConvertTo-Json -InputObject $Data -Depth 8
            Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
            return $true
        } catch {
            [System.Windows.MessageBox]::Show(("JSON could not be saved: {0}" -f $_.Exception.Message), "Error", "OK", "Error") | Out-Null
            return $false
        }
    }

    function Test-GuidString {
        param([string]$Text)
        $isGuid = $false
        try { $null = [Guid]::Parse($Text); $isGuid = $true } catch { $isGuid = $false }
        return $isGuid
    }

    # Pfad & Laden
    $configPath = Resolve-ConfigPath -Paths $PreferredPaths
    $cfg = Load-ConfigObject -Path $configPath

    # Fenster
    $dlg = New-Object Windows.Window
    $dlg.Title = "Edit settings"
    $dlg.Width = 900
    $dlg.Height = 640
    $dlg.WindowStartupLocation = "CenterOwner"
    if ($Owner -ne $null) { $dlg.Owner = $Owner }

    # Root-Grid
    $root = New-Object Windows.Controls.Grid
    $root.Margin = "12"
    $rowPath = New-Object Windows.Controls.RowDefinition; $rowPath.Height = [Windows.GridLength]::Auto
    $rowTabs = New-Object Windows.Controls.RowDefinition; $rowTabs.Height = New-Object Windows.GridLength -ArgumentList 1, ([Windows.GridUnitType]::Star)
    $rowBtns = New-Object Windows.Controls.RowDefinition; $rowBtns.Height = [Windows.GridLength]::Auto
    $null = $root.RowDefinitions.Add($rowPath); $null = $root.RowDefinitions.Add($rowTabs); $null = $root.RowDefinitions.Add($rowBtns)

    # Pfadzeile
    $pathGrid = New-Object Windows.Controls.Grid
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = "*"
    $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = "Auto"
    $null = $pathGrid.ColumnDefinitions.Add($c1); $null = $pathGrid.ColumnDefinitions.Add($c2)

    $tbPath = New-Object Windows.Controls.TextBox
    $tbPath.Text = $configPath
    $tbPath.Margin = "0,0,8,0"
    [Windows.Controls.Grid]::SetColumn($tbPath, 0)

    $btnBrowse = New-Object Windows.Controls.Button
    $btnBrowse.Content = "Browse..."
    [Windows.Controls.Grid]::SetColumn($btnBrowse, 1)

    $null = $pathGrid.Children.Add($tbPath); $null = $pathGrid.Children.Add($btnBrowse)
    [Windows.Controls.Grid]::SetRow($pathGrid, 0); $null = $root.Children.Add($pathGrid)

    # Tabs
    $tabs = New-Object Windows.Controls.TabControl
    [Windows.Controls.Grid]::SetRow($tabs, 1); $null = $root.Children.Add($tabs)

    # --- Tab: Allgemein ---
    $tabGeneral = New-Object Windows.Controls.TabItem
    $tabGeneral.Header = "Common"
    $generalGrid = New-Object Windows.Controls.Grid
    $generalGrid.Margin = "10"

    # 2 Spalten
    $gCol1 = New-Object Windows.Controls.ColumnDefinition; $gCol1.Width = "Auto"
    $gCol2 = New-Object Windows.Controls.ColumnDefinition; $gCol2.Width = "*"
    $null = $generalGrid.ColumnDefinitions.Add($gCol1); $null = $generalGrid.ColumnDefinitions.Add($gCol2)

    # ZEILEN:
    # 0: packetRoot
    # 1: removeExistingPacketDirOnEachRun
    # 2: Überschrift "Logo image conversion"
    # 6: Hyperlink (Cloudinary)
    for ($i=0; $i -lt 2; $i++) { $r = New-Object Windows.Controls.RowDefinition; $r.Height = [Windows.GridLength]::Auto; $null = $generalGrid.RowDefinitions.Add($r) }

    # packetRoot (mit Browse)
    $lblPacketRoot = New-Object Windows.Controls.TextBlock; $lblPacketRoot.Text = "packageRoot:"; $lblPacketRoot.VerticalAlignment = "Center"
    [Windows.Controls.Grid]::SetRow($lblPacketRoot,0); [Windows.Controls.Grid]::SetColumn($lblPacketRoot,0)

    $tbPacketRoot = New-Object Windows.Controls.TextBox; $tbPacketRoot.Margin = "6,0,0,0"; $tbPacketRoot.Text = $cfg.packetRoot
    $btnPacketBrowse = New-Object Windows.Controls.Button; $btnPacketBrowse.Content = "..."; $btnPacketBrowse.Width = 28; $btnPacketBrowse.Margin = "6,0,0,0"
    $cellGrid = New-Object Windows.Controls.Grid
    $cellCol1 = New-Object Windows.Controls.ColumnDefinition; $cellCol1.Width = "*"
    $cellCol2 = New-Object Windows.Controls.ColumnDefinition; $cellCol2.Width = "Auto"
    $null = $cellGrid.ColumnDefinitions.Add($cellCol1); $null = $cellGrid.ColumnDefinitions.Add($cellCol2)
    [Windows.Controls.Grid]::SetColumn($tbPacketRoot,0); [Windows.Controls.Grid]::SetColumn($btnPacketBrowse,1)
    $null = $cellGrid.Children.Add($tbPacketRoot); $null = $cellGrid.Children.Add($btnPacketBrowse)
    [Windows.Controls.Grid]::SetRow($cellGrid,0); [Windows.Controls.Grid]::SetColumn($cellGrid,1)

    # removeExistingPacketDirOnEachRun
    $lblRemove = New-Object Windows.Controls.TextBlock; $lblRemove.Text = "removeExistingPackageDirOnEachRun:"; $lblRemove.VerticalAlignment = "Center"
    [Windows.Controls.Grid]::SetRow($lblRemove,1); [Windows.Controls.Grid]::SetColumn($lblRemove,0)
    $cbRemove = New-Object Windows.Controls.CheckBox; $cbRemove.Margin = "6,0,0,0"; $cbRemove.IsChecked = $false
    if ($cfg.removeExistingPacketDirOnEachRun -is [bool]) { $cbRemove.IsChecked = $cfg.removeExistingPacketDirOnEachRun }
    elseif ($cfg.removeExistingPacketDirOnEachRun -is [string]) {
        $valLower = $cfg.removeExistingPacketDirOnEachRun.ToLower()
        if ($valLower -eq "true") { $cbRemove.IsChecked = $true }
        if ($valLower -eq "false") { $cbRemove.IsChecked = $false }
    }
    [Windows.Controls.Grid]::SetRow($cbRemove,1); [Windows.Controls.Grid]::SetColumn($cbRemove,1)

    # Controls in Tab "Allgemein" einfügen
    $null = $generalGrid.Children.Add($lblPacketRoot)
    $null = $generalGrid.Children.Add($cellGrid)
    $null = $generalGrid.Children.Add($lblRemove)
    $null = $generalGrid.Children.Add($cbRemove)

    $tabGeneral.Content = $generalGrid
    $null = $tabs.Items.Add($tabGeneral)

    # --- Tab: Tenants (inkl. clientSecret) ---
    $tabTenants = New-Object Windows.Controls.TabItem
    $tabTenants.Header = "Tenants"
    $tenantsGrid = New-Object Windows.Controls.Grid
    $tenantsGrid.Margin = "10"
    $tRow1 = New-Object Windows.Controls.RowDefinition; $tRow1.Height = New-Object Windows.GridLength -ArgumentList 1, ([Windows.GridUnitType]::Star)
    $tRow2 = New-Object Windows.Controls.RowDefinition; $tRow2.Height = [Windows.GridLength]::Auto
    $null = $tenantsGrid.RowDefinitions.Add($tRow1); $null = $tenantsGrid.RowDefinitions.Add($tRow2)

    $dgTenants = New-Object Windows.Controls.DataGrid
    $dgTenants.AutoGenerateColumns = $false
    $dgTenants.CanUserAddRows = $false
    $dgTenants.CanUserDeleteRows = $false
    $dgTenants.IsReadOnly = $false
    $dgTenants.SelectionMode = 'Extended'
    $dgTenants.SelectionUnit = 'FullRow'

    $colTName   = New-Object Windows.Controls.DataGridTextColumn; $colTName.Header   = "name";         $colTName.Binding   = New-Object Windows.Data.Binding("name")
    $colTAppId  = New-Object Windows.Controls.DataGridTextColumn; $colTAppId.Header  = "appid";        $colTAppId.Binding  = New-Object Windows.Data.Binding("appid")
    $colTSecret = New-Object Windows.Controls.DataGridTextColumn; $colTSecret.Header = "clientSecret"; $colTSecret.Binding = New-Object Windows.Data.Binding("clientSecret"); $colTSecret.Width = 260

    $null = $dgTenants.Columns.Add($colTName)
    $null = $dgTenants.Columns.Add($colTAppId)
    $null = $dgTenants.Columns.Add($colTSecret)

    $tenantItems = @()
    foreach ($t in $cfg.tenants) {
        $secret = ""
        if ($t.PSObject.Properties.Name -contains "clientSecret") { $secret = $t.clientSecret }
        $tenantItems += [PSCustomObject]@{ name = $t.name; appid = $t.appid; clientSecret = $secret }
    }
    $dgTenants.ItemsSource = $tenantItems

    [Windows.Controls.Grid]::SetRow($dgTenants, 0); $null = $tenantsGrid.Children.Add($dgTenants)

    $spTenantBtns = New-Object Windows.Controls.StackPanel
    $spTenantBtns.Orientation = "Horizontal"
    $spTenantBtns.HorizontalAlignment = "Right"
    $btnTenantAdd    = New-Object Windows.Controls.Button; $btnTenantAdd.Content    = "Add"; $btnTenantAdd.Margin    = "0,10,8,0"; $btnTenantAdd.Padding    = "14,6"
    $btnTenantEdit   = New-Object Windows.Controls.Button; $btnTenantEdit.Content   = "Edit"; $btnTenantEdit.Margin   = "0,10,8,0"; $btnTenantEdit.Padding   = "14,6"
    $btnTenantDelete = New-Object Windows.Controls.Button; $btnTenantDelete.Content = "Delete";    $btnTenantDelete.Margin = "0,10,0,0";  $btnTenantDelete.Padding = "14,6"
    $null = $spTenantBtns.Children.Add($btnTenantAdd)
    $null = $spTenantBtns.Children.Add($btnTenantEdit)
    $null = $spTenantBtns.Children.Add($btnTenantDelete)
    [Windows.Controls.Grid]::SetRow($spTenantBtns, 1); $null = $tenantsGrid.Children.Add($spTenantBtns)

    $tabTenants.Content = $tenantsGrid
    $null = $tabs.Items.Add($tabTenants)

    # --- Untere Buttons ---
    $spBtns = New-Object Windows.Controls.StackPanel
    $spBtns.Orientation = "Horizontal"
    $spBtns.HorizontalAlignment = "Right"
    $btnReload = New-Object Windows.Controls.Button; $btnReload.Content = "Reload"; $btnReload.Margin = "0,10,8,0"; $btnReload.Padding = "14,6"
    $btnSave   = New-Object Windows.Controls.Button; $btnSave.Content   = "Save"; $btnSave.Margin  = "0,10,8,0"; $btnSave.Padding  = "14,6"
    $btnClose  = New-Object Windows.Controls.Button; $btnClose.Content  = "Close"; $btnClose.Margin = "0,10,0,0";  $btnClose.Padding = "14,6"
    $null = $spBtns.Children.Add($btnReload); $null = $spBtns.Children.Add($btnSave); $null = $spBtns.Children.Add($btnClose)
    [Windows.Controls.Grid]::SetRow($spBtns, 2); $null = $root.Children.Add($spBtns)

    $dlg.Content = $root

    # --- Events ---

    # Datei durchsuchen
    $btnBrowse.Add_Click({
        try {
            $ofd = New-Object System.Windows.Forms.OpenFileDialog
            $ofd.Filter = "JSON file (*.json)|*.json|All files (*.*)|*.*"
            $ofd.Multiselect = $false
            $ofd.CheckFileExists = $false
            $ofd.FileName = "config.json"
            $res = $ofd.ShowDialog()
            if ($res -eq [System.Windows.Forms.DialogResult]::OK) {
                if ($ofd.FileName) { $tbPath.Text = $ofd.FileName }
            }
        } catch {
            [System.Windows.MessageBox]::Show(("File selection falied: {0}" -f $_.Exception.Message), "Error", "OK", "Error") | Out-Null
        }
    })

    # packetRoot Ordnerauswahl
    $btnPacketBrowse.Add_Click({
        try {
            $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
            $fbd.Description = "Select PackageRoot"
            $fbd.ShowNewFolderButton = $true
            $res = $fbd.ShowDialog()
            if ($res -eq [System.Windows.Forms.DialogResult]::OK) {
                if ($fbd.SelectedPath) { $tbPacketRoot.Text = $fbd.SelectedPath }
            }
        } catch {
            [System.Windows.MessageBox]::Show(("Folder selection failed: {0}" -f $_.Exception.Message), "Error", "OK", "Error") | Out-Null
        }
    })

    # Tenants: Hinzufügen
    $btnTenantAdd.Add_Click({
        try {
            $newTenant = Edit-TenantDialog -Owner $dlg
            if ($newTenant -ne $null) {
                $list = @($dgTenants.ItemsSource)
                $list += [PSCustomObject]@{ name = $newTenant.name; appid = $newTenant.appid; clientSecret = $newTenant.clientSecret }
                $dgTenants.ItemsSource = $null
                $dgTenants.ItemsSource = $list
            }
        } catch {
            [System.Windows.MessageBox]::Show(("Tenant edit failed: {0}" -f $_.Exception.Message), "Error", "OK", "Error") | Out-Null
        }
    })

    # Tenants: Bearbeiten
    $btnTenantEdit.Add_Click({
        try {
            $sel = $dgTenants.SelectedItem
            if ($sel -eq $null) {
                [System.Windows.MessageBox]::Show("Please select a tenant.", "Hint", "OK", "Information") | Out-Null
                return
            }
            $initialSecret = ""
            if ($sel.PSObject.Properties.Name -contains "clientSecret") { $initialSecret = $sel.clientSecret }
            $edited = Edit-TenantDialog -Owner $dlg -InitialName $sel.name -InitialAppId $sel.appid -InitialClientSecret $initialSecret
            if ($edited -ne $null) {
                $sel.name         = $edited.name
                $sel.appid        = $edited.appid
                $sel.clientSecret = $edited.clientSecret
                $dgTenants.Items.Refresh()
            }
        } catch {
            [System.Windows.MessageBox]::Show(("Tenant edit failed: {0}" -f $_.Exception.Message), "Error", "OK", "Error") | Out-Null
        }
    })

    # Tenants: Löschen
    $btnTenantDelete.Add_Click({
        try {
            $selected = $dgTenants.SelectedItems
            if ($selected -eq $null -or $selected.Count -eq 0) {
                [System.Windows.MessageBox]::Show("No tenants selected for deletion.", "Hint", "OK", "Information") | Out-Null
                return
            }
            $confirm = [System.Windows.MessageBox]::Show("Delete selected Tenants ?", "Confirm", "YesNo", "Warning")
            if ($confirm -eq "Yes") {
                $remaining = @()
                $current = @($dgTenants.ItemsSource)
                foreach ($item in $current) {
                    $isSelected = $false
                    foreach ($s in $selected) { if ($item -eq $s) { $isSelected = $true; break } }
                    if (-not $isSelected) { $remaining += $item }
                }
                $dgTenants.ItemsSource = $null
                $dgTenants.ItemsSource = $remaining
            }
        } catch {
            [System.Windows.MessageBox]::Show(("Tenant edit failed: {0}" -f $_.Exception.Message), "Error", "OK", "Error") | Out-Null
        }
    })

    # Neu laden
    $btnReload.Add_Click({
        try {
            $cfg = Load-ConfigObject -Path $tbPath.Text
            # Allgemein
            $tbPacketRoot.Text = $cfg.packetRoot
            $cbRemove.IsChecked = $false
            if ($cfg.removeExistingPacketDirOnEachRun -is [bool]) { $cbRemove.IsChecked = $cfg.removeExistingPacketDirOnEachRun }
            elseif ($cfg.removeExistingPacketDirOnEachRun -is [string]) {
                $valLower = $cfg.removeExistingPacketDirOnEachRun.ToLower()
                if ($valLower -eq "true") { $cbRemove.IsChecked = $true }
                if ($valLower -eq "false") { $cbRemove.IsChecked = $false }
            }
            # Tenants
            $tenantItems = @()
            foreach ($t in $cfg.tenants) {
                $secret = ""
                if ($t.PSObject.Properties.Name -contains "clientSecret") { $secret = $t.clientSecret }
                $tenantItems += [PSCustomObject]@{ name = $t.name; appid = $t.appid; clientSecret = $secret }
            }
            $dgTenants.ItemsSource = $null
            $dgTenants.ItemsSource = $tenantItems
        } catch {
            [System.Windows.MessageBox]::Show(("Reloading failed: {0}" -f $_.Exception.Message), "Error", "OK", "Error") | Out-Null
        }
    })

    # Speichern
    $btnSave.Add_Click({
        try {
            $targetPath = $tbPath.Text
            if (-not $targetPath) {
                [System.Windows.MessageBox]::Show("No path given.", "Hint", "OK", "Warning") | Out-Null
                return
            }

            # Tenants validieren/sammeln
            $tenantArray = @()
            foreach ($row in @($dgTenants.ItemsSource)) {
                $n = $row.name
                $a = $row.appid
                $s = ""
                if ($row.PSObject.Properties.Name -contains "clientSecret") { $s = $row.clientSecret }
                if (-not $n -or $n.Trim().Length -eq 0) {
                    [System.Windows.MessageBox]::Show("Tenant name must not be empty.", "Validation", "OK", "Warning") | Out-Null
                    return
                }
                if (-not (Test-GuidString -Text $a)) {
                    [System.Windows.MessageBox]::Show(("Invalid AppId (GUID) for tenant '{0}'." -f $n), "Validation", "OK", "Warning") | Out-Null
                    return
                }
                $tenantArray += @{ name = $n; appid = $a; clientSecret = $s }
            }

            # Allgemein sammeln
            $removeBool = $false
            if ($cbRemove.IsChecked -eq $true) { $removeBool = $true }

            $data = @{
                packetRoot = $tbPacketRoot.Text
                removeExistingPacketDirOnEachRun = $removeBool
                tenants   = $tenantArray
            }

            $ok = Save-ConfigObject -Data $data -Path $targetPath
            if ($ok) { [System.Windows.MessageBox]::Show(("Saved: {0}" -f $targetPath), "Success", "OK", "Information") | Out-Null }
        } catch {
            [System.Windows.MessageBox]::Show(("Save failed: {0}" -f $_.Exception.Message), "Error", "OK", "Error") | Out-Null
        }
    })

    # Schließen
    $btnClose.Add_Click({
        $dlg.DialogResult = $false
        $dlg.Close()
    })

    $null = $dlg.ShowDialog()
    return $true
}
#
function Edit-TenantDialog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [System.Windows.Window]$Owner,
        [string]$InitialName = "",
        [string]$InitialAppId = "",
        [string]$InitialClientSecret = ""
    )

    Add-Type -AssemblyName PresentationCore | Out-Null
    Add-Type -AssemblyName PresentationFramework | Out-Null

    function Test-GuidString {
        param([string]$Text)
        $isGuid = $false
        try {
            $null = [Guid]::Parse($Text)
            $isGuid = $true
        } catch {
            $isGuid = $false
        }
        return $isGuid
    }

    $dlg = New-Object Windows.Window
    $dlg.Title = "Tenant Edit"
    $dlg.Width = 560
    $dlg.Height = 280
    $dlg.WindowStartupLocation = "CenterOwner"
    if ($Owner -ne $null) { $dlg.Owner = $Owner }

    $grid = New-Object Windows.Controls.Grid
    $grid.Margin = "12"

    # Zeilen: name, appid, clientSecret, Buttons
    $row1 = New-Object Windows.Controls.RowDefinition; $row1.Height = [Windows.GridLength]::Auto
    $row2 = New-Object Windows.Controls.RowDefinition; $row2.Height = [Windows.GridLength]::Auto
    $row3 = New-Object Windows.Controls.RowDefinition; $row3.Height = [Windows.GridLength]::Auto
    $row4 = New-Object Windows.Controls.RowDefinition; $row4.Height = [Windows.GridLength]::Auto
    $null = $grid.RowDefinitions.Add($row1)
    $null = $grid.RowDefinitions.Add($row2)
    $null = $grid.RowDefinitions.Add($row3)
    $null = $grid.RowDefinitions.Add($row4)

    # Spalten: Label + Control
    $col1 = New-Object Windows.Controls.ColumnDefinition; $col1.Width = "Auto"
    $col2 = New-Object Windows.Controls.ColumnDefinition; $col2.Width = "*"
    $null = $grid.ColumnDefinitions.Add($col1)
    $null = $grid.ColumnDefinitions.Add($col2)

    # --- name ---
    $lblName = New-Object Windows.Controls.TextBlock
    $lblName.Text = "name:"
    $lblName.VerticalAlignment = "Center"
    [Windows.Controls.Grid]::SetRow($lblName,0); [Windows.Controls.Grid]::SetColumn($lblName,0)

    $tbName = New-Object Windows.Controls.TextBox
    $tbName.Margin = "6,0,0,0"
    $tbName.Text = $InitialName
    [Windows.Controls.Grid]::SetRow($tbName,0); [Windows.Controls.Grid]::SetColumn($tbName,1)

    # --- appid ---
    $lblAppId = New-Object Windows.Controls.TextBlock
    $lblAppId.Text = "appid (GUID):"
    $lblAppId.VerticalAlignment = "Center"
    [Windows.Controls.Grid]::SetRow($lblAppId,1); [Windows.Controls.Grid]::SetColumn($lblAppId,0)

    $tbAppId = New-Object Windows.Controls.TextBox
    $tbAppId.Margin = "6,0,0,0"
    $tbAppId.Text = $InitialAppId
    [Windows.Controls.Grid]::SetRow($tbAppId,1); [Windows.Controls.Grid]::SetColumn($tbAppId,1)

    # --- clientSecret (PasswordBox + Anzeigen-Checkbox) ---
    $lblSecret = New-Object Windows.Controls.TextBlock
    $lblSecret.Text = "clientSecret (optional):"
    $lblSecret.VerticalAlignment = "Center"
    [Windows.Controls.Grid]::SetRow($lblSecret,2); [Windows.Controls.Grid]::SetColumn($lblSecret,0)

    # Wir bauen rechts eine kleine Zelle mit PasswordBox + "anzeigen" Checkbox
    $secretCell = New-Object Windows.Controls.Grid
    $scCol1 = New-Object Windows.Controls.ColumnDefinition; $scCol1.Width = "*"
    $scCol2 = New-Object Windows.Controls.ColumnDefinition; $scCol2.Width = "Auto"
    $null = $secretCell.ColumnDefinitions.Add($scCol1)
    $null = $secretCell.ColumnDefinitions.Add($scCol2)

    $pbSecret = New-Object Windows.Controls.PasswordBox
    $pbSecret.Margin = "6,0,0,0"
    # PasswordBox kann nicht direkt vorbefüllt werden mit Klartext in sicheren Szenarien;
    # in WPF geht Set-Password nur über .Password:
    if ($InitialClientSecret) { $pbSecret.Password = $InitialClientSecret }
    [Windows.Controls.Grid]::SetColumn($pbSecret,0)

    $cbShow = New-Object Windows.Controls.CheckBox
    $cbShow.Content = "anzeigen"
    $cbShow.Margin = "6,0,0,0"
    [Windows.Controls.Grid]::SetColumn($cbShow,1)

    $null = $secretCell.Children.Add($pbSecret)
    $null = $secretCell.Children.Add($cbShow)

    [Windows.Controls.Grid]::SetRow($secretCell,2); [Windows.Controls.Grid]::SetColumn($secretCell,1)

    # Optional: bei "anzeigen" den Secret-Wert temporär in einem TextBox anzeigen
    # (Wir tauschen visuell zwischen PasswordBox und TextBox)
    $tbSecretPlain = New-Object Windows.Controls.TextBox
    $tbSecretPlain.Margin = "6,0,0,0"
    $tbSecretPlain.Visibility = 'Collapsed'
    if ($InitialClientSecret) { $tbSecretPlain.Text = $InitialClientSecret }
    # Wir legen die TextBox oben auf Column 0 derselben Zelle
    [Windows.Controls.Grid]::SetColumn($tbSecretPlain,0)
    $null = $secretCell.Children.Add($tbSecretPlain)

    # Toggle-Logik für Anzeigen
    $cbShow.Add_Checked({
        # Plain sichtbar, PasswordBox ausblenden; Inhalt synchronisieren
        $tbSecretPlain.Text = $pbSecret.Password
        $tbSecretPlain.Visibility = 'Visible'
        $pbSecret.Visibility = 'Collapsed'
    })
    $cbShow.Add_Unchecked({
        # PasswordBox sichtbar, Plain ausblenden; Inhalt synchronisieren
        $pbSecret.Password = $tbSecretPlain.Text
        $pbSecret.Visibility = 'Visible'
        $tbSecretPlain.Visibility = 'Collapsed'
    })

    # --- Buttons ---
    $spBtns = New-Object Windows.Controls.StackPanel
    $spBtns.Orientation = "Horizontal"
    $spBtns.HorizontalAlignment = "Right"
    [Windows.Controls.Grid]::SetRow($spBtns, 3); [Windows.Controls.Grid]::SetColumnSpan($spBtns, 2)

    $btnOK = New-Object Windows.Controls.Button
    $btnOK.Content = "OK"
    $btnOK.Margin = "0,10,8,0"
    $btnOK.Padding = "14,6"

    $btnCancel = New-Object Windows.Controls.Button
    $btnCancel.Content = "Cancel"
    $btnCancel.Margin = "0,10,0,0"
    $btnCancel.Padding = "14,6"

    $null = $spBtns.Children.Add($btnOK)
    $null = $spBtns.Children.Add($btnCancel)

    # --- Layout zusammenfügen ---
    $null = $grid.Children.Add($lblName)
    $null = $grid.Children.Add($tbName)
    $null = $grid.Children.Add($lblAppId)
    $null = $grid.Children.Add($tbAppId)
    $null = $grid.Children.Add($lblSecret)
    $null = $grid.Children.Add($secretCell)
    $null = $grid.Children.Add($spBtns)

    $dlg.Content = $grid

    $script:TenantResult = $null

    $btnCancel.Add_Click({
        $dlg.DialogResult = $false
        $dlg.Close()
    })

    $btnOK.Add_Click({
        try {
            $n = $tbName.Text
            $a = $tbAppId.Text
            # Secret: je nach Sichtbarkeit aus PasswordBox oder Plain-TextBox lesen
            $s = $pbSecret.Password
            if ($tbSecretPlain.Visibility -eq 'Visible') { $s = $tbSecretPlain.Text }

            if (-not $n -or $n.Trim().Length -eq 0) {
                [System.Windows.MessageBox]::Show("Name must not be empty.", "Validation", "OK", "Warning") | Out-Null
                return
            }
            if (-not (Test-GuidString -Text $a)) {
                [System.Windows.MessageBox]::Show("AppId is not a valid GUID.", "Validation", "OK", "Warning") | Out-Null
                return
            }
            # clientSecret darf leer sein; keine weitere Validierung erforderlich
            $script:TenantResult = [PSCustomObject]@{
                name         = $n
                appid        = $a
                clientSecret = $s
            }
            $dlg.DialogResult = $true
            $dlg.Close()
        } catch {
            [System.Windows.MessageBox]::Show(("Error: {0}" -f $_.Exception.Message), "Error", "OK", "Error") | Out-Null
        }
    })

    $null = $dlg.ShowDialog()
    return $script:TenantResult
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
