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


# Das Inventar ist der Ausgangspunkt: eine Zeile pro App, links Definition und
# Paket, rechts der Tenant. Anlegen, bauen und verteilen gehen von dort aus.
# Die Startkacheln und die Auswahldialoge dahinter gibt es nicht mehr.
Start-InventoryLoop -RootDir $rootDir -ToolVersion $toolVersion
Stop-Transcript
