<#
    .SYNOPSIS
    Verhaltenstest: ein fertiges Erkennungsskript statt ARP-Name/WinGet (Apps.csv-Spalte "DetectionScript").

    .DESCRIPTION
    Geprueft wird:

      1. Die Spalte ist da: Get-AppsCsvColumns kennt sie, Save/Read behalten sie.
      2. Der Pfad: absolut bleibt, relativ wird gegen den Tool-Ordner aufgeloest, leer heisst "kein eigenes Skript".
      3. Eine App hat EINE Erkennungsregel: DetectionScript zusammen mit MsiProductCode ist ein Widerspruch
         (Test-AppRecord im Editor, Get-DetectionConflict im Bau).
      4. Copy-DetectionScript legt das Skript unveraendert (Bytes) als detection.ps1 in den Paketordner und weist ein
         fehlendes Skript, ein leeres Feld und ein Skript mit Syntaxfehler ab - ohne eine detection.ps1 zu hinterlassen.
      5. Die Hinweise im Editor (Get-EditHint) sagen, was mit dem Wert passiert: leer, gesetzt, nicht gefunden, Widerspruch.
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

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('iw32h-detscript-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $work
try {
    # 1) Spalte
    Test-That ((Get-AppsCsvColumns) -contains 'DetectionScript') 'Get-AppsCsvColumns does not know DetectionScript - the editor would not show it and Save-AppsCsv would drop it'
    $csvRoot = Join-Path $work 'csv'
    $null = New-Item -ItemType Directory -Force -Path $csvRoot
    Save-AppsCsv -RootDir $csvRoot -Rows @([pscustomobject]@{ DisplayName = 'CbaHeartbeat'; Version = '1.1.1'; DetectionScript = 'C:\Repo\client\detect.ps1' })
    $back = @(Read-AppsCsv -RootDir $csvRoot)
    Test-That ($back.Count -eq 1 -and $back[0].DetectionScript -eq 'C:\Repo\client\detect.ps1') 'DetectionScript did not survive save and read'

    # 2) Pfad
    $abs = Join-Path $work 'abs\detect.ps1'
    Test-That ((Resolve-DetectionScriptPath -Path $abs -RootDir $rootDir) -eq $abs) 'an absolute path was changed'
    Test-That ((Resolve-DetectionScriptPath -Path "  `"$abs`"  " -RootDir $rootDir) -eq $abs) 'spaces and quotes around the path were kept'
    Test-That ((Resolve-DetectionScriptPath -Path 'Scripts\x.ps1' -RootDir $rootDir) -eq (Join-Path $rootDir 'Scripts\x.ps1')) 'a relative path does not start at the tool folder'
    Test-That ((Resolve-DetectionScriptPath -Path '' -RootDir $rootDir) -eq '' -and (Resolve-DetectionScriptPath -Path $null -RootDir $rootDir) -eq '') 'an empty value is a path'

    # 3) eine Regel
    $both = [pscustomobject]@{ DisplayName = 'X'; Version = '1.0'; DetectionScript = 'd.ps1'; MsiProductCode = '{23170F69-40C1-2702-2409-000001000000}' }
    Test-That ([bool](Get-DetectionConflict -Record $both)) 'DetectionScript + MsiProductCode is not a conflict'
    Test-That ([bool](Test-AppRecord -Record $both -Others @())) 'the editor accepts DetectionScript + MsiProductCode'
    Test-That (-not (Get-DetectionConflict -Record ([pscustomobject]@{ DetectionScript = 'd.ps1'; MsiProductCode = '' }))) 'DetectionScript alone is a conflict'
    Test-That (-not (Get-DetectionConflict -Record ([pscustomobject]@{ DetectionScript = ''; MsiProductCode = '{23170F69-40C1-2702-2409-000001000000}' }))) 'MsiProductCode alone is a conflict'
    Test-That (-not (Test-AppRecord -Record ([pscustomobject]@{ DisplayName = 'X'; Version = '1.0'; DetectionScript = 'd.ps1' }) -Others @())) 'the editor refuses a valid DetectionScript'

    # 4) kopieren
    $src = Join-Path $work 'src'
    $pkg = Join-Path $work 'pkg'
    $null = New-Item -ItemType Directory -Force -Path $src, $pkg
    $good = Join-Path $src 'detect.ps1'
    $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("# Umlaut: ä`r`n`$v = '1.1.1'`r`nexit 0`r`n"))
    [IO.File]::WriteAllBytes($good, $bytes)
    Copy-DetectionScript -AppFolder $pkg -ScriptPath $good -RootDir $rootDir
    $copied = Join-Path $pkg 'detection.ps1'
    Test-That ((Test-Path -LiteralPath $copied) -and ([BitConverter]::ToString([IO.File]::ReadAllBytes($copied)) -eq [BitConverter]::ToString($bytes))) 'the script was not copied byte for byte as detection.ps1 (BOM / umlaut / line endings)'

    $rel = Join-Path $work 'relroot'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $rel 'Scripts'), (Join-Path $work 'pkg2')
    [IO.File]::WriteAllBytes((Join-Path $rel 'Scripts\d.ps1'), $bytes)
    Copy-DetectionScript -AppFolder (Join-Path $work 'pkg2') -ScriptPath 'Scripts\d.ps1' -RootDir $rel
    Test-That (Test-Path -LiteralPath (Join-Path $work 'pkg2\detection.ps1')) 'a relative DetectionScript was not found from the tool folder'

    function Test-Rejects([string]$name, [string]$scriptPath, [string]$expect) {
        $folder = Join-Path $work "rej-$name"
        $null = New-Item -ItemType Directory -Force -Path $folder
        $message = ''
        try { Copy-DetectionScript -AppFolder $folder -ScriptPath $scriptPath -RootDir $rootDir } catch { $message = $_.Exception.Message }
        Test-That ($message -match $expect) "$name : expected an error matching '$expect', got '$message'"
        Test-That (-not (Test-Path -LiteralPath (Join-Path $folder 'detection.ps1'))) "$name : a detection.ps1 was left behind"
    }
    Test-Rejects 'missing' (Join-Path $src 'nope.ps1') 'does not exist'
    Test-Rejects 'empty' '' 'is empty'
    $broken = Join-Path $src 'broken.ps1'
    [IO.File]::WriteAllText($broken, "`$x = 1`r`nif (`$x {`r`n")
    Test-Rejects 'syntax' $broken 'syntax error \(line \d+\)'

    # 5) Hinweise
    $hint = { param($v) Get-EditHint -Key 'DetectionScript' -Values $v -RootDir $rootDir }
    Test-That ((& $hint @{ DisplayName = 'X'; DetectionScript = '' }) -match '^Empty: .*generated') 'hint (empty) does not say that detection.ps1 is generated'
    Test-That ((& $hint @{ DisplayName = 'X'; DetectionScript = (Join-Path $work 'gone.ps1') }) -match '^Not found: ') 'hint does not say that the file is missing'
    Test-That ((& $hint @{ DisplayName = 'X'; DetectionScript = $good }) -match 'copied into the package as detection\.ps1') 'hint (found) does not say what happens to the script'
    Test-That ((& $hint @{ DisplayName = 'X'; DetectionScript = $good; MsiProductCode = '{23170F69-40C1-2702-2409-000001000000}' }) -match 'both set') 'hint does not warn about the conflict with MsiProductCode'
    $arpHint = Get-EditHint -Key 'ArpName' -Values @{ DisplayName = 'Sample'; ArpName = ''; DetectionScript = $good }
    Test-That ($arpHint -match 'Detection is your DetectionScript' -and $arpHint -match "STARTS WITH 'Sample'") 'the ArpName hint still claims that ArpName drives the detection'
}
finally {
    foreach ($dir in @(Get-ChildItem -LiteralPath $work -Directory -ErrorAction SilentlyContinue)) {
        try { $null = Remove-PackageFolder -Path $dir.FullName -PacketRoot $work 6>$null } catch { $problems += "cleanup: $($_.Exception.Message)" }
    }
    Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $work) { $problems += "cleanup: $work is not empty" }
}

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { [Console]::WriteLine("FAIL: $p") }
    exit 1
}
[Console]::WriteLine('DetectionScript: column kept, path resolved, one detection rule per app, script copied byte for byte and refused when missing / empty / syntactically broken, editor hints follow the value. PASS')
exit 0
