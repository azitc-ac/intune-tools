<#
    .SYNOPSIS
    Verhaltenstest: "Check tenant" - der Zugriff auf einen Tenant, Schritt fuer Schritt.

    .DESCRIPTION
    Anmeldung und Graph sind ersetzt (Initialize-IntuneConnection setzt ein selbst gebautes Token,
    Invoke-RestMethod antwortet oder wirft); alles andere ist der echte Code. Geprueft wird:

      1. Alles in Ordnung: jeder Schritt OK.
      2. Eintrag unvollstaendig: FAIL, die Anmeldung wird gar nicht erst versucht, der Rest SKIP.
      3. Die Anmeldung scheitert: FAIL mit Fehlertext und Fundstelle, der Rest SKIP.
      4. Das Token traegt nur Leserechte: Permission FAIL, mit den vorhandenen Rechten genannt.
      5. Das Lesen scheitert: Read access FAIL.
      6. Das Token gehoert zu einem anderen Tenant als eingetragen (GUID): Tenant FAIL.
      7. Ein Token ohne Rechte-Angaben oder kein JWT: WARN statt FAIL oder Absturz.
      8. Invoke-TenantCheck: nach einer gescheiterten Pruefung gilt wieder das Token von vorher, nach
         einer bestandenen das neue; das Ergebnis geht in den Dialog.
#>
$ErrorActionPreference = 'Stop'

$rootDir = Split-Path -Parent $PSScriptRoot
foreach ($file in 'Functions\functions.ps1', 'Functions\tenantcheck.ps1') {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $rootDir $file), [ref]$null, [ref]$null)
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($fn.Extent.Text))
    }
}
$script:TenantCheckRole = 'DeviceManagementApps.ReadWrite.All'

$problems = @()
function Test-That([bool]$condition, [string]$what) { if (-not $condition) { $script:problems += $what } }

function New-TestToken([hashtable]$Claims) {
    $json = $Claims | ConvertTo-Json -Compress
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return @{ Authorization = "Bearer e30.$b64.sig" }
}
function Get-Status($results, [string]$check) { (@($results | Where-Object { $_.Check -eq $check })[0]).Status }

$tid = '11111111-2222-3333-4444-555555555555'
$goodTenant = [pscustomobject]@{ name = $tid; appid = '99999999-8888-7777-6666-555555555555'; clientSecret = 's3cret' }
$tenants = @($goodTenant)

$script:signIns = 0
$script:nextToken = New-TestToken @{ tid = $tid; roles = @('DeviceManagementApps.ReadWrite.All', 'Other.Read') }
$script:signInFails = $false
$script:graphFails = $false
function Initialize-IntuneConnection {
    param($Tenant, $Tenants, [switch]$Force)
    $script:signIns++; $script:lastForce = [bool]$Force
    if ($script:signInFails) { throw 'AADSTS7000215: Invalid client secret provided' }
    $global:AuthenticationHeader = $script:nextToken
    return $Tenant
}
function Invoke-RestMethod {
    param($Uri, $Headers, $Method, $Body, $ContentType, $ErrorAction)
    if ($script:graphFails) { throw 'Forbidden' }
    return [pscustomobject]@{ value = @() }
}

# 1: alles in Ordnung
$r = @(Test-TenantConfiguration -Tenant $goodTenant -Tenants $tenants)
Test-That ($r.Count -eq 5) "all five steps are reported: $($r.Count)"
foreach ($c in 'Entry', 'Sign-in', 'Permission', 'Read access', 'Tenant') { Test-That ((Get-Status $r $c) -eq 'OK') "good case: $c is $(Get-Status $r $c), expected OK" }
Test-That ($script:lastForce -eq $true) "the check signs in with -Force (a token from before proves nothing)"
$text = Format-TenantCheck -Results $r -TenantName 'T'
Test-That ($text -like '*The tenant is ready for Deploy.*') "verdict for the good case: $text"

# 2: Eintrag unvollstaendig
$script:signIns = 0
$bad = [pscustomobject]@{ name = 'x'; appid = 'not-a-guid'; clientSecret = '' }
$r = @(Test-TenantConfiguration -Tenant $bad -Tenants @($bad))
Test-That ((Get-Status $r 'Entry') -eq 'FAIL') 'incomplete entry: Entry is FAIL'
Test-That (($r | Where-Object { $_.Check -eq 'Entry' }).Detail -match 'appid is not a GUID' -and ($r | Where-Object { $_.Check -eq 'Entry' }).Detail -match 'clientSecret is empty') 'incomplete entry: both problems named'
Test-That ($script:signIns -eq 0) 'incomplete entry: no sign-in is attempted'
foreach ($c in 'Sign-in', 'Permission', 'Read access', 'Tenant') { Test-That ((Get-Status $r $c) -eq 'SKIP') "incomplete entry: $c is $(Get-Status $r $c), expected SKIP" }

# 3: die Anmeldung scheitert
$script:signInFails = $true
$r = @(Test-TenantConfiguration -Tenant $goodTenant -Tenants $tenants)
$signIn = $r | Where-Object { $_.Check -eq 'Sign-in' }
Test-That ($signIn.Status -eq 'FAIL' -and $signIn.Detail -match 'Invalid client secret' -and $signIn.Detail -match '\(\S+\.ps1:\d+\)') "failing sign-in: $($signIn.Status) / $($signIn.Detail)"
foreach ($c in 'Permission', 'Read access', 'Tenant') { Test-That ((Get-Status $r $c) -eq 'SKIP') "failing sign-in: $c is $(Get-Status $r $c), expected SKIP" }
$script:signInFails = $false

# 4: nur Leserechte
$script:nextToken = New-TestToken @{ tid = $tid; roles = @('DeviceManagementApps.Read.All') }
$r = @(Test-TenantConfiguration -Tenant $goodTenant -Tenants $tenants)
$perm = $r | Where-Object { $_.Check -eq 'Permission' }
Test-That ($perm.Status -eq 'FAIL' -and $perm.Detail -match 'ReadWrite\.All is missing' -and $perm.Detail -match 'DeviceManagementApps\.Read\.All') "read-only token: $($perm.Status) / $($perm.Detail)"
Test-That ((Get-Status $r 'Read access') -eq 'OK') 'read-only token: reading is still reported as OK'
$text = Format-TenantCheck -Results $r -TenantName 'T'
Test-That ($text -like '*1 step(s) failed*') "verdict names the failed step: $text"

# 5: Lesen scheitert
$script:nextToken = New-TestToken @{ tid = $tid; roles = @('DeviceManagementApps.ReadWrite.All') }
$script:graphFails = $true
$r = @(Test-TenantConfiguration -Tenant $goodTenant -Tenants $tenants)
$read = $r | Where-Object { $_.Check -eq 'Read access' }
Test-That ($read.Status -eq 'FAIL' -and $read.Detail -match 'Forbidden') "failing read: $($read.Status) / $($read.Detail)"
$script:graphFails = $false

# 6: anderer Tenant
$script:nextToken = New-TestToken @{ tid = '00000000-0000-0000-0000-000000000001'; roles = @('DeviceManagementApps.ReadWrite.All') }
$r = @(Test-TenantConfiguration -Tenant $goodTenant -Tenants $tenants)
Test-That ((Get-Status $r 'Tenant') -eq 'FAIL') "token of another tenant: Tenant is $(Get-Status $r 'Tenant')"
$named = [pscustomobject]@{ name = 'contoso.onmicrosoft.com'; appid = $goodTenant.appid; clientSecret = 's' }
$r = @(Test-TenantConfiguration -Tenant $named -Tenants @($named))
Test-That ((Get-Status $r 'Tenant') -eq 'OK') "an entry by name is not compared: Tenant is $(Get-Status $r 'Tenant')"

# 7: Token ohne Rechte-Angaben, Token kein JWT
$script:nextToken = New-TestToken @{ tid = $tid }
$r = @(Test-TenantConfiguration -Tenant $goodTenant -Tenants $tenants)
Test-That ((Get-Status $r 'Permission') -eq 'WARN') "token without permission claims: Permission is $(Get-Status $r 'Permission')"
$script:nextToken = @{ Authorization = 'Bearer opaque' }
$r = @(Test-TenantConfiguration -Tenant $goodTenant -Tenants $tenants)
Test-That ((Get-Status $r 'Permission') -eq 'WARN' -and (Get-Status $r 'Tenant') -eq 'WARN') 'token that is no JWT: WARN, no crash'
Test-That ($null -eq (Get-AccessTokenClaims -Header @{ Authorization = 'Basic abc' })) 'a non-bearer header has no claims'
# Base64url-Auffuellung: Nutzlasten jeder Laenge muessen lesbar sein
foreach ($n in 1..6) {
    $claims = Get-AccessTokenClaims -Header (New-TestToken @{ tid = ('x' * $n) })
    Test-That ($claims -and $claims.tid -eq ('x' * $n)) "base64url payload with $n chars is readable"
}

# 8: Invoke-TenantCheck
$script:shown = @()
function Show-ConfirmDialog { param($Text, $Title, $Buttons, $Icon, $Default) $script:shown += [pscustomobject]@{ Text = $Text; Icon = $Icon }; return 'OK' }
$old = @{ Authorization = 'Bearer OLD' }
$global:AuthenticationHeader = $old
$script:nextToken = New-TestToken @{ tid = $tid; roles = @('DeviceManagementApps.Read.All') }
$r = @(Invoke-TenantCheck -Tenant $goodTenant -Tenants $tenants 6>&1 | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
Test-That ($global:AuthenticationHeader.Authorization -eq 'Bearer OLD') 'a failed check restores the token from before'
Test-That ($script:shown.Count -eq 1 -and $script:shown[0].Icon -eq 'Error') "a failed check is shown with the error icon: $($script:shown[0].Icon)"
$script:nextToken = New-TestToken @{ tid = $tid; roles = @('DeviceManagementApps.ReadWrite.All') }
$null = Invoke-TenantCheck -Tenant $goodTenant -Tenants $tenants 6>&1
Test-That ($global:AuthenticationHeader.Authorization -ne 'Bearer OLD') 'a passed check keeps the new token'
Test-That ($script:shown.Count -eq 2 -and $script:shown[1].Icon -eq 'Information') 'a passed check is shown with the information icon'
$script:shown = @()
$null = Invoke-TenantCheck -Tenant $null -Tenants $tenants
Test-That ($script:shown.Count -eq 1 -and $script:shown[0].Text -like 'Choose a tenant first*') 'no tenant chosen: the user is told so'

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { [Console]::WriteLine("FAIL: $p") }
    exit 1
}
[Console]::WriteLine('Tenant check: entry, sign-in, permission, read access and tenant are reported step by step; a failure skips what builds on it and restores the previous token. PASS')
exit 0
