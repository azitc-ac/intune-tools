<#
    .SYNOPSIS
    Struktur- und Syntaxpruefungen fuer IntuneWin32Helper.

    .DESCRIPTION
    Jede Pruefung hier gehoert zu einem Fehler, der dieses Repo schon einmal
    getroffen hat. Sie ist absichtlich ausfuehrbar und nicht nur dokumentiert:
    ein Merksatz haelt nicht, ein fehlschlagender Check schon.

    Baut man einen der Fehler zurueck, MUSS dieses Skript fehlschlagen.

    .EXAMPLE
    .\Tests\Invoke-RepoChecks.ps1
    Prueft das Repo und beendet mit Exit-Code 1, wenn etwas gefunden wurde.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot
)

# Nicht als Default im param()-Block: dort ist $PSScriptRoot unter Windows
# PowerShell 5.1 leer, wenn das Skript per "powershell.exe -File" laeuft - genau
# so ruft es der pre-commit-Hook auf. Siehe Pruefung 25.
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.ArrayList
$checked  = 0

function Add-Failure {
    param([string]$Check, [string]$Detail)
    $null = $failures.Add([PSCustomObject]@{ Check = $Check; Detail = $Detail })
}

function Test-ResultAssigned {
    # Wird das Ergebnis des Knotens einer Variablen zugewiesen? Folgt dabei
    # Scriptbloecken - siehe Pruefung 10.
    param($Node, $Ast)
    $n = $Node.Parent
    while ($n -ne $null) {
        if ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) { return $true }
        if ($n -is [System.Management.Automation.Language.StatementBlockAst]) { return $false }
        if ($n -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
            $holder = $n.Parent
            # { ... } als Argument eines Befehls (Invoke-IntuneModuleCall -Operation { ... })
            if ($holder -is [System.Management.Automation.Language.CommandAst]) {
                if ($holder.GetCommandName() -ne 'Invoke-IntuneModuleCall') { return $false }
                return (Test-ResultAssigned -Node $holder -Ast $Ast)
            }
            # $x = { ... }: jeder Aufruf "& $x" muss zugewiesen sein
            $assign = $n.Parent
            while ($assign -ne $null -and -not ($assign -is [System.Management.Automation.Language.AssignmentStatementAst])) {
                if ($assign -is [System.Management.Automation.Language.StatementBlockAst]) { return $false }
                $assign = $assign.Parent
            }
            if (-not $assign -or -not ($assign.Left -is [System.Management.Automation.Language.VariableExpressionAst])) { return $false }
            $name = $assign.Left.VariablePath.UserPath
            $calls = @($Ast.FindAll({
                param($c)
                $c -is [System.Management.Automation.Language.CommandAst] -and
                $c.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and
                $c.CommandElements[0] -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $c.CommandElements[0].VariablePath.UserPath -eq $name
            }, $true))
            if ($calls.Count -eq 0) { return $false }
            foreach ($c in $calls) {
                if (-not (Test-ResultAssigned -Node $c -Ast $Ast)) { return $false }
            }
            return $true
        }
        $n = $n.Parent
    }
    return $false
}

$psFiles = Get-ChildItem -Path $RepoRoot -Filter *.ps1 -Recurse -File |
    Where-Object { $_.FullName -notmatch '\\\.git\\' }

if (-not $psFiles) { throw "No .ps1 files found under $RepoRoot" }

# Einmal parsen, Ergebnisse fuer alle Pruefungen wiederverwenden.
$parsed = @{}
foreach ($file in $psFiles) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    $parsed[$file.FullName] = [PSCustomObject]@{
        File = $file; Ast = $ast; Tokens = $tokens; Errors = $errors
    }
}

# ---------------------------------------------------------------------------
# 1) Syntax. Faengt z.B. "$_ -isnot [int]]" - eine doppelte Klammer machte das
#    komplette deploy.ps1 unausfuehrbar, ohne dass es beim Lesen auffiel.
# ---------------------------------------------------------------------------
foreach ($p in $parsed.Values) {
    $checked++
    if ($p.Errors -and $p.Errors.Count -gt 0) {
        foreach ($e in $p.Errors) {
            Add-Failure "Syntax" ("{0}:{1} {2}" -f $p.File.Name, $e.Extent.StartLineNumber, $e.Message)
        }
    }
}

# ---------------------------------------------------------------------------
# 2) BOM. Alle Skripte dieses Repos sind UTF-8 MIT BOM; ohne BOM liest
#    Windows PowerShell 5.1 Umlaute als Mojibake.
# ---------------------------------------------------------------------------
foreach ($file in $psFiles) {
    $checked++
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
        Add-Failure "BOM" ("{0} hat keinen UTF-8-BOM" -f $file.Name)
    }
}

# ---------------------------------------------------------------------------
# 3) Unterdrueckte .Add()-Rueckgaben. UIElementCollection.Add() gibt den
#    Einfuege-Index zurueck. Unterdrueckt man ihn in einer Funktion nicht,
#    landen int-Werte im Rueckgabewert und vermischen sich mit der Auswahl -
#    genau der Grund fuer die frueheren "-isnot [int]"-Filter.
#    Geprueft wird ueber die AST, nicht per Text: Kommentare zaehlen nicht.
# ---------------------------------------------------------------------------
foreach ($p in $parsed.Values) {
    $checked++
    $pipelines = $p.Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.PipelineAst]
    }, $true)

    foreach ($pipe in $pipelines) {
        # Nur Pipelines, deren Wert verworfen wird (direkt als Statement).
        if ($pipe.Parent -isnot [System.Management.Automation.Language.StatementBlockAst] -and
            $pipe.Parent -isnot [System.Management.Automation.Language.NamedBlockAst]) { continue }
        if ($pipe.PipelineElements.Count -ne 1) { continue }

        $el = $pipe.PipelineElements[0]
        if ($el -isnot [System.Management.Automation.Language.CommandExpressionAst]) { continue }

        $expr = $el.Expression
        if ($expr -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst]) { continue }
        if ($expr.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
        if ($expr.Member.Value -ne "Add") { continue }

        Add-Failure "AddNotSuppressed" ("{0}:{1} {2} - Rueckgabe nicht unterdrueckt ([void] davor setzen)" -f `
            $p.File.Name, $expr.Extent.StartLineNumber, $expr.Extent.Text)
    }
}

# ---------------------------------------------------------------------------
# 4) Kein Out-GridView. ogv braucht einen STA-Host, fehlt in PowerShell 7 ohne
#    Zusatzmodul und passt nicht zu den WPF-Dialogen des Tools. Geprueft wird
#    ueber die Token, damit erklaerende Kommentare nicht anschlagen.
# ---------------------------------------------------------------------------
foreach ($p in $parsed.Values) {
    $checked++
    foreach ($t in $p.Tokens) {
        if ($t.Kind -ne [System.Management.Automation.Language.TokenKind]::Generic -and
            $t.Kind -ne [System.Management.Automation.Language.TokenKind]::Identifier) { continue }
        if ($t.Text -in @("ogv", "Out-GridView")) {
            Add-Failure "OutGridView" ("{0}:{1} verwendet {2}" -f $p.File.Name, $t.Extent.StartLineNumber, $t.Text)
        }
    }
}

# ---------------------------------------------------------------------------
# 5) Aufrufe passen zu den Signaturen. "Open-SelectDialog -size small" lief ins
#    Leere, weil nur Open-SelectDialogWithEdit ein -size hatte. So etwas faellt
#    erst zur Laufzeit auf - hier faellt es sofort auf.
# ---------------------------------------------------------------------------
$funcParams = @{}
foreach ($p in $parsed.Values) {
    $defs = $p.Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)
    foreach ($d in $defs) {
        $names = @()
        $pb = $d.Body.ParamBlock
        if ($pb) { foreach ($par in $pb.Parameters) { $names += $par.Name.VariablePath.UserPath } }
        elseif ($d.Parameters) { foreach ($par in $d.Parameters) { $names += $par.Name.VariablePath.UserPath } }
        $funcParams[$d.Name] = $names
    }
}

$commonParams = @(
    "Verbose","Debug","ErrorAction","WarningAction","InformationAction","ErrorVariable",
    "WarningVariable","InformationVariable","OutVariable","OutBuffer","PipelineVariable",
    "WhatIf","Confirm"
)

foreach ($p in $parsed.Values) {
    $checked++
    $commands = $p.Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst]
    }, $true)

    foreach ($cmd in $commands) {
        $name = $cmd.GetCommandName()
        if (-not $name) { continue }
        if (-not $funcParams.ContainsKey($name)) { continue }

        $known = @($funcParams[$name]) + $commonParams

        foreach ($element in $cmd.CommandElements) {
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            $used = $element.ParameterName

            # PowerShell erlaubt eindeutige Abkuerzungen - Praefix genuegt.
            $match = $known | Where-Object { $_ -like ($used + "*") }
            if (-not $match) {
                Add-Failure "UnknownParameter" ("{0}:{1} {2} -{3} - kein solcher Parameter" -f `
                    $p.File.Name, $element.Extent.StartLineNumber, $name, $used)
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 6) Der Tenant laeuft ueber EINEN Pfad. Frueher fragte jedes erzeugte
#    deploy.ps1 selbst - im Bulk-Lauf also pro App erneut.
# ---------------------------------------------------------------------------
$checked++
$templatePath = Join-Path (Join-Path $RepoRoot "Templates") "deploy_template.ps1"
if (-not (Test-Path -LiteralPath $templatePath)) {
    Add-Failure "TenantOnePath" "Templates\deploy_template.ps1 fehlt"
}
else {
    $tpl = $parsed[(Get-Item -LiteralPath $templatePath).FullName]

    $hasTenantParam = $false
    if ($tpl.Ast.ParamBlock) {
        $hasTenantParam = [bool]($tpl.Ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq "Tenant" })
    }
    if (-not $hasTenantParam) {
        Add-Failure "TenantOnePath" "deploy_template.ps1 hat keinen Parameter -Tenant - ein Bulk-Lauf fragt sonst pro App"
    }

    $callsInit = $tpl.Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq "Initialize-IntuneConnection"
    }, $true)
    if (-not $callsInit) {
        Add-Failure "TenantOnePath" "deploy_template.ps1 ruft Initialize-IntuneConnection nicht auf"
    }

    $connects = $tpl.Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq "Connect-MSIntuneGraph"
    }, $true)
    if ($connects) {
        Add-Failure "TenantOnePath" ("deploy_template.ps1 ruft Connect-MSIntuneGraph direkt auf (Zeile {0}) - das gehoert in Initialize-IntuneConnection" -f `
            $connects[0].Extent.StartLineNumber)
    }
}

# ---------------------------------------------------------------------------
# 7) break/continue nur innerhalb einer Schleife (oder eines switch) derselben
#    Funktion. Ein break ohne eigene Schleife bricht die Schleife des AUFRUFERS
#    ab: in deployApps schloss "Cancel" dadurch das komplette Tool.
# ---------------------------------------------------------------------------
$loopTypes = @(
    [System.Management.Automation.Language.ForEachStatementAst],
    [System.Management.Automation.Language.ForStatementAst],
    [System.Management.Automation.Language.WhileStatementAst],
    [System.Management.Automation.Language.DoWhileStatementAst],
    [System.Management.Automation.Language.DoUntilStatementAst],
    [System.Management.Automation.Language.SwitchStatementAst]
)

foreach ($p in $parsed.Values) {
    $checked++
    $funcs = $p.Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)

    foreach ($fn in $funcs) {
        $jumps = $fn.Body.FindAll({
            param($n)
            ($n -is [System.Management.Automation.Language.BreakStatementAst]) -or
            ($n -is [System.Management.Automation.Language.ContinueStatementAst])
        }, $true)

        foreach ($jump in $jumps) {
            # Ein Label bezeichnet eine Schleife ausdruecklich - das ist Absicht.
            if ($jump.Label) { continue }

            $node = $jump.Parent
            $inLoop = $false
            while ($node -ne $null -and $node -ne $fn) {
                foreach ($lt in $loopTypes) {
                    if ($node -is $lt) { $inLoop = $true; break }
                }
                if ($inLoop) { break }
                # Verschachtelte Funktion: ab hier zaehlt deren Rahmen, nicht der aeussere.
                if ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) { break }
                $node = $node.Parent
            }

            if (-not $inLoop) {
                Add-Failure "BreakOutsideLoop" ("{0}:{1} {2} enthaelt '{3}' ohne eigene Schleife - bricht die Schleife des Aufrufers ab (return verwenden)" -f `
                    $p.File.Name, $jump.Extent.StartLineNumber, $fn.Name, $jump.Extent.Text.Trim())
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 8) Konfiguration nur ueber Get-ToolConfig. Frueher las jedes Skript die
#    config.json selbst - Pfad, Kodierung und das Anlegen der Datei drifteten
#    dadurch auseinander. Zusaetzlich muss Config/config.json ignoriert sein:
#    sie nimmt clientSecret im Klartext auf.
# ---------------------------------------------------------------------------
$enclosingFunction = {
    param($node)
    $n = $node
    while ($n -ne $null) {
        if ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $n.Name }
        $n = $n.Parent
    }
    return ""
}

foreach ($p in $parsed.Values) {
    $checked++
    $commands = $p.Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst]
    }, $true)

    foreach ($cmd in $commands) {
        $name = $cmd.GetCommandName()
        if ($name -ne "Get-Content") { continue }
        if ($cmd.Extent.Text -notmatch 'config\.json') { continue }

        $fn = & $enclosingFunction $cmd
        if ($fn -ne "Get-ToolConfig") {
            Add-Failure "ConfigOnePath" ("{0}:{1} liest config.json direkt (in '{2}') - Get-ToolConfig verwenden" -f `
                $p.File.Name, $cmd.Extent.StartLineNumber, $fn)
        }
    }
}

$checked++
$gitignorePath = Join-Path $RepoRoot ".gitignore"
if (-not (Test-Path -LiteralPath $gitignorePath)) {
    Add-Failure "ConfigOnePath" ".gitignore fehlt - Config/config.json wuerde mit clientSecret versioniert"
}
else {
    $ignored = Get-Content -LiteralPath $gitignorePath | ForEach-Object { $_.Trim() }
    if ($ignored -notcontains "Config/config.json") {
        Add-Failure "ConfigOnePath" ".gitignore listet Config/config.json nicht - clientSecret koennte committet werden"
    }
}

$checked++
$samplePath = Join-Path (Join-Path $RepoRoot "Config") "config.sample.json"
if (-not (Test-Path -LiteralPath $samplePath)) {
    Add-Failure "ConfigOnePath" "Config\config.sample.json fehlt - ein frischer Clone kann keine config.json erzeugen"
}

# ---------------------------------------------------------------------------
# 9) Sitzungsprotokoll nur ueber Start-ToolTranscript. Das Logs-Verzeichnis ist
#    nicht versioniert; der Helfer legt es an, statt sich auf das
#    versionsabhaengige Verhalten von Start-Transcript zu verlassen.
# ---------------------------------------------------------------------------
foreach ($p in $parsed.Values) {
    $checked++
    $commands = $p.Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq "Start-Transcript"
    }, $true)

    foreach ($cmd in $commands) {
        $fn = & $enclosingFunction $cmd
        if ($fn -ne "Start-ToolTranscript") {
            Add-Failure "TranscriptOnePath" ("{0}:{1} ruft Start-Transcript direkt auf (in '{2}') - Start-ToolTranscript verwenden" -f `
                $p.File.Name, $cmd.Extent.StartLineNumber, $fn)
        }
    }
}

# ---------------------------------------------------------------------------
# 10) Das Ergebnis von Add-IntuneWin32App muss aufgefangen werden, und jeder
#     Aufruf muss -Notes setzen.
#     Hintergrund: Bei fehlgeschlagenem Upload oder Commit wirft
#     Add-IntuneWin32App keine Exception, sondern warnt nur und gibt $null
#     zurueck. Ein Lauf meldete dadurch "Finished.", obwohl die App ohne Inhalt
#     in Intune lag. Und von den drei Aufrufen setzten nur zwei -Notes - genau
#     der dritte (keine bestehende App) lief in der Praxis.
# ---------------------------------------------------------------------------
foreach ($p in $parsed.Values) {
    $checked++
    $adds = $p.Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq "Add-IntuneWin32App"
    }, $true)

    foreach ($add in $adds) {
        # Rueckgabe auffangen: die Pipeline muss einer Variablen zugewiesen sein.
        # Seit Pruefung 26 steckt der Aufruf in Scriptblöcken
        # ($x = { Invoke-IntuneModuleCall -Operation { Add-IntuneWin32App ... } }).
        # Die Zuweisung des BLOCKS an $x ist keine Zuweisung des ERGEBNISSES -
        # so erfuellte sich diese Pruefung einmal leer. Deshalb: ein Scriptblock
        # als -Operation reicht das Ergebnis an Invoke-IntuneModuleCall weiter
        # (dort weitersuchen); ein einer Variablen zugewiesener Block zaehlt nur,
        # wenn JEDER Aufruf "& $x" selbst zugewiesen wird.
        $assigned = Test-ResultAssigned -Node $add -Ast $p.Ast
        if (-not $assigned) {
            Add-Failure "AddResultChecked" ("{0}:{1} Rueckgabe von Add-IntuneWin32App wird verworfen - bei Fehlschlag gibt es nur eine Warnung, kein Abbruch" -f `
                $p.File.Name, $add.Extent.StartLineNumber)
        }

        $hasNotes = $false
        foreach ($element in $add.CommandElements) {
            if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and
                $element.ParameterName -eq "Notes") { $hasNotes = $true }
        }
        if (-not $hasNotes) {
            Add-Failure "NotesOnAdd" ("{0}:{1} Add-IntuneWin32App ohne -Notes - die anderen Aufrufe setzen es" -f `
                $p.File.Name, $add.Extent.StartLineNumber)
        }
    }
}

# ---------------------------------------------------------------------------
# 11) Das erzeugte deploy.ps1 darf "Finished." nicht bedingungslos melden.
#     Vor der Meldung muss das Upload-Ergebnis geprueft werden.
# ---------------------------------------------------------------------------
$checked++
if (Test-Path -LiteralPath $templatePath) {
    $tplAst = $parsed[(Get-Item -LiteralPath $templatePath).FullName].Ast

    $throwsOnFailure = $tplAst.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.ThrowStatementAst] -and
        $n.Extent.Text -match 'uploadResult|FAILED'
    }, $true)

    $guard = $tplAst.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.IfStatementAst] -and
        $n.Extent.Text -match '\$uploadResult'
    }, $true)

    if (-not $guard -or -not $throwsOnFailure) {
        Add-Failure "FinishedNotUnconditional" 'deploy_template.ps1 prueft $uploadResult nicht, bevor es "Finished." meldet - ein fehlgeschlagener Upload bleibt unsichtbar'
    }
}

# ---------------------------------------------------------------------------
# 12) Keine fest verdrahteten Benutzerpfade. Das Startskript trug den
#     OneDrive-Pfad eines einzelnen Rechners als Fallback - auf jeder anderen
#     Maschine zeigt er ins Leere.
# ---------------------------------------------------------------------------
foreach ($p in $parsed.Values) {
    $checked++
    $strings = $p.Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
    }, $true)

    foreach ($s in $strings) {
        if ($s.Value -match '^[A-Za-z]:\\Users\\') {
            Add-Failure "NoHardcodedUserPath" ("{0}:{1} fest verdrahteter Benutzerpfad: {2}" -f `
                $p.File.Name, $s.Extent.StartLineNumber, $s.Value)
        }
    }
}

# ---------------------------------------------------------------------------
# 13) Rekursives Loeschen nur ueber Remove-PackageFolder. Der Paketpfad wird aus
#     CSV-Feldern gebaut; sind sie leer, zeigt er auf die Paketwurzel selbst.
#     Remove-PackageFolder prueft das, ein nacktes "del -Recurse" nicht.
# ---------------------------------------------------------------------------
foreach ($p in $parsed.Values) {
    $checked++
    $deletes = $p.Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -in @("Remove-Item", "del", "erase", "rd", "ri", "rmdir")
    }, $true)

    foreach ($d in $deletes) {
        $recurse = $false
        foreach ($element in $d.CommandElements) {
            if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and
                $element.ParameterName -like "Recurse*") { $recurse = $true }
        }
        if (-not $recurse) { continue }

        $fn = & $enclosingFunction $d
        if ($fn -ne "Remove-PackageFolder") {
            Add-Failure "RecursiveDeleteGuarded" ("{0}:{1} rekursives Loeschen in '{2}' statt ueber Remove-PackageFolder" -f `
                $p.File.Name, $d.Extent.StartLineNumber, $fn)
        }
    }
}

# ---------------------------------------------------------------------------
# 14) Das temporaere subst-Laufwerk muss in einem finally freigegeben werden.
#     Bricht das Packen ab, blieb der Laufwerksbuchstabe sonst bis zum Abmelden
#     belegt und jeder Lauf verbrauchte den naechsten.
# ---------------------------------------------------------------------------
$checked++
if (Test-Path -LiteralPath $templatePath) {
    $tplAst2 = $parsed[(Get-Item -LiteralPath $templatePath).FullName].Ast

    $substCalls = $tplAst2.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq "subst"
    }, $true)

    # Der Freigabe-Aufruf ist der mit /d
    $release = @($substCalls | Where-Object { $_.Extent.Text -match '/d\b' })

    if (@($release).Count -eq 0) {
        Add-Failure "SubstReleasedInFinally" "deploy_template.ps1 gibt das subst-Laufwerk nirgends frei (subst <drive> /d fehlt)"
    }
    foreach ($r in $release) {
        $inFinally = $false
        $node = $r.Parent
        while ($node -ne $null) {
            if ($node -is [System.Management.Automation.Language.TryStatementAst]) {
                if ($node.Finally -and $node.Finally.Extent.Text.Contains($r.Extent.Text)) { $inFinally = $true }
                break
            }
            $node = $node.Parent
        }
        if (-not $inFinally) {
            Add-Failure "SubstReleasedInFinally" ("deploy_template.ps1:{0} 'subst /d' liegt nicht in einem finally - bricht das Packen ab, bleibt das Laufwerk belegt" -f `
                $r.Extent.StartLineNumber)
        }
    }
}

# ---------------------------------------------------------------------------
# 15) VERSION-Datei. Die Version stand fest im Startskript und wanderte als
#     "Created by IntuneWin32Helper 2.0" in jede erzeugte App - jede Version
#     behauptete dasselbe. Jetzt liest das Startskript VERSION, die der
#     pre-commit-Hook je Tool hebt. Geprueft wird: die Datei existiert, hat eine
#     Zeile, endet auf einer Zahl, und das Startskript liest sie auch.
# ---------------------------------------------------------------------------
$checked++
$versionPath = Join-Path $RepoRoot "VERSION"
if (-not (Test-Path -LiteralPath $versionPath)) {
    Add-Failure "VersionFile" "VERSION fehlt - der pre-commit-Hook kann die Version dieses Tools nicht heben"
}
else {
    $versionLines = @(Get-Content -LiteralPath $versionPath)
    if ($versionLines.Count -ne 1) {
        Add-Failure "VersionFile" ("VERSION hat {0} Zeilen, erwartet genau eine" -f $versionLines.Count)
    }
    $versionText = ([string]$versionLines[0]).Trim()
    if ($versionText -notmatch '\.\d+$') {
        Add-Failure "VersionFile" ("VERSION enthaelt '{0}' und endet nicht auf '.<Zahl>' - der Hook koennte sie nicht heben" -f $versionText)
    }
}

$checked++
$starters = @($psFiles | Where-Object { $_.Name -like "start-*.ps1" })
foreach ($starter in $starters) {
    $starterAst = $parsed[$starter.FullName].Ast
    if ($starterAst.Extent.Text -notmatch "'VERSION'|""VERSION""") {
        Add-Failure "VersionFile" ("{0} liest die VERSION-Datei nicht - eine fest verdrahtete Version stempelt jeden Build gleich" -f $starter.Name)
    }
}

# ---------------------------------------------------------------------------
# 16) Keine Syntax, die Windows PowerShell 5.1 nicht parst. Uebernommen aus
#     Test-GroupAppAssignment.ps1. Das Tool laeuft auf 5.1; ??, ?., &&, || und
#     der Ternaeroperator kommen erst mit PowerShell 7 und liefern dort einen
#     Parse-Fehler, also gar keinen Lauf.
# ---------------------------------------------------------------------------
$ps7OnlyKinds = @(
    'QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot',
    'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark'
)
foreach ($p in $parsed.Values) {
    $checked++
    foreach ($token in $p.Tokens) {
        if ($ps7OnlyKinds -contains $token.Kind.ToString()) {
            Add-Failure "NoPs7OnlySyntax" ("{0}:{1} '{2}' gibt es erst in PowerShell 7 - unter 5.1 ein Parse-Fehler" -f `
                $p.File.Name, $token.Extent.StartLineNumber, $token.Text)
        }
    }
}

# ---------------------------------------------------------------------------
# 17) Kein Upload von App-Logos zu Dritten. Ein Logo, dessen URL nicht auf .png
#     endete, ging zu Cloudinary - mit leeren Zugangsdaten (wie in
#     config.sample.json) brach dabei der Paketbau ab. Geprueft ueber
#     String-Literale, damit ein erklaerender Kommentar nicht anschlaegt.
# ---------------------------------------------------------------------------
foreach ($p in $parsed.Values) {
    $checked++
    # Dieses Prüfskript selbst nennt die verbotenen Namen als Suchmuster - es
    # würde sich sonst selbst melden.
    if ($p.File.FullName -eq $PSCommandPath) { continue }

    $literals = $p.Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
    }, $true)
    foreach ($s in $literals) {
        if ($s.Value -match 'cloudinary') {
            Add-Failure "NoThirdPartyUpload" ("{0}:{1} verweist auf Cloudinary: {2}" -f `
                $p.File.Name, $s.Extent.StartLineNumber, $s.Value)
        }
    }

    $funcs = $p.Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)
    foreach ($fn in $funcs) {
        if ($fn.Name -match 'Cloudinary') {
            Add-Failure "NoThirdPartyUpload" ("{0}:{1} Funktion {2} lädt Logos zu einem Drittanbieter" -f `
                $p.File.Name, $fn.Extent.StartLineNumber, $fn.Name)
        }
    }
}

# ---------------------------------------------------------------------------
# 18) Logos laufen ueber Resolve-PackageLogo, und das normalisiert. Vorher lag
#     Herunterladen und Umwandeln offen im Ablauf von createApps und konnte den
#     Paketbau abbrechen; Logos gingen ausserdem unveraendert ins Paket -
#     defaultlogo.png allein mit 632 KB.
# ---------------------------------------------------------------------------
foreach ($p in $parsed.Values) {
    $checked++
    $requests = $p.Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Invoke-WebRequest'
    }, $true)
    foreach ($r in $requests) {
        $fn = & $enclosingFunction $r
        if ($fn -ne 'Resolve-PackageLogo') {
            Add-Failure "LogoOnePath" ("{0}:{1} Invoke-WebRequest in '{2}' - Logos laufen über Resolve-PackageLogo" -f `
                $p.File.Name, $r.Extent.StartLineNumber, $fn)
        }
    }
}

$checked++
$functionsFile = $parsed.Values | Where-Object { $_.File.Name -eq 'functions.ps1' } | Select-Object -First 1
if ($functionsFile) {
    $resolve = $functionsFile.Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -eq 'Resolve-PackageLogo'
    }, $true)
    if (-not $resolve) {
        Add-Failure "LogoOnePath" "Resolve-PackageLogo fehlt - ohne sie kann der Logo-Pfad den Paketbau wieder abbrechen"
    }
    elseif ($resolve[0].Extent.Text -notmatch 'Resize-IconFile') {
        Add-Failure "LogoOnePath" "Resolve-PackageLogo ruft Resize-IconFile nicht auf - Logos gingen unveraendert ins Paket"
    }
}

# ---------------------------------------------------------------------------
# 19) Die Requirement Rule kommt je App aus Apps.csv. Bisher bekam JEDE App
#     x64 und W10_20H2 fest verdrahtet: auf ARM64 kam nichts an, und eine App,
#     die ein neueres Windows braucht, wurde trotzdem angeboten.
# ---------------------------------------------------------------------------
$checked++
if (Test-Path -LiteralPath $templatePath) {
    $tplAst3 = $parsed[(Get-Item -LiteralPath $templatePath).FullName].Ast
    $rules = $tplAst3.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'New-IntuneWin32AppRequirementRule'
    }, $true)

    if (-not $rules) {
        Add-Failure "RequirementRulePerApp" "deploy_template.ps1 baut keine Requirement Rule mehr"
    }
    foreach ($rule in $rules) {
        $elements = @($rule.CommandElements)
        for ($i = 0; $i -lt $elements.Count - 1; $i++) {
            $element = $elements[$i]
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            if ($element.ParameterName -notin @('Architecture', 'MinimumSupportedOperatingSystem')) { continue }
            $value = $elements[$i + 1]
            if ($value -isnot [System.Management.Automation.Language.VariableExpressionAst]) {
                Add-Failure "RequirementRulePerApp" ("deploy_template.ps1:{0} -{1} ist fest verdrahtet ({2}) statt aus Apps.csv" -f `
                    $rule.Extent.StartLineNumber, $element.ParameterName, $value.Extent.Text)
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 20) Pfadlaengen werden gemeldet. Beim Packen faellt nichts auf, weil die
#     Quelle per subst kurz ist; auf dem Client entscheidet der IMECache-Pfad,
#     und der Fehler lautet dort "Datei nicht gefunden".
# ---------------------------------------------------------------------------
$checked++
if (Test-Path -LiteralPath $templatePath) {
    $tplAst4 = $parsed[(Get-Item -LiteralPath $templatePath).FullName].Ast
    $warn = $tplAst4.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Write-PackagePathWarning'
    }, $true)
    if (-not $warn) {
        Add-Failure "PathLengthReported" "deploy_template.ps1 ruft Write-PackagePathWarning nicht auf - zu lange Pfade fallen erst auf dem Client auf"
    }
}

# ---------------------------------------------------------------------------
# 21) Die WinGet-Erkennung prueft die Version mit. "winget list" allein meldet
#     die App, sobald die ID vorhanden ist - eine veraltete Fassung galt damit
#     als aktuell und wurde nie erneuert.
# ---------------------------------------------------------------------------
$checked++
$wingetDetection = Join-Path (Join-Path $RepoRoot "Templates") "detection_template-WinGetApp.ps1"
if (-not (Test-Path -LiteralPath $wingetDetection)) {
    Add-Failure "WingetDetectionChecksVersion" "Templates\detection_template-WinGetApp.ps1 fehlt"
}
else {
    $wgText = Get-Content -LiteralPath $wingetDetection -Raw
    if ($wgText -notmatch 'upgrade\s+--id') {
        Add-Failure "WingetDetectionChecksVersion" "detection_template-WinGetApp.ps1 fragt 'winget upgrade' nicht ab - die Erkennung ist damit versionsblind"
    }
}

# ---------------------------------------------------------------------------
# 22) Bei einem MSI wird nativ ueber den ProductCode erkannt. Vorher lief JEDE
#     App ueber ein Erkennungsskript - auch die, deren ProductCode schon
#     vorliegt. Nativ prueft der Client selbst: kein PowerShell-Host, kein
#     Timeout, und kein Skript, das bei einem Fehler "nicht installiert" meldet.
# ---------------------------------------------------------------------------
$checked++
if (Test-Path -LiteralPath $templatePath) {
    $tplAst5 = $parsed[(Get-Item -LiteralPath $templatePath).FullName].Ast

    $msiRules = $tplAst5.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'New-IntuneWin32AppDetectionRuleMSI'
    }, $true)
    if (-not $msiRules) {
        Add-Failure "MsiDetectionNative" "deploy_template.ps1 baut keine native MSI-Erkennung - ein vorliegender ProductCode bleibt ungenutzt"
    }

    # Die native Regel muss an den ProductCode gebunden sein, sonst bekaeme auch
    # eine App ohne MSI eine MSI-Regel.
    # Die BEDINGUNG muss den ProductCode pruefen, nicht irgendeine Stelle im
    # Block: $MsiProductCode steht auch als Argument darin, ein "if ($true)"
    # waere sonst durchgegangen. (Genau das hat die Gegenprobe gezeigt.)
    $guarded = $tplAst5.FindAll({
        param($n)
        if ($n -isnot [System.Management.Automation.Language.IfStatementAst]) { return $false }
        if ($n.Extent.Text -notmatch 'New-IntuneWin32AppDetectionRuleMSI') { return $false }
        foreach ($clause in $n.Clauses) {
            if ($clause.Item1.Extent.Text -match '\$MsiProductCode') { return $true }
        }
        return $false
    }, $true)
    if ($msiRules -and -not $guarded) {
        Add-Failure "MsiDetectionNative" 'die native MSI-Erkennung haengt nicht an $MsiProductCode - Apps ohne MSI bekaemen sie auch'
    }

    # Der Skript-Weg muss als Rueckfall erhalten bleiben.
    $scriptRules = $tplAst5.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'New-IntuneWin32AppDetectionRuleScript'
    }, $true)
    if (-not $scriptRules) {
        Add-Failure "MsiDetectionNative" "der Skript-Rueckfall fuer Nicht-MSI-Apps fehlt"
    }
}

# ---------------------------------------------------------------------------
# 23) Install- und Uninstall-Befehle werden abgeleitet, und die ISE wird nicht
#     mehr direkt aufgerufen. Vorher musste der Benutzer die Befehle von Hand
#     tippen; der Ablauf hielt dafuer zweimal mit "pause" an, womit
#     Massenerstellung fuer Nicht-WinGet-Apps konstruktiv unmoeglich war.
#     powershell_ise ist abgekuendigt und fehlt auf Server Core - daher nur
#     ueber Open-ScriptForEditing, das auf Notepad zurueckfaellt.
# ---------------------------------------------------------------------------
$checked++
if ($functionsFile) {
    foreach ($needed in 'Get-DerivedInstallCommands', 'Get-InstallerEngine', 'Find-PackageInstaller', 'Open-ScriptForEditing') {
        $found = $functionsFile.Ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq $needed
        }, $true)
        if (-not $found) {
            Add-Failure "InstallCommandsDerived" ("{0} fehlt - ohne sie muessen die Befehle wieder von Hand getippt werden" -f $needed)
        }
    }

    $usedInCreate = $functionsFile.Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Get-DerivedInstallCommands'
    }, $true)
    if (-not $usedInCreate) {
        Add-Failure "InstallCommandsDerived" "Get-DerivedInstallCommands wird nirgends aufgerufen - eine Funktion, die niemand benutzt"
    }
}

foreach ($p in $parsed.Values) {
    $checked++
    $ise = $p.Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -in @('powershell_ise', 'powershell_ise.exe')
    }, $true)
    foreach ($call in $ise) {
        $fn = & $enclosingFunction $call
        if ($fn -ne 'Open-ScriptForEditing') {
            Add-Failure "InstallCommandsDerived" ("{0}:{1} ruft powershell_ise direkt auf (in '{2}') - Open-ScriptForEditing verwenden" -f `
                $p.File.Name, $call.Extent.StartLineNumber, $fn)
        }
    }
}

# ---------------------------------------------------------------------------
# 24) Inventar und Vorlagen-Stempel. Ohne das war nicht sichtbar, welche
#     Definition kein Paket hat, welches Paket nicht veroeffentlicht ist,
#     welches aus einer aelteren Vorlage stammt und wo dieselbe App mehrfach in
#     Intune liegt. Der Stempel ist die Bedingung dafuer, die Artefakte
#     ueberhaupt im Paket lassen zu koennen: unveraenderlich ist nur brauchbar,
#     wenn man sieht, was nachgezogen werden sollte.
# ---------------------------------------------------------------------------
$checked++
if ($functionsFile) {
    foreach ($needed in 'Get-AppInventory', 'Get-TemplateFingerprint', 'Get-PackageTemplateFingerprint') {
        $found = $functionsFile.Ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq $needed
        }, $true)
        if (-not $found) {
            Add-Failure "InventoryAndFingerprint" ("{0} fehlt" -f $needed)
        }
    }

    # Das Hauptfenster muss das Inventar benutzen, nicht wieder nur die Ordnerliste.
    # Fehlt die Funktion, ist das ein Befund - nicht "nichts zu pruefen": die
    # Pruefung fuer deployApps ging so stillschweigend ins Leere, als es die
    # Funktion nicht mehr gab.
    $deploy = $functionsFile.Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -eq 'Start-InventoryLoop'
    }, $true)
    if (-not $deploy) {
        Add-Failure "InventoryAndFingerprint" "Start-InventoryLoop fehlt - ohne sie gibt es kein Hauptfenster"
    }
    elseif ($deploy[0].Extent.Text -notmatch 'Get-AppInventory') {
        Add-Failure "InventoryAndFingerprint" "Start-InventoryLoop benutzt Get-AppInventory nicht - die Liste zeigt dann wieder nur Ordner"
    }

    # Der Stempel muss beim Rendern ersetzt werden, sonst steht der Platzhalter
    # im Paket und jedes Paket gilt als ungestempelt.
    $write = $functionsFile.Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -eq 'Write-DeployScript'
    }, $true)
    if ($write -and $write[0].Extent.Text -notmatch 'Get-TemplateFingerprint') {
        Add-Failure "InventoryAndFingerprint" "Write-DeployScript setzt den Vorlagen-Stempel nicht - jedes Paket erschiene als ungestempelt"
    }
}

$checked++
if (Test-Path -LiteralPath $templatePath) {
    $tplText = Get-Content -LiteralPath $templatePath -Raw
    if ($tplText -notmatch '(?m)^#\s*ToolTemplateFingerprint:\s*#TPLFP#') {
        Add-Failure "InventoryAndFingerprint" "deploy_template.ps1 traegt die Zeile 'ToolTemplateFingerprint: #TPLFP#' nicht - ohne sie gibt es keinen Stempel zu vergleichen"
    }
}

# ---------------------------------------------------------------------------
# 25) Keine automatische Pfadvariable als Parameter-Default. Unter Windows
#     PowerShell 5.1 ist $PSScriptRoot (ebenso $PSCommandPath/$MyInvocation) im
#     param()-Block leer, wenn das Skript per "powershell.exe -File" startet.
#     Genau so ruft der pre-commit-Hook dieses Skript auf: es brach mit
#     "Split-Path: ... leere Zeichenfolge" ab, und unter Windows war damit jeder
#     Commit an IntuneWin32Helper blockiert. Unter pwsh 7 fiel es nie auf.
# ---------------------------------------------------------------------------
foreach ($p in $parsed.Values) {
    $checked++
    $params = $p.Ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.ParameterAst] -and $n.DefaultValue
    }, $true)
    foreach ($prm in $params) {
        $autoVars = $prm.DefaultValue.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
            @('PSScriptRoot', 'PSCommandPath', 'MyInvocation') -contains $n.VariablePath.UserPath
        }, $true)
        foreach ($v in $autoVars) {
            Add-Failure "NoAutoPathInParamDefault" ("{0}:{1} Default von {2} benutzt `${3} - unter 5.1 mit -File leer, im Rumpf setzen" -f `
                $p.File.Name, $prm.Extent.StartLineNumber, $prm.Name.Extent.Text, $v.VariablePath.UserPath)
        }
    }
}

# ---------------------------------------------------------------------------
# 26) Jedes Cmdlet des Moduls IntuneWin32App laeuft ueber
#     Invoke-IntuneModuleCall. Das Modul beendet Fehlerpfade mit "break" statt
#     throw; ohne umschliessende Schleife springt das break in die naechste
#     Schleife des AUFRUFERS. Im Feld hiess das: der Guard "Upload FAILED" im
#     deploy.ps1 lief nie, die foreach-Schleife in createApps/deployApps endete
#     stillschweigend (restliche Apps nicht versucht, Zusammenfassung
#     "0 succeeded, 0 failed"), und in deployApps haette es das Tool beendet.
#     try/catch faengt ein break nicht - nur eine Schleife tut das.
# ---------------------------------------------------------------------------
$moduleCmdPattern = '^(Add|Get|Update|New|Connect|Remove|Set|Expand|Test)-(IntuneWin32App\w*|MSIntuneGraph|AccessToken)$'
foreach ($p in $parsed.Values) {
    $checked++
    $calls = $p.Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -match $moduleCmdPattern
    }, $true)
    foreach ($call in $calls) {
        $wrapped = $false
        $n = $call.Parent
        while ($n -ne $null) {
            if ($n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
                $n.Parent -is [System.Management.Automation.Language.CommandAst] -and
                $n.Parent.GetCommandName() -eq 'Invoke-IntuneModuleCall') { $wrapped = $true; break }
            $n = $n.Parent
        }
        if (-not $wrapped) {
            Add-Failure "ModuleCallNoBreak" ("{0}:{1} {2} direkt aufgerufen - ein break des Moduls springt in die Schleife des Aufrufers; ueber Invoke-IntuneModuleCall aufrufen" -f `
                $p.File.Name, $call.Extent.StartLineNumber, $call.GetCommandName())
        }
    }
}

# Die Huelle selbst muss eine Schleife sein - sonst faengt sie kein break.
$checked++
if ($functionsFile) {
    $wrapper = $functionsFile.Ast.Find({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -eq 'Invoke-IntuneModuleCall'
    }, $true)
    if (-not $wrapper) {
        Add-Failure "ModuleCallNoBreak" "Invoke-IntuneModuleCall fehlt in functions.ps1"
    }
    elseif (-not $wrapper.Body.Find({ param($n) $n -is [System.Management.Automation.Language.LoopStatementAst] }, $true)) {
        Add-Failure "ModuleCallNoBreak" "Invoke-IntuneModuleCall ruft die Operation nicht in einer Schleife auf - ein break des Moduls wuerde nicht abgefangen"
    }
}

# ---------------------------------------------------------------------------
# 27) Kein -notlike / -notmatch auf der Ausgabe eines nativen Aufrufs.
#     "& winget.exe ..." liefert ein ARRAY von Zeilen. Auf einem Array filtert
#     -notlike: es liefert alle Zeilen OHNE Treffer (Kopfzeile, Trennlinie),
#     und das ist fast immer nicht leer, also wahr. So meldete die
#     WinGet-Erkennung seit c6eb0eb eine installierte App als "NOT found"
#     (Feld 2026-09-28). Treffer ausdruecklich zaehlen:
#     @($out | Where-Object { $_ -like ... }).Count
#     Geprueft je Gueltigkeitsbereich (Funktion bzw. Skript), damit eine
#     gleichnamige Variable einer anderen Funktion nicht zaehlt.
# ---------------------------------------------------------------------------
foreach ($p in $parsed.Values) {
    $checked++
    $negations = $p.Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.BinaryExpressionAst] -and
        $n.Operator.ToString() -match '^(I|C)?Not(Like|Match)$' -and
        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst]
    }, $true)
    foreach ($neg in $negations) {
        $scope = $neg.Parent
        while ($scope -ne $null -and -not ($scope -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and $scope.Parent -ne $null) {
            $scope = $scope.Parent
        }
        $name = $neg.Left.VariablePath.UserPath
        $fromNative = $scope.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $n.Left.VariablePath.UserPath -eq $name -and
            $n.Right -is [System.Management.Automation.Language.PipelineAst] -and
            $n.Right.PipelineElements[0] -is [System.Management.Automation.Language.CommandAst] -and
            $n.Right.PipelineElements[0].InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand
        }, $true)
        if (@($fromNative).Count -gt 0) {
            Add-Failure "NoNegatedMatchOnNativeOutput" ("{0}:{1} '{2}' - `${3} ist die Ausgabe eines nativen Aufrufs (Array); -not{4} filtert und ist fast immer wahr. Treffer zaehlen." -f `
                $p.File.Name, $neg.Extent.StartLineNumber, $neg.Extent.Text, $name, ($neg.Operator.ToString() -replace '^(I|C)?Not', ''))
        }
    }
}

# ---------------------------------------------------------------------------
# 28) Installiert wird als SYSTEM - dann muss auch alles dazu passen.
#     Feld 2026-09-28: das Inno-Setup von Greenshot installierte ohne /ALLUSERS
#     benutzerbezogen, also ins Profil von SYSTEM; der Benutzer hatte die App
#     nicht. Die Skript-Erkennung durchsuchte auch HKCU - als SYSTEM ist das die
#     Registry von SYSTEM - und meldete "installiert". Beides zusammen machte
#     den Fehler unsichtbar.
# ---------------------------------------------------------------------------
$checked++
$detectionTemplate = Join-Path $RepoRoot 'Templates\detection_template.ps1'
$installsAsSystem = (Test-Path -LiteralPath $templatePath) -and
    ((Get-Content -LiteralPath $templatePath -Raw) -match '-InstallExperience\s+"system"')
if ($installsAsSystem) {
    if (Test-Path -LiteralPath $detectionTemplate) {
        $detAst = $parsed[(Get-Item -LiteralPath $detectionTemplate).FullName].Ast
        $hkcu = $detAst.FindAll({
            param($n)
            ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
             $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and
            $n.Value -match '^(HKCU:|HKEY_CURRENT_USER|Registry::HKEY_CURRENT_USER)'
        }, $true)
        foreach ($h in $hkcu) {
            Add-Failure "SystemContextInstall" ("detection_template.ps1:{0} durchsucht HKCU - als SYSTEM ist das die Registry von SYSTEM, eine Fehlinstallation gilt dann als erkannt" -f $h.Extent.StartLineNumber)
        }
    }
    if ($functionsFile) {
        $switchFn = $functionsFile.Ast.Find({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-InstallerEngineSwitch'
        }, $true)
        $innoClause = $null
        if ($switchFn) {
            $innoClause = $switchFn.Body.Find({
                param($n)
                $n -is [System.Management.Automation.Language.HashtableAst] -and
                $n.Extent.Text -match "Engine\s*=\s*'inno'"
            }, $true)
        }
        if (-not $innoClause) {
            Add-Failure "SystemContextInstall" "Get-InstallerEngineSwitch: kein Eintrag fuer 'inno' gefunden"
        }
        else {
            $install = @($innoClause.KeyValuePairs | Where-Object { $_.Item1.Extent.Text -eq 'Install' })
            if ($install.Count -eq 0 -or $install[0].Item2.Extent.Text -notmatch '/ALLUSERS') {
                Add-Failure "SystemContextInstall" "Get-InstallerEngineSwitch: der Inno-Installationsschalter enthaelt kein /ALLUSERS - als SYSTEM landet die App sonst im Profil von SYSTEM"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 29) ServiceUI nur ueber Get-DeployCommandLine. Frueher stand der Befehl
#     "ServiceUi.exe -Process:Explorer.exe ..." fest in deploy_template.ps1
#     (und als tote Kopie in createApps), ServiceUI.exe wurde in JEDES Paket
#     kopiert. Folge im Feld: Setups liefen als SYSTEM in der Sitzung des
#     Benutzers, Greenshot blieb danach als SYSTEM auf dem Desktop stehen.
#     Jetzt: Befehlsform nur in Get-DeployCommandLine, das Kopieren nur hinter
#     deren NeedsServiceUI, und das Template holt sich die Befehle dort.
# ---------------------------------------------------------------------------
foreach ($p in $parsed.Values) {
    $checked++
    $strings = $p.Ast.FindAll({
        param($n)
        ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
         $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and
        $n.Value -match '(?i)ServiceUi\.exe\s+-Process'
    }, $true)
    foreach ($s in $strings) {
        $owner = & $enclosingFunction $s
        if ($owner -ne 'Get-DeployCommandLine') {
            Add-Failure "ServiceUiOnlyWhenInteractive" ("{0}:{1} ServiceUI-Befehl ausserhalb von Get-DeployCommandLine (in '{2}')" -f `
                $p.File.Name, $s.Extent.StartLineNumber, $owner)
        }
    }
    $copies = $p.Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -in @('cp', 'copy', 'Copy-Item', 'cpi') -and
        $n.Extent.Text -match '(?i)ServiceUI\.exe'
    }, $true)
    foreach ($c in $copies) {
        $guarded = $false
        $n = $c.Parent
        while ($n -ne $null) {
            if ($n -is [System.Management.Automation.Language.IfStatementAst] -and
                (@($n.Clauses | Where-Object { $_.Item1.Extent.Text -match 'NeedsServiceUI' }).Count -gt 0)) { $guarded = $true; break }
            $n = $n.Parent
        }
        if (-not $guarded) {
            Add-Failure "ServiceUiOnlyWhenInteractive" ("{0}:{1} ServiceUI.exe wird ohne Pruefung von NeedsServiceUI ins Paket kopiert" -f `
                $p.File.Name, $c.Extent.StartLineNumber)
        }
    }
}
$checked++
if ((Test-Path -LiteralPath $templatePath) -and ((Get-Content -LiteralPath $templatePath -Raw) -notmatch 'Get-DeployCommandLine')) {
    Add-Failure "ServiceUiOnlyWhenInteractive" "deploy_template.ps1 holt die Befehle nicht aus Get-DeployCommandLine"
}

# ---------------------------------------------------------------------------
# 30) detection.ps1 nur ueber Write-DetectionScript, Erneuern inklusive.
#     Frueher renderte createApps die Erkennung selbst, Update-DeployScript
#     fasste sie nicht an - der Stempel stand danach auf "current", die alte
#     Erkennung blieb. Dazu: die Deinstallation nutzt dieselbe Praefix-Regel
#     wie die Erkennung (ohne -NameMatch vergleicht PSADT 4 per 'Contains' und
#     entfernt jeden Treffer).
# ---------------------------------------------------------------------------
$checked++
if ($functionsFile) {
    $detRefs = $functionsFile.Ast.FindAll({
        param($n)
        ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
         $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and
        $n.Value -match 'detection_template'
    }, $true)
    foreach ($r in $detRefs) {
        $owner = & $enclosingFunction $r
        if ($owner -notin @('Write-DetectionScript', 'Get-TemplateFingerprint')) {
            Add-Failure "DetectionOnePath" ("functions.ps1:{0} Erkennungsvorlage ausserhalb von Write-DetectionScript benutzt (in '{1}')" -f $r.Extent.StartLineNumber, $owner)
        }
    }
    $upd = $functionsFile.Ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-DeployScript' }, $true)
    if ($upd -and $upd.Extent.Text -notmatch 'Write-DetectionScript') {
        Add-Failure "DetectionOnePath" "Update-DeployScript erneuert detection.ps1 nicht - der Stempel meldet danach 'current' fuer eine alte Erkennung"
    }
    $derive = $functionsFile.Ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-DerivedInstallCommands' }, $true)
    if ($derive) {
        $uninst = $derive.FindAll({
            param($n)
            ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
             $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and
            $n.Value -match 'Uninstall-ADTApplication'
        }, $true)
        foreach ($u in $uninst) {
            if ($u.Value -notmatch "-NameMatch 'Wildcard'" -or $u.Value -notmatch "-Name '[^']*\*'") {
                Add-Failure "DetectionOnePath" ("functions.ps1:{0} abgeleitete Deinstallation ohne Praefix-Regel (-Name '<Name>*' -NameMatch 'Wildcard') - PSADT vergleicht sonst per 'Contains'" -f $u.Extent.StartLineNumber)
            }
        }
    }
}
$checked++
$detTplPath = Join-Path $RepoRoot 'Templates\detection_template.ps1'
if ((Test-Path -LiteralPath $detTplPath) -and ((Get-Content -LiteralPath $detTplPath -Raw) -notmatch 'Test-AppInstallation\s+-AppName\s+\$ArpName')) {
    Add-Failure "DetectionOnePath" "detection_template.ps1 sucht nicht mit `$ArpName - Apps.csv 'ArpName' waere wirkungslos"
}

# ---------------------------------------------------------------------------
# 31) Das Hauptfenster ist der einzige Einstieg, und jede Aktion hat einen Zweig.
#     Frueher gab es drei Kacheln und zwei Auswahldialoge, die je einen Ausschnitt
#     desselben Zustands zeigten; createApps und deployApps bauten und verteilten
#     auf je eigenem Weg. Jetzt zeigt Start-InventoryLoop das Inventar, und:
#       - die alten Einstiege gibt es nicht wieder,
#       - das Startskript ruft Start-InventoryLoop,
#       - jede Aktion, die Show-InventoryDialog zurueckgeben kann, hat in
#         Start-InventoryLoop einen switch-Zweig - kein Knopf ohne Gegenstueck,
#       - der Tenant-Wechsel meldet sich neu an (-Force): Initialize-IntuneConnection
#         prueft ohne -Force nur, ob IRGENDEIN Token noch gilt, nicht fuer welchen
#         Tenant - die Liste zeigte sonst still den falschen.
# ---------------------------------------------------------------------------
$checked++
if ($functionsFile) {
    $findFn = {
        param($name)
        $functionsFile.Ast.Find({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
        }, $true)
    }

    foreach ($gone in 'createApps', 'deployApps', 'Show-StartDialog', 'Open-SelectDialogWithEdit') {
        if (& $findFn $gone) {
            Add-Failure "MainWindowOnePath" ("{0} gibt es wieder - Anlegen/Verteilen laufen ueber das Hauptfenster (Start-InventoryLoop), ein zweiter Einstieg driftet" -f $gone)
        }
    }

    $loopFn   = & $findFn 'Start-InventoryLoop'
    $dialogFn = & $findFn 'Show-InventoryDialog'
    $connect  = & $findFn 'Connect-InventoryTenant'
    if (-not $loopFn -or -not $dialogFn -or -not $connect) {
        Add-Failure "MainWindowOnePath" "Start-InventoryLoop, Show-InventoryDialog oder Connect-InventoryTenant fehlt"
    }
    else {
        # Aktionen des Dialogs: die Literale in "& $choose '<Aktion>'"
        $chooseCalls = $dialogFn.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and
            $n.CommandElements.Count -ge 2 -and
            $n.CommandElements[0] -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $n.CommandElements[0].VariablePath.UserPath -eq 'choose' -and
            $n.CommandElements[1] -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true)
        $actions = @($chooseCalls | ForEach-Object { $_.CommandElements[1].Value } | Sort-Object -Unique)

        # Wirkungslos waere die Pruefung ohne gefundene Aktionen - dann ist sie ein Befund.
        if ($actions.Count -lt 5) {
            Add-Failure "MainWindowOnePath" ("in Show-InventoryDialog nur {0} Aktionen gefunden - die Pruefung 'jeder Knopf hat einen Zweig' laeuft ins Leere" -f $actions.Count)
        }

        $actionSwitch = $loopFn.Find({
            param($n)
            $n -is [System.Management.Automation.Language.SwitchStatementAst] -and $n.Condition.Extent.Text -match 'Action'
        }, $true)
        if (-not $actionSwitch) {
            Add-Failure "MainWindowOnePath" "Start-InventoryLoop hat keinen switch ueber die Aktion"
        }
        else {
            $labels = @($actionSwitch.Clauses | ForEach-Object { $_.Item1.Extent.Text.Trim([char[]]@(39, 34)) })
            foreach ($action in $actions) {
                if ($labels -notcontains $action) {
                    Add-Failure "MainWindowOnePath" ("Show-InventoryDialog kann '{0}' zurueckgeben, Start-InventoryLoop hat keinen Zweig dafuer - der Knopf tut nichts" -f $action)
                }
            }

            $switchClause = $actionSwitch.Clauses | Where-Object { $_.Item1.Extent.Text.Trim([char[]]@(39, 34)) -eq 'SwitchTenant' } | Select-Object -First 1
            if (-not $switchClause) {
                Add-Failure "MainWindowOnePath" "Start-InventoryLoop hat keinen Zweig SwitchTenant"
            }
            elseif ($switchClause.Item2.Extent.Text -notmatch '-Force') {
                Add-Failure "MainWindowOnePath" "Der Zweig SwitchTenant meldet nicht mit -Force neu an - das Token des alten Tenants wuerde weiterbenutzt"
            }
        }

        if ($connect.Extent.Text -notmatch 'Initialize-IntuneConnection[^\r\n]*-Force:\$Force') {
            Add-Failure "MainWindowOnePath" "Connect-InventoryTenant reicht -Force nicht an Initialize-IntuneConnection weiter"
        }
    }
}

$checked++
foreach ($starter in @($psFiles | Where-Object { $_.Name -like "start-*.ps1" })) {
    $starterText = $parsed[$starter.FullName].Ast.Extent.Text
    if ($starterText -notmatch 'Start-InventoryLoop') {
        Add-Failure "MainWindowOnePath" ("{0} ruft Start-InventoryLoop nicht auf" -f $starter.Name)
    }
    if ($starterText -match 'Show-StartDialog') {
        Add-Failure "MainWindowOnePath" ("{0} ruft noch Show-StartDialog auf" -f $starter.Name)
    }
}

# ---------------------------------------------------------------------------
# 32) Apps.csv hat EINEN Schreibpfad (Save-AppsCsv) und ein Paket EINEN Bauweg
#     (Build-AppPackage). Vorher schrieb ein Auswahldialog die Datei und
#     createApps baute; "Build" und "Deploy" im Hauptfenster brauchen denselben
#     Weg, sonst baut eine der beiden Aktionen anders.
# ---------------------------------------------------------------------------
$checked++
if ($functionsFile) {
    $exports = $functionsFile.Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Export-Csv'
    }, $true)
    foreach ($e in $exports) {
        $owner = & $enclosingFunction $e
        if ($owner -notin @('Save-AppsCsv', 'Get-DeployScripts')) {
            Add-Failure "AppsCsvOneWriter" ("functions.ps1:{0} Export-Csv in '{1}' - Apps.csv wird nur in Save-AppsCsv geschrieben" -f $e.Extent.StartLineNumber, $owner)
        }
    }

    $templateCalls = $functionsFile.Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'New-ADTTemplate'
    }, $true)
    if (-not $templateCalls) {
        Add-Failure "PackageOneBuildPath" "New-ADTTemplate wird nirgends aufgerufen - Build-AppPackage baut kein Paket mehr"
    }
    foreach ($t in $templateCalls) {
        $owner = & $enclosingFunction $t
        if ($owner -ne 'Build-AppPackage') {
            Add-Failure "PackageOneBuildPath" ("functions.ps1:{0} New-ADTTemplate in '{1}' - Pakete werden nur in Build-AppPackage gebaut" -f $t.Extent.StartLineNumber, $owner)
        }
    }

    # Und die Aktionen benutzen diesen Weg: Build geht ueber Invoke-PackageBuild, Deploy ueber
    # Invoke-InventoryDeploy, und das baut seinerseits ueber Invoke-PackageBuild.
    $loopFn2   = $functionsFile.Ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-InventoryLoop' }, $true)
    $deployFn2 = $functionsFile.Ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-InventoryDeploy' }, $true)
    if ($loopFn2 -and $loopFn2.Extent.Text -notmatch 'Invoke-PackageBuild') {
        Add-Failure "PackageOneBuildPath" "Start-InventoryLoop ruft Invoke-PackageBuild in der Aktion Build nicht auf"
    }
    if (-not $deployFn2 -or $deployFn2.Extent.Text -notmatch 'Invoke-PackageBuild') {
        Add-Failure "PackageOneBuildPath" "Invoke-InventoryDeploy fehlt oder baut nicht ueber Invoke-PackageBuild - die Aktion Deploy baut anders als Build"
    }
}
# ---------------------------------------------------------------------------
# 33) Verwaiste Paketordner werden nur ueber Remove-OrphanPackages geloescht, und
#     die verweigert, was nicht eindeutig verwaist ist. Der Schutz liegt in der
#     Funktion, nicht im Knopf: ein Fehler beim Aktivieren des Knopfes darf keinen
#     Ordner treffen, der eine Definition hat. Dazu: Remove-PackageFolder (der
#     Wurzel-Schutz) hat nur diese beiden Aufrufer - Build-AppPackage (alten Ordner
#     vor dem Neubau entfernen) und Remove-OrphanPackages.
# ---------------------------------------------------------------------------
$checked++
if ($functionsFile) {
    $orphanFn = $functionsFile.Ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Remove-OrphanPackages' }, $true)
    $loopFn3  = $functionsFile.Ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-InventoryLoop' }, $true)
    if (-not $orphanFn) {
        Add-Failure "OrphanRemovalGuarded" "Remove-OrphanPackages fehlt"
    }
    else {
        foreach ($guard in 'HasDefinition', 'deploy.ps1', 'Remove-PackageFolder', 'Split-Path -Leaf') {
            if ($orphanFn.Extent.Text -notmatch [regex]::Escape($guard)) {
                Add-Failure "OrphanRemovalGuarded" ("Remove-OrphanPackages prueft/benutzt '{0}' nicht - der Schutz vor dem Loeschen eines Ordners mit Definition fehlt" -f $guard)
            }
        }
    }

    $removeCalls = $functionsFile.Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Remove-PackageFolder'
    }, $true)
    foreach ($call in $removeCalls) {
        $owner = & $enclosingFunction $call
        if ($owner -notin @('Build-AppPackage', 'Remove-OrphanPackages')) {
            Add-Failure "OrphanRemovalGuarded" ("functions.ps1:{0} Remove-PackageFolder in '{1}' - Ordner werden nur in Build-AppPackage und Remove-OrphanPackages entfernt" -f $call.Extent.StartLineNumber, $owner)
        }
    }

    if ($loopFn3) {
        $removeSwitch = $loopFn3.Find({ param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst] -and $n.Condition.Extent.Text -match 'Action' }, $true)
        $clause = $null
        if ($removeSwitch) { $clause = $removeSwitch.Clauses | Where-Object { $_.Item1.Extent.Text.Trim([char[]]@(39, 34)) -eq 'RemoveFolder' } | Select-Object -First 1 }
        if (-not $clause) {
            Add-Failure "OrphanRemovalGuarded" "Start-InventoryLoop hat keinen Zweig RemoveFolder"
        }
        else {
            $clauseText = $clause.Item2.Extent.Text
            if ($clauseText -notmatch 'Remove-OrphanPackages') { Add-Failure "OrphanRemovalGuarded" "Der Zweig RemoveFolder loescht nicht ueber Remove-OrphanPackages" }
            if ($clauseText -match 'Remove-Item|Remove-PackageFolder') { Add-Failure "OrphanRemovalGuarded" "Der Zweig RemoveFolder loescht direkt (Remove-Item/Remove-PackageFolder) und umgeht die Verweigerungsregeln" }
            if ($clauseText -notmatch "'YesNo'")                       { Add-Failure "OrphanRemovalGuarded" "Der Zweig RemoveFolder fragt nicht vor dem Loeschen (YesNo)" }
        }
    }
}
# ---------------------------------------------------------------------------
# 34) Ein Deploy legt keine Dublette an, weil niemand nachgesehen hat. Die Entscheidung
#     (neu anlegen / ueberspringen / Inhalt ersetzen) faellt im Tool, VOR dem Upload, auf
#     frisch gelesenem Intune-Stand - und das deploy.ps1 bekommt sie mit (-Mode). Frueher
#     legte der Bulk-Lauf IMMER eine neue App an, auch wenn dieselbe in derselben Version
#     schon in Intune lag. Geprueft wird die Struktur:
#       - Invoke-InventoryDeploy liest Intune (Read-TenantWin32Apps), plant (Get-DeployPlan)
#         und verteilt (Invoke-PackageDeploy) - in dieser Reihenfolge;
#       - die Schleife erreicht Invoke-PackageDeploy nur darueber (kein Deploy am Plan vorbei);
#       - Invoke-PackageDeploy ruft das deploy.ps1 mit -Mode auf und nicht mit -bulk;
#       - das Template kennt -Mode (Ask|New|Update) und -UpdateAppId, und das Ergebnis des
#         Updates wird gelesen (nicht "$null = ..."), sonst bliebe ein gescheitertes Update
#         unsichtbar.
# ---------------------------------------------------------------------------
$checked++
if ($functionsFile) {
    $fnAst = { param($name) $functionsFile.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object { $_.Name -eq $name } | Select-Object -First 1 }
    $planFn      = & $fnAst 'Get-DeployPlan'
    $invDeployFn = & $fnAst 'Invoke-InventoryDeploy'
    $pkgDeployFn = & $fnAst 'Invoke-PackageDeploy'
    $loopFn4     = & $fnAst 'Start-InventoryLoop'

    if (-not $planFn) { Add-Failure "DeployDecidedByPlan" "Get-DeployPlan fehlt" }
    if (-not $invDeployFn) {
        Add-Failure "DeployDecidedByPlan" "Invoke-InventoryDeploy fehlt"
    }
    else {
        $positions = @{}
        foreach ($name in 'Read-TenantWin32Apps', 'Get-DeployPlan', 'Invoke-PackageDeploy') {
            $call = $invDeployFn.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $name }, $true)
            if (-not $call) { Add-Failure "DeployDecidedByPlan" ("Invoke-InventoryDeploy ruft {0} nicht auf" -f $name) }
            else { $positions[$name] = $call.Extent.StartOffset }
        }
        if ($positions.Count -eq 3 -and -not ($positions['Read-TenantWin32Apps'] -lt $positions['Get-DeployPlan'] -and $positions['Get-DeployPlan'] -lt $positions['Invoke-PackageDeploy'])) {
            Add-Failure "DeployDecidedByPlan" "Invoke-InventoryDeploy: Reihenfolge muss Intune lesen -> planen -> verteilen sein"
        }
    }

    if ($loopFn4) {
        $direct = $loopFn4.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-PackageDeploy' }, $true)
        foreach ($d in $direct) {
            Add-Failure "DeployDecidedByPlan" ("functions.ps1:{0} Start-InventoryLoop ruft Invoke-PackageDeploy direkt - ein Deploy am Plan vorbei" -f $d.Extent.StartLineNumber)
        }
        if ($loopFn4.Extent.Text -notmatch 'Invoke-InventoryDeploy') {
            Add-Failure "DeployDecidedByPlan" "Start-InventoryLoop ruft Invoke-InventoryDeploy nicht auf - die Aktion Deploy verteilt nicht ueber den Plan"
        }
    }

    if ($pkgDeployFn) {
        $invocations = $pkgDeployFn.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand }, $true)
        $scriptCalls = @($invocations | Where-Object { $_.Extent.Text -match 'FullPath' })
        if ($scriptCalls.Count -eq 0) { Add-Failure "DeployDecidedByPlan" "Invoke-PackageDeploy ruft das deploy.ps1 (& `$app.FullPath) nicht auf" }
        foreach ($c in $scriptCalls) {
            if ($c.Extent.Text -notmatch '-Mode\b') { Add-Failure "DeployDecidedByPlan" ("functions.ps1:{0} Invoke-PackageDeploy ruft das deploy.ps1 ohne -Mode auf - es entschiede selbst und legte im Bulk-Lauf immer neu an" -f $c.Extent.StartLineNumber) }
            if ($c.Extent.Text -match '-bulk\b')  { Add-Failure "DeployDecidedByPlan" ("functions.ps1:{0} Invoke-PackageDeploy uebergibt -bulk - das deploy.ps1 legte damit immer neu an" -f $c.Extent.StartLineNumber) }
        }
    }
}
if (Test-Path -LiteralPath $templatePath) {
    $tplAst6 = $parsed[(Get-Item -LiteralPath $templatePath).FullName].Ast
    $modeParam = $tplAst6.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Mode' } | Select-Object -First 1
    $idParam   = $tplAst6.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'UpdateAppId' } | Select-Object -First 1
    if (-not $modeParam -or -not $idParam) {
        Add-Failure "DeployDecidedByPlan" "deploy_template.ps1 hat die Parameter -Mode / -UpdateAppId nicht - die Entscheidung des Plans kommt nicht an"
    }
    else {
        $validate = ($modeParam.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' } | ForEach-Object { $_.Extent.Text }) -join ' '
        foreach ($value in 'Ask', 'New', 'Update') {
            if ($validate -notmatch ("'{0}'" -f $value)) { Add-Failure "DeployDecidedByPlan" ("deploy_template.ps1: -Mode kennt '{0}' nicht" -f $value) }
        }
    }
    $discarded = $tplAst6.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$null' -and $n.Right.Extent.Text -match 'Update-IntuneWin32AppPackageFile'
    }, $true)
    foreach ($d in $discarded) {
        Add-Failure "DeployDecidedByPlan" ("deploy_template.ps1:{0} das Ergebnis von Update-IntuneWin32AppPackageFile wird verworfen - ein gescheitertes Update bliebe unsichtbar" -f $d.Extent.StartLineNumber)
    }
}# ---------------------------------------------------------------------------
# 35) Loeschen in Intune laesst sich nicht zuruecknehmen. Darum:
#       - Remove-IntuneWin32App wird NUR in Remove-TenantWin32Apps aufgerufen, und die Funktion
#         liest den Tenant danach neu (das Modul warnt bei einem Fehler nur, es wirft nicht -
#         "Kommando lief durch" hiesse sonst "App ist weg");
#       - Remove-TenantWin32Apps haben nur Retire und Rebuild als Aufrufer, die Schleife nie direkt;
#       - Retire: Tenant frisch lesen -> Rueckfrage -> loeschen, und die Rueckfrage hat die
#         Standardantwort Nein;
#       - Rebuild: Tenant lesen -> Rueckfrage -> BAUEN -> loeschen -> anlegen. Scheitert der Bau,
#         darf Intune nicht angefasst sein; angelegt wird erst nach dem Loeschen.
# ---------------------------------------------------------------------------
$checked++
if ($functionsFile) {
    $fn35 = { param($name) $functionsFile.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object { $_.Name -eq $name } | Select-Object -First 1 }
    $cmd35 = { param($scope, $name) $scope.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $name }, $true) | Select-Object -First 1 }

    $removeCalls = $functionsFile.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Remove-IntuneWin32App' }, $true)
    foreach ($c in $removeCalls) {
        $owner = & $enclosingFunction $c
        if ($owner -ne 'Remove-TenantWin32Apps') {
            Add-Failure "IntuneDeleteVerified" ("functions.ps1:{0} Remove-IntuneWin32App in '{1}' - Apps werden in Intune nur in Remove-TenantWin32Apps geloescht" -f $c.Extent.StartLineNumber, $owner)
        }
    }

    $removeFn = & $fn35 'Remove-TenantWin32Apps'
    if (-not $removeFn) { Add-Failure "IntuneDeleteVerified" "Remove-TenantWin32Apps fehlt" }
    else {
        $del  = & $cmd35 $removeFn 'Remove-IntuneWin32App'
        $read = & $cmd35 $removeFn 'Read-TenantWin32Apps'
        if (-not $del)  { Add-Failure "IntuneDeleteVerified" "Remove-TenantWin32Apps ruft Remove-IntuneWin32App nicht auf" }
        if (-not $read) { Add-Failure "IntuneDeleteVerified" "Remove-TenantWin32Apps liest den Tenant nach dem Loeschen nicht neu - ein Loeschen, das nur warnt, ginge als erfolgreich durch" }
        if ($del -and $read -and $read.Extent.StartOffset -lt $del.Extent.StartOffset) {
            Add-Failure "IntuneDeleteVerified" "Remove-TenantWin32Apps liest den Tenant VOR dem Loeschen, nicht danach"
        }
    }

    $removeUsers = $functionsFile.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Remove-TenantWin32Apps' }, $true)
    foreach ($c in $removeUsers) {
        $owner = & $enclosingFunction $c
        if ($owner -notin @('Invoke-InventoryRetire', 'Invoke-InventoryRebuild')) {
            Add-Failure "IntuneDeleteVerified" ("functions.ps1:{0} Remove-TenantWin32Apps in '{1}' - geloescht wird nur ueber Retire und Rebuild, beide mit Rueckfrage" -f $c.Extent.StartLineNumber, $owner)
        }
    }

    # Die Rueckfrage hat die Standardantwort Nein (einfache Anfuehrungszeichen: $Buttons soll woertlich gesucht werden).
    $askDefaultNo = '''Warning'',\s*\$\(if \(\$Buttons -eq ''YesNo''\) \{ ''No'' \}'

    $order = {
        param($fnAst, [string[]]$names, [string]$label)
        $pos = @()
        foreach ($name in $names) {
            $hit = $fnAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and ($n.GetCommandName() -eq $name -or ($name -eq '$Ask' -and $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and $n.Extent.Text -match '^&\s+\$Ask\b')) }, $true) | Select-Object -First 1
            if (-not $hit) { Add-Failure "IntuneDeleteVerified" ("{0} ruft {1} nicht auf" -f $label, $name); return }
            $pos += $hit.Extent.StartOffset
        }
        for ($i = 1; $i -lt $pos.Count; $i++) {
            if ($pos[$i] -lt $pos[$i - 1]) { Add-Failure "IntuneDeleteVerified" ("{0}: Reihenfolge muss {1} sein" -f $label, ($names -join ' -> ')); return }
        }
    }
    $retireFn  = & $fn35 'Invoke-InventoryRetire'
    $rebuildFn = & $fn35 'Invoke-InventoryRebuild'
    if (-not $retireFn)  { Add-Failure "IntuneDeleteVerified" "Invoke-InventoryRetire fehlt" }
    else {
        & $order $retireFn  @('Read-TenantWin32Apps', '$Ask', 'Remove-TenantWin32Apps') 'Invoke-InventoryRetire'
        if ($retireFn.Extent.Text -notmatch $askDefaultNo) {
            Add-Failure "IntuneDeleteVerified" "Invoke-InventoryRetire: die Rueckfrage hat nicht die Standardantwort Nein"
        }
    }
    if (-not $rebuildFn) { Add-Failure "IntuneDeleteVerified" "Invoke-InventoryRebuild fehlt" }
    else {
        & $order $rebuildFn @('Read-TenantWin32Apps', '$Ask', 'Invoke-PackageBuild', 'Remove-TenantWin32Apps', 'Invoke-PackageDeploy') 'Invoke-InventoryRebuild'
        if ($rebuildFn.Extent.Text -notmatch $askDefaultNo) {
            Add-Failure "IntuneDeleteVerified" "Invoke-InventoryRebuild: die Rueckfrage hat nicht die Standardantwort Nein"
        }
    }

    $loop35 = & $fn35 'Start-InventoryLoop'
    if ($loop35) {
        foreach ($name in 'Remove-TenantWin32Apps', 'Remove-IntuneWin32App') {
            $direct = & $cmd35 $loop35 $name
            if ($direct) { Add-Failure "IntuneDeleteVerified" ("functions.ps1:{0} Start-InventoryLoop ruft {1} direkt auf - ohne Rueckfrage und Plan" -f $direct.Extent.StartLineNumber, $name) }
        }
        foreach ($name in 'Invoke-InventoryRetire', 'Invoke-InventoryRebuild') {
            if (-not (& $cmd35 $loop35 $name)) { Add-Failure "IntuneDeleteVerified" ("Start-InventoryLoop ruft {0} nicht auf - der Knopf haette keine Wirkung" -f $name) }
        }
    }
}
# ---------------------------------------------------------------------------
# Ergebnis
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host ("Dateien: {0}   Pruefungen: {1}" -f $psFiles.Count, $checked)

if ($failures.Count -eq 0) {
    Write-Host "Alle Pruefungen bestanden." -ForegroundColor Green
    exit 0
}

Write-Host ("{0} Befund(e):" -f $failures.Count) -ForegroundColor Red
$failures | Group-Object Check | ForEach-Object {
    Write-Host ("  [{0}]" -f $_.Name) -ForegroundColor Yellow
    foreach ($f in $_.Group) { Write-Host ("    - " + $f.Detail) }
}
exit 1
