<#
    Hilfsdatei fuer die Tests: der Syntaxbaum ALLER Funktionen, die Functions\functions.ps1 laedt.

    Die Funktionen liegen nach Aufgabe in mehreren Dateien; functions.ps1 ist nur der Lader. Die Tests
    holen sich einzelne Funktionen per Syntaxbaum (ohne die Datei auszufuehren) - das tun sie ueber diese
    Funktion, damit keine Liste der Dateien in jedem Test steht. Die Liste ist die des Laders.
#>
function Get-ToolFunctionsAst {
    param([Parameter(Mandatory = $true)][string]$FunctionsDir)

    $loader = [System.IO.File]::ReadAllText((Join-Path $FunctionsDir 'functions.ps1'))
    $names = @([regex]::Matches($loader, '(?m)^\.\s+"\$PSScriptRoot\\([\w-]+\.ps1)"') | ForEach-Object { $_.Groups[1].Value })
    if ($names.Count -eq 0) { throw "functions.ps1 laedt keine Datei - der Lader ist leer oder anders geschrieben" }
    $text = ($names | ForEach-Object { [System.IO.File]::ReadAllText((Join-Path $FunctionsDir $_)) }) -join "`r`n"
    return [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
}
