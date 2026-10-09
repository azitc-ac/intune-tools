# IntuneWin32Helper
Quickly create and deploy Intune Win32 apps using PSADT. Supports WinGet and mutiple tenants.<br><br>
See https://blog.zarenko.net/intune-apps-verteilen-leicht-gemacht/<br><br>
<img width="726" height="443" alt="Screenshot 2025-12-09 12-42-03" src="https://github.com/user-attachments/assets/6537dcc9-3a4a-4c34-a831-f73432481e03" />


## The main window

The tool starts with the inventory - there are no start tiles and no separate "create" and "deploy"
dialogs any more. One row per app, with the state of the three things that exist per app: **on the
left** the definition and the package, **on the right** the app in the tenant. Everything is done from
that list:

```
Tenant [xyz.onmicrosoft.com v]  Show [All v]  [Filter...]                    [Refresh]
 Application | Version | Publisher | Package         |  Intune  | Next step
 (grey header: definition and package)                | (blue header: tenant)
[gear] [Open folder] [Remove orphan folder] [Retire from Intune]
                     [Add...] [New version...] [Edit] [Delete definition] [Build package] [Rebuild] [Deploy] [Close]
```

| Column | Meaning |
| --- | --- |
| `Package` | `Definition only`, `Package`, `Package, template outdated` / `unstamped`, or `No definition` (a package folder without a row in `Apps.csv`) |
| `Intune` | matched by **name and version**: `yes` is an app with this name and this version; `other version: 1.0.5` means the name exists, this version does not (a deploy creates it; the other version stays); `yes (2x)` means the same name **and** version twice (duplicates); `no content` means an entry a failed upload left behind (not published, no committed content); `not checked` when no tenant is connected |
| `Next step` | the sensible next step, derived from the row |

The tenant is chosen once at the start (not asked at all when only one is configured) and can be
switched in the window; a switch signs in again, because a token that is still valid for the
*previous* tenant would otherwise be reused. Without a tenant the tool keeps working - the Intune
column is simply empty.

The buttons follow the selected rows: a row without a definition can be deployed, but not edited,
deleted or built. **Deploy** builds a row that has no package first. **Delete definition** removes the
row from `Apps.csv` only - the package folder and the app in Intune stay. The row tooltip spells out
all three states, and the selection survives every action.

### Retire and Rebuild: deleting in Intune

Both delete **apps in Intune**, which cannot be undone, so both work the same careful way:

- The ids to delete come from a **fresh read** of the tenant - never from what the window showed -
  and only for apps with the **name and version** of the selected row. Another version of the same app
  is never touched. If a row has duplicates, all of them are named in the question and all are deleted.
- A question lists every app (id, creation date, with/without content, number of assignments) and says
  that the apps **and their assignments** are deleted. The default answer is **No**. If the tenant cannot
  be read, nothing happens and nothing is asked.
- The module's `Remove-IntuneWin32App` only *warns* when it fails (it does not throw), so "the command
  ran" does not mean "the app is gone". After deleting, the tool reads the tenant again and reports each
  app as `Removed`, `StillListed` (with the module's warning), `Failed` or `Unverified`.

**Retire from Intune** deletes the app of the selected row in Intune. The definition in `Apps.csv` and
the package folder stay, so the app can be deployed again - without its assignments.

**Rebuild** replaces an app: *build the package again from the definition -> delete the old app(s) in
Intune -> create a new one*, in exactly that order. If the build fails, Intune is not touched and the old
app keeps running. A new app is created only for a row whose old app was verified as removed; otherwise
the row is skipped, because creating it would make a duplicate. The assignments of the old app are
**not** restored; the question shows how many there are. To keep assignments, use **Deploy** and answer
*No* (replace the package content) instead.

### Deploy decides before it uploads

Earlier the generated `deploy.ps1` created a **new** app on every bulk run, even when the same app in
the same version was already in Intune - every second run made duplicates. Now the tool decides
first, on a fresh read of the tenant (the state shown in the window may be stale), and hands the
decision to `deploy.ps1` (`-Mode New|Update`, `-UpdateAppId`):

| In Intune | Plan |
| --- | --- |
| no app with this name and version | **Create** (also when only another version exists - it stays) |
| exactly one app with this name and version | **Skip** (`already in Intune`) |
| two or more | **Skip** - remove the duplicates first |
| one, but without content (failed upload) | **Skip** - remove the entry first |

A dialog shows the plan before anything happens. **Yes** deploys as planned. When apps are already
in Intune, **No** additionally *replaces the package content* of those apps (`Update`): their detection
rule, install and uninstall commands, requirements and assignments stay exactly as they are in Intune,
because `Update-IntuneWin32AppPackageFile` only changes the content version and the icon (read from
the module source, 1.5.0). Rows that are skipped are not built. If the tenant cannot be read, nothing
is deployed. Running `deploy.ps1` by hand still asks (`-Mode Ask`), as before.

Changing the template changed its fingerprint: existing packages show `Package, template outdated`
once and are renewed (with a `.bak`) on their next deploy.

**Remove orphan folder** deletes the package folder of selected rows that have **no definition** in
`Apps.csv` (status `No definition` - typically what is left after a rename or a deleted definition).
It asks first, listing every folder with its file count and size, and says that the apps in Intune
are not touched. The button is only enabled when the selection contains such a row, and the deletion
itself (`Remove-OrphanPackages`) refuses on its own anything that is not clearly an orphan: a folder
with a definition, a folder not named `<Name> - <Version>`, a folder without `deploy.ps1`, and
anything outside `packetRoot`. Use *Show: Package without definition* and select all to clean up in
one go.

**Add, New version and Edit** open one editor. The facts about the row (package folder, template,
Intune state, next step) are read-only at the top; the fields below are grouped (Application, Source,
Installation, Intune), label on the left, field on the right. `Architecture` and `MinimumOS` are lists
filled from the IntuneWin32App module, `Interactive` and `SingleMSI` are check boxes, the commands are
multi-line, and the WinGet fields are only enabled while `Version` is `LatestAvailable`. Under
`ArpName` the editor spells out the search name that detection and uninstall will use. OK checks name
and version - also against duplicates - and stays open until they are right. The package name comes
from `DisplayName`; the old `PackageName` column of `Apps.csv` is gone (it was never read) and drops out
of the file the next time the tool saves it.

### Templates stay inside the package

The generated `deploy.ps1` and `detection.ps1` stay **inside** the package on purpose: the package
is then a record of what was actually deployed, a template change cannot silently alter a package
that was already tested, and a single app can be given a special case by hand. The price is that a
template fix does not reach old packages by itself - which is exactly what the `Package` column
makes visible (`template outdated`). `Write-DeployScript` stamps every package with a short hash over the templates
(`# ToolTemplateFingerprint:`), and the inventory compares it against the current state.
`unstamped` means the package predates the stamp.

Renewing happens on deploy (`Update-DeployScript`, with `deploy.ps1.bak` and `detection.ps1.bak`
backups) and only for packages that need it - by the same stamp the inventory shows: `outdated` and
`unstamped` are renewed, `current` is left alone even if it was edited by hand. The stamp covers
all templates, so `deploy.ps1` **and** `detection.ps1` are renewed together; the search name or
WinGet id is carried over from the old `detection.ps1`.

## Configuration

`Config/config.json` holds the tenants (tenant name, app registration id, client secret)
and `packetRoot`. It is **not** version controlled, because the client secret is stored in
clear text. On first start it is created automatically from `Config/config.sample.json`;
fill it in via the gear icon in the main window or by editing the file.

App logos are resolved locally from `Logos\` and normalised to 256x256; nothing is uploaded
anywhere. A format this machine cannot read (webp without a codec, svg) falls back to
`Logos\defaultlogo.png` rather than failing the build.

## Apps.csv

Two columns beyond the obvious ones:

| Column | Empty means |
| --- | --- |
| `Architecture` | `x64` |
| `MinimumOS` | `W10_20H2` |
| `Interactive` | silent install without ServiceUI |
| `ArpName` | the `DisplayName` - the name under which the app appears in *Apps & features* |

Both go into the app's requirement rule, so an ARM64 or x86 app and an app that needs a newer
Windows no longer have to share one hard-coded rule. Values must be ones
`New-IntuneWin32AppRequirementRule` accepts.

`Interactive = true` is for the rare package that must show PSAppDeployToolkit dialogs - for
example "close the running application first". Such a package gets `ServiceUI.exe` and runs
without `-DeployMode Silent`. Everything else installs silently in session 0 and never touches the
user's desktop. The reason for that default: through ServiceUI the setup runs **as SYSTEM in the
user's session**, and a setup that starts its app when it is done (Greenshot does) leaves that app
running as SYSTEM on the user's desktop - observed in the field on 2026-09-28/29. That risk remains
for packages marked `Interactive`.

`ArpName` is the search name for both the script detection and the derived uninstall command.
Both use the **same** rule: an entry whose name *starts with* `ArpName`
(`DisplayName -like "<ArpName>*"` and `Uninstall-ADTApplication -Name '<ArpName>*' -NameMatch
'Wildcard'`). Set it when the Intune name differs from the product's entry in the program list, or
to be more precise - `Git` also matches `GitHub Desktop`, and the uninstall removes **every** match.

`Version = LatestAvailable` marks a WinGet app: the package is a thin wrapper that installs
through `winget` on the endpoint. Its detection checks **both** that the package id is present
and that no upgrade is available - otherwise an outdated version would count as current and the
app would never be renewed. When winget cannot reach its source, the app counts as current, so
an offline device does not loop through reinstalls.

## Third-party components

`ServiceUI.exe` in this folder is a Microsoft component and is **not** covered by this
repository's MIT license - see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md), which also
records that its redistribution terms have not been established.

## Checks

Before committing, run the structural checks from this folder:

```powershell
.\Tests\Invoke-RepoChecks.ps1
```

They parse every `.ps1` of this tool and fail (exit code 1) on: syntax errors, a missing
UTF-8 BOM, unsuppressed `.Add()` return values (these leak `int` indices into a dialog
result), `Out-GridView`/`ogv` usage, parameters that the called function does not declare,
`break`/`continue` outside a loop of the same function, a `deploy_template.ps1` that no
longer routes tenant selection through `Initialize-IntuneConnection`, config reads that
bypass `Get-ToolConfig` (including a missing `.gitignore` entry for `Config/config.json`),
`Start-Transcript` calls that bypass `Start-ToolTranscript`, syntax Windows PowerShell 5.1
cannot parse (`??`, `?.`, `&&`, `||`, ternary), any upload of logos to a third party, logo
handling outside `Resolve-PackageLogo`, a hard-coded requirement rule, a missing path-length
report, a WinGet detection that does not check for an upgrade, and the main window's wiring:
an old entry point (`createApps`, `deployApps`, the start tiles) coming back, a button whose
action has no branch in `Start-InventoryLoop`, a tenant switch that does not sign in again,
a second writer of `Apps.csv` besides `Save-AppsCsv`, a second place that builds packages
besides `Build-AppPackage`, a deploy that bypasses the plan (`Invoke-PackageDeploy` called without
going through `Invoke-InventoryDeploy`, `deploy.ps1` called without `-Mode` or with `-bulk`, a discarded
update result in the template), or an unguarded delete in Intune (`Remove-IntuneWin32App` outside
`Remove-TenantWin32Apps`, no read-back after deleting, no question before deleting, a question that does
not default to No, Rebuild deleting before building, the loop deleting directly).

Each check corresponds to a bug this tool already had, so re-introducing one turns the
check red.

The behaviour tests in `Tests\Test-*.ps1` run on their own and need no tenant:

| Test | What it proves |
| --- | --- |
| `Test-RetireRebuild.ps1` | only apps with the row's name **and** version from the fresh tenant are deleted (not another version, not what the window showed), the question names every app and its assignments, "No" and an unreadable tenant delete nothing, a delete that only warns is reported as `StillListed` and not as removed, Rebuild goes build -> delete -> create and never creates over a leftover |
| `Test-DeployPlan.ps1` | the plan: Intune is matched by name **and** version, Create/Skip/Update per state, duplicates and empty entries are never replaced, the decision reaches `deploy.ps1` as `-Mode`, Intune is read fresh before planning, only planned apps are built and deployed, nothing happens on cancel or an unreadable tenant |
| `Test-MainWindowModel.ps1` | the state of every inventory row, and that `Apps.csv` survives read, save and read again (values, own columns, BOM, header) |
| `Test-MainWindowUi.ps1` | operates the real main window through UI Automation: buttons follow the selected row, the selection survives, the filter narrows, a tenant switch is reported, and the real `Start-InventoryLoop` shows the window again after Refresh and ends on Close. Needs a desktop session - the window flashes briefly |
