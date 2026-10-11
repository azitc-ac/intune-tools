<#
    .SYNOPSIS
    Bedient den WinGet-Suchdialog ueber UI Automation, wie ein Mensch es tut.

    .DESCRIPTION
    Der Dialog (Show-WinGetSearchDialog, Muster aus SCCMAppHelper) laeuft in einem zweiten Prozess
    mit einer kleinen kuratierten Liste und einer Ersatzsuche; der Test bedient ihn und liest, was er
    zurueckgegeben hat. Geprueft wird:

      - alle Bedienelemente haben eine AutomationId (Suchfeld, Suchen, Liste, Indexzeile, Index
        erneuern, Remember, Next, Cancel),
      - ohne Suche steht die kuratierte Liste da, die Indexzeile sagt, dass es noch keinen Index gibt,
      - "Search" zeigt die Treffer der Suche und gibt ihr den eingegebenen Begriff,
      - Return im Suchfeld sucht,
      - kein Treffer und ein Fehler der Suche werden gemeldet, der Dialog bleibt bedienbar,
      - Remember schreibt die Auswahl in Config\catalog.json (in einer Wegwerf-Kopie), ein zweites
        Mal meldet es "schon drin", ohne Auswahl meldet es "Nothing selected",
      - Next gibt Name, Id, Version und den Publisher (erster Teil der Id) zurueck, Cancel nichts.

    Braucht eine angemeldete Desktop-Sitzung. Kein Netz, kein Tenant; der echte Index und die echte
    catalog.json bleiben unberuehrt.

    Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [switch]$Child,
    [string]$ResultPath,
    [string]$Scenario = 'main'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------------------
# Kindprozess
# ---------------------------------------------------------------------------
if ($Child) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Functions\functions.ps1'), [ref]$null, [ref]$null)
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    . (Join-Path $repoRoot 'Functions\wingetindex.ps1')
    Add-Type -AssemblyName WindowsBase, PresentationCore, PresentationFramework

    # Wegwerf-Wurzel: eigene catalog.json, kein Index
    $rootDir = Split-Path -Parent $ResultPath
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $rootDir 'Config')
    $catalogFile = Join-Path $rootDir 'Config\catalog.json'
    if (-not (Test-Path -LiteralPath $catalogFile)) {
        $null = Add-WinGetCatalogEntry -Name 'Alpha Tool' -PackageId 'Alpha.Tool' -Path $catalogFile
        $null = Add-WinGetCatalogEntry -Name 'Beta Tool'  -PackageId 'Beta.Tool'  -Path $catalogFile
    }

    $global:WgQueries = New-Object System.Collections.ArrayList
    $stub = {
        param($q)
        $null = $global:WgQueries.Add([string]$q)
        if ([string]$q -eq 'boom') { throw 'search exploded' }
        if ([string]$q -eq 'none') { return @() }
        if (([string]$q).Trim() -eq '') { return @(Get-WinGetCatalogList | ForEach-Object { [pscustomobject]@{ Name = $_.name; Id = $_.packageId; Version = ''; Source = 'catalog' } }) }
        return @(
            [pscustomobject]@{ Name = 'Foo App';  Id = 'FooCorp.FooApp';  Version = '1.2.3'; Source = 'index' },
            [pscustomobject]@{ Name = 'Foo Twin'; Id = 'OtherCo.FooTwin'; Version = '4.5';   Source = 'index' }
        )
    }

    if ($Scenario -eq 'enter') {
        # Return im Suchfeld muss suchen. Ein Tastendruck laesst sich ohne Vordergrundfenster nicht
        # senden; das KeyDown-Ereignis wird deshalb im Fenster selbst ausgeloest.
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(1200)
        $timer.Add_Tick({
            $timer.Stop()
            foreach ($source in [System.Windows.PresentationSource]::CurrentSources) {
                $win = $source.RootVisual
                if ($win -isnot [System.Windows.Window]) { continue }
                $stack = New-Object System.Collections.Stack
                $stack.Push($win.Content)
                $box = $null
                while ($stack.Count -gt 0 -and -not $box) {
                    $node = $stack.Pop()
                    if ($node -is [System.Windows.Controls.TextBox] -and [System.Windows.Automation.AutomationProperties]::GetAutomationId($node) -eq 'SearchQuery') { $box = $node }
                    elseif ($node -is [System.Windows.Controls.Panel]) { foreach ($ch in $node.Children) { $stack.Push($ch) } }
                }
                if ($box) {
                    $box.Text = 'enterq'
                    $args2 = New-Object System.Windows.Input.KeyEventArgs([System.Windows.Input.Keyboard]::PrimaryDevice, [System.Windows.PresentationSource]::FromVisual($box), 0, [System.Windows.Input.Key]::Return)
                    $args2.RoutedEvent = [System.Windows.Input.Keyboard]::KeyDownEvent
                    $box.RaiseEvent($args2)
                }
                $win.Close()
            }
        })
        $timer.Start()
    }

    $picked = Show-WinGetSearchDialog -Packages (Get-WinGetCatalogList) -OnSearch $stub
    $out = [pscustomobject]@{ Picked = $picked; Queries = @($global:WgQueries); Catalog = (Get-Content -LiteralPath $catalogFile -Raw) }
    [System.IO.File]::WriteAllText($ResultPath, ($out | ConvertTo-Json -Compress -Depth 4), (New-Object System.Text.UTF8Encoding $false))
    exit 0
}

# ---------------------------------------------------------------------------
# Elternprozess
# ---------------------------------------------------------------------------
Import-Module (Join-Path $PSScriptRoot 'UiAutomation.psm1') -Force

$script:Failures = New-Object System.Collections.ArrayList
$script:Passed = 0
function Test-That {
    param([string]$Name, [bool]$Condition, [string]$Detail)
    if ($Condition) { $script:Passed++ }
    else { $null = $script:Failures.Add($(if ($Detail) { "$Name - $Detail" } else { $Name })) }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('iw32h-wg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $work
$children = New-Object System.Collections.ArrayList

function Start-Child([string]$name) {
    $dir = Join-Path $work $name
    $null = New-Item -ItemType Directory -Force -Path $dir
    $resultFile = Join-Path $dir 'result.json'
    $proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Minimized -ArgumentList @(
        '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
        '-Child', '-ResultPath', ('"{0}"' -f $resultFile), '-Scenario', $name)
    $null = $children.Add($proc)
    return [pscustomobject]@{ Process = $proc; ResultFile = $resultFile }
}

function Wait-ChildResult($child, [int]$TimeoutSeconds = 40) {
    if (-not $child.Process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $child.Process.Kill() } catch { }
        return $null
    }
    if (-not (Test-Path -LiteralPath $child.ResultFile)) { return $null }
    return (Get-Content -LiteralPath $child.ResultFile -Raw | ConvertFrom-Json)
}

# Eine Hinweis-/Rueckfrage des Dialogs lesen und mit OK schliessen.
function Read-Note($processId) {
    $note = Wait-UiaWindow -ProcessId $processId -AutomationId 'ConfirmDialog' -TimeoutSeconds 20
    if (-not $note) { return $null }
    $text = (Find-UiaElement -Root $note -AutomationId 'ConfirmText' -TimeoutSeconds 5).Current.Name
    Invoke-UiaElement -Element (Find-UiaElement -Root $note -AutomationId 'ConfirmOK' -TimeoutSeconds 5)
    # warten, bis die Meldung weg ist
    foreach ($i in 1..20) { if (-not (Wait-UiaWindow -ProcessId $processId -AutomationId 'ConfirmDialog' -TimeoutSeconds 1)) { break } }
    return $text
}

function Invoke-Search($dlg, [string]$text) {
    Set-UiaText -Element (Find-UiaElement -Root $dlg -AutomationId 'SearchQuery' -TimeoutSeconds 5) -Text $text
    Invoke-UiaElement -Element (Find-UiaElement -Root $dlg -AutomationId 'Search' -TimeoutSeconds 5)
}

try {
    # ---- main: Bedienung -----------------------------------------------------
    $c = Start-Child 'main'
    $dlg = Wait-UiaWindow -ProcessId $c.Process.Id -AutomationId 'WinGetDialog' -TimeoutSeconds 60
    Test-That 'the search dialog appears' ($null -ne $dlg)
    if ($dlg) {
        foreach ($id in 'SearchQuery', 'Search', 'WinGetGrid', 'IndexStatus', 'UpdateIndex', 'Remember', 'Next', 'Cancel') {
            Test-That "control $id has its AutomationId" ($null -ne (Find-UiaElement -Root $dlg -AutomationId $id -TimeoutSeconds 5))
        }
        $grid = Find-UiaElement -Root $dlg -AutomationId 'WinGetGrid' -TimeoutSeconds 5
        Test-That 'the curated list is on the front page (2 rows)' ((Get-UiaElement -Root $grid -ControlType DataItem).Count -eq 2) "rows: $((Get-UiaElement -Root $grid -ControlType DataItem).Count)"
        $status = (Find-UiaElement -Root $dlg -AutomationId 'IndexStatus' -TimeoutSeconds 5).Current.Name
        Test-That 'the index line says there is no index yet' ($status -like 'No winget index yet*') "text: $status"

        # Suchen
        Invoke-Search $dlg 'foo'
        $found = $null
        foreach ($i in 1..30) { $found = Select-UiaRow -Root $grid -Match 'FooApp' -TimeoutSeconds 1; if ($found) { break } }
        Test-That 'Search shows the hits of the search' ($null -ne $found)
        Test-That 'Search replaces the curated list' ((Get-UiaElement -Root $grid -ControlType DataItem).Count -eq 2 -and $null -eq (Select-UiaRow -Root $grid -Match 'Alpha' -TimeoutSeconds 1))

        # Remember
        Invoke-UiaElement -Element (Find-UiaElement -Root $dlg -AutomationId 'Remember' -TimeoutSeconds 5)
        $note = Read-Note $c.Process.Id
        Test-That 'Remember reports the package is on the front page now' ($note -like '*FooCorp.FooApp is on the front page now*') "text: $note"
        Invoke-UiaElement -Element (Find-UiaElement -Root $dlg -AutomationId 'Remember' -TimeoutSeconds 5)
        $note = Read-Note $c.Process.Id
        Test-That 'Remember a second time says it was already there' ($note -like '*was already on the front page*') "text: $note"

        # kein Treffer, Fehler
        Invoke-Search $dlg 'none'
        $note = Read-Note $c.Process.Id
        Test-That 'no hits is reported' ($note -like 'Nothing found for [[]none]*') "text: $note"
        Invoke-Search $dlg 'boom'
        $note = Read-Note $c.Process.Id
        Test-That 'a failing search is reported with its message' ($note -like '*search exploded*') "text: $note"

        # Remember ohne Auswahl: leeren Suchbegriff -> kuratierte Liste, nichts gewaehlt
        Invoke-Search $dlg ' '
        $nothing = $false
        foreach ($i in 1..20) { if ((Get-UiaElement -Root $grid -ControlType DataItem).Count -eq 3) { $nothing = $true; break }; Start-Sleep -Milliseconds 200 }
        Test-That 'the remembered package is on the curated list now (3 rows)' $nothing "rows: $((Get-UiaElement -Root $grid -ControlType DataItem).Count)"
        Invoke-UiaElement -Element (Find-UiaElement -Root $dlg -AutomationId 'Remember' -TimeoutSeconds 5)
        $note = Read-Note $c.Process.Id
        Test-That 'Remember without a selection says so' ($note -like 'Nothing selected*') "text: $note"

        # Next
        Invoke-Search $dlg 'foo'
        $row = $null
        foreach ($i in 1..30) { $row = Select-UiaRow -Root $grid -Match 'FooTwin' -TimeoutSeconds 1; if ($row) { break } }
        Test-That 'a hit can be selected' ($null -ne $row)
        Invoke-UiaElement -Element (Find-UiaElement -Root $dlg -AutomationId 'Next' -TimeoutSeconds 5)
    }
    $r = Wait-ChildResult $c
    Test-That 'the dialog returned a result' ($null -ne $r)
    if ($r) {
        Test-That 'Next returns the selected package' ($r.Picked.Id -eq 'OtherCo.FooTwin' -and $r.Picked.Name -eq 'Foo Twin' -and $r.Picked.Version -eq '4.5') "picked: $($r.Picked | ConvertTo-Json -Compress)"
        Test-That 'the publisher is the first part of the id' ($r.Picked.Publisher -eq 'OtherCo') "publisher: $($r.Picked.Publisher)"
        Test-That 'the search was given what was typed' ((@($r.Queries) -join '|') -like '*foo*none*boom*') "queries: $(@($r.Queries) -join '|')"
        Test-That 'Remember wrote the package into catalog.json' ($r.Catalog -match '"packageId": "FooCorp.FooApp"') 'catalog.json has no FooCorp.FooApp'
        Test-That 'Remember kept the other entries' ($r.Catalog -match 'Alpha.Tool' -and $r.Catalog -match 'Beta.Tool')
    }

    # ---- cancel ----------------------------------------------------------------
    $c = Start-Child 'cancel'
    $dlg = Wait-UiaWindow -ProcessId $c.Process.Id -AutomationId 'WinGetDialog' -TimeoutSeconds 60
    if ($dlg) {
        $grid = Find-UiaElement -Root $dlg -AutomationId 'WinGetGrid' -TimeoutSeconds 5
        $null = Select-UiaRow -Root $grid -Match 'Alpha' -TimeoutSeconds 10
        Invoke-UiaElement -Element (Find-UiaElement -Root $dlg -AutomationId 'Cancel' -TimeoutSeconds 5)
    }
    $r = Wait-ChildResult $c
    Test-That 'Cancel returns nothing, even with a row selected' ($null -ne $r -and $null -eq $r.Picked) "picked: $($r.Picked | ConvertTo-Json -Compress)"

    # ---- enter -----------------------------------------------------------------
    $c = Start-Child 'enter'
    $r = Wait-ChildResult $c 60
    Test-That 'Return in the search box searches' ($null -ne $r -and (@($r.Queries) -contains 'enterq')) "queries: $(@($r.Queries) -join '|')"
    Test-That 'Return in the search box does not take Next' ($null -ne $r -and $null -eq $r.Picked)
}
finally {
    foreach ($p in $children) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
    foreach ($f in @(Get-ChildItem -LiteralPath $work -Recurse -File -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    foreach ($d in @(Get-ChildItem -LiteralPath $work -Recurse -Directory -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)) { Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue
}

if ($script:Failures.Count -gt 0) {
    foreach ($f in $script:Failures) { [Console]::WriteLine("FAIL: $f") }
    exit 1
}
[Console]::WriteLine("WinGet search dialog: $($script:Passed) checks, the dialog is operable through UI Automation. PASS")
exit 0
