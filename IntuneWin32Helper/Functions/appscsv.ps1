# ============================================================================
#  Apps.csv: die Definitionen lesen, pruefen, schreiben (Save-AppsCsv ist der einzige Schreiber).
# ============================================================================

function Get-AppsCsvColumns {
    <#
        Die Spalten von Apps.csv: die bekannten in fester Reihenfolge, danach
        alles, was Zeilen sonst noch mitbringen (eine eigene Spalte darf beim
        Speichern nicht verschwinden). EINE Quelle fuer Lesen, Bearbeiten und
        Speichern - der Bearbeitungsdialog zeigt genau diese Spalten.
    #>
    [CmdletBinding()]
    param($Definitions = @())

    # Aufgegebene Spalten: aeltere Apps.csv tragen sie noch. Sie werden nicht mehr als eigene Spalte
    # behandelt, sondern fallen beim naechsten Speichern weg (PackageName las kein Code - der Paketname
    # kommt aus DisplayName).
    $retired = @('PackageName')
    $columns = New-Object System.Collections.ArrayList
    foreach ($name in @('ProgramID', 'Publisher', 'DisplayName', 'Version', 'WinGetParams', 'SingleMSI',
                        'InstallCmd', 'UninstallCmd', 'logoURL', 'Architecture', 'MinimumOS', 'MsiProductCode', 'Interactive', 'ArpName')) {
        $null = $columns.Add($name)
    }
    foreach ($definition in @($Definitions)) {
        if ($null -eq $definition) { continue }
        foreach ($name in $definition.PSObject.Properties.Name) {
            if ($name -ne '__InternalId' -and $retired -notcontains $name -and ($columns -notcontains $name)) { $null = $columns.Add($name) }
        }
    }
    return @($columns)
}

function Get-AppsCsvPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RootDir)
    return (Join-Path $RootDir 'Apps.csv')
}

function Read-AppsCsv {
    <# Einziger Lesepfad fuer Apps.csv. Fehlt die Datei, gibt es keine Definitionen. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RootDir)

    $path = Get-AppsCsvPath -RootDir $RootDir
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Import-Csv -LiteralPath $path -Delimiter ';')
}

function Save-AppsCsv {
    <#
        Einziger Schreibpfad fuer Apps.csv. Sortiert nach Name und Version,
        schreibt alle Spalten (auch eigene) und behaelt das Format bei:
        Semikolon, alles in Anfuehrungszeichen, UTF-8 mit BOM.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RootDir,
        [AllowEmptyCollection()]$Rows = @()
    )

    $path    = Get-AppsCsvPath -RootDir $RootDir
    $columns = @(Get-AppsCsvColumns -Definitions $Rows)

    # Stabil sortieren: Sort-Object ist unter 5.1 nicht stabil, und ein zweiter Sortierschluessel
    # (Version) vertauschte Zeilen gleichen Namens bei jedem Speichern - die Datei zeigte
    # Aenderungen, die keine sind. Gleiche Namen behalten ihre Reihenfolge.
    $position = 0
    $ordered = @(@($Rows) | ForEach-Object { [pscustomobject]@{ Row = $_; Position = $position++ } } | Sort-Object { [string]$_.Row.DisplayName }, Position | ForEach-Object {
        $row = $_.Row
        $copy = [ordered]@{}
        foreach ($column in $columns) { $copy[$column] = [string]$row.$column }
        [pscustomobject]$copy
    })

    if ($ordered.Count -gt 0) {
        $ordered | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    }
    else {
        # Export-Csv schreibt ohne Zeilen auch keine Kopfzeile - dann waere die Datei leer.
        ('"' + ($columns -join '";"') + '"') | Set-Content -LiteralPath $path -Encoding UTF8
    }
}

function Test-AppRecord {
    <# Liefert den Grund, warum ein Datensatz so nicht gespeichert werden soll, sonst $null. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Record,
        $Others = @()
    )

    $name    = ([string]$Record.DisplayName).Trim()
    $version = ([string]$Record.Version).Trim()
    if (-not $name)    { return 'DisplayName is empty - the application name and the package folder come from it.' }
    if (-not $version) { return 'Version is empty - use LatestAvailable for a WinGet app.' }

    $clash = @(@($Others) | Where-Object { ([string]$_.DisplayName).Trim() -eq $name -and ([string]$_.Version).Trim() -eq $version })
    if ($clash.Count -gt 0) {
        return ("'{0} - {1}' already exists. Name and version make the package folder name and must be unique." -f $name, $version)
    }
    return $null
}

function Edit-AppRecord {
    <#
        Oeffnet den Bearbeitungsdialog fuer einen Datensatz (oder einen leeren) und
        gibt das Ergebnis als Objekt zurueck - $null bei Abbruch.
    #>
    [CmdletBinding()]
    param(
        $Record,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string[]]$ColumnOrder,
        [System.Collections.IDictionary]$Info,
        $Others = @()
    )

    $hash = @{}
    foreach ($column in $ColumnOrder) {
        if ($Record) { $hash[$column] = [string]$Record.$column } else { $hash[$column] = '' }
    }

    $edited = Open-EditDialog -item $hash -title $Title -PropertyOrder $ColumnOrder -Info $Info -Others $Others
    $edited = @($edited | Where-Object { $_ -is [System.Collections.IDictionary] }) | Select-Object -First 1
    if (-not $edited) { return $null }

    $result = [ordered]@{}
    foreach ($column in $ColumnOrder) { $result[$column] = [string]$edited[$column] }
    return [pscustomobject]$result
}
