<#
    IntuneWin32Helper - der offizielle winget-Index

    Der winget-Client durchsucht GitHub nicht. Er laedt einen fertigen Index vom CDN von
    Microsoft - source.msix, ein Paket mit einer SQLite-Datenbank, die jede Paket-Id, jeden
    Namen, Moniker, jede Version und jeden Herausgeber des Community-Repositorys enthaelt -
    und durchsucht den. Diese Datei macht dasselbe (Muster aus SCCMAppHelper, wingetindex.ps1).

        https://cdn.winget.microsoft.com/cache/source.msix
            -> Public\index.db  (SQLite)
            -> Config\winget-index\index.db, einmal am Tag erneuert

    Die Suche ist damit eine lokale Abfrage und antwortet sofort; sie haengt weder vom Modul
    Microsoft.WinGet.Client noch vom Netz ab, sobald der Index einmal da ist. Das Modul bleibt
    als Rueckfall, wenn der Index nicht zu holen oder zu lesen ist.

    SQLite wird ueber winsqlite3.dll gelesen, die jedes Windows seit 10 / Server 2016 in System32
    mitbringt: nichts zu installieren, keine Binaerdatei im Repository. Benutzt werden nur ein paar
    Einstiegspunkte der sqlite3_*-C-API, per P/Invoke aus einem kleinen C#-Helfer.

    Dazu die kuratierte Liste Config\catalog.json: die Titelseite des Suchdialogs. Was man auf dem
    harten Weg gefunden hat, kann man mit "Remember" dort eintragen.
#>

$script:WinGetIndexUrl    = 'https://cdn.winget.microsoft.com/cache/source.msix'
$script:WinGetIndexEntry  = 'Public/index.db'
$script:WinGetIndexMaxAge = [TimeSpan]::FromHours(24)
$script:WinGetUserAgent   = 'IntuneWin32Helper'
$script:WinGetSqlite      = $null   # der Helfertyp, sobald uebersetzt

#region ------------------------------------------------------------- sqlite

function Initialize-WinGetSqlite {
    if ($script:WinGetSqlite) { return $script:WinGetSqlite }

    $dll = Join-Path $env:SystemRoot 'System32\winsqlite3.dll'
    if (-not (Test-Path -LiteralPath $dll)) {
        throw "winsqlite3.dll is not on this machine ($dll) - it ships with Windows 10 / Server 2016 and later."
    }

    $source = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class IW32HWinGetSqlite
{
    const string Lib = "winsqlite3.dll";
    const int SQLITE_OK = 0, SQLITE_ROW = 100, SQLITE_DONE = 101, SQLITE_OPEN_READONLY = 1;

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_close(IntPtr db);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int nByte, out IntPtr stmt, out IntPtr tail);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_step(IntPtr stmt);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_finalize(IntPtr stmt);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_column_count(IntPtr stmt);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr sqlite3_column_text(IntPtr stmt, int col);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_column_bytes(IntPtr stmt, int col);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr sqlite3_errmsg(IntPtr db);

    static byte[] Utf8(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }

    static string ReadUtf8(IntPtr p)
    {
        if (p == IntPtr.Zero) return "";
        int len = 0;
        while (Marshal.ReadByte(p, len) != 0) len++;
        byte[] buffer = new byte[len];
        Marshal.Copy(p, buffer, 0, len);
        return Encoding.UTF8.GetString(buffer);
    }

    // Jede Zeile als Array von Zeichenketten in Spaltenreihenfolge; NULL kommt als "" zurueck.
    public static List<string[]> Query(string path, string sql)
    {
        IntPtr db;
        int rc = sqlite3_open_v2(Utf8(path), out db, SQLITE_OPEN_READONLY, IntPtr.Zero);
        if (rc != SQLITE_OK) { string m = ReadUtf8(sqlite3_errmsg(db)); sqlite3_close(db); throw new Exception("sqlite open failed (" + rc + "): " + m); }

        var rows = new List<string[]>();
        try
        {
            IntPtr stmt, tail;
            rc = sqlite3_prepare_v2(db, Utf8(sql), -1, out stmt, out tail);
            if (rc != SQLITE_OK) throw new Exception("sqlite prepare failed (" + rc + "): " + ReadUtf8(sqlite3_errmsg(db)));
            try
            {
                int columns = sqlite3_column_count(stmt);
                while ((rc = sqlite3_step(stmt)) == SQLITE_ROW)
                {
                    var row = new string[columns];
                    for (int i = 0; i < columns; i++)
                    {
                        IntPtr p = sqlite3_column_text(stmt, i);
                        int len = sqlite3_column_bytes(stmt, i);
                        if (p == IntPtr.Zero || len <= 0) { row[i] = ""; continue; }
                        byte[] buffer = new byte[len];
                        Marshal.Copy(p, buffer, 0, len);
                        row[i] = Encoding.UTF8.GetString(buffer);
                    }
                    rows.Add(row);
                }
                if (rc != SQLITE_DONE) throw new Exception("sqlite step failed (" + rc + "): " + ReadUtf8(sqlite3_errmsg(db)));
            }
            finally { sqlite3_finalize(stmt); }
        }
        finally { sqlite3_close(db); }
        return rows;
    }
}
'@

    if (-not ('IW32HWinGetSqlite' -as [type])) { Add-Type -TypeDefinition $source -ErrorAction Stop }
    $script:WinGetSqlite = [IW32HWinGetSqlite]
    return $script:WinGetSqlite
}

function Invoke-WinGetIndexQuery {
    param(
        [Parameter(Mandatory = $true)][string]$Sql,
        [string]$Path = (Get-WinGetIndexPath)
    )

    $sqlite = Initialize-WinGetSqlite
    # Jede Zeile einzeln und mit Komma ausgeben: ohne es entpackt die Pipeline eine Zeile in ihre Spalten,
    # und aus einem Ergebnis mit genau einer Zeile (COUNT(*)) wuerde das erste Zeichen der Zahl.
    # Aufrufer fassen das Ergebnis mit @(...) zusammen.
    foreach ($row in $sqlite::Query($Path, $Sql)) { , $row }
}

# Ein Wert auf dem Weg in eine LIKE-Klausel - maskiert werden muss nur das Anfuehrungszeichen;
# % und _ bleiben dem Benutzer, der sie vielleicht meint.
function ConvertTo-WinGetSqlLiteral {
    param([string]$Value)
    return "'" + ([string]$Value -replace "'", "''") + "'"
}

#endregion

#region ------------------------------------------------------------ versionen

<#
    Neueste zuerst. Eine Version, die nicht als [version] lesbar ist ("19c" und aehnliches), wird
    als Text hinter die lesbaren sortiert: sie bleibt erreichbar, ohne vergleichbar zu tun.
#>
function Sort-WinGetVersion {
    param([string[]]$Version)

    $parsed = foreach ($item in $Version) {
        $value = $null
        [pscustomobject]@{
            Text   = $item
            Parsed = $(if ([System.Version]::TryParse($item, [ref]$value)) { $value } else { $null })
        }
    }

    return @(
        @($parsed | Where-Object { $_.Parsed } | Sort-Object Parsed -Descending | Select-Object -ExpandProperty Text)
        @($parsed | Where-Object { -not $_.Parsed } | Sort-Object Text -Descending | Select-Object -ExpandProperty Text)
    )
}

#endregion

#region ----------------------------------------------------------- der index

function Get-WinGetIndexFolder { return (Join-Path $rootDir 'Config\winget-index') }
function Get-WinGetIndexPath   { return (Join-Path (Get-WinGetIndexFolder) 'index.db') }

<#
    Was von der lokalen Kopie bekannt ist: wann sie geholt wurde und wie viele Pakete sie hat.
    Nichts, wenn es keine gibt.
#>
function Get-WinGetIndexInfo {
    $path = Get-WinGetIndexPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }

    $stamp = Join-Path (Get-WinGetIndexFolder) 'index.json'
    $info = [pscustomobject]@{ Path = $path; Downloaded = (Get-Item -LiteralPath $path).LastWriteTime; Packages = 0; Schema = '' }
    if (Test-Path -LiteralPath $stamp) {
        try {
            $saved = Get-Content -LiteralPath $stamp -Raw | ConvertFrom-Json
            if ($saved.downloaded) { $info.Downloaded = [datetime]$saved.downloaded }
            if ($saved.packages)   { $info.Packages   = [int]$saved.packages }
            if ($saved.schema)     { $info.Schema     = [string]$saved.schema }
        }
        catch { }
    }
    return $info
}

<#
    Holt source.msix vom CDN. Eigene Funktion, damit ein Test den Abruf ersetzen kann, ohne das
    Netz zu brauchen. Windows PowerShell 5.1 verhandelt TLS 1.0 zuerst; das muss vor der ersten
    Anfrage auf 1.2 angehoben werden. -UseBasicParsing, weil Invoke-WebRequest sonst die
    Internet-Explorer-Engine will.
#>
function Save-WinGetIndexSource {
    param([Parameter(Mandatory = $true)][string]$Destination)

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $progress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $script:WinGetIndexUrl -OutFile $Destination -UseBasicParsing -ErrorAction Stop `
            -Headers @{ 'User-Agent' = $script:WinGetUserAgent }
    }
    finally { $ProgressPreference = $progress }
}

<#
    Holt source.msix und nimmt index.db heraus. Die msix ist ein zip; die Datenbank liegt unter
    Public\index.db. Nichts daraus wird ausgefuehrt - es sind nur Daten.
#>
function Update-WinGetIndex {
    $folder = Get-WinGetIndexFolder
    if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }

    $msix = Join-Path $folder 'source.msix'
    Write-Host "Downloading the winget index from $script:WinGetIndexUrl"
    Save-WinGetIndexSource -Destination $msix
    Write-Host ("Downloaded source.msix ({0:n1} MB)" -f ((Get-Item -LiteralPath $msix).Length / 1MB))

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $target = Get-WinGetIndexPath
    $fresh  = "$target.new"
    $zip = [System.IO.Compression.ZipFile]::OpenRead($msix)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq $script:WinGetIndexEntry -or $_.FullName -eq ($script:WinGetIndexEntry -replace '/', '\') } | Select-Object -First 1
        if (-not $entry) { throw "source.msix holds no $script:WinGetIndexEntry - the index format may have changed." }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $fresh, $true)
    }
    finally { $zip.Dispose() }
    Remove-Item -LiteralPath $msix -Force -ErrorAction SilentlyContinue

    # Einmal lesen, bevor sie die alte ersetzt: ein kaputter Download nimmt keinen funktionierenden Index mit.
    $count  = 0
    $schema = ''
    try {
        $count = [int]@(Invoke-WinGetIndexQuery -Path $fresh -Sql 'SELECT COUNT(*) FROM ids')[0][0]
        $meta  = @(Invoke-WinGetIndexQuery -Path $fresh -Sql "SELECT name, value FROM metadata WHERE name IN ('majorVersion', 'minorVersion')")
        $schema = (($meta | Sort-Object { $_[0] } | ForEach-Object { $_[1] }) -join '.')   # majorVersion vor minorVersion
    }
    catch {
        Remove-Item -LiteralPath $fresh -Force -ErrorAction SilentlyContinue
        throw ("The downloaded index could not be read: {0}" -f $_.Exception.Message)
    }
    Move-Item -LiteralPath $fresh -Destination $target -Force

    [pscustomobject]@{ downloaded = (Get-Date).ToString('o'); packages = $count; schema = $schema; source = $script:WinGetIndexUrl } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $folder 'index.json') -Encoding UTF8

    Write-Host ("winget index ready: {0} packages, schema {1}" -f $count, $schema)
    return (Get-WinGetIndexInfo)
}

<#
    Der Index, geholt oder erneuert, wenn er fehlt oder aelter als einen Tag ist. Laesst sich ein
    vorhandener nicht erneuern, bleibt er in Gebrauch (mit Warnung); gibt es keinen, wird geworfen,
    und der Aufrufer faellt auf das Modul zurueck.
#>
function Get-WinGetIndex {
    param([switch]$Force)

    $info = Get-WinGetIndexInfo
    $stale = (-not $info) -or $Force -or ((Get-Date) - $info.Downloaded) -gt $script:WinGetIndexMaxAge

    if ($stale) {
        try { $info = Update-WinGetIndex }
        catch {
            if ($info) { Write-Warning ("The winget index could not be refreshed - using the copy from {0:yyyy-MM-dd HH:mm}: {1}" -f $info.Downloaded, $_.Exception.Message) }
            else       { throw }
        }
    }
    return $info
}

function Test-WinGetIndexTable {
    param([Parameter(Mandatory = $true)][string]$Name)
    $rows = @(Invoke-WinGetIndexQuery -Sql ("SELECT name FROM sqlite_master WHERE type = 'table' AND name = {0}" -f (ConvertTo-WinGetSqlLiteral $Name)))
    return ($rows.Count -gt 0)
}

<#
    Sucht den Index nach Paket-Id, Name, Moniker und Herausgeber.

    Das Schema ist das des Clients: eine Zeile je Manifest in "manifest", die per rowid auf die
    Tabellen ids, names, monikers und versions zeigt; der normalisierte Herausgeber ("igorpavlov")
    haengt in neueren Schemata an einer Zuordnungstabelle und wird benutzt, wenn es sie gibt.
    Ergebnis: ein Eintrag je Paket mit seinen Versionen, neueste zuerst.
#>
function Search-WinGetIndex {
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [int]$Limit = 300
    )

    $null = Get-WinGetIndex

    $needle = $Query.Trim()
    if ($needle.Length -lt 2) { throw 'Please search for at least two characters.' }
    $like = ConvertTo-WinGetSqlLiteral ('%' + $needle + '%')
    $normalised = ConvertTo-WinGetSqlLiteral ('%' + (($needle.ToLowerInvariant() -replace '[^a-z0-9]', '')) + '%')

    $where = @(
        "ids.id LIKE $like",
        "names.name LIKE $like",
        "monikers.moniker LIKE $like"
    )
    if (Test-WinGetIndexTable -Name 'norm_publishers_map') {
        $where += "manifest.rowid IN (SELECT m.manifest FROM norm_publishers_map m JOIN norm_publishers p ON p.rowid = m.norm_publisher WHERE p.norm_publisher LIKE $normalised)"
    }

    $sql = @"
SELECT ids.id, names.name, versions.version
FROM manifest
JOIN ids ON ids.rowid = manifest.id
JOIN names ON names.rowid = manifest.name
JOIN versions ON versions.rowid = manifest.version
LEFT JOIN monikers ON monikers.rowid = manifest.moniker
WHERE $($where -join ' OR ')
"@

    $rows = @(Invoke-WinGetIndexQuery -Sql $sql)

    $byId = [ordered]@{}
    foreach ($row in $rows) {
        $id = $row[0]
        if (-not $byId.Contains($id)) { $byId[$id] = [pscustomobject]@{ Name = $row[1]; Id = $id; Versions = @() } }
        $byId[$id].Versions += $row[2]
    }

    $results = @()
    foreach ($entry in $byId.Values) {
        $sorted = @(Sort-WinGetVersion -Version $entry.Versions)
        $results += [pscustomobject]@{
            Name     = $entry.Name
            Id       = $entry.Id
            Version  = $sorted[0]
            Versions = $sorted
        }
    }

    # Treffer, die den Namen oder die Id genau treffen, zuerst; dann solche, die damit beginnen; der Rest nach Name.
    $lower = $needle.ToLowerInvariant()
    $results = @($results | Sort-Object `
        @{ Expression = { if ($_.Name.ToLowerInvariant() -eq $lower -or $_.Id.ToLowerInvariant() -eq $lower) { 0 } elseif ($_.Name.ToLowerInvariant().StartsWith($lower)) { 1 } else { 2 } } },
        @{ Expression = { $_.Name } })
    if ($results.Count -gt $Limit) { $results = @($results | Select-Object -First $Limit) }
    return $results
}

<#
    Die Versionen eines Pakets aus dem Index, neueste zuerst - oder nichts, wenn es nicht darin steht.
#>
function Get-WinGetIndexVersion {
    param([Parameter(Mandatory = $true)][string]$PackageIdentifier)

    $null = Get-WinGetIndex
    $sql = @"
SELECT versions.version
FROM manifest
JOIN ids ON ids.rowid = manifest.id
JOIN versions ON versions.rowid = manifest.version
WHERE ids.id = $(ConvertTo-WinGetSqlLiteral $PackageIdentifier)
"@
    $versions = @(Invoke-WinGetIndexQuery -Sql $sql | ForEach-Object { $_[0] } | Where-Object { $_ })
    if ($versions.Count -eq 0) { return @() }
    return @(Sort-WinGetVersion -Version $versions)
}

# Der Satz unter der Liste: wo die Suche hinschaut und wie alt das ist.
function Get-WinGetIndexStatusText {
    $info = Get-WinGetIndexInfo
    if ($info) {
        return ('winget index: {0} packages, fetched {1:yyyy-MM-dd HH:mm}. The search looks up id, name, moniker and publisher locally; the curated list is matched first.' -f $info.Packages, $info.Downloaded)
    }
    return 'No winget index yet - the first search fetches it from cdn.winget.microsoft.com (a few dozen MB, once a day). If that fails, the winget module is asked instead.'
}

#endregion

#region ------------------------------------------------- die kuratierte liste

function Get-WinGetCatalogPath { return (Join-Path $rootDir 'Config\catalog.json') }

function Get-WinGetCatalogList {
    param([string]$Path = (Get-WinGetCatalogPath))

    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try   { return @((Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).packages) }
    catch { Write-Warning ("catalog.json could not be read: {0}" -f $_.Exception.Message); return @() }
}

<#
    Traegt ein Paket in die kuratierte Liste ein. Gibt $true zurueck, wenn es neu ist, $false, wenn
    es schon drinstand.

    Von Hand geschrieben statt mit ConvertTo-Json: die Datei ist zum Bearbeiten von Hand gedacht, und
    ConvertTo-Json maskiert jedes Apostroph und jede spitze Klammer als \uXXXX und setzt jede
    Eigenschaft in eine eigene Zeile.
#>
function Add-WinGetCatalogEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$PackageId,
        [string]$Path = (Get-WinGetCatalogPath)
    )

    $catalog = $null
    $entries = @()
    $comment = ''
    if (Test-Path -LiteralPath $Path) {
        $catalog = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $entries = @($catalog.packages)
        $comment = [string]$catalog.comment
    }
    if (@($entries | Where-Object { $_.packageId -eq $PackageId }).Count -gt 0) { return $false }

    $entries = @($entries) + [pscustomobject]@{ name = $Name; packageId = $PackageId }
    $escape  = { param([string]$s) ($s -replace '\\', '\\' -replace '"', '\"') }

    $width = 3 + ($entries | ForEach-Object { (& $escape ([string]$_.name)).Length } | Measure-Object -Maximum).Maximum
    $lines = foreach ($entry in $entries) {
        $label = ('"' + (& $escape ([string]$entry.name)) + '",').PadRight($width)
        '        { "name": ' + $label + ' "packageId": "' + (& $escape ([string]$entry.packageId)) + '" }'
    }

    $nl = [Environment]::NewLine
    $json = '{' + $nl +
            ('    "comment": "{0}",' -f (& $escape $comment)) + $nl +
            '    "packages": [' + $nl +
            ($lines -join (',' + $nl)) + $nl +
            '    ]' + $nl + '}' + $nl

    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
    return $true
}

#endregion

#region ----------------------------------------------------------------- suche

<#
    Die Suche des Dialogs: erst die kuratierte Liste (liegt schon hier, und es ist das, was man
    verteilt), dann der Index; beides zusammen, die kuratierten Treffer oben. Ohne Suchbegriff
    die kuratierte Liste. Ist der Index nicht zu haben, fragt der Rueckfall das Modul
    Microsoft.WinGet.Client - langsamer und nur online, aber die Suche bleibt moeglich.

    Jeder Treffer: Name, Id, Version, Source ('catalog' | 'index' | 'module').
#>
function Search-WinGetCatalog {
    param(
        [string]$Query,
        $Packages = (Get-WinGetCatalogList)
    )

    $needle = ([string]$Query).Trim()
    $curated = @($Packages | Where-Object { $_ } | ForEach-Object {
        [pscustomobject]@{ Name = [string]$_.name; Id = [string]$_.packageId; Version = ''; Source = 'catalog' }
    })
    if (-not $needle) { return $curated }

    $local = @($curated | Where-Object { $_.Name -like "*$needle*" -or $_.Id -like "*$needle*" })

    $found = @()
    try {
        $found = @(Search-WinGetIndex -Query $needle | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Id = $_.Id; Version = [string]$_.Version; Source = 'index' }
        })
    }
    catch {
        if ($needle.Length -lt 2) { throw }
        Write-Warning ("winget index not available, asking the winget module instead: {0}" -f $_.Exception.Message)
        $found = @(Find-WinGetPackage -Query $needle -Source 'winget' | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.Name; Id = [string]$_.Id; Version = [string]$_.Version; Source = 'module' }
        })
    }

    # Ein kuratierter Treffer bekommt die Version aus dem Index, wenn der sie kennt.
    $byId = @{}
    foreach ($f in $found) { $byId[$f.Id] = $f }
    foreach ($l in $local) { if ($byId.ContainsKey($l.Id)) { $l.Version = $byId[$l.Id].Version } }

    $known = @($local | ForEach-Object { $_.Id })
    return @($local) + @($found | Where-Object { $_.Id -notin $known })
}

#endregion
