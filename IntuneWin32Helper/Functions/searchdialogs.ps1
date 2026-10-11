# ============================================================================
#  Suchen und Auswaehlen: der WinGet-Suchdialog und die Auswahllisten.
# ============================================================================

function Show-WinGetSearchDialog {
    <#
        Waehlt ein Paket aus winget: vorn die kuratierte Liste (Config\catalog.json), dazu ein
        Suchfeld, das den offiziellen Index durchsucht (wingetindex.ps1). Muster aus SCCMAppHelper
        (Show-CatalogDialog). Gibt Name, Id, Version und Publisher des gewaehlten Pakets zurueck
        oder $null bei Abbruch.

        -OnSearch ersetzt die Suche (Tests); -Packages die kuratierte Liste.
    #>
    param(
        $Packages = (Get-WinGetCatalogList),
        [string]$Query = '',
        [scriptblock]$OnSearch = { param($q) Search-WinGetCatalog -Query $q -Packages $Packages },
        [string]$Title = 'WinGet Search'
    )

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    $window = New-Object Windows.Window
    $window.Title = $Title
    $window.Width = 820
    $window.Height = 580
    $window.WindowStartupLocation = 'CenterScreen'
    [Windows.Automation.AutomationProperties]::SetAutomationId($window, 'WinGetDialog')

    $grid = New-Object Windows.Controls.Grid
    $grid.Margin = '12'
    foreach ($height in 'Auto', '*', 'Auto', 'Auto') {
        $row = New-Object Windows.Controls.RowDefinition
        $row.Height = $(if ($height -eq '*') { New-Object Windows.GridLength -ArgumentList 1, ([Windows.GridUnitType]::Star) } else { [Windows.GridLength]::Auto })
        $null = $grid.RowDefinitions.Add($row)
    }

    # --- Suchzeile ---
    $searchPanel = New-Object Windows.Controls.DockPanel
    $searchPanel.Margin = '0,0,0,8'
    $searchBox = New-Object Windows.Controls.TextBox
    $searchBox.Padding = '4'
    $searchBox.VerticalContentAlignment = 'Center'
    $searchBox.Text = $Query
    $searchBox.ToolTip = 'Package id, name, moniker or publisher - at least two characters. Empty = the curated list.'
    [Windows.Automation.AutomationProperties]::SetAutomationId($searchBox, 'SearchQuery')
    $searchButton = New-Object Windows.Controls.Button
    $searchButton.Content = 'Search'
    $searchButton.Padding = '12,4'
    $searchButton.Margin = '8,0,0,0'
    [Windows.Automation.AutomationProperties]::SetAutomationId($searchButton, 'Search')
    [Windows.Controls.DockPanel]::SetDock($searchButton, 'Right')
    $null = $searchPanel.Children.Add($searchButton)
    $null = $searchPanel.Children.Add($searchBox)
    [Windows.Controls.Grid]::SetRow($searchPanel, 0)
    $null = $grid.Children.Add($searchPanel)

    # --- Liste ---
    $dataGrid = New-Object Windows.Controls.DataGrid
    $dataGrid.AutoGenerateColumns = $false
    $dataGrid.IsReadOnly = $true
    $dataGrid.SelectionMode = 'Single'
    $dataGrid.SelectionUnit = 'FullRow'
    $dataGrid.CanUserSortColumns = $true
    [Windows.Automation.AutomationProperties]::SetAutomationId($dataGrid, 'WinGetGrid')
    foreach ($column in 'Name', 'Id', 'Version', 'Source') {
        $col = New-Object Windows.Controls.DataGridTextColumn
        $col.Header = $column
        $col.Binding = New-Object Windows.Data.Binding($column)
        $col.Width = $(switch ($column) { 'Name' { 250 } 'Id' { 340 } 'Version' { 110 } default { 70 } })
        $null = $dataGrid.Columns.Add($col)
    }
    $dataGrid.ItemsSource = @(& $OnSearch '')
    [Windows.Controls.Grid]::SetRow($dataGrid, 1)
    $null = $grid.Children.Add($dataGrid)

    # --- Indexzeile: wo die Suche hinschaut und wie alt das ist ---
    $indexLine = New-Object Windows.Controls.DockPanel
    $indexLine.Margin = '0,8,0,0'
    $indexText = New-Object Windows.Controls.TextBlock
    $indexText.Foreground = [System.Windows.Media.Brushes]::DimGray
    $indexText.VerticalAlignment = 'Center'
    $indexText.TextWrapping = 'Wrap'
    [Windows.Automation.AutomationProperties]::SetAutomationId($indexText, 'IndexStatus')
    $updateIndexButton = New-Object Windows.Controls.Button
    $updateIndexButton.Content = 'Update index'
    $updateIndexButton.Padding = '12,4'
    $updateIndexButton.Margin = '8,0,0,0'
    $updateIndexButton.ToolTip = 'Fetch the winget index from cdn.winget.microsoft.com again - it is refreshed once a day by itself'
    [Windows.Automation.AutomationProperties]::SetAutomationId($updateIndexButton, 'UpdateIndex')
    [Windows.Controls.DockPanel]::SetDock($updateIndexButton, 'Right')
    $null = $indexLine.Children.Add($updateIndexButton)
    $null = $indexLine.Children.Add($indexText)
    [Windows.Controls.Grid]::SetRow($indexLine, 2)
    $null = $grid.Children.Add($indexLine)

    $describeIndex = { $indexText.Text = Get-WinGetIndexStatusText }
    & $describeIndex

    # --- Knoepfe ---
    $buttons = New-Object Windows.Controls.StackPanel
    $buttons.Orientation = 'Horizontal'
    $buttons.HorizontalAlignment = 'Right'
    $buttons.Margin = '0,10,0,0'
    $rememberButton = New-Object Windows.Controls.Button
    $rememberButton.Content = 'Remember'
    $rememberButton.Padding = '18,6'
    $rememberButton.Margin = '0,0,8,0'
    $rememberButton.ToolTip = 'Add the selected package to Config\catalog.json - it is on the front page next time'
    [Windows.Automation.AutomationProperties]::SetAutomationId($rememberButton, 'Remember')
    $okButton = New-Object Windows.Controls.Button
    $okButton.Content = 'Next'; $okButton.Padding = '18,6'; $okButton.Margin = '0,0,8,0'; $okButton.IsDefault = $true
    [Windows.Automation.AutomationProperties]::SetAutomationId($okButton, 'Next')
    $cancelButton = New-Object Windows.Controls.Button
    $cancelButton.Content = 'Cancel'; $cancelButton.Padding = '18,6'; $cancelButton.IsCancel = $true
    [Windows.Automation.AutomationProperties]::SetAutomationId($cancelButton, 'Cancel')
    $null = $buttons.Children.Add($rememberButton)
    $null = $buttons.Children.Add($okButton)
    $null = $buttons.Children.Add($cancelButton)
    [Windows.Controls.Grid]::SetRow($buttons, 3)
    $null = $grid.Children.Add($buttons)

    $showNote = {
        param([string]$Text, [string]$Caption, [string]$Icon = 'Information')
        $null = Show-ConfirmDialog -Text $Text -Title $Caption -Buttons OK -Default OK -Icon $Icon
    }

    $updateIndexButton.Add_Click({
        $window.Cursor = 'Wait'
        try {
            $null = Get-WinGetIndex -Force
            & $describeIndex
        }
        catch { & $showNote (Format-ErrorDetail $_) 'winget index' 'Warning' }
        finally { $window.Cursor = 'Arrow' }
    })

    $rememberButton.Add_Click({
        $picked = $dataGrid.SelectedItem
        if (-not $picked) { & $showNote 'Nothing selected.' 'WinGet Search'; return }
        try {
            $added = Add-WinGetCatalogEntry -Name ([string]$picked.Name) -PackageId ([string]$picked.Id)
            & $showNote $(if ($added) { "$($picked.Id) is on the front page now." } else { "$($picked.Id) was already on the front page." }) 'WinGet Search'
        }
        catch { & $showNote (Format-ErrorDetail $_) 'WinGet Search' 'Warning' }
    })

    $okButton.Add_Click({ if ($dataGrid.SelectedItem) { $window.DialogResult = $true } })
    $dataGrid.Add_MouseDoubleClick({ if ($dataGrid.SelectedItem) { $window.DialogResult = $true } })

    $runSearch = {
        $needle = $searchBox.Text
        $window.Cursor = 'Wait'
        $indexText.Text = 'Searching ... the first search fetches the index and can take a moment.'
        # Die Meldung muss gezeichnet sein, bevor die Suche den Dispatcher belegt.
        try { $window.Dispatcher.Invoke([Action]{}, 'Background') } catch { }
        try {
            $merged = @(& $OnSearch $needle)
            $dataGrid.ItemsSource = $merged
            if ($needle.Trim() -and $merged.Count -eq 0) {
                & $showNote ("Nothing found for [$needle].`n`nThe index is searched by package id, name, moniker and publisher. Try another spelling or the vendor name.") 'WinGet Search'
            }
        }
        catch { & $showNote (Format-ErrorDetail $_) 'WinGet Search' 'Warning' }
        finally { $window.Cursor = 'Arrow'; & $describeIndex }
    }
    $searchButton.Add_Click({ & $runSearch })
    # Enter im Suchfeld sucht - es nimmt nicht "Next". Handled haelt die Eingabetaste vom Standardknopf fern.
    $searchBox.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { $e.Handled = $true; & $runSearch } })

    $window.Add_ContentRendered({ $searchBox.Focus(); $searchBox.SelectAll() })
    $window.Content = $grid
    if ($window.ShowDialog() -ne $true) { return $null }

    $selected = $dataGrid.SelectedItem
    $publisher = ''
    if ($selected.Id) { $publisher = ([string]$selected.Id).Split('.')[0] }
    return [pscustomobject]@{ Name = $selected.Name; Id = $selected.Id; Version = $selected.Version; Publisher = $publisher }
}

function Open-SelectDialog {
    param (
        $data,
        [string]$title,
        [switch]$large,
        # Gleiche Bedeutung wie in Open-SelectDialogWithEdit, damit beide Dialoge
        # gleich aufgerufen werden koennen. -large bleibt aus Kompatibilitaet
        # erhalten und entspricht -size large.
        [ValidateSet("small", "medium", "large")]
        [string]$size
    )

    Add-Type -AssemblyName PresentationFramework | Out-Null

    if ($large) { $size = "large" }
    if ([string]::IsNullOrEmpty($size)) { $size = "medium" }

    # Fenster erstellen
    $window = New-Object Windows.Window
    $window.Title = $title
    switch ($size) {
        "small" { $window.Width = 640;  $window.Height = 400 }
        "large" { $window.Width = 1024; $window.Height = 768 }
        default { $window.Width = 800;  $window.Height = 600 }
    }

    # DataGrid erstellen
    $dataGrid = New-Object Windows.Controls.DataGrid
    $dataGrid.CanUserSortColumns = $true
    $dataGrid.SelectionMode = 'Extended'
    $dataGrid.SelectionUnit = 'FullRow'
    $dataGrid.AutoGenerateColumns = $false

    # Spalten manuell erzeugen
    $firstItem = $data | Select-Object -First 1
    foreach ($property in $firstItem.PSObject.Properties.Name) {
        $column = New-Object Windows.Controls.DataGridTextColumn
        $column.Header = $property
        $column.Binding = New-Object Windows.Data.Binding($property)
        $column.CanUserSort = $true
        [void]$dataGrid.Columns.Add($column)
    }

    # ItemsSource setzen
    $dataGrid.ItemsSource = $data

    # OK-Button
    $okButton = New-Object Windows.Controls.Button
    $okButton.Height = 40
    $okButton.Width = 100
    $okButton.Content = "OK"
    $okButton.Margin = "5"
    $okButton.Add_Click({
        $window.DialogResult = $true
    })

    # Cancel-Button
    $cancelButton = New-Object Windows.Controls.Button
    $cancelButton.Height = 40
    $cancelButton.Width = 100
    $cancelButton.Content = "Cancel"
    $cancelButton.Margin = "5"
    $cancelButton.Add_Click({
        $window.DialogResult = $false
    })

    # Button-Panel
    $buttonPanel = New-Object Windows.Controls.StackPanel
    $buttonPanel.Orientation = 'Horizontal'
    $buttonPanel.HorizontalAlignment = 'Right'
    $buttonPanel.Margin = "10"
    [void]$buttonPanel.Children.Add($okButton)
    [void]$buttonPanel.Children.Add($cancelButton)

    # Layout-Grid
    $grid = New-Object Windows.Controls.Grid
    [void]$grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
    [void]$grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
    $grid.RowDefinitions[1].Height = [Windows.GridLength]::Auto

    [void]$grid.Children.Add($dataGrid)
    [Windows.Controls.Grid]::SetRow($dataGrid, 0)
    [void]$grid.Children.Add($buttonPanel)
    [Windows.Controls.Grid]::SetRow($buttonPanel, 1)

    $window.Content = $grid

    # Dialog anzeigen
    $window.WindowStartupLocation = 'CenterScreen'
    $result = $window.ShowDialog()

    if ($result -eq $true) {
        return $dataGrid.SelectedItems
    }
}

function Open-SelectDialogWithSearch {
    param (
        $data,
        [string]$title,
        [switch]$large,
        [ScriptBlock]$OnSearch,
        [string]$initialQuery = '',
        [string]$searchPlaceholder = 'Enter search string and hit "Search"...'
    )

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    # Fenster
    $window = New-Object Windows.Window
    $window.Title = $title
    if ($large) { $window.Width = 1024; $window.Height = 768 } else { $window.Width = 800; $window.Height = 600 }

    # Hauptgrid
    $grid = New-Object Windows.Controls.Grid
    [void]$grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
    $grid.RowDefinitions[0].Height = [Windows.GridLength]::Auto
    [void]$grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
    [void]$grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
    $grid.RowDefinitions[2].Height = [Windows.GridLength]::Auto

    # --- Suchleiste ---
    $searchPanel = New-Object Windows.Controls.StackPanel
    $searchPanel.Orientation = 'Horizontal'
    $searchPanel.Margin = '8'

    $searchBox = New-Object Windows.Controls.TextBox
    $searchBox.Width = 360
    $searchBox.Margin = '0,0,8,0'
    $searchBox.Text = $initialQuery
    $searchBox.ToolTip = $searchPlaceholder

    $searchButton = New-Object Windows.Controls.Button
    $searchButton.Content = 'Search'
    $searchButton.Width = 90
    $searchButton.Margin = '0,0,8,0'

    $spinner = New-Object Windows.Controls.TextBlock
    $spinner.VerticalAlignment = 'Center'
    $spinner.Margin = '8,0,0,0'
    $spinner.Text = ''

    [void]$searchPanel.Children.Add($searchBox)
    [void]$searchPanel.Children.Add($searchButton)
    [void]$searchPanel.Children.Add($spinner)

    # --- DataGrid ---
    $dataGrid = New-Object Windows.Controls.DataGrid
    $dataGrid.CanUserSortColumns = $true
    $dataGrid.SelectionMode = 'Extended'
    $dataGrid.SelectionUnit = 'FullRow'
    $dataGrid.AutoGenerateColumns = $false
    $dataGrid.IsReadOnly = $true

    # PERFORMANCE BOOST
    $dataGrid.EnableRowVirtualization = $true
    $dataGrid.EnableColumnVirtualization = $true
    $dataGrid.SetValue([Windows.Controls.VirtualizingStackPanel]::IsVirtualizingProperty, $true)
    $dataGrid.SetValue(
        [Windows.Controls.VirtualizingStackPanel]::VirtualizationModeProperty,
        [Windows.Controls.VirtualizationMode]::Recycling
    )

    # Spaltenaufbau
    $rebuildColumns = {
        param($sample)
        $dataGrid.Columns.Clear()
        if ($sample) {
            foreach ($property in $sample.PSObject.Properties.Name) {
                $column = New-Object Windows.Controls.DataGridTextColumn
                $column.Header = $property
                $column.Binding = New-Object Windows.Data.Binding($property)
                $column.CanUserSort = $true
                $dataGrid.Columns.Add($column) | Out-Null
            }
        }
    }

    $dataGrid.ItemsSource = $data
    & $rebuildColumns ($data | Select-Object -First 1)

    # --- Buttons ---
    $okButton = New-Object Windows.Controls.Button
    $okButton.Height = 40
    $okButton.Width = 100
    $okButton.Content = "OK"
    $okButton.Margin = "5"
    $okButton.Add_Click({ $window.DialogResult = $true })

    $cancelButton = New-Object Windows.Controls.Button
    $cancelButton.Height = 40
    $cancelButton.Width = 100
    $cancelButton.Content = "Cancel"
    $cancelButton.Margin = "5"
    $cancelButton.Add_Click({ $window.DialogResult = $false })

    $buttonPanel = New-Object Windows.Controls.StackPanel
    $buttonPanel.Orientation = 'Horizontal'
    $buttonPanel.HorizontalAlignment = 'Right'
    $buttonPanel.Margin = "10"
    [void]$buttonPanel.Children.Add($okButton)
    [void]$buttonPanel.Children.Add($cancelButton)

    # Layout
    [void]$grid.Children.Add($searchPanel)
    [Windows.Controls.Grid]::SetRow($searchPanel, 0)
    [void]$grid.Children.Add($dataGrid)
    [Windows.Controls.Grid]::SetRow($dataGrid, 1)
    [void]$grid.Children.Add($buttonPanel)
    [Windows.Controls.Grid]::SetRow($buttonPanel, 2)

    $window.Content = $grid
    $window.WindowStartupLocation = 'CenterScreen'

    # --- Search ---
    $runSearch = {
        if (-not $OnSearch) { return }

        # Busy
        $spinner.Text = 'Searching...'
        $searchButton.IsEnabled = $false
        $searchBox.IsEnabled = $false
        $window.Cursor = [System.Windows.Input.Cursors]::Wait

        # UI sofort aktualisieren
        try { $window.Dispatcher.Invoke([Action]{}, 'Background') } catch { }
        Start-Sleep -Milliseconds 50

        $query = $searchBox.Text
        $newData = @()

        try {
            # *** WICHTIG: Ergebnisse FLACH machen ***
            $raw = & $OnSearch $query
            $newData = foreach ($item in $raw) {
                [pscustomobject]@{
                    Name      = $item.Name
                    Id        = $item.Id
                    Version   = $item.Version
                    #Publisher = $item.Publisher
                    Moniker   = $item.Moniker
                    Source    = $item.Source
                }
            }
        } catch {
            $newData = @()
            $null = Show-ConfirmDialog -Text "Error while searching: $($_.Exception.Message)" -Title 'IntuneWin32Helper' -Buttons OK -Icon None -Default OK
        }

        $dataGrid.ItemsSource = $null
        & $rebuildColumns ($newData | Select-Object -First 1)
        $dataGrid.ItemsSource = $newData

        # Ready
        $spinner.Text = ''
        $searchButton.IsEnabled = $true
        $searchBox.IsEnabled = $true
        $window.Cursor = [System.Windows.Input.Cursors]::Arrow

        # Suchfeld wieder aktivieren + Fokus setzen
        $searchBox.IsEnabled = $true
        $searchBox.Focus()
        $searchBox.SelectAll()
    }

    $searchButton.Add_Click({ & $runSearch })
    $searchBox.Add_KeyDown({ if ($_.Key -eq 'Enter') { & $runSearch } })

    $window.Add_SourceInitialized({
        $searchBox.Focus()
        $searchBox.SelectAll()
    })

    $result = $window.ShowDialog()
    if ($result -eq $true) {
        return $dataGrid.SelectedItems
    }
}
