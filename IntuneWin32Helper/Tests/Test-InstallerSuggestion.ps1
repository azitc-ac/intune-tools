<#
    .SYNOPSIS
    Verhaltenstest: "From installer..." im Editor - Engine erkennen und Befehle vorschlagen.

    .DESCRIPTION
    Gegen kleine Dateien mit den Kennungen der Engines (kein echter Installer noetig):

      1. Inno / NSIS / Burn: der Vorschlag traegt die Schalter der Engine, der Dateiname steht im Befehl,
         Certain ist wahr, kein Vermerk.
      2. Unbekannte Engine: /S als Vermutung, Certain = $false, der Vermerk steht im Befehl und in Note.
      3. Ein getippter DisplayName/Publisher/Version bleibt; nur leere Felder werden aus der Datei gefuellt.
      4. Der Suchname der Deinstallation folgt DisplayName beziehungsweise ArpName (wie die Erkennung).
      5. MSI: SingleMSI = true, keine Install-/Uninstall-Befehle (Zero-Config).
      6. Derselbe Weg wie der Paketbau: Get-DerivedInstallCommands und Get-InstallCommandsForFile liefern fuer
         dieselbe Datei dieselben Befehle.
#>
$ErrorActionPreference = 'Stop'

$rootDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Get-ToolFunctionsAst.ps1')
$ast = Get-ToolFunctionsAst (Join-Path $rootDir 'Functions')
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}

$problems = @()
function Test-That([bool]$condition, [string]$what) { if (-not $condition) { $script:problems += $what } }

$work = Join-Path ([IO.Path]::GetTempPath()) ('iw32h-inst-' + [guid]::NewGuid().ToString('N'))
$files = Join-Path $work 'Files'
$null = New-Item -ItemType Directory -Path $files -Force
function New-FakeInstaller([string]$name, [string]$marker) {
    $path = Join-Path $files $name
    [IO.File]::WriteAllBytes($path, [Text.Encoding]::ASCII.GetBytes("MZ-fake-installer $marker padding"))
    return $path
}

# --- 1. Engines ---
$inno = New-FakeInstaller 'setup-inno.exe' 'Inno Setup'
$s = Get-InstallerSuggestion -Path $inno -Current @{ DisplayName = 'Sample'; ArpName = '' }
Test-That ($s.Engine -eq 'inno' -and $s.Certain) 'Inno is recognised'
Test-That ($s.Values['InstallCmd'] -match "Start-ADTProcess -FilePath 'setup-inno\.exe' -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /ALLUSERS'") "Inno install command carries the Inno switches and the file name ($($s.Values['InstallCmd']))"
Test-That ($s.Values['UninstallCmd'] -match "Uninstall-ADTApplication -Name 'Sample\*' -NameMatch 'Wildcard'") 'the uninstall command searches the program list by the name followed by a wildcard'
Test-That ($s.Note -eq '' -and $s.Values['InstallCmd'] -notmatch '#') 'a recognised engine carries no note'
$nsis = New-FakeInstaller 'setup-nsis.exe' 'Nullsoft'
$s = Get-InstallerSuggestion -Path $nsis -Current @{ DisplayName = 'Sample' }
Test-That ($s.Engine -eq 'nsis' -and $s.Values['InstallCmd'] -match "-ArgumentList '/S'") 'NSIS is recognised with /S'
$burn = New-FakeInstaller 'setup-burn.exe' '.wixburn'
$s = Get-InstallerSuggestion -Path $burn -Current @{ DisplayName = 'Sample' }
Test-That ($s.Engine -eq 'burn' -and $s.Values['InstallCmd'] -match '/quiet /norestart') 'Burn is recognised'

# --- 2. unbekannt ---
$unknown = New-FakeInstaller 'setup-unknown.exe' 'nothing special'
$s = Get-InstallerSuggestion -Path $unknown -Current @{ DisplayName = 'Sample' }
Test-That ($s.Engine -eq 'unknown' -and -not $s.Certain) 'an unknown engine is marked as a guess'
Test-That ($s.Note -match 'nicht erkannt' -and $s.Values['InstallCmd'] -match "-ArgumentList '/S'.*# .*nicht erkannt") 'the guess carries its note, in Note and as a comment in the command'

# --- 3. getippte Werte bleiben ---
$s = Get-InstallerSuggestion -Path $inno -Current @{ DisplayName = 'Typed Name'; Publisher = 'Typed Publisher'; Version = '9.9' }
Test-That (-not $s.Values.Contains('DisplayName') -and -not $s.Values.Contains('Publisher') -and -not $s.Values.Contains('Version')) 'typed DisplayName, Publisher and Version are not overwritten'
# Eine Datei mit Versionsressource (eine echte Windows-EXE, nur gelesen): leere Felder werden gefuellt, getippte bleiben.
$real = Join-Path $files 'whoami.exe'
Copy-Item -LiteralPath (Join-Path $env:windir 'System32\whoami.exe') -Destination $real
$s = Get-InstallerSuggestion -Path $real -Current @{ DisplayName = ''; Publisher = ''; Version = '' }
Test-That ($s.Values.Contains('DisplayName') -and $s.Values.Contains('Publisher') -and $s.Values.Contains('Version')) 'empty fields are filled from the version resource'
$s = Get-InstallerSuggestion -Path $real -Current @{ DisplayName = 'Typed Name'; Publisher = 'Typed Publisher'; Version = '9.9' }
Test-That (-not $s.Values.Contains('DisplayName') -and -not $s.Values.Contains('Publisher') -and -not $s.Values.Contains('Version')) 'typed values stay although the file has a version resource'
Remove-Item -LiteralPath $real -Force
Test-That ($s.Values['UninstallCmd'] -match "-Name 'Typed Name\*'") 'the uninstall uses the typed name'

# --- 4. ArpName ---
$s = Get-InstallerSuggestion -Path $inno -Current @{ DisplayName = 'Sample'; ArpName = 'Sample Pro' }
Test-That ($s.Values['UninstallCmd'] -match "-Name 'Sample Pro\*'") 'ArpName wins over DisplayName for the uninstall search'
$s = Get-InstallerSuggestion -Path $inno -Current @{ }
Test-That ($s.Values['UninstallCmd'] -match "-Name 'setup-inno\*'") 'without any name the file name is the last resort (no empty search that would match everything)'

# --- 5. MSI ---
$msi = Join-Path $files 'sample.msi'
[IO.File]::WriteAllBytes($msi, [byte[]](1, 2, 3))
$s = Get-InstallerSuggestion -Path $msi -Current @{ DisplayName = 'Sample' }
Test-That ($s.Engine -eq 'msi' -and $s.Values['SingleMSI'] -eq 'true') 'an MSI is zero-config (SingleMSI)'
Test-That (-not $s.Values.Contains('InstallCmd') -and -not $s.Values.Contains('UninstallCmd')) 'an MSI gets no install or uninstall command (PSADT is not customised)'

# --- 6. derselbe Weg wie der Bau ---
Remove-Item -LiteralPath $msi -Force
foreach ($exe in $inno, $nsis, $unknown) {
    foreach ($other in Get-ChildItem -LiteralPath $files -Filter '*.exe' | Where-Object { $_.FullName -ne $exe }) { Move-Item -LiteralPath $other.FullName -Destination ($other.FullName + '.keep') }
    $fromBuild = Get-DerivedInstallCommands -ContentPath $work -AppName 'Sample'
    $fromFile = Get-InstallCommandsForFile -Path $exe -AppName 'Sample'
    Test-That ($fromBuild.Install -eq $fromFile.Install -and $fromBuild.Uninstall -eq $fromFile.Uninstall -and $fromBuild.Engine -eq $fromFile.Engine) "package build and editor suggest the same commands for $(Split-Path -Leaf $exe)"
    foreach ($kept in Get-ChildItem -LiteralPath $files -Filter '*.keep') { Move-Item -LiteralPath $kept.FullName -Destination ($kept.FullName -replace '\.keep$', '') }
}

Get-ChildItem -LiteralPath $files -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
Remove-Item -LiteralPath $files -Force
Remove-Item -LiteralPath $work -Force

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { [Console]::WriteLine("FAIL: $p") }
    exit 1
}
[Console]::WriteLine('Installer suggestion: the engine is recognised from the file, the commands equal what the package build derives, typed values stay, a guess says so. PASS')
exit 0
