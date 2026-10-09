<#
    .SYNOPSIS
    Bedient das Hauptfenster ueber UI Automation, wie ein Mensch es tut.

    .DESCRIPTION
    Das Fenster wird in einem zweiten Prozess mit Beispieldaten gezeigt
    (-Child), der Test bedient es und liest danach, was das Fenster
    zurueckgegeben hat. Geprueft wird:

      - jede Aktion hat einen Knopf, der Knopf tut, was sein Name sagt
        (die zurueckgegebene Aktion ist die erwartete),
      - was moeglich ist, folgt aus der markierten Zeile: eine Zeile ohne
        Definition laesst sich weder bearbeiten noch loeschen noch bauen,
      - die Auswahl, die dem Fenster mitgegeben wird, ist beim Oeffnen markiert,
      - der Filter schraenkt die Liste ein,
      - ein Wechsel des Tenants wird gemeldet - aber nicht schon beim Oeffnen.

    Braucht eine angemeldete Desktop-Sitzung: das Fenster erscheint kurz. Kein
    Tenant, kein Netz; das Fenster bekommt nur Beispielzeilen. Aendert nichts an
    Apps.csv oder an Paketen.

    Windows PowerShell 5.1.

    .EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Tests\Test-MainWindowUi.ps1
#>
[CmdletBinding()]
param(
    [switch]$Child,
    [string]$ResultPath,
    [string]$Scenario = 'edit'
)

$ErrorActionPreference = 'Stop'
$rootDir = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------------------
# Kindprozess: zeigt das Fenster mit Beispielzeilen und schreibt das Ergebnis.
# ---------------------------------------------------------------------------
if ($Child) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $rootDir 'Functions\functions.ps1'), [ref]$null, [ref]$null)
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($fn.Extent.Text))
    }

    # Szenario "editdialog" / "editcancel": der Bearbeitungsdialog allein, mit Beispieldaten.
    if ($Scenario -in 'editdialog', 'editcancel') {
        $columns = @(Get-AppsCsvColumns) + 'MyColumn'
        $item = @{}
        foreach ($c in $columns) { $item[$c] = '' }
        $item.DisplayName = 'Sample'; $item.Version = '1.0'; $item.Publisher = 'Pub'; $item.Architecture = 'x64'
        $item.InstallCmd = "Start-ADTProcess -FilePath 'x.exe'"; $item.MyColumn = 'keep me'
        $info = [ordered]@{ 'Package' = 'C:\x\Sample - 1.0'; 'Template' = 'current'; 'Intune' = 'yes'; 'Next step' = 'up to date' }
        $others = @([pscustomobject]@{ DisplayName = 'Taken'; Version = '2.0' })
        $edited = Open-EditDialog -item $item -title 'Edit test' -PropertyOrder $columns -Info $info -Others $others
        $out = [pscustomobject]@{ Cancelled = ($null -eq $edited); Values = $edited }
        [System.IO.File]::WriteAllText($ResultPath, ($out | ConvertTo-Json -Compress -Depth 4), (New-Object System.Text.UTF8Encoding $false))
        exit 0
    }

    # Szenario "loop": die ECHTE Start-InventoryLoop, offline (kein Tenant), gegen
    # eine Wegwerf-Kopie der Konfiguration und die echte Apps.csv. Dass die
    # Schleife das Fenster nach Refresh erneut zeigt und bei Close endet, steht
    # sonst nirgends unter Test.
    if ($Scenario -eq 'loop') {
        $loopRoot = Join-Path (Split-Path -Parent $ResultPath) 'loop-root'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $loopRoot 'Config'), (Join-Path $loopRoot 'packets'), (Join-Path $loopRoot 'Templates')
        Copy-Item -Path (Join-Path $rootDir 'Templates\*') -Destination (Join-Path $loopRoot 'Templates')
        Copy-Item -LiteralPath (Join-Path $rootDir 'Apps.csv') -Destination (Join-Path $loopRoot 'Apps.csv')
        $cfg = [pscustomobject]@{ packetRoot = (Join-Path $loopRoot 'packets'); tenants = @(); removeExistingPacketDirOnEachRun = $true }
        [System.IO.File]::WriteAllText((Join-Path $loopRoot 'Config\config.json'), ($cfg | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))

        # Zaehlen, wie oft die Schleife das Fenster zeigt.
        $script:showCalls = 0
        $realDialog = ${function:Show-InventoryDialog}
        # Per Set-Item statt "function ...": eine zweite Funktionsdefinition gleichen Namens
        # ueberschriebe fuer Pruefung 5 die Parameterliste der echten.
        Set-Item -Path function:Show-InventoryDialog -Value { $script:showCalls++; & $realDialog @args }

        Start-InventoryLoop -RootDir $loopRoot -ToolVersion 'test'
        [System.IO.File]::WriteAllText($ResultPath, ([pscustomobject]@{ Calls = $script:showCalls } | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding $false))
        exit 0
    }

    function New-SampleRow([string]$name, [string]$status, [bool]$hasDef, [bool]$hasPkg, [string]$intune, [string]$next, [string]$template) {
        [pscustomobject]@{
            Key = "$name - 1.0"; AppName = $name; AppVersion = '1.0'; Publisher = 'Sample Inc'
            Definition = $(if ($hasDef) { 'yes' } else { '-' }); Package = $(if ($hasPkg) { 'yes' } else { '-' })
            Template = $template; Status = $status; Intune = $intune; Next = $next
            FullPath = $(if ($hasPkg) { "C:\x\$name - 1.0\deploy.ps1" } else { '' })
            HasDefinition = $hasDef; HasPackage = $hasPkg; DefinitionRecord = $(if ($hasDef) { [pscustomobject]@{ DisplayName = $name; Version = '1.0' } } else { $null })
            Detail = "Definition: $hasDef"
        }
    }
    $rows = @(
        (New-SampleRow 'DefOnly' 'Definition only' $true  $false '-'   'create package' '-'),
        (New-SampleRow 'Both'    'Package'         $true  $true  'yes' 'up to date'     'current'),
        (New-SampleRow 'Orphan'  'No definition'   $false $true  '-'   'package without a row in Apps.csv' 'current')
    )

    $result = Show-InventoryDialog -Inventory $rows -Title 'UI test' -PacketRoot 'C:\x' `
        -TenantNames @('a.onmicrosoft.com', 'b.onmicrosoft.com') -TenantName 'a.onmicrosoft.com' `
        -IntuneRead $true -ConfigPath 'C:\x\config.json' -Select @('DefOnly - 1.0')

    # Die zurueckgegebenen Zeilen auf ihre Schluessel reduzieren, das genuegt dem Test.
    $out = [pscustomobject]@{
        Action     = [string]$result.Action
        TenantName = [string]$result.TenantName
        Keys       = @(@($result.Selection) | ForEach-Object { [string]$_.Key })
    }
    [System.IO.File]::WriteAllText($ResultPath, ($out | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding $false))
    exit 0
}

# ---------------------------------------------------------------------------
# Elternprozess: bedient das Fenster.
# ---------------------------------------------------------------------------
Import-Module (Join-Path $PSScriptRoot 'UiAutomation.psm1') -Force

$script:Failures = New-Object System.Collections.ArrayList
$script:Children = New-Object System.Collections.ArrayList
$script:Passed = 0
function Test-That {
    param([string]$Name, [bool]$Condition, [string]$Detail)
    if ($Condition) { $script:Passed++ }
    else {
        $null = $script:Failures.Add($(if ($Detail) { "$Name - $Detail" } else { $Name }))
    }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('iw32h-ui-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $work

function Start-Child([string]$name) {
    $resultFile = Join-Path $work "$name.json"
    $proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Minimized -ArgumentList @(
        '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
        '-Child', '-ResultPath', ('"{0}"' -f $resultFile), '-Scenario', $name)
    $null = $script:Children.Add($proc)
    return [pscustomobject]@{ Process = $proc; ResultFile = $resultFile }
}

function Wait-ChildResult($child, [int]$TimeoutSeconds = 30) {
    if (-not $child.Process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $child.Process.Kill() } catch { }
        return $null
    }
    if (-not (Test-Path -LiteralPath $child.ResultFile)) { return $null }
    return (Get-Content -LiteralPath $child.ResultFile -Raw | ConvertFrom-Json)
}

# Eine Zeile ueber den Text einer ihrer Zellen waehlen. Der Name einer Zeile
# im Automationsbaum ist der Typname des Objekts dahinter, nicht sein Inhalt.
function Select-GridRowByCell($grid, [string]$text) {
    $rowsFound = Get-UiaElement -Root $grid -ControlType DataItem
    foreach ($row in $rowsFound) {
        foreach ($cell in (Get-UiaElement -Root $row -ControlType Text)) {
            if ($cell.Current.Name -eq $text) {
                $row.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
                return $row
            }
        }
    }
    return $null
}

function Test-ButtonStates($window, [hashtable]$expected, [string]$context) {
    foreach ($id in $expected.Keys) {
        $button = Find-UiaElement -Root $window -AutomationId $id -TimeoutSeconds 5
        if (-not $button) { Test-That "$context : button $id exists" $false; continue }
        Test-That "$context : button $id enabled=$($expected[$id])" ($button.Current.IsEnabled -eq $expected[$id]) "is $($button.Current.IsEnabled)"
    }
}

try {
    # ---- Szenario 1: Knoepfe, Zustaende, Auswahl, Filter, dann Edit --------------
    $c = Start-Child 'edit'
    $window = Wait-UiaWindow -ProcessId $c.Process.Id -AutomationId 'MainDialog' -TimeoutSeconds 60
    Test-That 'the main window appears' ($null -ne $window)
    if ($window) {
        $grid = Find-UiaElement -Root $window -AutomationId 'InventoryGrid' -TimeoutSeconds 10
        Test-That 'the inventory grid exists' ($null -ne $grid)

        foreach ($id in 'Add', 'NewVersion', 'Edit', 'Delete', 'Build', 'Deploy', 'OpenFolder', 'RemoveFolder', 'Settings', 'Refresh', 'Cancel', 'Filter', 'View', 'Tenant', 'Status') {
            Test-That "control $id exists" ($null -ne (Find-UiaElement -Root $window -AutomationId $id -TimeoutSeconds 5))
        }

        if ($grid) {
            Test-That 'three rows are listed' ((Get-UiaElement -Root $grid -ControlType DataItem).Count -eq 3) "rows: $((Get-UiaElement -Root $grid -ControlType DataItem).Count)"

            # Die mitgegebene Auswahl ist beim Oeffnen markiert: DefOnly -> alles moeglich.
            Start-Sleep -Milliseconds 800
            Test-ButtonStates $window @{ Edit = $true; NewVersion = $true; Delete = $true; Build = $true; Deploy = $true; RemoveFolder = $false } 'DefOnly restored as selection'

            # Zeile ohne Definition: nicht bearbeiten, nicht loeschen, nicht bauen - verteilen schon.
            $null = Select-GridRowByCell $grid 'Orphan'
            Start-Sleep -Milliseconds 300
            Test-ButtonStates $window @{ Edit = $false; NewVersion = $false; Delete = $false; Build = $false; Deploy = $true; RemoveFolder = $true } 'Orphan (package, no definition)'

            # Eine Zeile MIT Definition und Paket ist nicht verwaist: der Knopf bleibt aus.
            $null = Select-GridRowByCell $grid 'Both'
            Start-Sleep -Milliseconds 300
            Test-ButtonStates $window @{ RemoveFolder = $false } 'Both (definition and package)'
            $null = Select-GridRowByCell $grid 'Orphan'
            Start-Sleep -Milliseconds 300

            # Filter schraenkt ein.
            $filter = Find-UiaElement -Root $window -AutomationId 'Filter'
            Set-UiaText -Element $filter -Text 'Orphan'
            Start-Sleep -Milliseconds 500
            Test-That 'the filter narrows the list to one row' ((Get-UiaElement -Root $grid -ControlType DataItem).Count -eq 1) "rows: $((Get-UiaElement -Root $grid -ControlType DataItem).Count)"
            $filter.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('')
            Start-Sleep -Milliseconds 500
            Test-That 'clearing the filter shows all rows again' ((Get-UiaElement -Root $grid -ControlType DataItem).Count -eq 3)

            # Edit auf einer Zeile mit Definition gibt Aktion + Zeile zurueck.
            $null = Select-GridRowByCell $grid 'Both'
            Start-Sleep -Milliseconds 300
            Invoke-UiaElement -Element (Find-UiaElement -Root $window -AutomationId 'Edit')
        }
    }
    $r = Wait-ChildResult $c
    Test-That 'Edit: the window returned a result' ($null -ne $r)
    if ($r) {
        Test-That 'Edit: the action is Edit' ($r.Action -eq 'Edit') "was '$($r.Action)'"
        Test-That 'Edit: the selected row came back' (@($r.Keys) -contains 'Both - 1.0' -and @($r.Keys).Count -eq 1) "keys: $(@($r.Keys) -join ',')"
    }

    # ---- Szenario 2: Tenant-Wechsel wird gemeldet, aber nicht schon beim Oeffnen --
    $c = Start-Child 'tenant'
    $window = Wait-UiaWindow -ProcessId $c.Process.Id -AutomationId 'MainDialog' -TimeoutSeconds 60
    Test-That 'tenant: the main window appears' ($null -ne $window)
    if ($window) {
        Start-Sleep -Seconds 2
        Test-That 'tenant: opening the window does not report a tenant switch by itself' (-not $c.Process.HasExited)
        $combo = Find-UiaElement -Root $window -AutomationId 'Tenant'
        if ($combo) {
            $combo.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
            Start-Sleep -Milliseconds 500
            $item = $null
            $listItems = $combo.FindAll([Windows.Automation.TreeScope]::Descendants,
                (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ListItem)))
            foreach ($candidate in $listItems) { if ($candidate.Current.Name -eq 'b.onmicrosoft.com') { $item = $candidate } }
            Test-That 'tenant: the second tenant is offered' ($null -ne $item)
            if ($item) { $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select() }
        }
    }
    $r = Wait-ChildResult $c
    Test-That 'tenant: the window returned a result' ($null -ne $r)
    if ($r) {
        Test-That 'tenant: the action is SwitchTenant' ($r.Action -eq 'SwitchTenant') "was '$($r.Action)'"
        Test-That 'tenant: the chosen tenant is named' ($r.TenantName -eq 'b.onmicrosoft.com') "was '$($r.TenantName)'"
    }

    # ---- Szenario 4: die echte Schleife, offline --------------------------------
    $expectedRows = @(Import-Csv -LiteralPath (Join-Path $rootDir 'Apps.csv') -Delimiter ';').Count
    $c = Start-Child 'loop'
    $window = Wait-UiaWindow -ProcessId $c.Process.Id -AutomationId 'MainDialog' -TimeoutSeconds 90
    Test-That 'loop: the main window appears' ($null -ne $window)
    if ($window) {
        $statusText = (Find-UiaElement -Root $window -AutomationId 'Status' -TimeoutSeconds 10).Current.Name
        Test-That 'loop: every Apps.csv row is listed' ($statusText -match ('^{0} application\(s\)' -f $expectedRows)) "status line: '$statusText'"
        Test-That 'loop: without a tenant the status line says the tenant was not read' ($statusText -match 'tenant was not read') "status line: '$statusText'"

        # Refresh schliesst das Fenster und die Schleife zeigt es neu.
        Invoke-UiaElement -Element (Find-UiaElement -Root $window -AutomationId 'Refresh')
        Start-Sleep -Seconds 3
        $window = Wait-UiaWindow -ProcessId $c.Process.Id -AutomationId 'MainDialog' -TimeoutSeconds 60
        Test-That 'loop: after Refresh the window is shown again' ($null -ne $window)
        if ($window) { Invoke-UiaElement -Element (Find-UiaElement -Root $window -AutomationId 'Cancel') }
    }
    $r = Wait-ChildResult $c 60
    Test-That 'loop: the loop ended when the window was closed' ($null -ne $r)
    if ($r) { Test-That 'loop: the window was shown twice (start, Refresh)' ($r.Calls -eq 2) "calls: $($r.Calls)" }

    # ---- Szenario 5: Remove orphan folder gibt Aktion + verwaiste Zeile zurueck ----
    $c = Start-Child 'orphan'
    $window = Wait-UiaWindow -ProcessId $c.Process.Id -AutomationId 'MainDialog' -TimeoutSeconds 60
    Test-That 'orphan: the main window appears' ($null -ne $window)
    if ($window) {
        $grid = Find-UiaElement -Root $window -AutomationId 'InventoryGrid' -TimeoutSeconds 10
        $null = Select-GridRowByCell $grid 'Orphan'
        Start-Sleep -Milliseconds 300
        Invoke-UiaElement -Element (Find-UiaElement -Root $window -AutomationId 'RemoveFolder')
    }
    $r = Wait-ChildResult $c
    Test-That 'orphan: the window returned a result' ($null -ne $r)
    if ($r) {
        Test-That 'orphan: the action is RemoveFolder' ($r.Action -eq 'RemoveFolder') "was '$($r.Action)'"
        Test-That 'orphan: the orphan row came back' (@($r.Keys) -contains 'Orphan - 1.0' -and @($r.Keys).Count -eq 1) "keys: $(@($r.Keys) -join ',')"
    }

    # ---- Szenario 6: der Bearbeitungsdialog ----------------------------------------
    $c = Start-Child 'editdialog'
    $dlg = Wait-UiaWindow -ProcessId $c.Process.Id -AutomationId 'EditDialog' -TimeoutSeconds 60
    Test-That 'editdialog: the dialog appears' ($null -ne $dlg)
    if ($dlg) {
        # Jede Spalte hat ein Steuerelement, und es ist das passende.
        $expectedType = @{ Architecture = 'ControlType.ComboBox'; MinimumOS = 'ControlType.ComboBox'; Interactive = 'ControlType.CheckBox'; SingleMSI = 'ControlType.CheckBox'
                           InstallCmd = 'ControlType.Edit'; UninstallCmd = 'ControlType.Edit'; DisplayName = 'ControlType.Edit'; MyColumn = 'ControlType.Edit' }
        foreach ($col in 'ProgramID', 'Publisher', 'DisplayName', 'Version', 'WinGetParams', 'SingleMSI', 'InstallCmd', 'UninstallCmd', 'logoURL', 'Architecture', 'MinimumOS', 'MsiProductCode', 'Interactive', 'ArpName', 'MyColumn') {
            $el = Find-UiaElement -Root $dlg -AutomationId $col -TimeoutSeconds 5
            Test-That "editdialog: a control for $col exists" ($null -ne $el)
            if ($el -and $expectedType.ContainsKey($col)) {
                Test-That "editdialog: $col is a $($expectedType[$col])" ($el.Current.ControlType.ProgrammaticName -eq $expectedType[$col]) "is $($el.Current.ControlType.ProgrammaticName)"
            }
        }
        foreach ($id in 'OK', 'Cancel', 'FromWinGet', 'FromMsi', 'Error') {
            Test-That "editdialog: $id exists" ($null -ne (Find-UiaElement -Root $dlg -AutomationId $id -TimeoutSeconds 5))
        }
        $infoPackage = Find-UiaElement -Root $dlg -AutomationId 'InfoPackage' -TimeoutSeconds 5
        Test-That 'editdialog: the info box shows the package folder' ($infoPackage -and $infoPackage.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value -eq 'C:\x\Sample - 1.0')

        $setText = { param($id, $text) (Find-UiaElement -Root $dlg -AutomationId $id).GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($text) }
        $isEnabled = { param($id) (Find-UiaElement -Root $dlg -AutomationId $id).Current.IsEnabled }

        # WinGet-Felder gelten nur bei Version = LatestAvailable.
        Test-That 'editdialog: ProgramID is disabled for a version number' (-not (& $isEnabled 'ProgramID'))
        Test-That 'editdialog: WinGetParams is disabled for a version number' (-not (& $isEnabled 'WinGetParams'))
        & $setText 'Version' 'LatestAvailable'
        Start-Sleep -Milliseconds 400
        Test-That 'editdialog: ProgramID is enabled for LatestAvailable' (& $isEnabled 'ProgramID')
        Test-That 'editdialog: WinGetParams is enabled for LatestAvailable' (& $isEnabled 'WinGetParams')

        # Der Hinweis zu ArpName zeigt den Suchnamen, und er folgt dem Feld.
        $hint = (Find-UiaElement -Root $dlg -AutomationId 'ArpNameHint').Current.Name
        Test-That 'editdialog: the ArpName hint names the search name (DisplayName)' ($hint -match "STARTS WITH 'Sample'") "hint: $hint"
        & $setText 'ArpName' 'Foo Bar'
        Start-Sleep -Milliseconds 400
        $hint = (Find-UiaElement -Root $dlg -AutomationId 'ArpNameHint').Current.Name
        Test-That 'editdialog: the ArpName hint follows the field' ($hint -match "STARTS WITH 'Foo Bar'") "hint: $hint"

        # OK prueft und bleibt offen.
        $okButton = Find-UiaElement -Root $dlg -AutomationId 'OK'
        & $setText 'DisplayName' ''
        Invoke-UiaElement -Element $okButton
        Start-Sleep -Milliseconds 600
        Test-That 'editdialog: OK with an empty name keeps the dialog open' (-not $c.Process.HasExited)
        Test-That 'editdialog: the error names the empty DisplayName' ((Find-UiaElement -Root $dlg -AutomationId 'Error').Current.Name -match 'DisplayName is empty')
        & $setText 'DisplayName' 'Taken'
        & $setText 'Version' '2.0'
        Invoke-UiaElement -Element $okButton
        Start-Sleep -Milliseconds 600
        Test-That 'editdialog: OK with a duplicate name and version keeps the dialog open' (-not $c.Process.HasExited)
        Test-That 'editdialog: the error says it already exists' ((Find-UiaElement -Root $dlg -AutomationId 'Error').Current.Name -match 'already exists')

        # Gueltige Werte: zurueckgegeben werden die geaenderten UND die unberuehrten.
        & $setText 'DisplayName' 'NewApp'
        & $setText 'Version' '3.0'
        & $setText 'Architecture' 'arm64'
        (Find-UiaElement -Root $dlg -AutomationId 'Interactive').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
        Start-Sleep -Milliseconds 300
        Test-That 'editdialog: ProgramID is disabled again after leaving LatestAvailable' (-not (& $isEnabled 'ProgramID'))
        Invoke-UiaElement -Element $okButton
    }
    $r = Wait-ChildResult $c
    Test-That 'editdialog: the dialog returned a result' ($null -ne $r)
    if ($r) {
        $v = $r.Values
        Test-That 'editdialog: the dialog was not cancelled' (-not $r.Cancelled)
        Test-That 'editdialog: DisplayName and Version are the new ones' ($v.DisplayName -eq 'NewApp' -and $v.Version -eq '3.0') "got '$($v.DisplayName)' / '$($v.Version)'"
        Test-That 'editdialog: Architecture is the one typed' ($v.Architecture -eq 'arm64') "got '$($v.Architecture)'"
        Test-That 'editdialog: the Interactive checkbox comes back as true' ($v.Interactive -eq 'true') "got '$($v.Interactive)'"
        Test-That 'editdialog: untouched SingleMSI comes back empty' ($v.SingleMSI -eq '') "got '$($v.SingleMSI)'"
        Test-That 'editdialog: untouched values survive (Publisher, InstallCmd, own column)' ($v.Publisher -eq 'Pub' -and $v.InstallCmd -match 'Start-ADTProcess' -and $v.MyColumn -eq 'keep me') "got '$($v.Publisher)' / '$($v.InstallCmd)' / '$($v.MyColumn)'"
        Test-That 'editdialog: ArpName typed is kept' ($v.ArpName -eq 'Foo Bar') "got '$($v.ArpName)'"
    }

    $c = Start-Child 'editcancel'
    $dlg = Wait-UiaWindow -ProcessId $c.Process.Id -AutomationId 'EditDialog' -TimeoutSeconds 60
    if ($dlg) {
        (Find-UiaElement -Root $dlg -AutomationId 'DisplayName').GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('Changed but cancelled')
        Invoke-UiaElement -Element (Find-UiaElement -Root $dlg -AutomationId 'Cancel')
    }
    $r = Wait-ChildResult $c
    Test-That 'editcancel: the dialog returned a result' ($null -ne $r)
    if ($r) { Test-That 'editcancel: Cancel returns nothing' ($r.Cancelled -eq $true) "cancelled: $($r.Cancelled)" }

    # ---- Szenario 3: Close gibt Cancel zurueck --------------------------------
    $c = Start-Child 'close'
    $window = Wait-UiaWindow -ProcessId $c.Process.Id -AutomationId 'MainDialog' -TimeoutSeconds 60
    if ($window) { Invoke-UiaElement -Element (Find-UiaElement -Root $window -AutomationId 'Cancel') }
    $r = Wait-ChildResult $c
    Test-That 'close: the window returned a result' ($null -ne $r)
    if ($r) { Test-That 'close: the action is Cancel' ($r.Action -eq 'Cancel') "was '$($r.Action)'" }
}
catch {
    # Ein unbehandelter Fehler ist ein Befund - sonst bliebe nur eine Ausnahme ohne FAIL-Zeile.
    $null = $script:Failures.Add(("unhandled error in the test run: {0} (line {1})" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber))
}
finally {
    # Kein Fenster zuruecklassen, auch wenn ein Schritt davor scheiterte.
    foreach ($proc in $script:Children) { try { if (-not $proc.HasExited) { $proc.Kill() } } catch { } }
    # Ohne -Recurse (Pruefung 13): erst die Dateien, dann die leeren Ordner, tief zuerst.
    foreach ($f in @(Get-ChildItem -LiteralPath $work -Recurse -File -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $f.FullName -Force }
    foreach ($d in @(Get-ChildItem -LiteralPath $work -Recurse -Directory -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)) { Remove-Item -LiteralPath $d.FullName -Force }
    Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue
}

if ($script:Failures.Count -gt 0) {
    foreach ($f in $script:Failures) { [Console]::WriteLine("FAIL: $f") }
    [Console]::WriteLine(("{0} passed, {1} failed" -f $script:Passed, $script:Failures.Count))
    exit 1
}
[Console]::WriteLine(("Main window UI: {0} checks passed (buttons, row-dependent states, restored selection, filter, tenant switch, close). PASS" -f $script:Passed))
exit 0
