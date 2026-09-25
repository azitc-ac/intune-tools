$rootDir = $PSScriptRoot
# Ohne $PSScriptRoot (markierter Code in der ISE) das aktuelle Verzeichnis nehmen -
# kein fest verdrahteter Pfad eines einzelnen Rechners. Muster aus SCCMAppHelper.
if (-not $rootDir) { $rootDir = (Get-Location).Path }

# Die Version steht in VERSION, eine Zeile. Der pre-commit-Hook (.githooks des
# Repos) hebt ihre letzte Zahl bei jedem Commit. Sie landet im Fenstertitel UND
# als Vermerk an jeder erzeugten App in Intune - dort sagt sie also, welcher
# Build die App gebaut hat. Der Wert hier ist nur der Notnagel, falls die Datei
# fehlt.
$toolVersion = '2.0'
$versionFile = Join-Path $rootDir 'VERSION'
if (Test-Path -LiteralPath $versionFile) {
    $fileVersion = (Get-Content -LiteralPath $versionFile -TotalCount 1).Trim()
    if ($fileVersion) { $toolVersion = $fileVersion }
}

# Funktionen zuerst laden: Protokoll und Konfiguration laufen ueber gemeinsame
# Helfer (Start-ToolTranscript / Get-ToolConfig), nicht ueber eigene Pfade.
. "$rootDir\functions\functions.ps1"

$null = Start-ToolTranscript -RootDir $rootDir

$config = Get-ToolConfig -RootDir $rootDir

$packetRoot = $config.packetRoot

if (-not (Test-Path $packetRoot)) { md $packetRoot }

check-prereqs


Add-Type -AssemblyName PresentationFramework | Out-Null
Add-Type -AssemblyName System.Windows.Forms    | Out-Null


$continue = $true
while ($continue) {
    $choice = Show-StartDialog -Title ("IntuneWin32Helper {0} - https://blog.zarenko.net/" -f $toolVersion)
    switch ($choice) {
        'CreateNew'          { "-> Start packaging assistant"; createApps }
        'CreateNewAndDeploy' { "-> Start packaging + deployment"; createApps -createAndDeploy }
        'DeployExisting'     { "-> Start deployment of existing app"; deployApps }
        'Cancel'             { "-> Cancelled"; $continue = $false }
        'Closed'             { "-> Closed with [X]"; $continue = $false }
        default              { "-> Unexpected: $choice"; $continue = $false }
    }
}
Stop-Transcript
