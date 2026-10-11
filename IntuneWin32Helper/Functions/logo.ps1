# ============================================================================
#  Logos: Quelle finden, auf 256x256 bringen. Alles lokal, nichts wird hochgeladen.
# ============================================================================

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
