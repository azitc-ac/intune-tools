# Intune Tools

Werkzeuge für Microsoft Intune, ein Ordner pro Tool. Windows PowerShell 5.1, Microsoft Graph.

| Tool | Was es macht |
| --- | --- |
| [**GroupAppAssignment**](GroupAppAssignment/README.md) | App-Zuweisungen aus Sicht einer Gruppe (oder Alle Benutzer / Alle Geräte): welche Apps in welchem Modus zugewiesen sind, dazu hinzufügen, Modus ändern, entfernen. Gegenstück zu app-zentrierten Bulk-Tools. |

## Repository-Konventionen

Alle `.ps1` sind UTF-8 mit BOM (sonst zerlegt PowerShell 5.1 die Umlaute) und laufen unter
Windows PowerShell 5.1. Zeilenenden: CRLF über `.gitattributes`.

Autor: Alexander Zarenko IT Consulting (AZITC).
