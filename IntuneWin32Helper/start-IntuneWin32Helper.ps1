$toolVersion = "2.0"
$rootDir = $PSScriptRoot
# Ohne $PSScriptRoot (markierter Code in der ISE) das aktuelle Verzeichnis nehmen -
# kein fest verdrahteter Pfad eines einzelnen Rechners. Muster aus SCCMAppHelper.
if (-not $rootDir) { $rootDir = (Get-Location).Path }

# Funktionen zuerst laden: Protokoll und Konfiguration laufen ueber gemeinsame
# Helfer (Start-ToolTranscript / Get-ToolConfig), nicht ueber eigene Pfade.
. "$rootDir\functions\functions.ps1"

$null = Start-ToolTranscript -RootDir $rootDir

$config = Get-ToolConfig -RootDir $rootDir

$cloudName = $config.cloudName
$ApiKey = $config.apiKey
$ApiSecret = $config.apiSecret
$packetRoot = $config.packetRoot

if (-not (Test-Path $packetRoot)) { md $packetRoot }

check-prereqs


Add-Type -AssemblyName PresentationFramework | Out-Null
Add-Type -AssemblyName System.Windows.Forms    | Out-Null


$continue = $true
while ($continue) {
    $choice = Show-StartDialog
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
