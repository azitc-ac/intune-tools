# ============================================================================
#  IntuneWin32Helper - Lader
#
#  Die Funktionen liegen nach Aufgabe in eigenen Dateien. Diese Datei laedt sie
#  und ist der EINE Einstieg: das Startskript und die Vorlage deploy_template.ps1
#  laden functions.ps1, und alle Pakete, die mit frueheren Staenden gebaut wurden,
#  tun es auch - der Dateiname bleibt deshalb.
#
#  Jede Datei hier gehoert in diese Liste (oder wird vom Startskript geladen);
#  das prueft Tests\Invoke-RepoChecks.ps1.
# ============================================================================

. "$PSScriptRoot\core.ps1"
. "$PSScriptRoot\dialogs.ps1"
. "$PSScriptRoot\logo.ps1"
. "$PSScriptRoot\installer.ps1"
. "$PSScriptRoot\deployscripts.ps1"
. "$PSScriptRoot\package.ps1"
. "$PSScriptRoot\appscsv.ps1"
. "$PSScriptRoot\inventory.ps1"
. "$PSScriptRoot\intune.ps1"
. "$PSScriptRoot\retire.ps1"
. "$PSScriptRoot\editdialog.ps1"
. "$PSScriptRoot\searchdialogs.ps1"
. "$PSScriptRoot\settingsdialogs.ps1"
. "$PSScriptRoot\mainwindow.ps1"
