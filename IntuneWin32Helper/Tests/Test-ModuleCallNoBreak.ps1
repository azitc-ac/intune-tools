<#
    .SYNOPSIS
    Verhaltenstest fuer Invoke-IntuneModuleCall (siehe Pruefung 26 in Invoke-RepoChecks.ps1).

    .DESCRIPTION
    Das Modul IntuneWin32App beendet Fehlerpfade mit "Write-Warning ...; break".
    Hier wird genau das nachgestellt: ein Stapel aus drei Apps wie in
    createApps/deployApps, die mittlere bricht im "Modul" per break ab.

    Erwartet: App 1 und 3 laufen durch, App 2 landet als FAILED in der Liste.
    Ohne die Schleife in Invoke-IntuneModuleCall endet der Stapel nach App 1
    stillschweigend - so war es im Feld.

    Laeuft ohne Netz, ohne GUI und ohne Tenant (Bedingung des pre-commit-Hooks).
#>
$ErrorActionPreference = 'Stop'

# Nur die zu pruefende Funktion laden, nicht die ganze functions.ps1.
$functionsPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Functions\functions.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($functionsPath, [ref]$null, [ref]$null)
$def = $ast.Find({
    param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-IntuneModuleCall'
}, $true)
if (-not $def) { Write-Host "FAIL: Invoke-IntuneModuleCall not found in functions.ps1"; exit 1 }
. ([scriptblock]::Create($def.Extent.Text))

# Nachbau eines Modul-Cmdlets: bricht wie Add-IntuneWin32App (1.5.0, Zeile 280) per break ab.
# Als String, damit Pruefung 7 (BreakOutsideLoop) den absichtlichen Fehler in
# dieser Attrappe nicht als Fehler des Repos meldet.
. ([scriptblock]::Create(@'
function Add-FakeIntuneApp {
    [CmdletBinding()]
    param([string]$Name)
    Begin {
        if ($Name -eq 'App2') {
            Write-Warning "Authentication token was not found, use Connect-MSIntuneGraph before using this function"; break
        }
    }
    Process { [PSCustomObject]@{ id = "id-$Name" } }
}
'@))

$succeeded = @()
$failed    = @()
foreach ($app in 'App1', 'App2', 'App3') {
    try {
        $uploadResult = Invoke-IntuneModuleCall -Label 'Add-FakeIntuneApp' -Operation { Add-FakeIntuneApp -Name $app } 3>$null
        if (-not $uploadResult) { throw "Upload FAILED for $app" }
        $succeeded += $app
    }
    catch {
        $failed += ("{0}: {1}" -f $app, $_.Exception.Message)
    }
}

$problems = @()
if (($succeeded -join ',') -ne 'App1,App3') { $problems += "succeeded should be 'App1,App3', is '$($succeeded -join ',')'" }
if (@($failed).Count -ne 1 -or $failed[0] -notmatch '^App2: .*aborted inside the IntuneWin32App module') {
    $problems += "failed should hold exactly App2 with the module-abort message, is '$($failed -join ' | ')'"
}

if ($problems.Count -gt 0) {
    foreach ($pr in $problems) { Write-Host "FAIL: $pr" }
    exit 1
}
Write-Host "Invoke-IntuneModuleCall: break caught, batch continued (App1, App3 ok; App2 failed). PASS"
exit 0
