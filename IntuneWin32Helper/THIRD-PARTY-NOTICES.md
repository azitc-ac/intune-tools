# Third-party notices

## ServiceUI.exe

`ServiceUI.exe` in this folder is a **Microsoft** component, not part of this tool. The install and
uninstall command lines of every generated package call it so that PSAppDeployToolkit can show its
dialogs in the logged-on user's session while the Intune Management Extension runs as SYSTEM.

Read from the file's own version resource:

| Field | Value |
| --- | --- |
| CompanyName | Microsoft Corporation |
| ProductName / FileDescription | ServiceUI Application |
| FileVersion / ProductVersion | 1, 3, 0, 0 |
| OriginalFilename | ServiceUI.exe |
| LegalCopyright | Microsoft Corporation. All rights reserved. |
| SHA256 | `1be85a64aad2c3caa0dc28705b49a1548e85157f4d2d522c20fec4b4570a623f` |

The file ships with the **Microsoft Deployment Toolkit (MDT)**, under
`Templates\Distribution\Tools\<architecture>\ServiceUI.exe` of an MDT installation.

**The MIT license of this repository does not cover it.** Microsoft's license terms for MDT apply,
and whether they permit redistributing the binary in a public repository has **not** been
established here. Until that is confirmed, treat this copy as unverified with regard to
redistribution. The alternative that avoids the question entirely: remove the file from the
repository and have each installation copy it out of its own local MDT, since anyone running the
tool needs an MDT-licensed environment anyway.

## PSAppDeployToolkit

The generated packages are built with [PSAppDeployToolkit](https://psappdeploytoolkit.com/)
(`New-ADTTemplate`). It is not redistributed here; the tool installs the `PSAppDeployToolkit`
module from the PowerShell Gallery at first run (`check-prereqs`).

## IntuneWin32App

Upload and management of the Win32 apps use the
[IntuneWin32App](https://github.com/MSEndpointMgr/IntuneWin32App) module, likewise installed from
the PowerShell Gallery rather than redistributed.
