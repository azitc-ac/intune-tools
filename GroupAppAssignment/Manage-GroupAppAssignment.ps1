<#
.SYNOPSIS
    Intune assignments seen from a group: which apps, configuration profiles, compliance policies,
    app configuration and app protection policies and policy sets are assigned to the group, in which
    mode - and add, change or remove those assignments.

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
        BtnDisconnect      = 'Abmelden'
        StatusSignedOut    = "Abgemeldet. Beim nächsten 'Verbinden' lässt sich ein anderes Konto wählen."
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
        CatPolicySets      = 'Richtliniensätze'
        TypeMamAppConfig   = 'verwaltete Apps (MAM)'
        CatNotLoaded       = '(...)'
        CatCounts          = '({0} / {1})'
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
        ColPublisher       = 'Herausgeber'
        ColVersion         = 'Version'
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
        ChangeRemove       = 'wird entfernt'
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
        StatusVerifying    = 'Prüfe Ergebnis in Intune ({0} / {1})... (App-Schutz / MAM: Intune braucht dafür bis zu einer Minute)'
        SaveErrors         = "Abgeschlossen mit Fehlern:`n`n{0}"
        VerifyFailedHint   = "`n`n'?' = gespeichert, aber das Ergebnis konnte nicht aus Intune gelesen werden - die Anzeige kann veraltet sein, bitte 'Laden' klicken."
        SaveOk             = '{0} Änderung(en) gespeichert und in Intune bestätigt.'
        MamPending         = "`n`nNoch nicht überall sichtbar (App-Schutz / MAM - Intune zeigt Ausschlüsse teils erst nach Minuten an; das Tool arbeitet 10 Minuten lang mit dem gesendeten Stand weiter):`n{0}"
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
        BtnDisconnect      = 'Sign out'
        StatusSignedOut    = "Signed out. The next 'Connect' lets you pick another account."
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
        CatPolicySets      = 'Policy sets'
        TypeMamAppConfig   = 'managed apps (MAM)'
        CatNotLoaded       = '(...)'
        CatCounts          = '({0} / {1})'
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
        ColPublisher       = 'Publisher'
        ColVersion         = 'Version'
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
        ChangeRemove       = 'to be removed'
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
        StatusVerifying    = 'Checking the result in Intune ({0} / {1})... (app protection / MAM: Intune needs up to a minute)'
        SaveErrors         = "Completed with errors:`n`n{0}"
        VerifyFailedHint   = "`n`n'?' = saved, but the result could not be read back from Intune - the view may be out of date, please click 'Load'."
        SaveOk             = '{0} change(s) saved and confirmed by Intune.'
        MamPending         = "`n`nNot visible everywhere yet (app protection / MAM - Intune shows exclusions only after minutes at times; for 10 minutes the tool keeps working with the state it sent):`n{0}"
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

function Get-UiLanguage {
    # English unless -Language de, or -Language auto and a German Windows display language (de-DE, de-AT, ...)
    param([string]$Language, [string]$CultureName)
    if ($Language -eq 'de') { return 'de' }
    if ($Language -eq 'en') { return 'en' }
    if ($CultureName -match '^(?i)de(-|$)') { return 'de' }
    return 'en'
}
$L = $strings[(Get-UiLanguage $Language ([System.Globalization.CultureInfo]::CurrentUICulture.Name))]
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
    #   ReadVia        Collection = GET ItemPath/assignments; Expand = GET ItemPath?$expand=assignments
    #                  (policy sets have no assignments collection to GET)
    # Write modes and paths are the ones that worked against a live tenant (2026-09), which differ from
    # the documentation for compliance, app configuration, app protection and policy sets.
    param([string]$List, [string]$ItemPath, [string]$Write, [string]$AssignmentType,
          [string]$AssignAction = '', [string]$NameProp = 'displayName', [bool]$UsersOnly = $false, [string]$TypeName = '',
          [ValidateSet('Collection', 'Expand')][string]$ReadVia = 'Collection', [bool]$Eventual = $false,
          [string]$DefaultType = '')
    #   DefaultType    type when Graph sends no @odata.type (a $select on a collection of one type, measured
    #                  live for app protection and policy sets) - also drives the platform
    #   Eventual       reads lag behind writes and may flip between old and new for 20 s and more, writes
    #                  shortly after a change fail with ConditionNotMet / ResourceNotFound (MAM, measured
    #                  live): read until stable, retry the write, wait for the result
    [PSCustomObject]@{
        List = $List; ItemPath = $ItemPath; Write = $Write; AssignmentType = $AssignmentType
        AssignAction = $AssignAction; NameProp = $NameProp; UsersOnly = $UsersOnly; TypeName = $TypeName; ReadVia = $ReadVia
        Eventual = $Eventual; DefaultType = $DefaultType
    }
}

# Category icons: the Intune portal icons as drawn by IntuneManagement (github.com/Micke-K/IntuneManagement,
# MIT, (c) 2019 Mikael Karlsson), Xaml/Icons/*.xaml, converted to 48 px PNG. The drawings are Microsoft's
# Azure / Intune portal icons.
$script:IconData = @{
    Intune               = 'iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAAE90lEQVR4nOxaa2gcVRT+7uwj2c0mu3lt0mAaVorQNsZQmhZNKakiitCKSm2rCFqxWkGLiGBbwYqiQUVTbGjJDynaaClWiYJQMFpR2/4xAfMiIclaU/PYZrfJZB/Z11zvzO6apOluZnZm3a30g507M/fO3PPNueeec89dPW5y6HGT4/9B4KlPZzcTTjgECis4dkNgv1wpCTxRQXijfW9pf1IC3mh4P43QHYQQUErBClayZ3PlGmSIifl6UgJ9bt4sUi02cdhVXwiDjiDbCEUo2rt5eIMiAdiStZMIDM0E2JHiyEY7XtlajFzB2FwQLb+5IakkCeJGTKWjxx9BLmHaF5dHEJK24WJF9odMSnBc0qolGshZpNBAnICoAfUkggLFiC8EZn+oK8qDZsi0BgJRimOjHpy+Mrvkfi0j8UxNMZrKzFCFTNrATFjAs11/LxNeRC8fxKs9k3h3cBqqkEkNHO6fwqA3JJ1vsxegocSE0jwdpuYjuDgdwEW3H2fHeVTm67G3xpZeJ5mygR72hS95AtL57lWleLDMGu8QqDAyO6iyolx3Dd+6rqGVDbHHbyuCRccp7idjGvjB5ZVKu9GABxLCX4cddhvOe3jwkSjOXOFRZ82HXPiMFJYSHQx5qKr5ydmUuE8oaPe9jp8XEUhPA3/6w1LpMOcltSI986I1pjz0zPklLSgCG3F3bDSKZ9tBhe2LqzZ0Dn/Ydd+a11RpICG0gWTDEZJK8ahKA6vNBoCFKhPBUMp2k/H6/Y5i1NtMaHN60DUzj6N1lchXaBNh5msO/DGBMFMJoNIG7rdb0D42ixF/EL3eAGotpmVtunkfroYiMHIET1TbYGaR7ldGHdglGkvT8w/isAzTmMyq/MCdzFHdUxITuvWvKXS6ebiCYenlE6w8Nz2L42Muqf559vXN8TBd0CByIZRIsqv2A++sr8Cb/S78wub7z8dv7LAerSrC06sXfACngclQsmQIpR8LWfUcWthY/pUROHl5BgMshp+Pf2LNQokU0Cwa3cLG85b4mB6YC2FtoRH/BTKyHlhJeC1tIE4gd9YDLm9UUfucW5G9/aMLxy/J99hLNDDsDiHbiLDx9WLHBD65II/Eklno+0EvyME+ZBoFVg6+WQHkXPK+Xv5ugqV3gBc2l6R8V0ID3yAHwcmIsWIaaK79EgcHfgeNVCENVI4P79SH5hsT3uT6Mmi2nrlqr76QaF/h0L1vMOgbTtQv704cOl/38Wh9eBX2bVo5R7WQ3H1vrZi+G0IaMO46tZulAe8ShV0cmiWu8/2eE2h+6HzivrVz5DLzfw1Ntxcse9fZXh5tj1ThuU3yEmyaZKcDdzeaUk7EFPk4DVk4vK0clYXyxdKEAE2Ru4xD9mJYifAi0lig3gCErElZz61QrwKqCdiOjdawHPi6lI0o3cp+GfGWqgnow+SQjGbVJS3Ox5ABpE2g4oPJgvIWZzObK/fJac8R7mTZx849WmtCmcUcoVyZdXQPCPdSBP4NbOfEIP9hWsDIflF21Nk274DPUgRNoIhAqdX5JBP+M/GcpB0AEosQhUWrCFjhnEV4lnV7a+EasY04hdd6I93JzlIbvkwoIuA+4OhgRQdUorpzZD1LaK/7aNgNi16ZGfoiwr9LVhFZ3ScWUzJqkS0CWmzGSe/ICgE2kZ5iRzE1mNZMwCaQaOwdOb+7tzJu/dkj2/gHAAD//18jY1cAAAAGSURBVAMA6azhlH1wVCgAAAAASUVORK5CYII='
    Applications         = 'iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAAFkUlEQVR4nNxav28fNRR/7/mCMiCWDpAOoEIQEoGpHTpkAUV0oWMXJrIg4A8ogqFpKiADKzDAQAfE0LUMiAimRCpSMyA1kSqIECAlLAyolVLUfG3e2X4+3519X1+DBKmjxnn3/LH9fr87tYJjPio45qMvwMUfzwLRLJQMBbvwwYu/w3s7c6Anz8GYQeo2fPj8Prxz60lA83QRBukA1hZ+iB81Alz+ZRYO7u4A4ikoHRNzkX9/BBP9KuM+gzHD6Df49+dA8BoYXCvDGIB3b+3C2gvz8ogC8+87L4+6fDwIxg/dmUuHgWfYauf6R6N6FEYPdHiN40VA/nnQgfiY/NkcPBmrimg8iAX+pdEcrY5wiyPIflTh/3sLHEV4+D9Y4IgjpFHF/wyiS1WlM7m7Uy07kzASH7AwDldH/yQtAITEYhf3ZtPi13fWHhukKMaTxVak+E4muX8Oj2gSAlgJyG6G9eWSc5cPcMiwGXY/neQP4Pn298H5MFJu/wzeqaxrAWUtmZY8PaNxf5I1ABXj3IEOPMM4A2bUuXEFaVkATUpycb2+RmQjRbVGdEZzGbzGIHxjgTJ8PBoBSG2D1qt9iSGrCUNmw2qxoptam9X0ujSeZtSWnQk2+NFqXuMpPG3LvSNjHM8RLPDElZ8WyMAFmxq1Tyo2zw3QBtf3Ls1vzl35+TRnhvNT10c0u8P1/UvzWyff313UE71UdJ7QE7j2x+Vnd1oCsBcvoKKV2umU8r6mXN4doA8YujmDcIYjYKVgfaA1mD3GbvF9FhWfW3iepavKulBbgEc4ivXIbCD+Rz4BlOKswozLWhW5GjXm3DiOW4WsToWS31304yAdLsM/Bs3U9TEto8lCUIwnSgmgnIuF1EXSHeRpLXWAXHtvRuAdVVuAis8TWkcmaFvAtgdek/UMw7TyZX+G9ahRT13fon0VDBYoOE/oihKVmGoTWMnEPr73GKBFETWUDE1dH9PSDrhKXHae0HHub1kAqOlFxG7DtBde9scReGgswKYvPI+GYwBa2UC6yzwtnuheJaavb9EhC5FzJyzHI2RiQBbnuk9ReeB7TVQsvdEJ/gBeAtEmAL+uGB+ZINGNgnc1TM8x32vCdeIJ/gBewjDUgRH4dAwonwqtZqPUNUj7xoxcTp2+vqHjGCg/z9NJAcSFJMBaFTBHNxYAKlkf0UZ5xSmpUsV4RJ2ygNrmWFrVXM6ozuvSOUV0d+YtbTvN7yY3ubVe7fKH8KxJ105PYIMUrab2z+GVUQ9hO33u4/0F7scuwIhhiNbX33p885VP905zLjw/Bsvd3/Vv3z65tfTJ3iKXpqUx0ImCa9+9OdfuRtmR+X2AW+LmBBAfbxJY6wbsBtq204TqDK9a6fKn4G07zXVgkUNgJbV/Dk/a9NvpEIg+XpruD6LuEzp8F4iuEmOCn8dLJxhnoWJ8rg5I4yQK6KfhNr8lfNQIFuH9JWwKNun9c/hsHTBA0BK5N1OflktAip/Ha921fDneJAUA/4lT2olg1il0dImi9fISpCCygCk/L/hTRwC7KTUSu65vGu0v4WsRjcCHXihczpTjU+8D6YoIUQ/SeY6NJ4YPwyl+Bo9K3A/cF74R+GQMuLUuECXcpTeSci5vRIFvGhOg0X3+AF4uETJYav8c3iQEcJkEPAhCNmhSmacjfrh/pLFSPAUBqJV9SvA6EiB6t4GQompfwwKaIuFxJL5l+cLzhFYqYYGK8G74KpGYWy87jWa8LozBFH8IL9YLr7zleD7vTs8CCv76nmPgN/tQJPegeqYObTWB5Pd2n6m6/EF8lM5z+2fwv365fOKbngWuLp+6x9NTr3/x51lOKbMgpXBgRjPZtfqv7n9dHVYvTVsfz4eVvu0t8JXScKMMp+9dXT5xA6LRdsZjOI79/1b5BwAA//866124AAAABklEQVQDABl7AXnzFQwTAAAAAElFTkSuQmCC'
    DeviceConfiguration  = 'iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAAA7klEQVR4nOzYsRGCMBQG4Bcua1jZWLgAM7iAG7iAVcCzyRIOY80UbmFtTBqOJgfI5X4f/F8VvYN7P3k8OKwoZ0U5/QGcc2djjI/rvejyCiG4tAN30Vd8kmq+2Xj1D6JUrP0Iuwe89/26bduf/+cUQjNN0wRRjC2EZp+7U/+ju9SiQf3o+jVbCI0B0LYRYHjXTzGcZnOPzZ0nhy2ENjtAbltzrVL64cgWQiseYMkEm4I7gFY8AKfQCAYYw3ehEdsLUPrBNBdbCG1SgH/+XsQWQmMAtHUFWPLeglJJCG/RKtZefcRcRalUuxHlOIXQvgAAAP//NYUeiAAAAAZJREFUAwAeuzlEsJpSAAAAAABJRU5ErkJggg=='
    CompliancePolicies   = 'iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAACtklEQVR4nOyZz08TQRTHv7PdWgURRBDhoKiR0INRNAESTmqMMUbqj4ChaGIMHvwTvOg/QOLRGC8mWutBEmnBCx40xpgARoOm1h8N/mhCG61RpFq17fi2slq001Zbdkrcz2XezLxu3nvz+nYzT0We9Hp87Rysm3M0gWENA1bT8jIYBAcP03AXXBlwO5ov6ess1w+dQy+X88Sni4xhD0oEDoyA2464HevCSjbFrpFAJRLR0VIyXoOivpOxmGtWFuP0+K6RikOfl1sV7FpbjR2NVaiyqTCKM2NBjIdm/lindD4qdMA59HgrkhjX520NFejbVI8yNeuhFZ3+0SDuh2cy7lEqeYVh5Al+iLEf/tUsseJESwOsSs6/TFGZeBMVGj/LFnEeMNaqi/uaVhhuvMad4HQuFZswHxjHel3eWLsUMvBHorlUJoQOUN1dqcvViy2QQeRzPOs+A78gTCHK/0W6rLBf6dPr9aPYuPY2Z1znafLlTnvGHDauFs4T/58DouOWhZlCsvlrB4ysQvlgppBszCokG7MKFQOzCi1kzCokG7MKFQOzCi1kzCokG9MB2ZgOyGaOAz2D/sN037ifrvTa09fn4+WlUWmz4Dj1HFrq/v3yOOVA1/CjVWrC4iLjt2tzIy7StW7P6Y5G1JVbUQgpB6xxy1WyugMG4thQU7DxGmqPx9dHo6HGa7TWV6AYKODsICRQW1Z49DUUasVshgReT3/Juj/5IYZ8UBhnHBIYC33Mvj+Vts8hVNZO4AEkMPDkLV4JTiHwPobBZ5Gfc4rwQ9FzqEemnIMkTt6axHDgHULRr6n5FI3e5xGcuv3iN012VvSMVMmnjvx1EnejBKHo33R32reJ9lNdym+W5DHq299A6XEvrqrd2RTmvHS1TwkgeYCW26gx2QBJcI6nFPn+Kw77+Vy63wEAAP//AI6L4wAAAAZJREFUAwB9D7vsiuaNMgAAAABJRU5ErkJggg=='
    AppConfiguration     = 'iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAAFXElEQVR4nOxYe0ibVxS/J/k0aazPsGGHdN3qXoyO2T1AKwodwwcUtoJQWB+TPdqNDWYRZ3wwwddmNzMMyJpB2YpdH7L9MVpUsO5hN7cOVtrujz1o1eEf66yOxRJNjN/t72oCJvnyJSafSQs58HEf59xzzzn33HPO/aQthwc5WwNMdJeTr5+otatBYnc5JBVINCQVSDQkFUg0JBVINCQVSDQQu8sh6UKJBin6spbTlsNDcnRrtSundewOA87oFZnRLs7ZcCT0MShAkVmQcwfnvJfJugK/acbPB5OyjsnusmN/d5ednbSWPy+T/Dgm7Wrs1/cOcP7HhLXiUdFtbm7eJjc22tCtIKJdR2eNL5iMrm/hF0+t0LIzELoRUIXRESjdR/TDp+3t7QfzagYtobZYVxfitGIgCNUpy/IVdN/CtxX9869nD5s9LqkMVh/A3GmWaThgsVgK0T+O734o2Yh2oqmpqXrKWj7LtFeAh80hxMm8TMm5wW+eaBPmRl6754IeVq/EBd2zZ2EoD/PngDaupl1aWjKq7bG+LkQsy9ubCUIRPeh2u39paGgY944fQZOtQPcfU4F1zwPw3xyi0f+VcBBuM5rNaut1Op1DFc+ihqAodFl8cI3r8Jlp9BdwMUelTIMTc04WJeC+uNTwMZyAuAND3i53eFhm4ZS1aD6QCtGnQCb6iEUPvbjcRZ2dnTNKSG1ciOjYVHfRPKLNKe+FdcA9RPyfgwXfxnij0jLgl9BcBW062q3KrOlhNAOIRk2gF3dEfFlibUdHxxGKtZRAGAQvKX+vaUSEvpEI2fTj65qenr5st9sXxURNTc0Go9H4NHy+DcOSCHi4EaFyNSunEU2+hAK7w5DdhLYvw3LnwvB6FbxE0lMNoTjdN/VMA6iqqtKbzWY7NjWo0UH43RB+gIWB0dHRX0tKSoRxd4Yh3ahJJu7v71/S6/Wl6P6rQtYL4YdYhAD3+mA5ooUA4KbgbgdJi3Ia92BsziOXH0q/kIbhWZzE9sB1InG1tbWNszUAXGk/1n3OgoW/kpqaWtbS0vKPJidAxAozJLp4fP45HRjvwNTVgA1n1iq8d91Fhbkxj8dTLIQXY+0SGUoBiS32gfGCOF5/FI2xKMBgMPyJJjAJDnd1dc35BppWo5xWBIfAgdEt6nwDY/jxAms/w2lWjSIdnJjMMFbX19fnY/hkgBA7cDJr3gtxfhsE3hAwvbO2tjbNN9DkBFZeUhV76xeGChAZhN/mrsaLTAu/jSQ5+QHWFClMF+OefQOD5IiBFnegRrykEDEqEEq/h7DZStQ4BTs2jdiVQJsBXs2KOxM9g1L8Z+y5KWYXgmBur3ucZOqZ8yFs2sQihMXFxY/FwycUHrh8fJ/F7kJEb0ABFJx0MjwpNcNqH4I+pKLA5aIoPINudTh+MN4JbRKZzIv2p/94y/vujQSu4XvP6XR+ZbVal0vwurq6+yRJEkJboGhaBDxuOhyOPE3KadLRodbW1gOw7jvY3AXLjOObxHcD92IQJM8GLBGlc5/JZPJgzW9Yk4nxA6H4g8/XCA42GEhcXHE3MtBes9lsLk1OADu4HB5+76ytMuj5B5fIEhfOW9evGSD8KUSdfeDjUcLH5e80rPwuFHifRQGw+mN4jf0eCh+Xn7veI48K4Do5avh4/Z1WVADu8QWav7zDF6HoEwo0innFB3FRAEJkBJdH7DTeBy/5BvDxTxD7L7GALA4wq7COz99pCC8Ec/vGUOg7PFj2raYR5THmy9C9tWpazE2q8dbkSRkO8ET8qbi4+CgT/4oYM6FIq+zp6XEq0N0oLS29BKG3w/ctKSkp1XhHXFfjfRsAAP//E0JInwAAAAZJREFUAwDDOF7tAmFwsQAAAABJRU5ErkJggg=='
    AppProtection        = 'iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAADUUlEQVR4nOyZS0wTQRjHv5ktqAGJChESInIyPmI8ESVKeAQROBg1mBgfCMSDT0TAaKLgilEiRoqKiRIMBL0QTTh4kAKNIHDw4EUl3kwPCgcelgoVu+yO34qblNpCS1lmSfo7tLvz2vl/8+90dsaUWNrOIABstdlEu+ZV1x0TLHNCAngTEsCbkADehATwJiSANwSWOSEL8cbEezmNH4OE0aM2c1bPw94TDwCE6eKU5rKNJZYMIEoLISTes+4sAcALxj4yQp//lOSG4kNP6Lq8ky8p0Dw161F/wYZRoe5US1vpNkWST6PI476aWTIBjMGA+73NnLNDfHtgTXRYVDkha89gUoyWR4AcjpFjU89mN5gnYLheTO++66tdHQWwm7baHNEz9XbX/thVEZHbTXJYASUEI05WeK9P1q8Mj6wOZ6uu3+850mqXhhoF19SAmPve4V5K9xGo68uvIQTiKJAtGNlN2LEoUMDvCZwSIcIp2YuoIhQxUwTc6EgfYYx8weof0FrjugswEeEyBMEvyQHTissthcRgQFLwIkWNgaGnUZlNw4Trx5xlDC3AMTU8bxnDCnD+Zx3vGFKAap3JeayjYUgB/lhHw3AC/LWOhu7L6fr+Qr/XS6p1xpzfIRAMNQKBWEfDMAKc0nhA1tHQcTntfS3kDVmRcNaxw0IwxAg4fgduHQ3uAmasI8FC4SogGOtocBUQjHU0uAkI1joaFHSCAVk98w1jnnnqdBmsdf49xa6bAHwJ3ql+EQZdnlmOqRFYFBjp000AbofsTiyzbJYEdgVf6Ce1dDXyMgveOjPPUFr1GwGEKcrjS8nNNvznK1HvVeuo3l+UtoH1i1ndL3QVgKOQkVBiuXB+T1MjodS8WNZRX+Yppfnqta4CVHCYzQkl7Znnkp+VyoqrBYIEIy8xKueImdavf9uHJaayI70Kt1cqYAFg5Cfxh3uwap+1U0vjsr1eaUk7hkPThELC/K7E2DeFyrm39r775J7M7Xygois1iSjCG+xA9HxlMfKvJUoKqzOto555XA84rlkz4gUZ2rATSd5LsAn0fHlVVvdTX21wP6ERP28NVwbjarAjF2dlMHglMan4Tnbv0Fz1DXPEJHam7cI9z3t46VCIfNXT6774AwAA//9EXgF+AAAABklEQVQDAPtbVXQXSCetAAAAAElFTkSuQmCC'
    PolicySets           = 'iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAAGL0lEQVR4nNRZa2wUVRQ+s9vt7pY+7EMwAqFUMbFAQ4xVo9A0xiqGxIBEJFqCabtKm4BSScAfGhJfKYn8aIOm3b5ITJAKJgqJmiZqpFRQ8FVbf1D6oLRIoXXbbt2dfcz43dnudrvdbWdmZ9rwbe7OzH1+555z7p25J4HucBjkVmxoaDh87NixZNIZVVVVKY2Nje/IrZ8wX4Xm5ubtoig2JSQkpAiC8BiyNpOOyMrKOmUymZ5uamqq9Pl8r9lstpNz1ediFWDGHzYYDC0gvjqYBwFofHw8b+/evR2kA+rq6jaYzebfMG4oz+v19huNxh27d+/+OVqbWRqorq5ekZKSchqNHuG4mfKxjpOSkr7A7RrSAZj5U+Hkp/JWwQIuwqx+x/0Lu3bt6qZoAsC+74H0J1CpMLKTcEAokXQCiIoxxmSCbEDxFVhGm8fj2VleXj7IyiSmyDySmpo6BAFikvf7/ZM8z9tKSkoeIJ2AvtewMdhYFEOQxMTEjbCC63a7/UOWJ2nA5XKthsNwFouFIgWA3ftRZkfnFXrOfhBlZWX1mGnMaUMt/K8UpmyI4EMQktxu9/3sOVQIZ6GJiQmpkGmSJajqx5GRkaWlpaXlC0E+CDYWBHl1dHT0bnBoC/Jh3BhH5IVMOegDQrAxJJMSNFFQUVFxLtTr/gGr0Tp2zS9QFmkNkQ5S1bojkdmVlZWjuGyCuRSC/PcUIWS4ALMMH+vxxRkZ5n8tfsGQ9W7RUtqYnURa4Y0zN3x/3HDnzFUHJv5TpGlDI9ISOe9GFgJv5Mgs0tplZirMWUJaIc1qFChyvVYA+QKE4Zsunk784lLUxpQg0itPWKA9K2kJVQJcveWju5IMVLgmUVb9MZdAZzpd9GxTH31ny6b8FdoJoUoAB+8jgfPTtg2psupfve2jpksOcnoEetLeR9+WrKLHV2njR7LfRsNx3emm3nH5JsRj6eoeC9RnQjxV30c/9EySFlAlwG23h/75zy27vgebz9DkdH2XT6TNjf3UesVJ8UKVACStwKoXDgm8X6Qtzf00OulTx2EKqnwgwD3+jdmL7bNz2AMOYjaphCrpA43ka8A4VdUQpYk0DSJXRAc7d5AKyNeAGToHdY4Rl/Yd+RrIXWqmdKuRstNNktj+sKa3Jn3ihMs/yhm59zI/6nH3vpnzFSmA4p1Y+kmv7Qo0gKn/4JllVNM+Ql3DfGQx6yiTvGImx/Gf495MCqDKB8Swf7nY82i6lGKh5c8xKm4ZNJFCqHNiDVahWWBmqWJd0GQVam1tpZqaGlKKgoICOnDgQOCBmaWKdzpNNFBUVCSluCBpQLkKNNGAw+GggYEBUoqMjAxavnx54EHSACmGJhrApx91dCg/Klq5cuW0ALSIPpCTkyOl+CCq+q7RRAPt7e109uxZUorc3FwqLi4OPIC8uFg+kJeXRzjNI6VYsiTs03QxfSA5OZnWr19PcWEx9wFNsJj7gCZQuQ/If502B94hO2/y+MJit3pogBRDvgAWgxf9j7/dOkyDY95xzTWg+z5weJ0T/aexW6G6+y8DJ64lTbGQ+4AE7X0gnn1ACM/EkTbhVDoft+ejN+MclwddxL3VSVoixWzwe6PkI26Rz47VETeYZhDtcJepkMUIEERgs9FWX19/DjGxrVOnxCH03uRftuWnb7GYOHlHczJxvs99+dew56NHj2akpaV9iejMRsaNHauzk/Op4/aZh7uMNCMftEN2heSbMjMzh3G8bcd5fSjA4Xg/t99O9DHpBEYOQ9aC04wAB+OIoIcUJ2CJQSqEhBdQ6I/mRDjWNkKwPQi3TiBqUko6A1ovO378+ITVarVFRmem+DBBBJRfYs8hxohOpiKzGcJsRcOYHgo1/o2ITS7pAExQF8g9GKscfiBi/K/hny8dOnRojOWFTGjfvn1Y2+l5fBreixn/DB1tihHwi2PlmhsgyMfIZyEwFifegcB3P81FBkHsIVwKamtrH4ImWuAH9wXL2CqAgN9zpBOcTuc2WEBPuAVgvGtIL4L4hWht5l3Modbt6LARKRUrwEl0tJN0BKL1dcz+WagVs74H4306V/15zQH2fhqX09DIfpjVJ6QzoIXXcekE8Wo5kVGtX2gWHP8DAAD//2l6ZyYAAAAGSURBVAMA/UOKJE3dAp0AAAAASUVORK5CYII='
}
$script:AllIcon = 'Intune'

function Get-CategoryTable {
    # Every category the tool can show: one shared load / plan / write / verify path for all of them.
    $t = [ordered]@{}
    $t['apps'] = [PSCustomObject]@{
        Key = 'apps'; Icon = 'Applications'; Label = $L.CatApps; HasIntent = $true; NeedsConfigScope = $false
        Sources = @(
            # no $select: the version fields (displayVersion, productVersion, identityVersion) belong to the
            # derived app types and would not come back with a $select on the base collection
            (New-Source -List 'deviceAppManagement/mobileApps' `
                        -ItemPath 'deviceAppManagement/mobileApps/{0}' -Write 'Single' `
                        -AssignmentType '#microsoft.graph.mobileAppAssignment')
        )
    }
    $t['config'] = [PSCustomObject]@{
        Key = 'config'; Icon = 'DeviceConfiguration'; Label = $L.CatConfig; HasIntent = $false; NeedsConfigScope = $true
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
        Key = 'compliance'; Icon = 'CompliancePolicies'; Label = $L.CatCompliance; HasIntent = $false; NeedsConfigScope = $true
        Sources = @(
            # POST .../assignments is documented but has no route in the service: /assign
            (New-Source -List 'deviceManagement/deviceCompliancePolicies?$select=id,displayName' `
                        -ItemPath 'deviceManagement/deviceCompliancePolicies/{0}' -Write 'Replace' `
                        -AssignAction 'deviceManagement/deviceCompliancePolicies/{0}/assign' `
                        -AssignmentType '#microsoft.graph.deviceCompliancePolicyAssignment')
        )
    }
    $t['appConfig'] = [PSCustomObject]@{
        Key = 'appConfig'; Icon = 'AppConfiguration'; Label = $L.CatAppConfig; HasIntent = $false; NeedsConfigScope = $true
        Sources = @(
            # POST .../assignments is documented but has no route in the service: /assign
            (New-Source -List 'deviceAppManagement/mobileAppConfigurations?$select=id,displayName' `
                        -ItemPath 'deviceAppManagement/mobileAppConfigurations/{0}' -Write 'Replace' `
                        -AssignAction 'deviceAppManagement/mobileAppConfigurations/{0}/assign' `
                        -AssignmentType '#microsoft.graph.managedDeviceMobileAppConfigurationAssignment'),
            # managed apps (MAM): users only, written as a complete list through /assign
            (New-Source -List 'deviceAppManagement/targetedManagedAppConfigurations?$select=id,displayName' `
                        -ItemPath 'deviceAppManagement/targetedManagedAppConfigurations/{0}' -Write 'Replace' `
                        -AssignAction 'deviceAppManagement/targetedManagedAppConfigurations/{0}/assign' `
                        -AssignmentType '#microsoft.graph.targetedManagedAppPolicyAssignment' -UsersOnly $true `
                        -TypeName $L.TypeMamAppConfig -Eventual $true)
        )
    }
    # app protection: users only; read and written per platform collection (the documented
    # managedAppPolicies/{id}/assign answers "Resource not found for the segment 'assign'")
    $t['appProtection'] = [PSCustomObject]@{
        Key = 'appProtection'; Icon = 'AppProtection'; Label = $L.CatAppProtection; HasIntent = $false; NeedsConfigScope = $true
        Sources = @(
            foreach ($coll in @('iosManagedAppProtections', 'androidManagedAppProtections', 'windowsManagedAppProtections')) {
                $single = $coll.Substring(0, $coll.Length - 1)   # iosManagedAppProtection ...
                New-Source -List "deviceAppManagement/$coll`?`$select=id,displayName" `
                           -ItemPath "deviceAppManagement/$coll/{0}" -Write 'Replace' `
                           -AssignAction "deviceAppManagement/$coll/{0}/assign" `
                           -AssignmentType '#microsoft.graph.targetedManagedAppPolicyAssignment' -UsersOnly $true -Eventual $true `
                           -DefaultType $single
            }
        )
    }
    # policy sets: the set itself is assigned; what it contains shows up read-only in the other categories.
    # No GET/POST on .../assignments and no $expand on the list: read per set with $expand, write the
    # complete list through /update.
    $t['policySets'] = [PSCustomObject]@{
        Key = 'policySets'; Icon = 'PolicySets'; Label = $L.CatPolicySets; HasIntent = $false; NeedsConfigScope = $true
        Sources = @(
            (New-Source -List 'deviceAppManagement/policySets?$select=id,displayName' `
                        -ItemPath 'deviceAppManagement/policySets/{0}' -Write 'Replace' `
                        -AssignAction 'deviceAppManagement/policySets/{0}/update' -ReadVia 'Expand' -DefaultType 'policySet' `
                        -AssignmentType '#microsoft.graph.policySetAssignment')
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

function Get-AppVersion {
    # Windows app version by type: win32LobApp displayVersion, windowsMobileMSI productVersion,
    # AppX/MSIX identityVersion; store, WinGet, Office and Edge apps have none ('')
    param($Raw)
    foreach ($p in 'displayVersion', 'productVersion', 'identityVersion') {
        $v = [string]$Raw.$p
        if ($v) { return $v }
    }
    return ''
}

function ConvertTo-Item {
    # One Graph object of a category -> the object the tool works with.
    param($Raw, $Category, $Source)
    $id    = [string]$Raw.id
    $odata = ([string]$Raw.'@odata.type') -replace '^#microsoft\.graph\.', ''
    if (-not $odata -and $Source.DefaultType) { $odata = $Source.DefaultType }
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
        Version       = (Get-AppVersion $Raw)
        HasIntent     = [bool]$Category.HasIntent
        UsersOnly     = [bool]$Source.UsersOnly
        Write         = $Source.Write
        AssignmentType = $Source.AssignmentType
        ItemPath      = ($Source.ItemPath -f $id)
        ReadVia       = $Source.ReadVia
        Eventual      = [bool]$Source.Eventual
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

function Connect-GaaGraph {
    # not "Connect-Graph": Microsoft.Graph.Authentication exports that as an alias of Connect-MgGraph, and
    # an alias wins over a function - after the module is loaded, "Reconnect" called Connect-MgGraph
    param([bool]$WithFilterNames = $false, [bool]$WithConfig = $false)
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) { throw $L.ModuleMissing }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $p = @{ Scopes = (Get-RequestedScopes $WithFilterNames $WithConfig); ErrorAction = 'Stop' }
    if ($TenantId) { $p['TenantId'] = $TenantId }
    if ((Get-Command Connect-MgGraph).Parameters.ContainsKey('NoWelcome')) { $p['NoWelcome'] = $true }
    Connect-MgGraph @p | Out-Null
    return Get-MgContext
}

function Disconnect-GaaGraph {
    # Connect-MgGraph keeps a sign-in record per Windows user and signs in with that account again without
    # asking. Disconnect-MgGraph deletes the record and the token cache, so the next connect offers the
    # account choice again. (Not -SignOutFromBroker: that would sign other apps out of the Windows account.)
    if (Get-Command Disconnect-MgGraph -ErrorAction SilentlyContinue) {
        try { Disconnect-MgGraph -ErrorAction Stop | Out-Null } catch { }   # "No application to sign out from" is fine
    }
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

function Read-Assignments {
    # the assignments of one object, as object[] - via its assignments collection or via $expand
    param([string]$ItemPath, [string]$ReadVia = 'Collection')
    if ($ReadVia -eq 'Expand') {
        $r = Invoke-MgGraphRequest -Method GET -Uri "$($script:GraphBase)/$ItemPath`?`$expand=assignments" -ErrorAction Stop
        $list = @()
        foreach ($a in $r.assignments) { if ($null -ne $a) { $list += $a } }
        return ,$list
    }
    return ,(Invoke-GraphPaged -Uri "$($script:GraphBase)/$ItemPath/assignments")
}

function Get-ItemAssignments {
    param($Item)
    return ,(Read-Assignments $Item.ItemPath $Item.ReadVia)
}

$script:Sleep       = { param([int]$Seconds) Start-Sleep -Seconds $Seconds }   # replaced by the tests
$script:PollSeconds = 5
# MAM (measured live): after /assign, exclusions show up only now and then for minutes - even two reads in
# a row can both be stale. For these objects the list the tool itself sent last is the truth for
# $script:SentTrustMinutes: the next write builds on it, loading and read-back show it.
$script:LastSent         = @{}   # item key -> @{ Time; List }
$script:SentTrustMinutes = 10
$script:Now              = { Get-Date }   # replaced by the tests

function Get-LastSent {
    # the list last sent for an eventually consistent object, while it is still trusted; else $null
    param($Item)
    if (-not $Item.Eventual) { return $null }
    $e = $script:LastSent[$Item.Key]
    if (-not $e) { return $null }
    if (((& $script:Now) - $e.Time).TotalMinutes -gt $script:SentTrustMinutes) { return $null }
    return ,$e.List
}

function Get-GraphErrorCode {
    param($ErrorRecord)
    try { return [string](($ErrorRecord.ErrorDetails.Message | ConvertFrom-Json -ErrorAction Stop).error.code) } catch { return '' }
}

function Get-AssignmentSignature {
    # order-independent fingerprint of an assignment list: target type, group, filter
    param($Assignments)
    $parts = foreach ($a in $Assignments) {
        if (-not $a) { continue }
        "$($a.target.'@odata.type')|$($a.target.groupId)|$($a.target.deviceAndAppManagementAssignmentFilterId)|$($a.target.deviceAndAppManagementAssignmentFilterType)|$($a.intent)"
    }
    return ((@($parts) | Sort-Object) -join ';')
}

function Read-StableAssignments {
    # For eventually consistent objects: read until two reads $script:PollSeconds apart agree
    # (at most $MaxSeconds); everything else is read once.
    param($Item, [int]$MaxSeconds = 40)
    $a = Get-ItemAssignments $Item
    if (-not $Item.Eventual) { return ,$a }
    $waited = 0
    while ($waited -lt $MaxSeconds) {
        & $script:Sleep $script:PollSeconds; $waited += $script:PollSeconds
        $b = Get-ItemAssignments $Item
        if ((Get-AssignmentSignature $a) -eq (Get-AssignmentSignature $b)) { return ,$b }
        $a = $b
    }
    return ,$a
}

function Test-StateMatches {
    # does the live state of the target match what was wanted ($null = not assigned)?
    param($Live, $Want)
    if (-not $Want) { return (-not $Live) }
    return ([bool]$Live -and $Live.Intent -eq $Want.Intent -and [bool]$Live.Exclude -eq [bool]$Want.Exclude)
}

function Wait-ItemState {
    # Read the object's assignments after a write. Eventually consistent objects are polled until the
    # target shows the wanted state in two reads in a row (at most $MaxSeconds); returns the last read.
    # Returns @{ List; Pending }: Pending = Intune does not show the sent state yet, the list is the one sent.
    param($Item, $Selection, $Want, [int]$MaxSeconds = 60)
    $list = Get-ItemAssignments $Item
    if (-not $Item.Eventual) { return @{ List = $list; Pending = $false } }
    $hits = 0; $waited = 0
    while ($true) {
        $live = ConvertTo-AssignmentState (Find-AssignmentForSelection $list $Selection) $Item.HasIntent
        if (Test-StateMatches $live $Want) { $hits++ } else { $hits = 0 }
        if ($hits -ge 2) { return @{ List = $list; Pending = $false } }
        if ($waited -ge $MaxSeconds) {
            $sent = Get-LastSent $Item
            if ($null -ne $sent) { return @{ List = $sent; Pending = $true } }
            return @{ List = $list; Pending = $false }
        }
        & $script:Sleep $script:PollSeconds; $waited += $script:PollSeconds
        $list = Get-ItemAssignments $Item
    }
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
        $sep = if ($uri.Contains('?')) { '&' } else { '?' }
        try { $raw = Invoke-GraphPaged -Uri "$uri$sep`$expand=assignments" -OnPage $OnPage } catch { $raw = $null }
        $expanded = $false
        foreach ($r in $raw) { if ($r -is [System.Collections.IDictionary] -and $r.Contains('assignments')) { $expanded = $true; break } }
        if (-not $expanded) {
            $raw = Invoke-GraphPaged -Uri $uri -OnPage $OnPage
            foreach ($r in $raw) {
                $r['assignments'] = Read-Assignments ($src.ItemPath -f [string]$r.id) $src.ReadVia
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
        # read the list fresh (and, where reads lag, stable) right before writing it back, so no other
        # target gets lost; resending the same complete list is harmless, so transient errors are retried
        $current = Get-LastSent $Item
        if ($null -eq $current) { $current = Read-StableAssignments $Item }
        $list = New-ReplaceAssignmentList -Current $current -Selection $Selection -Desired $Operation.To `
                    -AssignmentType $Item.AssignmentType -Carry $Operation.From
        $json = @{ assignments = $list } | ConvertTo-Json -Depth 20
        $transient = @('ConditionNotMet', 'TooManyRequests', 'ServiceUnavailable')
        if ($Item.Eventual) { $transient += 'ResourceNotFound' }
        for ($try = 1; $true; $try++) {
            try {
                Invoke-MgGraphRequest -Method POST -Uri "$($script:GraphBase)/$($Item.AssignAction)" -Body $json `
                    -ContentType 'application/json' -ErrorAction Stop | Out-Null
                if ($Item.Eventual) { $script:LastSent[$Item.Key] = @{ Time = (& $script:Now); List = $list } }
                return
            } catch {
                if ($try -ge 5 -or $transient -notcontains (Get-GraphErrorCode $_)) { throw (Get-GraphErrorText $_) }
                & $script:Sleep $script:PollSeconds
            }
        }
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
$form.MinimumSize   = New-Object System.Drawing.Size(1000, 560)   # widened in Shown to fit the top strip
$form.StartPosition = 'CenterScreen'
$form.Font          = New-Object System.Drawing.Font('Segoe UI', 9)

# --- Top strip ---
$stripTop = New-Object System.Windows.Forms.Panel
$stripTop.Dock = 'Top'; $stripTop.Height = 112
$stripTop.BackColor = [System.Drawing.SystemColors]::Control

$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = $L.BtnConnect; $btnConnect.Location = New-Object System.Drawing.Point(10, 8)
$btnConnect.Size = New-Object System.Drawing.Size(120, 26)

$btnDisconnect = New-Object System.Windows.Forms.Button
$btnDisconnect.Text = $L.BtnDisconnect; $btnDisconnect.Location = New-Object System.Drawing.Point(136, 8)
$btnDisconnect.Size = New-Object System.Drawing.Size(100, 26); $btnDisconnect.Enabled = $false

# green check mark: visible only while connected
$lblConnected = New-Object System.Windows.Forms.Label
$lblConnected.Text = [string][char]0x2714; $lblConnected.AutoSize = $true; $lblConnected.Visible = $false
$lblConnected.Font = New-Object System.Drawing.Font('Segoe UI Symbol', 11, [System.Drawing.FontStyle]::Bold)
$lblConnected.ForeColor = [System.Drawing.Color]::FromArgb(16, 124, 16)
$lblConnected.Location = New-Object System.Drawing.Point(244, 10)

$lblAccount = New-Object System.Windows.Forms.Label
$lblAccount.Text = $L.NotConnected; $lblAccount.AutoSize = $true
$lblAccount.Location = New-Object System.Drawing.Point(266, 13)
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

$stripTop.Controls.AddRange(@($btnConnect, $btnDisconnect, $lblConnected, $lblAccount, $lblGroup, $txtGroup, $btnPick, $btnLoad, $lblPlatform, $cmbPlatform,
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

# DPI factor for the owner-drawn category list
$gTmp = $form.CreateGraphics(); $script:Scale = [Math]::Max(1.0, $gTmp.DpiX / 96.0); $gTmp.Dispose()
$script:IconImages = @{}
foreach ($k in $script:IconData.Keys) {
    $ms = [System.IO.MemoryStream]::new([Convert]::FromBase64String($script:IconData[$k]))   # stays open: Image needs it
    $script:IconImages[$k] = [System.Drawing.Image]::FromStream($ms)
}
$catFontSmall = New-Object System.Drawing.Font('Segoe UI', 8)

$lbCat = New-Object System.Windows.Forms.ListBox
$lbCat.Dock = 'Fill'; $lbCat.IntegralHeight = $false; $lbCat.BorderStyle = 'None'
$lbCat.BackColor = [System.Drawing.SystemColors]::Control
$lbCat.DrawMode = 'OwnerDrawFixed'; $lbCat.ItemHeight = [int](42 * $script:Scale)
$lbCat.Add_DrawItem({
    # icon left, name, counts below in grey - like the Intune portal navigation
    param($s, $e)
    if ($e.Index -lt 0 -or $e.Index -ge $lbCat.Items.Count) { return }
    $it = $lbCat.Items[$e.Index]
    $sel = (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0)
    $bg = if ($sel) { [System.Drawing.Color]::FromArgb(204, 228, 247) } else { [System.Drawing.SystemColors]::Control }
    $brush = New-Object System.Drawing.SolidBrush($bg)
    $e.Graphics.FillRectangle($brush, $e.Bounds); $brush.Dispose()
    $icon = [int](24 * $script:Scale); $pad = [int](8 * $script:Scale)
    $img = $script:IconImages[$it.Icon]
    if ($img) {
        $e.Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $e.Graphics.DrawImage($img, $e.Bounds.X + $pad, $e.Bounds.Y + [int](($e.Bounds.Height - $icon) / 2), $icon, $icon)
    }
    $x = $e.Bounds.X + $pad * 2 + $icon
    $w = [Math]::Max(10, $e.Bounds.Right - $x - 2)
    $flags = [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
    $half = [int]($e.Bounds.Height / 2)
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $it.Label, $form.Font,
        (New-Object System.Drawing.Rectangle($x, ($e.Bounds.Y + $half - [int](17 * $script:Scale)), $w, [int](17 * $script:Scale))),
        [System.Drawing.SystemColors]::ControlText, $flags)
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $it.Counts, $catFontSmall,
        (New-Object System.Drawing.Rectangle($x, ($e.Bounds.Y + $half), $w, [int](16 * $script:Scale))),
        [System.Drawing.SystemColors]::GrayText, $flags)
})

# "Not assigned": a read-only grid (name, category, type, publisher, version, change), sortable like the right one
$gridLeft = New-Object System.Windows.Forms.DataGridView
$gridLeft.Dock = 'Fill'; $gridLeft.ReadOnly = $true
$gridLeft.AllowUserToAddRows = $false; $gridLeft.AllowUserToDeleteRows = $false
$gridLeft.AllowUserToResizeRows = $false; $gridLeft.RowHeadersVisible = $false
$gridLeft.SelectionMode = 'FullRowSelect'; $gridLeft.MultiSelect = $true
$gridLeft.AutoSizeColumnsMode = 'None'; $gridLeft.ScrollBars = 'Both'
$gridLeft.BackgroundColor = [System.Drawing.SystemColors]::Window; $gridLeft.BorderStyle = 'FixedSingle'
function New-TextColumn {
    param([string]$Name, [string]$Header, [int]$Width)
    $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c.Name = $Name; $c.HeaderText = $Header; $c.ReadOnly = $true
    $c.Width = [int]($Width * $script:Scale)
    $c.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::Programmatic
    return $c
}
$lcolName      = New-TextColumn 'Name'      $L.ColName      160
$lcolName.MinimumWidth = [int](160 * $script:Scale)
$lcolCategory  = New-TextColumn 'Category'  $L.ColCategory  130
$lcolType      = New-TextColumn 'Type'      $L.ColType      150
$lcolPublisher = New-TextColumn 'Publisher' $L.ColPublisher 130
$lcolVersion   = New-TextColumn 'Version'   $L.ColVersion   90
$lcolChange    = New-TextColumn 'Change'    $L.ColChange    90
$lcolChange.AutoSizeMode = 'Fill'; $lcolChange.MinimumWidth = [int](80 * $script:Scale)
foreach ($c in @($lcolName, $lcolCategory, $lcolType, $lcolPublisher, $lcolVersion, $lcolChange)) { [void]$gridLeft.Columns.Add($c) }
$script:SortLeftColumn = 'Name'
$script:SortLeftDesc   = $false

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
$grid.AutoSizeColumnsMode = 'None'; $grid.ScrollBars = 'Both'   # long names: scroll sideways
$grid.BackgroundColor = [System.Drawing.SystemColors]::Window
$grid.BorderStyle = 'FixedSingle'; $grid.EditMode = 'EditOnEnter'

$colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colName.Name = 'Name'; $colName.HeaderText = $L.ColName; $colName.ReadOnly = $true
$colName.MinimumWidth = [int](160 * $script:Scale)   # sized to the longest name once per rebuild (Update-Views)
$colCategory = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colCategory.Name = 'Category'; $colCategory.HeaderText = $L.ColCategory; $colCategory.ReadOnly = $true; $colCategory.Width = [int](130 * $script:Scale)
$colType = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colType.Name = 'Type'; $colType.HeaderText = $L.ColType; $colType.ReadOnly = $true; $colType.Width = [int](160 * $script:Scale)
$colPublisher = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colPublisher.Name = 'Publisher'; $colPublisher.HeaderText = $L.ColPublisher; $colPublisher.ReadOnly = $true; $colPublisher.Width = [int](130 * $script:Scale)
$colVersion = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colVersion.Name = 'Version'; $colVersion.HeaderText = $L.ColVersion; $colVersion.ReadOnly = $true; $colVersion.Width = [int](90 * $script:Scale)
$colIntent = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
$colIntent.Name = 'Intent'; $colIntent.HeaderText = $L.ColIntent; $colIntent.Width = [int](150 * $script:Scale)
$colIntent.DataSource = $intentTable; $colIntent.ValueMember = 'Value'; $colIntent.DisplayMember = 'Text'
$colIntent.FlatStyle = 'Flat'
$colExcl = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colExcl.Name = 'Exclude'; $colExcl.HeaderText = $L.ColExclude; $colExcl.Width = [int](80 * $script:Scale)
$colFilter = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colFilter.Name = 'Filter'; $colFilter.HeaderText = $L.ColFilter; $colFilter.ReadOnly = $true; $colFilter.Width = [int](150 * $script:Scale)
$colChange = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colChange.Name = 'Change'; $colChange.HeaderText = $L.ColChange; $colChange.ReadOnly = $true
$colChange.AutoSizeMode = 'Fill'; $colChange.MinimumWidth = [int](80 * $script:Scale)   # takes the rest, never squeezes the others
# One by one: Columns.AddRange takes a params array, and Windows PowerShell 5.1 does not bind an
# object[] to it (Controls.AddRange has no params and works with @(...)).
foreach ($c in @($colName, $colCategory, $colType, $colPublisher, $colVersion, $colIntent, $colExcl, $colFilter, $colChange)) {
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
[void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, [int](190 * $script:Scale))))
[void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 150)))
[void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))
[void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$table.Controls.Add($lblCat,     0, 0)
$table.Controls.Add($lblLeft,    1, 0)
$table.Controls.Add($lblRight,   3, 0)
$table.Controls.Add($lbCat,      0, 1)
$table.Controls.Add($gridLeft,   1, 1)
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

function New-CategoryEntry {
    # entry of the owner-drawn category list; ToString keeps keyboard search in the list working
    param([string]$Icon, [string]$Label, [string]$Counts)
    $e = [PSCustomObject]@{ Icon = $Icon; Label = $Label; Counts = $Counts }
    $e | Add-Member -MemberType ScriptMethod -Name ToString -Value { $this.Label } -Force
    return $e
}

function Update-CategoryList {
    # "Apps  (assigned / total)" per category for the selected platform; "(...)" = not loaded yet
    $platform = Get-SelectedPlatform
    $texts = @()
    $sumA = 0; $sumT = 0
    foreach ($cat in $script:Categories.Values) {
        if (-not $script:LoadedCats[$cat.Key]) { $texts += (New-CategoryEntry $cat.Icon $cat.Label $L.CatNotLoaded); continue }
        $a = 0; $t = 0
        foreach ($it in $script:ItemByKey.Values) {
            if ($it.Category -ne $cat.Key -or -not (Test-PlatformMatch $it.Platforms $platform)) { continue }
            $t++
            if ($script:Desired.ContainsKey($it.Key)) { $a++ }
        }
        $sumA += $a; $sumT += $t
        $texts += (New-CategoryEntry $cat.Icon $cat.Label ($L.CatCounts -f $a, $t))
    }
    $all = @((New-CategoryEntry $script:AllIcon $L.CatAll ($L.CatCounts -f $sumA, $sumT))) + $texts
    $script:Rebuilding = $true
    try {
        $sel = $lbCat.SelectedIndex
        $lbCat.BeginUpdate()
        if ($lbCat.Items.Count -ne $all.Count) {
            $lbCat.Items.Clear()
            foreach ($x in $all) { [void]$lbCat.Items.Add($x) }
        } else {
            for ($i = 0; $i -lt $all.Count; $i++) {
                $old = $lbCat.Items[$i]
                if ($old.Label -ne $all[$i].Label -or $old.Counts -ne $all[$i].Counts) { $lbCat.Items[$i] = $all[$i] }
            }
        }
        $lbCat.EndUpdate()
        $want = 0
        if ($script:CurrentCat -ne 'all') { $want = 1 + [array]::IndexOf(@($script:Categories.Keys), $script:CurrentCat) }
        if ($sel -ne $want -or $lbCat.SelectedIndex -ne $want) { $lbCat.SelectedIndex = $want }
    } finally { $script:Rebuilding = $false }
}

function Update-ColumnVisibility {
    # Category only in "All"; mode and publisher where apps are shown; version for apps on Windows (or all platforms)
    $cat  = $script:CurrentCat
    $apps = ($cat -eq 'apps' -or $cat -eq 'all')
    $win  = (@('Windows', 'All') -contains (Get-SelectedPlatform))
    [void]$grid.EndEdit(); $grid.CurrentCell = $null; $gridLeft.CurrentCell = $null
    $colCategory.Visible  = ($cat -eq 'all');  $lcolCategory.Visible  = ($cat -eq 'all')
    $colIntent.Visible    = $apps
    $colPublisher.Visible = $apps;             $lcolPublisher.Visible = $apps
    $colVersion.Visible   = ($apps -and $win); $lcolVersion.Visible   = ($apps -and $win)
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
    Update-ColumnVisibility
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

        $gridLeft.SuspendLayout()
        $gridLeft.Rows.Clear()
        $leftRows = @()
        foreach ($it in $sorted) {
            if ($script:Desired.ContainsKey($it.Key)) { continue }
            $chg = ''
            if ($script:Original.ContainsKey($it.Key)) { $chg = $L.ChangeRemove }   # assigned now, removed on Save
            $leftRows += [PSCustomObject]@{ Key = $it.Key; Name = $it.Name; Category = $it.CategoryLabel; Type = $it.Type
                                            Publisher = $it.Publisher; Version = $it.Version; Change = $chg }
        }
        foreach ($r in (Sort-GridRows $leftRows $script:SortLeftColumn $script:SortLeftDesc)) {
            $row = New-Object System.Windows.Forms.DataGridViewRow
            $row.CreateCells($gridLeft)
            $row.Cells[$lcolName.Index].Value      = $r.Name
            $row.Cells[$lcolCategory.Index].Value  = $r.Category
            $row.Cells[$lcolType.Index].Value      = $r.Type
            $row.Cells[$lcolPublisher.Index].Value = $r.Publisher
            $row.Cells[$lcolVersion.Index].Value   = $r.Version
            $row.Cells[$lcolChange.Index].Value    = $r.Change
            $idx = $gridLeft.Rows.Add($row)
            $row = $gridLeft.Rows[$idx]
            $row.Tag = $r.Key
            if ($r.Change) { $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::MistyRose }
        }
        $gridLeft.AutoResizeColumn($lcolName.Index, [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::AllCells)
        # a grid selects its first row by itself when filled - a button click would then move an object
        # nobody picked
        $gridLeft.CurrentCell = $null; $gridLeft.ClearSelection()
        foreach ($col in $gridLeft.Columns) {
            $col.HeaderCell.SortGlyphDirection = [System.Windows.Forms.SortOrder]::None
            if ($col.Name -eq $script:SortLeftColumn) {
                $col.HeaderCell.SortGlyphDirection = if ($script:SortLeftDesc) { [System.Windows.Forms.SortOrder]::Descending } else { [System.Windows.Forms.SortOrder]::Ascending }
            }
        }
        $gridLeft.ResumeLayout()

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
                Publisher = $it.Publisher; Version = $it.Version
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
            $row.Cells[$colPublisher.Index].Value = $r.Publisher
            $row.Cells[$colVersion.Index].Value  = $r.Version
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
        # once after filling - an AllCells column would measure all rows again after every single row
        $grid.AutoResizeColumn($colName.Index, [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::AllCells)
        $grid.CurrentCell = $null; $grid.ClearSelection()   # no row selected by itself (Remove would act on it)
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
    $btnDisconnect.Enabled = (-not $Busy -and $script:Connected)
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
function Set-AccountDisplay {
    # "Connected: account (tenant)" with a green check mark, or "(not connected)" - the only place that sets it
    param($Context)
    if ($Context) {
        $lblAccount.Text = $L.ConnectedAs -f $Context.Account, $Context.TenantId
        $lblAccount.ForeColor = [System.Drawing.SystemColors]::ControlText
        $lblConnected.Visible = $true
        $btnConnect.Text = $L.BtnReconnect
    } else {
        $lblAccount.Text = $L.NotConnected
        $lblAccount.ForeColor = [System.Drawing.SystemColors]::GrayText
        $lblConnected.Visible = $false
        $btnConnect.Text = $L.BtnConnect
    }
}

function Invoke-Connect {
    Set-Busy $true
    $lblStatus.Text = $L.StatusConnecting; $form.Update()
    try {
        $ctx = Connect-GaaGraph -WithFilterNames $chkFilterNames.Checked -WithConfig $script:NeedConfig
        $script:Connected = $true
        $who = "$($ctx.Account)|$($ctx.TenantId)"
        if ($script:ConnectedAs -and $script:ConnectedAs -ne $who) {
            # other account or tenant: the loaded IDs belong to the old one - never write them to the new one
            $script:ItemByKey = @{}; $script:Original = @{}; $script:Desired = @{}; $script:LoadedCats = @{}
            $script:NeedReload = $true
        }
        $script:ConnectedAs = $who
        Set-AccountDisplay $ctx
        $lblStatus.Text = ''
        if ($chkFilterNames.Checked) { Update-FilterNames }
    } catch {
        $script:Connected = $false
        Set-AccountDisplay $null   # a failed connect ends the previous session too (Connect-MgGraph logs out on error)
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
                [void](Connect-GaaGraph -WithFilterNames $true -WithConfig $script:NeedConfig)
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
        [void](Connect-GaaGraph -WithFilterNames $chkFilterNames.Checked -WithConfig $true)   # the one consent prompt
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
        $sent = Get-LastSent $it
        if ($null -ne $sent) { $it.Assignments = $sent }   # MAM: fresher than what Intune shows yet
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
    $keys = @($gridLeft.SelectedRows | ForEach-Object { [string]$_.Tag })
    if (-not $keys) { return }
    foreach ($k in $keys) {
        $it = $script:ItemByKey[$k]
        $want = $Intent
        if (-not $it.HasIntent) { $want = '' }
        $o = $script:Original[$k]
        if ($o -and $o.Intent -eq $want -and [bool]$o.Exclude -eq $Exclude) {
            $script:Desired[$k] = [PSCustomObject]@{ Intent = $o.Intent; Exclude = $o.Exclude }
        } else {
            $script:Desired[$k] = [PSCustomObject]@{ Intent = $want; Exclude = $Exclude }
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
$gridLeft.Add_CellDoubleClick({
    param($s, $e)
    if ($e.RowIndex -lt 0 -or $script:CurrentCat -eq 'all') { return }
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
$gridLeft.Add_ColumnHeaderMouseClick({
    param($s, $e)
    $name = $gridLeft.Columns[$e.ColumnIndex].Name
    if ($script:SortLeftColumn -eq $name) { $script:SortLeftDesc = -not $script:SortLeftDesc }
    else { $script:SortLeftColumn = $name; $script:SortLeftDesc = $false }
    Update-Views
})
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
$cmbPlatform.Add_SelectedIndexChanged({ if (-not $script:Rebuilding) { Update-ColumnVisibility; Update-Views } })
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
    $pendingMam = New-Object System.Collections.Generic.List[string]
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
                $res = Wait-ItemState $it $sel $op.To
                $it.Assignments = $res.List
                if ($res.Pending) { $pendingMam.Add("[$($it.CategoryLabel)] $($it.Name)") }
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
            $ok = Test-StateMatches $live $want
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
        $msg = $L.SaveOk -f $plan.Count
        if ($pendingMam.Count -gt 0) { $msg += ($L.MamPending -f ($pendingMam -join "`n")) }
        [void][System.Windows.Forms.MessageBox]::Show($msg, $L.TitleSave, 'OK', 'Information')
    }
}
#endregion

#region Wiring
$btnConnect.Add_Click({ Invoke-Connect })
$btnDisconnect.Add_Click({
    if (-not (Confirm-Discard)) { return }
    Disconnect-GaaGraph
    # nothing of the old account may survive: data, sent MAM lists, filter names, extra permission
    $script:Connected = $false; $script:ConnectedAs = ''; $script:NeedConfig = $false
    $script:ItemByKey = @{}; $script:Original = @{}; $script:Desired = @{}; $script:LoadedCats = @{}
    $script:LastSent = @{}; $script:FilterNames = @{}
    Set-AccountDisplay $null
    Set-Busy $false
    Update-ButtonMode; Update-Views
    $lblStatus.Text = $L.StatusSignedOut
})
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
    # the window may not get narrower than the top strip (the rightmost control is fully visible)
    $right = 0
    foreach ($c in $stripTop.Controls) { if ($c.Right -gt $right) { $right = $c.Right } }
    $minW = $right + [int](12 * $script:Scale) + ($form.Width - $form.ClientSize.Width)
    if ($form.MinimumSize.Width -lt $minW) { $form.MinimumSize = New-Object System.Drawing.Size($minW, $form.MinimumSize.Height) }
    if ($form.Width -lt $minW) { $form.Width = $minW }
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
