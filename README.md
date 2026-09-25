# Intune Tools

Tools for Microsoft Intune, one folder per tool. Windows PowerShell 5.1, Microsoft Graph.

| Tool | What it does |
| --- | --- |
| [**GroupAppAssignment**](GroupAppAssignment/README.md) | Intune assignments seen from a group (or All users / All devices): apps, configuration profiles (templates and settings catalog), compliance, app configuration, app protection, policy sets – what is assigned in which mode, plus adding, changing and removing assignments. Platform filter (default iOS). |
| [**IntuneWin32Helper**](IntuneWin32Helper/README.md) | Create and deploy Intune Win32 apps with PSADT: packages the source, builds detection and requirement rules, uploads to Intune and updates existing apps. WinGet apps supported; the target tenant is picked once per run across several apps. |

## Repository conventions

All `.ps1` files are UTF-8 with BOM (otherwise Windows PowerShell 5.1 mangles non-ASCII characters) and run
on Windows PowerShell 5.1. Line endings: CRLF via `.gitattributes`.

Each tool carries its own `VERSION` file, one line, read by the tool and shown in its window title.
The `pre-commit` hook raises its last number for every tool a commit touches, so builds can be told
apart; a `VERSION` already staged - a deliberate jump to 2.1.0 - is left alone. The hook refuses a
commit when a `VERSION` does not end in a number, or when no `.ps1` of that tool reads it - a number
nobody sees would grow forever. The same hook runs a tool's `Tests/Invoke-RepoChecks.ps1` if it has
one and refuses the commit when a check fails.

Activate the hooks once per clone:

```bash
git config core.hooksPath .githooks
```

Without PowerShell on the machine (a Linux clone, say) the hook cannot run the checks. It says so
loudly rather than passing silently.

Author: Alexander Zarenko IT Consulting (AZITC).

## License

MIT – see `LICENSE`.
