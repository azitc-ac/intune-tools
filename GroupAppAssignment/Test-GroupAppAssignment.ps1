<#
.SYNOPSIS
    Checks for Manage-GroupAppAssignment.ps1 - no Graph, no GUI, no Pester needed.
    Exit code 0 = all passed. Runs on Windows PowerShell 5.1 and PowerShell 7.

    1. Static: every .ps1 in this folder is UTF-8 with BOM, uses no syntax that Windows
       PowerShell 5.1 cannot parse (?? ?. ?: && || ??=) and calls AddRange(@(...)) only on
       .Controls (5.1 does not bind an object[] to a params array such as Columns.AddRange).
    2. Logic: categories, platforms, requested permissions, target matching, request bodies, the
       add / change / remove plan, sorting.
    3. Graph paths with a mocked Invoke-MgGraphRequest: loading (with and without $expand), reading
       back, and writing - one assignment at a time and as a complete list (/assign), where the
       assignments of OTHER targets must survive.
#>
$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:fail = 0
$script:pass = 0

function Assert {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $Name" -ForegroundColor Red }
}

#region Static checks
$ps7Only = @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')
foreach ($f in Get-ChildItem -Path $here -Filter *.ps1) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    Assert ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) "$($f.Name): UTF-8 BOM"

    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    Assert (@($errors).Count -eq 0) "$($f.Name): parses without errors ($(@($errors) -join '; '))"
    $bad = @($tokens | Where-Object { $ps7Only -contains $_.Kind.ToString() })
    foreach ($t in $bad) { Assert $false "$($f.Name): PS 5.1-incompatible token '$($t.Text)' at line $($t.Extent.StartLineNumber)" }
    if (-not $bad) { Assert $true "$($f.Name): no PS 7-only operators" }

    # AddRange(@(...)) only on .Controls: other AddRange overloads (DataGridView Columns, Items, ...)
    # take a params array that Windows PowerShell 5.1 does not bind from an object[] - pwsh 7 does,
    # so only this check catches it here.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
    $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                                     $n.Member.Extent.Text -eq 'AddRange' }, $true)
    foreach ($c in $calls) {
        Assert ($c.Expression.Extent.Text -match '\.Controls$') "$($f.Name): AddRange only on .Controls (line $($c.Extent.StartLineNumber): $($c.Expression.Extent.Text).AddRange)"
    }
}

# No function of the tool may carry the name of a command or alias of Microsoft.Graph.Authentication:
# an alias wins over a function once the module is loaded ("Connect-Graph" broke "Reconnect" this way).
# Names from the module manifest (msgraph-sdk-powershell, src/Authentication/.../Microsoft.Graph.Authentication.psd1).
$graphModuleNames = @(
    'Connect-MgGraph', 'Disconnect-MgGraph', 'Get-MgContext', 'Invoke-MgGraphRequest', 'Add-MgEnvironment',
    'Get-MgEnvironment', 'Remove-MgEnvironment', 'Set-MgEnvironment', 'Get-MgRequestContext', 'Set-MgRequestContext',
    'Set-MgGraphOption', 'Get-MgGraphOption', 'Find-MgGraphCommand', 'Find-MgGraphPermission',
    'Connect-Graph', 'Disconnect-Graph', 'Invoke-GraphRequest', 'Invoke-MgRestMethod')
$toolAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $here 'Manage-GroupAppAssignment.ps1'), [ref]$null, [ref]$null)
$toolFunctions = @($toolAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
$clash = @($toolFunctions | Where-Object { $graphModuleNames -contains $_ })

# The account line (text + green check mark) is set in Set-AccountDisplay only, so both always agree
$guiText = [System.IO.File]::ReadAllText((Join-Path $here 'Manage-GroupAppAssignment.ps1'))
$accSets = [regex]::Matches($guiText, '\$(lblAccount\.Text|lblConnected\.Visible)\s*=')
$fnAcc = $toolAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-AccountDisplay' }, $true) | Select-Object -First 1
$inside = @($accSets | Where-Object { $fnAcc -and $_.Index -ge $fnAcc.Extent.StartOffset -and $_.Index -lt $fnAcc.Extent.EndOffset }).Count
Assert ($fnAcc -and ($accSets.Count - $inside) -eq 2) "account line set only in Set-AccountDisplay (outside: $($accSets.Count - $inside), expected 2 initial values)"

# Both grids drop the selection they make by themselves when filled (else a button acts on an unpicked row)
foreach ($g in 'grid', 'gridLeft') {
    Assert ($guiText -match ('\$' + $g + '\.CurrentCell = \$null; \$' + $g + '\.ClearSelection\(\)')) "$g clears its automatic selection after filling"
}

# Every visible text of the window comes from the de/en tables: no literal .Text / .HeaderText / message
# box text / list item in the GUI part (only "..." for the picker button is allowed).
$guiPart = $mainText = [System.IO.File]::ReadAllText((Join-Path $here 'Manage-GroupAppAssignment.ps1'))
$guiPart = $guiPart.Substring($guiPart.IndexOf('# ---- end of the GUI-free part'))
$literal = [regex]::Matches($guiPart, "(\.(Text|HeaderText)\s*=\s*['""][^'""]*[A-Za-z\u00C0-\u017F][^'""]*['""])|(MessageBox\]::Show\(\s*['""])|(Items\.Add\(\s*['""][A-Za-z])")
Assert ($literal.Count -eq 0) "no hard-coded visible text in the GUI ($(@($literal | ForEach-Object { $_.Value }) -join ' | '))"
Assert ($toolFunctions.Count -gt 20 -and $clash.Count -eq 0) "no function name collides with the Graph module ($($clash -join ', '))"
#endregion

#region Logic
# Only the part above the marker line: the GUI part needs Windows Forms / System.Drawing.
$main   = [System.IO.File]::ReadAllText((Join-Path $here 'Manage-GroupAppAssignment.ps1'))
$marker = '# ---- end of the GUI-free part'
$cut    = $main.IndexOf($marker)
Assert ($cut -gt 0) 'marker line for the GUI-free part exists'
. ([scriptblock]::Create($main.Substring(0, $cut))) -Language en

# Every text the script uses ($L.Key) exists in German and English, both sets have the same keys, none unused.
$usedKeys = @([regex]::Matches($main, '\$L\.([A-Za-z]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
foreach ($k in $usedKeys) {
    Assert ($strings.de.ContainsKey($k) -and $strings.en.ContainsKey($k)) "text '$k' exists in de and en"
}
Assert (@(Compare-Object @($strings.de.Keys) @($strings.en.Keys)).Count -eq 0) 'de and en have the same text keys'
Assert (@($strings.de.Keys | Where-Object { $usedKeys -notcontains $_ }).Count -eq 0) "no unused text keys ($(@($strings.de.Keys | Where-Object { $usedKeys -notcontains $_ }) -join ', '))"

$g1 = 'aaaaaaaa-0000-0000-0000-000000000001'
$g2 = 'aaaaaaaa-0000-0000-0000-000000000002'
$selG1  = New-Selection 'group' $g1 'G1'
$selAU  = New-Selection 'allUsers'
$selAD  = New-Selection 'allDevices'

$assignments = @(
    @{ id = 'as-1'; intent = 'required';  target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $g2 } },
    @{ id = 'as-2'; intent = 'available'; target = @{ '@odata.type' = '#microsoft.graph.exclusionGroupAssignmentTarget'; groupId = $g1 } },
    @{ id = 'as-3'; intent = 'required';  target = @{ '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget';
                                                     deviceAndAppManagementAssignmentFilterId = 'f-1'; deviceAndAppManagementAssignmentFilterType = 'include' };
       settings = @{ '@odata.type' = '#microsoft.graph.win32LobAppAssignmentSettings'; notifications = 'hideAll' } }
)

# Language: English by default, German for a German Windows display language, -Language overrides
Assert ((Get-UiLanguage 'auto' 'de-DE') -eq 'de' -and (Get-UiLanguage 'auto' 'de-AT') -eq 'de' -and (Get-UiLanguage 'auto' 'de') -eq 'de') 'language: German Windows -> de'
Assert ((Get-UiLanguage 'auto' 'en-US') -eq 'en' -and (Get-UiLanguage 'auto' 'fr-FR') -eq 'en' -and (Get-UiLanguage 'auto' '') -eq 'en') 'language: anything else -> en (default)'
Assert ((Get-UiLanguage 'en' 'de-DE') -eq 'en' -and (Get-UiLanguage 'de' 'en-US') -eq 'de') 'language: -Language overrides'

# Icons: every category (and "All") has one, and it is a real 48 x 48 PNG
foreach ($c in (Get-CategoryTable).Values) { Assert ($script:IconData.ContainsKey($c.Icon)) "category $($c.Key) has icon '$($c.Icon)'" }
Assert ($script:IconData.ContainsKey($script:AllIcon)) 'the "All" entry has an icon'
foreach ($k in $script:IconData.Keys) {
    $png = [Convert]::FromBase64String($script:IconData[$k])
    $isPng = ($png.Length -gt 24 -and $png[0] -eq 0x89 -and $png[1] -eq 0x50 -and $png[2] -eq 0x4E -and $png[3] -eq 0x47)
    $w = if ($isPng) { ($png[16] -shl 24) + ($png[17] -shl 16) + ($png[18] -shl 8) + $png[19] } else { 0 }
    Assert ($isPng -and $w -eq 48) "icon $k is a 48 px PNG"
}

# Permissions: by default only the two scopes an app-centric bulk tool asks for too (no new consent)
$def = Get-RequestedScopes
Assert (@($def).Count -eq 2 -and $def -contains 'DeviceManagementApps.ReadWrite.All' -and $def -contains 'Group.Read.All') 'default scopes: exactly DeviceManagementApps.ReadWrite.All + Group.Read.All'
Assert ($def -notcontains 'DeviceManagementConfiguration.Read.All') 'default scopes: no filter-names permission'
Assert ((Get-RequestedScopes $true) -contains 'DeviceManagementConfiguration.Read.All') 'filter names on request add DeviceManagementConfiguration.Read.All'
$cfg = Get-RequestedScopes $false $true
Assert ($cfg -contains 'DeviceManagementConfiguration.ReadWrite.All' -and $cfg.Count -eq 3) 'categories beyond apps add DeviceManagementConfiguration.ReadWrite.All'
Assert ((Get-RequestedScopes $true $true) -notcontains 'DeviceManagementConfiguration.Read.All') 'ReadWrite already covers the filter names'

# Matching: the exclusion of G1 belongs to G1, the include of G2 does not
$m = Find-AssignmentForSelection $assignments $selG1
Assert ($m.id -eq 'as-2') 'group target finds its exclusion assignment'
Assert ($null -eq (Find-AssignmentForSelection $assignments (New-Selection 'group' 'other'))) 'unrelated group finds nothing'
Assert ((Find-AssignmentForSelection $assignments $selAU).id -eq 'as-3') 'All users finds allLicensedUsers target'
Assert ($null -eq (Find-AssignmentForSelection $assignments $selAD)) 'All devices finds nothing here'
Assert ($null -eq (Find-AssignmentForSelection $null $selG1)) 'no assignments -> $null'

$st = ConvertTo-AssignmentState $m
Assert ($st.Exclude -eq $true -and $st.Intent -eq 'available' -and $st.AssignmentId -eq 'as-2') 'state of an exclusion'
$stAU = ConvertTo-AssignmentState (Find-AssignmentForSelection $assignments $selAU)
Assert ($stAU.Exclude -eq $false -and $stAU.FilterId -eq 'f-1' -and $stAU.FilterType -eq 'include') 'state keeps the filter'

# Any collection type: a List[object] once made @($x) throw "Argument types do not match"
$list = New-Object System.Collections.Generic.List[object]
foreach ($x in $assignments) { $list.Add($x) }
$hit = $null; try { $hit = Find-AssignmentForSelection $list $selG1 } catch { }
Assert ($hit.id -eq 'as-2') 'matching accepts a List[object]'

# Sign-out: Disconnect-MgGraph is called (it deletes the sign-in record that makes the next connect silent),
# without -SignOutFromBroker, and "no application to sign out from" does not stop the tool
$script:discon = @()
function Disconnect-MgGraph { param([switch]$SignOutFromBroker, $ErrorAction) $script:discon += [PSCustomObject]@{ Broker = [bool]$SignOutFromBroker }; if ($script:disconFail) { throw 'No application to sign out from.' } }
$script:disconFail = $false; Disconnect-GaaGraph
Assert ($script:discon.Count -eq 1 -and -not $script:discon[0].Broker) 'sign-out calls Disconnect-MgGraph, not from the Windows broker'
$script:disconFail = $true; $ok = $true; try { Disconnect-GaaGraph } catch { $ok = $false }
Assert $ok 'sign-out without a session does not throw'
Remove-Item Function:\Disconnect-MgGraph

# Graph paging and read-back, with Invoke-MgGraphRequest mocked: 0 / 1 / 2 assignments, two pages
function Invoke-MgGraphRequest {
    param($Method, $Uri, $Headers, $Body, $ContentType, $ErrorAction)
    $script:mockCalls++
    if ($Uri -like '*page2') { return @{ value = @(@{ id = 'p2' }) } }
    $v = @(); for ($k = 1; $k -le $script:mockCount; $k++) { $v += @{ id = "a$k" } }
    $r = @{ value = $v }
    if ($script:mockPaged) { $r['@odata.nextLink'] = 'https://x/page2' }
    return $r
}
$script:mockPaged = $false
foreach ($n in 0, 1, 2) {
    $script:mockCount = $n
    $app = [PSCustomObject]@{ Id = 'x'; Assignments = @() }
    $ok = $true
    try { $app.Assignments = Get-ItemAssignments ([PSCustomObject]@{ AssignPath = 'deviceAppManagement/mobileApps/x/assignments' }) } catch { $ok = $false }
    Assert $ok "read-back with $n assignment(s) does not throw"
    Assert ($ok -and $app.Assignments -is [object[]] -and $app.Assignments.Count -eq $n) "read-back with $n assignment(s) is an object[] of $n"
    if ($ok) { Assert ($null -eq (Find-AssignmentForSelection $app.Assignments $selG1) -or $n -gt 0) "matching on the read-back result ($n)" }
}
$script:mockCount = 1; $script:mockPaged = $true; $script:mockCalls = 0
$pg = Invoke-GraphPaged -Uri 'https://x/page1'
Assert ($script:mockCalls -eq 2 -and $pg.Count -eq 2 -and $pg -is [object[]]) 'paging follows @odata.nextLink and returns object[]'
Remove-Item Function:\Invoke-MgGraphRequest

# Policy sets: a direct assignment wins, a policy-set one is read-only
$psDirect = @{ id = 'd'; intent = 'required';  source = 'direct';     target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $g1 } }
$psSet    = @{ id = 'p'; intent = 'available'; source = 'policySets'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $g1 } }
Assert ((Find-AssignmentForSelection @($psSet, $psDirect) $selG1).id -eq 'd') 'direct assignment wins over policy set'
$stPs = ConvertTo-AssignmentState (Find-AssignmentForSelection @($psSet) $selG1)
Assert ($stPs.PolicySet -eq $true) 'policy-set assignment is marked'
Assert ((ConvertTo-AssignmentState $psDirect).PolicySet -eq $false) 'direct assignment is not marked'
$opPs = [PSCustomObject]@{ Key = 'x'; Action = 'Remove'; From = $stPs; To = $null }
Assert ($null -ne (Get-PlanProblem $opPs $selG1)) 'removing a policy-set assignment is rejected'
$opOk = [PSCustomObject]@{ Key = 'x'; Action = 'Add'; From = $null; To = [PSCustomObject]@{ Intent = 'required'; Exclude = $false } }
Assert ($null -eq (Get-PlanProblem $opOk $selG1)) 'plain add has no problem'
$opBad = [PSCustomObject]@{ Key = 'x'; Action = 'Add'; From = $null; To = [PSCustomObject]@{ Intent = 'available'; Exclude = $false } }
Assert ($null -ne (Get-PlanProblem $opBad $selAD)) 'plan check applies the target rules'
$opUsr = [PSCustomObject]@{ Key = 'x'; Action = 'Add'; From = $null; To = [PSCustomObject]@{ Intent = ''; Exclude = $false } }
Assert ($null -ne (Get-PlanProblem $opUsr $selAD $true)) 'user-only objects (MAM) cannot go to All devices'
Assert ($null -eq (Get-PlanProblem $opUsr $selAU $true)) 'user-only objects can go to All users'
Assert ($null -eq (Get-PlanProblem $opUsr $selAD $false)) 'device objects can go to All devices'

# Bodies
$b = New-AssignmentBody -Selection $selG1 -Intent 'required' -Exclude $false -AppType 'win32LobApp' -VppDeviceLicensing $true
Assert ($b.target.'@odata.type' -eq '#microsoft.graph.groupAssignmentTarget' -and $b.target.groupId -eq $g1) 'include body targets the group'
Assert (-not $b.Contains('settings')) 'no settings for a new non-VPP include'

$b = New-AssignmentBody -Selection $selG1 -Intent 'required' -Exclude $true -AppType 'iosVppApp' -VppDeviceLicensing $true -Carry $stAU
Assert ($b.target.'@odata.type' -eq '#microsoft.graph.exclusionGroupAssignmentTarget') 'exclusion body uses exclusionGroupAssignmentTarget'
Assert (-not $b.Contains('settings') -and -not $b.target.Contains('deviceAndAppManagementAssignmentFilterId')) 'exclusion carries neither settings nor filter'

$b = New-AssignmentBody -Selection $selG1 -Intent 'available' -Exclude $false -AppType 'iosVppApp' -VppDeviceLicensing $true
Assert ($b.settings.'@odata.type' -eq '#microsoft.graph.iosVppAppAssignmentSettings' -and $b.settings.useDeviceLicensing -eq $true) 'new iOS VPP include: device licensing'
$b = New-AssignmentBody -Selection $selG1 -Intent 'available' -Exclude $false -AppType 'macOsVppApp' -VppDeviceLicensing $false
Assert ($b.settings.'@odata.type' -eq '#microsoft.graph.macOsVppAppAssignmentSettings' -and $b.settings.useDeviceLicensing -eq $false) 'new macOS VPP include: user licensing when switched off'

$b = New-AssignmentBody -Selection $selAU -Intent 'uninstall' -Exclude $false -AppType 'win32LobApp' -VppDeviceLicensing $true -Carry $stAU
Assert ($b.target.'@odata.type' -eq '#microsoft.graph.allLicensedUsersAssignmentTarget' -and -not $b.target.Contains('groupId')) 'All users body has no groupId'
Assert ($b.target.deviceAndAppManagementAssignmentFilterId -eq 'f-1' -and $b.settings.notifications -eq 'hideAll') 'intent change keeps filter and settings'
$b = New-AssignmentBody -Selection $selAD -Intent 'required' -Exclude $false -AppType 'win32LobApp' -VppDeviceLicensing $true
Assert ($b.target.'@odata.type' -eq '#microsoft.graph.allDevicesAssignmentTarget') 'All devices body'
$json = New-AssignmentBody -Selection $selG1 -Intent 'required' -Exclude $false -AppType 'iosVppApp' -VppDeviceLicensing $true | ConvertTo-Json -Depth 10
Assert ($json -match '"@odata.type":\s*"#microsoft.graph.mobileAppAssignment"' -and $json -match '"useDeviceLicensing":\s*true') 'body serialises to the expected JSON'

# Validation
Assert ($null -eq (Test-DesiredAssignment $selG1 'available' $true)) 'group exclusion is allowed'
Assert ($null -ne (Test-DesiredAssignment $selAU 'required' $true)) 'All users exclusion is rejected'
Assert ($null -ne (Test-DesiredAssignment $selAD 'available' $false)) 'Available to All devices is rejected'
Assert ($null -ne (Test-DesiredAssignment $selAD 'availableWithoutEnrollment' $false)) 'Available w/o enrollment to All devices is rejected'
Assert ($null -eq (Test-DesiredAssignment $selAD 'required' $false)) 'Required to All devices is allowed'

# Plan
function S([string]$i, [bool]$x = $false) { [PSCustomObject]@{ Intent = $i; Exclude = $x } }

# Change column and sorting
$o1 = S 'required'
Assert ((Get-ChangeText $null (S 'required')) -eq $L.ChangeNew) 'change text: new'
Assert ((Get-ChangeText $o1 (S 'available')) -eq $L.ChangeChanged) 'change text: changed intent'
Assert ((Get-ChangeText $o1 (S 'required' $true)) -eq $L.ChangeChanged) 'change text: changed to exclusion'
Assert ((Get-ChangeText $o1 (S 'required')) -eq '') 'change text: unchanged'
$rows = @(
    [PSCustomObject]@{ Name = 'Teams';   Type = 'iosVppApp';        Intent = 'Required';  Exclude = $false; Filter = ''; Change = '' },
    [PSCustomObject]@{ Name = 'Edge';    Type = 'iosVppApp';        Intent = 'Available'; Exclude = $false; Filter = ''; Change = 'new' },
    [PSCustomObject]@{ Name = 'Outlook'; Type = 'iosStoreApp';      Intent = 'Required';  Exclude = $true;  Filter = ''; Change = '' },
    [PSCustomObject]@{ Name = 'Authenticator'; Type = 'iosVppApp';  Intent = 'Uninstall'; Exclude = $false; Filter = ''; Change = '' }
)
Assert (((Sort-GridRows $rows 'Name' $false) | ForEach-Object { $_.Name }) -join ',' -eq 'Authenticator,Edge,Outlook,Teams') 'sort by app'
Assert (((Sort-GridRows $rows 'Name' $true) | ForEach-Object { $_.Name }) -join ',' -eq 'Teams,Outlook,Edge,Authenticator') 'sort by app, descending'
Assert (((Sort-GridRows $rows 'Type' $false) | ForEach-Object { $_.Name }) -join ',' -eq 'Outlook,Authenticator,Edge,Teams') 'sort by type, then app'
Assert (((Sort-GridRows $rows 'Intent' $false) | ForEach-Object { $_.Name }) -join ',' -eq 'Edge,Outlook,Teams,Authenticator') 'sort by mode text, then app'
Assert (((Sort-GridRows $rows 'Intent' $true) | ForEach-Object { $_.Name }) -join ',' -eq 'Authenticator,Outlook,Teams,Edge') 'sort by mode descending, app stays ascending'
Assert (@(Sort-GridRows @() 'Name' $false).Count -eq 0) 'sorting no rows'

$orig = @{ keep = (S 'required'); gone = (S 'available'); intent = (S 'required'); excl = (S 'required') }
$want = @{ keep = (S 'required'); new = (S 'uninstall'); intent = (S 'available'); excl = (S 'required' $true) }
$plan = Get-AssignmentPlan -Original $orig -Desired $want
$byId = @{}; foreach ($p in $plan) { $byId[$p.Key] = $p.Action }
Assert ($plan.Count -eq 4) "plan has 4 operations (got $($plan.Count))"
Assert ($byId['new'] -eq 'Add') 'plan: new app -> Add'
Assert ($byId['gone'] -eq 'Remove') 'plan: removed app -> Remove'
Assert ($byId['intent'] -eq 'Change') 'plan: other intent -> Change'
Assert ($byId['excl'] -eq 'Change') 'plan: include -> exclude -> Change'
Assert (-not $byId.ContainsKey('keep')) 'plan: unchanged app -> no operation'
Assert ((Get-AssignmentPlan -Original @{} -Desired @{}).Count -eq 0) 'empty plan'

# ---- Categories: one table, one shared path; every entry must be complete ----
$cats = Get-CategoryTable
foreach ($c in $cats.Values) {
    Assert (@($c.Sources).Count -ge 1) "category $($c.Key): has a source"
    Assert ($c.HasIntent -eq ($c.Key -eq 'apps')) "category $($c.Key): only apps have an intent"
    Assert ($c.NeedsConfigScope -eq ($c.Key -ne 'apps')) "category $($c.Key): permission beyond apps only outside apps"
    foreach ($src in $c.Sources) {
        Assert ($src.List -match '^[A-Za-z/]+(\?\$select=.+)?$') "category $($c.Key): list '$($src.List)' is a path, optionally with `$select"
        Assert ($src.ItemPath -match '\{0\}$') "category $($c.Key): item path '$($src.ItemPath)' ends in {0}"
        Assert (@('Single', 'Replace') -contains $src.Write) "category $($c.Key): write mode '$($src.Write)' is Single or Replace"
        if ($src.Write -eq 'Replace') { Assert ($src.AssignAction -match '\{0\}/(assign|update)$') "category $($c.Key): Replace source has an /assign or /update action" }
        Assert (@('Collection', 'Expand') -contains $src.ReadVia) "category $($c.Key): read path '$($src.ReadVia)'" 
        Assert ($src.AssignmentType -match '^#microsoft\.graph\..+Assignment$') "category $($c.Key): assignment type '$($src.AssignmentType)'"
    }
}
Assert ($cats.Contains('apps') -and $cats.Contains('config') -and $cats.Contains('compliance') -and $cats.Contains('appConfig')) 'phase 1 categories exist'
# phase 2: MAM - users only, complete list through /assign
$mamCfg = @($cats['appConfig'].Sources | Where-Object { $_.List -like 'deviceAppManagement/targetedManagedAppConfigurations*' })
Assert ($mamCfg.Count -eq 1 -and $mamCfg[0].UsersOnly -and $mamCfg[0].Write -eq 'Replace' -and $mamCfg[0].AssignAction -eq 'deviceAppManagement/targetedManagedAppConfigurations/{0}/assign') 'MAM app configuration: users only, /assign'
Assert (@($cats['appConfig'].Sources | Where-Object { $_.List -like 'deviceAppManagement/mobileAppConfigurations*' -and -not $_.UsersOnly }).Count -eq 1) 'device app configuration: not users-only'
Assert ($cats.Contains('appProtection') -and @($cats['appProtection'].Sources).Count -eq 3) 'app protection: iOS, Android, Windows collections'
foreach ($src in $cats['appProtection'].Sources) {
    Assert ($src.UsersOnly -and $src.Write -eq 'Replace' -and $src.AssignAction -eq "$($src.ItemPath)/assign" -and $src.AssignmentType -eq '#microsoft.graph.targetedManagedAppPolicyAssignment') "app protection source $($src.List): users only, <collection>/{id}/assign (live-verified)"
}
$itemAp = ConvertTo-Item @{ id = 'ap1'; displayName = 'iOS MAM'; '@odata.type' = '#microsoft.graph.iosManagedAppProtection' } $cats['appProtection'] $cats['appProtection'].Sources[0]
Assert ($itemAp.AssignPath -eq 'deviceAppManagement/iosManagedAppProtections/ap1/assignments' -and $itemAp.AssignAction -eq 'deviceAppManagement/iosManagedAppProtections/ap1/assign') 'app protection item: read and write per platform collection'
Assert (($itemAp.Platforms -join ',') -eq 'iOS' -and $itemAp.UsersOnly) 'app protection item: platform iOS, users only'
# measured live: with $select, Graph sends no @odata.type for these collections - the source's type is used
$apNoType = @(foreach ($src in $cats['appProtection'].Sources) { ConvertTo-Item @{ id = 'x'; displayName = 'P' } $cats['appProtection'] $src })
Assert ((($apNoType | ForEach-Object { $_.Platforms -join '' }) -join ',') -eq 'iOS,Android,Windows') 'app protection without @odata.type: platform from the collection'
Assert ((($apNoType | ForEach-Object { $_.Type }) -join ',') -eq 'iosManagedAppProtection,androidManagedAppProtection,windowsManagedAppProtection') 'app protection without @odata.type: type from the collection'
$psNoType = ConvertTo-Item @{ id = 'p'; displayName = 'S' } $cats['policySets'] $cats['policySets'].Sources[0]
Assert ($psNoType.Type -eq 'policySet' -and ($psNoType.Platforms -join '') -eq '*') 'policy set without @odata.type: type policySet, no platform'
Assert (($cats['appProtection'].Sources[1].List) -eq 'deviceAppManagement/androidManagedAppProtections?$select=id,displayName') 'app protection list path built correctly'
# phase 3: policy sets - assigned one by one like apps, no intent
Assert ($cats.Contains('policySets') -and $cats['policySets'].Sources[0].Write -eq 'Replace' -and $cats['policySets'].Sources[0].AssignAction -eq 'deviceAppManagement/policySets/{0}/update' -and $cats['policySets'].Sources[0].ReadVia -eq 'Expand' -and $cats['policySets'].Sources[0].AssignmentType -eq '#microsoft.graph.policySetAssignment') 'policy sets: read via $expand, complete list through /update (live-verified)'
# live-verified write paths (2026-09): the documented POST .../assignments has no route for these
Assert ($cats['compliance'].Sources[0].Write -eq 'Replace' -and $cats['compliance'].Sources[0].AssignAction -eq 'deviceManagement/deviceCompliancePolicies/{0}/assign') 'compliance: /assign (live-verified)'
Assert (@($cats['appConfig'].Sources | Where-Object { $_.List -like 'deviceAppManagement/mobileAppConfigurations*' -and $_.Write -eq 'Replace' -and $_.AssignAction -eq 'deviceAppManagement/mobileAppConfigurations/{0}/assign' }).Count -eq 1) 'device app configuration: /assign (live-verified)'
Assert (@($cats['config'].Sources | Where-Object { $_.List -like 'deviceManagement/deviceConfigurations*' -and $_.Write -eq 'Single' }).Count -eq 1) 'device configurations: single writes (live-verified)'
$itemPs = ConvertTo-Item @{ id = 'ps1'; displayName = 'iOS Baseline'; '@odata.type' = '#microsoft.graph.policySet' } $cats['policySets'] $cats['policySets'].Sources[0]
Assert ($itemPs.AssignPath -eq 'deviceAppManagement/policySets/ps1/assignments' -and ($itemPs.Platforms -join ',') -eq '*' -and -not $itemPs.HasIntent) 'policy set item: path, no platform of its own, no intent'
$bPs = New-AssignmentBody -Selection $selG1 -Intent '' -Exclude $false -AppType 'policySet' -VppDeviceLicensing $true -AssignmentType '#microsoft.graph.policySetAssignment' -HasIntent $false
Assert ($bPs.'@odata.type' -eq '#microsoft.graph.policySetAssignment' -and -not $bPs.Contains('intent') -and $bPs.target.groupId -eq $g1) 'policy set body'

# ---- App version (Windows) and publisher ----
Assert ((Get-AppVersion @{ displayVersion = '1.2.3' }) -eq '1.2.3') 'version: win32LobApp displayVersion'
Assert ((Get-AppVersion @{ productVersion = '4.5'; identityVersion = '9.9' }) -eq '4.5') 'version: MSI productVersion first'
Assert ((Get-AppVersion @{ identityVersion = '7.0.1.0' }) -eq '7.0.1.0') 'version: AppX/MSIX identityVersion'
Assert ((Get-AppVersion @{ packageIdentifier = 'XP99' }) -eq '') 'version: WinGet / store apps have none'
$itApp = ConvertTo-Item @{ id = 'w1'; displayName = 'Notepad++'; publisher = 'Don Ho'; displayVersion = '8.6'; '@odata.type' = '#microsoft.graph.win32LobApp' } $cats['apps'] $cats['apps'].Sources[0]
Assert ($itApp.Publisher -eq 'Don Ho' -and $itApp.Version -eq '8.6') 'app item carries publisher and version'
Assert ($cats['apps'].Sources[0].List -notmatch '\$select') 'apps list without $select (version fields live on the derived types)'

# ---- Platforms ----
function P([string]$t, [string]$v = '') { (Get-ItemPlatforms -OdataType $t -PlatformsValue $v) -join ',' }
Assert ((P 'iosVppApp') -eq 'iOS') 'platform: iosVppApp'
Assert ((P 'managedIOSStoreApp') -eq 'iOS') 'platform: managedIOSStoreApp'
Assert ((P 'iosGeneralDeviceConfiguration') -eq 'iOS') 'platform: iOS device configuration'
Assert ((P 'macOSLobApp') -eq 'macOS' -and (P 'macOsVppApp') -eq 'macOS') 'platform: macOS apps (not iOS)'
Assert ((P 'macOSGeneralDeviceConfiguration') -eq 'macOS') 'platform: macOS configuration (not iOS)'
Assert ((P 'androidManagedStoreApp') -eq 'Android' -and (P 'aospDeviceOwnerDeviceConfiguration') -eq 'Android') 'platform: Android'
Assert ((P 'win32LobApp') -eq 'Windows' -and (P 'windows10GeneralConfiguration') -eq 'Windows') 'platform: Windows'
# Every concrete Windows app type of the Graph beta mobileApp hierarchy (winGetApp once fell through to '*')
foreach ($wt in 'winGetApp', 'win32CatalogApp', 'win32LobApp', 'windowsMicrosoftEdgeApp', 'microsoftStoreForBusinessApp', 'officeSuiteApp',
                'windowsUniversalAppX', 'windowsAppX', 'windowsMobileMSI', 'windowsWebApp', 'windowsStoreApp') {
    Assert ((P $wt) -eq 'Windows') "platform: $wt is Windows"
}
Assert (-not (Test-PlatformMatch (Get-ItemPlatforms 'winGetApp') 'iOS')) 'platform: WinGet app is hidden under iOS'
Assert ((P 'webApp') -eq '*') 'platform: web app has none (shown everywhere)'
Assert ((P '' 'iOS') -eq 'iOS' -and (P '' 'macOS') -eq 'macOS' -and (P '' 'windows10') -eq 'Windows') 'platform: settings catalog platforms value'
Assert ((P '' 'iOS,macOS') -eq 'iOS,macOS') 'platform: several platforms'
Assert ((Test-PlatformMatch @('iOS') 'iOS') -and -not (Test-PlatformMatch @('macOS') 'iOS')) 'platform filter matches'
Assert ((Test-PlatformMatch @('*') 'iOS') -and (Test-PlatformMatch @('macOS') 'All')) 'platform filter: * and All'
Assert ((Get-PlatformIndex 'all') -eq 4 -and (Get-PlatformIndex 'ios') -eq 0 -and (Get-PlatformIndex 'Android') -eq 2) 'platform parameter is found case-insensitively'

# ---- Items ----
$srcSc  = $cats['config'].Sources | Where-Object { $_.Write -eq 'Replace' }
$itemSc = ConvertTo-Item @{ id = 'sc1'; name = 'Passcode'; platforms = 'iOS'; '@odata.type' = '#microsoft.graph.deviceManagementConfigurationPolicy'; assignments = @() } $cats['config'] $srcSc
Assert ($itemSc.Key -eq 'config|sc1' -and $itemSc.Name -eq 'Passcode' -and $itemSc.Type -eq $L.TypeSettingsCatalog) 'settings catalog item: key, name from "name", type'
Assert ($itemSc.AssignPath -eq 'deviceManagement/configurationPolicies/sc1/assignments' -and $itemSc.AssignAction -eq 'deviceManagement/configurationPolicies/sc1/assign') 'settings catalog item: paths'
Assert (($itemSc.Platforms -join ',') -eq 'iOS' -and -not $itemSc.HasIntent -and $itemSc.Write -eq 'Replace') 'settings catalog item: platform, no intent, Replace'
$itemDc = ConvertTo-Item @{ id = 'dc1'; displayName = 'WLAN'; '@odata.type' = '#microsoft.graph.iosWiFiConfiguration' } $cats['config'] $cats['config'].Sources[0]
Assert ($itemDc.Type -eq 'iosWiFiConfiguration' -and $itemDc.Write -eq 'Single' -and $itemDc.AssignPath -eq 'deviceManagement/deviceConfigurations/dc1/assignments') 'device configuration item'

# ---- States and bodies outside apps ----
$stCfg = ConvertTo-AssignmentState @{ id = 'c-1'; intent = 'remove'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $g1 } } $false
Assert ($stCfg.Intent -eq '' -and $stCfg.RawIntent -eq 'remove') 'no intent outside apps; the raw apply/remove is kept'
Assert ((Get-StateText $stCfg $false) -eq $L.StateIncluded -and (Get-StateText (S '' $true) $false) -eq $L.IsExcluded) 'state text outside apps'
$b = New-AssignmentBody -Selection $selG1 -Intent '' -Exclude $false -AppType 'iosVppApp' -VppDeviceLicensing $true -Carry $stCfg -AssignmentType '#microsoft.graph.deviceConfigurationAssignment' -HasIntent $false
Assert ($b.'@odata.type' -eq '#microsoft.graph.deviceConfigurationAssignment' -and $b.intent -eq 'remove' -and -not $b.Contains('settings')) 'device configuration body: own type, keeps apply/remove, no app settings'
$b = New-AssignmentBody -Selection $selG1 -Intent '' -Exclude $true -AppType '' -VppDeviceLicensing $true -AssignmentType '#microsoft.graph.deviceCompliancePolicyAssignment' -HasIntent $false
Assert (-not $b.Contains('intent') -and $b.target.'@odata.type' -eq '#microsoft.graph.exclusionGroupAssignmentTarget') 'compliance exclusion body: no intent'

# ---- Replace list: everything of OTHER targets survives ----
$cur = @(
    @{ id = 'r1'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $g2;
                             deviceAndAppManagementAssignmentFilterId = 'f-9'; deviceAndAppManagementAssignmentFilterType = 'exclude' } },
    @{ id = 'r2'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $g1;
                             deviceAndAppManagementAssignmentFilterId = 'f-1'; deviceAndAppManagementAssignmentFilterType = 'include' } },
    @{ id = 'r3'; source = 'policySets'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'g3' } },
    @{ id = 'r4'; target = @{ '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget' } }
)
$aType = '#microsoft.graph.deviceManagementConfigurationPolicyAssignment'
$fromG1 = ConvertTo-AssignmentState $cur[1] $false
$l = New-ReplaceAssignmentList -Current $cur -Selection $selG1 -Desired $null -AssignmentType $aType -Carry $fromG1
Assert ($l.Count -eq 2) "replace/remove: 2 assignments stay (got $($l.Count))"
Assert (@($l | Where-Object { $_.target.groupId -eq $g1 }).Count -eq 0) 'replace/remove: the selected group is gone'
$keptG2 = @($l | Where-Object { $_.target.groupId -eq $g2 })
Assert ($keptG2.Count -eq 1 -and $keptG2[0].target.deviceAndAppManagementAssignmentFilterId -eq 'f-9' -and $keptG2[0].target.deviceAndAppManagementAssignmentFilterType -eq 'exclude') 'replace: another group keeps its filter'
Assert (@($l | Where-Object { $_.target.'@odata.type' -eq '#microsoft.graph.allLicensedUsersAssignmentTarget' }).Count -eq 1) 'replace: All users stays'
Assert (@($l | Where-Object { $_.target.groupId -eq 'g3' }).Count -eq 0) 'replace: policy-set assignments are not sent back'
Assert (@($l | Where-Object { $_.'@odata.type' -ne $aType }).Count -eq 0) 'replace: every entry has the assignment type'
$l = New-ReplaceAssignmentList -Current $cur -Selection $selG1 -Desired (S '' $true) -AssignmentType $aType -Carry $fromG1
$mine = @($l | Where-Object { $_.target.groupId -eq $g1 })
Assert ($l.Count -eq 3 -and $mine.Count -eq 1 -and $mine[0].target.'@odata.type' -eq '#microsoft.graph.exclusionGroupAssignmentTarget') 'replace/change: the group becomes one exclusion'
Assert (-not $mine[0].target.Contains('deviceAndAppManagementAssignmentFilterId')) 'replace: an exclusion has no filter'
$l = New-ReplaceAssignmentList -Current @() -Selection $selG1 -Desired (S '' $false) -AssignmentType $aType
Assert ($l.Count -eq 1 -and $l[0].target.groupId -eq $g1) 'replace/add to an object without assignments'
$json = @{ assignments = (New-ReplaceAssignmentList -Current @() -Selection $selG1 -Desired $null -AssignmentType $aType) } | ConvertTo-Json -Depth 20
Assert ($json -match '"assignments":\s*\[\s*\]') 'replace: removing the last assignment sends an empty list'

# ---- Graph mock: load and write ----
$script:calls = @()
$script:responses = @{}
function Invoke-MgGraphRequest {
    param($Method, $Uri, $Headers, $Body, $ContentType, $ErrorAction)
    $script:calls += [PSCustomObject]@{ Method = $Method; Uri = $Uri; Body = $Body }
    foreach ($k in $script:responses.Keys) {
        if ($Uri -like $k) {
            $r = $script:responses[$k]
            if ($r -is [scriptblock]) { return (& $r) }
            return $r
        }
    }
    return @{ value = @() }
}
function Get-Calls([string]$Method) { @($script:calls | Where-Object { $_.Method -eq $Method }) }

# a list without '?' gets '?$expand', not '&$expand'
$script:calls = @(); $script:responses = [ordered]@{}
[void](Get-CategoryItems -Category $cats['apps'])
Assert (@($script:calls | Where-Object { $_.Uri -like '*/mobileApps?$expand=assignments' }).Count -eq 1 -and @($script:calls | Where-Object { $_.Uri -like '*mobileApps&*' }).Count -eq 0) 'apps list: ?$expand=assignments'
$script:calls = @()

# load with $expand
$script:responses = @{ '*configurationPolicies?*expand=assignments' = @{ value = @(@{ id = 'sc1'; name = 'A'; platforms = 'iOS'; assignments = @($cur[1]) }) } }
$cc = [PSCustomObject]@{ Key = 'config'; Label = 'C'; HasIntent = $false; Sources = @($srcSc) }
$items = Get-CategoryItems -Category $cc
Assert ($items.Count -eq 1 -and $items[0].Name -eq 'A' -and @($items[0].Assignments).Count -eq 1) 'load with $expand: item and its assignment'
Assert ((Get-Calls 'GET').Count -eq 1) 'load with $expand: one call'
# load without $expand support: object by object
$script:calls = @()
$script:responses = @{
    '*expand=assignments'                             = @{ value = @(@{ id = 'sc1'; name = 'A'; platforms = 'iOS' }) }
    '*configurationPolicies/sc1/assignments'          = @{ value = @($cur[1], $cur[0]) }
    '*configurationPolicies?$select=*'                = @{ value = @(@{ id = 'sc1'; name = 'A'; platforms = 'iOS' }) }
}
$items = Get-CategoryItems -Category $cc
Assert ($items.Count -eq 1 -and @($items[0].Assignments).Count -eq 2) 'load without $expand: assignments read per object'
Assert ((ConvertTo-AssignmentState (Find-AssignmentForSelection $items[0].Assignments $selG1) $false).FilterId -eq 'f-1') 'load without $expand: the group is found'

# read via $expand (policy sets): no list $expand, per set GET ?$expand=assignments
$script:calls = @()
$srcPs = $cats['policySets'].Sources[0]
# ordered, and '[?]' because '?' is a one-character wildcard for -like
$script:responses = [ordered]@{
    '*/policySets/ps1[?]$expand=assignments'         = @{ id = 'ps1'; assignments = @($cur[0]) }
    '*/policySets[?]$select=*&$expand=assignments'   = { throw 'Query option Expand is not allowed' }
    '*/policySets[?]$select=id,displayName'          = @{ value = @(@{ id = 'ps1'; displayName = 'Set' }) }
}
$psItems = Get-CategoryItems -Category ([PSCustomObject]@{ Key = 'policySets'; Label = 'P'; HasIntent = $false; Sources = @($srcPs) })
Assert ($psItems.Count -eq 1 -and @($psItems[0].Assignments).Count -eq 1 -and $psItems[0].Assignments[0].target.groupId -eq $g2) 'policy sets: assignments read per set via $expand'
Assert (@(Get-Calls 'GET' | Where-Object { $_.Uri -like '*/assignments' }).Count -eq 0) 'policy sets: never GET .../assignments'
$script:responses = [ordered]@{ '*/policySets/ps1[?]$expand=assignments' = @{ id = 'ps1' } }
$pa = Get-ItemAssignments $psItems[0]    # used by assignment, like the tool does
Assert ($pa -is [object[]] -and $pa.Count -eq 0) 'policy sets: a set without assignments reads as an empty array'

# write, Replace: fresh read, then one POST to /assign that keeps the other targets
$script:calls = @()
$script:responses = @{ '*configurationPolicies/sc1/assignments' = @{ value = $cur } }
$opR = [PSCustomObject]@{ Key = 'config|sc1'; Action = 'Remove'; From = $fromG1; To = $null }
Invoke-ItemWrite -Item $itemSc -Operation $opR -Selection $selG1 -VppDeviceLicensing $true
$posts = Get-Calls 'POST'
Assert ((Get-Calls 'GET').Count -eq 1 -and $posts.Count -eq 1 -and (Get-Calls 'DELETE').Count -eq 0) 'write Replace: one fresh read, one POST, no DELETE'
Assert ($posts[0].Uri -like '*/deviceManagement/configurationPolicies/sc1/assign') 'write Replace: POST goes to /assign'
$sent = ($posts[0].Body | ConvertFrom-Json).assignments
Assert (@($sent).Count -eq 2 -and @($sent | Where-Object { $_.target.groupId -eq $g2 }).Count -eq 1 -and @($sent | Where-Object { $_.target.groupId -eq $g1 }).Count -eq 0) 'write Replace: other group kept, selected group removed'

# write, Single: Change = DELETE the old, POST the new
$script:calls = @()
$script:responses = @{}
$fromDc = ConvertTo-AssignmentState @{ id = 'as-9'; intent = 'apply'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $g1 } } $false
$opC = [PSCustomObject]@{ Key = 'config|dc1'; Action = 'Change'; From = $fromDc; To = (S '' $true) }
Invoke-ItemWrite -Item $itemDc -Operation $opC -Selection $selG1 -VppDeviceLicensing $true
Assert ($script:calls.Count -eq 2 -and $script:calls[0].Method -eq 'DELETE' -and $script:calls[0].Uri -like '*/deviceConfigurations/dc1/assignments/as-9') 'write Single/change: DELETE of the old assignment first'
$pb = $script:calls[1].Body | ConvertFrom-Json
Assert ($script:calls[1].Method -eq 'POST' -and $script:calls[1].Uri -like '*/deviceConfigurations/dc1/assignments' -and $pb.target.'@odata.type' -eq '#microsoft.graph.exclusionGroupAssignmentTarget' -and $pb.'@odata.type' -eq '#microsoft.graph.deviceConfigurationAssignment') 'write Single/change: POST of the new exclusion'

# write, Single: a failing POST after the DELETE puts the old assignment back
$script:calls = @()
$script:postCount = 0
$script:responses = @{ '*/deviceConfigurations/dc1/assignments' = { $script:postCount++; if ($script:postCount -eq 1) { throw 'rejected' }; @{} } }
$err = $null
try { Invoke-ItemWrite -Item $itemDc -Operation $opC -Selection $selG1 -VppDeviceLicensing $true } catch { $err = $_.Exception.Message }
$restorePost = @(Get-Calls 'POST')
Assert ($err -and $err -like "*$($L.Restored)*" -and $restorePost.Count -eq 2 -and ($restorePost[1].Body | ConvertFrom-Json).target.'@odata.type' -eq '#microsoft.graph.groupAssignmentTarget') 'write Single/change: failed POST -> old assignment restored and reported'

# ---- eventually consistent objects (MAM, measured live): stable read, retry, wait for the result ----
$script:slept = 0
$script:Sleep = { param($s) $script:slept += $s }
$srcAp  = $cats['appProtection'].Sources[0]
Assert ($srcAp.Eventual -and (@($cats['appConfig'].Sources | Where-Object { $_.Eventual }).Count -eq 1)) 'MAM sources are marked eventually consistent'
Assert (-not ($cats['config'].Sources | Where-Object { $_.Eventual }) -and -not $cats['apps'].Sources[0].Eventual) 'other sources are not'
$itemEv = ConvertTo-Item @{ id = 'ev1'; displayName = 'MAM'; '@odata.type' = '#microsoft.graph.iosManagedAppProtection' } $cats['appProtection'] $srcAp
$aC  = @{ id = 'c'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'gC' } }
$aAx = @{ id = 'a'; target = @{ '@odata.type' = '#microsoft.graph.exclusionGroupAssignmentTarget'; groupId = $g1 } }

# stable read: stale, new, new -> the new list after the second agreeing read
$script:seq = @( @{ value = @($aC, $aAx) }, @{ value = @($aC) }, @{ value = @($aC) } ); $script:n = 0
$script:responses = [ordered]@{ '*/iosManagedAppProtections/ev1/assignments' = { $r = $script:seq[[Math]::Min($script:n, $script:seq.Count - 1)]; $script:n++; $r } }
$script:calls = @(); $script:slept = 0
$st = Read-StableAssignments $itemEv
Assert ($st.Count -eq 1 -and $script:n -eq 3 -and $script:slept -eq 10) 'stable read: waits until two reads agree'
Assert ((Get-AssignmentSignature @($aC, $aAx)) -eq (Get-AssignmentSignature @($aAx, $aC))) 'signature ignores the order'
$script:n = 0; $script:slept = 0
[void](Read-StableAssignments $itemDc)
Assert ($script:slept -eq 0) 'stable read: other objects are read once, no waiting'

# the write builds its list from the STABLE read: a stale first read still showing a just-removed
# exclusion must not bring it back
$gB2 = 'aaaaaaaa-0000-0000-0000-00000000000b'
$script:seq = @( @{ value = @($aC, $aAx) }, @{ value = @($aC) }, @{ value = @($aC) } ); $script:n = 0; $script:slept = 0
$script:responses = [ordered]@{
    '*/iosManagedAppProtections/ev1/assignments' = { $r = $script:seq[[Math]::Min($script:n, $script:seq.Count - 1)]; $script:n++; $r }
    '*/iosManagedAppProtections/ev1/assign'      = @{}
}
$script:calls = @()
Invoke-ItemWrite -Item $itemEv -Operation ([PSCustomObject]@{ Key = 'k'; Action = 'Add'; From = $null; To = (S '' $false) }) -Selection (New-Selection 'group' $gB2 'B') -VppDeviceLicensing $true
$sentEv = @((Get-Calls 'POST')[0].Body | ConvertFrom-Json).assignments
Assert (@($sentEv).Count -eq 2 -and @($sentEv | Where-Object { $_.target.groupId -eq $g1 }).Count -eq 0) 'write: a stale read does not bring back a removed assignment'

# retry: ConditionNotMet twice, then accepted - one list, sent three times
$script:post = 0
$script:responses = [ordered]@{
    '*/iosManagedAppProtections/ev1/assignments' = @{ value = @($aC) }
    '*/iosManagedAppProtections/ev1/assign'      = { $script:post++; if ($script:post -le 2) { $e = [System.Management.Automation.ErrorRecord]::new([Exception]::new('412'), 'x', 'NotSpecified', $null); $e.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"error":{"code":"ConditionNotMet","message":"busy"}}'); throw $e }; @{} }
}
$script:calls = @(); $err = $null
try { Invoke-ItemWrite -Item $itemEv -Operation ([PSCustomObject]@{ Key = 'k'; Action = 'Add'; From = $null; To = (S '' $false) }) -Selection $selG1 -VppDeviceLicensing $true } catch { $err = $_.Exception.Message }
Assert (-not $err -and $script:post -eq 3) "retry: ConditionNotMet is retried until accepted ($err)"
# no retry for a real error
$script:post = 0
$script:responses['*/iosManagedAppProtections/ev1/assign'] = { $script:post++; $e = [System.Management.Automation.ErrorRecord]::new([Exception]::new('400'), 'x', 'NotSpecified', $null); $e.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"error":{"code":"BadRequest","message":"invalid"}}'); throw $e }
$err = $null
try { Invoke-ItemWrite -Item $itemEv -Operation ([PSCustomObject]@{ Key = 'k'; Action = 'Add'; From = $null; To = (S '' $false) }) -Selection $selG1 -VppDeviceLicensing $true } catch { $err = $_.Exception.Message }
Assert ($err -eq 'invalid' -and $script:post -eq 1) 'retry: a real error is reported at once'

# wait for the result: stale twice, then the wanted state twice
$script:seq = @( @{ value = @($aC) }, @{ value = @($aC) }, @{ value = @($aC, $aAx) }, @{ value = @($aC, $aAx) } ); $script:n = 0; $script:slept = 0
$script:responses = [ordered]@{ '*/iosManagedAppProtections/ev1/assignments' = { $r = $script:seq[[Math]::Min($script:n, $script:seq.Count - 1)]; $script:n++; $r } }
$fin = Wait-ItemState $itemEv $selG1 (S '' $true)
$live = ConvertTo-AssignmentState (Find-AssignmentForSelection $fin.List $selG1) $false
Assert ((Test-StateMatches $live (S '' $true)) -and $script:n -eq 4 -and -not $fin.Pending) 'wait: polls until the wanted state shows twice'
# never reaches the state: gives up after the limit with the last read
$script:seq = @( @{ value = @($aC) } ); $script:n = 0; $script:slept = 0
$script:LastSent = @{}
$fin = Wait-ItemState $itemEv $selG1 (S '' $true) -MaxSeconds 20
Assert ($script:slept -eq 20 -and -not $fin.Pending -and -not (Test-StateMatches (ConvertTo-AssignmentState (Find-AssignmentForSelection $fin.List $selG1) $false) (S '' $true))) 'wait: without a sent list, gives up after the limit and reports the real state'

# the sent list wins (measured live: two stale reads in a row happen for minutes after an exclusion change)
$script:LastSent = @{}
$script:clock = [datetime]'2026-09-24T12:00:00'
$script:Now = { $script:clock }
$script:responses = [ordered]@{
    '*/iosManagedAppProtections/ev1/assignments' = @{ value = @($aC) }      # stale: the exclusion of G1 is missing
    '*/iosManagedAppProtections/ev1/assign'      = @{}
}
$script:calls = @()
Invoke-ItemWrite -Item $itemEv -Operation ([PSCustomObject]@{ Key = 'k'; Action = 'Add'; From = $null; To = (S '' $true) }) -Selection $selG1 -VppDeviceLicensing $true
Assert ($script:LastSent.ContainsKey($itemEv.Key)) 'sent list: remembered after a successful MAM write'
$script:calls = @()
Invoke-ItemWrite -Item $itemEv -Operation ([PSCustomObject]@{ Key = 'k'; Action = 'Add'; From = $null; To = (S '' $false) }) -Selection (New-Selection 'group' $gB2 'B') -VppDeviceLicensing $true
$sent2 = @(((Get-Calls 'POST')[0].Body | ConvertFrom-Json).assignments)
Assert ($sent2.Count -eq 3 -and @($sent2 | Where-Object { $_.target.groupId -eq $g1 -and $_.target.'@odata.type' -like '*exclusion*' }).Count -eq 1) 'sent list: the next write keeps the exclusion a stale read would drop'
Assert (@(Get-Calls 'GET').Count -eq 0) 'sent list: the next write does not read at all'
$script:n = 0; $script:slept = 0
$fin = Wait-ItemState $itemEv (New-Selection 'group' $gB2 'B') (S '' $false) -MaxSeconds 10
Assert ($fin.Pending -and $fin.List.Count -eq 3) 'wait: returns the sent list (3 entries) when Intune does not show it yet'
$script:responses['*/iosManagedAppProtections/ev1/assignments'] = @{ value = @($aC) }
$fin = Wait-ItemState $itemEv $selG1 (S '' $true) -MaxSeconds 10
Assert ($fin.Pending -and @($fin.List | Where-Object { $_.target.groupId -eq $g1 }).Count -eq 1) 'wait: stale reads until the limit -> Pending, list = sent list'
$script:clock = $script:clock.AddMinutes(11)
Assert ($null -eq (Get-LastSent $itemEv)) 'sent list: no longer trusted after 10 minutes'
$script:LastSent[$itemDc.Key] = @{ Time = $script:clock; List = @() }
Assert ($null -eq (Get-LastSent $itemDc)) 'sent list: never used for objects that read back reliably'
$script:Now = { Get-Date }; $script:LastSent = @{}
$script:Sleep = { param($s) Start-Sleep -Seconds $s }
Remove-Item Function:\Invoke-MgGraphRequest
#endregion

Write-Host ("{0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit [int]($script:fail -gt 0)
