<#
.SYNOPSIS
    Intune app assignments seen from a group: which apps are assigned to the group, in which
    mode - and add, change or remove those assignments.

.DESCRIPTION
    Pick an Entra ID group (or All Users / All Devices). The left list shows every Intune app
    that is NOT assigned to that target, the right grid every app that IS assigned, with its
    intent (Required / Available / Uninstall / Available without enrollment), whether it is
    an exclusion and its assignment filter. Arrow buttons move apps across, the mode can be
    changed in the grid; Save writes the difference to Intune and reads the result back.

    Only the assignment for the chosen target is touched; every other assignment of an app
    stays as it is. Needs the Microsoft.Graph.Authentication module (Connect-MgGraph /
    Invoke-MgGraphRequest), Windows PowerShell 5.1 or later.

.PARAMETER GroupId
    Group object ID to open directly, or 'AllUsers' / 'AllDevices'.
.PARAMETER TenantId
    Tenant for Connect-MgGraph (optional).
.PARAMETER VppDeviceLicensing
    License type for NEW assignments of Apple VPP apps (iosVppApp / macOsVppApp):
    $true = device licensing (default), $false = user licensing. Also a checkbox in the window.
.PARAMETER LoadFilterNames
    Show the names of assignment filters instead of their IDs. Needs the additional delegated
    permission DeviceManagementConfiguration.Read.All (a consent prompt, once). Off by default,
    so the tool asks for no more than DeviceManagementApps.ReadWrite.All and Group.Read.All.
    Also a checkbox in the window.
.PARAMETER Language
    auto (UI culture) | de | en
#>
param(
    [string]$GroupId            = "",
    [string]$TenantId           = "",
    [bool]  $VppDeviceLicensing = $true,
    [switch]$LoadFilterNames,
    [ValidateSet('auto','de','en')]
    [string]$Language           = 'auto'
)

#region Localization
$strings = @{
    de = @{
        FormTitle          = 'App-Zuweisungen der Gruppe: {0}'
        FormTitleNoGroup   = 'App-Zuweisungen einer Gruppe verwalten'
        BtnConnect         = 'Verbinden'
        BtnReconnect       = 'Neu verbinden'
        NotConnected       = '(nicht verbunden)'
        ConnectedAs        = 'Verbunden: {0}  ({1})'
        LblGroup           = 'Gruppe / Ziel:'
        NoGroupSelected    = '(kein Ziel gewählt)'
        BtnLoad            = 'Laden'
        LblSearch          = 'Suche:'
        LblType            = 'App-Typ:'
        AllTypes           = '(alle Typen)'
        ChkVpp             = 'VPP neu: Gerätelizenz'
        ChkFilterNames     = 'Filternamen laden'
        FilterNamesFailed  = "Filternamen konnten nicht geladen werden (Berechtigung DeviceManagementConfiguration.Read.All):`n{0}"
        HdrNotAssigned     = 'Nicht zugewiesen'
        HdrAssigned        = 'Zugewiesen'
        BtnRequired        = 'Erforderlich >'
        BtnAvailable       = 'Verfügbar >'
        BtnUninstall       = 'Deinstallieren >'
        BtnExclude         = 'Ausschließen >'
        BtnRemove          = '< Entfernen'
        BtnSave            = 'Speichern'
        ColApp             = 'App'
        ColType            = 'Typ'
        ColIntent          = 'Modus'
        ColExclude         = 'Ausschluss'
        ColFilter          = 'Filter'
        ColChange          = 'Änderung'
        IntentRequired     = 'Erforderlich'
        IntentAvailable    = 'Verfügbar'
        IntentUninstall    = 'Deinstallieren'
        IntentAvailNoEnr   = 'Verfügbar ohne Registrierung'
        ChangeNew          = 'neu'
        ChangeChanged      = 'geändert'
        PendingRemove      = '(wird entfernt)  '
        TargetAllUsers     = 'Alle Benutzer'
        TargetAllDevices   = 'Alle Geräte'
        GroupDynamic       = 'dynamisch'
        PickTitle          = 'Gruppe / Ziel auswählen'
        SearchTerm         = 'Suchbegriff (leer = erste 200 Gruppen):'
        BtnSearch          = 'Suchen'
        BtnSelect          = 'Auswählen'
        BtnCancel          = 'Abbrechen'
        NoResults          = '(keine Ergebnisse)'
        TitleError         = 'Fehler'
        TitleWarning       = 'Warnung'
        TitleSave          = 'Speichern'
        TitleConfirm       = 'Bestätigen'
        ModuleMissing      = "Modul 'Microsoft.Graph.Authentication' nicht gefunden.`nInstall-Module Microsoft.Graph.Authentication -Scope CurrentUser"
        ConnectFailed      = "Verbindung zu Microsoft Graph fehlgeschlagen:`n{0}"
        NotConnectedMsg    = 'Bitte zuerst verbinden.'
        NoGroupMsg         = "Kein Ziel gewählt.`nBitte über '...' eine Gruppe oder Alle Benutzer / Alle Geräte wählen."
        SearchFailed       = "Suche fehlgeschlagen:`n{0}"
        StatusConnecting   = 'Verbinde mit Microsoft Graph...'
        StatusLoadingApps  = 'Lade Apps und Zuweisungen... ({0})'
        StatusLoaded       = '{0} Apps geladen  --  {1} dem Ziel zugewiesen'
        StatusPending      = '{0} Apps  --  {1} zugewiesen  --  {2} ungespeicherte Änderung(en)'
        LoadFailed         = "Fehler beim Laden:`n{0}"
        NoChanges          = 'Keine Änderungen erkannt.'
        SaveConfirm        = "Änderungen für '{0}' speichern?`n`n{1}"
        SaveMore           = '... und {0} weitere'
        OpAdd              = '+ {0}  [{1}]'
        OpRemove           = '- {0}  [{1}]'
        OpChange           = '~ {0}  [{1}  ->  {2}]'
        InvalidTitle       = 'Nicht speicherbar'
        Invalid            = "Diese Zuweisungen sind so nicht möglich:`n`n{0}"
        ErrExcludeSpecial  = 'Ausschluss geht nur für Gruppen, nicht für Alle Benutzer / Alle Geräte'
        ErrAvailAllDevices = "'Verfügbar' kann nicht an Alle Geräte zugewiesen werden"
        StatusSaving       = 'Speichere ({0} / {1}): {2}'
        StatusVerifying    = 'Prüfe Ergebnis in Intune ({0} / {1})...'
        SaveErrors         = "Abgeschlossen mit Fehlern:`n`n{0}"
        SaveOk             = '{0} Änderung(en) gespeichert und in Intune bestätigt.'
        VerifyMismatch     = "Nach dem Speichern weicht Intune bei diesen Apps ab (Anzeige zeigt jetzt den Ist-Stand):`n`n{0}"
        Restored           = 'alte Zuweisung wiederhergestellt'
        RestoreFailed      = 'WIEDERHERSTELLUNG FEHLGESCHLAGEN - App hat jetzt KEINE Zuweisung für dieses Ziel'
        StatusSaved        = 'Gespeichert  --  {0} Änderung(en), {1} Fehler'
        DiscardChanges     = "Es gibt {0} ungespeicherte Änderung(en). Verwerfen?"
        IsExcluded         = 'ausgeschlossen'
        FromPolicySet      = 'Richtliniensatz'
        ErrPolicySet       = 'Zuweisung stammt aus einem Richtliniensatz (Policy Set) - dort ändern'
    }
    en = @{
        FormTitle          = 'App assignments of group: {0}'
        FormTitleNoGroup   = 'Manage app assignments of a group'
        BtnConnect         = 'Connect'
        BtnReconnect       = 'Reconnect'
        NotConnected       = '(not connected)'
        ConnectedAs        = 'Connected: {0}  ({1})'
        LblGroup           = 'Group / target:'
        NoGroupSelected    = '(no target selected)'
        BtnLoad            = 'Load'
        LblSearch          = 'Search:'
        LblType            = 'App type:'
        AllTypes           = '(all types)'
        ChkVpp             = 'New VPP: device license'
        ChkFilterNames     = 'Load filter names'
        FilterNamesFailed  = "Could not load filter names (permission DeviceManagementConfiguration.Read.All):`n{0}"
        HdrNotAssigned     = 'Not assigned'
        HdrAssigned        = 'Assigned'
        BtnRequired        = 'Required >'
        BtnAvailable       = 'Available >'
        BtnUninstall       = 'Uninstall >'
        BtnExclude         = 'Exclude >'
        BtnRemove          = '< Remove'
        BtnSave            = 'Save'
        ColApp             = 'App'
        ColType            = 'Type'
        ColIntent          = 'Mode'
        ColExclude         = 'Exclusion'
        ColFilter          = 'Filter'
        ColChange          = 'Change'
        IntentRequired     = 'Required'
        IntentAvailable    = 'Available'
        IntentUninstall    = 'Uninstall'
        IntentAvailNoEnr   = 'Available without enrollment'
        ChangeNew          = 'new'
        ChangeChanged      = 'changed'
        PendingRemove      = '(to be removed)  '
        TargetAllUsers     = 'All users'
        TargetAllDevices   = 'All devices'
        GroupDynamic       = 'dynamic'
        PickTitle          = 'Select group / target'
        SearchTerm         = 'Search term (empty = first 200 groups):'
        BtnSearch          = 'Search'
        BtnSelect          = 'Select'
        BtnCancel          = 'Cancel'
        NoResults          = '(no results)'
        TitleError         = 'Error'
        TitleWarning       = 'Warning'
        TitleSave          = 'Save'
        TitleConfirm       = 'Confirm'
        ModuleMissing      = "Module 'Microsoft.Graph.Authentication' not found.`nInstall-Module Microsoft.Graph.Authentication -Scope CurrentUser"
        ConnectFailed      = "Connecting to Microsoft Graph failed:`n{0}"
        NotConnectedMsg    = 'Please connect first.'
        NoGroupMsg         = "No target selected.`nUse '...' to choose a group or All users / All devices."
        SearchFailed       = "Search failed:`n{0}"
        StatusConnecting   = 'Connecting to Microsoft Graph...'
        StatusLoadingApps  = 'Loading apps and assignments... ({0})'
        StatusLoaded       = '{0} apps loaded  --  {1} assigned to the target'
        StatusPending      = '{0} apps  --  {1} assigned  --  {2} unsaved change(s)'
        LoadFailed         = "Error while loading:`n{0}"
        NoChanges          = 'No changes detected.'
        SaveConfirm        = "Save changes for '{0}'?`n`n{1}"
        SaveMore           = '... and {0} more'
        OpAdd              = '+ {0}  [{1}]'
        OpRemove           = '- {0}  [{1}]'
        OpChange           = '~ {0}  [{1}  ->  {2}]'
        InvalidTitle       = 'Cannot save'
        Invalid            = "These assignments are not possible:`n`n{0}"
        ErrExcludeSpecial  = 'Exclusions work only for groups, not for All users / All devices'
        ErrAvailAllDevices = "'Available' cannot be assigned to All devices"
        StatusSaving       = 'Saving ({0} / {1}): {2}'
        StatusVerifying    = 'Checking the result in Intune ({0} / {1})...'
        SaveErrors         = "Completed with errors:`n`n{0}"
        SaveOk             = '{0} change(s) saved and confirmed by Intune.'
        VerifyMismatch     = "After saving, Intune differs for these apps (the view now shows the live state):`n`n{0}"
        Restored           = 'previous assignment restored'
        RestoreFailed      = 'RESTORE FAILED - the app now has NO assignment for this target'
        StatusSaved        = 'Saved  --  {0} change(s), {1} error(s)'
        DiscardChanges     = "There are {0} unsaved change(s). Discard them?"
        IsExcluded         = 'excluded'
        FromPolicySet      = 'policy set'
        ErrPolicySet       = 'the assignment comes from a policy set - change it there'
    }
}

$useDe = switch ($Language) {
    'de'    { $true }
    'en'    { $false }
    default { [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'de' }
}
$L = if ($useDe) { $strings.de } else { $strings.en }
#endregion

#region Assignment logic (no GUI, no Graph - covered by Test-GroupAppAssignment.ps1)
$script:GraphBase = 'https://graph.microsoft.com/beta'
$script:BaseScopes  = @('DeviceManagementApps.ReadWrite.All', 'Group.Read.All')
$script:FilterScope = 'DeviceManagementConfiguration.Read.All'   # only for filter names, only on request
$script:Intents   = @('required', 'available', 'uninstall', 'availableWithoutEnrollment')

$script:OdGroup      = '#microsoft.graph.groupAssignmentTarget'
$script:OdExclGroup  = '#microsoft.graph.exclusionGroupAssignmentTarget'
$script:OdAllUsers   = '#microsoft.graph.allLicensedUsersAssignmentTarget'
$script:OdAllDevices = '#microsoft.graph.allDevicesAssignmentTarget'

function Get-RequestedScopes {
    # Delegated permissions for Connect-MgGraph. By default the same two as app-centric bulk tools,
    # so no new consent prompt; the filter-names permission is added only when asked for.
    param([bool]$WithFilterNames = $false)
    $s = @($script:BaseScopes)
    if ($WithFilterNames) { $s += $script:FilterScope }
    return ,$s
}

function Get-IntentText {
    param([string]$Intent)
    switch ($Intent) {
        'required'                   { return $L.IntentRequired }
        'available'                  { return $L.IntentAvailable }
        'uninstall'                  { return $L.IntentUninstall }
        'availableWithoutEnrollment' { return $L.IntentAvailNoEnr }
        default                      { return $Intent }
    }
}

function Get-StateText {
    # "Required" / "Required, excluded"
    param($State)
    if (-not $State) { return '' }
    $t = Get-IntentText $State.Intent
    if ($State.Exclude) { $t = "$t, $($L.IsExcluded)" }
    return $t
}

function New-Selection {
    # A target: Kind = group | allUsers | allDevices
    param([string]$Kind, [string]$Id = '', [string]$Name = '')
    [PSCustomObject]@{ Kind = $Kind; Id = $Id; Name = $Name }
}

function Find-AssignmentForSelection {
    # The assignment of an app that belongs to the selected target (include or exclude), or $null.
    # A direct assignment wins over one that comes from a policy set.
    param($Assignments, $Selection)
    $hit = $null
    foreach ($a in @($Assignments)) {
        if (-not $a) { continue }
        $type  = [string]$a.target.'@odata.type'
        $match = switch ($Selection.Kind) {
            'group'      { ($type -eq $script:OdGroup -or $type -eq $script:OdExclGroup) -and [string]$a.target.groupId -eq $Selection.Id }
            'allUsers'   { $type -eq $script:OdAllUsers }
            'allDevices' { $type -eq $script:OdAllDevices }
            default      { $false }
        }
        if (-not $match) { continue }
        if ([string]$a.source -ne 'policySets') { return $a }
        if (-not $hit) { $hit = $a }
    }
    return $hit
}

function ConvertTo-AssignmentState {
    # Graph assignment -> the state the tool works with; $null stays $null.
    param($Assignment)
    if (-not $Assignment) { return $null }
    $t = $Assignment.target
    [PSCustomObject]@{
        Intent       = [string]$Assignment.intent
        Exclude      = ([string]$t.'@odata.type' -eq $script:OdExclGroup)
        AssignmentId = [string]$Assignment.id
        FilterId     = [string]$t.deviceAndAppManagementAssignmentFilterId
        FilterType   = [string]$t.deviceAndAppManagementAssignmentFilterType
        Settings     = $Assignment.settings
        PolicySet    = ([string]$Assignment.source -eq 'policySets')   # read-only here, changed in the policy set
    }
}

function Test-DesiredAssignment {
    # $null when Intune accepts the combination, otherwise the reason.
    param($Selection, [string]$Intent, [bool]$Exclude)
    if ($Exclude -and $Selection.Kind -ne 'group') { return $L.ErrExcludeSpecial }
    if (-not $Exclude -and $Selection.Kind -eq 'allDevices' -and
        ($Intent -eq 'available' -or $Intent -eq 'availableWithoutEnrollment')) { return $L.ErrAvailAllDevices }
    return $null
}

function Get-PlanProblem {
    # $null when the operation can be written, otherwise the reason.
    param($Operation, $Selection)
    if ($Operation.From -and $Operation.From.PolicySet) { return $L.ErrPolicySet }
    if ($Operation.To) { return (Test-DesiredAssignment $Selection $Operation.To.Intent ([bool]$Operation.To.Exclude)) }
    return $null
}

function New-AssignmentBody {
    # POST body for .../mobileApps/{id}/assignments.
    # $Carry = the previous state of the same target: its filter and settings are kept as long as
    # the assignment stays an include (an exclusion has neither).
    param($Selection, [string]$Intent, [bool]$Exclude, [string]$AppType, [bool]$VppDeviceLicensing, $Carry = $null)

    $target = [ordered]@{}
    switch ($Selection.Kind) {
        'group' {
            $target['@odata.type'] = if ($Exclude) { $script:OdExclGroup } else { $script:OdGroup }
            $target['groupId']     = $Selection.Id
        }
        'allUsers'   { $target['@odata.type'] = $script:OdAllUsers }
        'allDevices' { $target['@odata.type'] = $script:OdAllDevices }
        default      { throw "Unknown target kind '$($Selection.Kind)'" }
    }

    $keep = ($Carry -and -not $Carry.Exclude -and -not $Exclude)
    if ($keep -and $Carry.FilterId -and $Carry.FilterType -and $Carry.FilterType -ne 'none') {
        $target['deviceAndAppManagementAssignmentFilterId']   = $Carry.FilterId
        $target['deviceAndAppManagementAssignmentFilterType'] = $Carry.FilterType
    }

    $body = [ordered]@{
        '@odata.type' = '#microsoft.graph.mobileAppAssignment'
        intent        = $Intent
        target        = $target
    }
    if (-not $Exclude) {
        if ($keep -and $Carry.Settings) {
            $body['settings'] = $Carry.Settings
        } elseif ($AppType -eq 'iosVppApp') {
            $body['settings'] = [ordered]@{
                '@odata.type'      = '#microsoft.graph.iosVppAppAssignmentSettings'
                useDeviceLicensing = $VppDeviceLicensing
            }
        } elseif ($AppType -eq 'macOsVppApp') {
            $body['settings'] = [ordered]@{
                '@odata.type'      = '#microsoft.graph.macOsVppAppAssignmentSettings'
                useDeviceLicensing = $VppDeviceLicensing
            }
        }
    }
    return $body
}

function Get-AssignmentPlan {
    # Original / Desired: hashtable appId -> state (Intent, Exclude). Missing key = not assigned.
    # Returns one operation per app that differs: Add | Remove | Change.
    param([hashtable]$Original, [hashtable]$Desired)
    $ops = New-Object System.Collections.Generic.List[object]
    $ids = New-Object System.Collections.Generic.HashSet[string]
    foreach ($k in $Original.Keys) { [void]$ids.Add([string]$k) }
    foreach ($k in $Desired.Keys)  { [void]$ids.Add([string]$k) }
    foreach ($id in ($ids | Sort-Object)) {
        $o = $Original[$id]; $d = $Desired[$id]
        if (-not $o -and -not $d) { continue }
        if (-not $o) { $ops.Add([PSCustomObject]@{ AppId = $id; Action = 'Add';    From = $null; To = $d    }); continue }
        if (-not $d) { $ops.Add([PSCustomObject]@{ AppId = $id; Action = 'Remove'; From = $o;    To = $null }); continue }
        if ($o.Intent -ne $d.Intent -or [bool]$o.Exclude -ne [bool]$d.Exclude) {
            $ops.Add([PSCustomObject]@{ AppId = $id; Action = 'Change'; From = $o; To = $d })
        }
    }
    return ,$ops
}
#endregion

# ---- end of the GUI-free part (Test-GroupAppAssignment.ps1 loads everything above this line) ----

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

#region Graph
function Get-GraphErrorText {
    param($ErrorRecord)
    $msg = $ErrorRecord.Exception.Message
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        try {
            $j = $ErrorRecord.ErrorDetails.Message | ConvertFrom-Json -ErrorAction Stop
            if ($j.error.message) { $msg = $j.error.message }
        } catch { $msg = $ErrorRecord.ErrorDetails.Message }
    }
    return $msg
}

function Invoke-GraphPaged {
    param([string]$Uri, [hashtable]$Headers = @{}, [scriptblock]$OnPage = $null)
    $all = New-Object System.Collections.Generic.List[object]
    while ($Uri) {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $Uri -Headers $Headers -ErrorAction Stop
        foreach ($v in @($resp.value)) { if ($null -ne $v) { $all.Add($v) } }
        if ($OnPage) { & $OnPage $all.Count }
        $Uri = $resp.'@odata.nextLink'
    }
    return ,$all
}

function Connect-Graph {
    param([bool]$WithFilterNames = $false)
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) { throw $L.ModuleMissing }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $p = @{ Scopes = (Get-RequestedScopes $WithFilterNames); ErrorAction = 'Stop' }
    if ($TenantId) { $p['TenantId'] = $TenantId }
    if ((Get-Command Connect-MgGraph).Parameters.ContainsKey('NoWelcome')) { $p['NoWelcome'] = $true }
    Connect-MgGraph @p | Out-Null
    return Get-MgContext
}

function Search-Groups {
    param([string]$Term)
    $sel = 'id,displayName,groupTypes'
    $Term = $Term.Trim().Replace('"', '')
    if ($Term -and $Term -ne '*') {
        $q   = [System.Uri]::EscapeDataString("`"displayName:$Term`"")
        $uri = "https://graph.microsoft.com/v1.0/groups?`$search=$q&`$select=$sel&`$top=200"
        $resp = Invoke-MgGraphRequest -Method GET -Uri $uri -Headers @{ ConsistencyLevel = 'eventual' } -ErrorAction Stop
    } else {
        $resp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups?`$select=$sel&`$top=200" -ErrorAction Stop
    }
    return @(@($resp.value) | Where-Object { $_ } | Sort-Object { $_.displayName })
}

function Get-AppAssignments {
    param([string]$AppId)
    return @((Invoke-GraphPaged -Uri "$($script:GraphBase)/deviceAppManagement/mobileApps/$AppId/assignments"))
}
#endregion

#region State
$script:Selection   = $null
$script:Connected   = $false
$script:Apps        = New-Object System.Collections.Generic.List[object]   # Id, Name, Type, Publisher, Assignments
$script:AppById     = @{}
$script:Original    = @{}   # appId -> state (live, for the selected target)
$script:Desired     = @{}   # appId -> state (what the user wants)
$script:FilterNames = @{}
$script:Rebuilding  = $false

switch -Regex ($GroupId) {
    '^\s*$'          { break }
    '^(?i)allusers$'   { $script:Selection = New-Selection 'allUsers'   '' $L.TargetAllUsers; break }
    '^(?i)alldevices$' { $script:Selection = New-Selection 'allDevices' '' $L.TargetAllDevices; break }
    default          { $script:Selection = New-Selection 'group' $GroupId.Trim() $GroupId.Trim() }
}

function Get-PendingCount {
    return (Get-AssignmentPlan -Original $script:Original -Desired $script:Desired).Count
}

function Confirm-Discard {
    $n = Get-PendingCount
    if ($n -eq 0) { return $true }
    return ([System.Windows.Forms.MessageBox]::Show(($L.DiscardChanges -f $n), $L.TitleConfirm, 'YesNo', 'Question') -eq 'Yes')
}
#endregion

#region Form
$form = New-Object System.Windows.Forms.Form
$form.Text          = $L.FormTitleNoGroup
$form.Size          = New-Object System.Drawing.Size(1180, 760)
$form.MinimumSize   = New-Object System.Drawing.Size(900, 560)
$form.StartPosition = 'CenterScreen'
$form.Font          = New-Object System.Drawing.Font('Segoe UI', 9)

# --- Top strip ---
$stripTop = New-Object System.Windows.Forms.Panel
$stripTop.Dock = 'Top'; $stripTop.Height = 112
$stripTop.BackColor = [System.Drawing.SystemColors]::Control

$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = $L.BtnConnect; $btnConnect.Location = New-Object System.Drawing.Point(10, 8)
$btnConnect.Size = New-Object System.Drawing.Size(120, 26)

$lblAccount = New-Object System.Windows.Forms.Label
$lblAccount.Text = $L.NotConnected; $lblAccount.AutoSize = $true
$lblAccount.Location = New-Object System.Drawing.Point(140, 13)
$lblAccount.ForeColor = [System.Drawing.SystemColors]::GrayText

$lblGroup = New-Object System.Windows.Forms.Label
$lblGroup.Text = $L.LblGroup; $lblGroup.AutoSize = $true
$lblGroup.Location = New-Object System.Drawing.Point(10, 46)

$txtGroup = New-Object System.Windows.Forms.TextBox
$txtGroup.Location = New-Object System.Drawing.Point(120, 43); $txtGroup.Width = 520
$txtGroup.ReadOnly = $true; $txtGroup.BackColor = [System.Drawing.SystemColors]::Window
$txtGroup.Text = $L.NoGroupSelected

$btnPick = New-Object System.Windows.Forms.Button
$btnPick.Text = '...'; $btnPick.Location = New-Object System.Drawing.Point(646, 42)
$btnPick.Size = New-Object System.Drawing.Size(36, 26)

$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Text = $L.BtnLoad; $btnLoad.Location = New-Object System.Drawing.Point(690, 42)
$btnLoad.Size = New-Object System.Drawing.Size(80, 26)

$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = $L.LblSearch; $lblSearch.AutoSize = $true
$lblSearch.Location = New-Object System.Drawing.Point(10, 81)

$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.Location = New-Object System.Drawing.Point(120, 78); $txtSearch.Width = 260

$lblType = New-Object System.Windows.Forms.Label
$lblType.Text = $L.LblType; $lblType.AutoSize = $true
$lblType.Location = New-Object System.Drawing.Point(392, 81)

$cmbType = New-Object System.Windows.Forms.ComboBox
$cmbType.DropDownStyle = 'DropDownList'
$cmbType.Location = New-Object System.Drawing.Point(460, 78); $cmbType.Width = 220
[void]$cmbType.Items.Add($L.AllTypes); $cmbType.SelectedIndex = 0

$chkVpp = New-Object System.Windows.Forms.CheckBox
$chkVpp.Text = $L.ChkVpp; $chkVpp.AutoSize = $true
$chkVpp.Location = New-Object System.Drawing.Point(692, 80)
$chkVpp.Checked = $VppDeviceLicensing

$chkFilterNames = New-Object System.Windows.Forms.CheckBox
$chkFilterNames.Text = $L.ChkFilterNames; $chkFilterNames.AutoSize = $true
$chkFilterNames.Location = New-Object System.Drawing.Point(870, 80)
$chkFilterNames.Checked = [bool]$LoadFilterNames

$stripTop.Controls.AddRange(@($btnConnect, $lblAccount, $lblGroup, $txtGroup, $btnPick, $btnLoad,
                              $lblSearch, $txtSearch, $lblType, $cmbType, $chkVpp, $chkFilterNames))

# --- Bottom strip ---
$stripBottom = New-Object System.Windows.Forms.Panel
$stripBottom.Dock = 'Bottom'; $stripBottom.Height = 50
$stripBottom.BackColor = [System.Drawing.SystemColors]::Control

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.AutoSize = $false; $lblStatus.Location = New-Object System.Drawing.Point(10, 16)
$lblStatus.Width = 800; $lblStatus.ForeColor = [System.Drawing.SystemColors]::GrayText

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = $L.BtnSave; $btnSave.Size = New-Object System.Drawing.Size(110, 28)
$btnSave.Enabled = $false

$stripBottom.Controls.AddRange(@($lblStatus, $btnSave))
$stripBottom.Add_Resize({
    $btnSave.Location = New-Object System.Drawing.Point(($stripBottom.ClientSize.Width - $btnSave.Width - 10), 11)
    $lblStatus.Width  = $stripBottom.ClientSize.Width - $btnSave.Width - 30
})

$separator = New-Object System.Windows.Forms.Panel
$separator.Dock = 'Bottom'; $separator.Height = 1
$separator.BackColor = [System.Drawing.SystemColors]::ControlDark

# --- Center: list | buttons | grid ---
$boldFont = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

$lblLeft = New-Object System.Windows.Forms.Label
$lblLeft.Text = $L.HdrNotAssigned; $lblLeft.Dock = 'Fill'; $lblLeft.Font = $boldFont; $lblLeft.TextAlign = 'MiddleLeft'

$lblRight = New-Object System.Windows.Forms.Label
$lblRight.Text = $L.HdrAssigned; $lblRight.Dock = 'Fill'; $lblRight.Font = $boldFont; $lblRight.TextAlign = 'MiddleLeft'

$lbLeft = New-Object System.Windows.Forms.ListBox
$lbLeft.Dock = 'Fill'; $lbLeft.SelectionMode = 'MultiExtended'
$lbLeft.ScrollAlwaysVisible = $true; $lbLeft.IntegralHeight = $false; $lbLeft.BorderStyle = 'FixedSingle'

# Intent column source: DataTable, because WinForms data binding does not see PSCustomObject properties
$intentTable = New-Object System.Data.DataTable
[void]$intentTable.Columns.Add('Value', [string])
[void]$intentTable.Columns.Add('Text',  [string])
foreach ($i in $script:Intents) { [void]$intentTable.Rows.Add($i, (Get-IntentText $i)) }

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false; $grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $true
$grid.AutoSizeColumnsMode = 'Fill'; $grid.BackgroundColor = [System.Drawing.SystemColors]::Window
$grid.BorderStyle = 'FixedSingle'; $grid.EditMode = 'EditOnEnter'

$colApp = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colApp.Name = 'App'; $colApp.HeaderText = $L.ColApp; $colApp.ReadOnly = $true; $colApp.FillWeight = 40
$colType = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colType.Name = 'Type'; $colType.HeaderText = $L.ColType; $colType.ReadOnly = $true; $colType.FillWeight = 16
$colIntent = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
$colIntent.Name = 'Intent'; $colIntent.HeaderText = $L.ColIntent; $colIntent.FillWeight = 20
$colIntent.DataSource = $intentTable; $colIntent.ValueMember = 'Value'; $colIntent.DisplayMember = 'Text'
$colIntent.FlatStyle = 'Flat'
$colExcl = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colExcl.Name = 'Exclude'; $colExcl.HeaderText = $L.ColExclude; $colExcl.FillWeight = 9
$colFilter = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colFilter.Name = 'Filter'; $colFilter.HeaderText = $L.ColFilter; $colFilter.ReadOnly = $true; $colFilter.FillWeight = 16
$colChange = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colChange.Name = 'Change'; $colChange.HeaderText = $L.ColChange; $colChange.ReadOnly = $true; $colChange.FillWeight = 9
# One by one: Columns.AddRange takes a params array, and Windows PowerShell 5.1 does not bind an
# object[] to it (Controls.AddRange has no params and works with @(...)).
foreach ($c in @($colApp, $colType, $colIntent, $colExcl, $colFilter, $colChange)) { [void]$grid.Columns.Add($c) }

function New-MoveButton {
    param([string]$Text)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Size = New-Object System.Drawing.Size(130, 28)
    $b.Margin = New-Object System.Windows.Forms.Padding(8, 4, 8, 4); $b.Enabled = $false
    return $b
}
$btnReq    = New-MoveButton $L.BtnRequired
$btnAvl    = New-MoveButton $L.BtnAvailable
$btnUni    = New-MoveButton $L.BtnUninstall
$btnExcl   = New-MoveButton $L.BtnExclude
$btnRemove = New-MoveButton $L.BtnRemove
$script:MoveButtons = @($btnReq, $btnAvl, $btnUni, $btnExcl, $btnRemove)

$arrowPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$arrowPanel.Dock = 'Fill'; $arrowPanel.FlowDirection = 'TopDown'; $arrowPanel.WrapContents = $false
$arrowPanel.Controls.AddRange($script:MoveButtons)
$arrowPanel.Add_Resize({
    $total  = (28 + 8) * 5 + 16
    $topPad = [Math]::Max(0, [int](($arrowPanel.ClientSize.Height - $total) / 2))
    $arrowPanel.Padding = New-Object System.Windows.Forms.Padding(2, $topPad, 2, 0)
})
$btnRemove.Margin = New-Object System.Windows.Forms.Padding(8, 20, 8, 4)

$table = New-Object System.Windows.Forms.TableLayoutPanel
$table.Dock = 'Fill'; $table.ColumnCount = 3; $table.RowCount = 2
$table.Padding = New-Object System.Windows.Forms.Padding(6)
[void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 36)))
[void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 150)))
[void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 64)))
[void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))
[void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$table.Controls.Add($lblLeft,    0, 0)
$table.Controls.Add($lblRight,   2, 0)
$table.Controls.Add($lbLeft,     0, 1)
$table.Controls.Add($arrowPanel, 1, 1)
$table.Controls.Add($grid,       2, 1)

$form.Controls.Add($table)
$form.Controls.Add($separator)
$form.Controls.Add($stripBottom)
$form.Controls.Add($stripTop)
#endregion

#region View
function Test-AppVisible {
    param($App)
    $q = $txtSearch.Text.Trim()
    if ($q -and $App.Name.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -and
        ([string]$App.Publisher).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    if ($cmbType.SelectedIndex -gt 0 -and $App.Type -ne [string]$cmbType.SelectedItem) { return $false }
    return $true
}

function Get-FilterText {
    param($State)
    if (-not $State -or -not $State.FilterId -or $State.FilterType -eq 'none') { return '' }
    $n = $script:FilterNames[$State.FilterId]
    if (-not $n) { $n = $State.FilterId }
    return "$n ($($State.FilterType))"
}

function Update-GridRow {
    param($Row)
    $id = [string]$Row.Tag
    $o = $script:Original[$id]; $d = $script:Desired[$id]
    $change = ''
    $color  = [System.Drawing.SystemColors]::Window
    if (-not $o) {
        $change = $L.ChangeNew; $color = [System.Drawing.Color]::Honeydew
    } elseif ($o.Intent -ne $d.Intent -or [bool]$o.Exclude -ne [bool]$d.Exclude) {
        $change = $L.ChangeChanged; $color = [System.Drawing.Color]::LightYellow
    } elseif ($o.PolicySet) {
        $change = $L.FromPolicySet
    }
    $Row.Cells['Change'].Value = $change
    $Row.DefaultCellStyle.BackColor = $color
}

function Update-Status {
    $pending = Get-PendingCount
    $lblStatus.Text = $L.StatusPending -f $script:Apps.Count, $script:Desired.Count, $pending
    $btnSave.Enabled = ($pending -gt 0)
}

function Update-Views {
    $script:Rebuilding = $true
    try {
        $sorted = @($script:Apps | Sort-Object Name)

        $lbLeft.BeginUpdate()
        $lbLeft.Items.Clear()
        foreach ($a in $sorted) {
            if ($script:Desired.ContainsKey($a.Id) -or -not (Test-AppVisible $a)) { continue }
            $prefix = ''
            if ($script:Original.ContainsKey($a.Id)) { $prefix = $L.PendingRemove }
            $entry = [PSCustomObject]@{ Id = $a.Id; Text = "$prefix$($a.Name)   [$($a.Type)]" }
            $entry | Add-Member -MemberType ScriptMethod -Name ToString -Value { $this.Text } -Force
            [void]$lbLeft.Items.Add($entry)
        }
        $lbLeft.EndUpdate()

        [void]$grid.EndEdit()          # EditOnEnter keeps a cell in edit mode; clearing under it can throw
        $grid.CurrentCell = $null
        $grid.SuspendLayout()
        $grid.Rows.Clear()
        foreach ($a in $sorted) {
            if (-not $script:Desired.ContainsKey($a.Id) -or -not (Test-AppVisible $a)) { continue }
            $d = $script:Desired[$a.Id]
            if ($script:Intents -notcontains $d.Intent -and -not $intentTable.Select("Value = '$($d.Intent)'")) {
                [void]$intentTable.Rows.Add($d.Intent, $d.Intent)   # an intent this tool does not know yet
            }
            $idx = $grid.Rows.Add($a.Name, $a.Type, $d.Intent, [bool]$d.Exclude, (Get-FilterText $script:Original[$a.Id]), '')
            $row = $grid.Rows[$idx]
            $row.Tag = $a.Id
            if ($script:Selection -and $script:Selection.Kind -ne 'group') { $row.Cells['Exclude'].ReadOnly = $true }
            $o = $script:Original[$a.Id]
            if ($o -and $o.PolicySet) {
                $row.ReadOnly = $true
                $row.DefaultCellStyle.ForeColor = [System.Drawing.SystemColors]::GrayText
            }
            Update-GridRow $row
        }
        $grid.ResumeLayout()
    } finally {
        $script:Rebuilding = $false
    }
    Update-Status
}

function Set-Busy {
    param([bool]$Busy)
    $form.Cursor = if ($Busy) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default }
    foreach ($c in @($btnConnect, $btnPick, $btnLoad) + $script:MoveButtons) { $c.Enabled = -not $Busy }
    if ($Busy) { $btnSave.Enabled = $false }
    if (-not $Busy -and $script:Apps.Count -eq 0) { foreach ($b in $script:MoveButtons) { $b.Enabled = $false } }
    $form.Update()
}

function Set-SelectionText {
    if ($script:Selection) {
        $s = $script:Selection
        $txtGroup.Text = if ($s.Kind -eq 'group') { "$($s.Name)  [$($s.Id)]" } else { $s.Name }
        $form.Text = $L.FormTitle -f $s.Name
    } else {
        $txtGroup.Text = $L.NoGroupSelected
        $form.Text = $L.FormTitleNoGroup
    }
}
#endregion

#region Connect / load
function Invoke-Connect {
    Set-Busy $true
    $lblStatus.Text = $L.StatusConnecting; $form.Update()
    try {
        $ctx = Connect-Graph -WithFilterNames $chkFilterNames.Checked
        $script:Connected = $true
        $lblAccount.Text = $L.ConnectedAs -f $ctx.Account, $ctx.TenantId
        $lblAccount.ForeColor = [System.Drawing.SystemColors]::ControlText
        $btnConnect.Text = $L.BtnReconnect
        $lblStatus.Text = ''
        if ($chkFilterNames.Checked) { Update-FilterNames }
    } catch {
        $script:Connected = $false
        [void][System.Windows.Forms.MessageBox]::Show(($L.ConnectFailed -f (Get-GraphErrorText $_)), $L.TitleError, 'OK', 'Error')
        $lblStatus.Text = ''
    } finally {
        Set-Busy $false
    }
}

function Update-FilterNames {
    # Filter names need DeviceManagementConfiguration.Read.All: connect again with it when the current
    # token lacks it (that is the one consent prompt), then read the names. Without names the filter
    # column shows the filter ID.
    $script:FilterNames = @{}
    if ($chkFilterNames.Checked -and $script:Connected) {
        try {
            $ctx = Get-MgContext
            if (@($ctx.Scopes) -notcontains $script:FilterScope) { [void](Connect-Graph -WithFilterNames $true) }
            $f = Invoke-GraphPaged -Uri "$($script:GraphBase)/deviceManagement/assignmentFilters?`$select=id,displayName"
            foreach ($x in $f) { $script:FilterNames[[string]$x.id] = [string]$x.displayName }
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show(($L.FilterNamesFailed -f (Get-GraphErrorText $_)), $L.TitleWarning, 'OK', 'Warning')
            $script:FilterNames = @{}
            $chkFilterNames.Checked = $false   # fires CheckedChanged again, which only clears
        }
    }
}

function Invoke-Load {
    if (-not $script:Connected) {
        [void][System.Windows.Forms.MessageBox]::Show($L.NotConnectedMsg, $L.TitleWarning, 'OK', 'Warning'); return
    }
    if (-not $script:Selection) {
        [void][System.Windows.Forms.MessageBox]::Show($L.NoGroupMsg, $L.TitleWarning, 'OK', 'Warning'); return
    }
    Set-Busy $true
    try {
        $sel = $script:Selection
        if ($sel.Kind -eq 'group' -and $sel.Name -eq $sel.Id) {
            $g = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$($sel.Id)?`$select=id,displayName" -ErrorAction Stop
            $sel.Name = [string]$g.displayName
            Set-SelectionText
        }

        $onPage = { param($n) $lblStatus.Text = $L.StatusLoadingApps -f $n; $form.Update() }
        $appsUri = "$($script:GraphBase)/deviceAppManagement/mobileApps?`$select=id,displayName,publisher"
        $raw = $null
        try { $raw = Invoke-GraphPaged -Uri "$appsUri&`$expand=assignments" -OnPage $onPage } catch { $raw = $null }
        # $expand=assignments is not in the documented query options of the list call: when it fails or
        # comes back without the property, read the assignments app by app instead of showing "nothing assigned".
        $expanded = $false
        if ($raw) { foreach ($r in $raw) { if ($r -is [System.Collections.IDictionary] -and $r.Contains('assignments')) { $expanded = $true; break } } }
        if (-not $expanded) {
            $raw = Invoke-GraphPaged -Uri $appsUri -OnPage $onPage
            $k = 0
            foreach ($r in $raw) {
                $k++
                if ($k % 10 -eq 0 -or $k -eq 1) { $lblStatus.Text = $L.StatusLoadingApps -f "$k / $($raw.Count)"; $form.Update() }
                $r['assignments'] = Get-AppAssignments ([string]$r.id)
            }
        }

        $script:Apps.Clear(); $script:AppById = @{}
        $script:Original = @{}; $script:Desired = @{}
        foreach ($r in $raw) {
            $app = [PSCustomObject]@{
                Id          = [string]$r.id
                Name        = [string]$r.displayName
                Type        = ([string]$r.'@odata.type') -replace '^#microsoft\.graph\.', ''
                Publisher   = [string]$r.publisher
                Assignments = @($r.assignments)
            }
            $script:Apps.Add($app); $script:AppById[$app.Id] = $app
            $st = ConvertTo-AssignmentState (Find-AssignmentForSelection $app.Assignments $sel)
            if ($st) {
                $script:Original[$app.Id] = $st
                $script:Desired[$app.Id]  = [PSCustomObject]@{ Intent = $st.Intent; Exclude = $st.Exclude }
            }
        }

        $keep = [string]$cmbType.SelectedItem
        $cmbType.Items.Clear(); [void]$cmbType.Items.Add($L.AllTypes)
        foreach ($t in ($script:Apps | ForEach-Object { $_.Type } | Sort-Object -Unique)) { [void]$cmbType.Items.Add($t) }
        $cmbType.SelectedIndex = [Math]::Max(0, $cmbType.Items.IndexOf($keep))

        Update-Views
        $lblStatus.Text = $L.StatusLoaded -f $script:Apps.Count, $script:Original.Count
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(($L.LoadFailed -f (Get-GraphErrorText $_)), $L.TitleError, 'OK', 'Error')
    } finally {
        Set-Busy $false
        $btnSave.Enabled = ((Get-PendingCount) -gt 0)
    }
}
#endregion

#region Group picker
function Show-GroupPicker {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $L.PickTitle
    $dlg.ClientSize = New-Object System.Drawing.Size(560, 430)
    $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $false; $dlg.Font = $form.Font

    $lblS = New-Object System.Windows.Forms.Label
    $lblS.Text = $L.SearchTerm; $lblS.AutoSize = $true; $lblS.Location = New-Object System.Drawing.Point(10, 12)
    $txtS = New-Object System.Windows.Forms.TextBox
    $txtS.Location = New-Object System.Drawing.Point(10, 32); $txtS.Width = 446
    $btnS = New-Object System.Windows.Forms.Button
    $btnS.Text = $L.BtnSearch; $btnS.Location = New-Object System.Drawing.Point(464, 30); $btnS.Size = New-Object System.Drawing.Size(85, 26)
    $lbRes = New-Object System.Windows.Forms.ListBox
    $lbRes.Location = New-Object System.Drawing.Point(10, 66); $lbRes.Size = New-Object System.Drawing.Size(539, 316)
    $lbRes.ScrollAlwaysVisible = $true; $lbRes.IntegralHeight = $false
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = $L.BtnSelect; $btnOk.DialogResult = 'OK'; $btnOk.Enabled = $false
    $btnOk.Location = New-Object System.Drawing.Point(360, 392); $btnOk.Size = New-Object System.Drawing.Size(90, 28)
    $btnC = New-Object System.Windows.Forms.Button
    $btnC.Text = $L.BtnCancel; $btnC.DialogResult = 'Cancel'
    $btnC.Location = New-Object System.Drawing.Point(459, 392); $btnC.Size = New-Object System.Drawing.Size(90, 28)
    $dlg.Controls.AddRange(@($lblS, $txtS, $btnS, $lbRes, $btnOk, $btnC))
    $dlg.CancelButton = $btnC

    $script:_pick = New-Object System.Collections.Generic.List[object]
    $doSearch = {
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $script:_pick.Clear()
            $script:_pick.Add((New-Selection 'allUsers'   '' $L.TargetAllUsers))
            $script:_pick.Add((New-Selection 'allDevices' '' $L.TargetAllDevices))
            foreach ($g in (Search-Groups $txtS.Text)) {
                $n = [string]$g.displayName
                if (@($g.groupTypes) -contains 'DynamicMembership') { $n = "$n  ($($L.GroupDynamic))" }
                $script:_pick.Add((New-Selection 'group' ([string]$g.id) $n))
            }
            $lbRes.BeginUpdate(); $lbRes.Items.Clear()
            foreach ($p in $script:_pick) {
                if ($p.Kind -eq 'group') { [void]$lbRes.Items.Add("$($p.Name)   [$($p.Id)]") }
                else { [void]$lbRes.Items.Add("* $($p.Name)") }
            }
            if ($script:_pick.Count -eq 2) { [void]$lbRes.Items.Add($L.NoResults) }
            $lbRes.EndUpdate()
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show(($L.SearchFailed -f (Get-GraphErrorText $_)), $L.TitleError, 'OK', 'Error')
        } finally {
            $dlg.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }
    $isPick = { $lbRes.SelectedIndex -ge 0 -and $lbRes.SelectedIndex -lt $script:_pick.Count }
    $dlg.Add_Shown($doSearch)
    $btnS.Add_Click($doSearch)
    $txtS.Add_KeyDown({ if ($_.KeyCode -eq 'Return') { $_.SuppressKeyPress = $true; & $doSearch } })
    $lbRes.Add_SelectedIndexChanged({ $btnOk.Enabled = (& $isPick) })
    $lbRes.Add_DoubleClick({ if (& $isPick) { $dlg.DialogResult = 'OK'; $dlg.Close() } })

    $result = $null
    if ($dlg.ShowDialog($form) -eq 'OK' -and (& $isPick)) {
        $p = $script:_pick[$lbRes.SelectedIndex]
        $result = New-Selection $p.Kind $p.Id ($p.Name -replace "  \($([regex]::Escape($L.GroupDynamic))\)$", '')
    }
    $dlg.Dispose()
    return $result
}
#endregion

#region Move / edit
function Add-SelectedApps {
    param([string]$Intent, [bool]$Exclude)
    $items = @($lbLeft.SelectedItems)
    if (-not $items) { return }
    foreach ($it in $items) {
        $o = $script:Original[$it.Id]
        if ($o -and $o.Intent -eq $Intent -and [bool]$o.Exclude -eq $Exclude) {
            $script:Desired[$it.Id] = [PSCustomObject]@{ Intent = $o.Intent; Exclude = $o.Exclude }
        } else {
            $script:Desired[$it.Id] = [PSCustomObject]@{ Intent = $Intent; Exclude = $Exclude }
        }
    }
    Update-Views
}

$btnReq.Add_Click({  Add-SelectedApps 'required'  $false })
$btnAvl.Add_Click({  Add-SelectedApps 'available' $false })
$btnUni.Add_Click({  Add-SelectedApps 'uninstall' $false })
$btnExcl.Add_Click({ Add-SelectedApps 'required'  $true  })
$btnRemove.Add_Click({
    $ids = @($grid.SelectedRows | ForEach-Object { [string]$_.Tag })
    if (-not $ids) { return }
    foreach ($id in $ids) {
        $o = $script:Original[$id]
        if ($o -and $o.PolicySet) { continue }   # only the policy set can remove it
        $script:Desired.Remove($id)
    }
    Update-Views
})
$lbLeft.Add_DoubleClick({ Add-SelectedApps 'required' $false })

# Commit combo / checkbox edits at once instead of when the cell is left
$grid.Add_CurrentCellDirtyStateChanged({
    if ($grid.IsCurrentCellDirty) { [void]$grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) }
})
$grid.Add_CellValueChanged({
    param($s, $e)
    if ($script:Rebuilding -or $e.RowIndex -lt 0) { return }
    $row = $grid.Rows[$e.RowIndex]
    $id  = [string]$row.Tag
    if (-not $script:Desired.ContainsKey($id)) { return }
    $script:Desired[$id] = [PSCustomObject]@{
        Intent  = [string]$row.Cells['Intent'].Value
        Exclude = [bool]$row.Cells['Exclude'].Value
    }
    Update-GridRow $row
    Update-Status
})
$grid.Add_DataError({ param($s, $e) $e.ThrowException = $false })

$txtSearch.Add_TextChanged({ Update-Views })
$chkFilterNames.Add_CheckedChanged({
    if (-not $script:Connected) { return }   # applied at the next connect
    Set-Busy $true
    try { Update-FilterNames } finally { Set-Busy $false }
    Update-Views
})
$cmbType.Add_SelectedIndexChanged({ if (-not $script:Rebuilding) { Update-Views } })
#endregion

#region Save
function Invoke-Save {
    $plan = Get-AssignmentPlan -Original $script:Original -Desired $script:Desired
    if ($plan.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show($L.NoChanges, $L.TitleSave, 'OK', 'Information'); return
    }
    $sel = $script:Selection

    $invalid = New-Object System.Collections.Generic.List[string]
    foreach ($op in $plan) {
        $why = Get-PlanProblem $op $sel
        if ($why) { $invalid.Add("$($script:AppById[$op.AppId].Name): $why") }
    }
    if ($invalid.Count -gt 0) {
        [void][System.Windows.Forms.MessageBox]::Show(($L.Invalid -f ($invalid -join "`n")), $L.InvalidTitle, 'OK', 'Warning'); return
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($op in $plan) {
        $n = $script:AppById[$op.AppId].Name
        switch ($op.Action) {
            'Add'    { $lines.Add(($L.OpAdd    -f $n, (Get-StateText $op.To))) }
            'Remove' { $lines.Add(($L.OpRemove -f $n, (Get-StateText $op.From))) }
            'Change' { $lines.Add(($L.OpChange -f $n, (Get-StateText $op.From), (Get-StateText $op.To))) }
        }
    }
    $shown = @($lines | Select-Object -First 25)
    if ($lines.Count -gt 25) { $shown += ($L.SaveMore -f ($lines.Count - 25)) }
    if ([System.Windows.Forms.MessageBox]::Show(($L.SaveConfirm -f $sel.Name, ($shown -join "`n")),
            $L.TitleConfirm, 'YesNo', 'Question') -ne 'Yes') { return }

    Set-Busy $true
    $errs = New-Object System.Collections.Generic.List[string]
    $vpp  = $chkVpp.Checked
    $i = 0
    try {
        foreach ($op in $plan) {
            $i++
            $app = $script:AppById[$op.AppId]
            $lblStatus.Text = $L.StatusSaving -f $i, $plan.Count, $app.Name; $form.Update()
            $base = "$($script:GraphBase)/deviceAppManagement/mobileApps/$($app.Id)/assignments"
            try {
                if ($op.Action -eq 'Remove' -or $op.Action -eq 'Change') {
                    Invoke-MgGraphRequest -Method DELETE -Uri "$base/$($op.From.AssignmentId)" -ErrorAction Stop | Out-Null
                }
                if ($op.Action -eq 'Add' -or $op.Action -eq 'Change') {
                    $body = New-AssignmentBody -Selection $sel -Intent $op.To.Intent -Exclude ([bool]$op.To.Exclude) `
                                -AppType $app.Type -VppDeviceLicensing $vpp -Carry $op.From
                    try {
                        Invoke-MgGraphRequest -Method POST -Uri $base -Body ($body | ConvertTo-Json -Depth 10) `
                            -ContentType 'application/json' -ErrorAction Stop | Out-Null
                    } catch {
                        $msg = Get-GraphErrorText $_
                        if ($op.Action -eq 'Change') {
                            # the old assignment is already gone: put it back as it was
                            $restore = New-AssignmentBody -Selection $sel -Intent $op.From.Intent -Exclude ([bool]$op.From.Exclude) `
                                           -AppType $app.Type -VppDeviceLicensing $vpp -Carry $op.From
                            try {
                                Invoke-MgGraphRequest -Method POST -Uri $base -Body ($restore | ConvertTo-Json -Depth 10) `
                                    -ContentType 'application/json' -ErrorAction Stop | Out-Null
                                $msg = "$msg ($($L.Restored))"
                            } catch { $msg = "$msg ($($L.RestoreFailed))" }
                        }
                        throw $msg
                    }
                }
            } catch {
                $sym = switch ($op.Action) { 'Add' { '+' } 'Remove' { '-' } default { '~' } }
                $text = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { "$_" }
                if ($_.ErrorDetails) { $text = Get-GraphErrorText $_ }
                $errs.Add("$sym $($app.Name): $text")
            }
        }

        # Read back what Intune really has now, per touched app
        $mismatch = New-Object System.Collections.Generic.List[string]
        $j = 0
        foreach ($op in $plan) {
            $j++
            $lblStatus.Text = $L.StatusVerifying -f $j, $plan.Count; $form.Update()
            $app = $script:AppById[$op.AppId]
            try {
                $app.Assignments = Get-AppAssignments $app.Id
            } catch {
                $errs.Add("? $($app.Name): $(Get-GraphErrorText $_)"); continue
            }
            $live = ConvertTo-AssignmentState (Find-AssignmentForSelection $app.Assignments $sel)
            if ($live) {
                $script:Original[$app.Id] = $live
                $script:Desired[$app.Id]  = [PSCustomObject]@{ Intent = $live.Intent; Exclude = $live.Exclude }
            } else {
                $script:Original.Remove($app.Id); $script:Desired.Remove($app.Id)
            }
            $want = $op.To
            $ok = if (-not $want) { -not $live } else { $live -and $live.Intent -eq $want.Intent -and [bool]$live.Exclude -eq [bool]$want.Exclude }
            if (-not $ok) { $mismatch.Add("$($app.Name): $(Get-StateText $want)  <>  $(Get-StateText $live)") }
        }
    } finally {
        Set-Busy $false
    }

    Update-Views
    $lblStatus.Text = $L.StatusSaved -f $plan.Count, $errs.Count
    if ($errs.Count -gt 0) {
        [void][System.Windows.Forms.MessageBox]::Show(($L.SaveErrors -f ($errs -join "`n")), $L.TitleWarning, 'OK', 'Warning')
    }
    if ($mismatch.Count -gt 0 -and $errs.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show(($L.VerifyMismatch -f ($mismatch -join "`n")), $L.TitleWarning, 'OK', 'Warning')
    }
    if ($errs.Count -eq 0 -and $mismatch.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show(($L.SaveOk -f $plan.Count), $L.TitleSave, 'OK', 'Information')
    }
}
#endregion

#region Wiring
$btnConnect.Add_Click({ Invoke-Connect })
$btnLoad.Add_Click({ if (Confirm-Discard) { Invoke-Load } })
$btnSave.Add_Click({ Invoke-Save })
$btnPick.Add_Click({
    if (-not $script:Connected) { Invoke-Connect; if (-not $script:Connected) { return } }
    if (-not (Confirm-Discard)) { return }
    $p = Show-GroupPicker
    if ($p) {
        $script:Selection = $p
        Set-SelectionText
        $script:Original = @{}; $script:Desired = @{}
        Invoke-Load
    }
})
$form.Add_FormClosing({ param($s, $e) if (-not (Confirm-Discard)) { $e.Cancel = $true } })
$form.Add_Shown({
    Set-SelectionText
    if ($script:Selection) {
        Invoke-Connect
        if ($script:Connected) { Invoke-Load }
    }
})

[void]$form.ShowDialog()
$form.Dispose()
#endregion
