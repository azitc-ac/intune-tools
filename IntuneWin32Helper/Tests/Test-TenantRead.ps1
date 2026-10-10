<#
    .SYNOPSIS
    Verhaltenstest: Read-TenantWin32Apps und Get-TenantAppAssignmentInfo lesen direkt ueber Graph.

    .DESCRIPTION
    Beides stand zuerst auf den Cmdlets des Moduls IntuneWin32App (1.5.0) und lieferte im Feldtest
    (2026-10-10) falsche Antworten:
      - Get-IntuneWin32App fuehrte eine gerade angelegte App erst nach 40 bis 120 Sekunden;
        die einfache Liste (ohne Filter isof) schon nach wenigen. Ein zweiter Deploy in dieser
        Luecke haette eine Dublette angelegt.
      - Get-IntuneWin32AppAssignment meldete fuer eine App mit einer "alle Benutzer"-Zuweisung keine.
    Geprueft wird, ohne Netz (Invoke-RestMethod ist nachgebaut): nur Win32-Apps kommen zurueck, alle
    Seiten werden gelesen, ohne Token und bei einem Graph-Fehler ist das Ergebnis "nicht gelesen"
    ($null bzw. Known = $false) und nicht "leer" bzw. "0", und die Zuweisungen werden gezaehlt.
#>
$ErrorActionPreference = 'Stop'

$rootDir = Split-Path -Parent $PSScriptRoot
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $rootDir 'Functions\functions.ps1'), [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}

$problems = @()
function Test-That([bool]$condition, [string]$what) { if (-not $condition) { $script:problems += $what } }

$script:calls = @(); $script:fail = $false
function Invoke-RestMethod {
    [CmdletBinding()] param([string]$Method, [string]$Uri, $Headers)
    $script:calls += $Uri
    if ($script:fail) { throw 'simulated Graph error' }
    if ($Uri -match '/mobileApps/([^/]+)/assignments') {
        if ($Matches[1] -eq 'one')  { return [pscustomobject]@{ value = @([pscustomobject]@{ intent = 'available' }) } }
        if ($Matches[1] -eq 'two')  { return [pscustomobject]@{ value = @([pscustomobject]@{ intent = 'required' }, [pscustomobject]@{ intent = 'available' }) } }
        return [pscustomobject]@{ value = @() }
    }
    if ($Uri -match 'page=2') {
        return [pscustomobject]@{ value = @([pscustomobject]@{ '@odata.type' = '#microsoft.graph.win32LobApp'; id = 'c'; displayName = 'C' }) }
    }
    $page1 = [pscustomobject]@{
        value = @(
            [pscustomobject]@{ '@odata.type' = '#microsoft.graph.win32LobApp'; id = 'a'; displayName = 'A'; displayVersion = '1.0' },
            [pscustomobject]@{ '@odata.type' = '#microsoft.graph.iosStoreApp'; id = 'x'; displayName = 'Phone app' },
            [pscustomobject]@{ '@odata.type' = '#microsoft.graph.win32CatalogApp'; id = 'cat'; displayName = 'Catalog app' },
            [pscustomobject]@{ '@odata.type' = '#microsoft.graph.win32LobApp'; id = 'b'; displayName = 'B'; displayVersion = '2.0' }
        )
    }
    $page1 | Add-Member -NotePropertyName '@odata.nextLink' -NotePropertyValue 'https://graph.example/mobileApps?page=2'
    return $page1
}

try {
    # ---- Liste ----
    $global:AuthenticationHeader = @{ Authorization = 'Bearer test' }
    $apps = Read-TenantWin32Apps 6>$null
    Test-That ($null -ne $apps) 'list: returned $null although Graph answered'
    Test-That (@($apps).Count -eq 4) "list: expected 3 Win32 apps over 2 pages (2 Win32 + 1 catalog app + 1 on page 2), got $(@($apps).Count)"
    Test-That ((@($apps | ForEach-Object { $_.id }) -join ',') -eq 'a,cat,b,c') "list: ids [$((@($apps | ForEach-Object { $_.id }) -join ','))], expected a,cat,b,c (a non-Win32 app slipped in, the catalog app is missing or a page was skipped)"
    Test-That ($apps[0].displayVersion -eq '1.0') 'list: the Graph properties are not on the objects'
    Test-That (@($script:calls | Where-Object { $_ -match 'isof' }).Count -eq 0) 'list: uses the isof filter again - the filtered list lags behind new apps'

    $script:fail = $true
    Test-That ($null -eq (Read-TenantWin32Apps 6>$null)) 'list: a Graph error was reported as an (empty) list instead of $null'
    $script:fail = $false
    $global:AuthenticationHeader = $null
    Test-That ($null -eq (Read-TenantWin32Apps 6>$null)) 'list: without a token the result was not $null'
    $global:AuthenticationHeader = @{ Authorization = 'Bearer test' }

    # ---- Zuweisungen ----
    foreach ($case in @(@('one', 1), @('two', 2), @('none', 0))) {
        $info = Get-TenantAppAssignmentInfo -Id $case[0]
        Test-That ($info.Known -and $info.Count -eq $case[1]) "assignments '$($case[0])': Count=$($info.Count) Known=$($info.Known), expected $($case[1]) / known"
    }
    $script:fail = $true
    $info = Get-TenantAppAssignmentInfo -Id 'one'
    Test-That (-not $info.Known) 'assignments: a Graph error was reported as known'
    $script:fail = $false
    $global:AuthenticationHeader = $null
    $info = Get-TenantAppAssignmentInfo -Id 'one'
    Test-That (-not $info.Known) 'assignments: without a token the count was reported as known'
}
finally {
    $global:AuthenticationHeader = $null
}

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { [Console]::WriteLine("FAIL: $p") }
    exit 1
}
[Console]::WriteLine('Tenant read: Win32 apps over all pages straight from Graph (no lagging filter), errors and a missing token mean "not read", assignments are counted. PASS')
exit 0
