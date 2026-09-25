# Intune Tools

Tools for Microsoft Intune, one folder per tool. Windows PowerShell 5.1, Microsoft Graph.

| Tool | What it does |
| --- | --- |
| [**GroupAppAssignment**](GroupAppAssignment/README.md) | Intune assignments seen from a group (or All users / All devices): apps, configuration profiles (templates and settings catalog), compliance, app configuration, app protection, policy sets – what is assigned in which mode, plus adding, changing and removing assignments. Platform filter (default iOS). |
| [**IntuneWin32Helper**](IntuneWin32Helper/README.md) | Create and deploy Intune Win32 apps with PSADT: packages the source, builds detection and requirement rules, uploads to Intune and updates existing apps. WinGet apps supported; the target tenant is picked once per run across several apps. |

## Repository conventions

All `.ps1` files are UTF-8 with BOM (otherwise Windows PowerShell 5.1 mangles non-ASCII characters) and run
on Windows PowerShell 5.1. Line endings: CRLF via `.gitattributes`.

Author: Alexander Zarenko IT Consulting (AZITC).

## License

MIT – see `LICENSE`.
