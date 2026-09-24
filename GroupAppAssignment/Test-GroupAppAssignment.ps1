<#
.SYNOPSIS
    Checks for Manage-GroupAppAssignment.ps1 - no Graph, no GUI, no Pester needed.
    Exit code 0 = all passed. Runs on Windows PowerShell 5.1 and PowerShell 7.

    1. Static: every .ps1 in this folder is UTF-8 with BOM, uses no syntax that Windows
       PowerShell 5.1 cannot parse (?? ?. ?: && || ??=) and calls AddRange(@(...)) only on
       .Controls (5.1 does not bind an object[] to a params array such as Columns.AddRange).
    2. Logic: requested permissions, target matching, request bodies and the add / change / remove plan.
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
#endregion

#region Logic
# Only the part above the marker line: the GUI part needs Windows Forms / System.Drawing.
$main   = [System.IO.File]::ReadAllText((Join-Path $here 'Manage-GroupAppAssignment.ps1'))
$marker = '# ---- end of the GUI-free part'
$cut    = $main.IndexOf($marker)
Assert ($cut -gt 0) 'marker line for the GUI-free part exists'
. ([scriptblock]::Create($main.Substring(0, $cut))) -Language en

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

# Permissions: by default only the two scopes an app-centric bulk tool asks for too (no new consent)
$def = Get-RequestedScopes
Assert (@($def).Count -eq 2 -and $def -contains 'DeviceManagementApps.ReadWrite.All' -and $def -contains 'Group.Read.All') 'default scopes: exactly DeviceManagementApps.ReadWrite.All + Group.Read.All'
Assert ($def -notcontains 'DeviceManagementConfiguration.Read.All') 'default scopes: no filter-names permission'
Assert ((Get-RequestedScopes $true) -contains 'DeviceManagementConfiguration.Read.All') 'filter names on request add DeviceManagementConfiguration.Read.All'

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
    try { $app.Assignments = Get-AppAssignments 'x' } catch { $ok = $false }
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
$opPs = [PSCustomObject]@{ AppId = 'x'; Action = 'Remove'; From = $stPs; To = $null }
Assert ($null -ne (Get-PlanProblem $opPs $selG1)) 'removing a policy-set assignment is rejected'
$opOk = [PSCustomObject]@{ AppId = 'x'; Action = 'Add'; From = $null; To = [PSCustomObject]@{ Intent = 'required'; Exclude = $false } }
Assert ($null -eq (Get-PlanProblem $opOk $selG1)) 'plain add has no problem'
$opBad = [PSCustomObject]@{ AppId = 'x'; Action = 'Add'; From = $null; To = [PSCustomObject]@{ Intent = 'available'; Exclude = $false } }
Assert ($null -ne (Get-PlanProblem $opBad $selAD)) 'plan check applies the target rules'

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
    [PSCustomObject]@{ App = 'Teams';   Type = 'iosVppApp';        Intent = 'Required';  Exclude = $false; Filter = ''; Change = '' },
    [PSCustomObject]@{ App = 'Edge';    Type = 'iosVppApp';        Intent = 'Available'; Exclude = $false; Filter = ''; Change = 'new' },
    [PSCustomObject]@{ App = 'Outlook'; Type = 'iosStoreApp';      Intent = 'Required';  Exclude = $true;  Filter = ''; Change = '' },
    [PSCustomObject]@{ App = 'Authenticator'; Type = 'iosVppApp';  Intent = 'Uninstall'; Exclude = $false; Filter = ''; Change = '' }
)
Assert (((Sort-GridRows $rows 'App' $false) | ForEach-Object { $_.App }) -join ',' -eq 'Authenticator,Edge,Outlook,Teams') 'sort by app'
Assert (((Sort-GridRows $rows 'App' $true) | ForEach-Object { $_.App }) -join ',' -eq 'Teams,Outlook,Edge,Authenticator') 'sort by app, descending'
Assert (((Sort-GridRows $rows 'Type' $false) | ForEach-Object { $_.App }) -join ',' -eq 'Outlook,Authenticator,Edge,Teams') 'sort by type, then app'
Assert (((Sort-GridRows $rows 'Intent' $false) | ForEach-Object { $_.App }) -join ',' -eq 'Edge,Outlook,Teams,Authenticator') 'sort by mode text, then app'
Assert (((Sort-GridRows $rows 'Intent' $true) | ForEach-Object { $_.App }) -join ',' -eq 'Authenticator,Outlook,Teams,Edge') 'sort by mode descending, app stays ascending'
Assert (@(Sort-GridRows @() 'App' $false).Count -eq 0) 'sorting no rows'

$orig = @{ keep = (S 'required'); gone = (S 'available'); intent = (S 'required'); excl = (S 'required') }
$want = @{ keep = (S 'required'); new = (S 'uninstall'); intent = (S 'available'); excl = (S 'required' $true) }
$plan = Get-AssignmentPlan -Original $orig -Desired $want
$byId = @{}; foreach ($p in $plan) { $byId[$p.AppId] = $p.Action }
Assert ($plan.Count -eq 4) "plan has 4 operations (got $($plan.Count))"
Assert ($byId['new'] -eq 'Add') 'plan: new app -> Add'
Assert ($byId['gone'] -eq 'Remove') 'plan: removed app -> Remove'
Assert ($byId['intent'] -eq 'Change') 'plan: other intent -> Change'
Assert ($byId['excl'] -eq 'Change') 'plan: include -> exclude -> Change'
Assert (-not $byId.ContainsKey('keep')) 'plan: unchanged app -> no operation'
Assert ((Get-AssignmentPlan -Original @{} -Desired @{}).Count -eq 0) 'empty plan'
#endregion

Write-Host ("{0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit [int]($script:fail -gt 0)
