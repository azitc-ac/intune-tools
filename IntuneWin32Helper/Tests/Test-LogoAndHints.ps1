<#
    .SYNOPSIS
    Verhaltenstest: Logo-Suche mit Namenskuerzung, mitlaufende Hinweise im Editor, PSADT-Log in den IME-Ordner.

    .DESCRIPTION
    Alles gegen Dateien in einem Testordner, ohne Fenster:

      1. Find-LogoFile: genau > ohne "(x64)"/Endversion > Logo ist Wortanfang des App-Namens > App-Name ist
         Wortanfang des Logo-Namens; "PDF" greift nie "PDF24 Creator", "7-Zip" nie "7"; defaultlogo zaehlt nicht;
         der laengste Treffer gewinnt.
      2. Resolve-PackageLogo: ohne URL kommt das verwandte Logo ins Paket (nicht das Standardlogo); eine
         ausdrueckliche URL wird von einer Vermutung nicht uebersteuert (Download versucht); genau gleicher
         Name gewinnt weiter.
      3. Get-EditHint: Version (WinGet / Paket mit Ordnername), MsiProductCode (leer / GUID / kein GUID),
         logoURL (URL / gefundenes Logo / keins), ArpName; ein Feld ohne lebenden Hinweis gibt $null.
      4. Set-PsadtLogPath: ersetzt das Muster, auch in einer schreibgeschuetzten Datei und einem
         schreibgeschuetzten Ordner, behaelt die BOM; fehlt das Muster, bleibt die Datei unveraendert und das
         Ergebnis ist $false. Gegen das echte Template des installierten PSAppDeployToolkit (falls da) wird
         geprueft, dass das Muster noch drinsteht - sonst loggte PSADT nach einem Update still in den falschen Ordner.
#>
$ErrorActionPreference = 'Stop'

$rootDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Get-ToolFunctionsAst.ps1')
$ast = Get-ToolFunctionsAst (Join-Path $rootDir 'Functions')
foreach ($name in 'Find-LogoFile', 'Resolve-PackageLogo', 'Resize-IconFile', 'Get-ImageExtensionFromUrl', 'Get-EditHint', 'Get-ArpSearchName', 'Set-PsadtLogPath') {
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if (-not $fn) { throw "Funktion $name nicht gefunden" }
    . ([scriptblock]::Create($fn.Extent.Text))
}

$problems = @()
function Test-That([bool]$condition, [string]$what) { if (-not $condition) { $script:problems += $what } }

Add-Type -AssemblyName System.Drawing
$work = Join-Path ([IO.Path]::GetTempPath()) ('iw32h-logo-' + [guid]::NewGuid().ToString('N'))
$logos = Join-Path $work 'Logos'
$null = New-Item -ItemType Directory -Path $logos -Force
function New-TestPng([string]$path) {
    $bitmap = New-Object System.Drawing.Bitmap 40, 20
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}
foreach ($n in '7-Zip', 'PDF24 Creator', 'Oracle_Database_Client', 'Git', 'Git for Windows', 'Exact Name 2.0', 'defaultlogo') { New-TestPng (Join-Path $logos "$n.png") }
function Leaf($p) { if ($p) { Split-Path -Leaf $p } else { '<none>' } }

# --- 1. Find-LogoFile ---
Test-That ((Leaf (Find-LogoFile -AppName 'Exact Name 2.0' -LogoDir $logos)) -eq 'Exact Name 2.0.png') 'exact name wins'
Test-That ((Leaf (Find-LogoFile -AppName '7-Zip 26.02 (x64 edition)' -LogoDir $logos)) -eq '7-Zip.png') 'a logo that is a word-prefix of the app name is found'
Test-That ((Leaf (Find-LogoFile -AppName '7-Zip (x64)' -LogoDir $logos)) -eq '7-Zip.png') 'architecture in brackets is cut off'
Test-That ((Leaf (Find-LogoFile -AppName 'Git for Windows 2.47' -LogoDir $logos)) -eq 'Git for Windows.png') 'the longest matching logo name wins over a shorter one'
Test-That ((Leaf (Find-LogoFile -AppName 'Oracle' -LogoDir $logos)) -eq 'Oracle_Database_Client.png') 'an app name that is the start of a logo name finds it'
Test-That ($null -eq (Find-LogoFile -AppName 'PDF' -LogoDir $logos)) 'PDF does not pick up PDF24 Creator (word boundary)'
Test-That ($null -eq (Find-LogoFile -AppName '7' -LogoDir $logos)) 'a hyphen is no word boundary: 7 does not pick up 7-Zip'
Test-That ($null -eq (Find-LogoFile -AppName 'default' -LogoDir $logos)) 'defaultlogo is never a candidate'
Test-That ($null -eq (Find-LogoFile -AppName 'Nothing Like It' -LogoDir $logos)) 'no related logo gives $null'
Test-That ($null -eq (Find-LogoFile -AppName 'Git' -LogoDir (Join-Path $work 'missing'))) 'a missing Logos folder gives $null, not an error'
Test-That ((Leaf (Find-LogoFile -AppName 'a/b:c' -LogoDir $logos)) -eq '<none>') 'characters that are not allowed in file names do not break the search'
Test-That ($null -eq (Find-LogoFile -AppName 'Gitea Server' -LogoDir $logos)) 'a logo name that is not followed by a word boundary does not match: Git is not Gitea'
Test-That ((Leaf (Find-LogoFile -AppName '7-Zip(x64)' -LogoDir $logos)) -eq '7-Zip.png') 'architecture in brackets without a space is cut off'
Test-That ($null -eq (Find-LogoFile -AppName 'defaultlogo extra' -LogoDir $logos)) 'defaultlogo is never a candidate, not even as a word-prefix'

# --- 2. Resolve-PackageLogo ---
$app1 = Join-Path $work 'app1'; $null = New-Item -ItemType Directory -Path $app1
$result = Resolve-PackageLogo -AppFolder $app1 -AppName '7-Zip 26.02 (x64 edition)' -LogoUrl '' -RootDir $work 6>$null
Test-That ($result -eq '7-Zip 26.02 (x64 edition).png') "the package gets the logo under the app name (got '$result')"
$packed = Join-Path $app1 '7-Zip 26.02 (x64 edition).png'
Test-That (Test-Path -LiteralPath $packed) 'the logo file is in the package folder'
# Es ist das Logo von 7-Zip (40x20 -> auf 256 quadratisch gebracht), nicht das Standardlogo: das gibt es hier nur als 40x20-Datei,
# darum zaehlt der Logname im Protokoll. Direkt: ein Standardlogo mit anderer Groesse zum Unterscheiden.
$defaultBitmap = New-Object System.Drawing.Bitmap 10, 10; $defaultBitmap.Save((Join-Path $logos 'defaultlogo.png'), [System.Drawing.Imaging.ImageFormat]::Png); $defaultBitmap.Dispose()
$app2 = Join-Path $work 'app2'; $null = New-Item -ItemType Directory -Path $app2
$null = Resolve-PackageLogo -AppFolder $app2 -AppName 'Nothing Like It' -LogoUrl '' -RootDir $work 6>$null
$img = [System.Drawing.Image]::FromFile((Join-Path $app2 'Nothing Like It.png')); $unrelatedWidth = $img.Width; $img.Dispose()
$img = [System.Drawing.Image]::FromFile($packed); $relatedWidth = $img.Width; $img.Dispose()
Test-That ($relatedWidth -eq 256 -and $unrelatedWidth -eq 256) 'both logos are brought to 256 wide'
$transcript = (Resolve-PackageLogo -AppFolder (New-Item -ItemType Directory -Path (Join-Path $work 'app3')).FullName -AppName 'Git for Windows 2.47' -LogoUrl '' -RootDir $work 6>&1 | Out-String)
Test-That ($transcript -match 'related name \[Git for Windows\.png\]') "the message names the related logo ($transcript)"
$transcript = (Resolve-PackageLogo -AppFolder (New-Item -ItemType Directory -Path (Join-Path $work 'app4')).FullName -AppName 'Nothing Like It' -LogoUrl '' -RootDir $work 6>&1 | Out-String)
Test-That ($transcript -match 'default logo') 'without a related logo the default logo is taken'
# Eine ausdrueckliche URL wird von einer Vermutung nicht uebersteuert: der Download wird versucht (und scheitert hier),
# erst danach gilt das Standardlogo - nicht das verwandte 7-Zip-Logo.
$transcript = (Resolve-PackageLogo -AppFolder (New-Item -ItemType Directory -Path (Join-Path $work 'app5')).FullName -AppName '7-Zip 26.02' -LogoUrl 'http://127.0.0.1:9/none.png' -RootDir $work 6>&1 | Out-String)
Test-That ($transcript -match 'Trying logo download' -and $transcript -notmatch 'related name') "an explicit logoURL is tried first, a guess does not replace it ($transcript)"
$transcript = (Resolve-PackageLogo -AppFolder (New-Item -ItemType Directory -Path (Join-Path $work 'app6')).FullName -AppName 'Exact Name 2.0' -LogoUrl 'http://127.0.0.1:9/none.png' -RootDir $work 6>&1 | Out-String)
Test-That ($transcript -match 'Using existing logo' -and $transcript -notmatch 'Trying logo download') 'a logo named exactly like the app wins over a URL'

# --- 3. Get-EditHint ---
function Hint([string]$key, [hashtable]$values, [string]$dir = '') { Get-EditHint -Key $key -Values $values -LogoDir $dir }
Test-That ((Hint 'Version' @{ DisplayName = 'Sample'; Version = 'LatestAvailable' }) -match 'WinGet app') 'Version hint: LatestAvailable is a WinGet app'
Test-That ((Hint 'Version' @{ DisplayName = 'Sample'; Version = '1.2' }) -match "package folder is named 'Sample - 1\.2'") 'Version hint: a number names the package folder'
Test-That ((Hint 'Version' @{ DisplayName = ''; Version = '' }) -match 'DisplayName - Version') 'Version hint: empty fields do not print empty quotes'
Test-That ((Hint 'MsiProductCode' @{ MsiProductCode = '' }) -match 'detection\.ps1 decides') 'product code hint: empty'
Test-That ((Hint 'MsiProductCode' @{ MsiProductCode = '{23170F69-40C1-2702-2409-000001000000}' }) -match 'Detection by the MSI product code \{23170F69') 'product code hint: a GUID in braces is accepted'
Test-That ((Hint 'MsiProductCode' @{ MsiProductCode = '23170F69-40C1-2702-2409-000001000000' }) -match 'is not a product code') 'product code hint: a GUID without braces is flagged'
Test-That ((Hint 'MsiProductCode' @{ MsiProductCode = 'x{23170F69-40C1-2702-2409-000001000000}' }) -match 'is not a product code') 'product code hint: text before the braces is flagged'
Test-That ((Hint 'MsiProductCode' @{ MsiProductCode = 'abc' }) -match "'abc' is not a product code") 'product code hint: junk is flagged'
Test-That ((Hint 'logoURL' @{ DisplayName = '7-Zip 26.02'; logoURL = '' } $logos) -match 'logo \[7-Zip\.png\]') 'logo hint: names the related logo that will be used'
Test-That ((Hint 'logoURL' @{ DisplayName = 'Nothing Like It'; logoURL = '' } $logos) -match 'default logo is used') 'logo hint: no fitting logo means the default logo'
Test-That ((Hint 'logoURL' @{ DisplayName = 'Sample'; logoURL = 'https://x/y.png' } $logos) -match 'Downloaded once') 'logo hint: with a URL it says it is downloaded'
Test-That ((Hint 'logoURL' @{ DisplayName = ''; logoURL = '' } $logos) -match '^Empty: ') 'logo hint: no name yet'
Test-That ((Hint 'ArpName' @{ DisplayName = 'Sample'; ArpName = '' }) -match "STARTS WITH 'Sample'") 'ArpName hint: DisplayName when empty'
Test-That ((Hint 'ArpName' @{ DisplayName = 'Sample'; ArpName = 'Foo' }) -match "STARTS WITH 'Foo'") 'ArpName hint: follows the field'
Test-That ($null -eq (Hint 'Publisher' @{ DisplayName = 'x' })) 'a field without a live hint gives $null'

# --- 4. Set-PsadtLogPath ---
$config = Join-Path $work 'Config'; $null = New-Item -ItemType Directory -Path $config
$file = Join-Path $config 'config.psd1'
[IO.File]::WriteAllText($file, "@{`r`n    Toolkit = @{`r`n        LogPath = '`$envWinDir\Logs\Software'`r`n    }`r`n}`r`n", (New-Object Text.UTF8Encoding $true))
(Get-Item $file).Attributes = 'ReadOnly'; (Get-Item $config).Attributes = 'ReadOnly'
Test-That ((Set-PsadtLogPath -ConfigFile $file) -eq $true) 'Set-PsadtLogPath reports success'
$bytes = [IO.File]::ReadAllBytes($file)
$text = [IO.File]::ReadAllText($file)
Test-That ($text.Contains('$envProgramData\Microsoft\IntuneManagementExtension\Logs') -and -not $text.Contains('envWinDir\Logs\Software')) 'the log path points into the IME logs, also in a read-only file and folder'
Test-That ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'the file keeps its BOM'
$before = [IO.File]::ReadAllText($file)
Test-That ((Set-PsadtLogPath -ConfigFile $file) -eq $false) 'a second run finds nothing to replace and says so'
Test-That ([IO.File]::ReadAllText($file) -eq $before) 'a file without the pattern stays unchanged'

$module = Get-Module -ListAvailable -Name PSAppDeployToolkit | Sort-Object Version -Descending | Select-Object -First 1
if ($module) {
    $template = Join-Path $module.ModuleBase 'Config\config.psd1'
    if (Test-Path -LiteralPath $template) {
        $copy = Join-Path $work 'template-config.psd1'
        Copy-Item -LiteralPath $template -Destination $copy
        Test-That ((Set-PsadtLogPath -ConfigFile $copy) -eq $true) "the installed PSAppDeployToolkit $($module.Version) template still holds the pattern the tool replaces"
    }
    else { [Console]::WriteLine("hinweis: kein Config\config.psd1 im Modul $($module.Version) - Template-Vergleich uebersprungen") }
}
else { [Console]::WriteLine('hinweis: PSAppDeployToolkit nicht installiert - Template-Vergleich uebersprungen') }

# Aufraeumen: erst die Schreibschutz-Attribute zurueck (der Testordner liegt im Temp), dann nur die eigenen Dateien
(Get-Item $config).Attributes = 'Directory'; (Get-Item $file).Attributes = 'Normal'
Get-ChildItem -LiteralPath $work -Recurse -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
Get-ChildItem -LiteralPath $work -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
Remove-Item -LiteralPath $work -Force

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { [Console]::WriteLine("FAIL: $p") }
    exit 1
}
[Console]::WriteLine('Logo search, live editor hints and PSADT log path: related logos are found by name (word boundary, longest wins), an explicit URL beats a guess, hints follow the value, the PSADT log goes to the IME logs. PASS')
exit 0
