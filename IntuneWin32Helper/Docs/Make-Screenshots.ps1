<#
    .SYNOPSIS
    Macht die Bilder fuer das README: Hauptfenster, WinGet-Suche, "Check tenant". Neu erzeugen, wenn sich ein Fenster aendert.

    .DESCRIPTION
    Die Bilder sind keine Handarbeit, sondern kommen aus den echten Fenstern (Show-InventoryDialog,
    Show-WinGetSearchDialog, Show-ConfirmDialog), die in einem Kindprozess mit ERFUNDENEN Beispieldaten
    gezeigt werden. Kein echter Tenant, keine echten Namen, keine Konfiguration. Die WinGet-Suche fragt den
    offiziellen Index wirklich ab (wie im Betrieb; beim ersten Mal laedt sie ihn nach Config\winget-index\,
    das ist gitignoriert).

    Das Bild malt das Fenster selbst (RenderTargetBitmap) - es muss also nicht sichtbar oder auf einem
    entsperrten Bildschirm liegen, und es zeigt nur den Inhalt, ohne Titelleiste und Rahmen.

        .\Docs\Make-Screenshots.ps1            # schreibt Docs\main-window.png, winget-search.png, check-tenant.png
#>
[CmdletBinding()]
param(
    [switch]$Child,
    [string]$Scenario,
    [string]$OutFile,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = $PSScriptRoot }

# ---------------------------------------------------------------------------
# Kindprozess: ein Fenster mit Beispieldaten zeigen, sich selbst abbilden, schliessen
# ---------------------------------------------------------------------------
if ($Child) {
    $rootDir = $toolRoot   # die Funktionen des Tools erwarten $rootDir (wie im Startskript)
    . (Join-Path $toolRoot 'Tests\Get-ToolFunctionsAst.ps1')
    $ast = Get-ToolFunctionsAst (Join-Path $toolRoot 'Functions')
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    . (Join-Path $toolRoot 'Functions\wingetindex.ps1')
    . (Join-Path $toolRoot 'Functions\tenantcheck.ps1')
    Add-Type -AssemblyName WindowsBase, PresentationCore, PresentationFramework

    # Nach einer Weile das (einzige) Fenster als PNG schreiben und schliessen. Die WinGet-Suche braucht
    # beim ersten Mal Zeit fuer den Index.
    $delay = $(if ($Scenario -eq 'winget') { 10000 } else { 2500 })
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds($delay)
    $timer.Add_Tick({
        $timer.Stop()
        foreach ($source in [System.Windows.PresentationSource]::CurrentSources) {
            $win = $source.RootVisual
            if ($win -isnot [System.Windows.Window]) { continue }
            $content = $win.Content
            $scale = 1.5
            # Der Rand des Inhalts (Margin) gehoert zum Bild: Render() setzt den Inhalt um ihn versetzt, ohne ihn
            # in der Groesse zu zaehlen - sonst fehlt rechts und unten ein Stueck.
            $width = $content.ActualWidth + $content.Margin.Left + $content.Margin.Right
            $height = $content.ActualHeight + $content.Margin.Top + $content.Margin.Bottom
            $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap ([int]($width * $scale)), ([int]($height * $scale)), (96 * $scale), (96 * $scale), ([System.Windows.Media.PixelFormats]::Pbgra32)
            # Hintergrund des Fensters mitnehmen, dann der Inhalt
            $visual = New-Object System.Windows.Media.DrawingVisual
            $context = $visual.RenderOpen()
            $context.DrawRectangle($win.Background, $null, (New-Object System.Windows.Rect 0, 0, $width, $height))
            $context.Close()
            $bitmap.Render($visual)
            $bitmap.Render($content)
            # Ein leeres Bild ist schlimmer als keins: in einer getrennten oder gesperrten Sitzung malt WPF nichts
            # (alle Pixel gleich). Dann kein Bild schreiben und mit Exit 3 melden.
            $stride = $bitmap.PixelWidth * 4
            $pixels = New-Object byte[] ($stride * $bitmap.PixelHeight)
            $bitmap.CopyPixels($pixels, $stride, 0)
            $colors = New-Object System.Collections.Generic.HashSet[int]
            for ($i = 0; $i -lt $pixels.Length; $i += 64) { $null = $colors.Add([BitConverter]::ToInt32($pixels, $i)) }
            if ($colors.Count -lt 5) {
                [Console]::Error.WriteLine("blank: the window painted nothing ({0} colours) - is the session disconnected or locked?" -f $colors.Count)
                $win.Close()
                $script:blank = $true
                return
            }
            $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $null = $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
            $stream = [System.IO.File]::Create($OutFile)
            $encoder.Save($stream)
            $stream.Dispose()
            $win.Close()
        }
    })
    $timer.Start()

    # Die WinGet-Suche zeigt erst nach "Search" ein Ergebnis: den Knopf wie ein Benutzer ausloesen (UI Automation).
    if ($Scenario -eq 'winget') {
        $press = New-Object System.Windows.Threading.DispatcherTimer
        $press.Interval = [TimeSpan]::FromMilliseconds(1500)
        $press.Add_Tick({
            $press.Stop()
            foreach ($source in [System.Windows.PresentationSource]::CurrentSources) {
                $win = $source.RootVisual
                if ($win -isnot [System.Windows.Window]) { continue }
                $stack = New-Object System.Collections.Stack
                $stack.Push($win)
                while ($stack.Count) {
                    $node = $stack.Pop()
                    if ($node -is [System.Windows.Controls.Button] -and [System.Windows.Automation.AutomationProperties]::GetAutomationId($node) -eq 'Search') {
                        $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($node)
                        $peer.GetPattern([System.Windows.Automation.Peers.PatternInterface]::Invoke).Invoke()
                        break
                    }
                    if ($node -is [System.Windows.DependencyObject]) {
                        for ($k = 0; $k -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($node); $k++) { $stack.Push([System.Windows.Media.VisualTreeHelper]::GetChild($node, $k)) }
                    }
                }
            }
        })
        $press.Start()
    }

    switch ($Scenario) {
        'main' {
            function New-Row([string]$name, [string]$version, [string]$publisher, [string]$status, [bool]$hasDef, [bool]$hasPkg, [string]$intune, [string]$next, [string]$template, [string]$origin = '') {
                [pscustomobject]@{
                    Key = "$name - $version"; AppName = $name; AppVersion = $version; Publisher = $publisher
                    Definition = $(if ($hasDef) { 'yes' } else { '-' }); Package = $(if ($hasPkg) { 'yes' } else { '-' })
                    Template = $template; Status = $status; Intune = $intune; Next = $next
                    FullPath = $(if ($hasPkg) { "D:\Packages\$name - $version\deploy.ps1" } else { '' })
                    HasDefinition = $hasDef; HasPackage = $hasPkg
                    DefinitionRecord = $(if ($hasDef) { [pscustomobject]@{ DisplayName = $name; Version = $version } } else { $null })
                    Detail = "$name $version`nDefinition: $(if ($hasDef) { 'Apps.csv' } else { 'none' })`nPackage: $(if ($hasPkg) { "D:\Packages\$name - $version" } else { 'not built' })"
                    IntuneOnly = [bool]$origin; Origin = $origin
                }
            }
            $rows = @(
                (New-Row '7-Zip'              '24.09'           'Igor Pavlov'    'Package'                    $true  $true  'yes'                   'up to date'                                     'current'),
                (New-Row 'Git'                '2.47.1'          'Git'            'Package'                    $true  $true  'yes'                   'up to date'                                     'current'),
                (New-Row 'Greenshot'          '1.3.290'         'Greenshot'      'Package, template outdated' $true  $true  'yes'                   'renew from template, then deploy'               'outdated'),
                (New-Row 'Notepad++'          '8.7.5'           'Notepad++ Team' 'Definition only'            $true  $false '-'                     'create package'                                 '-'),
                (New-Row 'VLC media player'   '3.0.21'          'VideoLAN'       'Package'                    $true  $true  'other version: 3.0.20' 'deploy (new version)'                           'current'),
                (New-Row 'Visual Studio Code' 'LatestAvailable' 'Microsoft'      'Package'                    $true  $true  '-'                     'deploy'                                         'current'),
                (New-Row 'Old Tool'           '1.0'             ''               'No definition'              $false $true  '-'                     'package without a row in Apps.csv'              'current'),
                (New-Row 'Contoso Kiosk'      '2.1'             'Contoso'        'Intune only'                $false $false 'yes'                   'in Intune only - no definition or package here' '-' 'tool'),
                (New-Row 'Company Portal'     '11.2'            'Microsoft'      'Foreign app'                $false $false 'yes'                   'not created by this tool'                       '-' 'foreign')
            )
            $null = Show-InventoryDialog -Inventory $rows -Title 'IntuneWin32Helper - https://blog.zarenko.net/' -PacketRoot 'D:\Packages' `
                -TenantNames @('contoso.onmicrosoft.com', 'fabrikam.onmicrosoft.com') -TenantName 'contoso.onmicrosoft.com' `
                -IntuneRead $true -ConfigPath 'D:\Tool\Config\config.json' -Select @('Greenshot - 1.3.290')
        }
        'winget' {
            $null = Show-WinGetSearchDialog -Packages (Get-WinGetCatalogList) -Query 'vlc'
        }
        'check' {
            $results = @(
                [pscustomobject]@{ Check = 'Entry';       Status = 'OK'; Detail = 'contoso.onmicrosoft.com, appid 6b5f0a52-0000-0000-0000-000000000000, clientSecret set' },
                [pscustomobject]@{ Check = 'Sign-in';     Status = 'OK'; Detail = 'token received' },
                [pscustomobject]@{ Check = 'Permission';  Status = 'OK'; Detail = 'DeviceManagementApps.ReadWrite.All granted' },
                [pscustomobject]@{ Check = 'Read access'; Status = 'OK'; Detail = 'the app list of the tenant can be read' },
                [pscustomobject]@{ Check = 'Tenant';      Status = 'OK'; Detail = 'token tenant 0f1e2d3c-0000-0000-0000-000000000000 (the entry is a name, not compared)' }
            )
            $null = Show-ConfirmDialog -Text (Format-TenantCheck -Results $results -TenantName 'contoso.onmicrosoft.com') -Title 'Check tenant' -Buttons OK -Icon Information
        }
        default { throw "unbekanntes Szenario: $Scenario" }
    }
    if ($script:blank) { exit 3 }
    exit 0
}

# ---------------------------------------------------------------------------
# Elternprozess: je Bild einen Kindprozess starten und auf die Datei warten
# ---------------------------------------------------------------------------
$shots = @(
    @{ Scenario = 'main';   File = 'main-window.png' },
    @{ Scenario = 'winget'; File = 'winget-search.png' },
    @{ Scenario = 'check';  File = 'check-tenant.png' }
)
foreach ($shot in $shots) {
    # Erst in eine Nebendatei: ein misslungener Lauf (getrennte Sitzung) darf das vorhandene Bild nicht loeschen.
    $target = Join-Path $OutDir $shot.File
    $fresh = $target + '.new'
    if (Test-Path -LiteralPath $fresh) { Remove-Item -LiteralPath $fresh -Force }
    $process = Start-Process -FilePath powershell.exe -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $PSCommandPath), '-Child', '-Scenario', $shot.Scenario, '-OutFile', ('"{0}"' -f $fresh))
    if (-not $process.WaitForExit(120000)) { Stop-Process -Id $process.Id -Force; throw "$($shot.Scenario): das Fenster schloss sich nicht" }
    if (-not (Test-Path -LiteralPath $fresh)) { throw "$($shot.Scenario): kein Bild entstanden, das alte bleibt (Exit $($process.ExitCode); 3 = das Fenster malte nichts, die Sitzung ist getrennt oder gesperrt)" }
    Move-Item -LiteralPath $fresh -Destination $target -Force
    '{0}: {1:N0} KB' -f $shot.File, ((Get-Item -LiteralPath $target).Length / 1KB)
}
