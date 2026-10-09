<#
    .SYNOPSIS
    Verhaltenstest: ein Deploy legt keine Dublette an, weil niemand nachgesehen hat.

    .DESCRIPTION
    Das erzeugte deploy.ps1 legte im Bulk-Lauf IMMER eine neue App an - auch wenn dieselbe
    App in derselben Version schon in Intune lag. Seit Stufe 3 entscheidet das Tool vorher
    (Get-DeployPlan) und gibt die Entscheidung an das deploy.ps1 weiter (-Mode). Geprueft wird,
    ohne Tenant und ohne Netz:

      1. Inventar: Intune-Apps werden nach Name UND Version abgeglichen. Zwei Versionen derselben
         App sind keine Dubletten; zwei Apps mit Name und Version schon.
      2. Get-DeployPlan: Create / Skip / Update je Zustand, und dass ein nicht gelesener
         Intune-Zustand nicht geplant wird.
      3. Invoke-PackageDeploy ruft das deploy.ps1 mit -Mode und -UpdateAppId auf (ein Skript, das
         seine Parameter aufschreibt, steht fuer das Paket) und bricht VOR dem ersten Upload ab,
         wenn eine Entscheidung fehlt.
      4. Invoke-InventoryDeploy: liest Intune frisch (auch wenn das Fenster einen anderen Stand
         zeigt), baut nur, was verteilt wird, verteilt nur, was der Plan erlaubt, und tut bei
         Abbruch oder nicht lesbarem Tenant nichts.

    Die Mocks ersetzen nur, was Netz oder Windows braucht (Tenant lesen, Paket bauen, Skript
    hochladen); Inventar, Plan und Deploy-Aufruf laufen echt.
#>
$ErrorActionPreference = 'Stop'

$rootDir = Split-Path -Parent $PSScriptRoot
$functionsPath = Join-Path $rootDir 'Functions\functions.ps1'

$ast = [System.Management.Automation.Language.Parser]::ParseFile($functionsPath, [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}

$problems = @()
function Test-That([bool]$condition, [string]$what) { if (-not $condition) { $script:problems += $what } }

$current = Get-TemplateFingerprint -RootDir $rootDir
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('iw32h-plan-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $work
$packets = Join-Path $work 'packets'
$null = New-Item -ItemType Directory -Force -Path $packets
$fakes = Join-Path $work 'fakes'
$null = New-Item -ItemType Directory -Force -Path $fakes

function New-App([string]$name, [string]$version, [string]$id = '', [string]$content = '1', [string]$state = 'published') {
    [pscustomobject]@{ id = $(if ($id) { $id } else { "id-$name-$version" }); displayName = $name; displayVersion = $version; publishingState = $state; committedContentVersion = $content }
}
function New-TestPackage([string]$name, [string]$version) {
    $folder = Join-Path $packets "$name - $version"
    $null = New-Item -ItemType Directory -Force -Path $folder
    Write-DeployScript -AppFolder $folder -AppName $name -AppVersion $version -Publisher 'Test' -Description 'Installed using PSADT' `
        -RootDir $rootDir -ToolVersion '0.0.1' -Architecture 'x64' -MinimumOS 'W10_20H2' -MsiProductCode '' 6>$null
}

try {
    # ------------------------------------------------------------------ 1) Inventar: Name UND Version
    $defsInv = @(
        [pscustomobject]@{ DisplayName = 'Exact';   Version = '1.0' },
        [pscustomobject]@{ DisplayName = 'Newer';   Version = '2.0' },
        [pscustomobject]@{ DisplayName = 'Multi';   Version = '1.0' },
        [pscustomobject]@{ DisplayName = 'Multi';   Version = '2.0' },
        [pscustomobject]@{ DisplayName = 'Twin';    Version = '1.0' },
        [pscustomobject]@{ DisplayName = 'NoVer';   Version = '1.0' },
        [pscustomobject]@{ DisplayName = 'Absent';  Version = '1.0' }
    )
    $appsInv = @(
        (New-App 'Exact' '1.0'),
        (New-App 'Newer' '1.0'),
        (New-App 'Multi' '1.0'), (New-App 'Multi' '2.0'),
        (New-App 'Twin' '1.0' 'twin-a'), (New-App 'Twin' '1.0' 'twin-b'),
        (New-App 'NoVer' '')
    )
    $inv = @(Get-AppInventory -Definitions $defsInv -PacketRoot $packets -RootDir $rootDir -IntuneApps $appsInv 6>$null)
    $byKey = @{}; foreach ($x in $inv) { $byKey[$x.Key] = $x }

    Test-That ($byKey['Exact - 1.0'].Intune -eq 'yes')                      "inventory: Name+Version match is not 'yes' ('$($byKey['Exact - 1.0'].Intune)')"
    Test-That ($byKey['Exact - 1.0'].IntuneSame.Count -eq 1)                "inventory: Exact has $($byKey['Exact - 1.0'].IntuneSame.Count) same-version apps, expected 1"
    Test-That ($byKey['Newer - 2.0'].Intune -eq 'other version: 1.0')       "inventory: other version only: '$($byKey['Newer - 2.0'].Intune)'"
    Test-That ($byKey['Newer - 2.0'].Next -eq 'deploy (new version)' -or $byKey['Newer - 2.0'].Next -eq 'create package') "inventory: Newer next step '$($byKey['Newer - 2.0'].Next)'"
    # Zwei Versionen derselben App sind KEINE Dubletten (frueher: "yes (2x)" und "check duplicates").
    Test-That ($byKey['Multi - 1.0'].Intune -eq 'yes' -and $byKey['Multi - 2.0'].Intune -eq 'yes') "inventory: two versions of one app flagged: '$($byKey['Multi - 1.0'].Intune)' / '$($byKey['Multi - 2.0'].Intune)'"
    Test-That ($byKey['Twin - 1.0'].Intune -eq 'yes (2x)')                  "inventory: same name+version twice: '$($byKey['Twin - 1.0'].Intune)'"
    Test-That ($byKey['NoVer - 1.0'].Intune -eq 'other version: (none)')    "inventory: app without displayVersion: '$($byKey['NoVer - 1.0'].Intune)'"
    Test-That ($byKey['Absent - 1.0'].Intune -eq '-')                       "inventory: absent app: '$($byKey['Absent - 1.0'].Intune)'"
    $unchecked = @(Get-AppInventory -Definitions $defsInv[0..0] -PacketRoot $packets -RootDir $rootDir -IntuneApps $null 6>$null)
    Test-That ($unchecked[0].Intune -eq 'not checked')                      "inventory: not read is '$($unchecked[0].Intune)'"

    # ------------------------------------------------------------------ 2) Get-DeployPlan
    $plan = @{}
    foreach ($p in @(Get-DeployPlan -Rows $inv)) { $plan[$p.Key] = $p }
    Test-That ($plan['Absent - 1.0'].Action -eq 'Create')                   "plan: absent app is '$($plan['Absent - 1.0'].Action)', expected Create"
    Test-That ($plan['Newer - 2.0'].Action -eq 'Create' -and $plan['Newer - 2.0'].Reason -match '1\.0') "plan: new version of an app in Intune: '$($plan['Newer - 2.0'].Action)' / '$($plan['Newer - 2.0'].Reason)'"
    Test-That ($plan['NoVer - 1.0'].Action -eq 'Create')                    "plan: app without a version in Intune is '$($plan['NoVer - 1.0'].Action)', expected Create (different version)"
    Test-That ($plan['Exact - 1.0'].Action -eq 'Skip' -and $plan['Exact - 1.0'].Replaceable) "plan: existing app is '$($plan['Exact - 1.0'].Action)', expected Skip and replaceable"
    Test-That ($plan['Multi - 1.0'].Action -eq 'Skip' -and $plan['Multi - 2.0'].Action -eq 'Skip') "plan: both versions exist, expected two Skips"
    Test-That ($plan['Twin - 1.0'].Action -eq 'Skip' -and -not $plan['Twin - 1.0'].Replaceable -and $plan['Twin - 1.0'].Reason -match 'duplicate') "plan: duplicates: '$($plan['Twin - 1.0'].Action)' / '$($plan['Twin - 1.0'].Reason)'"

    $replace = @{}
    foreach ($p in @(Get-DeployPlan -Rows $inv -ReplaceExisting)) { $replace[$p.Key] = $p }
    Test-That ($replace['Exact - 1.0'].Action -eq 'Update' -and $replace['Exact - 1.0'].UpdateAppId -eq 'id-Exact-1.0') "plan -ReplaceExisting: Exact is '$($replace['Exact - 1.0'].Action)' id '$($replace['Exact - 1.0'].UpdateAppId)'"
    Test-That ($replace['Twin - 1.0'].Action -eq 'Skip')                    "plan -ReplaceExisting: duplicates must stay skipped, got '$($replace['Twin - 1.0'].Action)'"
    Test-That ($replace['Absent - 1.0'].Action -eq 'Create')                "plan -ReplaceExisting: absent app is '$($replace['Absent - 1.0'].Action)'"

    $ghostInv = @(Get-AppInventory -Definitions @([pscustomobject]@{ DisplayName = 'Ghost'; Version = '1.0' }) -PacketRoot $packets -RootDir $rootDir `
        -IntuneApps @((New-App 'Ghost' '1.0' 'g1' '' 'notPublished')) 6>$null)
    $ghostPlan = @(Get-DeployPlan -Rows $ghostInv -ReplaceExisting)[0]
    Test-That ($ghostPlan.Action -eq 'Skip' -and $ghostPlan.Reason -match 'no content') "plan: entry without content: '$($ghostPlan.Action)' / '$($ghostPlan.Reason)' (even with -ReplaceExisting)"

    $threw = $false
    try { $null = @(Get-DeployPlan -Rows $unchecked) } catch { $threw = $true }
    Test-That $threw "plan: a row whose Intune state was not read was planned (not checked must not look like absent)"

    # ------------------------------------------------------------------ 3) Invoke-PackageDeploy (echt)
    $stamp = "# ToolTemplateFingerprint: $current"
    $record = Join-Path $work 'record.txt'
    function New-FakePackage([string]$name) {
        $folder = Join-Path $fakes "$name - fake"
        $null = New-Item -ItemType Directory -Force -Path $folder
        $path = Join-Path $folder 'deploy.ps1'
        $body = @(
            'param([switch]$bulk, $Tenant, [string]$Mode = "Ask", [string]$UpdateAppId = "")',
            $stamp,
            ('Add-Content -LiteralPath "{0}" -Value ("{1}|" + $Mode + "|" + $UpdateAppId + "|bulk=" + $bulk.IsPresent)' -f $record, $name)
        ) -join "`r`n"
        [IO.File]::WriteAllText($path, $body, (New-Object System.Text.UTF8Encoding $true))
        return $path
    }
    $pNew = New-FakePackage 'FakeNew'
    $pUpd = New-FakePackage 'FakeUpd'
    $tenant = [pscustomobject]@{ name = 't' }
    Invoke-PackageDeploy -Packages @(
        [pscustomobject]@{ AppName = 'FakeNew'; AppVersion = 'fake'; FullPath = $pNew; Mode = 'New';    UpdateAppId = '' },
        [pscustomobject]@{ AppName = 'FakeUpd'; AppVersion = 'fake'; FullPath = $pUpd; Mode = 'Update'; UpdateAppId = 'abc-123' }
    ) -Tenant $tenant -RootDir $rootDir -ToolVersion '0.0.1' -Skipped @('Skipped one: already in Intune') 6>$null
    $lines = @(); if (Test-Path -LiteralPath $record) { $lines = @([IO.File]::ReadAllLines($record)) }
    Test-That ($lines -contains 'FakeNew|New||bulk=False')        "deploy call: FakeNew did not get -Mode New without -bulk (got: $($lines -join ' ; '))"
    Test-That ($lines -contains 'FakeUpd|Update|abc-123|bulk=False') "deploy call: FakeUpd did not get -Mode Update -UpdateAppId abc-123 (got: $($lines -join ' ; '))"

    if (Test-Path -LiteralPath $record) { Remove-Item -LiteralPath $record -Force }
    $threw = $false
    try {
        Invoke-PackageDeploy -Packages @(
            [pscustomobject]@{ AppName = 'FakeNew'; AppVersion = 'fake'; FullPath = $pNew; Mode = 'New'; UpdateAppId = '' },
            [pscustomobject]@{ AppName = 'FakeUpd'; AppVersion = 'fake'; FullPath = $pUpd; UpdateAppId = '' }
        ) -Tenant $tenant -RootDir $rootDir -ToolVersion '0.0.1' 6>$null
    } catch { $threw = $true }
    Test-That $threw "deploy call: a package without a decision (Mode) did not stop the run"
    Test-That (-not (Test-Path -LiteralPath $record)) "deploy call: a package ran although another one had no decision - the check must come BEFORE the first upload"

    $threw = $false
    try {
        Invoke-PackageDeploy -Packages @([pscustomobject]@{ AppName = 'FakeUpd'; AppVersion = 'fake'; FullPath = $pUpd; Mode = 'Update'; UpdateAppId = '' }) `
            -Tenant $tenant -RootDir $rootDir -ToolVersion '0.0.1' 6>$null
    } catch { $threw = $true }
    Test-That $threw "deploy call: Mode Update without an app id was accepted"

    # ------------------------------------------------------------------ 4) Invoke-InventoryDeploy (Mocks fuer Netz/Windows)
    $script:tenantApps = @(); $script:tenantReadable = $true; $script:reads = 0
    $script:defs = @(); $script:built = @(); $script:deployed = @(); $script:deploySkipped = @(); $script:deployCalls = 0
    $script:asked = @(); $script:answer = 'Yes'

    function Read-TenantWin32Apps { $script:reads++; if (-not $script:tenantReadable) { return $null }; return , @($script:tenantApps) }
    function Read-AppsCsv { param($RootDir) return @($script:defs) }
    function Invoke-PackageBuild {
        param($Rows, $PacketRoot, $RootDir, $ToolVersion, $RemoveExisting)
        $script:built += @($Rows | ForEach-Object { $_.Key })
        $b = foreach ($row in @($Rows)) { [pscustomobject]@{ AppName = $row.AppName; AppVersion = $row.AppVersion; FullPath = ('C:\fake\{0}\deploy.ps1' -f $row.Key) } }
        return [pscustomobject]@{ Built = @($b); Failed = @() }
    }
    function Invoke-PackageDeploy {
        param($Packages, $Tenant, $RootDir, $ToolVersion, [string[]]$Skipped = @())
        $script:deployCalls++
        $script:deployed = @($Packages)
        $script:deploySkipped = @($Skipped)
    }
    $ask = { param($Text, $Buttons) $script:asked += [pscustomobject]@{ Text = $Text; Buttons = $Buttons }; return $script:answer }

    # Zustand: zwei Pakete im Ordner (Have, MultiOld), eines mit Dublette, eines ohne Inhalt, Neue ohne Paket.
    foreach ($spec in @(@('Have', '1.0'), @('MultiNew', '2.0'), @('MultiOld', '1.0'), @('Dup', '1.0'), @('Ghost', '1.0'))) { New-TestPackage $spec[0] $spec[1] }
    $script:defs = @(
        [pscustomobject]@{ DisplayName = 'Have';     Version = '1.0' },
        [pscustomobject]@{ DisplayName = 'MultiNew'; Version = '2.0' },
        [pscustomobject]@{ DisplayName = 'MultiOld'; Version = '1.0' },
        [pscustomobject]@{ DisplayName = 'Dup';      Version = '1.0' },
        [pscustomobject]@{ DisplayName = 'Ghost';    Version = '1.0' },
        [pscustomobject]@{ DisplayName = 'Fresh';    Version = '1.0' },    # nicht in Intune, kein Paket -> bauen und anlegen
        [pscustomobject]@{ DisplayName = 'ExistsNoPkg'; Version = '1.0' }  # in Intune, kein Paket -> NICHT bauen
    )
    $script:tenantApps = @(
        (New-App 'Have' '1.0'),
        (New-App 'MultiNew' '1.0'),                    # andere Version von MultiNew
        (New-App 'MultiOld' '1.0'),
        (New-App 'Dup' '1.0' 'dup-a'), (New-App 'Dup' '1.0' 'dup-b'),
        (New-App 'Ghost' '1.0' 'ghost-1' '' 'notPublished'),
        (New-App 'ExistsNoPkg' '1.0')
    )
    # Die Auswahl stammt aus einem VERALTETEN Fenster: dort war Intune leer.
    $staleInventory = @(Get-AppInventory -Definitions $script:defs -PacketRoot $packets -RootDir $rootDir -IntuneApps @() 6>$null)
    Test-That ($staleInventory.Count -eq 7) "setup: stale inventory has $($staleInventory.Count) rows, expected 7"
    $run = { param($answerValue)
        $script:built = @(); $script:deployed = @(); $script:deploySkipped = @(); $script:deployCalls = 0; $script:asked = @(); $script:reads = 0
        $script:answer = $answerValue
        Invoke-InventoryDeploy -Selection $staleInventory -Tenant $tenant -RootDir $rootDir -PacketRoot $packets -ToolVersion '0.0.1' -Ask $ask 6>$null
    }

    # 'Yes': wie geplant.
    $null = & $run 'Yes'
    Test-That ($script:reads -ge 1) "inventory deploy: Intune was not read again before planning (stale window state would be trusted)"
    $deployedKeys = @($script:deployed | ForEach-Object { '{0} - {1}:{2}' -f $_.AppName, $_.AppVersion, $_.Mode } | Sort-Object)
    Test-That (($deployedKeys -join ',') -eq 'Fresh - 1.0:New,MultiNew - 2.0:New') "inventory deploy (Yes): deployed [$($deployedKeys -join ', ')], expected [Fresh - 1.0:New, MultiNew - 2.0:New]"
    Test-That (($script:built -join ',') -eq 'Fresh - 1.0') "inventory deploy (Yes): built [$($script:built -join ', ')], expected only [Fresh - 1.0] (a skipped app without package must not be built)"
    $skippedText = $script:deploySkipped -join ' | '
    foreach ($k in 'Have - 1.0', 'MultiOld - 1.0', 'Dup - 1.0', 'Ghost - 1.0', 'ExistsNoPkg - 1.0') {
        Test-That ($skippedText -match [regex]::Escape($k)) "inventory deploy (Yes): $k is missing from the skipped list ($skippedText)"
    }
    Test-That ($script:asked.Count -eq 1 -and $script:asked[0].Buttons -eq 'YesNoCancel') "inventory deploy: expected one YesNoCancel question, got $($script:asked.Count) ($($script:asked[0].Buttons))"
    Test-That ($script:asked[0].Text -match 'already in Intune' -and $script:asked[0].Text -match 'Have - 1\.0') "inventory deploy: the question does not show the plan"

    # 'No': zusaetzlich Inhalt vorhandener Apps ersetzen - nur die eindeutigen.
    $null = & $run 'No'
    $deployedKeys = @($script:deployed | ForEach-Object { '{0} - {1}:{2}:{3}' -f $_.AppName, $_.AppVersion, $_.Mode, $_.UpdateAppId } | Sort-Object)
    $expected = @('ExistsNoPkg - 1.0:Update:id-ExistsNoPkg-1.0', 'Fresh - 1.0:New:', 'Have - 1.0:Update:id-Have-1.0', 'MultiNew - 2.0:New:', 'MultiOld - 1.0:Update:id-MultiOld-1.0')
    Test-That (($deployedKeys -join ',') -eq ($expected -join ',')) "inventory deploy (No): deployed [$($deployedKeys -join ', ')], expected [$($expected -join ', ')]"
    Test-That ((($script:deploySkipped -join '|') -match 'Dup - 1\.0') -and (($script:deploySkipped -join '|') -match 'Ghost - 1\.0')) "inventory deploy (No): duplicates or the empty entry were not skipped"
    # Ein Update braucht ein Paket: ExistsNoPkg hat keins und wird erst jetzt gebaut.
    Test-That ((($script:built | Sort-Object) -join ',') -eq 'ExistsNoPkg - 1.0,Fresh - 1.0') "inventory deploy (No): built [$($script:built -join ', ')]"

    # 'Cancel': nichts.
    $null = & $run 'Cancel'
    Test-That ($script:deployCalls -eq 0 -and $script:built.Count -eq 0) "inventory deploy (Cancel): built $($script:built.Count), deploy calls $($script:deployCalls) - expected nothing"

    # Tenant nicht lesbar: nichts, und es wird nicht einmal gefragt.
    $script:tenantReadable = $false
    $null = & $run 'Yes'
    Test-That ($script:deployCalls -eq 0 -and $script:built.Count -eq 0 -and $script:asked.Count -eq 0) "inventory deploy (tenant unreadable): built $($script:built.Count), deploys $($script:deployCalls), questions $($script:asked.Count) - expected nothing"
    $script:tenantReadable = $true

    # Nur Dubletten/Geister in der Auswahl: nichts zu tun, nichts gebaut, kein Deploy.
    $onlyBlocked = @($staleInventory | Where-Object { $_.AppName -in 'Dup', 'Ghost' })
    $script:built = @(); $script:deployCalls = 0; $script:asked = @()
    $null = Invoke-InventoryDeploy -Selection $onlyBlocked -Tenant $tenant -RootDir $rootDir -PacketRoot $packets -ToolVersion '0.0.1' -Ask $ask 6>$null
    Test-That ($script:deployCalls -eq 0 -and $script:built.Count -eq 0) "inventory deploy (only blocked rows): built $($script:built.Count), deploys $($script:deployCalls)"
    Test-That ($script:asked.Count -eq 1 -and $script:asked[0].Buttons -eq 'OK') "inventory deploy (only blocked rows): expected an OK-only message, got '$($script:asked[0].Buttons)'"

    # Alles neu: einfache Ja/Nein-Frage.
    $script:tenantApps = @()
    $script:built = @(); $script:deployCalls = 0; $script:asked = @(); $script:answer = 'Yes'
    $null = Invoke-InventoryDeploy -Selection @($staleInventory | Where-Object { $_.AppName -in 'Have', 'Fresh' }) -Tenant $tenant -RootDir $rootDir -PacketRoot $packets -ToolVersion '0.0.1' -Ask $ask 6>$null
    Test-That ($script:asked.Count -eq 1 -and $script:asked[0].Buttons -eq 'YesNo') "inventory deploy (all new): expected a YesNo question, got '$($script:asked[0].Buttons)'"
    Test-That ($script:deployCalls -eq 1 -and $script:deployed.Count -eq 2 -and (@($script:deployed | Where-Object { $_.Mode -ne 'New' }).Count -eq 0)) "inventory deploy (all new): deploys $($script:deployCalls), packages $($script:deployed.Count)"
}
finally {
    foreach ($root in @($packets, $fakes)) {
        foreach ($pkg in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            try { $null = Remove-PackageFolder -Path $pkg.FullName -PacketRoot $root } catch { $problems += "cleanup: $($_.Exception.Message)" }
        }
        Remove-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath (Join-Path $work 'record.txt') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $work) { $problems += "cleanup: $work is not empty" }
}

if ($problems.Count -gt 0) {
    foreach ($pr in $problems) { [Console]::WriteLine("FAIL: $pr") }
    exit 1
}
[Console]::WriteLine("Deploy plan: inventory matches name AND version, plan decides Create/Skip/Update, the decision reaches deploy.ps1 (-Mode), Intune is read fresh, only planned apps are built and deployed. PASS")
exit 0
