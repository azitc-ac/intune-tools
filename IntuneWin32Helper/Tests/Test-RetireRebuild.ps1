<#
    .SYNOPSIS
    Verhaltenstest: Retire und Rebuild loeschen in Intune nur, was sie sollen - und merken,
    wenn das Loeschen nicht gewirkt hat.

    .DESCRIPTION
    Loeschen in Intune laesst sich nicht zuruecknehmen. Geprueft wird, ohne Tenant und ohne Netz:

      1. Welche Ids geloescht werden: nur Apps mit Name UND Version der Zeile, aus dem frisch
         gelesenen Tenant (nicht aus dem Stand des Fensters); eine andere Version derselben App
         bleibt; bei Dubletten alle, einzeln in der Rueckfrage genannt.
      2. Die Rueckfrage nennt jede App (Id, Inhalt, Zuweisungen) und warnt; "Nein" und ein nicht
         lesbarer Tenant loeschen nichts.
      3. Das Modul warnt bei einem fehlgeschlagenen Loeschen nur (kein throw). Das Ergebnis
         unterscheidet darum Removed / StillListed / Failed / Unverified - "Kommando lief durch"
         wird nicht als "App ist weg" gemeldet.
      4. Rebuild: erst bauen, dann loeschen, dann anlegen. Scheitert der Bau, bleibt Intune
         unangetastet; bleibt die alte App stehen, wird keine neue angelegt (Dublette).

    Das Modul wird nachgebaut (Remove-IntuneWin32App, Get-IntuneWin32AppAssignment, mit dem
    echten Verhalten "warnt statt zu werfen"); Invoke-IntuneModuleCall, Inventar, Plan, Loeschen
    und Pruefen laufen echt.
#>
$ErrorActionPreference = 'Stop'

$rootDir = Split-Path -Parent $PSScriptRoot
$functionsPath = Join-Path $rootDir 'Functions\functions.ps1'

$ast = [System.Management.Automation.Language.Parser]::ParseFile($functionsPath, [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}

$problems = @()
function Test-That([bool]$condition, [string]$what) { if (-not $condition) { $script:problems += $what } }

$current = Get-TemplateFingerprint -RootDir $rootDir
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('iw32h-retire-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $work
$packets = Join-Path $work 'packets'
$null = New-Item -ItemType Directory -Force -Path $packets

function New-App([string]$name, [string]$version, [string]$id = '', [string]$content = '1', [string]$state = 'published') {
    [pscustomobject]@{ id = $(if ($id) { $id } else { "id-$name-$version" }); displayName = $name; displayVersion = $version; publishingState = $state
                       committedContentVersion = $content; createdDateTime = '2026-10-01T10:00:00Z' }
}
function New-TestPackage([string]$name, [string]$version) {
    $folder = Join-Path $packets "$name - $version"
    $null = New-Item -ItemType Directory -Force -Path $folder
    Write-DeployScript -AppFolder $folder -AppName $name -AppVersion $version -Publisher 'Test' -Description 'Installed using PSADT' `
        -RootDir $rootDir -ToolVersion '0.0.1' -Architecture 'x64' -MinimumOS 'W10_20H2' -MsiProductCode '' 6>$null
}

# ---- Mocks fuer Netz und Windows; das Modul wird nachgebaut --------------------------------
$script:tenantApps = @(); $script:tenantReadable = $true; $script:defs = @()
$script:events = @(); $script:asked = @(); $script:answer = 'Yes'
$script:stuck = @(); $script:throwFor = @(); $script:assignments = @{}; $script:assignWarn = @()
$script:failBuild = @(); $script:buildRemoveExisting = $null; $script:deployed = @(); $script:deploySkipped = @(); $script:deployCalls = 0

function Read-TenantWin32Apps { $script:events += 'read'; if (-not $script:tenantReadable) { return $null }; return , @($script:tenantApps) }
function Read-AppsCsv { param($RootDir) return @($script:defs) }

function Remove-IntuneWin32App {
    [CmdletBinding()] param([string]$ID)
    $script:events += "remove:$ID"
    if ($script:throwFor -contains $ID) { throw 'simulated failure' }
    if ($script:stuck -contains $ID) {
        # wie das Modul 1.5.0: catch -> Write-Warning, KEIN throw, die App bleibt
        Write-Warning "An error occurred while deleting Win32 app with ID: $ID. Error message: Forbidden"
        return
    }
    $script:tenantApps = @($script:tenantApps | Where-Object { $_.id -ne $ID })
}
function Get-IntuneWin32AppAssignment {
    [CmdletBinding()] param([string]$ID)
    if ($script:assignWarn -contains $ID) { Write-Warning "An error occurred while retrieving Win32 app assignments for app with ID: $ID"; return }
    if ($script:assignments.ContainsKey($ID)) { return $script:assignments[$ID] }
}
function Invoke-PackageBuild {
    param($Rows, $PacketRoot, $RootDir, $ToolVersion, $RemoveExisting)
    $script:events += 'build'
    $script:buildRemoveExisting = $RemoveExisting
    $ok = @($Rows | Where-Object { $script:failBuild -notcontains $_.Key })
    $bad = @($Rows | Where-Object { $script:failBuild -contains $_.Key } | ForEach-Object { $_.Key })
    $b = foreach ($row in $ok) { [pscustomobject]@{ AppName = $row.AppName; AppVersion = $row.AppVersion; FullPath = ('C:\fake\{0}\deploy.ps1' -f $row.Key) } }
    return [pscustomobject]@{ Built = @($b); Failed = @($bad) }
}
function Invoke-PackageDeploy {
    param($Packages, $Tenant, $RootDir, $ToolVersion, [string[]]$Skipped = @())
    $script:events += 'deploy'
    $script:deployCalls++
    $script:deployed = @($Packages)
    $script:deploySkipped = @($Skipped)
}
$ask = { param($Text, $Buttons) $script:asked += [pscustomobject]@{ Text = $Text; Buttons = $Buttons }; return $script:answer }
$tenant = [pscustomobject]@{ name = 't' }

function Reset-Run {
    $script:events = @(); $script:asked = @(); $script:answer = 'Yes'; $script:stuck = @(); $script:throwFor = @()
    $script:assignWarn = @(); $script:failBuild = @(); $script:deployed = @(); $script:deploySkipped = @(); $script:deployCalls = 0
    $script:tenantReadable = $true
}
function Get-RemovedIds { @($script:events | Where-Object { $_ -like 'remove:*' } | ForEach-Object { $_.Substring(7) } | Sort-Object) }

try {
    foreach ($spec in @(@('Have', '1.0'), @('Dup', '1.0'), @('Other', '2.0'), @('Fresh', '1.0'), @('BuildFail', '1.0'), @('Stuck', '1.0'), @('Ghost', '1.0'))) { New-TestPackage $spec[0] $spec[1] }
    $script:defs = @(
        [pscustomobject]@{ DisplayName = 'Have';      Version = '1.0' },
        [pscustomobject]@{ DisplayName = 'Dup';       Version = '1.0' },
        [pscustomobject]@{ DisplayName = 'Other';     Version = '2.0' },
        [pscustomobject]@{ DisplayName = 'Fresh';     Version = '1.0' },
        [pscustomobject]@{ DisplayName = 'BuildFail'; Version = '1.0' },
        [pscustomobject]@{ DisplayName = 'Stuck';     Version = '1.0' },
        [pscustomobject]@{ DisplayName = 'Ghost';     Version = '1.0' }
    )
    $resetTenant = {
        $script:tenantApps = @(
            (New-App 'Have' '1.0'),
            (New-App 'Dup' '1.0' 'dup-a'), (New-App 'Dup' '1.0' 'dup-b'),
            (New-App 'Other' '1.0'),                       # andere Version: darf NIE geloescht werden
            (New-App 'BuildFail' '1.0'),
            (New-App 'Stuck' '1.0' 'stuck-1'),
            (New-App 'Ghost' '1.0' 'ghost-1' '' 'notPublished'),
            (New-App 'Unrelated' '9.9')
        )
        $script:assignments = @{ 'id-Have-1.0' = @([pscustomobject]@{ GroupName = 'g1' }, [pscustomobject]@{ GroupName = 'g2' }) }
    }
    & $resetTenant
    $stale = @(Get-AppInventory -Definitions $script:defs -PacketRoot $packets -RootDir $rootDir -IntuneApps @() 6>$null)   # Fenster mit leerem Intune
    $pick = { param([string[]]$names) @($stale | Where-Object { $names -contains $_.AppName }) }

    # ------------------------------------------------------------------ Retire
    Reset-Run; & $resetTenant
    $res = Invoke-InventoryRetire -Selection (& $pick 'Have', 'Dup', 'Other') -RootDir $rootDir -PacketRoot $packets -Ask $ask 6>$null
    Test-That (((Get-RemovedIds) -join ',') -eq 'dup-a,dup-b,id-Have-1.0') "retire: removed [$((Get-RemovedIds) -join ',')], expected [dup-a,dup-b,id-Have-1.0]"
    Test-That (@($script:tenantApps | Where-Object { $_.displayName -eq 'Other' }).Count -eq 1) "retire: the OTHER version of an app was deleted"
    Test-That (@($script:tenantApps | Where-Object { $_.displayName -eq 'Unrelated' }).Count -eq 1) "retire: an unrelated app was deleted"
    Test-That (@($res | Where-Object { $_.State -eq 'Removed' }).Count -eq 3) "retire: expected 3 x Removed, got: $(@($res | ForEach-Object { $_.State }) -join ',')"
    Test-That ($script:asked.Count -eq 1 -and $script:asked[0].Buttons -eq 'YesNo') "retire: expected one YesNo question, got $($script:asked.Count) ($($script:asked[0].Buttons))"
    $q = [string]$script:asked[0].Text
    foreach ($needle in 'id-Have-1.0', 'dup-a', 'dup-b', 'assignments: 2', 'ALL are deleted', 'cannot be undone', 'AND their assignments') {
        Test-That ($q -match [regex]::Escape($needle)) "retire: the question lacks '$needle'"
    }
    Test-That ($q -notmatch 'Other') "retire: the question names an app that is not deleted (Other 1.0 is another version)"
    Test-That ((@($script:events | Where-Object { $_ -eq 'read' }).Count) -ge 2) "retire: the tenant was not read again after deleting (no verification)"

    # Fenster-Stand veraltet: die Id im Fenster gibt es nicht mehr - geloescht wird die aus dem frischen Stand.
    Reset-Run; & $resetTenant
    $staleWithApp = @(Get-AppInventory -Definitions $script:defs -PacketRoot $packets -RootDir $rootDir -IntuneApps @((New-App 'Have' '1.0' 'old-window-id')) 6>$null | Where-Object { $_.AppName -eq 'Have' })
    $null = Invoke-InventoryRetire -Selection $staleWithApp -RootDir $rootDir -PacketRoot $packets -Ask $ask 6>$null
    Test-That (((Get-RemovedIds) -join ',') -eq 'id-Have-1.0') "retire (stale window): removed [$((Get-RemovedIds) -join ',')], expected only the id from the fresh read"

    # Nein / nicht lesbarer Tenant / nichts zu loeschen
    Reset-Run; & $resetTenant; $script:answer = 'No'
    $res = Invoke-InventoryRetire -Selection (& $pick 'Have') -RootDir $rootDir -PacketRoot $packets -Ask $ask 6>$null
    Test-That ((Get-RemovedIds).Count -eq 0 -and $null -eq $res) "retire (No): something was removed or a result returned"
    Reset-Run; & $resetTenant; $script:tenantReadable = $false
    $res = Invoke-InventoryRetire -Selection (& $pick 'Have') -RootDir $rootDir -PacketRoot $packets -Ask $ask 6>$null
    Test-That ((Get-RemovedIds).Count -eq 0 -and $script:asked.Count -eq 0) "retire (tenant unreadable): removed $((Get-RemovedIds).Count), questions $($script:asked.Count) - expected nothing"
    Reset-Run; & $resetTenant
    $res = Invoke-InventoryRetire -Selection (& $pick 'Fresh') -RootDir $rootDir -PacketRoot $packets -Ask $ask 6>$null
    Test-That ((Get-RemovedIds).Count -eq 0 -and $script:asked.Count -eq 1 -and $script:asked[0].Buttons -eq 'OK') "retire (nothing in Intune): removed $((Get-RemovedIds).Count), asked '$($script:asked[0].Buttons)'"

    # Das Modul warnt statt zu loeschen: das darf nicht als "Removed" durchgehen.
    Reset-Run; & $resetTenant; $script:stuck = @('stuck-1'); $script:throwFor = @('dup-b')
    $res = Invoke-InventoryRetire -Selection (& $pick 'Stuck', 'Dup') -RootDir $rootDir -PacketRoot $packets -Ask $ask 6>$null
    $state = @{}; foreach ($x in $res) { $state[$x.Id] = $x }
    Test-That ($state['stuck-1'].State -eq 'StillListed' -and $state['stuck-1'].Detail -match 'Forbidden') "retire (module warns): stuck-1 is '$($state['stuck-1'].State)' / '$($state['stuck-1'].Detail)', expected StillListed with the warning"
    Test-That ($state['dup-b'].State -eq 'Failed' -and $state['dup-b'].Detail -match 'simulated') "retire (call throws): dup-b is '$($state['dup-b'].State)'"
    Test-That ($state['dup-a'].State -eq 'Removed') "retire: dup-a is '$($state['dup-a'].State)', expected Removed (one failure must not stop the others)"

    # Nach dem Loeschen laesst sich der Tenant nicht lesen: unbestaetigt, nicht "Removed".
    Reset-Run; & $resetTenant
    $unreadableAfter = { param($Text, $Buttons) $script:asked += [pscustomobject]@{ Text = $Text; Buttons = $Buttons }; $script:tenantReadable = $false; return 'Yes' }
    $res = Invoke-InventoryRetire -Selection (& $pick 'Have') -RootDir $rootDir -PacketRoot $packets -Ask $unreadableAfter 6>$null
    Test-That (@($res).Count -eq 1 -and @($res)[0].State -eq 'Unverified') "retire (tenant unreadable afterwards): state '$(@($res)[0].State)', expected Unverified"

    # Zuweisungen nicht lesbar: die Rueckfrage sagt es, statt "0" zu behaupten.
    Reset-Run; & $resetTenant; $script:assignWarn = @('id-Have-1.0')
    $null = Invoke-InventoryRetire -Selection (& $pick 'Have') -RootDir $rootDir -PacketRoot $packets -Ask $ask 6>$null
    Test-That ($script:asked[0].Text -match 'could not be read') "retire (assignments unreadable): the question does not say so"
    Test-That ($script:asked[0].Text -notmatch 'assignments: 0') "retire (assignments unreadable): the question claims 0 assignments"

    # Eine Zeile ohne gelesenen Tenant-Stand wird nicht geplant.
    $threw = $false
    try { $null = @(Get-RetirePlan -Rows @(Get-AppInventory -Definitions $script:defs[0..0] -PacketRoot $packets -RootDir $rootDir -IntuneApps $null 6>$null)) } catch { $threw = $true }
    Test-That $threw "retire plan: a row whose Intune state was not read was planned"

    # ------------------------------------------------------------------ Rebuild
    Reset-Run; & $resetTenant; $script:failBuild = @('BuildFail - 1.0'); $script:stuck = @('stuck-1')
    $orphanPkg = $null
    $selection = & $pick 'Have', 'Fresh', 'BuildFail', 'Stuck', 'Ghost'
    $res = Invoke-InventoryRebuild -Selection $selection -Tenant $tenant -RootDir $rootDir -PacketRoot $packets -ToolVersion '0.0.1' -Ask $ask 6>$null
    $evt = $script:events
    $iBuild = [array]::IndexOf($evt, 'build')
    $firstRemove = @($evt | Where-Object { $_ -like 'remove:*' } | Select-Object -First 1)
    $iRemove = $(if ($firstRemove) { [array]::IndexOf($evt, $firstRemove[0]) } else { -1 })
    $iDeploy = [array]::IndexOf($evt, 'deploy')
    Test-That ($iBuild -ge 0 -and $iRemove -gt $iBuild -and $iDeploy -gt $iRemove) "rebuild: order must be build -> remove -> deploy, events: $($evt -join ' > ')"
    Test-That ($script:buildRemoveExisting -eq $true) "rebuild: the package was not rebuilt from scratch (RemoveExisting=$($script:buildRemoveExisting))"
    Test-That (((Get-RemovedIds) -join ',') -eq 'ghost-1,id-Have-1.0,stuck-1') "rebuild: removal attempted for [$((Get-RemovedIds) -join ',')], expected [ghost-1,id-Have-1.0,stuck-1] (BuildFail must not be touched)"
    Test-That (@($script:tenantApps | Where-Object { $_.displayName -eq 'BuildFail' }).Count -eq 1) "rebuild: the app of a row whose build failed was deleted from Intune"
    $deployedKeys = @($script:deployed | ForEach-Object { '{0} - {1}:{2}' -f $_.AppName, $_.AppVersion, $_.Mode } | Sort-Object)
    Test-That (($deployedKeys -join ',') -eq 'Fresh - 1.0:New,Ghost - 1.0:New,Have - 1.0:New') "rebuild: created [$($deployedKeys -join ', ')], expected [Fresh, Ghost, Have as New]"
    $skipText = $script:deploySkipped -join ' | '
    Test-That ($skipText -match 'BuildFail - 1\.0: the build failed - Intune was not touched') "rebuild: skipped list lacks the build failure ($skipText)"
    Test-That ($skipText -match 'Stuck - 1\.0: the old app could not be removed' -and $skipText -match 'duplicate') "rebuild: skipped list lacks the stuck app ($skipText)"
    Test-That ($script:asked.Count -eq 1 -and $script:asked[0].Buttons -eq 'YesNo' -and $script:asked[0].Text -match 'assignments: 2' -and $script:asked[0].Text -match 'only after the build worked') "rebuild: the question is missing the plan or the assignment count"

    Reset-Run; & $resetTenant; $script:answer = 'No'
    $res = Invoke-InventoryRebuild -Selection (& $pick 'Have') -Tenant $tenant -RootDir $rootDir -PacketRoot $packets -ToolVersion '0.0.1' -Ask $ask 6>$null
    Test-That (($script:events -contains 'build') -eq $false -and (Get-RemovedIds).Count -eq 0 -and $script:deployCalls -eq 0) "rebuild (No): something happened: $($script:events -join ' > ')"

    Reset-Run; & $resetTenant; $script:tenantReadable = $false
    $res = Invoke-InventoryRebuild -Selection (& $pick 'Have') -Tenant $tenant -RootDir $rootDir -PacketRoot $packets -ToolVersion '0.0.1' -Ask $ask 6>$null
    Test-That (($script:events -contains 'build') -eq $false -and $script:asked.Count -eq 0 -and $script:deployCalls -eq 0) "rebuild (tenant unreadable): something happened: $($script:events -join ' > ')"

    Reset-Run; & $resetTenant
    $orphanRow = [pscustomobject]@{ Key = 'Nobody - 1.0'; AppName = 'Nobody'; AppVersion = '1.0'; HasDefinition = $false; HasPackage = $true; Intune = 'yes' }
    $res = Invoke-InventoryRebuild -Selection @($orphanRow) -Tenant $tenant -RootDir $rootDir -PacketRoot $packets -ToolVersion '0.0.1' -Ask $ask 6>$null
    Test-That (($script:events -contains 'build') -eq $false -and (Get-RemovedIds).Count -eq 0) "rebuild (no definition): something happened: $($script:events -join ' > ')"

    # Alle Bauten scheitern: Intune bleibt vollstaendig unangetastet.
    Reset-Run; & $resetTenant; $script:failBuild = @('Have - 1.0', 'Dup - 1.0')
    $res = Invoke-InventoryRebuild -Selection (& $pick 'Have', 'Dup') -Tenant $tenant -RootDir $rootDir -PacketRoot $packets -ToolVersion '0.0.1' -Ask $ask 6>$null
    Test-That ((Get-RemovedIds).Count -eq 0 -and $script:deployCalls -eq 0) "rebuild (all builds fail): removed $((Get-RemovedIds).Count), deploy calls $($script:deployCalls) - expected nothing in Intune"
}
finally {
    foreach ($pkg in @(Get-ChildItem -LiteralPath $packets -Directory -ErrorAction SilentlyContinue)) {
        try { $null = Remove-PackageFolder -Path $pkg.FullName -PacketRoot $packets } catch { $problems += "cleanup: $($_.Exception.Message)" }
    }
    Remove-Item -LiteralPath $packets -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $work) { $problems += "cleanup: $work is not empty" }
}

if ($problems.Count -gt 0) {
    foreach ($pr in $problems) { [Console]::WriteLine("FAIL: $pr") }
    exit 1
}
[Console]::WriteLine("Retire/Rebuild: only name+version apps from the fresh tenant are deleted, the question names each one, a delete that only warns is not reported as removed, rebuild goes build -> delete -> create and never leaves a duplicate. PASS")
exit 0
