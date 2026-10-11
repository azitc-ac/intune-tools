<#
    .SYNOPSIS
    Verhaltenstest: der lokale winget-Index und die Suche darueber (Functions\wingetindex.ps1).

    .DESCRIPTION
    Ohne Netz. Eine kleine echte SQLite-Datenbank mit dem Schema des winget-Index (ids, names,
    monikers, versions, manifest, norm_publishers[_map], metadata) wird in eine msix gepackt; der
    Abruf (Save-WinGetIndexSource) liefert diese msix. Geprueft wird:

      1. Update-WinGetIndex nimmt index.db aus der msix, zaehlt die Pakete RICHTIG (ein Ergebnis aus
         genau einer Zeile darf nicht in seine Spalten zerfallen: COUNT(*)=4 war einmal '4' -> 52),
         liest die Schemaversion in der richtigen Reihenfolge (major.minor) und schreibt index.json.
      2. Ein kaputter Download (keine index.db in der msix, keine Datenbank) laesst den vorhandenen
         Index unberuehrt.
      3. Get-WinGetIndex holt nur, wenn der Index fehlt oder aelter als einen Tag ist; schlaegt die
         Erneuerung fehl, bleibt der alte in Gebrauch (Warnung); ohne Index wird geworfen.
      4. Search-WinGetIndex findet nach Id, Name, Moniker und Herausgeber, auch mit genau einem Treffer,
         kommt mit einem Apostroph im Suchbegriff klar, verlangt zwei Zeichen, sortiert genaue Treffer
         zuerst und die Versionen eines Pakets neueste zuerst ("0.10" vor "0.9", "19c" hinten).
      5. Search-WinGetCatalog: ohne Begriff die kuratierte Liste; mit Begriff kuratierte Treffer oben
         (mit Version aus dem Index), dann der Index ohne Dubletten; ohne Index und ohne Netz faellt
         die Suche auf das Modul zurueck (Source 'module').
      6. Add-WinGetCatalogEntry: neu -> $true, vorhanden -> $false, Anfuehrungszeichen und Backslash
         bleiben erhalten, die Datei bleibt gueltiges JSON, die anderen Eintraege bleiben.
#>
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$problems = @()
function Test-That([bool]$condition, [string]$what) { if (-not $condition) { $script:problems += $what } }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('iw32h-wgidx-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path (Join-Path $work 'Config')
$rootDir = $work

. (Join-Path $repoRoot 'Functions\wingetindex.ps1')

# --- eine echte, kleine Datenbank bauen (lesen kann der Helfer nur) ---
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class IW32HFakeIndexWriter
{
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_open_v2(byte[] f, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_exec(IntPtr db, byte[] sql, IntPtr cb, IntPtr arg, out IntPtr err);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_close(IntPtr db);
    public static void Run(string path, string sql)
    {
        IntPtr db, err;
        if (sqlite3_open_v2(Encoding.UTF8.GetBytes(path + "\0"), out db, 6, IntPtr.Zero) != 0) throw new Exception("open");
        int rc = sqlite3_exec(db, Encoding.UTF8.GetBytes(sql + "\0"), IntPtr.Zero, IntPtr.Zero, out err);
        sqlite3_close(db);
        if (rc != 0) throw new Exception("exec " + rc);
    }
}
'@

function New-FakeIndexMsix([string]$msixPath, [switch]$WithoutIndex, [switch]$Garbage) {
    $db = Join-Path $work 'fake-index.db'
    if (Test-Path -LiteralPath $db) { Remove-Item -LiteralPath $db -Force }
    if ($Garbage) { [IO.File]::WriteAllText($db, 'this is not a database') }
    else {
        [IW32HFakeIndexWriter]::Run($db, @"
CREATE TABLE ids (id TEXT); CREATE TABLE names (name TEXT); CREATE TABLE monikers (moniker TEXT); CREATE TABLE versions (version TEXT);
CREATE TABLE manifest (id INTEGER, name INTEGER, moniker INTEGER, version INTEGER);
CREATE TABLE norm_publishers (norm_publisher TEXT); CREATE TABLE norm_publishers_map (manifest INTEGER, norm_publisher INTEGER);
CREATE TABLE metadata (name TEXT, value TEXT);
INSERT INTO ids VALUES ('Acme.Tool'), ('Acme.Other'), ('O''Brien.App'), ('Solo.One');
INSERT INTO names VALUES ('Acme Tool'), ('Other Thing'), ('O''Brien App'), ('Solo');
INSERT INTO monikers VALUES ('acmet');
INSERT INTO versions VALUES ('0.9'), ('0.10'), ('1.0'), ('19c'), ('2.0');
INSERT INTO manifest VALUES (1,1,1,1), (1,1,1,2), (1,1,1,4), (2,2,NULL,3), (3,3,NULL,5), (4,4,NULL,3);
INSERT INTO norm_publishers VALUES ('acme'), ('obrien');
INSERT INTO norm_publishers_map VALUES (1,1), (2,1), (3,1), (4,1), (5,2), (6,3);
INSERT INTO metadata VALUES ('majorVersion','1'), ('minorVersion','7');
"@)
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $msixPath) { Remove-Item -LiteralPath $msixPath -Force }
    $zip = [System.IO.Compression.ZipFile]::Open($msixPath, 'Create')
    try {
        $name = $(if ($WithoutIndex) { 'Public/other.txt' } else { 'Public/index.db' })
        $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $db, $name)
    }
    finally { $zip.Dispose() }
}

# Der Abruf: liefert die vorbereitete msix und zaehlt mit.
$script:Fetches = 0
$script:FetchSource = Join-Path $work 'source.msix'
$script:FetchFails = $false
function Save-WinGetIndexSource {
    param([string]$Destination)
    $script:Fetches++
    if ($script:FetchFails) { throw 'network down' }
    Copy-Item -LiteralPath $script:FetchSource -Destination $Destination -Force
}
function Find-WinGetPackage {
    param($Query, $Source)
    [pscustomobject]@{ Name = 'Module Hit'; Id = 'Mod.Hit'; Version = '9.9'; Source = 'winget' }
}

$warnings = @()
function Invoke-Quiet([scriptblock]$block) {
    $script:warnings = @()
    $old = $WarningPreference; $WarningPreference = 'Continue'
    try { & $block 6>$null 3>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.WarningRecord]) { $script:warnings += $_.Message } else { $_ } } }
    finally { $WarningPreference = $old }
}

try {
    New-FakeIndexMsix $script:FetchSource

    # 1: Update
    $info = Update-WinGetIndex 6>$null
    Test-That ($info.Packages -eq 4) "Update: Packages is '$($info.Packages)', expected 4 (a one-row result must not fall apart into its columns)"
    Test-That ($info.Schema -eq '1.7') "Update: Schema is '$($info.Schema)', expected 1.7 (major.minor)"
    Test-That (Test-Path -LiteralPath (Join-Path $work 'Config\winget-index\index.json')) 'Update: index.json was not written'
    Test-That (-not (Test-Path -LiteralPath (Join-Path $work 'Config\winget-index\source.msix'))) 'Update: source.msix was left behind'
    Test-That ((Get-WinGetIndexInfo).Packages -eq 4) 'Info: Packages is not read back from index.json'

    # 2: kaputter Download laesst den Index unberuehrt
    $before = (Get-FileHash -LiteralPath (Get-WinGetIndexPath)).Hash
    New-FakeIndexMsix $script:FetchSource -WithoutIndex
    $threw = $false; try { $null = Update-WinGetIndex 6>$null } catch { $threw = $true }
    Test-That $threw 'a msix without index.db did not throw'
    New-FakeIndexMsix $script:FetchSource -Garbage
    $threw = $false; try { $null = Update-WinGetIndex 6>$null } catch { $threw = $true }
    Test-That $threw 'a download that is not a database did not throw'
    Test-That ((Get-FileHash -LiteralPath (Get-WinGetIndexPath)).Hash -eq $before) 'a broken download replaced the working index'
    Test-That (-not (Test-Path -LiteralPath ((Get-WinGetIndexPath) + '.new'))) 'a broken download left index.db.new behind'
    New-FakeIndexMsix $script:FetchSource

    # 3: wann geholt wird
    $script:Fetches = 0
    $null = Get-WinGetIndex 6>$null
    Test-That ($script:Fetches -eq 0) "a fresh index was fetched again ($($script:Fetches)x)"
    (Get-Item -LiteralPath (Get-WinGetIndexPath)).LastWriteTime = (Get-Date).AddDays(-2)
    $stamp = Join-Path $work 'Config\winget-index\index.json'
    $saved = Get-Content -LiteralPath $stamp -Raw | ConvertFrom-Json
    $saved.downloaded = (Get-Date).AddDays(-2).ToString('o')
    $saved | ConvertTo-Json | Set-Content -LiteralPath $stamp -Encoding UTF8
    $null = Get-WinGetIndex 6>$null
    Test-That ($script:Fetches -eq 1) "an index older than a day was fetched $($script:Fetches)x, expected 1"
    # Erneuerung scheitert -> alter bleibt, Warnung
    $saved.downloaded = (Get-Date).AddDays(-2).ToString('o'); $saved | ConvertTo-Json | Set-Content -LiteralPath $stamp -Encoding UTF8
    $script:FetchFails = $true
    Invoke-Quiet { $null = Get-WinGetIndex }
    Test-That ($script:warnings.Count -ge 1 -and ($script:warnings -join ' ') -like '*could not be refreshed*') 'a failed refresh did not warn'
    Test-That (@(Search-WinGetIndex -Query 'acme' 3>$null 6>$null).Count -gt 0) 'a failed refresh made the old index unusable'
    $script:FetchFails = $false

    # 4: Suche
    $byId = @(Search-WinGetIndex -Query 'Acme.Tool')
    Test-That ($byId.Count -eq 1 -and $byId[0].Id -eq 'Acme.Tool' -and $byId[0].Name -eq 'Acme Tool') "search by id: $($byId.Count) hit(s), '$($byId[0].Id)' / '$($byId[0].Name)'"
    Test-That ((@($byId[0].Versions) -join ',') -eq '0.10,0.9,19c') "versions order: $(@($byId[0].Versions) -join ',')"
    Test-That ((@(Search-WinGetIndex -Query 'Acme.Tool')[0].Version) -eq '0.10') "newest version is '$($byId[0].Version)', expected 0.10 (not 0.9)"
    Test-That (@(Search-WinGetIndex -Query 'Other Thing').Count -eq 1) 'search by name found nothing'
    Test-That (@(Search-WinGetIndex -Query 'acmet').Count -eq 1 -and (@(Search-WinGetIndex -Query 'acmet')[0].Id -eq 'Acme.Tool')) 'search by moniker found nothing'
    $pub = @(Search-WinGetIndex -Query 'obrien')
    Test-That ($pub.Count -eq 1 -and $pub[0].Id -eq "O'Brien.App") "search by publisher: $($pub.Count) hit(s)"
    $quote = @(Search-WinGetIndex -Query "O'Brien")
    Test-That ($quote.Count -eq 1) "a search with an apostrophe: $($quote.Count) hit(s)"
    $threw = $false; try { $null = Search-WinGetIndex -Query 'a' } catch { $threw = $true }
    Test-That $threw 'a one character search was not refused'
    $ordered = @(Search-WinGetIndex -Query 'Solo')
    Test-That ($ordered[0].Id -eq 'Solo.One') "exact name hit is not first: '$($ordered[0].Id)'"
    Test-That ((@(Get-WinGetIndexVersion 'Acme.Tool') -join ',') -eq '0.10,0.9,19c') "Get-WinGetIndexVersion: $(@(Get-WinGetIndexVersion 'Acme.Tool') -join ',')"
    Test-That (@(Get-WinGetIndexVersion 'Nope.Nothing').Count -eq 0) 'an unknown package has versions'
    Test-That ((Get-WinGetIndexStatusText) -like 'winget index: 4 packages*') "status text: $(Get-WinGetIndexStatusText)"

    # 5: Suche des Dialogs
    $curated = @([pscustomobject]@{ name = 'Acme Tool (curated)'; packageId = 'Acme.Tool' }, [pscustomobject]@{ name = 'Unrelated'; packageId = 'Zed.Zed' })
    $front = @(Search-WinGetCatalog -Query '' -Packages $curated)
    Test-That ($front.Count -eq 2 -and $front[0].Source -eq 'catalog') 'no query did not return the curated list'
    $merged = @(Search-WinGetCatalog -Query 'acme' -Packages $curated)
    Test-That ($merged[0].Source -eq 'catalog' -and $merged[0].Id -eq 'Acme.Tool') "curated hit is not on top: '$($merged[0].Id)' $($merged[0].Source)"
    Test-That ($merged[0].Version -eq '0.10') "curated hit has no version from the index: '$($merged[0].Version)'"
    Test-That (@($merged | Where-Object { $_.Id -eq 'Acme.Tool' }).Count -eq 1) 'a curated package appears twice'
    Test-That (@($merged | Where-Object { $_.Id -eq 'Acme.Other' }).Count -eq 1) 'the index hit is missing next to the curated one'
    Test-That (@($merged | Where-Object { $_.Id -eq 'Zed.Zed' }).Count -eq 0) 'an unrelated curated package matched'

    # Rueckfall auf das Modul: kein Index, kein Netz
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $work 'Config\winget-index') -File)) { Remove-Item -LiteralPath $f.FullName -Force }
    $script:FetchFails = $true
    $fallback = $null
    Invoke-Quiet { $script:fallback = @(Search-WinGetCatalog -Query 'whatever' -Packages $curated) }
    Test-That ($fallback.Count -eq 1 -and $fallback[0].Source -eq 'module' -and $fallback[0].Id -eq 'Mod.Hit') "fallback to the module: $($fallback.Count) hit(s), source '$($fallback[0].Source)'"
    Test-That (($script:warnings -join ' ') -like '*asking the winget module*') 'the fallback to the module did not warn'
    Test-That ((Get-WinGetIndexStatusText) -like 'No winget index yet*') 'status text without an index'
    $script:FetchFails = $false

    # 6: kuratierte Liste schreiben
    $cat = Join-Path $work 'Config\catalog.json'
    Test-That (Add-WinGetCatalogEntry -Name 'First' -PackageId 'A.First' -Path $cat) 'a new entry did not return $true'
    Test-That (-not (Add-WinGetCatalogEntry -Name 'First again' -PackageId 'A.First' -Path $cat)) 'an existing entry did not return $false'
    Test-That (Add-WinGetCatalogEntry -Name 'Say "Hi" \ there' -PackageId 'B.Quote' -Path $cat) 'the second entry was not added'
    $list = @(Get-WinGetCatalogList -Path $cat)
    Test-That ($list.Count -eq 2) "catalog list has $($list.Count) entries, expected 2"
    Test-That ($list[1].name -eq 'Say "Hi" \ there') "quotes and backslash did not survive: '$($list[1].name)'"
    Test-That ($list[0].packageId -eq 'A.First') 'the first entry was lost'
    Test-That (@(Get-WinGetCatalogList -Path (Join-Path $work 'nope.json')).Count -eq 0) 'a missing catalog.json is not an empty list'
}
finally {
    foreach ($f in @(Get-ChildItem -LiteralPath $work -Recurse -File -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    foreach ($d in @(Get-ChildItem -LiteralPath $work -Recurse -Directory -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)) { Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue
}

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { [Console]::WriteLine("FAIL: $p") }
    exit 1
}
[Console]::WriteLine('winget index: update and schema, broken download, age, search by id/name/moniker/publisher, curated list and module fallback. PASS')
exit 0
