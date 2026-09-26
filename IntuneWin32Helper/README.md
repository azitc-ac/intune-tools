# IntuneWin32Helper
Quickly create and deploy Intune Win32 apps using PSADT. Supports WinGet and mutiple tenants.<br><br>
See https://blog.zarenko.net/intune-apps-verteilen-leicht-gemacht/<br><br>
<img width="726" height="443" alt="Screenshot 2025-12-09 12-42-03" src="https://github.com/user-attachments/assets/6537dcc9-3a4a-4c34-a831-f73432481e03" />


## Inventory

"Deploy existing apps" no longer lists folders that happen to hold a `deploy.ps1`. It shows one row
per app with the state of all three things that exist per app, and you pick from that list what to
deploy:

| Column | Meaning |
| --- | --- |
| `Definition` | a row in `Apps.csv` |
| `Package` | the folder `<Name> - <Version>\` under `packetRoot`, with `deploy.ps1` |
| `Template` | `current`, `outdated` or `unstamped` - see below |
| `Intune` | present in the tenant; `yes (2x)` means duplicates |
| `Next` | the sensible next step, derived from the row |

The generated `deploy.ps1` and `detection.ps1` stay **inside** the package on purpose: the package
is then a record of what was actually deployed, a template change cannot silently alter a package
that was already tested, and a single app can be given a special case by hand. The price is that a
template fix does not reach old packages by itself - which is exactly what the `Template` column
makes visible. `Write-DeployScript` stamps every package with a short hash over the templates
(`# ToolTemplateFingerprint:`), and the inventory compares it against the current state.
`unstamped` means the package predates the stamp.

Renewing happens on deploy (`Update-DeployScript`, with a `deploy.ps1.bak` backup) and only for
packages that need it.

## Configuration

`Config/config.json` holds the tenants (tenant name, app registration id, client secret)
and `packetRoot`. It is **not** version controlled, because the client secret is stored in
clear text. On first start it is created automatically from `Config/config.sample.json`;
fill it in via the gear icon in the start dialog or by editing the file.

App logos are resolved locally from `Logos\` and normalised to 256x256; nothing is uploaded
anywhere. A format this machine cannot read (webp without a codec, svg) falls back to
`Logos\defaultlogo.png` rather than failing the build.

## Apps.csv

Two columns beyond the obvious ones:

| Column | Empty means |
| --- | --- |
| `Architecture` | `x64` |
| `MinimumOS` | `W10_20H2` |

Both go into the app's requirement rule, so an ARM64 or x86 app and an app that needs a newer
Windows no longer have to share one hard-coded rule. Values must be ones
`New-IntuneWin32AppRequirementRule` accepts.

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
report, and a WinGet detection that does not check for an upgrade.

Each check corresponds to a bug this tool already had, so re-introducing one turns the
check red.
