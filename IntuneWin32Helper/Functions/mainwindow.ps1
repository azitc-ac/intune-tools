# ============================================================================
#  Hauptfenster: das Inventar ist der Ausgangspunkt
#
#  Muster aus SCCMAppHelper (Show-InventoryDialog). Pro App eine Zeile; links
#  Definition und Paket, rechts die App im Tenant. Jede Aktion geht von dieser
#  Liste aus - anlegen, bauen, verteilen. Die Kacheln "Create / Create and
#  deploy / Deploy" und die beiden Auswahldialoge dahinter gibt es nicht mehr:
#  sie zeigten je einen Ausschnitt desselben Zustands.
#
#  Das Fenster fuehrt nichts aus. Es gibt die Aktion und die markierten Zeilen
#  zurueck (Start-InventoryLoop arbeitet sie ab), damit die Konsole dort bleibt,
#  wo gearbeitet wird, und das Fenster nach jeder Aktion neu aufgebaut wird.
# ============================================================================

function Show-InventoryDialog {
    <#
        .SYNOPSIS
        Das Hauptfenster. Gibt { Action, Selection, TenantName } zurueck.

        .DESCRIPTION
        Action: Add | NewVersion | Edit | Delete | Build | Publish | Remove |
                OpenFolder | RemoveFolder | Refresh | SwitchTenant | CheckTenant | Cancel | Closed
        Die Knoepfe folgen den drei Dingen einer App (Definition, Paket, Intune); welcher gerade moeglich
        ist, entscheidet Get-InventoryActionState aus den markierten Zeilen - der Rest ist ausgegraut.
        Jede Aktion hier hat in Start-InventoryLoop einen Zweig - das prueft
        Tests\Invoke-RepoChecks.ps1 (kein Knopf ohne Gegenstueck).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Inventory,
        [string]$Title = 'IntuneWin32Helper',
        [string]$PacketRoot = '',
        [string[]]$TenantNames = @(),
        [string]$TenantName = '',
        [bool]$IntuneRead = $true,
        [string]$ConfigPath = '',
        # Schluessel ("<Name> - <Version>") der Zeilen, die beim Oeffnen markiert
        # sein sollen. Das Fenster wird nach jeder Aktion neu gebaut; die Zeile,
        # an der gerade gearbeitet wurde, soll nicht neu gesucht werden muessen.
        [string[]]$Select = @()
    )

    Add-Type -AssemblyName PresentationCore      -ErrorAction SilentlyContinue | Out-Null
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue | Out-Null

    $rows = @($Inventory)

    $window = New-Object Windows.Window
    $window.Title = $Title
    $window.Width = 1280
    $window.Height = 720
    $window.MinWidth = 960
    $window.MinHeight = 480
    $window.WindowStartupLocation = 'CenterScreen'
    [Windows.Automation.AutomationProperties]::SetAutomationId($window, 'MainDialog')

    $grid = New-Object Windows.Controls.Grid
    $grid.Margin = '12'
    foreach ($height in 'Auto', '*', 'Auto', 'Auto') {
        $rowDefinition = New-Object Windows.Controls.RowDefinition
        $rowDefinition.Height = $(if ($height -eq '*') { New-Object Windows.GridLength -ArgumentList 1, ([Windows.GridUnitType]::Star) } else { [Windows.GridLength]::Auto })
        $null = $grid.RowDefinitions.Add($rowDefinition)
    }

    # --- obere Leiste: Tenant, Ansicht, Filter, Refresh ---
    $top = New-Object Windows.Controls.DockPanel
    $top.Margin = '0,0,0,8'

    $refreshButton = New-Object Windows.Controls.Button
    $refreshButton.Content = 'Refresh'
    $refreshButton.Padding = '14,4'
    $refreshButton.Margin = '8,0,0,0'
    $refreshButton.ToolTip = 'Read Apps.csv, the package folders and the tenant again'
    [Windows.Automation.AutomationProperties]::SetAutomationId($refreshButton, 'Refresh')
    [Windows.Controls.DockPanel]::SetDock($refreshButton, 'Right')
    $null = $top.Children.Add($refreshButton)

    $checkTenantButton = New-Object Windows.Controls.Button
    $checkTenantButton.Content = 'Check tenant'
    $checkTenantButton.Padding = '14,4'
    $checkTenantButton.Margin = '8,0,0,0'
    $checkTenantButton.ToolTip = 'Sign in again and test what the app registration of this tenant may do (read, create apps)'
    [Windows.Automation.AutomationProperties]::SetAutomationId($checkTenantButton, 'CheckTenant')
    [Windows.Controls.DockPanel]::SetDock($checkTenantButton, 'Right')
    $null = $top.Children.Add($checkTenantButton)

    $tenantLabel = New-Object Windows.Controls.TextBlock
    $tenantLabel.Text = 'Tenant:'
    $tenantLabel.VerticalAlignment = 'Center'
    $tenantLabel.Margin = '0,0,6,0'
    [Windows.Controls.DockPanel]::SetDock($tenantLabel, 'Left')
    $null = $top.Children.Add($tenantLabel)

    $tenantItems = @('(not connected)') + @($TenantNames)
    $initialTenantIndex = 0
    if ($TenantName) {
        $found = [array]::IndexOf($tenantItems, $TenantName)
        if ($found -ge 0) { $initialTenantIndex = $found }
    }
    $tenantBox = New-Object Windows.Controls.ComboBox
    $tenantBox.ItemsSource = $tenantItems
    $tenantBox.SelectedIndex = $initialTenantIndex
    $tenantBox.MinWidth = 200
    $tenantBox.Margin = '0,0,12,0'
    $tenantBox.VerticalContentAlignment = 'Center'
    $tenantBox.ToolTip = 'The tenant whose apps the Intune column shows - and where Deploy uploads to'
    [Windows.Automation.AutomationProperties]::SetAutomationId($tenantBox, 'Tenant')
    [Windows.Controls.DockPanel]::SetDock($tenantBox, 'Left')
    $null = $top.Children.Add($tenantBox)

    # Die Ansicht: welcher der drei Zustaende einer Zeile interessiert.
    $views = @(
        [pscustomobject]@{ Name = 'All (foreign Intune apps hidden)'; Test = { $_.Origin -ne 'foreign' } },
        [pscustomobject]@{ Name = 'Definition only (no package)';     Test = { $_.Status -eq 'Definition only' } },
        [pscustomobject]@{ Name = 'Package, not in Intune';           Test = { $_.HasPackage -and ($_.Intune -eq '-' -or $_.Intune -like 'other version*') } },
        [pscustomobject]@{ Name = 'In Intune';                        Test = { $_.Intune -like 'yes*' -or $_.Intune -eq 'no content' } },
        [pscustomobject]@{ Name = 'Template outdated';                Test = { $_.Template -eq 'outdated' -or $_.Template -eq 'unstamped' } },
        [pscustomobject]@{ Name = 'Duplicates or empty in Intune';    Test = { $_.Intune -eq 'no content' -or $_.Intune -like 'yes (*' } },
        [pscustomobject]@{ Name = 'Package without definition';       Test = { $_.HasPackage -and -not $_.HasDefinition } },
        [pscustomobject]@{ Name = 'Intune only (created by this tool)'; Test = { $_.IntuneOnly -and $_.Origin -eq 'tool' } },
        [pscustomobject]@{ Name = 'Foreign apps in Intune';           Test = { $_.Origin -eq 'foreign' } },
        [pscustomobject]@{ Name = 'Everything, incl. foreign apps';   Test = { $true } }
    )
    $viewLabel = New-Object Windows.Controls.TextBlock
    $viewLabel.Text = 'Show:'
    $viewLabel.VerticalAlignment = 'Center'
    $viewLabel.Margin = '0,0,6,0'
    [Windows.Controls.DockPanel]::SetDock($viewLabel, 'Left')
    $null = $top.Children.Add($viewLabel)

    $viewBox = New-Object Windows.Controls.ComboBox
    $viewBox.ItemsSource = @($views | ForEach-Object { $_.Name })
    $viewBox.SelectedIndex = 0
    $viewBox.Width = 230
    $viewBox.Margin = '0,0,8,0'
    $viewBox.VerticalContentAlignment = 'Center'
    [Windows.Automation.AutomationProperties]::SetAutomationId($viewBox, 'View')
    [Windows.Controls.DockPanel]::SetDock($viewBox, 'Left')
    $null = $top.Children.Add($viewBox)

    $filterBox = New-Object Windows.Controls.TextBox
    $filterBox.Padding = '4'
    $filterBox.VerticalContentAlignment = 'Center'
    $filterBox.ToolTip = 'Filter - matches name, version, publisher, package state, Intune state and next step'
    [Windows.Automation.AutomationProperties]::SetAutomationId($filterBox, 'Filter')
    $null = $top.Children.Add($filterBox)
    [Windows.Controls.Grid]::SetRow($top, 0)
    $null = $grid.Children.Add($top)

    # --- die Liste ---
    $dataGrid = New-Object Windows.Controls.DataGrid
    $dataGrid.AutoGenerateColumns = $false
    $dataGrid.IsReadOnly = $true
    $dataGrid.CanUserSortColumns = $true
    $dataGrid.SelectionMode = 'Extended'
    $dataGrid.SelectionUnit = 'FullRow'
    $dataGrid.GridLinesVisibility = 'Horizontal'
    $dataGrid.HeadersVisibility = 'Column'
    [Windows.Automation.AutomationProperties]::SetAutomationId($dataGrid, 'InventoryGrid')

    $converter = New-Object Windows.Media.BrushConverter
    $leftHeaderBrush  = $converter.ConvertFromString('#EDEDED')   # Definition und Paket
    $rightHeaderBrush = $converter.ConvertFromString('#D6E6F7')   # Tenant
    $separatorBrush   = $converter.ConvertFromString('#7FA6D1')

    # Farben je Zustand: gruen ist erledigt, blau der naechste Schritt, orange
    # will angesehen werden, rot stimmt nicht, grau fehlt noch.
    $statusColors = @(
        @('Package',                      'DarkGreen'),
        @('Package, template outdated',   'DarkOrange'),
        @('Package, template unstamped',  'DarkOrange'),
        @('Definition only',              'Gray'),
        @('No definition',                'Firebrick')
    )
    $nextColors = @(
        @('up to date',                                       'DarkGreen'),
        @('deploy',                                           'DodgerBlue'),
        @('renew from template, then deploy',                 'DarkOrange'),
        @('check duplicates in Intune',                       'DarkOrange'),
        @('remove the entry without content in Intune',       'Firebrick'),
        @('package without a row in Apps.csv',                'Firebrick'),
        @('create package',                                   'Gray')
    )

    $columnSpecs = @(
        @{ Header = 'Application'; Binding = 'AppName';    Width = 250; Right = $false; Colors = $null },
        @{ Header = 'Version';     Binding = 'AppVersion'; Width = 120; Right = $false; Colors = $null },
        @{ Header = 'Publisher';   Binding = 'Publisher';  Width = 170; Right = $false; Colors = $null },
        @{ Header = 'Package';     Binding = 'Status';     Width = 200; Right = $false; Colors = $statusColors },
        @{ Header = 'Intune';      Binding = 'Intune';     Width = 190; Right = $true;  Colors = $null; Separator = $true },
        @{ Header = 'Next step';   Binding = 'Next';       Width = 0;   Right = $true;  Colors = $nextColors }
    )

    foreach ($spec in $columnSpecs) {
        $column = New-Object Windows.Controls.DataGridTextColumn
        $column.Header = $spec.Header
        $column.Binding = New-Object Windows.Data.Binding($spec.Binding)
        $column.CanUserSort = $true
        if ($spec.Width -gt 0) { $column.Width = $spec.Width }
        else { $column.Width = New-Object Windows.Controls.DataGridLength -ArgumentList 1, ([Windows.Controls.DataGridLengthUnitType]::Star) }

        try {
            # Die Kopfzeile sagt, auf welcher Seite die Spalte steht.
            $headerStyle = New-Object Windows.Style -ArgumentList ([Windows.Controls.Primitives.DataGridColumnHeader])
            $headerBrush = $(if ($spec.Right) { $rightHeaderBrush } else { $leftHeaderBrush })
            $null = $headerStyle.Setters.Add((New-Object Windows.Setter -ArgumentList ([Windows.Controls.Control]::BackgroundProperty), $headerBrush))
            $null = $headerStyle.Setters.Add((New-Object Windows.Setter -ArgumentList ([Windows.Controls.Control]::PaddingProperty), (New-Object Windows.Thickness -ArgumentList 8, 5, 8, 5)))
            $null = $headerStyle.Setters.Add((New-Object Windows.Setter -ArgumentList ([Windows.Controls.Control]::FontWeightProperty), ([Windows.FontWeights]::SemiBold)))
            if ($spec.Separator) {
                $null = $headerStyle.Setters.Add((New-Object Windows.Setter -ArgumentList ([Windows.Controls.Control]::BorderBrushProperty), $separatorBrush))
                $null = $headerStyle.Setters.Add((New-Object Windows.Setter -ArgumentList ([Windows.Controls.Control]::BorderThicknessProperty), (New-Object Windows.Thickness -ArgumentList 2, 0, 0, 0)))
            }
            $column.HeaderStyle = $headerStyle

            $cellStyle = New-Object Windows.Style -ArgumentList ([Windows.Controls.DataGridCell])
            if ($spec.Separator) {
                $null = $cellStyle.Setters.Add((New-Object Windows.Setter -ArgumentList ([Windows.Controls.Control]::BorderBrushProperty), $separatorBrush))
                $null = $cellStyle.Setters.Add((New-Object Windows.Setter -ArgumentList ([Windows.Controls.Control]::BorderThicknessProperty), (New-Object Windows.Thickness -ArgumentList 2, 0, 0, 0)))
            }
            foreach ($pair in @($spec.Colors)) {
                if (-not $pair) { continue }
                $trigger = New-Object Windows.DataTrigger
                $trigger.Binding = New-Object Windows.Data.Binding($spec.Binding)
                $trigger.Value = $pair[0]
                $brush = [System.Windows.Media.Brushes]::($pair[1])
                $null = $trigger.Setters.Add((New-Object Windows.Setter -ArgumentList ([Windows.Controls.Control]::ForegroundProperty), $brush))
                $null = $cellStyle.Triggers.Add($trigger)
            }
            $column.CellStyle = $cellStyle
        }
        catch { }   # Optik - kein Grund, das Fenster nicht zu zeigen
        $null = $dataGrid.Columns.Add($column)
    }

    # Der Tooltip einer Zeile nennt alle drei Zustaende.
    try {
        $rowStyle = New-Object Windows.Style -ArgumentList ([Windows.Controls.DataGridRow])
        $null = $rowStyle.Setters.Add((New-Object Windows.Setter -ArgumentList ([Windows.Controls.DataGridRow]::ToolTipProperty), (New-Object Windows.Data.Binding('Detail'))))
        $dataGrid.RowStyle = $rowStyle
    }
    catch { }

    # Die erste Ansicht (fremde Intune-Apps ausgeblendet) gilt schon beim Oeffnen, nicht erst nach dem ersten Filterwechsel.
    $dataGrid.ItemsSource = @($rows | Where-Object $views[0].Test)
    [Windows.Controls.Grid]::SetRow($dataGrid, 1)
    $null = $grid.Children.Add($dataGrid)

    # --- Statuszeile ---
    $status = New-Object Windows.Controls.TextBlock
    $status.Margin = '0,8,0,0'
    $status.Foreground = [System.Windows.Media.Brushes]::DimGray
    $status.TextWrapping = 'Wrap'
    [Windows.Automation.AutomationProperties]::SetAutomationId($status, 'Status')
    $ownRows     = @($rows | Where-Object { $_.Origin -ne 'foreign' })
    $foreignRows = @($rows | Where-Object { $_.Origin -eq 'foreign' })
    $withPackage = @($ownRows | Where-Object { $_.HasPackage }).Count
    $inIntune    = @($ownRows | Where-Object { $_.Intune -like 'yes*' -or $_.Intune -eq 'no content' }).Count
    $summary = ('{0} application(s) - {1} with a package in {2} - {3} in Intune{4}{5}' -f
                    $ownRows.Count, $withPackage, $PacketRoot, $inIntune,
                    $(if ($foreignRows.Count -gt 0) { (' - {0} foreign Intune app(s) hidden (see Show:)' -f $foreignRows.Count) } else { '' }),
                    $(if (-not $IntuneRead) { ' - the tenant was not read, the Intune column is empty' } else { '' }))
    $status.Text = $summary
    $defaultShownCount = $ownRows.Count
    [Windows.Controls.Grid]::SetRow($status, 2)
    $null = $grid.Children.Add($status)

    # Ansicht und Textfilter gelten zusammen; die Statuszeile sagt, wie viele zu sehen sind.
    $applyFilter = {
        $view   = $views[[Math]::Max(0, $viewBox.SelectedIndex)]
        $needle = $filterBox.Text
        $items  = @($rows | Where-Object $view.Test)
        if (-not [string]::IsNullOrWhiteSpace($needle)) {
            $items = @($items | Where-Object {
                $row = $_
                @(@('AppName', 'AppVersion', 'Publisher', 'Status', 'Intune', 'Next') | Where-Object { [string]$row.$_ -like "*$needle*" }).Count -gt 0
            })
        }
        $dataGrid.ItemsSource = $null
        $dataGrid.ItemsSource = @($items)
        $status.Text = $(if ($items.Count -eq $defaultShownCount -and $viewBox.SelectedIndex -le 0 -and [string]::IsNullOrWhiteSpace($needle)) { $summary } else { '{0} of {1} shown - {2}' -f $items.Count, $rows.Count, $summary })
    }
    $filterBox.Add_TextChanged($applyFilter)
    $viewBox.Add_SelectionChanged($applyFilter)

    # --- Knopfleiste ---
    $bar = New-Object Windows.Controls.DockPanel
    $bar.Margin = '0,12,0,0'
    $bar.LastChildFill = $false
    $left = New-Object Windows.Controls.StackPanel
    $left.Orientation = 'Horizontal'
    [Windows.Controls.DockPanel]::SetDock($left, 'Left')
    $right = New-Object Windows.Controls.StackPanel
    $right.Orientation = 'Horizontal'
    [Windows.Controls.DockPanel]::SetDock($right, 'Right')
    $null = $bar.Children.Add($left)
    $null = $bar.Children.Add($right)
    [Windows.Controls.Grid]::SetRow($bar, 3)
    $null = $grid.Children.Add($bar)

    $window.Tag = $null
    $choose = {
        param([string]$action)
        $selected = @($dataGrid.SelectedItems | Where-Object { $_ -isnot [int] })
        if ($action -in 'NewVersion', 'Edit', 'Delete', 'Build', 'Publish', 'Remove', 'RemoveFolder' -and $selected.Count -eq 0) {
            $null = Show-ConfirmDialog -Text 'Select one or more rows first.' -Title 'IntuneWin32Helper' -Buttons OK -Icon Information -Default OK -Owner $window
            return
        }
        $chosenTenant = ''
        if ($tenantBox.SelectedIndex -gt 0) { $chosenTenant = [string]$tenantBox.SelectedItem }
        $window.Tag = [pscustomobject]@{ Action = $action; Selection = $selected; TenantName = $chosenTenant }
        $window.Close()
    }

    $newButton = {
        param([string]$caption, [string]$id, [string]$tip, $panel)
        $button = New-Object Windows.Controls.Button
        $button.Content = $caption
        $button.Padding = '14,6'
        $button.Margin = '0,0,8,0'
        $button.ToolTip = $tip
        # Ein ausgegrauter Knopf soll im Tooltip sagen, warum (WPF zeigt ihn sonst nur bei aktiven Knoepfen).
        [Windows.Controls.ToolTipService]::SetShowOnDisabled($button, $true)
        [Windows.Automation.AutomationProperties]::SetAutomationId($button, $id)
        $null = $panel.Children.Add($button)
        return $button
    }

    $settingsButton = New-Object Windows.Controls.Button
    $settingsButton.ToolTip = 'Settings'
    $settingsButton.Padding = '10,4'
    $settingsButton.Margin = '0,0,8,0'
    $settingsButton.MinWidth = 40
    [Windows.Automation.AutomationProperties]::SetAutomationId($settingsButton, 'Settings')
    $settingsIcon = New-Object Windows.Controls.TextBlock
    $settingsIcon.Text = [char]0xE713
    $settingsIcon.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe MDL2 Assets'
    $settingsIcon.FontSize = 16
    $settingsIcon.Foreground = [System.Windows.Media.Brushes]::Gray
    $settingsButton.Content = $settingsIcon
    $null = $left.Children.Add($settingsButton)

    $folderButton  = & $newButton 'Open folder'      'OpenFolder' 'The package folder of the selected row, or the package root' $left
    $orphanButton  = & $newButton 'Remove orphan folder' 'RemoveFolder' 'Delete the package folder of selected rows that have no definition in Apps.csv - the app in Intune stays' $left

    # Links: aufraeumen (loescht etwas). Rechts: der Weg einer App in drei Schritten, von links nach rechts -
    # Definition, Paket, Intune. Zwischen den Gruppen eine Luecke, damit man die Schritte sieht.
    $removeButton = & $newButton 'Remove from Intune' 'Remove' 'Delete the app of the selected row in Intune (name AND version) - with its assignments. The definition and the package folder stay' $left

    $baseTips = @{}
    $addButton     = & $newButton 'Add...'            'Add'        'Add an application definition (the editor offers WinGet and MSI to prefill)' $right
    $versionButton = & $newButton 'New version...'    'NewVersion' 'Copy the selected definition as a new version (another version number = another app in Intune)' $right
    $editButton    = & $newButton 'Edit...'           'Edit'       'Edit the definition of the selected row. Afterwards: Build package, then Publish to Intune' $right
    $deleteButton  = & $newButton 'Delete definition' 'Delete'     'Remove the row from Apps.csv - the package folder and the app in Intune stay' $right
    $deleteButton.Margin = '0,0,24,0'
    $buildButton   = & $newButton 'Build package'     'Build'      'Create the package folder on disk from the definition (replaces the one that is there)' $right
    $buildButton.Margin = '0,0,24,0'
    $publishButton = & $newButton 'Publish to Intune' 'Publish'    'Put the app into Intune: create it, or - if it is already there - bring it up to date (package, detection, commands, requirement, icon; the assignments stay). A row without a package is built first' $right
    $publishButton.Margin = '0,0,24,0'
    $closeButton   = & $newButton 'Close'             'Cancel'     'Close the tool' $right
    $closeButton.Margin = '0'
    $closeButton.IsCancel = $true
    foreach ($b in $removeButton, $addButton, $versionButton, $editButton, $deleteButton, $buildButton, $publishButton) { $baseTips[$b] = [string]$b.ToolTip }

    $settingsButton.Add_Click({
        try {
            $null = Edit-SettingsDialog -Owner $window -PreferredPaths @($ConfigPath)
        }
        catch {
            $null = Show-ConfirmDialog -Text ("Error while opening the settings: {0}" -f (Format-ErrorDetail $_)) -Title 'Settings' -Buttons OK -Icon Error -Default OK -Owner $window
        }
        # Tenants und Paketordner koennen sich geaendert haben: neu lesen.
        & $choose 'Refresh'
    })
    $folderButton.Add_Click({  & $choose 'OpenFolder' })
    $orphanButton.Add_Click({  & $choose 'RemoveFolder' })
    $addButton.Add_Click({     & $choose 'Add' })
    $versionButton.Add_Click({ & $choose 'NewVersion' })
    $editButton.Add_Click({    & $choose 'Edit' })
    $deleteButton.Add_Click({  & $choose 'Delete' })
    $buildButton.Add_Click({   & $choose 'Build' })
    $publishButton.Add_Click({ & $choose 'Publish' })
    $removeButton.Add_Click({  & $choose 'Remove' })
    $refreshButton.Add_Click({ & $choose 'Refresh' })
    $checkTenantButton.Add_Click({ & $choose 'CheckTenant' })
    $closeButton.Add_Click({   & $choose 'Cancel' })
    $dataGrid.Add_MouseDoubleClick({
        $row = $dataGrid.SelectedItem
        if ($row -and $row.HasDefinition) { & $choose 'Edit' }
    })

    # Der Tenant-Wechsel wird erst NACH dem Setzen des Anfangswerts gemeldet.
    $tenantBox.Add_SelectionChanged({
        if ($tenantBox.SelectedIndex -ne $initialTenantIndex) { & $choose 'SwitchTenant' }
    })

    # Was moeglich ist, folgt aus dem, was markiert ist.
    $syncButtons = {
        $selected = @($dataGrid.SelectedItems | Where-Object { $_ -isnot [int] })
        # Die Entscheidung trifft Get-InventoryActionState (eine Funktion, getestet); hier wird sie nur angezeigt.
        # Ein ausgegrauter Knopf sagt im Tooltip, warum.
        $state = Get-InventoryActionState -Rows $selected
        $editButton.IsEnabled    = $state.Edit
        $versionButton.IsEnabled = $state.NewVersion
        $deleteButton.IsEnabled  = $state.Delete
        $buildButton.IsEnabled   = $state.Build
        $publishButton.IsEnabled = $state.Publish
        $publishButton.ToolTip   = $(if ($state.Publish) { $baseTips[$publishButton] } else { 'Not possible now: ' + $state.PublishWhy })
        # Remove loescht in Intune, was zu Name UND Version der Zeile gehoert; fremde Apps nie.
        $removeButton.IsEnabled  = $state.Remove
        $removeButton.ToolTip    = $(if ($state.Remove) { $baseTips[$removeButton] } else { 'Not possible now: ' + $state.RemoveWhy })
        # Nur ein Ordner ohne Definition ist verwaist - alles andere loescht dieser Weg nie.
        $orphanButton.IsEnabled  = $state.RemoveFolder
    }
    & $syncButtons
    $dataGrid.Add_SelectionChanged($syncButtons)

    $window.Content = $grid
    $window.Add_Closing({
        if ($null -eq $window.Tag) { $window.Tag = [pscustomobject]@{ Action = 'Closed'; Selection = @(); TenantName = '' } }
    })

    # Auswahl wiederherstellen, sobald das Grid seine Zeilen hat. Eine Zeile, die
    # die Ansicht ausblendet oder die es nicht mehr gibt, fehlt einfach.
    if ($Select.Count -gt 0) {
        $window.Add_Loaded({
            try {
                $wanted = @($dataGrid.ItemsSource | Where-Object { $Select -contains $_.Key })
                if ($wanted.Count -eq 0) { return }
                $dataGrid.SelectedItems.Clear()
                foreach ($row in $wanted) { $null = $dataGrid.SelectedItems.Add($row) }
                $dataGrid.ScrollIntoView($wanted[0])
                $null = $dataGrid.Focus()
            }
            catch { }   # eine Auswahl, die sich nicht herstellen laesst, ist keine Meldung wert
        })
    }

    $null = $window.ShowDialog()
    return $window.Tag
}

function Start-InventoryLoop {
    <#
        .SYNOPSIS
        Das Tool: Inventar zeigen, Aktion abarbeiten, Inventar neu zeigen.

        .DESCRIPTION
        Ersetzt die Startkacheln samt createApps und deployApps. Der Tenant wird
        einmal am Anfang gewaehlt (bei genau einem konfigurierten gar nicht
        gefragt) und laesst sich im Fenster wechseln. Ohne Tenant laeuft das Tool
        weiter, die Intune-Spalte bleibt dann leer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RootDir,
        [Parameter(Mandatory = $true)][string]$ToolVersion
    )

    $config  = Get-ToolConfig -RootDir $RootDir
    $tenants = @($config.tenants | Where-Object { $_ })
    $tenant  = $null
    $intuneApps   = $null
    $reloadIntune = $false

    if ($tenants.Count -gt 0) {
        $only = $null
        if ($tenants.Count -eq 1) { $only = $tenants[0] }
        $tenant = Connect-InventoryTenant -Tenants $tenants -Tenant $only
        $reloadIntune = ($null -ne $tenant)
    }
    else {
        Write-Host "No tenant configured - the Intune column stays empty. Add one under Settings (gear icon)." -ForegroundColor Yellow
    }

    $select = @()
    while ($true) {
        # Jede Runde neu lesen: Einstellungen koennen sich geaendert haben.
        $config     = Get-ToolConfig -RootDir $RootDir
        $tenants    = @($config.tenants | Where-Object { $_ })
        $packetRoot = [string]$config.packetRoot
        if ($packetRoot -and -not (Test-Path -LiteralPath $packetRoot)) { $null = New-Item -ItemType Directory -Path $packetRoot -Force }

        if ($reloadIntune) {
            $intuneApps = $null
            if ($tenant) { $intuneApps = Read-TenantWin32Apps }
            $reloadIntune = $false
        }

        $definitions = @(Read-AppsCsv -RootDir $RootDir)
        $columns     = @(Get-AppsCsvColumns -Definitions $definitions)
        $inventory   = @(Get-AppInventory -Definitions $definitions -PacketRoot $packetRoot -RootDir $RootDir -IntuneApps $intuneApps)

        $result = Show-InventoryDialog -Inventory $inventory `
            -Title ("IntuneWin32Helper {0} - https://blog.zarenko.net/" -f $ToolVersion) `
            -PacketRoot $packetRoot `
            -TenantNames @($tenants | ForEach-Object { [string]$_.name }) `
            -TenantName $(if ($tenant) { [string]$tenant.name } else { '' }) `
            -IntuneRead ($null -ne $intuneApps) `
            -ConfigPath (Get-ToolConfigPath -RootDir $RootDir) `
            -Select $select

        $selection = @($result.Selection)
        $select    = @($selection | ForEach-Object { [string]$_.Key })
        $removeExisting = ($config.removeExistingPacketDirOnEachRun -eq $true)

        try {
            switch ($result.Action) {
                'Refresh' { $reloadIntune = $true }

                'CheckTenant' {
                    # Pruefen meldet sich neu an: danach gilt das Token dieses Tenants, die Liste wird neu gelesen.
                    $target = $tenant
                    if (-not $target -and -not [string]::IsNullOrEmpty($result.TenantName)) {
                        $target = $tenants | Where-Object { [string]$_.name -eq $result.TenantName } | Select-Object -First 1
                    }
                    $checked = Invoke-TenantCheck -Tenant $target -Tenants $tenants
                    if ($checked -and -not (@($checked) | Where-Object { $_.Status -eq 'FAIL' })) { $tenant = $target; $reloadIntune = $true }
                }

                'SwitchTenant' {
                    if ([string]::IsNullOrEmpty($result.TenantName)) {
                        $tenant = $null
                        $intuneApps = $null
                    }
                    else {
                        $target = $tenants | Where-Object { [string]$_.name -eq $result.TenantName } | Select-Object -First 1
                        $tenant = Connect-InventoryTenant -Tenants $tenants -Tenant $target -Force
                        $reloadIntune = ($null -ne $tenant)
                        if (-not $tenant) { $intuneApps = $null }
                    }
                }

                'Add' {
                    $new = Edit-AppRecord -Record $null -Title 'Add application' -ColumnOrder $columns -Others $definitions
                    if ($new) {
                        $problem = Test-AppRecord -Record $new -Others $definitions
                        if ($problem) {
                            $null = Show-ConfirmDialog -Text $problem -Title 'Add application' -Buttons OK -Icon Warning -Default OK
                        }
                        else {
                            Save-AppsCsv -RootDir $RootDir -Rows (@($definitions) + $new)
                            $select = @('{0} - {1}' -f $new.DisplayName, $new.Version)
                        }
                    }
                }

                'NewVersion' {
                    $row = $selection | Select-Object -First 1
                    if ($row -and $row.DefinitionRecord) {
                        $copy = $row.DefinitionRecord | Select-Object *
                        $new = Edit-AppRecord -Record $copy -Title ("New version of {0}" -f $row.AppName) -ColumnOrder $columns -Info (Get-InventoryRowInfo -Row $row) -Others $definitions
                        if ($new) {
                            $problem = Test-AppRecord -Record $new -Others $definitions
                            if ($problem) {
                                $null = Show-ConfirmDialog -Text $problem -Title 'New version' -Buttons OK -Icon Warning -Default OK
                            }
                            else {
                                Save-AppsCsv -RootDir $RootDir -Rows (@($definitions) + $new)
                                $select = @('{0} - {1}' -f $new.DisplayName, $new.Version)
                            }
                        }
                    }
                }

                'Edit' {
                    $row = $selection | Select-Object -First 1
                    if ($row -and $row.DefinitionRecord) {
                        $record = $row.DefinitionRecord
                        $others = @($definitions | Where-Object { -not [object]::ReferenceEquals($_, $record) })
                        $edited = Edit-AppRecord -Record $record -Title ("Edit - {0}" -f $row.Key) -ColumnOrder $columns -Info (Get-InventoryRowInfo -Row $row) -Others $others
                        if ($edited) {
                            $problem = Test-AppRecord -Record $edited -Others $others
                            if ($problem) {
                                $null = Show-ConfirmDialog -Text $problem -Title 'Edit' -Buttons OK -Icon Warning -Default OK
                            }
                            else {
                                Save-AppsCsv -RootDir $RootDir -Rows (@($others) + $edited)
                                $select = @('{0} - {1}' -f $edited.DisplayName, $edited.Version)
                                if ($row.HasPackage -and $select[0] -ne $row.Key) {
                                    Write-Host ("Renamed {0} -> {1}: the existing package folder keeps its old name until it is built again." -f $row.Key, $select[0]) -ForegroundColor Yellow
                                }
                            }
                        }
                    }
                }

                'Delete' {
                    $victims = @($selection | Where-Object { $_.HasDefinition })
                    if ($victims.Count -gt 0) {
                        $names = ($victims | ForEach-Object { $_.Key }) -join "`n"
                        $answer = Show-ConfirmDialog -Text ("Remove {0} definition(s) from Apps.csv?`n`n{1}`n`nThe package folders and the apps in Intune stay." -f $victims.Count, $names) -Title 'Delete definition' -Buttons YesNo -Icon Warning -Default No
                        if ($answer -eq 'Yes') {
                            $remove = @($victims | ForEach-Object { $_.DefinitionRecord })
                            Save-AppsCsv -RootDir $RootDir -Rows @($definitions | Where-Object { $remove -notcontains $_ })
                            $select = @()
                        }
                    }
                }

                'Build' {
                    $targets = @($selection | Where-Object { $_.HasDefinition })
                    $existing = @($targets | Where-Object { $_.HasPackage })
                    $go = $true
                    if ($existing.Count -gt 0) {
                        $answer = Show-ConfirmDialog -Text ("{0} of the selected rows already have a package. Building creates it again from the definition; changes made by hand inside the package are lost.`n`nContinue?" -f $existing.Count) -Title 'Build package' -Buttons YesNo -Icon Warning -Default No
                        $go = ($answer -eq 'Yes')
                    }
                    if ($go -and $targets.Count -gt 0) {
                        $null = Invoke-PackageBuild -Rows $targets -PacketRoot $packetRoot -RootDir $RootDir -ToolVersion $ToolVersion -RemoveExisting $removeExisting
                    }
                }

                'Publish' {
                    # Zuerst der Tenant: scheitert das, soll nicht vorher gebaut werden. Auch mit
                    # bekanntem Tenant: ein abgelaufener Token wuerde das frische Lesen vereiteln.
                    $tenant = Connect-InventoryTenant -Tenants $tenants -Tenant $tenant
                    $reloadIntune = ($null -ne $tenant)
                    if (-not $tenant) {
                        Write-Host "No tenant - nothing was published." -ForegroundColor Yellow
                    }
                    else {
                        # Lesen, planen, fragen, bauen, verteilen: ein Pfad in Invoke-InventoryDeploy.
                        $null = Invoke-InventoryDeploy -Selection $selection -Tenant $tenant -RootDir $RootDir -PacketRoot $packetRoot -ToolVersion $ToolVersion -RemoveExisting $removeExisting
                        $reloadIntune = $true
                    }
                }

                'Remove' {
                    $tenant = Connect-InventoryTenant -Tenants $tenants -Tenant $tenant
                    $reloadIntune = ($null -ne $tenant)
                    if (-not $tenant) {
                        Write-Host "No tenant - nothing was removed." -ForegroundColor Yellow
                    }
                    else {
                        $null = Invoke-InventoryRetire -Selection $selection -RootDir $RootDir -PacketRoot $packetRoot
                        $reloadIntune = $true
                    }
                }

                'OpenFolder' {
                    $path = $packetRoot
                    $row = $selection | Where-Object { $_.FullPath } | Select-Object -First 1
                    if ($row) { $path = Split-Path -Parent $row.FullPath }
                    if ($path -and (Test-Path -LiteralPath $path)) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $path) }
                }

                'RemoveFolder' {
                    # Nur Ordner ohne Definition. Die Auswahl der Zeilen entscheidet der Knopf, die
                    # Verweigerung liegt in Remove-OrphanPackages: ein Ordner MIT Definition wird dort
                    # auch dann nicht angefasst, wenn er hier durchrutschte.
                    $orphans = @($selection | Where-Object { $_.HasPackage -and -not $_.HasDefinition })
                    if ($orphans.Count -eq 0) {
                        $null = Show-ConfirmDialog -Text 'None of the selected rows is an orphan: only a package folder without a row in Apps.csv can be removed here.' -Title 'Remove orphan folder' -Buttons OK -Icon Information -Default OK
                    }
                    else {
                        $lines = foreach ($orphan in $orphans) {
                            $folder  = Split-Path -Parent ([string]$orphan.FullPath)
                            $summary = Get-PackageFolderSummary -Path $folder
                            $stays   = $(if ($orphan.Intune -like 'yes*' -or $orphan.Intune -eq 'no content') { '  (the app stays in Intune)' } else { '' })
                            ("{0}`n    {1}  -  {2} file(s), {3:N1} MB{4}" -f $orphan.Key, $folder, $summary.Files, ($summary.Bytes / 1MB), $stays)
                        }
                        $answer = Show-ConfirmDialog -Text ("Delete {0} package folder(s) that have no definition in Apps.csv?`n`n{1}`n`nThis cannot be undone. The apps in Intune are not touched." -f $orphans.Count, ($lines -join "`n`n")) -Title 'Remove orphan folder' -Buttons YesNo -Icon Warning -Default No
                        if ($answer -eq 'Yes') {
                            $outcome = Remove-OrphanPackages -Rows $orphans -PacketRoot $packetRoot
                            Write-Host ("Orphan folders: {0} removed, {1} skipped, {2} failed." -f $outcome.Removed.Count, $outcome.Skipped.Count, $outcome.Failed.Count) -ForegroundColor Cyan
                            foreach ($name in $outcome.Removed) { Write-Host ("  REMOVED  {0}" -f $name) -ForegroundColor Green }
                            foreach ($name in $outcome.Skipped) { Write-Host ("  SKIPPED  {0}" -f $name) -ForegroundColor Yellow }
                            foreach ($name in $outcome.Failed)  { Write-Host ("  FAILED   {0}" -f $name) -ForegroundColor Red }
                            $select = @()
                        }
                    }
                }

                'Cancel' { return }
                'Closed' { return }
                default {
                    Write-Host ("Unexpected action: {0}" -f $result.Action) -ForegroundColor Yellow
                    return
                }
            }
        }
        catch {
            # Eine gescheiterte Aktion beendet das Tool nicht.
            Write-Host ("Action [{0}] failed: {1}" -f $result.Action, (Format-ErrorDetail $_)) -ForegroundColor Red
            $null = Show-ConfirmDialog -Text ("Action [{0}] failed:`n`n{1}" -f $result.Action, (Format-ErrorDetail $_)) -Title 'IntuneWin32Helper' -Buttons OK -Icon Error -Default OK
        }
    }
}
