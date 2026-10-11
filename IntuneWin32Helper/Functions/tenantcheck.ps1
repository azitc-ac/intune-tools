<#
    IntuneWin32Helper - Tenant-Zugriff pruefen

    "Hat die App-Registrierung, was das Tool braucht?" laesst sich vor dem ersten Deploy beantworten,
    statt erst in dessen Mitte als 403 (Muster: Test-SiteConfiguration im SCCMAppHelper). Geprueft wird
    in dieser Reihenfolge, jeder Schritt setzt den vorigen voraus:

        1. Eintrag    name, appid (GUID) und clientSecret sind in der Konfiguration eingetragen
        2. Anmeldung  Token holen - ueber Initialize-IntuneConnection, den einzigen Weg dafuer
        3. Rechte     das Token traegt DeviceManagementApps.ReadWrite.All (Apps anlegen und loeschen)
        4. Lesen      die App-Liste des Tenants laesst sich wirklich abrufen
        5. Tenant     das Token gehoert zu dem Tenant, der eingetragen ist

    Schreiben wird NICHT durch Anlegen einer App erprobt (das haette Nebenwirkungen im Tenant); das
    Recht steht im Token, und ob es wirkt, zeigt der erste Deploy.
#>

$script:TenantCheckRole = 'DeviceManagementApps.ReadWrite.All'

function Get-AccessTokenClaims {
    <#
        Die Ansprueche (claims) eines Bearer-Tokens, ohne Pruefung der Signatur - gelesen wird nur,
        was das Token ueber sich selbst sagt. $null, wenn es kein JWT ist.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Header)

    $bearer = [string]$Header.Authorization
    if ($bearer -notmatch '^Bearer\s+(?<jwt>\S+)$') { return $null }
    $parts = $Matches['jwt'] -split '\.'
    if ($parts.Count -lt 2) { return $null }
    try {
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
        $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        return ($json | ConvertFrom-Json)
    }
    catch { return $null }
}

function Test-TenantConfiguration {
    <#
        .SYNOPSIS
        Prueft den Zugriff auf einen Tenant und gibt je Schritt { Check, Status, Detail } zurueck.

        .DESCRIPTION
        Status ist OK, WARN oder FAIL. Scheitert ein Schritt, entfallen die, die auf ihm aufbauen
        (Status SKIP): ohne Eintrag keine Anmeldung, ohne Anmeldung kein Token.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Tenant,
        [Parameter(Mandatory = $true)]$Tenants
    )

    $results = New-Object System.Collections.ArrayList
    $add = { param($check, $status, $detail) $null = $results.Add([pscustomobject]@{ Check = $check; Status = $status; Detail = $detail }) }
    $stop = {
        param($from)
        foreach ($rest in 'Sign-in', 'Permission', 'Read access', 'Tenant') {
            if ($rest -eq $from) { $go = $true }
            if ($go) { & $add $rest 'SKIP' 'not checked, the step before failed' }
        }
    }

    # 1. Eintrag
    $problems = @()
    if ([string]::IsNullOrWhiteSpace([string]$Tenant.name)) { $problems += 'name is empty' }
    $appId = [guid]::Empty
    if (-not [guid]::TryParse([string]$Tenant.appid, [ref]$appId)) { $problems += 'appid is not a GUID' }
    if ([string]::IsNullOrWhiteSpace([string]$Tenant.clientSecret)) { $problems += 'clientSecret is empty' }
    if ($problems.Count -gt 0) {
        & $add 'Entry' 'FAIL' (($problems -join '; ') + ' - fix it under Settings (gear icon), tab Tenants')
        & $stop 'Sign-in'
        return $results.ToArray()
    }
    & $add 'Entry' 'OK' ("{0}, appid {1}, clientSecret set" -f $Tenant.name, $Tenant.appid)

    # 2. Anmeldung - immer neu: geprueft wird die Konfiguration, nicht ein Token von vorhin
    $global:AuthenticationHeader = $null
    try {
        $null = Initialize-IntuneConnection -Tenant $Tenant -Tenants $Tenants -Force
    }
    catch {
        & $add 'Sign-in' 'FAIL' (Format-ErrorDetail $_)
        & $stop 'Permission'
        return $results.ToArray()
    }
    $header = $global:AuthenticationHeader
    if (-not $header) {
        & $add 'Sign-in' 'FAIL' 'the sign-in ran through but left no token'
        & $stop 'Permission'
        return $results.ToArray()
    }
    & $add 'Sign-in' 'OK' 'token received'

    # 3. Rechte (aus dem Token) und 5. Tenant
    $claims = Get-AccessTokenClaims -Header $header
    if (-not $claims) {
        & $add 'Permission' 'WARN' 'the token is not readable - cannot tell which permissions it carries'
    }
    else {
        $granted = @()
        if ($claims.PSObject.Properties.Name -contains 'roles') { $granted += @($claims.roles) }
        if ($claims.PSObject.Properties.Name -contains 'scp')   { $granted += @(([string]$claims.scp) -split '\s+') }
        $granted = @($granted | Where-Object { $_ })
        if ($granted -contains $script:TenantCheckRole) {
            & $add 'Permission' 'OK' ("{0} granted" -f $script:TenantCheckRole)
        }
        elseif ($granted.Count -eq 0) {
            & $add 'Permission' 'WARN' 'the token carries no permission claims - cannot tell what it may do'
        }
        else {
            & $add 'Permission' 'FAIL' ("{0} is missing (granted: {1}) - add it to the app registration and grant admin consent" -f $script:TenantCheckRole, ($granted -join ', '))
        }
    }

    # 4. Lesen
    try {
        $probe = Invoke-RestMethod -Method Get -Uri 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?$top=1&$select=id' -Headers $header -ErrorAction Stop
        & $add 'Read access' 'OK' 'the app list of the tenant can be read'
    }
    catch {
        & $add 'Read access' 'FAIL' (Format-ErrorDetail $_)
    }

    # 5. Tenant: eingetragen als Name (Domaene) oder als GUID - nur die GUID laesst sich sicher vergleichen
    if ($claims -and $claims.tid) {
        $configured = [guid]::Empty
        if ([guid]::TryParse([string]$Tenant.name, [ref]$configured)) {
            if ($configured -eq [guid]$claims.tid) { & $add 'Tenant' 'OK' ("token tenant {0}" -f $claims.tid) }
            else { & $add 'Tenant' 'FAIL' ("the token belongs to tenant {0}, the entry says {1}" -f $claims.tid, $Tenant.name) }
        }
        else {
            & $add 'Tenant' 'OK' ("token tenant {0} (the entry is a name, not compared)" -f $claims.tid)
        }
    }
    else {
        & $add 'Tenant' 'WARN' 'the token names no tenant'
    }

    return $results.ToArray()
}

function Format-TenantCheck {
    <# Das Ergebnis von Test-TenantConfiguration als Text fuer Fenster und Konsole. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Results, [string]$TenantName = '')

    $lines = foreach ($r in @($Results)) { '[{0,-4}] {1,-11} {2}' -f $r.Status, $r.Check, $r.Detail }
    $failed = @($Results | Where-Object { $_.Status -eq 'FAIL' }).Count
    $verdict = if ($failed -gt 0) { "$failed step(s) failed - the tenant cannot be used as it is." }
               elseif (@($Results | Where-Object { $_.Status -eq 'WARN' }).Count -gt 0) { 'Usable, with remarks.' }
               else { 'The tenant is ready for Deploy.' }
    return ("Tenant {0}`n`n{1}`n`n{2}" -f $TenantName, ($lines -join "`n"), $verdict)
}

function Invoke-TenantCheck {
    <#
        Der Weg des Knopfes "Check tenant": pruefen, auf der Konsole und im Fenster berichten.
        Gibt die Ergebnisse zurueck. Der Tenant danach ist angemeldet, wenn die Anmeldung gelang.
    #>
    [CmdletBinding()]
    param($Tenant, [Parameter(Mandatory = $true)]$Tenants)

    if (-not $Tenant) {
        $null = Show-ConfirmDialog -Text 'Choose a tenant first (list at the top left).' -Title 'Check tenant' -Buttons OK -Icon Information
        return $null
    }
    # Die Pruefung meldet sich neu an. Scheitert sie, gilt wieder das Token von vorher - sonst bliebe ein Token
    # des geprueften Tenants stehen, waehrend das Fenster einen anderen zeigt.
    $previous = $global:AuthenticationHeader
    $results = @(Test-TenantConfiguration -Tenant $Tenant -Tenants $Tenants)
    if (@($results | Where-Object { $_.Status -eq 'FAIL' }).Count -gt 0) { $global:AuthenticationHeader = $previous }
    $text = Format-TenantCheck -Results $results -TenantName ([string]$Tenant.name)
    Write-Host $text
    $failed = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
    $null = Show-ConfirmDialog -Text $text -Title 'Check tenant' -Buttons OK -Icon $(if ($failed -gt 0) { 'Error' } else { 'Information' })
    return $results
}
