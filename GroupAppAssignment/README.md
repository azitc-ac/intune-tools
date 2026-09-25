# GroupAppAssignment – Intune assignments seen from the group

*English · [Deutsch](README.de.md)*

Counterpart to the [Intune Bulk App Assignment Tool](https://github.com/TheJamberry/Intune-Bulk-App-Assignment-Tool):
that one starts from the **apps** ("these apps to these groups"). This tool starts from the **group** –
like `CollectionMembership` in the [SCCM-RightClickTools](https://github.com/azitc-ac/SCCM-RightClickTools/tree/main/CollectionMembership) –
and shows not only apps but everything you typically assign to a (for example iOS) group.

```
┌ Category ───────────┬ Not assigned ─────────┬──────────┬ Assigned ───────────────────────────────┐
│ All         (23/410)│                       │ Assign > │ Name | Category | Type | Mode | Exclus. │
│ Apps        (12/140)│                       │Exclude > │ …                                       │
│ Configuration (6/85)│                       │          │                                         │
│ Compliance    (1/9) │                       │ < Remove │                                         │
│ …                   │                       │          │                                         │
└─────────────────────┴───────────────────────┴──────────┴─────────────────────────────────────────┘
```

- Pick a group (search in Entra ID) – or **All users** / **All devices**.
- The **category on the left** (icons as in the Intune portal, below them "assigned / total" for the selected
  platform, `(...)` = not loaded yet) decides what the middle and the right side show. A category is loaded
  the first time it is opened.
- **Middle:** every object of the category that is *not* assigned to the target – a sortable table like the
  right one.
- **Right:** every object that is assigned – for apps with their **mode** (Required / Available / Uninstall /
  Available without enrollment), for all of them with **exclusion** and **filter**.
- **Buttons** follow the category: apps `Required >` `Available >` `Uninstall >` `Exclude >`, all other
  categories `Assign >` `Exclude >`, plus `< Remove`. Double-click in the middle = Required or Assign.
  **"All"** only shows and removes (a *Category* column is added).
- **Platform** at the top (default iOS/iPadOS) narrows every category; objects without a platform of their
  own (web apps, …) are always shown. Search and type filter apply to the middle and the right side.
- Clicking a column header on the right sorts by it (again: descending), equal values by name.
- Apps (and "All") show a **Publisher** column on both sides, with platform Windows (or All) also a
  **Version** column (`displayVersion` of Win32 apps, `productVersion` of MSI, `identityVersion` of AppX/MSIX;
  store, WinGet, Office and Edge apps have none).
- Long names: the middle and the right side scroll sideways; the name column on the right grows with the
  longest name. "Not assigned" and "Assigned" have the same width.
- Colours: right green = new, yellow = changed; middle red with "to be removed" = the assignment will be
  deleted.
- A green check mark next to "Connected: …" shows that the sign-in worked.
- **Save** lists all changes across all categories, writes them and then **reads every touched object back
  from Intune** – the view shows the real state, differences are reported.

Only the assignment **of the selected target** is touched; every other assignment of an object stays as it
is. The window is bilingual: **English** by default, **German** automatically with a German Windows display
language (`de-*`); `-Language en|de` forces one.

The category icons come from [IntuneManagement](https://github.com/Micke-K/IntuneManagement) (MIT) and show
Microsoft's Intune portal icons – see `THIRD-PARTY-NOTICES.md`.

## Categories

| Category | Graph (beta) | Write |
|---|---|---|
| Apps | `deviceAppManagement/mobileApps` | one by one (`POST`/`DELETE …/assignments`) |
| Configuration profiles – templates (device restrictions, Wi-Fi, VPN, certificates, iOS update, …) | `deviceManagement/deviceConfigurations` | one by one |
| Configuration profiles – settings catalog (incl. declarative software update) | `deviceManagement/configurationPolicies` | complete list (`…/assign`) |
| Compliance | `deviceManagement/deviceCompliancePolicies` | complete list (`…/assign`) |
| App configuration (managed devices) | `deviceAppManagement/mobileAppConfigurations` | complete list (`…/assign`) |
| App configuration (managed apps, MAM) – users only | `deviceAppManagement/targetedManagedAppConfigurations` | complete list (`…/assign`) |
| App protection (iOS, Android, Windows) – users only | `deviceAppManagement/{ios,android,windows}ManagedAppProtections` | complete list (`…/{id}/assign`) |
| Policy sets (the set itself; its content shows up read-only in the other categories) | `deviceAppManagement/policySets` | complete list (`…/update`), read via `?$expand=assignments` |

**Complete list** means: right before writing, the tool reads the object's assignment list fresh, changes
only the entry of the selected target and sends the list back. All other targets go along unchanged,
including their filter; the test script checks this explicitly and it is confirmed live (see below).

**Checked live** (test tenant, 2026-09) – and different from the Graph documentation:
- Compliance and app configuration (devices): the documented `POST …/assignments` has no route in the
  service ("No OData route exists") – only `/assign` works.
- App protection: the documented `managedAppPolicies/{id}/assign` answers "Resource not found for the
  segment 'assign'" – `iosManagedAppProtections/{id}/assign` (or android/windows) works.
- Policy sets: neither `GET` nor `POST …/assignments` exists, and the list does not allow `$expand` –
  each set is read via `?$expand=assignments` and written via `/update`.
- App protection and policy sets: with `$select`, Graph sends no `@odata.type` for these collections – type
  and platform come from the collection the object was read from.
- **MAM (app protection, MAM app configuration) is only eventually consistent:** after `/assign`,
  inclusions show up at once, **exclusions only now and then for minutes** – measured: after setting an
  exclusion, 11 of 13 reads over 2 minutes did not show it, and two reads in a row were stale too. A
  complete-list write based on such a read deleted the exclusion in the test. Writing shortly after a change
  also fails temporarily with `ConditionNotMet`/`ResourceNotFound`. For MAM objects the tool therefore:
  - remembers the list it **sent itself** last for 10 minutes and builds the next write on it instead of on
    a read; loading and reading back show the sent state during that time as well;
  - otherwise reads only when two reads 5 s apart agree;
  - retries the complete-list write on these errors (up to 5 attempts);
  - waits up to 60 s when reading back; if Intune still does not show the state, it reports that as a note
    ("not visible everywhere yet"), not as an error.

  **Limit:** if *someone else* (portal, another tool) changes exclusions of the same MAM object, the tool
  cannot see that reliably during the first minutes – and every complete-list writer, a script included, has
  the same gap. Leave a few minutes between two people editing the same MAM object.

## Requirements

| | |
|---|---|
| OS / PowerShell | Windows, Windows PowerShell 5.1 (or 7.x) – WinForms |
| Module | `Microsoft.Graph.Authentication` (`Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`) |
| Graph permissions (delegated) | Apps: `DeviceManagementApps.ReadWrite.All`, `Group.Read.All` – the same as the Bulk App Assignment Tool, so no new consent prompt. Every other category: additionally `DeviceManagementConfiguration.ReadWrite.All`, requested only when such a category is opened for the first time (one consent prompt). "Load filter names" without another category: `DeviceManagementConfiguration.Read.All` |

Sign-in is interactive with your own account (`Connect-MgGraph`), no app registration.
**Switching accounts:** `Connect-MgGraph` remembers the sign-in per Windows user and signs in with the same
account next time without asking – so "Reconnect" stays with the same account. **"Sign out"** calls
`Disconnect-MgGraph` (deletes that stored sign-in and the token cache) and discards all loaded data; the next
"Connect" lets you pick another account. Other applications using the Windows account stay signed in
(no `-SignOutFromBroker`).

## Start

```powershell
Unblock-File .\Manage-GroupAppAssignment.ps1
.\Manage-GroupAppAssignment.ps1                                # pick the target in the window
.\Manage-GroupAppAssignment.ps1 -GroupId <object id>           # this group directly
.\Manage-GroupAppAssignment.ps1 -GroupId AllUsers              # or AllDevices
.\Manage-GroupAppAssignment.ps1 -Platform All                  # all platforms instead of iOS
```

or double-click `Start-GroupAppAssignment.bat` (parameters are passed on).

| Parameter | Default | Meaning | In the window |
|---|---|---|---|
| `-GroupId` | – | group object ID, `AllUsers` or `AllDevices` | `...` button |
| `-TenantId` | – | tenant for `Connect-MgGraph` | – (sign-in dialog) |
| `-Platform` | `iOS` | `iOS` \| `macOS` \| `Android` \| `Windows` \| `All` | "Platform" list |
| `-VppDeviceLicensing` | `$true` | license type of **new** VPP assignments (`iosVppApp`, `macOsVppApp`): device / user | checkbox "New VPP: device license" |
| `-LoadFilterNames` | off | show the names of assignment filters instead of their IDs (permission see above); if the box is ticked after connecting, the tool connects again | checkbox "Load filter names" |
| `-Language` | `auto` | `auto` \| `de` \| `en` | – |

## Behaviour in detail

- **One-by-one writes:** new `POST …/assignments`, remove `DELETE …/assignments/{id}`.
  **Changing mode/exclusion:** `DELETE` + `POST` (a target can be assigned only once per object).
  Filter and settings (for example Win32 notifications, VPP license type; `apply`/`remove` of configuration
  profiles) of the old assignment are kept as long as it stays an inclusion; an exclusion has neither. If the
  `POST` fails, the old assignment is restored – and reported if that fails too.
- **Policy sets:** assignments with `source = policySets` are shown grey and read-only ("policy set"); the
  tool neither changes nor deletes them and does not send them back in a complete list. If a target has a
  direct and a policy-set assignment, the direct one is shown.
- **Rejected up front:** exclusion for All users/All devices, "Available" to All devices, app protection and
  MAM app configuration to All devices (they apply to users only; whether a *group* holds users or devices is
  checked by Intune when saving). Everything else is checked by Intune itself (for example "Available" to a
  device group) – Graph's error message is shown per object.
- **New app exclusions** get the mode "Required"; changeable in the grid.
- **Load** reloads the apps and every category opened before.
- Unsaved changes: the tool asks before closing, reloading and changing the group.

## Limits / assumptions

- Only the **direct** assignment to the group counts. Nested groups (the group is a member of an assigned
  group) are **not** resolved.
- `$expand=assignments` on the lists is not among the documented query options; if the expansion is missing
  from the answer, the tool reads the assignments object by object (slower, but correct).
- **Settings catalog:** `/assign` (complete list, as the portal does) – confirmed live.
- **Complete list without policy-set entries:** that `/assign` leaves assignments coming from policy sets
  alone when they are not sent along is an assumption (the documentation says nothing about it).
- **Policy sets:** Intune accepts exclusions – confirmed live.
- Paths, assignment types, `intent` values, target types, `source` and `useDeviceLicensing` were checked
  against the Graph beta documentation (source: `microsoftgraph/microsoft-graph-docs-contrib`) and – where it
  is wrong – corrected after the live test. The Graph logic (loading, writing one by one and as a complete
  list, reading back) ran live against a test tenant; the WinForms window itself did not run during
  development (no Windows).

## Tests

```powershell
.\Test-GroupAppAssignment.ps1     # exit code 0 = all passed; no Graph, no GUI, no Pester
```

Checks:
- **static:** UTF-8 BOM of every `.ps1`, parses, no PS 7-only operators (`??`, `?.`, `?:`, `&&`, `||`),
  `AddRange(@(...))` only on `.Controls`;
- **logic:** category table complete (paths, write mode, assignment type, mode only for apps), platform
  detection, requested Graph permissions, target matching incl. policy-set precedence, request bodies
  (inclusion/exclusion, VPP license, keeping filter/settings, `apply`/`remove`), target rules, plan, sorting;
- **Graph with a mocked `Invoke-MgGraphRequest`:** loading with and without `$expand`, paging, reading back
  (0/1/2 assignments), writing one by one (`DELETE` + `POST`, restore on error) and as a complete list (read
  fresh, other targets keep their filter, policy-set entries not sent);
- **MAM:** stable reads, retry on `ConditionNotMet`, waiting when reading back, last sent list instead of a
  stale read;
- **window, without running it:** every visible text comes from the de/en tables (both complete, no
  hard-coded text), language choice, one 48 px icon per category, no function name collides with a command
  or alias of `Microsoft.Graph.Authentication`, sign-out calls `Disconnect-MgGraph`.

The script loads only the GUI-free part of `Manage-GroupAppAssignment.ps1` up to the marker line
`# ---- end of the GUI-free part`.

All `.ps1` files are UTF-8 with BOM, CRLF via `.gitattributes` in the repository root.

## Outlook: a cross-platform window (idea, not implemented)

The window is WinForms and therefore runs on Windows only. Everything above the marker line is free of
WinForms and already ran under PowerShell 7 on Linux, live against a tenant.

**Proposal:** a local web page instead of WinForms.
- The script starts a small HTTP server on `127.0.0.1` only, on a random port, and opens the browser.
  That works on Windows, macOS and Linux.
- The page has the same layout as now and calls a few JSON endpoints that use the existing functions
  directly. The Intune logic stays in PowerShell; none of it is rebuilt in JavaScript.
- Sign-in stays `Connect-MgGraph`, without a desktop browser via device code. The Graph token stays in the
  PowerShell process.
- Protection: a one-time token in the start URL; requests without it or from another origin are rejected.
- For Windows PowerShell 5.1 without admin rights use a plain TCP listener instead of `HttpListener`.
  Whether `HttpListener` runs on 5.1 without a URL reservation is unchecked.
- Move the core into a shared file used by both the WinForms and the web window, so there is only one
  write path. Keep WinForms until the web window has proven itself.

**Why:** besides the platform question, a web page can be clicked through automatically with Playwright,
against a mocked Graph or live. The runtime errors so far (`Columns.AddRange` on 5.1, `@()` on
`List[object]`, the `Connect-Graph` alias) were exactly in the window that could not be tested
automatically.

**Rejected:** Avalonia for PowerShell (binding too immature), a console window with Terminal.Gui (too narrow
for four lists with a grid), a pure browser app with MSAL.js (needs its own app registration, and the logic
would have to be rewritten in JavaScript without the existing tests).
