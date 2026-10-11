# ============================================================================
#  Rueckfragen und Meldungen: Show-ConfirmDialog ersetzt jede Win32-MessageBox (per UI Automation bedienbar).
# ============================================================================

function Show-ConfirmDialog {
    <#
        .SYNOPSIS
        Eine Rueckfrage als eigenes Fenster - Ersatz fuer MessageBox, der sich per UI Automation bedienen laesst.

        .DESCRIPTION
        Gibt 'Yes' | 'No' | 'Cancel' | 'OK' zurueck, wie [MessageBox]::Show. Die Taste -Default ist die
        Standardtaste (Enter) und hat den Fokus; Esc und das Schliessen des Fensters antworten mit der
        "sicheren" Antwort (OK, No bzw. Cancel) - nie mit Yes. AutomationIds: ConfirmDialog, ConfirmText,
        ConfirmYes, ConfirmNo, ConfirmCancel, ConfirmOK. -Owner zentriert das Fenster
        ueber einem anderen Fenster (Einstellungen, Tenants).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Title = 'IntuneWin32Helper',
        [ValidateSet('OK', 'YesNo', 'YesNoCancel')][string]$Buttons = 'OK',
        [ValidateSet('Yes', 'No', 'Cancel', 'OK')][string]$Default = 'OK',
        [ValidateSet('None', 'Question', 'Warning', 'Information', 'Error')][string]$Icon = 'None',
        [System.Windows.Window]$Owner
    )

    Add-Type -AssemblyName PresentationCore      -ErrorAction SilentlyContinue | Out-Null
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue | Out-Null

    $names = switch ($Buttons) {
        'YesNo'       { @('Yes', 'No') }
        'YesNoCancel' { @('Yes', 'No', 'Cancel') }
        default       { @('OK') }
    }
    if ($names -notcontains $Default) { $Default = $names[0] }
    $safe = $names[-1]

    $window = New-Object Windows.Window
    $window.Title = $Title
    $window.Width = 760
    $window.SizeToContent = 'Height'
    $window.MaxHeight = 720
    $window.WindowStartupLocation = 'CenterScreen'
    if ($Owner) { $window.Owner = $Owner; $window.WindowStartupLocation = 'CenterOwner' }
    $window.ResizeMode = 'NoResize'
    $window.Tag = $safe
    [Windows.Automation.AutomationProperties]::SetAutomationId($window, 'ConfirmDialog')

    $grid = New-Object Windows.Controls.Grid
    $grid.Margin = '16'
    foreach ($height in 'Auto', 'Auto') {
        $rowDefinition = New-Object Windows.Controls.RowDefinition
        $rowDefinition.Height = [Windows.GridLength]::Auto
        $null = $grid.RowDefinitions.Add($rowDefinition)
    }

    $body = New-Object Windows.Controls.DockPanel
    $body.LastChildFill = $true
    $glyph = switch ($Icon) { 'Warning' { [string][char]0x26A0 } 'Question' { '?' } 'Information' { 'i' } 'Error' { [string][char]0x2716 } default { '' } }
    if ($glyph) {
        $iconBlock = New-Object Windows.Controls.TextBlock
        $iconBlock.Text = $glyph
        $iconBlock.FontSize = 32
        $iconBlock.Margin = '0,0,14,0'
        $iconBlock.VerticalAlignment = 'Top'
        $iconBlock.Foreground = $(switch ($Icon) { 'Warning' { 'DarkOrange' } 'Error' { 'Firebrick' } default { 'SteelBlue' } })
        [Windows.Controls.DockPanel]::SetDock($iconBlock, 'Left')
        $null = $body.Children.Add($iconBlock)
    }
    $scroll = New-Object Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $scroll.MaxHeight = 560
    $textBlock = New-Object Windows.Controls.TextBlock
    $textBlock.Text = $Text
    $textBlock.TextWrapping = 'Wrap'
    [Windows.Automation.AutomationProperties]::SetAutomationId($textBlock, 'ConfirmText')
    $scroll.Content = $textBlock
    $null = $body.Children.Add($scroll)
    [Windows.Controls.Grid]::SetRow($body, 0)
    $null = $grid.Children.Add($body)

    $panel = New-Object Windows.Controls.StackPanel
    $panel.Orientation = 'Horizontal'
    $panel.HorizontalAlignment = 'Right'
    $panel.Margin = '0,16,0,0'
    $defaultButton = $null
    foreach ($name in $names) {
        $button = New-Object Windows.Controls.Button
        $button.Content = $name
        $button.MinWidth = 84
        $button.Padding = '14,4'
        $button.Margin = '8,0,0,0'
        $button.IsDefault = ($name -eq $Default)
        $button.IsCancel  = ($name -eq $safe)
        [Windows.Automation.AutomationProperties]::SetAutomationId($button, "Confirm$name")
        $answer = $name
        $button.Add_Click({ $window.Tag = $answer; $window.Close() }.GetNewClosure())
        if ($name -eq $Default) { $defaultButton = $button }
        $null = $panel.Children.Add($button)
    }
    [Windows.Controls.Grid]::SetRow($panel, 1)
    $null = $grid.Children.Add($panel)

    $window.Content = $grid
    $window.Add_ContentRendered({ $null = $defaultButton.Focus() }.GetNewClosure())
    $null = $window.ShowDialog()
    return [string]$window.Tag
}
