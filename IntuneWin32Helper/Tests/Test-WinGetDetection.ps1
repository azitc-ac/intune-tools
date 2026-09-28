<#
    .SYNOPSIS
    Verhaltenstest fuer Templates\detection_template-WinGetApp.ps1.

    .DESCRIPTION
    Faehrt die echte Vorlage - gerendert wie in createApps - gegen ein
    nachgebautes winget. Das gibt wie das echte ein ARRAY von Zeilen aus
    (Kopfzeile, Trennlinie, Paketzeile). Genau daran scheiterte die Erkennung
    seit c6eb0eb: "-notlike" auf dem Array war fuer eine installierte App wahr,
    sie galt als "NOT found" und wurde bei jedem Zyklus neu installiert.

    Erwartet:
      installiert, aktuell   -> Exit 0
      installiert, veraltet  -> Exit 1
      nicht installiert      -> Exit 1

    Ersetzt wird in der Vorlage nur der feste Suchpfad von winget.exe; der Test
    prueft vorher, dass es ihn gibt. $env:ProgramData zeigt auf einen Temp-
    Ordner, damit kein Log in die echten IME-Logs geht.
    Laeuft ohne Netz, ohne GUI und ohne Tenant.
#>
$ErrorActionPreference = 'Stop'

$rootDir  = Split-Path -Parent $PSScriptRoot
$template = Join-Path $rootDir 'Templates\detection_template-WinGetApp.ps1'
$wingetSearch = 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller*\winget.exe'
$packageId = 'Vendor.SampleApp'

$problems = @()
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('iw32h-winget-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $work
$programData = Join-Path $work 'ProgramData'
$null = New-Item -ItemType Directory -Force -Path (Join-Path $programData 'Microsoft\IntuneManagementExtension\Logs')

try {
    $text = [IO.File]::ReadAllText($template)
    if (-not $text.Contains($wingetSearch)) { throw "setup: winget search path not found in the template - test cannot substitute it" }

    # Nachgebautes winget: Zeilen wie das echte, Zustand ueber eine Umgebungsvariable.
    $fake = Join-Path $work 'winget.ps1'
    [IO.File]::WriteAllText($fake, @'
$state = $env:IW32H_FAKE_WINGET
$id = $args[$args.IndexOf('--id') + 1]
$header = 'Name          Id                  Version    Available  Source'
$line   = '-----------------------------------------------------------------'
if ($args[0] -eq 'list') {
    if ($state -eq 'absent') { 'Es wurde kein installiertes Paket gefunden, das den Eingabekriterien entspricht.'; exit 0 }
    $header; $line; ("Sample App    {0}    1.0.0      2.0.0      winget" -f $id)
}
elseif ($args[0] -eq 'upgrade') {
    if ($state -eq 'outdated') { $header; $line; ("Sample App    {0}    1.0.0      2.0.0      winget" -f $id); '1 Aktualisierungen verfuegbar.' }
    else { 'Es wurde kein verfuegbares Upgrade gefunden.' }
}
'@, (New-Object System.Text.UTF8Encoding $true))

    $rendered = Join-Path $work 'detection.ps1'
    $body = $text.Replace('WINGETPROGRAMID', $packageId).Replace($wingetSearch, $fake)
    [IO.File]::WriteAllText($rendered, $body, (New-Object System.Text.UTF8Encoding $true))

    $shell = (Get-Process -Id $PID).Path
    $cases = @(
        @{ State = 'current';  Expected = 0 }
        @{ State = 'outdated'; Expected = 1 }
        @{ State = 'absent';   Expected = 1 }
    )
    $savedPd = $env:ProgramData
    try {
        $env:ProgramData = $programData
        foreach ($c in $cases) {
            $env:IW32H_FAKE_WINGET = $c.State
            $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $rendered 2>&1
            $code = $LASTEXITCODE
            if ($code -ne $c.Expected) {
                $problems += ("{0}: exit {1}, expected {2} - output: {3}" -f $c.State, $code, $c.Expected, (($out | ForEach-Object { "$_" }) -join ' / '))
            }
        }
    }
    finally {
        $env:ProgramData = $savedPd
        Remove-Item Env:\IW32H_FAKE_WINGET -ErrorAction SilentlyContinue
    }
}
catch { $problems += $_.Exception.Message }
finally {
    foreach ($f in @(Get-ChildItem -LiteralPath $work -Recurse -File -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $f.FullName -Force }
    foreach ($d in @(Get-ChildItem -LiteralPath $work -Recurse -Directory -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)) { Remove-Item -LiteralPath $d.FullName -Force }
    Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue
}

if ($problems.Count -gt 0) {
    foreach ($pr in $problems) { Write-Host "FAIL: $pr" }
    exit 1
}
Write-Host "WinGet detection: installed+current -> 0, installed+outdated -> 1, absent -> 1. PASS"
exit 0
