# Intune Tools

Werkzeuge für Microsoft Intune, ein Ordner pro Tool. Windows PowerShell 5.1, Microsoft Graph.

| Tool | Was es macht |
| --- | --- |
| [**GroupAppAssignment**](GroupAppAssignment/README.md) | Intune-Zuweisungen aus Sicht einer Gruppe (oder Alle Benutzer / Alle Geräte): Apps, Konfigurationsprofile (Vorlagen und Einstellungskatalog), Compliance, App-Konfiguration – was in welchem Modus zugewiesen ist, dazu hinzufügen, ändern, entfernen. Plattform-Filter (Standard iOS). |

## Repository-Konventionen

Alle `.ps1` sind UTF-8 mit BOM (sonst zerlegt PowerShell 5.1 die Umlaute) und laufen unter
Windows PowerShell 5.1. Zeilenenden: CRLF über `.gitattributes`.

Autor: Alexander Zarenko IT Consulting (AZITC).

## Lizenz

MIT – siehe `LICENSE`.
