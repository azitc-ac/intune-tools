<#
    .SYNOPSIS
    Verhaltenstest: Fehlermeldungen nennen die Stelle, von der sie kommen (Datei:Zeile).

    .DESCRIPTION
    "Cannot validate argument on parameter 'Path'" sagt nicht, welcher der vielen Aufrufe eines Laufs
    ihn ausgeloest hat (Muster aus SCCMAppHelper: Format-ErrorDetail). Geprueft wird:

      1. Format-ErrorDetail haengt "(<datei>:<zeile>)" aus dem ErrorRecord an die Meldung; ohne
         Fundstelle im Fehler bleibt die Meldung unveraendert.
      2. Der echte Weg: schlaegt das Lesen des Tenants fehl, steht die Fundstelle in der Ausgabe.
#>
$ErrorActionPreference = 'Stop'

$rootDir = Split-Path -Parent $PSScriptRoot
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $rootDir 'Functions\functions.ps1'), [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}

$problems = @()
function Test-That([bool]$condition, [string]$what) { if (-not $condition) { $script:problems += $what } }

# 1: die Funktion
$thrownAt = 0
try {
    $thrownAt = (Get-PSCallStack)[0].ScriptLineNumber + 1
    throw 'boom'
}
catch { $detail = Format-ErrorDetail $_ }
Test-That ($detail -eq ('boom (Test-ErrorDetail.ps1:{0})' -f $thrownAt)) "with a location: '$detail', expected 'boom (Test-ErrorDetail.ps1:$thrownAt)'"

$bare = New-Object System.Management.Automation.ErrorRecord ([System.Exception]'no place'), 'id', 'NotSpecified', $null
Test-That ((Format-ErrorDetail $bare) -eq 'no place') "without a location: '$(Format-ErrorDetail $bare)'"

# 2: der echte Weg - das Lesen des Tenants scheitert
$global:AuthenticationHeader = @{ Authorization = 'Bearer x' }
function Invoke-RestMethod { param($Uri, $Headers, $Method, $Body, $ContentType, $ErrorAction) throw 'graph said no' }
$lines = @(Read-TenantWin32Apps 6>&1 | ForEach-Object { [string]$_ })
$msg = ($lines | Where-Object { $_ -like '*graph said no*' }) -join ' | '
Test-That ($msg -match 'graph said no \(\S+\.ps1:\d+\)') "the failure of the tenant read has no place in it: '$msg'"

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { [Console]::WriteLine("FAIL: $p") }
    exit 1
}
[Console]::WriteLine('Error detail: messages carry file and line of the failing call, also on the real tenant-read path. PASS')
exit 0
