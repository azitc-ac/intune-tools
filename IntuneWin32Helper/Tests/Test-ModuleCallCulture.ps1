<#
    .SYNOPSIS
    Verhaltenstest: Invoke-IntuneModuleCall ruft das Modul unter der InvariantCulture.

    .DESCRIPTION
    IntuneWin32App 1.5.0 (Test-AccessToken, Invoke-AzureStorageBlobUpload) liest
    das Token-Ablaufdatum per
      [DateTimeOffset]::Parse($Global:AccessToken.ExpiresOn.ToString(), InvariantCulture, AssumeUniversal)
    ToString() formatiert in der Kultur des Rechners. Unter de-DE wirft das ab
    dem 13. eines Monats - im Feld (2026-09-28) scheiterte so jeder Upload.

    Der Test erzwingt de-DE und einen 28. als Datum, damit er auf JEDEM Rechner
    aussagekraeftig ist, auch unter en-US in einer Linux-Cloud-Session. Er prueft
    zuerst, dass der Nachbau den Fehler ohne Huelle wirklich zeigt - sonst waere
    ein gruener Lauf wertlos.

    Laeuft ohne Netz, ohne GUI, ohne Tenant und ohne das Modul.
#>
$ErrorActionPreference = 'Stop'

$functionsPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Functions\functions.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($functionsPath, [ref]$null, [ref]$null)
$def = $ast.Find({
    param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-IntuneModuleCall'
}, $true)
if (-not $def) { Write-Host "FAIL: Invoke-IntuneModuleCall not found in functions.ps1"; exit 1 }
. ([scriptblock]::Create($def.Extent.Text))

# Genau die Zeile aus IntuneWin32App 1.5.0, Public\Test-AccessToken.ps1:49
$expires = New-Object System.DateTimeOffset 2026, 9, 28, 10, 20, 17, ([TimeSpan]::Zero)
function Read-FakeTokenExpiry {
    [DateTimeOffset]::Parse($expires.ToString(), [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
}

$problems = @()
$original = [System.Threading.Thread]::CurrentThread.CurrentCulture
try {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = New-Object System.Globalization.CultureInfo 'de-DE'

    # 1) Der Nachbau muss den Fehler zeigen, sonst prueft dieser Test nichts.
    $reproduced = $false
    try { $null = Read-FakeTokenExpiry } catch { $reproduced = $true }
    if (-not $reproduced) { $problems += "setup: the de-DE parse error could not be reproduced - this test proves nothing here" }

    # 2) Ueber die Huelle: kein Fehler, richtiges Datum.
    try {
        $value = Invoke-IntuneModuleCall -Label 'Read-FakeTokenExpiry' -Operation { Read-FakeTokenExpiry }
        if ($value -ne $expires) { $problems += "wrapped: parsed $value, expected $expires" }
    }
    catch { $problems += "wrapped: still throws - $($_.Exception.Message)" }

    # 3) Die Kultur des Aufrufers ist danach wieder hergestellt.
    $after = [System.Threading.Thread]::CurrentThread.CurrentCulture.Name
    if ($after -ne 'de-DE') { $problems += "culture after the call is '$after', expected 'de-DE'" }
}
finally {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $original
}

if ($problems.Count -gt 0) {
    foreach ($pr in $problems) { Write-Host "FAIL: $pr" }
    exit 1
}
Write-Host "Invoke-IntuneModuleCall: module runs under InvariantCulture, de-DE token date parses, caller culture restored. PASS"
exit 0
