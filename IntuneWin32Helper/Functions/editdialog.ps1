# ============================================================================
#  Bearbeiten und Anlegen einer Definition.
# ============================================================================

function Get-RequirementRuleChoices {
    <#
        Zulaessige Werte fuer Architecture und MinimumOS - aus dem Modul gelesen,
        nicht aus einer Kopie: sie gehen in New-IntuneWin32AppRequirementRule, und
        ein Wert, den das Modul nicht kennt, scheitert erst beim Upload. Der Parameter
        heisst im Modul MinimumSupportedWindowsRelease (MinimumSupportedOperatingSystem
        ist sein Alias). Die Rueckfallliste gilt nur, wenn das Modul nicht lesbar ist.
    #>
    [CmdletBinding()]
    param()

    $architecture = @('x64', 'x86', 'arm64', 'x64x86', 'AllWithARM64')
    $minimumOs    = @('W10_1607', 'W10_1703', 'W10_1709', 'W10_1803', 'W10_1809', 'W10_1903', 'W10_1909', 'W10_2004',
                      'W10_20H2', 'W10_21H1', 'W10_21H2', 'W10_22H2', 'W11_21H2', 'W11_22H2')
    try {
        $command = Get-Command -Name New-IntuneWin32AppRequirementRule -ErrorAction Stop
        $set = @($command.Parameters['Architecture'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })
        if ($set.Count -gt 0) { $architecture = @($set[0].ValidValues) }
        $set = @($command.Parameters['MinimumSupportedWindowsRelease'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })
        if ($set.Count -gt 0) { $minimumOs = @($set[0].ValidValues) }
    }
    catch { }
    return [pscustomobject]@{ Architecture = $architecture; MinimumOS = $minimumOs }
}

function Open-EditDialog {
    <#
        .SYNOPSIS
        Bearbeitungsdialog fuer eine Definition aus Apps.csv.

        .DESCRIPTION
        Gibt die Werte als geordnetes Dictionary zurueck, bei Abbruch nichts.
        Aufbau wie im SCCMAppHelper: oben die Fakten zur Zeile (nur lesen), darunter
        die Felder in Gruppen, Beschriftung links und Feld rechts. Jedes Feld hat das
        passende Steuerelement (Auswahlliste, Haken, mehrzeilig) und, wo es etwas zu
        erklaeren gibt, einen Hinweis darunter. Jedes Steuerelement traegt als
        AutomationId den Spaltennamen, damit der Dialog maschinell testbar ist.
        OK prueft Name und Version, auch auf Doppelte (-Others), und bleibt bei einem
        Fehler offen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$item,
        [string]$title,
        [string[]]$PropertyOrder,
        # Nur lesende Fakten oberhalb der Felder (Paket, Vorlage, Intune, naechster Schritt)
        [System.Collections.IDictionary]$Info,
        # Die uebrigen Definitionen: Name + Version muessen eindeutig bleiben
        $Others = @()
    )

    Add-Type -AssemblyName PresentationCore      -ErrorAction SilentlyContinue | Out-Null
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue | Out-Null

    $keys = if ($PropertyOrder) { @($PropertyOrder) } else { @($item.Keys) }
    $choices = Get-RequirementRuleChoices

    # Gruppen und Reihenfolge; unbekannte (eigene) Spalten landen unter "Other".
    $groups = [ordered]@{
        'Application'  = @('DisplayName', 'Publisher', 'Version')
        'Source'       = @('ProgramID', 'WinGetParams', 'SingleMSI', 'MsiProductCode', 'logoURL')
        'Installation' = @('InstallCmd', 'UninstallCmd', 'Interactive')
        'Intune'       = @('Architecture', 'MinimumOS', 'ArpName')
    }
    $known = @($groups.Values | ForEach-Object { $_ })
    $other = @($keys | Where-Object { $known -notcontains $_ })
    if ($other.Count -gt 0) { $groups['Other'] = $other }

    $comboValues = @{ Architecture = $choices.Architecture; MinimumOS = $choices.MinimumOS }
    $checkText = @{
        SingleMSI   = 'Zero-config MSI: the PSADT script is not customised (a package that only holds one MSI)'
        Interactive = 'Show PSADT dialogs through ServiceUI'
    }
    $multiline = @('InstallCmd', 'UninstallCmd')
    $hints = @{
        Version        = 'LatestAvailable makes this a WinGet app: a thin wrapper that installs through winget on the device.'
        ProgramID      = 'WinGet package id. Used only when Version is LatestAvailable.'
        WinGetParams   = 'Extra winget arguments, e.g. "--scope=machine". Used only when Version is LatestAvailable.'
        MsiProductCode = 'Detection by the MSI product code - native in Intune, version included. Empty: detection.ps1 is used.'
        logoURL        = 'Empty: Logos\<DisplayName>.png if it exists, otherwise the default logo. Nothing is uploaded anywhere.'
        InstallCmd     = 'PSADT code for the install section. Empty: derived from the installer in Files\ when the package is built.'
        UninstallCmd   = 'PSADT code for the uninstall section. Empty: derived like the install command.'
        Interactive    = 'Runs the setup AS SYSTEM IN THE USER SESSION. A setup that starts its app when it is done leaves it running as SYSTEM on the desktop. Leave off unless the package must show dialogs.'
        Architecture   = 'Empty means x64.'
        MinimumOS      = 'Empty means W10_20H2.'
    }

    $window = New-Object Windows.Window
    $window.Title = $title
    $window.Width = 780
    $window.MinWidth = 640
    $window.SizeToContent = 'Height'
    $window.MaxHeight = [Math]::Max(480, [System.Windows.SystemParameters]::WorkArea.Height - 40)
    $window.WindowStartupLocation = 'CenterScreen'
    [Windows.Automation.AutomationProperties]::SetAutomationId($window, 'EditDialog')

    $dock = New-Object Windows.Controls.DockPanel

    # --- unten: Fehler und Knoepfe (ausserhalb des Scrollbereichs, immer sichtbar) ---
    $bottom = New-Object Windows.Controls.StackPanel
    $bottom.Margin = '12,0,12,12'
    [Windows.Controls.DockPanel]::SetDock($bottom, 'Bottom')

    $errorText = New-Object Windows.Controls.TextBlock
    $errorText.Foreground = [System.Windows.Media.Brushes]::Firebrick
    $errorText.TextWrapping = 'Wrap'
    $errorText.Margin = '0,6,0,6'
    [Windows.Automation.AutomationProperties]::SetAutomationId($errorText, 'Error')
    $null = $bottom.Children.Add($errorText)

    $buttonBar = New-Object Windows.Controls.DockPanel
    $null = $bottom.Children.Add($buttonBar)

    $newButton = {
        param([string]$caption, [string]$id, [string]$tip, [string]$dock)
        $button = New-Object Windows.Controls.Button
        $button.Content = $caption
        $button.Padding = '14,5'
        $button.Margin = '0,0,8,0'
        $button.ToolTip = $tip
        [Windows.Automation.AutomationProperties]::SetAutomationId($button, $id)
        [Windows.Controls.DockPanel]::SetDock($button, $dock)
        $null = $buttonBar.Children.Add($button)
        return $button
    }
    $okButton     = & $newButton 'OK'       'OK'        'Save the definition' 'Right'
    $cancelButton = & $newButton 'Cancel'   'Cancel'    'Discard the changes' 'Right'
    $wingetButton = & $newButton 'From WinGet...' 'FromWinGet' 'Search WinGet and fill in name, publisher, id and version' 'Left'
    $msiButton    = & $newButton 'From MSI...'    'FromMsi'    'Read name, version, publisher and product code from an MSI file' 'Left'
    $okButton.IsDefault = $true
    $cancelButton.IsCancel = $true
    $okButton.Margin = '8,0,0,0'
    $cancelButton.Margin = '0'
    $null = $dock.Children.Add($bottom)

    # --- Mitte: scrollbar ---
    $scroll = New-Object Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $scroll.HorizontalScrollBarVisibility = 'Disabled'
    $null = $dock.Children.Add($scroll)

    $stack = New-Object Windows.Controls.StackPanel
    $stack.Margin = '12'
    $scroll.Content = $stack

    # Fakten zur Zeile
    if ($Info -and $Info.Count -gt 0) {
        $infoBorder = New-Object Windows.Controls.Border
        $infoBorder.Background = [System.Windows.Media.Brushes]::WhiteSmoke
        $infoBorder.BorderBrush = [System.Windows.Media.Brushes]::LightGray
        $infoBorder.BorderThickness = '1'
        $infoBorder.CornerRadius = '4'
        $infoBorder.Padding = '10,8'
        $infoBorder.Margin = '0,0,0,10'
        [Windows.Automation.AutomationProperties]::SetAutomationId($infoBorder, 'Info')

        $infoGrid = New-Object Windows.Controls.Grid
        $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = New-Object Windows.GridLength -ArgumentList 100
        $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = New-Object Windows.GridLength -ArgumentList 1, ([Windows.GridUnitType]::Star)
        $null = $infoGrid.ColumnDefinitions.Add($c1)
        $null = $infoGrid.ColumnDefinitions.Add($c2)
        $infoRow = 0
        foreach ($infoKey in $Info.Keys) {
            $rd = New-Object Windows.Controls.RowDefinition; $rd.Height = [Windows.GridLength]::Auto
            $null = $infoGrid.RowDefinitions.Add($rd)
            $infoLabel = New-Object Windows.Controls.TextBlock
            $infoLabel.Text = $infoKey
            $infoLabel.Foreground = [System.Windows.Media.Brushes]::DimGray
            $infoLabel.Margin = '0,1,8,1'
            [Windows.Controls.Grid]::SetRow($infoLabel, $infoRow)
            $null = $infoGrid.Children.Add($infoLabel)
            $infoValue = New-Object Windows.Controls.TextBox
            $infoValue.Text = [string]$Info[$infoKey]
            $infoValue.IsReadOnly = $true
            $infoValue.BorderThickness = '0'
            $infoValue.Background = [System.Windows.Media.Brushes]::Transparent
            $infoValue.TextWrapping = 'Wrap'
            $infoValue.Margin = '0,1,0,1'
            [Windows.Automation.AutomationProperties]::SetAutomationId($infoValue, 'Info' + ($infoKey -replace '\W', ''))
            [Windows.Controls.Grid]::SetRow($infoValue, $infoRow)
            [Windows.Controls.Grid]::SetColumn($infoValue, 1)
            $null = $infoGrid.Children.Add($infoValue)
            $infoRow++
        }
        $infoBorder.Child = $infoGrid
        $null = $stack.Children.Add($infoBorder)
    }

    # Felder: eine Gruppe = ein Kopf plus ein Grid mit Beschriftung links, Feld rechts
    $controls = [ordered]@{}
    $hintBlocks = @{}
    foreach ($groupName in $groups.Keys) {
        $groupKeys = @($groups[$groupName] | Where-Object { $keys -contains $_ })
        if ($groupKeys.Count -eq 0) { continue }

        $header = New-Object Windows.Controls.TextBlock
        $header.Text = $groupName
        $header.FontWeight = [Windows.FontWeights]::SemiBold
        $header.FontSize = 14
        $header.Margin = '0,8,0,4'
        $null = $stack.Children.Add($header)

        $fieldGrid = New-Object Windows.Controls.Grid
        $lc = New-Object Windows.Controls.ColumnDefinition; $lc.Width = New-Object Windows.GridLength -ArgumentList 150
        $vc = New-Object Windows.Controls.ColumnDefinition; $vc.Width = New-Object Windows.GridLength -ArgumentList 1, ([Windows.GridUnitType]::Star)
        $null = $fieldGrid.ColumnDefinitions.Add($lc)
        $null = $fieldGrid.ColumnDefinitions.Add($vc)
        $rowIndex = 0

        foreach ($key in $groupKeys) {
            $rd = New-Object Windows.Controls.RowDefinition; $rd.Height = [Windows.GridLength]::Auto
            $null = $fieldGrid.RowDefinitions.Add($rd)

            $value = [string]$item[$key]
            $isMulti = ($multiline -contains $key) -or ($value -match "`n")
            $isCheck = $checkText.ContainsKey($key)
            $isCombo = $comboValues.ContainsKey($key)

            $label = New-Object Windows.Controls.Label
            $label.Content = $key
            $label.Margin = '0,0,8,4'
            $label.VerticalAlignment = $(if ($isMulti) { 'Top' } else { 'Center' })
            [Windows.Controls.Grid]::SetRow($label, $rowIndex)
            $null = $fieldGrid.Children.Add($label)

            if ($isCheck) {
                $control = New-Object Windows.Controls.CheckBox
                $control.Content = $checkText[$key]
                $control.IsChecked = ($value.Trim() -ne '' -and $value -notmatch '^\s*(?i)(false|0|no|nein)\s*$')
                $control.VerticalAlignment = 'Center'
                $control.Margin = '0,5,0,4'
            }
            elseif ($isCombo) {
                $control = New-Object Windows.Controls.ComboBox
                $control.IsEditable = $true            # ein unbekannter Wert in einer alten Zeile ueberlebt das Ansehen
                $control.ItemsSource = @($comboValues[$key])
                $control.Text = $value
                $control.Height = 26
                $control.Margin = '0,0,0,4'
            }
            else {
                $control = New-Object Windows.Controls.TextBox
                $control.Text = $value
                $control.TextWrapping = 'Wrap'
                $control.VerticalContentAlignment = 'Center'
                $control.Margin = '0,0,0,4'
                if ($isMulti) { $control.AcceptsReturn = $true; $control.Height = 78; $control.VerticalScrollBarVisibility = 'Auto'; $control.VerticalContentAlignment = 'Top' }
                else { $control.Height = 26 }
            }
            [Windows.Automation.AutomationProperties]::SetAutomationId($control, $key)
            [Windows.Automation.AutomationProperties]::SetName($control, $key)
            [Windows.Controls.Grid]::SetRow($control, $rowIndex)
            [Windows.Controls.Grid]::SetColumn($control, 1)
            $null = $fieldGrid.Children.Add($control)
            $controls[$key] = $control
            $rowIndex++

            # Hinweis unter dem Feld (bei ArpName ein lebender Text, siehe unten)
            if ($hints.ContainsKey($key) -or $key -eq 'ArpName') {
                $rd2 = New-Object Windows.Controls.RowDefinition; $rd2.Height = [Windows.GridLength]::Auto
                $null = $fieldGrid.RowDefinitions.Add($rd2)
                $hint = New-Object Windows.Controls.TextBlock
                $hint.Foreground = [System.Windows.Media.Brushes]::DimGray
                $hint.TextWrapping = 'Wrap'
                $hint.Margin = '2,0,0,8'
                if ($hints.ContainsKey($key)) { $hint.Text = $hints[$key] }
                [Windows.Automation.AutomationProperties]::SetAutomationId($hint, $key + 'Hint')
                [Windows.Controls.Grid]::SetRow($hint, $rowIndex)
                [Windows.Controls.Grid]::SetColumn($hint, 1)
                $null = $fieldGrid.Children.Add($hint)
                $hintBlocks[$key] = $hint
                $rowIndex++
            }
        }
        $null = $stack.Children.Add($fieldGrid)
    }

    $getValue = {
        param([string]$key)
        $c = $controls[$key]
        if ($c -is [Windows.Controls.CheckBox]) { if ($c.IsChecked) { return 'true' } else { return '' } }
        return [string]$c.Text
    }
    $setValue = {
        param([string]$key, [string]$value)
        if ([string]::IsNullOrWhiteSpace($value)) { return }
        if (-not $controls.Contains($key)) { return }
        $c = $controls[$key]
        if ($c -is [Windows.Controls.CheckBox]) { $c.IsChecked = ($value -notmatch '^\s*(?i)(false|0|no|nein)\s*$') }
        else { $c.Text = $value }
    }

    # WinGet-Felder gelten nur bei Version = LatestAvailable.
    $syncWinGet = {
        if (-not $controls.Contains('Version')) { return }
        $isWinGet = (([string]$controls['Version'].Text).Trim() -eq 'LatestAvailable')
        foreach ($k in 'ProgramID', 'WinGetParams') { if ($controls.Contains($k)) { $controls[$k].IsEnabled = $isWinGet } }
    }
    if ($controls.Contains('Version')) { $controls['Version'].Add_TextChanged($syncWinGet) }
    & $syncWinGet

    # Der Suchname der Programmliste - wie ihn Erkennung und Deinstallation benutzen.
    $syncArp = {
        if (-not $hintBlocks.ContainsKey('ArpName')) { return }
        $name = ''; $arp = ''
        if ($controls.Contains('DisplayName')) { $name = [string]$controls['DisplayName'].Text }
        if ($controls.Contains('ArpName'))     { $arp  = [string]$controls['ArpName'].Text }
        $search = Get-ArpSearchName -DisplayName $name -ArpName $arp
        $hintBlocks['ArpName'].Text = ("Detection and uninstall look for programs whose name STARTS WITH '{0}'. Empty ArpName = DisplayName. Set it when the entry in Apps & features is named differently, or to be more precise - the uninstall removes every match." -f $search)
    }
    foreach ($k in 'DisplayName', 'ArpName') { if ($controls.Contains($k)) { $controls[$k].Add_TextChanged($syncArp) } }
    & $syncArp

    # --- Vorbelegung aus WinGet / MSI (verhalten wie bisher) ---
    $wingetButton.Add_Click({
        try {
            $found = Show-WinGetSearchDialog
            if ($found) {
                & $setValue 'DisplayName' ([string]$found.Name)
                & $setValue 'Version' 'LatestAvailable'
                & $setValue 'Publisher' ([string]$found.Publisher)
                & $setValue 'ProgramID' ([string]$found.Id)
                & $setValue 'InstallCmd' ([string]$found.InstallCmd)
                & $setValue 'WinGetParams' '"--scope=machine"'
            }
        }
        catch { $errorText.Text = ("WinGet search failed: {0}" -f (Format-ErrorDetail $_)) }
    })
    $msiButton.Add_Click({
        try {
            $dialog = New-Object Microsoft.Win32.OpenFileDialog
            $dialog.Title  = 'Select MSI'
            $dialog.Filter = 'MSI files (*.msi)|*.msi|All files (*.*)|*.*'
            $dialog.Multiselect = $false
            if ($dialog.ShowDialog() -eq $true -and $dialog.FileName) {
                $props = Get-MsiProperties -Path $dialog.FileName
                & $setValue 'DisplayName' ([string]$props.ProductName)
                & $setValue 'Version' ([string]$props.ProductVersion)
                & $setValue 'Publisher' ([string]$props.Manufacturer)
                & $setValue 'MsiProductCode' ([string]$props.ProductCode)
                & $setValue 'SingleMSI' 'true'
            }
        }
        catch { $errorText.Text = ("Reading the MSI failed: {0}" -f (Format-ErrorDetail $_)) }
    })

    # --- OK: pruefen, bei Fehler offen bleiben ---
    $okButton.Add_Click({
        $values = [ordered]@{}
        foreach ($k in $keys) { $values[$k] = (& $getValue $k) }
        $problem = Test-AppRecord -Record ([pscustomobject]$values) -Others $Others
        if ($problem) {
            $errorText.Text = $problem
            return
        }
        $window.DialogResult = $true
    })

    $window.Content = $dock
    $result = $window.ShowDialog()

    if ($result -eq $true) {
        $newItem = [ordered]@{}
        foreach ($k in $keys) { $newItem[$k] = (& $getValue $k) }
        return $newItem
    }
}
