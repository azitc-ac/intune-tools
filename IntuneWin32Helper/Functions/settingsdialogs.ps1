# ============================================================================
#  Einstellungen und Tenants.
# ============================================================================

function Edit-SettingsDialog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [System.Windows.Window]$Owner,

        [string[]]$PreferredPaths = @(            
            (Join-Path $rootPath "Config\config.json")
        )
    )

    Add-Type -AssemblyName PresentationCore | Out-Null
    Add-Type -AssemblyName PresentationFramework | Out-Null
    Add-Type -AssemblyName System.Windows.Forms | Out-Null

    function Resolve-ConfigPath {
        param([string[]]$Paths)
        $resolved = $null
        foreach ($p in $Paths) { if ($p -and (Test-Path -LiteralPath $p)) { $resolved = $p; break } }
        if ($resolved -eq $null) {
            foreach ($p in $Paths) {
                if ($p) {
                    $dir = Split-Path -Path $p -Parent
                    if ($dir -and (Test-Path -LiteralPath $dir)) { $resolved = $p; break }
                }
            }
        }
        return $resolved
    }

    function Load-ConfigObject {
        param([string]$Path)
        $obj = $null
        if ($Path -and (Test-Path -LiteralPath $Path)) {
            try {
                $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
                $obj = $raw | ConvertFrom-Json -ErrorAction Stop
            } catch {
                $null = Show-ConfirmDialog -Text ("JSON could not be loaded: {0}" -f $_.Exception.Message) -Title "Error" -Buttons OK -Icon Error -Default OK
            }
        }
        if ($obj -eq $null) {
            $obj = [PSCustomObject]@{
                packetRoot = "$env:TEMP\IntuneWin32Helper\out"
                removeExistingPacketDirOnEachRun = $false
                tenants   = @()
            }
        }
        if ($obj.tenants -eq $null) { $obj.tenants = @() }
        return $obj
    }

    function Save-ConfigObject {
        param([hashtable]$Data, [string]$Path)
        try {
            $dir = Split-Path -Path $Path -Parent
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $json = ConvertTo-Json -InputObject $Data -Depth 8
            Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
            return $true
        } catch {
            $null = Show-ConfirmDialog -Text ("JSON could not be saved: {0}" -f $_.Exception.Message) -Title "Error" -Buttons OK -Icon Error -Default OK
            return $false
        }
    }

    function Test-GuidString {
        param([string]$Text)
        $isGuid = $false
        try { $null = [Guid]::Parse($Text); $isGuid = $true } catch { $isGuid = $false }
        return $isGuid
    }

    # Pfad & Laden
    $configPath = Resolve-ConfigPath -Paths $PreferredPaths
    $cfg = Load-ConfigObject -Path $configPath

    # Fenster
    $dlg = New-Object Windows.Window
    $dlg.Title = "Edit settings"
    $dlg.Width = 900
    $dlg.Height = 640
    $dlg.WindowStartupLocation = "CenterOwner"
    if ($Owner -ne $null) { $dlg.Owner = $Owner }

    # Root-Grid
    $root = New-Object Windows.Controls.Grid
    $root.Margin = "12"
    $rowPath = New-Object Windows.Controls.RowDefinition; $rowPath.Height = [Windows.GridLength]::Auto
    $rowTabs = New-Object Windows.Controls.RowDefinition; $rowTabs.Height = New-Object Windows.GridLength -ArgumentList 1, ([Windows.GridUnitType]::Star)
    $rowBtns = New-Object Windows.Controls.RowDefinition; $rowBtns.Height = [Windows.GridLength]::Auto
    $null = $root.RowDefinitions.Add($rowPath); $null = $root.RowDefinitions.Add($rowTabs); $null = $root.RowDefinitions.Add($rowBtns)

    # Pfadzeile
    $pathGrid = New-Object Windows.Controls.Grid
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = "*"
    $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = "Auto"
    $null = $pathGrid.ColumnDefinitions.Add($c1); $null = $pathGrid.ColumnDefinitions.Add($c2)

    $tbPath = New-Object Windows.Controls.TextBox
    $tbPath.Text = $configPath
    $tbPath.Margin = "0,0,8,0"
    [Windows.Controls.Grid]::SetColumn($tbPath, 0)

    $btnBrowse = New-Object Windows.Controls.Button
    $btnBrowse.Content = "Browse..."
    [Windows.Controls.Grid]::SetColumn($btnBrowse, 1)

    $null = $pathGrid.Children.Add($tbPath); $null = $pathGrid.Children.Add($btnBrowse)
    [Windows.Controls.Grid]::SetRow($pathGrid, 0); $null = $root.Children.Add($pathGrid)

    # Tabs
    $tabs = New-Object Windows.Controls.TabControl
    [Windows.Controls.Grid]::SetRow($tabs, 1); $null = $root.Children.Add($tabs)

    # --- Tab: Allgemein ---
    $tabGeneral = New-Object Windows.Controls.TabItem
    $tabGeneral.Header = "Common"
    $generalGrid = New-Object Windows.Controls.Grid
    $generalGrid.Margin = "10"

    # 2 Spalten
    $gCol1 = New-Object Windows.Controls.ColumnDefinition; $gCol1.Width = "Auto"
    $gCol2 = New-Object Windows.Controls.ColumnDefinition; $gCol2.Width = "*"
    $null = $generalGrid.ColumnDefinitions.Add($gCol1); $null = $generalGrid.ColumnDefinitions.Add($gCol2)

    # ZEILEN:
    # 0: packetRoot
    # 1: removeExistingPacketDirOnEachRun
    # 2: Überschrift "Logo image conversion"
    # 6: Hyperlink (Cloudinary)
    for ($i=0; $i -lt 2; $i++) { $r = New-Object Windows.Controls.RowDefinition; $r.Height = [Windows.GridLength]::Auto; $null = $generalGrid.RowDefinitions.Add($r) }

    # packetRoot (mit Browse)
    $lblPacketRoot = New-Object Windows.Controls.TextBlock; $lblPacketRoot.Text = "packageRoot:"; $lblPacketRoot.VerticalAlignment = "Center"
    [Windows.Controls.Grid]::SetRow($lblPacketRoot,0); [Windows.Controls.Grid]::SetColumn($lblPacketRoot,0)

    $tbPacketRoot = New-Object Windows.Controls.TextBox; $tbPacketRoot.Margin = "6,0,0,0"; $tbPacketRoot.Text = $cfg.packetRoot
    $btnPacketBrowse = New-Object Windows.Controls.Button; $btnPacketBrowse.Content = "..."; $btnPacketBrowse.Width = 28; $btnPacketBrowse.Margin = "6,0,0,0"
    $cellGrid = New-Object Windows.Controls.Grid
    $cellCol1 = New-Object Windows.Controls.ColumnDefinition; $cellCol1.Width = "*"
    $cellCol2 = New-Object Windows.Controls.ColumnDefinition; $cellCol2.Width = "Auto"
    $null = $cellGrid.ColumnDefinitions.Add($cellCol1); $null = $cellGrid.ColumnDefinitions.Add($cellCol2)
    [Windows.Controls.Grid]::SetColumn($tbPacketRoot,0); [Windows.Controls.Grid]::SetColumn($btnPacketBrowse,1)
    $null = $cellGrid.Children.Add($tbPacketRoot); $null = $cellGrid.Children.Add($btnPacketBrowse)
    [Windows.Controls.Grid]::SetRow($cellGrid,0); [Windows.Controls.Grid]::SetColumn($cellGrid,1)

    # removeExistingPacketDirOnEachRun
    $lblRemove = New-Object Windows.Controls.TextBlock; $lblRemove.Text = "removeExistingPackageDirOnEachRun:"; $lblRemove.VerticalAlignment = "Center"
    [Windows.Controls.Grid]::SetRow($lblRemove,1); [Windows.Controls.Grid]::SetColumn($lblRemove,0)
    $cbRemove = New-Object Windows.Controls.CheckBox; $cbRemove.Margin = "6,0,0,0"; $cbRemove.IsChecked = $false
    if ($cfg.removeExistingPacketDirOnEachRun -is [bool]) { $cbRemove.IsChecked = $cfg.removeExistingPacketDirOnEachRun }
    elseif ($cfg.removeExistingPacketDirOnEachRun -is [string]) {
        $valLower = $cfg.removeExistingPacketDirOnEachRun.ToLower()
        if ($valLower -eq "true") { $cbRemove.IsChecked = $true }
        if ($valLower -eq "false") { $cbRemove.IsChecked = $false }
    }
    [Windows.Controls.Grid]::SetRow($cbRemove,1); [Windows.Controls.Grid]::SetColumn($cbRemove,1)

    # Controls in Tab "Allgemein" einfügen
    $null = $generalGrid.Children.Add($lblPacketRoot)
    $null = $generalGrid.Children.Add($cellGrid)
    $null = $generalGrid.Children.Add($lblRemove)
    $null = $generalGrid.Children.Add($cbRemove)

    $tabGeneral.Content = $generalGrid
    $null = $tabs.Items.Add($tabGeneral)

    # --- Tab: Tenants (inkl. clientSecret) ---
    $tabTenants = New-Object Windows.Controls.TabItem
    $tabTenants.Header = "Tenants"
    $tenantsGrid = New-Object Windows.Controls.Grid
    $tenantsGrid.Margin = "10"
    $tRow1 = New-Object Windows.Controls.RowDefinition; $tRow1.Height = New-Object Windows.GridLength -ArgumentList 1, ([Windows.GridUnitType]::Star)
    $tRow2 = New-Object Windows.Controls.RowDefinition; $tRow2.Height = [Windows.GridLength]::Auto
    $null = $tenantsGrid.RowDefinitions.Add($tRow1); $null = $tenantsGrid.RowDefinitions.Add($tRow2)

    $dgTenants = New-Object Windows.Controls.DataGrid
    $dgTenants.AutoGenerateColumns = $false
    $dgTenants.CanUserAddRows = $false
    $dgTenants.CanUserDeleteRows = $false
    $dgTenants.IsReadOnly = $false
    $dgTenants.SelectionMode = 'Extended'
    $dgTenants.SelectionUnit = 'FullRow'

    $colTName   = New-Object Windows.Controls.DataGridTextColumn; $colTName.Header   = "name";         $colTName.Binding   = New-Object Windows.Data.Binding("name")
    $colTAppId  = New-Object Windows.Controls.DataGridTextColumn; $colTAppId.Header  = "appid";        $colTAppId.Binding  = New-Object Windows.Data.Binding("appid")
    $colTSecret = New-Object Windows.Controls.DataGridTextColumn; $colTSecret.Header = "clientSecret"; $colTSecret.Binding = New-Object Windows.Data.Binding("clientSecret"); $colTSecret.Width = 260

    $null = $dgTenants.Columns.Add($colTName)
    $null = $dgTenants.Columns.Add($colTAppId)
    $null = $dgTenants.Columns.Add($colTSecret)

    $tenantItems = @()
    foreach ($t in $cfg.tenants) {
        $secret = ""
        if ($t.PSObject.Properties.Name -contains "clientSecret") { $secret = $t.clientSecret }
        $tenantItems += [PSCustomObject]@{ name = $t.name; appid = $t.appid; clientSecret = $secret }
    }
    $dgTenants.ItemsSource = $tenantItems

    [Windows.Controls.Grid]::SetRow($dgTenants, 0); $null = $tenantsGrid.Children.Add($dgTenants)

    $spTenantBtns = New-Object Windows.Controls.StackPanel
    $spTenantBtns.Orientation = "Horizontal"
    $spTenantBtns.HorizontalAlignment = "Right"
    $btnTenantAdd    = New-Object Windows.Controls.Button; $btnTenantAdd.Content    = "Add"; $btnTenantAdd.Margin    = "0,10,8,0"; $btnTenantAdd.Padding    = "14,6"
    $btnTenantEdit   = New-Object Windows.Controls.Button; $btnTenantEdit.Content   = "Edit"; $btnTenantEdit.Margin   = "0,10,8,0"; $btnTenantEdit.Padding   = "14,6"
    $btnTenantDelete = New-Object Windows.Controls.Button; $btnTenantDelete.Content = "Delete";    $btnTenantDelete.Margin = "0,10,0,0";  $btnTenantDelete.Padding = "14,6"
    $null = $spTenantBtns.Children.Add($btnTenantAdd)
    $null = $spTenantBtns.Children.Add($btnTenantEdit)
    $null = $spTenantBtns.Children.Add($btnTenantDelete)
    [Windows.Controls.Grid]::SetRow($spTenantBtns, 1); $null = $tenantsGrid.Children.Add($spTenantBtns)

    $tabTenants.Content = $tenantsGrid
    $null = $tabs.Items.Add($tabTenants)

    # --- Untere Buttons ---
    $spBtns = New-Object Windows.Controls.StackPanel
    $spBtns.Orientation = "Horizontal"
    $spBtns.HorizontalAlignment = "Right"
    $btnReload = New-Object Windows.Controls.Button; $btnReload.Content = "Reload"; $btnReload.Margin = "0,10,8,0"; $btnReload.Padding = "14,6"
    $btnSave   = New-Object Windows.Controls.Button; $btnSave.Content   = "Save"; $btnSave.Margin  = "0,10,8,0"; $btnSave.Padding  = "14,6"
    $btnClose  = New-Object Windows.Controls.Button; $btnClose.Content  = "Close"; $btnClose.Margin = "0,10,0,0";  $btnClose.Padding = "14,6"
    $null = $spBtns.Children.Add($btnReload); $null = $spBtns.Children.Add($btnSave); $null = $spBtns.Children.Add($btnClose)
    [Windows.Controls.Grid]::SetRow($spBtns, 2); $null = $root.Children.Add($spBtns)

    $dlg.Content = $root

    # --- Events ---

    # Datei durchsuchen
    $btnBrowse.Add_Click({
        try {
            $ofd = New-Object System.Windows.Forms.OpenFileDialog
            $ofd.Filter = "JSON file (*.json)|*.json|All files (*.*)|*.*"
            $ofd.Multiselect = $false
            $ofd.CheckFileExists = $false
            $ofd.FileName = "config.json"
            $res = $ofd.ShowDialog()
            if ($res -eq [System.Windows.Forms.DialogResult]::OK) {
                if ($ofd.FileName) { $tbPath.Text = $ofd.FileName }
            }
        } catch {
            $null = Show-ConfirmDialog -Text ("File selection falied: {0}" -f $_.Exception.Message) -Title "Error" -Buttons OK -Icon Error -Default OK -Owner $dlg
        }
    })

    # packetRoot Ordnerauswahl
    $btnPacketBrowse.Add_Click({
        try {
            $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
            $fbd.Description = "Select PackageRoot"
            $fbd.ShowNewFolderButton = $true
            $res = $fbd.ShowDialog()
            if ($res -eq [System.Windows.Forms.DialogResult]::OK) {
                if ($fbd.SelectedPath) { $tbPacketRoot.Text = $fbd.SelectedPath }
            }
        } catch {
            $null = Show-ConfirmDialog -Text ("Folder selection failed: {0}" -f $_.Exception.Message) -Title "Error" -Buttons OK -Icon Error -Default OK -Owner $dlg
        }
    })

    # Tenants: Hinzufügen
    $btnTenantAdd.Add_Click({
        try {
            $newTenant = Edit-TenantDialog -Owner $dlg
            if ($newTenant -ne $null) {
                $list = @($dgTenants.ItemsSource)
                $list += [PSCustomObject]@{ name = $newTenant.name; appid = $newTenant.appid; clientSecret = $newTenant.clientSecret }
                $dgTenants.ItemsSource = $null
                $dgTenants.ItemsSource = $list
            }
        } catch {
            $null = Show-ConfirmDialog -Text ("Tenant edit failed: {0}" -f $_.Exception.Message) -Title "Error" -Buttons OK -Icon Error -Default OK -Owner $dlg
        }
    })

    # Tenants: Bearbeiten
    $btnTenantEdit.Add_Click({
        try {
            $sel = $dgTenants.SelectedItem
            if ($sel -eq $null) {
                $null = Show-ConfirmDialog -Text "Please select a tenant." -Title "Hint" -Buttons OK -Icon Information -Default OK -Owner $dlg
                return
            }
            $initialSecret = ""
            if ($sel.PSObject.Properties.Name -contains "clientSecret") { $initialSecret = $sel.clientSecret }
            $edited = Edit-TenantDialog -Owner $dlg -InitialName $sel.name -InitialAppId $sel.appid -InitialClientSecret $initialSecret
            if ($edited -ne $null) {
                $sel.name         = $edited.name
                $sel.appid        = $edited.appid
                $sel.clientSecret = $edited.clientSecret
                $dgTenants.Items.Refresh()
            }
        } catch {
            $null = Show-ConfirmDialog -Text ("Tenant edit failed: {0}" -f $_.Exception.Message) -Title "Error" -Buttons OK -Icon Error -Default OK -Owner $dlg
        }
    })

    # Tenants: Löschen
    $btnTenantDelete.Add_Click({
        try {
            $selected = $dgTenants.SelectedItems
            if ($selected -eq $null -or $selected.Count -eq 0) {
                $null = Show-ConfirmDialog -Text "No tenants selected for deletion." -Title "Hint" -Buttons OK -Icon Information -Default OK -Owner $dlg
                return
            }
            $confirm = Show-ConfirmDialog -Text "Delete selected Tenants ?" -Title "Confirm" -Buttons YesNo -Icon Warning -Default No -Owner $dlg
            if ($confirm -eq "Yes") {
                $remaining = @()
                $current = @($dgTenants.ItemsSource)
                foreach ($item in $current) {
                    $isSelected = $false
                    foreach ($s in $selected) { if ($item -eq $s) { $isSelected = $true; break } }
                    if (-not $isSelected) { $remaining += $item }
                }
                $dgTenants.ItemsSource = $null
                $dgTenants.ItemsSource = $remaining
            }
        } catch {
            $null = Show-ConfirmDialog -Text ("Tenant edit failed: {0}" -f $_.Exception.Message) -Title "Error" -Buttons OK -Icon Error -Default OK -Owner $dlg
        }
    })

    # Neu laden
    $btnReload.Add_Click({
        try {
            $cfg = Load-ConfigObject -Path $tbPath.Text
            # Allgemein
            $tbPacketRoot.Text = $cfg.packetRoot
            $cbRemove.IsChecked = $false
            if ($cfg.removeExistingPacketDirOnEachRun -is [bool]) { $cbRemove.IsChecked = $cfg.removeExistingPacketDirOnEachRun }
            elseif ($cfg.removeExistingPacketDirOnEachRun -is [string]) {
                $valLower = $cfg.removeExistingPacketDirOnEachRun.ToLower()
                if ($valLower -eq "true") { $cbRemove.IsChecked = $true }
                if ($valLower -eq "false") { $cbRemove.IsChecked = $false }
            }
            # Tenants
            $tenantItems = @()
            foreach ($t in $cfg.tenants) {
                $secret = ""
                if ($t.PSObject.Properties.Name -contains "clientSecret") { $secret = $t.clientSecret }
                $tenantItems += [PSCustomObject]@{ name = $t.name; appid = $t.appid; clientSecret = $secret }
            }
            $dgTenants.ItemsSource = $null
            $dgTenants.ItemsSource = $tenantItems
        } catch {
            $null = Show-ConfirmDialog -Text ("Reloading failed: {0}" -f $_.Exception.Message) -Title "Error" -Buttons OK -Icon Error -Default OK -Owner $dlg
        }
    })

    # Speichern
    $btnSave.Add_Click({
        try {
            $targetPath = $tbPath.Text
            if (-not $targetPath) {
                $null = Show-ConfirmDialog -Text "No path given." -Title "Hint" -Buttons OK -Icon Warning -Default OK -Owner $dlg
                return
            }

            # Tenants validieren/sammeln
            $tenantArray = @()
            foreach ($row in @($dgTenants.ItemsSource)) {
                $n = $row.name
                $a = $row.appid
                $s = ""
                if ($row.PSObject.Properties.Name -contains "clientSecret") { $s = $row.clientSecret }
                if (-not $n -or $n.Trim().Length -eq 0) {
                    $null = Show-ConfirmDialog -Text "Tenant name must not be empty." -Title "Validation" -Buttons OK -Icon Warning -Default OK -Owner $dlg
                    return
                }
                if (-not (Test-GuidString -Text $a)) {
                    $null = Show-ConfirmDialog -Text ("Invalid AppId (GUID) for tenant '{0}'." -f $n) -Title "Validation" -Buttons OK -Icon Warning -Default OK -Owner $dlg
                    return
                }
                $tenantArray += @{ name = $n; appid = $a; clientSecret = $s }
            }

            # Allgemein sammeln
            $removeBool = $false
            if ($cbRemove.IsChecked -eq $true) { $removeBool = $true }

            $data = @{
                packetRoot = $tbPacketRoot.Text
                removeExistingPacketDirOnEachRun = $removeBool
                tenants   = $tenantArray
            }

            $ok = Save-ConfigObject -Data $data -Path $targetPath
            if ($ok) { $null = Show-ConfirmDialog -Text ("Saved: {0}" -f $targetPath) -Title "Success" -Buttons OK -Icon Information -Default OK -Owner $dlg }
        } catch {
            $null = Show-ConfirmDialog -Text ("Save failed: {0}" -f $_.Exception.Message) -Title "Error" -Buttons OK -Icon Error -Default OK -Owner $dlg
        }
    })

    # Schließen
    $btnClose.Add_Click({
        $dlg.DialogResult = $false
        $dlg.Close()
    })

    $null = $dlg.ShowDialog()
    return $true
}

#
function Edit-TenantDialog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [System.Windows.Window]$Owner,
        [string]$InitialName = "",
        [string]$InitialAppId = "",
        [string]$InitialClientSecret = ""
    )

    Add-Type -AssemblyName PresentationCore | Out-Null
    Add-Type -AssemblyName PresentationFramework | Out-Null

    function Test-GuidString {
        param([string]$Text)
        $isGuid = $false
        try {
            $null = [Guid]::Parse($Text)
            $isGuid = $true
        } catch {
            $isGuid = $false
        }
        return $isGuid
    }

    $dlg = New-Object Windows.Window
    $dlg.Title = "Tenant Edit"
    $dlg.Width = 560
    $dlg.Height = 280
    $dlg.WindowStartupLocation = "CenterOwner"
    if ($Owner -ne $null) { $dlg.Owner = $Owner }

    $grid = New-Object Windows.Controls.Grid
    $grid.Margin = "12"

    # Zeilen: name, appid, clientSecret, Buttons
    $row1 = New-Object Windows.Controls.RowDefinition; $row1.Height = [Windows.GridLength]::Auto
    $row2 = New-Object Windows.Controls.RowDefinition; $row2.Height = [Windows.GridLength]::Auto
    $row3 = New-Object Windows.Controls.RowDefinition; $row3.Height = [Windows.GridLength]::Auto
    $row4 = New-Object Windows.Controls.RowDefinition; $row4.Height = [Windows.GridLength]::Auto
    $null = $grid.RowDefinitions.Add($row1)
    $null = $grid.RowDefinitions.Add($row2)
    $null = $grid.RowDefinitions.Add($row3)
    $null = $grid.RowDefinitions.Add($row4)

    # Spalten: Label + Control
    $col1 = New-Object Windows.Controls.ColumnDefinition; $col1.Width = "Auto"
    $col2 = New-Object Windows.Controls.ColumnDefinition; $col2.Width = "*"
    $null = $grid.ColumnDefinitions.Add($col1)
    $null = $grid.ColumnDefinitions.Add($col2)

    # --- name ---
    $lblName = New-Object Windows.Controls.TextBlock
    $lblName.Text = "name:"
    $lblName.VerticalAlignment = "Center"
    [Windows.Controls.Grid]::SetRow($lblName,0); [Windows.Controls.Grid]::SetColumn($lblName,0)

    $tbName = New-Object Windows.Controls.TextBox
    $tbName.Margin = "6,0,0,0"
    $tbName.Text = $InitialName
    [Windows.Controls.Grid]::SetRow($tbName,0); [Windows.Controls.Grid]::SetColumn($tbName,1)

    # --- appid ---
    $lblAppId = New-Object Windows.Controls.TextBlock
    $lblAppId.Text = "appid (GUID):"
    $lblAppId.VerticalAlignment = "Center"
    [Windows.Controls.Grid]::SetRow($lblAppId,1); [Windows.Controls.Grid]::SetColumn($lblAppId,0)

    $tbAppId = New-Object Windows.Controls.TextBox
    $tbAppId.Margin = "6,0,0,0"
    $tbAppId.Text = $InitialAppId
    [Windows.Controls.Grid]::SetRow($tbAppId,1); [Windows.Controls.Grid]::SetColumn($tbAppId,1)

    # --- clientSecret (PasswordBox + Anzeigen-Checkbox) ---
    $lblSecret = New-Object Windows.Controls.TextBlock
    $lblSecret.Text = "clientSecret (optional):"
    $lblSecret.VerticalAlignment = "Center"
    [Windows.Controls.Grid]::SetRow($lblSecret,2); [Windows.Controls.Grid]::SetColumn($lblSecret,0)

    # Wir bauen rechts eine kleine Zelle mit PasswordBox + "anzeigen" Checkbox
    $secretCell = New-Object Windows.Controls.Grid
    $scCol1 = New-Object Windows.Controls.ColumnDefinition; $scCol1.Width = "*"
    $scCol2 = New-Object Windows.Controls.ColumnDefinition; $scCol2.Width = "Auto"
    $null = $secretCell.ColumnDefinitions.Add($scCol1)
    $null = $secretCell.ColumnDefinitions.Add($scCol2)

    $pbSecret = New-Object Windows.Controls.PasswordBox
    $pbSecret.Margin = "6,0,0,0"
    # PasswordBox kann nicht direkt vorbefüllt werden mit Klartext in sicheren Szenarien;
    # in WPF geht Set-Password nur über .Password:
    if ($InitialClientSecret) { $pbSecret.Password = $InitialClientSecret }
    [Windows.Controls.Grid]::SetColumn($pbSecret,0)

    $cbShow = New-Object Windows.Controls.CheckBox
    $cbShow.Content = "anzeigen"
    $cbShow.Margin = "6,0,0,0"
    [Windows.Controls.Grid]::SetColumn($cbShow,1)

    $null = $secretCell.Children.Add($pbSecret)
    $null = $secretCell.Children.Add($cbShow)

    [Windows.Controls.Grid]::SetRow($secretCell,2); [Windows.Controls.Grid]::SetColumn($secretCell,1)

    # Optional: bei "anzeigen" den Secret-Wert temporär in einem TextBox anzeigen
    # (Wir tauschen visuell zwischen PasswordBox und TextBox)
    $tbSecretPlain = New-Object Windows.Controls.TextBox
    $tbSecretPlain.Margin = "6,0,0,0"
    $tbSecretPlain.Visibility = 'Collapsed'
    if ($InitialClientSecret) { $tbSecretPlain.Text = $InitialClientSecret }
    # Wir legen die TextBox oben auf Column 0 derselben Zelle
    [Windows.Controls.Grid]::SetColumn($tbSecretPlain,0)
    $null = $secretCell.Children.Add($tbSecretPlain)

    # Toggle-Logik für Anzeigen
    $cbShow.Add_Checked({
        # Plain sichtbar, PasswordBox ausblenden; Inhalt synchronisieren
        $tbSecretPlain.Text = $pbSecret.Password
        $tbSecretPlain.Visibility = 'Visible'
        $pbSecret.Visibility = 'Collapsed'
    })
    $cbShow.Add_Unchecked({
        # PasswordBox sichtbar, Plain ausblenden; Inhalt synchronisieren
        $pbSecret.Password = $tbSecretPlain.Text
        $pbSecret.Visibility = 'Visible'
        $tbSecretPlain.Visibility = 'Collapsed'
    })

    # --- Buttons ---
    $spBtns = New-Object Windows.Controls.StackPanel
    $spBtns.Orientation = "Horizontal"
    $spBtns.HorizontalAlignment = "Right"
    [Windows.Controls.Grid]::SetRow($spBtns, 3); [Windows.Controls.Grid]::SetColumnSpan($spBtns, 2)

    $btnOK = New-Object Windows.Controls.Button
    $btnOK.Content = "OK"
    $btnOK.Margin = "0,10,8,0"
    $btnOK.Padding = "14,6"

    $btnCancel = New-Object Windows.Controls.Button
    $btnCancel.Content = "Cancel"
    $btnCancel.Margin = "0,10,0,0"
    $btnCancel.Padding = "14,6"

    $null = $spBtns.Children.Add($btnOK)
    $null = $spBtns.Children.Add($btnCancel)

    # --- Layout zusammenfügen ---
    $null = $grid.Children.Add($lblName)
    $null = $grid.Children.Add($tbName)
    $null = $grid.Children.Add($lblAppId)
    $null = $grid.Children.Add($tbAppId)
    $null = $grid.Children.Add($lblSecret)
    $null = $grid.Children.Add($secretCell)
    $null = $grid.Children.Add($spBtns)

    $dlg.Content = $grid

    $script:TenantResult = $null

    $btnCancel.Add_Click({
        $dlg.DialogResult = $false
        $dlg.Close()
    })

    $btnOK.Add_Click({
        try {
            $n = $tbName.Text
            $a = $tbAppId.Text
            # Secret: je nach Sichtbarkeit aus PasswordBox oder Plain-TextBox lesen
            $s = $pbSecret.Password
            if ($tbSecretPlain.Visibility -eq 'Visible') { $s = $tbSecretPlain.Text }

            if (-not $n -or $n.Trim().Length -eq 0) {
                $null = Show-ConfirmDialog -Text "Name must not be empty." -Title "Validation" -Buttons OK -Icon Warning -Default OK -Owner $dlg
                return
            }
            if (-not (Test-GuidString -Text $a)) {
                $null = Show-ConfirmDialog -Text "AppId is not a valid GUID." -Title "Validation" -Buttons OK -Icon Warning -Default OK -Owner $dlg
                return
            }
            # clientSecret darf leer sein; keine weitere Validierung erforderlich
            $script:TenantResult = [PSCustomObject]@{
                name         = $n
                appid        = $a
                clientSecret = $s
            }
            $dlg.DialogResult = $true
            $dlg.Close()
        } catch {
            $null = Show-ConfirmDialog -Text ("Error: {0}" -f (Format-ErrorDetail $_)) -Title "Error" -Buttons OK -Icon Error -Default OK -Owner $dlg
        }
    })

    $null = $dlg.ShowDialog()
    return $script:TenantResult
}
