<#
.SYNOPSIS
	App detection script
					 
.DESCRIPTION
	This script detects if an app is installed.
					 
.NOTES
	Version:        2.2
	LastMod Date:   2024-01-31
	Purpose/Change: added support for ARM/x86, optimized logging, fixes
    # inspired by https://github.com/FlorianSLZ/Intune-Win32-Deployer
    # adapted by AZ - https://blog.zarenko.net
#>

Param
  (
    [parameter(Mandatory=$false)]
    [String[]]
    $param
  )

$Action = "Detect"
$PackageID = "WINGETPROGRAMID"
$logFile = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\$($PackageID)_$Action.log"

function Write-Log {
    param (
        [string]$message,
        [string]$logFilePath=$logfile
    )
    Add-Content -Path $logFilePath -Value "$(Get-Date): $message" -Force
    Write-Output $message
}
  
Write-Log "------------------------------------"
Write-Log "$Action $PackageID"
Write-Log "Resolving winget_exe"
$wingetPaths = Resolve-Path "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller*\winget.exe"

if ($wingetPaths.Count -gt 1) {
    # Sortiere die Pfade nach dem Installationsdatum und wähle den neuesten aus
    $wingetPaths = $wingetPaths | Sort-Object { (Get-Item $_.Path).CreationTime } -Descending
    $wingetPath = $wingetPaths[0].Path
    Write-Log "Path: $wingetPath"
    Write-Log "Winget found."
} elseif ($wingetPaths.Count -eq 1) {
    $wingetPath = $wingetPaths[0].Path
    Write-Log "Path: $wingetPath"
    Write-Log "Winget found."

} else {
    Write-Log "Winget NOT installed, exiting."
    exit 1
}

# 1. Ist die App ueberhaupt da?
$wingetPrg_Existing = & $wingetPath list --id $PackageID --exact --accept-source-agreements
if ($wingetPrg_Existing -notlike "*$PackageID*"){
    Write-Log "App $PackageID NOT found!"
    Write-Log "$Action finished."
    exit 1
}
Write-Log "App $PackageID found."

# 2. Ist sie aktuell? Dieser Schritt fehlte, und deshalb hat die Erkennung
#    gelogen: "winget list" meldet die App, sobald die ID irgendwie vorhanden
#    ist - eine drei Jahre alte Fassung galt damit als aktuell, Intune zeigte
#    gruen, und die App wurde nie erneuert. Das widerspricht dem Sinn von
#    Version "LatestAvailable".
#
#    Liegt ein Upgrade vor, wird "nicht installiert" gemeldet. Intune installiert
#    dann neu, und die Installationsroutine des Pakets holt per winget die
#    aktuelle Fassung.
#
#    Wichtig, absichtlich so: erreicht winget seine Quelle nicht (kein Netz,
#    Quelle gesperrt), erscheint die ID in der Upgrade-Liste nicht und die App
#    gilt als aktuell. Das ist die sichere Richtung - offline soll kein Geraet
#    in eine Neuinstallationsschleife laufen.
$wingetPrg_Upgrade = & $wingetPath upgrade --id $PackageID --exact --accept-source-agreements
if ($wingetPrg_Upgrade -like "*$PackageID*"){
    Write-Log "An upgrade is available for $PackageID - reporting as NOT installed so it gets renewed."
    Write-Log "$Action finished."
    exit 1
}

Write-Log "No upgrade available - $PackageID is current."
Write-Log "$Action finished."
exit 0