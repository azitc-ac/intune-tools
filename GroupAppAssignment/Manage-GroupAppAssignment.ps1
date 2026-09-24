<#
.SYNOPSIS
    Intune assignments seen from a group: which apps, configuration profiles, compliance policies,
    app configuration and app protection policies are assigned to the group, in which mode - and
    add, change or remove those assignments.

.DESCRIPTION
    Pick an Entra ID group (or All Users / All Devices) and a category on the left. The middle list
    shows every object of that category that is NOT assigned to the target, the grid on the right
    every object that IS assigned: for apps with their intent (Required / Available / Uninstall /
    Available without enrollment), for all objects whether it is an exclusion and the assignment
    filter. Buttons move objects across, mode and exclusion can be changed in the grid; Save writes
    the difference to Intune and reads the result back.

    Only the assignment for the chosen target is touched; every other assignment of an object stays
    as it is. Apps need DeviceManagementApps.ReadWrite.All; the other categories additionally
    DeviceManagementConfiguration.ReadWrite.All, requested only when such a category is opened.
    Needs the Microsoft.Graph.Authentication module, Windows PowerShell 5.1 or later.

.PARAMETER GroupId
    Group object ID to open directly, or 'AllUsers' / 'AllDevices'.
.PARAMETER TenantId
    Tenant for Connect-MgGraph (optional).
.PARAMETER Platform
    Show only objects for this platform: iOS (default), macOS, Android, Windows or All.
    Objects without a platform (web apps, policy sets, ...) are always shown. Also a list in the window.
.PARAMETER VppDeviceLicensing
    License type for NEW assignments of Apple VPP apps (iosVppApp / macOsVppApp):
    $true = device licensing (default), $false = user licensing. Also a checkbox in the window.
.PARAMETER LoadFilterNames
    Show the names of assignment filters instead of their IDs. Needs the additional delegated
    permission DeviceManagementConfiguration.Read.All (a consent prompt, once) unless a category
    beyond apps is open anyway. Also a checkbox in the window.
.PARAMETER Language
    auto (UI culture) | de | en
#>
param(
    [string]$GroupId            = "",
    [string]$TenantId           = "",
    [ValidateSet('iOS','macOS','Android','Windows','All')]
    [string]$Platform           = 'iOS',
    [bool]  $VppDeviceLicensing = $true,
    [switch]$LoadFilterNames,
    [ValidateSet('auto','de','en')]
    [string]$Language           = 'auto'
)

#region Localization
$strings = @{
    de = @{
        FormTitle          = 'Zuweisungen der Gruppe: {0}'
        FormTitleNoGroup   = 'Intune-Zuweisungen einer Gruppe verwalten'
        BtnConnect         = 'Verbinden'
        BtnReconnect       = 'Neu verbinden'
        NotConnected       = '(nicht verbunden)'
        ConnectedAs        = 'Verbunden: {0}  ({1})'
        LblGroup           = 'Gruppe / Ziel:'
        NoGroupSelected    = '(kein Ziel gewählt)'
        BtnLoad            = 'Laden'
        LblSearch          = 'Suche:'
        LblType            = 'Typ:'
        LblPlatform        = 'Plattform:'
        AllTypes           = '(alle Typen)'
        PlatformAll        = 'Alle'
        ChkVpp             = 'VPP neu: Gerätelizenz'
        ChkFilterNames     = 'Filternamen laden'
        FilterNamesFailed  = "Filternamen konnten nicht geladen werden (Berechtigung DeviceManagementConfiguration.Read.All):`n{0}"
        HdrCategory        = 'Kategorie'
        HdrNotAssigned     = 'Nicht zugewiesen'
        HdrAssigned        = 'Zugewiesen'
        CatAll             = 'Alle'
        CatApps            = 'Apps'
        CatConfig          = 'Konfigurationsprofile'
        CatCompliance      = 'Compliance'
        CatAppConfig       = 'App-Konfiguration'
        CatAppProtection   = 'App-Schutz'
        TypeMamAppConfig   = 'verwaltete Apps (MAM)'
        CatNotLoaded       = '{0}  (...)'
        CatCounts          = '{0}  ({1} / {2})'
        TypeSettingsCatalog = 'Einstellungskatalog'
        BtnRequired        = 'Erforderlich >'
        BtnAvailable       = 'Verfügbar >'
        BtnUninstall       = 'Deinstallieren >'
        BtnAssign          = 'Zuweisen >'
        BtnExclude         = 'Ausschließen >'
        BtnRemove          = '< Entfernen'
        BtnSave            = 'Speichern'
        ColName            = 'Name'
        ColCategory        = 'Kategorie'
        ColType            = 'Typ'
        ColIntent          = 'Modus'
        ColExclude         = 'Ausschluss'
        ColFilter          = 'Filter'
        ColChange          = 'Änderung'
        IntentRequired     = 'Erforderlich'
        IntentAvailable    = 'Verfügbar'
        IntentUninstall    = 'Deinstallieren'
        IntentAvailNoEnr   = 'Verfügbar ohne Registrierung'
        NoIntent           = '-'
        StateIncluded      = 'eingeschlossen'
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
        StatusLoadingCat   = 'Lade {0}... ({1})'
        StatusLoaded       = '{0} Objekte geladen  --  {1} dem Ziel zugewiesen'
        StatusPending      = '{0} Objekte  --  {1} zugewiesen  --  {2} ungespeicherte Änderung(en)'
        LoadFailed         = "Fehler beim Laden:`n{0}"
        CategoryLoadFailed = "'{0}' konnte nicht geladen werden (Berechtigung DeviceManagementConfiguration.ReadWrite.All?):`n{1}"
        NoChanges          = 'Keine Änderungen erkannt.'
        SaveConfirm        = "Änderungen für '{0}' speichern?`n`n{1}"
        SaveMore           = '... und {0} weitere'
        OpAdd              = '+ [{0}] {1}  [{2}]'
        OpRemove           = '- [{0}] {1}  [{2}]'
        OpChange           = '~ [{0}] {1}  [{2}  ->  {3}]'
        InvalidTitle       = 'Nicht speicherbar'
        Invalid            = "Diese Zuweisungen sind so nicht möglich:`n`n{0}"
        ErrExcludeSpecial  = 'Ausschluss geht nur für Gruppen, nicht für Alle Benutzer / Alle Geräte'
        ErrAvailAllDevices = "'Verfügbar' kann nicht an Alle Geräte zugewiesen werden"
        ErrUsersOnly       = 'geht nur an Benutzer (Gruppen mit Benutzern oder Alle Benutzer), nicht an Alle Geräte'
        StatusSaving       = 'Speichere ({0} / {1}): {2}'
        StatusVerifying    = 'Prüfe Ergebnis in Intune ({0} / {1})...'
        SaveErrors         = "Abgeschlossen mit Fehlern:`n`n{0}"
        VerifyFailedHint   = "`n`n'?' = gespeichert, aber das Ergebnis konnte nicht aus Intune gelesen werden - die Anzeige kann veraltet sein, bitte 'Laden' klicken."
        SaveOk             = '{0} Änderung(en) gespeichert und in Intune bestätigt.'
        VerifyMismatch     = "Nach dem Speichern weicht Intune bei diesen Objekten ab (Anzeige zeigt jetzt den Ist-Stand):`n`n{0}"
        Restored           = 'alte Zuweisung wiederhergestellt'
        RestoreFailed      = 'WIEDERHERSTELLUNG FEHLGESCHLAGEN - das Objekt hat jetzt KEINE Zuweisung für dieses Ziel'
        StatusSaved        = 'Gespeichert  --  {0} Änderung(en), {1} Fehler'
        DiscardChanges     = "Es gibt {0} ungespeicherte Änderung(en). Verwerfen?"
        IsExcluded         = 'ausgeschlossen'
        FromPolicySet      = 'Richtliniensatz'
        ErrPolicySet       = 'Zuweisung stammt aus einem Richtliniensatz (Policy Set) - dort ändern'
    }
    en = @{
        FormTitle          = 'Assignments of group: {0}'
        FormTitleNoGroup   = 'Manage the Intune assignments of a group'
        BtnConnect         = 'Connect'
        BtnReconnect       = 'Reconnect'
        NotConnected       = '(not connected)'
        ConnectedAs        = 'Connected: {0}  ({1})'
        LblGroup           = 'Group / target:'
        NoGroupSelected    = '(no target selected)'
        BtnLoad            = 'Load'
        LblSearch          = 'Search:'
        LblType            = 'Type:'
        LblPlatform        = 'Platform:'
        AllTypes           = '(all types)'
        PlatformAll        = 'All'
        ChkVpp             = 'New VPP: device license'
        ChkFilterNames     = 'Load filter names'
        FilterNamesFailed  = "Could not load filter names (permission DeviceManagementConfiguration.Read.All):`n{0}"
        HdrCategory        = 'Category'
        HdrNotAssigned     = 'Not assigned'
        HdrAssigned        = 'Assigned'
        CatAll             = 'All'
        CatApps            = 'Apps'
        CatConfig          = 'Configuration profiles'
        CatCompliance      = 'Compliance'
        CatAppConfig       = 'App configuration'
        CatAppProtection   = 'App protection'
        TypeMamAppConfig   = 'managed apps (MAM)'
        CatNotLoaded       = '{0}  (...)'
        CatCounts          = '{0}  ({1} / {2})'
        TypeSettingsCatalog = 'Settings catalog'
        BtnRequired        = 'Required >'
        BtnAvailable       = 'Available >'
        BtnUninstall       = 'Uninstall >'
        BtnAssign          = 'Assign >'
        BtnExclude         = 'Exclude >'
        BtnRemove          = '< Remove'
        BtnSave            = 'Save'
        ColName            = 'Name'
        ColCategory        = 'Category'
        ColType            = 'Type'
        ColIntent          = 'Mode'
        ColExclude         = 'Exclusion'
        ColFilter          = 'Filter'
        ColChange          = 'Change'
        IntentRequired     = 'Required'
        IntentAvailable    = 'Available'
        IntentUninstall    = 'Uninstall'
        IntentAvailNoEnr   = 'Available without enrollment'
        NoIntent           = '-'
        StateIncluded      = 'included'
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
        StatusLoadingCat   = 'Loading {0}... ({1})'
        StatusLoaded       = '{0} objects loaded  --  {1} assigned to the target'
        StatusPending      = '{0} objects  --  {1} assigned  --  {2} unsaved change(s)'
        LoadFailed         = "Error while loading:`n{0}"
        CategoryLoadFailed = "Could not load '{0}' (permission DeviceManagementConfiguration.ReadWrite.All?):`n{1}"
        NoChanges          = 'No changes detected.'
        SaveConfirm        = "Save changes for '{0}'?`n`n{1}"
        SaveMore           = '... and {0} more'
        OpAdd              = '+ [{0}] {1}  [{2}]'
        OpRemove           = '- [{0}] {1}  [{2}]'
        OpChange           = '~ [{0}] {1}  [{2}  ->  {3}]'
        InvalidTitle       = 'Cannot save'
        Invalid            = "These assignments are not possible:`n`n{0}"
        ErrExcludeSpecial  = 'Exclusions work only for groups, not for All users / All devices'
        ErrAvailAllDevices = "'Available' cannot be assigned to All devices"
        ErrUsersOnly       = 'can only be assigned to users (groups of users or All users), not to All devices'
        StatusSaving       = 'Saving ({0} / {1}): {2}'
        StatusVerifying    = 'Checking the result in Intune ({0} / {1})...'
        SaveErrors         = "Completed with errors:`n`n{0}"
        VerifyFailedHint   = "`n`n'?' = saved, but the result could not be read back from Intune - the view may be out of date, please click 'Load'."
        SaveOk             = '{0} change(s) saved and confirmed by Intune.'
        VerifyMismatch     = "After saving, Intune differs for these objects (the view now shows the live state):`n`n{0}"
        Restored           = 'previous assignment restored'
        RestoreFailed      = 'RESTORE FAILED - the object now has NO assignment for this target'
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
$script:GraphBase   = 'https://graph.microsoft.com/beta'
$script:BaseScopes  = @('DeviceManagementApps.ReadWrite.All', 'Group.Read.All')
$script:FilterScope = 'DeviceManagementConfiguration.Read.All'        # only for filter names, only on request
$script:ConfigScope = 'DeviceManagementConfiguration.ReadWrite.All'   # every category beyond apps, only when opened
$script:Intents     = @('required', 'available', 'uninstall', 'availableWithoutEnrollment')
$script:Platforms   = @('iOS', 'macOS', 'Android', 'Windows', 'All')

$script:OdGroup      = '#microsoft.graph.groupAssignmentTarget'
$script:OdExclGroup  = '#microsoft.graph.exclusionGroupAssignmentTarget'
$script:OdAllUsers   = '#microsoft.graph.allLicensedUsersAssignmentTarget'
$script:OdAllDevices = '#microsoft.graph.allDevicesAssignmentTarget'

function New-Source {
    # One Graph collection that feeds a category.
    #   List           collection URI below /beta, with $select (the tool appends &$expand=assignments)
    #   ItemPath       path of one object, {0} = its id; its assignments are ItemPath/assignments
    #   Write          Single  = POST ItemPath/assignments + DELETE ItemPath/assignments/{id} per assignment
    #                  Replace = POST AssignAction with the object's complete assignment list
    #   AssignmentType @odata.type of an assignment object in the request body
    #   UsersOnly      the objects apply to users only (MAM): All devices is rejected
    #   TypeName       shown as type instead of the @odata.type (settings catalog has one type)
    param([string]$List, [string]$ItemPath, [string]$Write, [string]$AssignmentType,
          [string]$AssignAction = '', [string]$NameProp = 'displayName', [bool]$UsersOnly = $false, [string]$TypeName = '')
    [PSCustomObject]@{
        List = $List; ItemPath = $ItemPath; Write = $Write; AssignmentType = $AssignmentType
        AssignAction = $AssignAction; NameProp = $NameProp; UsersOnly = $UsersOnly; TypeName = $TypeName
    }
}

function Get-CategoryTable {
    # Every category the tool can show: one shared load / plan / write / verify path for all of them.
    $t = [ordered]@{}
    $t['apps'] = [PSCustomObject]@{
        Key = 'apps'; Label = $L.CatApps; HasIntent = $true; NeedsConfigScope = $false
        Sources = @(
            (New-Source -List 'deviceAppManagement/mobileApps?$select=id,displayName,publisher' `
                        -ItemPath 'deviceAppManagement/mobileApps/{0}' -Write 'Single' `
                        -AssignmentType '#microsoft.graph.mobileAppAssignment')
        )
    }
    $t['config'] = [PSCustomObject]@{
        Key = 'config'; Label = $L.CatConfig; HasIntent = $false; NeedsConfigScope = $true
        Sources = @(
            (New-Source -List 'deviceManagement/deviceConfigurations?$select=id,displayName' `
                        -ItemPath 'deviceManagement/deviceConfigurations/{0}' -Write 'Single' `
                        -AssignmentType '#microsoft.graph.deviceConfigurationAssignment'),
            # settings catalog: /assign is the documented write path (single create/delete are listed on
            # the resource page, but their method pages do not exist)
            (New-Source -List 'deviceManagement/configurationPolicies?$select=id,name,platforms,technologies' `
                        -ItemPath 'deviceManagement/configurationPolicies/{0}' -Write 'Replace' `
                        -AssignAction 'deviceManagement/configurationPolicies/{0}/assign' -NameProp 'name' `
                        -AssignmentType '#microsoft.graph.deviceManagementConfigurationPolicyAssignment' `
                        -TypeName $L.TypeSettingsCatalog)
        )
    }
    $t['compliance'] = [PSCustomObject]@{
        Key = 'compliance'; Label = $L.CatCompliance; HasIntent = $false; NeedsConfigScope = $true
        Sources = @(
            (New-Source -List 'deviceManagement/deviceCompliancePolicies?$select=id,displayName' `
                        -ItemPath 'deviceManagement/deviceCompliancePolicies/{0}' -Write 'Single' `
                        -AssignmentType '#microsoft.graph.deviceCompliancePolicyAssignment')
        )
    }
    $t['appConfig'] = [PSCustomObject]@{
        Key = 'appConfig'; Label = $L.CatAppConfig; HasIntent = $false; NeedsConfigScope = $true
        Sources = @(
            (New-Source -List 'deviceAppManagement/mobileAppConfigurations?$select=id,displayName' `
                        -ItemPath 'deviceAppManagement/mobileAppConfigurations/{0}' -Write 'Single' `
                        -AssignmentType '#microsoft.graph.managedDeviceMobileAppConfigurationAssignment'),
            # managed apps (MAM): users only, written as a complete list through /assign
            (New-Source -List 'deviceAppManagement/targetedManagedAppConfigurations?$select=id,displayName' `
                        -ItemPath 'deviceAppManagement/targetedManagedAppConfigurations/{0}' -Write 'Replace' `
                        -AssignAction 'deviceAppManagement/targetedManagedAppConfigurations/{0}/assign' `
                        -AssignmentType '#microsoft.graph.targetedManagedAppPolicyAssignment' -UsersOnly $true `
                        -TypeName $L.TypeMamAppConfig)
        )
    }
    # app protection: users only; read per platform collection, written through managedAppPolicies/{id}/assign
    $t['appProtection'] = [PSCustomObject]@{
        Key = 'appProtection'; Label = $L.CatAppProtection; HasIntent = $false; NeedsConfigScope = $true
        Sources = @(
            foreach ($coll in @('iosManagedAppProtections', 'androidManagedAppProtections', 'windowsManagedAppProtections')) {
                New-Source -List "deviceAppManagement/$coll`?`$select=id,displayName" `
                           -ItemPath "deviceAppManagement/$coll/{0}" -Write 'Replace' `
                           -AssignAction 'deviceAppManagement/managedAppPolicies/{0}/assign' `
                           -AssignmentType '#microsoft.graph.targetedManagedAppPolicyAssignment' -UsersOnly $true
            }
        )
    }
    return $t
}

function Get-RequestedScopes {
    # Delegated permissions for Connect-MgGraph. By default the same two as app-centric bulk tools,
    # so no new consent prompt; more only when asked for (filter names) or a category needs it.
    param([bool]$WithFilterNames = $false, [bool]$WithConfig = $false)
    $s = @($script:BaseScopes)
    if ($WithConfig) { $s += $script:ConfigScope }
    elseif ($WithFilterNames) { $s += $script:FilterScope }   # ReadWrite covers reading the filters
    return ,$s
}

function Get-ItemPlatforms {
    # Platforms of an object from its @odata.type (without '#microsoft.graph.') or, for the settings
    # catalog, its 'platforms' value. '*' = no platform of its own: shown for every platform.
    param([string]$OdataType, [string]$PlatformsValue = '')
    $p = @()
    if ($PlatformsValue) {
        foreach ($v in ($PlatformsValue -split '[,\s]+')) {
            if ($v -match '^(?i)ios$')      { $p += 'iOS' }
            if ($v -match '^(?i)macos$')    { $p += 'macOS' }
            if ($v -match '^(?i)android')   { $p += 'Android' }
            if ($v -match '^(?i)windows')   { $p += 'Windows' }
        }
    } else {
        $t = $OdataType
        if ($t -match '^(?i)(managed)?ios')     { $p += 'iOS' }
        if ($t -match '^(?i)(managed)?macos')   { $p += 'macOS' }
        if ($t -match '^(?i)((managed)?android|aosp)') { $p += 'Android' }
        if ($t -match '^(?i)(windows|win32|win10|microsoftStore|officeSuite|sharedPC|editionUpgrade)') { $p += 'Windows' }
    }
    if ($p.Count -eq 0) { $p = @('*') }
    return ,$p
}

function Get-PlatformIndex {
    # Position of a platform in $script:Platforms, case-insensitive (the parameter accepts 'all' too)
    param([string]$Name)
    for ($i = 0; $i -lt $script:Platforms.Count; $i++) { if ($script:Platforms[$i] -eq $Name) { return $i } }
    return 0
}

function Test-PlatformMatch {
    param([string[]]$ItemPlatforms, [string]$Platform)
    if (-not $Platform -or $Platform -eq 'All') { return $true }
    return ($ItemPlatforms -contains '*' -or $ItemPlatforms -contains $Platform)
}

function ConvertTo-Item {
    # One Graph object of a category -> the object the tool works with.
    param($Raw, $Category, $Source)
    $id    = [string]$Raw.id
    $odata = ([string]$Raw.'@odata.type') -replace '^#microsoft\.graph\.', ''
    $type  = $odata
    if ($Source.TypeName) { $type = $Source.TypeName }
    $action = ''
    if ($Source.AssignAction) { $action = $Source.AssignAction -f $id }
    [PSCustomObject]@{
        Key           = "$($Category.Key)|$id"
        Category      = $Category.Key
        CategoryLabel = $Category.Label
        Id            = $id
        Name          = [string]$Raw.($Source.NameProp)
        Type          = $type
        Platforms     = (Get-ItemPlatforms -OdataType $odata -PlatformsValue ([string]$Raw.platforms))
        Publisher     = [string]$Raw.publisher
        HasIntent     = [bool]$Category.HasIntent
        UsersOnly     = [bool]$Source.UsersOnly
        Write         = $Source.Write
        AssignmentType = $Source.AssignmentType
        AssignPath    = ($Source.ItemPath -f $id) + '/assignments'
        AssignAction  = $action
        Assignments   = $Raw.assignments
    }
}

function Get-IntentText {
    param([string]$Intent)
    switch ($Intent) {
        'required'                   { return $L.IntentRequired }
        'available'                  { return $L.IntentAvailable }
        'uninstall'                  { return $L.IntentUninstall }
        'availableWithoutEnrollment' { return $L.IntentAvailNoEnr }
        ''                           { return $L.NoIntent }
        default                      { return $Intent }
    }
}

function Get-StateText {
    # Apps: "Required" / "Required, excluded". Everything else: "included" / "excluded".
    param($State, [bool]$HasIntent = $true)
    if (-not $State) { return '' }
    if (-not $HasIntent) {
        if ($State.Exclude) { return $L.IsExcluded }
        return $L.StateIncluded
    }
    $t = Get-IntentText $State.Intent
    if ($State.Exclude) { $t = "$t, $($L.IsExcluded)" }
    return $t
}

function New-Selection {
    # A target: Kind = group | allUsers | allDevices
    param([string]$Kind, [string]$Id = '', [string]$Name = '')
    [PSCustomObject]@{ Kind = $Kind; Id = $Id; Name = $Name }
}

function Test-AssignmentForSelection {
    # Does this assignment (include or exclude) belong to the selected target?
    param($Assignment, $Selection)
    if (-not $Assignment) { return $false }
    $type = [string]$Assignment.target.'@odata.type'
    switch ($Selection.Kind) {
        'group'      { return (($type -eq $script:OdGroup -or $type -eq $script:OdExclGroup) -and [string]$Assignment.target.groupId -eq $Selection.Id) }
        'allUsers'   { return ($type -eq $script:OdAllUsers) }
        'allDevices' { return ($type -eq $script:OdAllDevices) }
    }
    return $false
}

function Find-AssignmentForSelection {
    # The assignment of an object that belongs to the selected target (include or exclude), or $null.
    # A direct assignment wins over one that comes from a policy set.
    param($Assignments, $Selection)
    $hit = $null
    foreach ($a in $Assignments) {        # no @(): any collection type, $null iterates zero times
        if (-not (Test-AssignmentForSelection $a $Selection)) { continue }
        if ([string]$a.source -ne 'policySets') { return $a }
        if (-not $hit) { $hit = $a }
    }
    return $hit
}

function ConvertTo-AssignmentState {
    # Graph assignment -> the state the tool works with; $null stays $null.
    # Intent only for categories that have one (apps); elsewhere '' so the plan compares exclusion only.
    param($Assignment, [bool]$HasIntent = $true)
    if (-not $Assignment) { return $null }
    $t = $Assignment.target
    $intent = ''
    if ($HasIntent) { $intent = [string]$Assignment.intent }
    [PSCustomObject]@{
        Intent       = $intent
        RawIntent    = [string]$Assignment.intent     # e.g. apply / remove of a device configuration
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
    param($Selection, [string]$Intent, [bool]$Exclude, [bool]$UsersOnly = $false)
    if ($Exclude -and $Selection.Kind -ne 'group') { return $L.ErrExcludeSpecial }
    if ($UsersOnly -and $Selection.Kind -eq 'allDevices') { return $L.ErrUsersOnly }
    if (-not $Exclude -and $Selection.Kind -eq 'allDevices' -and
        ($Intent -eq 'available' -or $Intent -eq 'availableWithoutEnrollment')) { return $L.ErrAvailAllDevices }
    return $null
}

function Get-ChangeText {
    # Text of the grid's change column for one object: new / changed / from a policy set / ''
    param($Original, $Desired)
    if (-not $Original) { return $L.ChangeNew }
    if ($Desired -and ($Original.Intent -ne $Desired.Intent -or [bool]$Original.Exclude -ne [bool]$Desired.Exclude)) { return $L.ChangeChanged }
    if ($Original.PolicySet) { return $L.FromPolicySet }
    return ''
}

function Sort-GridRows {
    # Rows carry one property per grid column (Name, Category, Type, Intent = display text, Exclude,
    # Filter, Change). Sorted by the clicked column, then by name.
    param($Rows, [string]$Column = 'Name', [bool]$Descending = $false)
    $by = @(@{ Expression = $Column; Descending = $Descending })
    if ($Column -ne 'Name') { $by += @{ Expression = 'Name'; Descending = $false } }
    $Rows | Sort-Object -Property $by     # streamed: no rows = no output
}

function Get-PlanProblem {
    # $null when the operation can be written, otherwise the reason.
    param($Operation, $Selection, [bool]$UsersOnly = $false)
    if ($Operation.From -and $Operation.From.PolicySet) { return $L.ErrPolicySet }
    if ($Operation.To) { return (Test-DesiredAssignment $Selection $Operation.To.Intent ([bool]$Operation.To.Exclude) $UsersOnly) }
    return $null
}

function New-AssignmentTarget {
    # target of an assignment; an include keeps the filter of $Carry (an exclusion has none)
    param($Selection, [bool]$Exclude, $Carry = $null)
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
    return $target
}

function New-AssignmentBody {
    # One assignment object: the POST body of a Single write, an entry of a Replace list.
    # $Carry = the previous state of the same target: its filter and settings are kept as long as the
    # assignment stays an include. Apps carry an intent; a device configuration keeps its apply/remove.
    param($Selection, [string]$Intent, [bool]$Exclude, [string]$AppType, [bool]$VppDeviceLicensing, $Carry = $null,
          [string]$AssignmentType = '#microsoft.graph.mobileAppAssignment', [bool]$HasIntent = $true)

    $body = [ordered]@{ '@odata.type' = $AssignmentType }
    if ($HasIntent) { $body['intent'] = $Intent }
    elseif ($Carry -and $Carry.RawIntent) { $body['intent'] = $Carry.RawIntent }
    $body['target'] = New-AssignmentTarget $Selection $Exclude $Carry
    if (-not $HasIntent -or $Exclude) { return $body }

    $keep = ($Carry -and -not $Carry.Exclude)
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
    return $body
}

function New-ReplaceAssignmentList {
    # The complete assignment list for a Replace write (/assign): every current direct assignment of
    # OTHER targets unchanged (target incl. filter), the selected target as desired ($null = removed).
    # Assignments that come from a policy set are left to the policy set and not sent back.
    param($Current, $Selection, $Desired, [string]$AssignmentType, $Carry = $null)
    $list = @()
    foreach ($a in $Current) {
        if (-not $a) { continue }
        if ([string]$a.source -eq 'policySets') { continue }
        if (Test-AssignmentForSelection $a $Selection) { continue }
        $list += [ordered]@{ '@odata.type' = $AssignmentType; target = $a.target }
    }
    if ($Desired) {
        $list += (New-AssignmentBody -Selection $Selection -Intent '' -Exclude ([bool]$Desired.Exclude) -AppType '' `
                      -VppDeviceLicensing $false -Carry $Carry -AssignmentType $AssignmentType -HasIntent $false)
    }
    return ,$list
}

function Get-AssignmentPlan {
    # Original / Desired: hashtable item key -> state (Intent, Exclude). Missing key = not assigned.
    # Returns one operation per object that differs: Add | Remove | Change.
    param([hashtable]$Original, [hashtable]$Desired)
    $ops = New-Object System.Collections.Generic.List[object]
    $ids = New-Object System.Collections.Generic.HashSet[string]
    foreach ($k in $Original.Keys) { [void]$ids.Add([string]$k) }
    foreach ($k in $Desired.Keys)  { [void]$ids.Add([string]$k) }
    foreach ($id in ($ids | Sort-Object)) {
        $o = $Original[$id]; $d = $Desired[$id]
        if (-not $o -and -not $d) { continue }
        if (-not $o) { $ops.Add([PSCustomObject]@{ Key = $id; Action = 'Add';    From = $null; To = $d    }); continue }
        if (-not $d) { $ops.Add([PSCustomObject]@{ Key = $id; Action = 'Remove'; From = $o;    To = $null }); continue }
        if ($o.Intent -ne $d.Intent -or [bool]$o.Exclude -ne [bool]$d.Exclude) {
            $ops.Add([PSCustomObject]@{ Key = $id; Action = 'Change'; From = $o; To = $d })
        }
    }
    return ,$ops.ToArray()
}
#endregion

#region Graph (no GUI; Invoke-MgGraphRequest is mocked by Test-GroupAppAssignment.ps1)
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
    # object[], never List[object]: @($x) on a List[object] throws "Argument types do not match"
    # (Windows PowerShell 5.1 and 7). The leading comma keeps an empty or one-item result an array.
    return ,$all.ToArray()
}

function Connect-Graph {
    param([bool]$WithFilterNames = $false, [bool]$WithConfig = $false)
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) { throw $L.ModuleMissing }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $p = @{ Scopes = (Get-RequestedScopes $WithFilterNames $WithConfig); ErrorAction = 'Stop' }
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

function Get-ItemAssignments {
    param($Item)
    return ,(Invoke-GraphPaged -Uri "$($script:GraphBase)/$($Item.AssignPath)")
}

function Get-CategoryItems {
    # All objects of a category with their assignments. $expand=assignments is not in the documented
    # query options of the list calls: when it fails or comes back without the property, the
    # assignments are read object by object instead of showing "nothing assigned".
    param($Category, [scriptblock]$OnPage = $null)
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($src in $Category.Sources) {
        $uri = "$($script:GraphBase)/$($src.List)"
        $raw = $null
        try { $raw = Invoke-GraphPaged -Uri "$uri&`$expand=assignments" -OnPage $OnPage } catch { $raw = $null }
        $expanded = $false
        foreach ($r in $raw) { if ($r -is [System.Collections.IDictionary] -and $r.Contains('assignments')) { $expanded = $true; break } }
        if (-not $expanded) {
            $raw = Invoke-GraphPaged -Uri $uri -OnPage $OnPage
            foreach ($r in $raw) {
                $r['assignments'] = Invoke-GraphPaged -Uri ("$($script:GraphBase)/" + ($src.ItemPath -f [string]$r.id) + '/assignments')
            }
        }
        foreach ($r in $raw) { $items.Add((ConvertTo-Item $r $Category $src)) }
    }
    return ,$items.ToArray()
}

function Invoke-ItemWrite {
    # Writes one plan operation of one object to Intune; throws a readable message on failure.
    param($Item, $Operation, $Selection, [bool]$VppDeviceLicensing)
    $base = "$($script:GraphBase)/$($Item.AssignPath)"

    if ($Item.Write -eq 'Replace') {
        # read the list fresh right before writing it back, so no other target gets lost
        $current = Get-ItemAssignments $Item
        $list = New-ReplaceAssignmentList -Current $current -Selection $Selection -Desired $Operation.To `
                    -AssignmentType $Item.AssignmentType -Carry $Operation.From
        $json = @{ assignments = $list } | ConvertTo-Json -Depth 20
        try {
            Invoke-MgGraphRequest -Method POST -Uri "$($script:GraphBase)/$($Item.AssignAction)" -Body $json `
                -ContentType 'application/json' -ErrorAction Stop | Out-Null
        } catch { throw (Get-GraphErrorText $_) }
        return
    }

    if ($Operation.Action -eq 'Remove' -or $Operation.Action -eq 'Change') {
        try {
            Invoke-MgGraphRequest -Method DELETE -Uri "$base/$($Operation.From.AssignmentId)" -ErrorAction Stop | Out-Null
        } catch { throw (Get-GraphErrorText $_) }
    }
    if ($Operation.Action -eq 'Add' -or $Operation.Action -eq 'Change') {
        $body = New-AssignmentBody -Selection $Selection -Intent $Operation.To.Intent -Exclude ([bool]$Operation.To.Exclude) `
                    -AppType $Item.Type -VppDeviceLicensing $VppDeviceLicensing -Carry $Operation.From `
                    -AssignmentType $Item.AssignmentType -HasIntent $Item.HasIntent
        try {
            Invoke-MgGraphRequest -Method POST -Uri $base -Body ($body | ConvertTo-Json -Depth 20) `
                -ContentType 'application/json' -ErrorAction Stop | Out-Null
        } catch {
            $msg = Get-GraphErrorText $_
            if ($Operation.Action -eq 'Change') {
                # the old assignment is already gone: put it back as it was
                $restore = New-AssignmentBody -Selection $Selection -Intent $Operation.From.Intent -Exclude ([bool]$Operation.From.Exclude) `
                               -AppType $Item.Type -VppDeviceLicensing $VppDeviceLicensing -Carry $Operation.From `
                               -AssignmentType $Item.AssignmentType -HasIntent $Item.HasIntent
                try {
                    Invoke-MgGraphRequest -Method POST -Uri $base -Body ($restore | ConvertTo-Json -Depth 20) `
                        -ContentType 'application/json' -ErrorAction Stop | Out-Null
                    $msg = "$msg ($($L.Restored))"
                } catch { $msg = "$msg ($($L.RestoreFailed))" }
            }
            throw $msg
        }
    }
}
#endregion

# ---- end of the GUI-free part (Test-GroupAppAssignment.ps1 loads everything above this line) ----

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()


#region State
$script:Selection   = $null
$script:Connected   = $false
$script:Categories  = Get-CategoryTable
$script:CurrentCat  = 'apps'
$script:LoadedCats  = @{}   # category key -> $true once loaded for the current target
$script:NeedConfig  = $false   # a category needing DeviceManagementConfiguration.ReadWrite.All was opened
$script:ItemByKey   = @{}   # item key -> item (Key, Category, Id, Name, Type, Platforms, Assignments, ...)
$script:Original    = @{}   # item key -> state (live, for the selected target)
$script:Desired     = @{}   # item key -> state (what the user wants)
$script:FilterNames = @{}
$script:Rebuilding  = $false
$script:ConnectedAs = ''      # "account|tenant" of the current connection
$script:NeedReload  = $false

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

function Test-HasScope {
    param([string[]]$Names)
    $ctx = Get-MgContext
    if (-not $ctx) { return $false }
    foreach ($n in $Names) { if (@($ctx.Scopes) -contains $n) { return $true } }
    return $false
}
#endregion

#region Form
$form = New-Object System.Windows.Forms.Form
$form.Text          = $L.FormTitleNoGroup
$form.Size          = New-Object System.Drawing.Size(1320, 780)
$form.MinimumSize   = New-Object System.Drawing.Size(1000, 560)
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

$lblPlatform = New-Object System.Windows.Forms.Label
$lblPlatform.Text = $L.LblPlatform; $lblPlatform.AutoSize = $true
$lblPlatform.Location = New-Object System.Drawing.Point(792, 46)

$cmbPlatform = New-Object System.Windows.Forms.ComboBox
$cmbPlatform.DropDownStyle = 'DropDownList'
$cmbPlatform.Location = New-Object System.Drawing.Point(868, 43); $cmbPlatform.Width = 120
foreach ($p in $script:Platforms) {
    if ($p -eq 'All') { [void]$cmbPlatform.Items.Add($L.PlatformAll) } else { [void]$cmbPlatform.Items.Add($p) }
}
$cmbPlatform.SelectedIndex = Get-PlatformIndex $Platform

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
$cmbType.Location = New-Object System.Drawing.Point(440, 78); $cmbType.Width = 240
[void]$cmbType.Items.Add($L.AllTypes); $cmbType.SelectedIndex = 0

$chkVpp = New-Object System.Windows.Forms.CheckBox
$chkVpp.Text = $L.ChkVpp; $chkVpp.AutoSize = $true
$chkVpp.Location = New-Object System.Drawing.Point(692, 80)
$chkVpp.Checked = $VppDeviceLicensing

$chkFilterNames = New-Object System.Windows.Forms.CheckBox
$chkFilterNames.Text = $L.ChkFilterNames; $chkFilterNames.AutoSize = $true
$chkFilterNames.Location = New-Object System.Drawing.Point(870, 80)
$chkFilterNames.Checked = [bool]$LoadFilterNames

$stripTop.Controls.AddRange(@($btnConnect, $lblAccount, $lblGroup, $txtGroup, $btnPick, $btnLoad, $lblPlatform, $cmbPlatform,
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

# --- Center: categories | not assigned | buttons | assigned ---
$boldFont = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

$lblCat = New-Object System.Windows.Forms.Label
$lblCat.Text = $L.HdrCategory; $lblCat.Dock = 'Fill'; $lblCat.Font = $boldFont; $lblCat.TextAlign = 'MiddleLeft'

$lblLeft = New-Object System.Windows.Forms.Label
$lblLeft.Text = $L.HdrNotAssigned; $lblLeft.Dock = 'Fill'; $lblLeft.Font = $boldFont; $lblLeft.TextAlign = 'MiddleLeft'

$lblRight = New-Object System.Windows.Forms.Label
$lblRight.Text = $L.HdrAssigned; $lblRight.Dock = 'Fill'; $lblRight.Font = $boldFont; $lblRight.TextAlign = 'MiddleLeft'

$lbCat = New-Object System.Windows.Forms.ListBox
$lbCat.Dock = 'Fill'; $lbCat.IntegralHeight = $false; $lbCat.BorderStyle = 'FixedSingle'

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

$colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colName.Name = 'Name'; $colName.HeaderText = $L.ColName; $colName.ReadOnly = $true; $colName.FillWeight = 36
$colCategory = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colCategory.Name = 'Category'; $colCategory.HeaderText = $L.ColCategory; $colCategory.ReadOnly = $true; $colCategory.FillWeight = 16
$colType = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colType.Name = 'Type'; $colType.HeaderText = $L.ColType; $colType.ReadOnly = $true; $colType.FillWeight = 16
$colIntent = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
$colIntent.Name = 'Intent'; $colIntent.HeaderText = $L.ColIntent; $colIntent.FillWeight = 18
$colIntent.DataSource = $intentTable; $colIntent.ValueMember = 'Value'; $colIntent.DisplayMember = 'Text'
$colIntent.FlatStyle = 'Flat'
$colExcl = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colExcl.Name = 'Exclude'; $colExcl.HeaderText = $L.ColExclude; $colExcl.FillWeight = 9
$colFilter = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colFilter.Name = 'Filter'; $colFilter.HeaderText = $L.ColFilter; $colFilter.ReadOnly = $true; $colFilter.FillWeight = 14
$colChange = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colChange.Name = 'Change'; $colChange.HeaderText = $L.ColChange; $colChange.ReadOnly = $true; $colChange.FillWeight = 9
# One by one: Columns.AddRange takes a params array, and Windows PowerShell 5.1 does not bind an
# object[] to it (Controls.AddRange has no params and works with @(...)).
foreach ($c in @($colName, $colCategory, $colType, $colIntent, $colExcl, $colFilter, $colChange)) {
    $c.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::Programmatic   # sorted by Update-Views
    [void]$grid.Columns.Add($c)
}
$script:SortColumn = 'Name'
$script:SortDesc   = $false

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
$btnAssign = New-MoveButton $L.BtnAssign
$btnExcl   = New-MoveButton $L.BtnExclude
$btnRemove = New-MoveButton $L.BtnRemove
$script:MoveButtons = @($btnReq, $btnAvl, $btnUni, $btnAssign, $btnExcl, $btnRemove)

$arrowPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$arrowPanel.Dock = 'Fill'; $arrowPanel.FlowDirection = 'TopDown'; $arrowPanel.WrapContents = $false
$arrowPanel.Controls.AddRange($script:MoveButtons)
function Update-ArrowPadding {
    # centre the visible buttons vertically (their number depends on the category)
    $visible = @($script:MoveButtons | Where-Object { $_.Visible }).Count
    $total  = (28 + 8) * $visible + 16
    $topPad = [Math]::Max(0, [int](($arrowPanel.ClientSize.Height - $total) / 2))
    $arrowPanel.Padding = New-Object System.Windows.Forms.Padding(2, $topPad, 2, 0)
}
$arrowPanel.Add_Resize({ Update-ArrowPadding })
$btnRemove.Margin = New-Object System.Windows.Forms.Padding(8, 20, 8, 4)

$table = New-Object System.Windows.Forms.TableLayoutPanel
$table.Dock = 'Fill'; $table.ColumnCount = 4; $table.RowCount = 2
$table.Padding = New-Object System.Windows.Forms.Padding(6)
[void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 230)))
[void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 34)))
[void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 150)))
[void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 66)))
[void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))
[void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$table.Controls.Add($lblCat,     0, 0)
$table.Controls.Add($lblLeft,    1, 0)
$table.Controls.Add($lblRight,   3, 0)
$table.Controls.Add($lbCat,      0, 1)
$table.Controls.Add($lbLeft,     1, 1)
$table.Controls.Add($arrowPanel, 2, 1)
$table.Controls.Add($grid,       3, 1)

$form.Controls.Add($table)
$form.Controls.Add($separator)
$form.Controls.Add($stripBottom)
$form.Controls.Add($stripTop)
#endregion

#region View
function Get-SelectedPlatform {
    return $script:Platforms[[Math]::Max(0, $cmbPlatform.SelectedIndex)]
}

function Test-InCurrentCategory {
    param($Item)
    return ($script:CurrentCat -eq 'all' -or $Item.Category -eq $script:CurrentCat)
}

function Test-ItemVisible {
    # category, platform, search text and type filter
    param($Item)
    if (-not (Test-InCurrentCategory $Item)) { return $false }
    if (-not (Test-PlatformMatch $Item.Platforms (Get-SelectedPlatform))) { return $false }
    $q = $txtSearch.Text.Trim()
    if ($q -and $Item.Name.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -and
        ([string]$Item.Publisher).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    if ($cmbType.SelectedIndex -gt 0 -and $Item.Type -ne [string]$cmbType.SelectedItem) { return $false }
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
    $key = [string]$Row.Tag
    $change = Get-ChangeText $script:Original[$key] $script:Desired[$key]
    $color  = [System.Drawing.SystemColors]::Window
    if ($change -eq $L.ChangeNew)         { $color = [System.Drawing.Color]::Honeydew }
    elseif ($change -eq $L.ChangeChanged) { $color = [System.Drawing.Color]::LightYellow }
    $Row.Cells['Change'].Value = $change
    $Row.DefaultCellStyle.BackColor = $color
}

function Update-CategoryList {
    # "Apps  (assigned / total)" per category for the selected platform; "(...)" = not loaded yet
    $platform = Get-SelectedPlatform
    $texts = @()
    $sumA = 0; $sumT = 0
    foreach ($cat in $script:Categories.Values) {
        if (-not $script:LoadedCats[$cat.Key]) { $texts += ($L.CatNotLoaded -f $cat.Label); continue }
        $a = 0; $t = 0
        foreach ($it in $script:ItemByKey.Values) {
            if ($it.Category -ne $cat.Key -or -not (Test-PlatformMatch $it.Platforms $platform)) { continue }
            $t++
            if ($script:Desired.ContainsKey($it.Key)) { $a++ }
        }
        $sumA += $a; $sumT += $t
        $texts += ($L.CatCounts -f $cat.Label, $a, $t)
    }
    $all = @($L.CatCounts -f $L.CatAll, $sumA, $sumT) + $texts
    $script:Rebuilding = $true
    try {
        $sel = $lbCat.SelectedIndex
        $lbCat.BeginUpdate()
        if ($lbCat.Items.Count -ne $all.Count) {
            $lbCat.Items.Clear()
            foreach ($x in $all) { [void]$lbCat.Items.Add($x) }
        } else {
            for ($i = 0; $i -lt $all.Count; $i++) { if ([string]$lbCat.Items[$i] -ne $all[$i]) { $lbCat.Items[$i] = $all[$i] } }
        }
        $lbCat.EndUpdate()
        $want = 0
        if ($script:CurrentCat -ne 'all') { $want = 1 + [array]::IndexOf(@($script:Categories.Keys), $script:CurrentCat) }
        if ($sel -ne $want -or $lbCat.SelectedIndex -ne $want) { $lbCat.SelectedIndex = $want }
    } finally { $script:Rebuilding = $false }
}

function Update-ButtonMode {
    # Apps: Required / Available / Uninstall / Exclude. Other categories: Assign / Exclude.
    # "All" only shows and removes - what "assign" means differs per category.
    [void]$grid.EndEdit(); $grid.CurrentCell = $null   # no cell in edit mode while columns are hidden
    $cat = $script:CurrentCat
    $btnReq.Visible    = ($cat -eq 'apps')
    $btnAvl.Visible    = ($cat -eq 'apps')
    $btnUni.Visible    = ($cat -eq 'apps')
    $btnAssign.Visible = ($cat -ne 'apps' -and $cat -ne 'all')
    $btnExcl.Visible   = ($cat -ne 'all')
    $colCategory.Visible = ($cat -eq 'all')
    $colIntent.Visible   = ($cat -eq 'apps' -or $cat -eq 'all')
    Update-ArrowPadding
    $script:Rebuilding = $true
    try {
        $keep = [string]$cmbType.SelectedItem
        $cmbType.Items.Clear(); [void]$cmbType.Items.Add($L.AllTypes)
        $types = @($script:ItemByKey.Values | Where-Object { Test-InCurrentCategory $_ } | ForEach-Object { $_.Type } | Sort-Object -Unique)
        foreach ($t in $types) { [void]$cmbType.Items.Add($t) }
        $cmbType.SelectedIndex = [Math]::Max(0, $cmbType.Items.IndexOf($keep))
    } finally { $script:Rebuilding = $false }
}

function Update-Status {
    $pending = Get-PendingCount
    $lblStatus.Text = $L.StatusPending -f $script:ItemByKey.Count, $script:Desired.Count, $pending
    $btnSave.Enabled = ($pending -gt 0)
}

function Update-Views {
    $script:Rebuilding = $true
    try {
        $sorted = @($script:ItemByKey.Values | Where-Object { Test-ItemVisible $_ } | Sort-Object Name)

        $lbLeft.BeginUpdate()
        $lbLeft.Items.Clear()
        foreach ($it in $sorted) {
            if ($script:Desired.ContainsKey($it.Key)) { continue }
            $prefix = ''
            if ($script:Original.ContainsKey($it.Key)) { $prefix = $L.PendingRemove }
            $label = $it.Type
            if ($script:CurrentCat -eq 'all') { $label = "$($it.CategoryLabel) - $($it.Type)" }
            $entry = [PSCustomObject]@{ Key = $it.Key; Text = "$prefix$($it.Name)   [$label]" }
            $entry | Add-Member -MemberType ScriptMethod -Name ToString -Value { $this.Text } -Force
            [void]$lbLeft.Items.Add($entry)
        }
        $lbLeft.EndUpdate()

        [void]$grid.EndEdit()          # EditOnEnter keeps a cell in edit mode; clearing under it can throw
        $grid.CurrentCell = $null
        $grid.SuspendLayout()
        $grid.Rows.Clear()
        $gridRows = @()
        foreach ($it in $sorted) {
            if (-not $script:Desired.ContainsKey($it.Key)) { continue }
            $d = $script:Desired[$it.Key]
            $gridRows += [PSCustomObject]@{
                Key = $it.Key; Name = $it.Name; Category = $it.CategoryLabel; Type = $it.Type; IntentKey = $d.Intent
                Intent  = (Get-IntentText $d.Intent)
                Exclude = [bool]$d.Exclude
                Filter  = (Get-FilterText $script:Original[$it.Key])
                Change  = (Get-ChangeText $script:Original[$it.Key] $d)
            }
        }
        $intentIdx = $colIntent.Index
        foreach ($r in (Sort-GridRows $gridRows $script:SortColumn $script:SortDesc)) {
            $it  = $script:ItemByKey[$r.Key]
            $row = New-Object System.Windows.Forms.DataGridViewRow
            $row.CreateCells($grid)
            if ($it.HasIntent) {
                if ($script:Intents -notcontains $r.IntentKey -and -not $intentTable.Select("Value = '$($r.IntentKey)'")) {
                    [void]$intentTable.Rows.Add($r.IntentKey, $r.IntentKey)   # an intent this tool does not know yet
                }
                $row.Cells[$intentIdx].Value = $r.IntentKey
            } else {
                # no intent outside apps: a plain read-only text cell instead of the list
                $tc = New-Object System.Windows.Forms.DataGridViewTextBoxCell
                $tc.Value = $L.NoIntent
                $row.Cells[$intentIdx] = $tc
            }
            $row.Cells[$colName.Index].Value     = $r.Name
            $row.Cells[$colCategory.Index].Value = $r.Category
            $row.Cells[$colType.Index].Value     = $r.Type
            $row.Cells[$colExcl.Index].Value     = $r.Exclude
            $row.Cells[$colFilter.Index].Value   = $r.Filter
            $idx = $grid.Rows.Add($row)
            $row = $grid.Rows[$idx]        # the row as the grid holds it (never a shared row)
            $row.Tag = $it.Key
            if (-not $it.HasIntent) { $row.Cells[$intentIdx].ReadOnly = $true }
            if ($script:Selection -and $script:Selection.Kind -ne 'group') { $row.Cells[$colExcl.Index].ReadOnly = $true }
            $o = $script:Original[$it.Key]
            if ($o -and $o.PolicySet) {
                $row.ReadOnly = $true
                $row.DefaultCellStyle.ForeColor = [System.Drawing.SystemColors]::GrayText
            }
            Update-GridRow $row
        }
        foreach ($col in $grid.Columns) {
            $col.HeaderCell.SortGlyphDirection = [System.Windows.Forms.SortOrder]::None
            if ($col.Name -eq $script:SortColumn) {
                $col.HeaderCell.SortGlyphDirection = if ($script:SortDesc) { [System.Windows.Forms.SortOrder]::Descending } else { [System.Windows.Forms.SortOrder]::Ascending }
            }
        }
        $grid.ResumeLayout()
    } finally {
        $script:Rebuilding = $false
    }
    Update-CategoryList
    Update-Status
}

function Set-Busy {
    param([bool]$Busy)
    $form.Cursor = if ($Busy) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default }
    foreach ($c in @($btnConnect, $btnPick, $btnLoad) + $script:MoveButtons) { $c.Enabled = -not $Busy }
    $lbCat.Enabled = -not $Busy
    if ($Busy) { $btnSave.Enabled = $false }
    if (-not $Busy -and $script:ItemByKey.Count -eq 0) { foreach ($b in $script:MoveButtons) { $b.Enabled = $false } }
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
        $ctx = Connect-Graph -WithFilterNames $chkFilterNames.Checked -WithConfig $script:NeedConfig
        $script:Connected = $true
        $who = "$($ctx.Account)|$($ctx.TenantId)"
        if ($script:ConnectedAs -and $script:ConnectedAs -ne $who) {
            # other account or tenant: the loaded IDs belong to the old one - never write them to the new one
            $script:ItemByKey = @{}; $script:Original = @{}; $script:Desired = @{}; $script:LoadedCats = @{}
            $script:NeedReload = $true
        }
        $script:ConnectedAs = $who
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
        $btnSave.Enabled = ((Get-PendingCount) -gt 0)   # Set-Busy switched it off
    }
    if ($script:NeedReload) {
        $script:NeedReload = $false
        Update-ButtonMode; Update-Views
        if ($script:Selection) { Invoke-Load }
    }
}

function Update-FilterNames {
    # Filter names need DeviceManagementConfiguration.Read.All (or ReadWrite, when a category beyond apps
    # is open): connect again with it when the current token lacks it - that is the one consent prompt.
    # Without names the filter column shows the filter ID.
    $script:FilterNames = @{}
    if ($chkFilterNames.Checked -and $script:Connected) {
        try {
            if (-not (Test-HasScope @($script:FilterScope, $script:ConfigScope))) {
                [void](Connect-Graph -WithFilterNames $true -WithConfig $script:NeedConfig)
            }
            $f = Invoke-GraphPaged -Uri "$($script:GraphBase)/deviceManagement/assignmentFilters?`$select=id,displayName"
            foreach ($x in $f) { $script:FilterNames[[string]$x.id] = [string]$x.displayName }
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show(($L.FilterNamesFailed -f (Get-GraphErrorText $_)), $L.TitleWarning, 'OK', 'Warning')
            $script:FilterNames = @{}
            $script:Rebuilding = $true
            try { $chkFilterNames.Checked = $false } finally { $script:Rebuilding = $false }   # no nested handler run
        }
    }
}

function Import-Category {
    # (Re)load one category for the selected target; its pending edits are replaced by the live state.
    param([string]$CatKey)
    $cat = $script:Categories[$CatKey]
    if ($cat.NeedsConfigScope -and -not (Test-HasScope @($script:ConfigScope))) {
        $script:NeedConfig = $true
        [void](Connect-Graph -WithFilterNames $chkFilterNames.Checked -WithConfig $true)   # the one consent prompt
    }
    # no GetNewClosure(): a closure no longer sees the script's variables ($lblStatus, $form)
    $script:LoadingLabel = $cat.Label
    $onPage = { param($n) $lblStatus.Text = $L.StatusLoadingCat -f $script:LoadingLabel, $n; $form.Update() }
    $items = Get-CategoryItems -Category $cat -OnPage $onPage

    foreach ($k in @($script:ItemByKey.Keys)) {
        if ($script:ItemByKey[$k].Category -eq $CatKey) {
            $script:ItemByKey.Remove($k); $script:Original.Remove($k); $script:Desired.Remove($k)
        }
    }
    foreach ($it in $items) {
        $script:ItemByKey[$it.Key] = $it
        $st = ConvertTo-AssignmentState (Find-AssignmentForSelection $it.Assignments $script:Selection) $it.HasIntent
        if ($st) {
            $script:Original[$it.Key] = $st
            $script:Desired[$it.Key]  = [PSCustomObject]@{ Intent = $st.Intent; Exclude = $st.Exclude }
        }
    }
    $script:LoadedCats[$CatKey] = $true
}

function Invoke-Load {
    # Reload the target: apps plus every category that was opened before
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
        $cats = @('apps') + @($script:LoadedCats.Keys | Where-Object { $_ -ne 'apps' })
        if ($script:CurrentCat -eq 'all') { $cats = @($script:Categories.Keys) }
        elseif ($cats -notcontains $script:CurrentCat) { $cats += $script:CurrentCat }
        $script:ItemByKey = @{}; $script:Original = @{}; $script:Desired = @{}; $script:LoadedCats = @{}
        foreach ($k in $cats) {
            try { Import-Category $k }
            catch {
                if ($k -eq 'apps') { throw }
                [void][System.Windows.Forms.MessageBox]::Show(($L.CategoryLoadFailed -f $script:Categories[$k].Label, (Get-GraphErrorText $_)), $L.TitleWarning, 'OK', 'Warning')
            }
        }
        if (-not $script:LoadedCats[$script:CurrentCat] -and $script:CurrentCat -ne 'all') { $script:CurrentCat = 'apps' }
        Update-ButtonMode
        Update-Views
        $lblStatus.Text = $L.StatusLoaded -f $script:ItemByKey.Count, $script:Original.Count
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(($L.LoadFailed -f (Get-GraphErrorText $_)), $L.TitleError, 'OK', 'Error')
        Update-ButtonMode; Update-Views   # show what is loaded now, not the previous target
    } finally {
        Set-Busy $false
        $btnSave.Enabled = ((Get-PendingCount) -gt 0)
    }
}

function Select-Category {
    # Open a category; loads it (and asks for its permission) the first time
    param([string]$CatKey)
    $script:CurrentCat = $CatKey
    if ($script:Connected -and $script:Selection) {
        $need = @()
        if ($CatKey -eq 'all') { $need = @($script:Categories.Keys) } else { $need = @($CatKey) }
        $need = @($need | Where-Object { -not $script:LoadedCats[$_] })
        if ($need.Count -gt 0) {
            Set-Busy $true
            try {
                foreach ($k in $need) {
                    try { Import-Category $k }
                    catch {
                        [void][System.Windows.Forms.MessageBox]::Show(($L.CategoryLoadFailed -f $script:Categories[$k].Label, (Get-GraphErrorText $_)), $L.TitleWarning, 'OK', 'Warning')
                    }
                }
            } finally { Set-Busy $false }
        }
    }
    Update-ButtonMode
    Update-Views
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
            $lbRes.Items.Clear()
            foreach ($p in $script:_pick) { [void]$lbRes.Items.Add("* $($p.Name)") }   # only All users / All devices are left
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
function Add-SelectedItems {
    # Move the selected objects of the left list to "assigned". Objects without an intent get ''.
    param([string]$Intent, [bool]$Exclude)
    $entries = @($lbLeft.SelectedItems)
    if (-not $entries) { return }
    foreach ($e in $entries) {
        $it = $script:ItemByKey[$e.Key]
        $want = $Intent
        if (-not $it.HasIntent) { $want = '' }
        $o = $script:Original[$e.Key]
        if ($o -and $o.Intent -eq $want -and [bool]$o.Exclude -eq $Exclude) {
            $script:Desired[$e.Key] = [PSCustomObject]@{ Intent = $o.Intent; Exclude = $o.Exclude }
        } else {
            $script:Desired[$e.Key] = [PSCustomObject]@{ Intent = $want; Exclude = $Exclude }
        }
    }
    Update-Views
}

$btnReq.Add_Click({    Add-SelectedItems 'required'  $false })
$btnAvl.Add_Click({    Add-SelectedItems 'available' $false })
$btnUni.Add_Click({    Add-SelectedItems 'uninstall' $false })
$btnAssign.Add_Click({ Add-SelectedItems ''          $false })
$btnExcl.Add_Click({   Add-SelectedItems 'required'  $true  })   # an app exclusion sits under Required
$btnRemove.Add_Click({
    $keys = @($grid.SelectedRows | ForEach-Object { [string]$_.Tag })
    if (-not $keys) { return }
    foreach ($k in $keys) {
        $o = $script:Original[$k]
        if ($o -and $o.PolicySet) { continue }   # only the policy set can remove it
        $script:Desired.Remove($k)
    }
    Update-Views
})
$lbLeft.Add_DoubleClick({
    if ($script:CurrentCat -eq 'all') { return }
    if ($script:CurrentCat -eq 'apps') { Add-SelectedItems 'required' $false } else { Add-SelectedItems '' $false }
})

# Commit combo / checkbox edits at once instead of when the cell is left
$grid.Add_CurrentCellDirtyStateChanged({
    if ($grid.IsCurrentCellDirty) { [void]$grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) }
})
$grid.Add_CellValueChanged({
    param($s, $e)
    if ($script:Rebuilding -or $e.RowIndex -lt 0) { return }
    if ($e.ColumnIndex -ne $colIntent.Index -and $e.ColumnIndex -ne $colExcl.Index) { return }
    $row = $grid.Rows[$e.RowIndex]
    $key = [string]$row.Tag
    if (-not $script:Desired.ContainsKey($key)) { return }
    $it = $script:ItemByKey[$key]
    $intent = ''
    if ($it.HasIntent) { $intent = [string]$row.Cells[$colIntent.Index].Value }
    $script:Desired[$key] = [PSCustomObject]@{
        Intent  = $intent
        Exclude = [bool]$row.Cells[$colExcl.Index].Value
    }
    Update-GridRow $row
    Update-Status
})
$grid.Add_DataError({ param($s, $e) $e.ThrowException = $false })
# Header click sorts by that column; a second click on the same column reverses the order
$grid.Add_ColumnHeaderMouseClick({
    param($s, $e)
    $name = $grid.Columns[$e.ColumnIndex].Name
    if ($script:SortColumn -eq $name) { $script:SortDesc = -not $script:SortDesc }
    else { $script:SortColumn = $name; $script:SortDesc = $false }
    Update-Views
})

$lbCat.Add_SelectedIndexChanged({
    if ($script:Rebuilding -or $lbCat.SelectedIndex -lt 0) { return }
    $key = 'all'
    if ($lbCat.SelectedIndex -gt 0) { $key = @($script:Categories.Keys)[$lbCat.SelectedIndex - 1] }
    $missing = ($key -eq 'all' -and @($script:Categories.Keys | Where-Object { -not $script:LoadedCats[$_] }).Count -gt 0) -or
               ($key -ne 'all' -and -not $script:LoadedCats[$key])
    if ($key -ne $script:CurrentCat -or $missing) { Select-Category $key }
})
$txtSearch.Add_TextChanged({ Update-Views })
$cmbPlatform.Add_SelectedIndexChanged({ if (-not $script:Rebuilding) { Update-Views } })
$chkFilterNames.Add_CheckedChanged({
    if ($script:Rebuilding) { return }
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
        $it  = $script:ItemByKey[$op.Key]
        $why = Get-PlanProblem $op $sel $it.UsersOnly
        if ($why) { $invalid.Add("[$($it.CategoryLabel)] $($it.Name): $why") }
    }
    if ($invalid.Count -gt 0) {
        [void][System.Windows.Forms.MessageBox]::Show(($L.Invalid -f ($invalid -join "`n")), $L.InvalidTitle, 'OK', 'Warning'); return
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($op in $plan) {
        $it = $script:ItemByKey[$op.Key]
        switch ($op.Action) {
            'Add'    { $lines.Add(($L.OpAdd    -f $it.CategoryLabel, $it.Name, (Get-StateText $op.To $it.HasIntent))) }
            'Remove' { $lines.Add(($L.OpRemove -f $it.CategoryLabel, $it.Name, (Get-StateText $op.From $it.HasIntent))) }
            'Change' { $lines.Add(($L.OpChange -f $it.CategoryLabel, $it.Name, (Get-StateText $op.From $it.HasIntent), (Get-StateText $op.To $it.HasIntent))) }
        }
    }
    $shown = @($lines | Select-Object -First 25)
    if ($lines.Count -gt 25) { $shown += ($L.SaveMore -f ($lines.Count - 25)) }
    if ([System.Windows.Forms.MessageBox]::Show(($L.SaveConfirm -f $sel.Name, ($shown -join "`n")),
            $L.TitleConfirm, 'YesNo', 'Question') -ne 'Yes') { return }

    Set-Busy $true
    $errs = New-Object System.Collections.Generic.List[string]
    $mismatch = New-Object System.Collections.Generic.List[string]
    $vpp  = $chkVpp.Checked
    try {
        $i = 0
        foreach ($op in $plan) {
            $i++
            $it = $script:ItemByKey[$op.Key]
            $lblStatus.Text = $L.StatusSaving -f $i, $plan.Count, $it.Name; $form.Update()
            try {
                Invoke-ItemWrite -Item $it -Operation $op -Selection $sel -VppDeviceLicensing $vpp
            } catch {
                $sym = '~'
                if ($op.Action -eq 'Add') { $sym = '+' } elseif ($op.Action -eq 'Remove') { $sym = '-' }
                $errs.Add("$sym [$($it.CategoryLabel)] $($it.Name): $($_.Exception.Message)")
            }
        }

        # Read back what Intune really has now, per touched object
        $j = 0
        foreach ($op in $plan) {
            $j++
            $lblStatus.Text = $L.StatusVerifying -f $j, $plan.Count; $form.Update()
            $it = $script:ItemByKey[$op.Key]
            try {
                $it.Assignments = Get-ItemAssignments $it
            } catch {
                $errs.Add("? [$($it.CategoryLabel)] $($it.Name): $(Get-GraphErrorText $_)"); continue
            }
            $live = ConvertTo-AssignmentState (Find-AssignmentForSelection $it.Assignments $sel) $it.HasIntent
            if ($live) {
                $script:Original[$it.Key] = $live
                $script:Desired[$it.Key]  = [PSCustomObject]@{ Intent = $live.Intent; Exclude = $live.Exclude }
            } else {
                $script:Original.Remove($it.Key); $script:Desired.Remove($it.Key)
            }
            $want = $op.To
            $ok = $false
            if (-not $want) { $ok = (-not $live) }
            else { $ok = ($live -and $live.Intent -eq $want.Intent -and [bool]$live.Exclude -eq [bool]$want.Exclude) }
            if (-not $ok) { $mismatch.Add("[$($it.CategoryLabel)] $($it.Name): $(Get-StateText $want $it.HasIntent)  <>  $(Get-StateText $live $it.HasIntent)") }
        }
    } finally {
        Set-Busy $false
    }

    Update-Views
    $lblStatus.Text = $L.StatusSaved -f $plan.Count, $errs.Count
    if ($errs.Count -gt 0) {
        $msg = $L.SaveErrors -f ($errs -join "`n")
        if (@($errs | Where-Object { $_.StartsWith('?') }).Count -gt 0) { $msg += $L.VerifyFailedHint }
        [void][System.Windows.Forms.MessageBox]::Show($msg, $L.TitleWarning, 'OK', 'Warning')
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
    Update-ButtonMode
    Update-CategoryList
    if ($script:Selection) {
        Invoke-Connect
        if ($script:Connected) { Invoke-Load }
    }
})

[void]$form.ShowDialog()
$form.Dispose()
#endregion
