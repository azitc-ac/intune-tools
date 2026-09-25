# IntuneWin32Helper
Quickly create and deploy Intune Win32 apps using PSADT. Supports WinGet and mutiple tenants.<br><br>
See https://blog.zarenko.net/intune-apps-verteilen-leicht-gemacht/<br><br>
<img width="726" height="443" alt="Screenshot 2025-12-09 12-42-03" src="https://github.com/user-attachments/assets/6537dcc9-3a4a-4c34-a831-f73432481e03" />


## Configuration

`Config/config.json` holds the tenants (tenant name, app registration id, client secret)
and `packetRoot`. It is **not** version controlled, because the client secret is stored in
clear text. On first start it is created automatically from `Config/config.sample.json`;
fill it in via the gear icon in the start dialog or by editing the file.

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
and `Start-Transcript` calls that bypass `Start-ToolTranscript`.

Each check corresponds to a bug this tool already had, so re-introducing one turns the
check red.
