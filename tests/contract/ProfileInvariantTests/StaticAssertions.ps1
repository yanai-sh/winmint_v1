#Requires -Version 7.6

function Get-WinMintSetupCompleteText {
    # SetupComplete is now a thin orchestrator plus per-concern modules under
    # src\runtime\setup\SetupComplete\. Content assertions must span both.
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add((Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\SetupComplete.ps1') -Raw))
    $setupCatalogPath = Join-Path $root 'src\runtime\setup\Setup.Actions.ps1'
    if (Test-Path -LiteralPath $setupCatalogPath -PathType Leaf) {
        $parts.Add((Get-Content -LiteralPath $setupCatalogPath -Raw))
    }
    $moduleDir = Join-Path $root 'src\runtime\setup\SetupComplete'
    if (Test-Path -LiteralPath $moduleDir) {
        foreach ($module in @(Get-ChildItem -LiteralPath $moduleDir -Filter '*.ps1' -File | Sort-Object Name)) {
            $parts.Add((Get-Content -LiteralPath $module.FullName -Raw))
        }
    }
    return ($parts.ToArray() -join "`n")
}

function Get-WinMintFirstLogonText {
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($relativePath in @(
        'src\runtime\setup\FirstLogon.ps1',
        'src\runtime\setup\FirstLogon.Support.ps1',
        'src\runtime\setup\WinMint.Runtime.Common.ps1',
        'src\runtime\setup\WinMint.Diagnostics.ps1',
        'src\runtime\setup\FirstLogon.Context.ps1',
        'src\runtime\setup\FirstLogon.State.ps1',
        'src\runtime\setup\FirstLogon.Host.ps1',
        'src\runtime\setup\FirstLogon.Desktop.ps1',
        'src\runtime\setup\FirstLogon.Region.ps1',
        'src\runtime\setup\FirstLogon.Cleanup.ps1',
        'src\runtime\setup\WindowsTerminal.Profiles.ps1',
        'src\runtime\setup\FirstLogon.Transaction.ps1',
        'src\runtime\setup\FirstLogon.Runtime.ps1',
        'src\runtime\setup\WinMint.RuntimeState.ps1',
        'src\runtime\setup\WinMintSetupShell.Status.ps1',
        'src\runtime\setup\ProvisioningGuard.ps1'
    )) {
        $path = Join-Path $root $relativePath
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $parts.Add((Get-Content -LiteralPath $path -Raw))
        }
    }
    return ($parts.ToArray() -join "`n")
}

function Get-WinMintRepositoryText {
    param([Parameter(Mandatory)][string]$RelativePath)

    return (Get-Content -LiteralPath (Join-Path $root $RelativePath) -Raw)
}

function Assert-StaticUiFlowInvariants {
    $wizardRoot = Join-Path $root 'assets\runtime\setup\setup-shell'
    $wizardJsPath = Join-Path $wizardRoot 'wizard.js'
    $wizardHtmlPath = Join-Path $wizardRoot 'wizard.html'
    $wizardBridgePath = Join-Path $root 'apps\setup-shell-web\WizardBridge.cs'

    foreach ($path in @($wizardJsPath, $wizardHtmlPath, $wizardBridgePath)) {
        if (-not (Test-Path -LiteralPath $path)) {
            Add-SmokeFailure "Expected WebView2 wizard contract file to exist: $path"
            return
        }
    }

    $wizardJsText = Get-Content -LiteralPath $wizardJsPath -Raw
    $wizardHtmlText = Get-Content -LiteralPath $wizardHtmlPath -Raw
    if ($wizardHtmlText -notmatch 'wizard\.js') {
        Add-SmokeFailure 'Build wizard HTML must load wizard.js.'
    }
    if ($wizardJsText -notmatch 'function buildWizardSettings|buildWizardSettings\(') {
        Add-SmokeFailure 'Build wizard JS must expose buildWizardSettings().'
    }
    foreach ($requiredKey in @('ISOPath', 'KeepEdge', 'KeepGaming', 'KeepCopilot', 'Edition', 'InstallWindhawk', 'InstallNilesoft', 'Browsers', 'Wsl2Distros')) {
        if ($wizardJsText -notmatch [regex]::Escape($requiredKey)) {
            Add-SmokeFailure "Build wizard JS must emit '$requiredKey' in wizard settings."
        }
    }

    $removedUiTerms = @(
        ('WinMint-Legacy' + 'UI'),
        ('legacy' + '-wpf'),
        ('Wpf' + '.Ui')
    )
    foreach ($forbidden in $removedUiTerms) {
        if ($wizardJsText -match [regex]::Escape($forbidden) -or
            $wizardHtmlText -match [regex]::Escape($forbidden)) {
            Add-SmokeFailure "Build wizard assets must not reference removed legacy UI surface '$forbidden'."
        }
    }
    foreach ($forbidden in @('Tumbleweed', 'openSUSE')) {
        if ($wizardJsText -match [regex]::Escape($forbidden)) {
            Add-SmokeFailure "Build wizard JS must not contain '$forbidden'."
        }
    }
}

function Assert-HardwareBypassIsExplicit {
    $unattendPath = Join-Path $root 'config\autounattend.xml'
    $unattendText = Get-Content -LiteralPath $unattendPath -Raw
    foreach ($valueName in @('BypassTPMCheck', 'BypassSecureBootCheck', 'BypassRAMCheck')) {
        if ($unattendText -match [regex]::Escape($valueName)) {
            Add-SmokeFailure "autounattend.xml must not always set $valueName; hardware bypass must be injected only when selected."
        }
    }
}

function Assert-ElevationRequiredForAllRuns {
    $cliVerbPath = Join-Path $root 'src\runtime\image\Cli.ps1'
    $headlessPath = Join-Path $root 'src\runtime\image\Private\Headless.ps1'
    $enginePath = Join-Path $root 'src\runtime\image\Engine.ps1'
    $cliVerbText = Get-Content -LiteralPath $cliVerbPath -Raw
    $headlessText = Get-Content -LiteralPath $headlessPath -Raw
    $engineText = Get-Content -LiteralPath $enginePath -Raw

    # build/validate run through Invoke-WinMintProfileRun, which must gate on
    # elevation before doing any work (including -DryRun and -ValidateOnly).
    if ($headlessText -notmatch 'Resolve-WinMintCliElevation') {
        Add-SmokeFailure 'Invoke-WinMintProfileRun must call Resolve-WinMintCliElevation so build and validate always require admin.'
    }
    if ($cliVerbText -notmatch 'function Resolve-WinMintCliElevation') {
        Add-SmokeFailure 'Cli.ps1 must define Resolve-WinMintCliElevation as the single elevation gate.'
    }
    if ($headlessText -match 'Test-WinMintAdministrator\)\s+-and\s+-not\s+\$DryRun') {
        Add-SmokeFailure 'Elevation guard must not exempt -DryRun; UUP prep and ISO inspection still require admin.'
    }
    if ($headlessText -match 'Test-WinMintAdministrator\)\s+-and\s+-not\s+\$ValidateOnly') {
        Add-SmokeFailure 'Elevation guard must not exempt -ValidateOnly; validation still probes DISM/source/driver state.'
    }
    if ($engineText -match 'Test-WinMintAdministrator\)\s+-and\s+-not\s+\$DryRun') {
        Add-SmokeFailure 'Engine elevation guard must not exempt -DryRun.'
    }
    # The elevation error must name -DryRun so it is clear dry-run is not exempt.
    if ($cliVerbText -notmatch 'require an elevated shell, including -DryRun') {
        Add-SmokeFailure 'Elevation error should explain that even -DryRun requires an elevated shell.'
    }
}

function Assert-HardwareBypassUnattendGeneration {
    $template = Get-Content -LiteralPath (Join-Path $root 'config\autounattend.xml') -Raw
    $common = @{
        MountDir = 'C:\WinMint-Mount'
        IsoContents = 'C:\WinMint-Iso'
        AutounattendTemplate = $template
        ImageArch = 'amd64'
        TimeZone = 'UTC'
        TargetPCName = 'WinMint'
        TargetUser = 'dev'
        TargetPass = ''
        EditionName = 'Windows 11 Home Single Language'
        EditionMode = 'TargetLicense'
        AutoWipeDisk = $false
        AutoLogon = $false
        InputLocale = 'en-US'
        SystemLocale = 'en-US'
        UILanguage = 'en-US'
        UILanguageFallback = 'en-US'
        UserLocale = 'en-US'
        ScriptRoot = $root
        AgentProfile = $null
        SetupProfile = $null
        DryRun = $true
    }

    $plain = Install-Autounattend @common -HardwareBypass:$false
    if ([string]$plain.AutounattendXml -match 'BypassTPMCheck') {
        Add-SmokeFailure 'Expected generated default autounattend to omit hardware bypass commands.'
    }
    if ([string]$plain.AutounattendXml -match '<Key>\s*[A-Z0-9]{5}-') {
        Add-SmokeFailure 'Expected target-license autounattend to omit generic setup product keys.'
    }
    if ([string]$plain.AutounattendXml -match '<ProductKey') {
        Add-SmokeFailure 'Expected target-license autounattend to omit ProductKey entirely.'
    }

    $keyed = $common.Clone()
    $keyed.EditionName = 'Windows 11 Home'
    $keyed.EditionMode = 'Fixed'
    $keyed.ProductKey = 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7'
    $withKey = Install-Autounattend @keyed -HardwareBypass:$false
    if ([string]$withKey.AutounattendXml -notmatch '<Key>\s*YTMG3-N6DKC-DKB77-7M9GH-8HVX7\s*</Key>') {
        Add-SmokeFailure 'Expected -ProductKey to inject the generic key into UserData/ProductKey/Key.'
    }

    # RunSynchronousCommand <Path> has a ~259-char WCM limit; exceeding it makes
    # Windows Setup reject the answer file in the specialize pass (0x80220005),
    # which boot-loops the install with "restarted unexpectedly".
    $unattendXml = [xml]$plain.AutounattendXml
    $nsRsc = [System.Xml.XmlNamespaceManager]::new($unattendXml.NameTable)
    $nsRsc.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
    foreach ($pathNode in $unattendXml.SelectNodes('//u:RunSynchronousCommand/u:Path', $nsRsc)) {
        $pathText = [string]$pathNode.InnerText
        if ($pathText.Length -gt 259) {
            Add-SmokeFailure "RunSynchronousCommand <Path> is $($pathText.Length) chars (> 259 limit); Setup will reject specialize: '$($pathText.Substring(0, 50))...'"
        }
    }

    $singleImage = Install-Autounattend @common -HardwareBypass:$false -InstallImageCount 1
    if ([string]$singleImage.AutounattendXml -notmatch '<Key>\s*/IMAGE/INDEX\s*</Key>\s*<Value>\s*1\s*</Value>') {
        Add-SmokeFailure 'Expected single-image target-license media to pin InstallFrom /IMAGE/INDEX = 1.'
    }

    $bypass = Install-Autounattend @common -HardwareBypass:$true
    foreach ($valueName in @('BypassTPMCheck', 'BypassSecureBootCheck', 'BypassCPUCheck', 'BypassRAMCheck', 'BypassStorageCheck')) {
        if ([string]$bypass.AutounattendXml -notmatch [regex]::Escape($valueName)) {
            Add-SmokeFailure "Expected generated hardware-bypass autounattend to include $valueName."
        }
    }
}

function Assert-FixedEditionSelectionIsUnambiguous {
    $pipelineText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Private\Pipeline.ps1') -Raw
    if ($pipelineText -notmatch '\$imageMatches\.Count\s+-eq\s+1') {
        Add-SmokeFailure 'Fixed edition wildcard matching must only proceed when exactly one install image matches.'
    }
    if ($pipelineText -match 'ImageName\s+-like\s+"\*\$EditionName\*"\s*\}\s*\|\s*Select-Object\s+-First\s+1') {
        Add-SmokeFailure 'Fixed edition selection must not choose the first loose wildcard match; Home and Home Single Language must stay unambiguous.'
    }
}

function Assert-HyperVProfileIsProAndUnattended {
    Assert-HyperVFullProfileContract
    Assert-HyperVSmokeProfileContract
    Assert-HyperVProfilePassesTierValidator
}

function Assert-HyperVProfilePassesTierValidator {
    $validator = Join-Path $root 'tools\vm\Test-WinMintHyperVProfile.ps1'
    foreach ($pair in @(
        @{ Path = 'tests\profiles\hyper-v-install-arm64.json'; Tier = 'Full' },
        @{ Path = 'tests\profiles\hyper-v-smoke-arm64.json'; Tier = 'Smoke' },
        @{ Path = 'tests\profiles\hyper-v-sl7-smoke-arm64.json'; Tier = 'Smoke' }
    )) {
        $profilePath = Join-Path $root $pair.Path
        try {
            & pwsh -NoProfile -File $validator -ProfilePath $profilePath -Tier $pair.Tier | Out-Null
        }
        catch {
            Add-SmokeFailure "Test-WinMintHyperVProfile.ps1 -Tier $($pair.Tier) failed for $($pair.Path): $($_.Exception.Message)"
        }
    }
}

function Assert-GitHubApiReachabilityContract {
    $runtimeText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Private\Runtime.ps1') -Raw
    foreach ($expected in @(
        'function Get-WinMintGitHubApiHeaders',
        "'User-Agent' = 'WinMint/1.0'",
        'https://api.github.com/rate_limit',
        'Get-WinMintGitHubApiHeaders'
    )) {
        if ($runtimeText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "GitHub API reachability probe should include '$expected' in Runtime.ps1."
        }
    }
    if ($runtimeText -match 'Invoke-WebRequest.*https://api\.github\.com[^/]') {
        Add-SmokeFailure 'GitHub API reachability probe must use /rate_limit, not a bare api.github.com HEAD.'
    }
}

function Assert-HyperVFullProfileContract {
    $profilePath = Join-Path $root 'tests\profiles\hyper-v-install-arm64.json'
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        Add-SmokeFailure 'Hyper-V full acceptance profile must exist at tests\profiles\hyper-v-install-arm64.json.'
        return
    }
    $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json

    if ([string]$profile.profileName -ne 'Hyper-V Test') {
        Add-SmokeFailure 'Hyper-V full profile must use profileName Hyper-V Test for harness labeling.'
    }
    if (-not (Test-WinMintVmAcceptanceDiagnosticsPreset -Profile $profile -Tier 'Full')) {
        Add-SmokeFailure 'Hyper-V full profile must include the VM acceptance diagnostics preset.'
    }
    if ([string]$profile.target.edition -ne 'Windows 11 Pro') {
        Add-SmokeFailure 'Hyper-V full profile must target Windows 11 Pro.'
    }
    if ([string]$profile.target.productKey -ne 'VK7JG-NPHTM-C97JM-9MPGT-3V66T') {
        Add-SmokeFailure 'Hyper-V full profile must use the Pro generic key.'
    }
    if ([string]$profile.identity.accountMode -ne 'Local') {
        Add-SmokeFailure 'Hyper-V full profile must use a local account for unattended install.'
    }
    if (-not [bool]$profile.identity.autoLogon) {
        Add-SmokeFailure 'Hyper-V full profile must enable autoLogon.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$profile.identity.password)) {
        Add-SmokeFailure 'Hyper-V full profile must include a local-account password.'
    }
    if (-not [bool]$profile.identity.passwordSet -or -not [bool]$profile.identity.passwordIncluded) {
        Add-SmokeFailure 'Hyper-V full profile must mark the password as set and included.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$profile.identity.computerName)) {
        Add-SmokeFailure 'Hyper-V full profile must set an explicit computer name.'
    }
    if (@($profile.development.editors) -notcontains 'cursor' -or @($profile.development.editors) -notcontains 'neovim') {
        Add-SmokeFailure 'Hyper-V full profile must select Cursor and Neovim editors.'
    }
    foreach ($browser in @('zen-browser', 'helium')) {
        if (@($profile.development.browsers) -notcontains $browser) {
            Add-SmokeFailure "Hyper-V full profile must select browser '$browser'."
        }
    }
    foreach ($distro in @('Ubuntu', 'NixOS-WSL')) {
        if (@($profile.development.wsl.distros) -notcontains $distro) {
            Add-SmokeFailure "Hyper-V full profile must select WSL distro '$distro'."
        }
    }
    if (@($profile.development.wsl.distros).Count -ne 2) {
        Add-SmokeFailure 'Hyper-V full profile must select exactly Ubuntu and NixOS-WSL.'
    }
    if (@($profile.desktop.layers) -notcontains 'nilesoft') {
        Add-SmokeFailure 'Hyper-V full profile must select the Nilesoft shell layer.'
    }
    if ([string]$profile.features.launcher -ne 'None') {
        Add-SmokeFailure 'Hyper-V full profile must not select a launcher for the Nilesoft/browser/editor VM acceptance pass.'
    }
    if (-not [bool]$profile.features.liveInstallAudit) {
        Add-SmokeFailure 'Hyper-V full profile must enable features.liveInstallAudit for release-gate evidence.'
    }
}

function Assert-HyperVSmokeProfileContract {
    $profilePath = Join-Path $root 'tests\profiles\hyper-v-smoke-arm64.json'
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        Add-SmokeFailure 'Hyper-V smoke acceptance profile must exist at tests\profiles\hyper-v-smoke-arm64.json.'
        return
    }
    $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    if ([string]$profile.profileName -ne 'Hyper-V Smoke') {
        Add-SmokeFailure 'Hyper-V smoke profile must use profileName Hyper-V Smoke for harness labeling.'
    }
    if (-not (Test-WinMintVmAcceptanceDiagnosticsPreset -Profile $profile -Tier 'Smoke')) {
        Add-SmokeFailure 'Hyper-V smoke profile must include the VM acceptance diagnostics preset.'
    }
    if (@($profile.development.browsers).Count -gt 0) {
        Add-SmokeFailure 'Hyper-V smoke profile must not select browsers.'
    }
    if (@($profile.development.editors).Count -gt 0) {
        Add-SmokeFailure 'Hyper-V smoke profile must not select editors.'
    }
    if (@($profile.development.wsl.distros).Count -gt 0) {
        Add-SmokeFailure 'Hyper-V smoke profile must not select WSL distros.'
    }
    if (@($profile.desktop.layers).Count -ne 1 -or [string]@($profile.desktop.layers)[0] -ne 'standard') {
        Add-SmokeFailure 'Hyper-V smoke profile must use the standard desktop layer only.'
    }
    if ($profile.features.PSObject.Properties['liveInstallAudit'] -and [bool]$profile.features.liveInstallAudit) {
        Add-SmokeFailure 'Hyper-V smoke profile must not enable features.liveInstallAudit.'
    }

    Assert-HyperVSl7SmokeProfileContract
}

function Assert-HyperVSl7SmokeProfileContract {
    $profilePath = Join-Path $root 'tests\profiles\hyper-v-sl7-smoke-arm64.json'
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        Add-SmokeFailure 'Hyper-V SL7 smoke acceptance profile must exist at tests\profiles\hyper-v-sl7-smoke-arm64.json.'
        return
    }
    $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    if ([string]$profile.profileName -ne 'Hyper-V SL7 Smoke') {
        Add-SmokeFailure 'Hyper-V SL7 smoke profile must use profileName Hyper-V SL7 Smoke for harness labeling.'
    }
    if (-not (Test-WinMintVmAcceptanceDiagnosticsPreset -Profile $profile -Tier 'Smoke')) {
        Add-SmokeFailure 'Hyper-V SL7 smoke profile must include the VM acceptance diagnostics preset.'
    }
    if ([string]$profile.diagnostics.wslRuntimeValidation -ne 'skip') {
        Add-SmokeFailure 'Hyper-V SL7 smoke profile must mock WSL via diagnostics.wslRuntimeValidation=skip.'
    }
    if (@($profile.development.editors) -notcontains 'cursor' -or @($profile.development.browsers) -notcontains 'zen-browser') {
        Add-SmokeFailure 'Hyper-V SL7 smoke profile must select Cursor and zen-browser.'
    }
    if (@($profile.development.wsl.distros) -notcontains 'FedoraLinux' -or @($profile.development.wsl.distros).Count -ne 1) {
        Add-SmokeFailure 'Hyper-V SL7 smoke profile must select exactly FedoraLinux.'
    }
    if (-not [bool]$profile.keep.edge) {
        Add-SmokeFailure 'Hyper-V SL7 smoke profile must keep.edge=true (Edge stays installed; debloat-only).'
    }
    if (-not [bool]$profile.features.phoneLink) {
        Add-SmokeFailure 'Hyper-V SL7 smoke profile must enable features.phoneLink.'
    }
    if (-not [bool]$profile.features.liveInstallAudit) {
        Add-SmokeFailure 'Hyper-V SL7 smoke profile must enable features.liveInstallAudit.'
    }
    if ([string]$profile.regional.uiLanguage -ne 'en-US' -or [string]$profile.regional.userLocale -ne 'he-IL' -or [int]$profile.regional.homeLocationGeoId -ne 117) {
        Add-SmokeFailure 'Hyper-V SL7 smoke profile must use en-US UI with Israel locale/GeoID restore.'
    }
    if (@($profile.regional.secondaryInputLanguages) -notcontains 'he-IL') {
        Add-SmokeFailure 'Hyper-V SL7 smoke profile must add he-IL as a secondary input language.'
    }
}

function Test-WinMintSmokeStringArrayExactly {
    param(
        [Parameter(Mandatory)][object[]]$Actual,
        [Parameter(Mandatory)][string[]]$Expected
    )

    $actualValues = @($Actual | ForEach-Object { [string]$_ } | Sort-Object)
    $expectedValues = @($Expected | Sort-Object)
    if ($actualValues.Count -ne $expectedValues.Count) {
        return $false
    }
    for ($i = 0; $i -lt $expectedValues.Count; $i++) {
        if ($actualValues[$i] -ne $expectedValues[$i]) {
            return $false
        }
    }
    return $true
}

function Assert-TrackedHardwareBuildProfiles {
    $profilePath = Join-Path $root 'config\build-profiles\surface-laptop-7-microsoft-oobe.json'
    $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json

    if ([string]$profile.source.architecture -ne 'arm64') {
        Add-SmokeFailure 'Surface Laptop 7 profile must target arm64 source media.'
    }
    if ([string]$profile.target.editionMode -ne 'Fixed' -or [string]$profile.target.edition -ne 'Windows 11 Home') {
        Add-SmokeFailure 'Surface Laptop 7 profile must target fixed standard Windows 11 Home, not Home Single Language or target-license selection.'
    }
    if (-not (Test-WinMintSmokeStringArrayExactly -Actual @($profile.desktop.layers) -Expected @('yasb', 'thide'))) {
        Add-SmokeFailure 'Surface Laptop 7 profile desktop layers must be exactly yasb and thide.'
    }
    if ([string]$profile.features.launcher -ne 'None') {
        Add-SmokeFailure 'Surface Laptop 7 profile must not select a launcher.'
    }
    if ([string]$profile.drivers.source -ne 'SurfaceCatalog' -or [string]$profile.drivers.path -ne 'surface-laptop-7') {
        Add-SmokeFailure 'Surface Laptop 7 profile must use SurfaceCatalog with the surface-laptop-7 catalog id.'
    }

    $profilePath = Join-Path $root 'config\build-profiles\thinkpad-return-amd64.json'
    $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json

    if ([string]$profile.source.architecture -ne 'amd64') {
        Add-SmokeFailure 'ThinkPad return profile must target amd64 source media.'
    }
    if ([string]$profile.target.formFactor -ne 'Laptop') {
        Add-SmokeFailure 'ThinkPad return profile must use Laptop form factor.'
    }
    if ([string]$profile.target.diskMode -ne 'AutoWipeDisk0') {
        Add-SmokeFailure 'ThinkPad return profile must use AutoWipeDisk0 disk mode.'
    }
    if (-not [bool]$profile.keep.edge) {
        Add-SmokeFailure 'ThinkPad return profile must keep Edge.'
    }
    if (-not (Test-WinMintSmokeStringArrayExactly -Actual @($profile.desktop.layers) -Expected @('standard'))) {
        Add-SmokeFailure 'ThinkPad return profile desktop layers must be exactly standard.'
    }
    if (@($profile.development.browsers).Count -ne 0 -or @($profile.development.editors).Count -ne 0) {
        Add-SmokeFailure 'ThinkPad return profile must not select browsers or editors.'
    }
    if (-not (Test-WinMintSmokeStringArrayExactly -Actual @($profile.development.wsl.distros) -Expected @('Ubuntu'))) {
        Add-SmokeFailure 'ThinkPad return profile WSL distros must be exactly Ubuntu.'
    }
    if ([string]$profile.features.launcher -ne 'None') {
        Add-SmokeFailure 'ThinkPad return profile must not select a launcher.'
    }

    $profilePath = Join-Path $root 'config\build-profiles\alienware-aurora-amd64.json'
    $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json

    if ([string]$profile.source.architecture -ne 'amd64') {
        Add-SmokeFailure 'Alienware Aurora profile must target amd64 source media.'
    }
    if ([string]$profile.target.formFactor -ne 'Desktop') {
        Add-SmokeFailure 'Alienware Aurora profile must use Desktop form factor.'
    }
    if ([string]$profile.target.diskMode -ne 'Manual') {
        Add-SmokeFailure 'Alienware Aurora profile must use Manual disk mode.'
    }
    if (-not (Test-WinMintSmokeStringArrayExactly -Actual @($profile.development.browsers) -Expected @('helium', 'zen-browser'))) {
        Add-SmokeFailure 'Alienware Aurora profile browsers must be exactly helium and zen-browser.'
    }
    if (-not (Test-WinMintSmokeStringArrayExactly -Actual @($profile.development.editors) -Expected @('neovim', 'zed'))) {
        Add-SmokeFailure 'Alienware Aurora profile editors must be exactly neovim and zed.'
    }
    if (-not (Test-WinMintSmokeStringArrayExactly -Actual @($profile.desktop.layers) -Expected @('nilesoft'))) {
        Add-SmokeFailure 'Alienware Aurora profile desktop layers must be exactly nilesoft.'
    }
    if ([string]$profile.features.launcher -ne 'None') {
        Add-SmokeFailure 'Alienware Aurora profile must not select a launcher.'
    }
    if ([bool]$profile.keep.gaming) {
        Add-SmokeFailure 'Alienware Aurora profile must not keep gaming.'
    }
}

function Assert-MicrosoftOobeUnattendGeneration {
    $common = @{
        MountDir = 'C:\Mount'
        IsoContents = 'C:\ISO'
        AutounattendTemplate = (Get-Content -LiteralPath (Join-Path (Get-WinMintRepositoryRoot) 'config\autounattend.xml') -Raw)
        ImageArch = 'arm64'
        TimeZone = 'Israel Standard Time'
        TargetPCName = 'SL7'
        TargetUser = 'Yanai'
        AccountMode = 'MicrosoftOobe'
        TargetPass = ''
        EditionName = 'Windows 11 Home Single Language'
        EditionMode = 'TargetLicense'
        AutoWipeDisk = $true
        AutoLogon = $false
        HardwareBypass = $false
        InputLocale = 'en-US;he-IL'
        SystemLocale = 'he-IL'
        UILanguage = 'en-US'
        UILanguageFallback = 'en-US'
        UserLocale = 'he-IL'
        ScriptRoot = (Get-WinMintRepositoryRoot)
        AgentProfile = @{}
        SetupProfile = @{}
        DryRun = $true
    }

    $prepared = Install-Autounattend @common
    $xml = [string]$prepared.AutounattendXml
    foreach ($unexpected in @('BypassNRO', 'HideOnlineAccountScreens', 'HideLocalAccountScreen', '<LocalAccount')) {
        if ($xml -match [regex]::Escape($unexpected)) {
            Add-SmokeFailure "Expected Microsoft OOBE account mode to omit '$unexpected'."
        }
    }
    foreach ($expected in @('<ComputerName>SL7</ComputerName>', '<TimeZone>Israel Standard Time</TimeZone>', '<InputLocale>en-US;he-IL</InputLocale>', '<UserLocale>he-IL</UserLocale>')) {
        if ($xml -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Expected Microsoft OOBE unattend to retain '$expected'."
        }
    }
    if ($xml -notmatch '<HideWirelessSetupInOOBE>\s*false\s*</HideWirelessSetupInOOBE>') {
        Add-SmokeFailure 'Expected Microsoft OOBE account mode to keep the network page visible.'
    }
}

function Assert-LocalAccountUnattendGeneration {
    $common = @{
        MountDir = 'C:\Mount'
        IsoContents = 'C:\ISO'
        AutounattendTemplate = (Get-Content -LiteralPath (Join-Path (Get-WinMintRepositoryRoot) 'config\autounattend.xml') -Raw)
        ImageArch = 'amd64'
        TimeZone = 'UTC'
        TargetPCName = 'WinMint'
        TargetUser = 'dev'
        AccountMode = 'Local'
        TargetPass = ''
        EditionName = 'Windows 11 Home Single Language'
        EditionMode = 'TargetLicense'
        AutoWipeDisk = $false
        AutoLogon = $false
        HardwareBypass = $false
        InputLocale = 'en-US'
        SystemLocale = 'en-US'
        UILanguage = 'en-US'
        UILanguageFallback = 'en-US'
        UserLocale = 'en-US'
        ScriptRoot = (Get-WinMintRepositoryRoot)
        AgentProfile = @{}
        SetupProfile = @{}
        DryRun = $true
    }

    $prepared = Install-Autounattend @common
    $xml = [string]$prepared.AutounattendXml
    foreach ($expected in @('BypassNRO', 'HideOnlineAccountScreens', 'HideLocalAccountScreen', '<LocalAccount', '<Name>dev</Name>')) {
        if ($xml -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Expected local account mode to include '$expected'."
        }
    }
    if ($xml -notmatch '<HideWirelessSetupInOOBE>\s*true\s*</HideWirelessSetupInOOBE>') {
        Add-SmokeFailure 'Expected local account mode to hide the network page for unattended installs.'
    }
    if ($xml -notmatch '<settings pass="specialize">[\s\S]*<ComputerName>WinMint</ComputerName>') {
        Add-SmokeFailure 'Expected local unattended answer file to stamp ComputerName during specialize.'
    }
}

function Assert-SetupCompleteDoesNotDecryptBitLocker {
    $setupCompleteText = Get-WinMintSetupCompleteText
    if ($setupCompleteText -match '\bDisable-BitLocker\b') {
        Add-SmokeFailure 'SetupComplete.ps1 must not silently disable BitLocker; WinMint should only prevent surprise auto-encryption.'
    }
    if ($setupCompleteText -notmatch 'Leaving active BitLocker protection enabled') {
        Add-SmokeFailure 'SetupComplete.ps1 should log when active BitLocker protection is detected and preserved.'
    }
}

function Assert-ServiceabilityGuardrails {
    $packagesPath = Join-Path $root 'src\runtime\image\Private\Image\Packages.ps1'
    $packagesText = Get-Content -LiteralPath $packagesPath -Raw
    if ($packagesText -match '/ResetBase') {
        Add-SmokeFailure 'Default image cleanup must not use /ResetBase; it removes component rollback and is only acceptable in an explicit tiny-image mode.'
    }

    $unattendTemplate = Get-Content -LiteralPath (Join-Path $root 'config\autounattend.xml') -Raw
    if ($unattendTemplate -match '<Compact>\s*true\s*</Compact>' -or $unattendTemplate -match '\bCompactOS\b') {
        Add-SmokeFailure 'Default autounattend must not force Compact OS; WinMint is performance-first, not smallest-possible.'
    }

    $common = @{
        MountDir = 'C:\WinMint-Mount'
        IsoContents = 'C:\WinMint-Iso'
        AutounattendTemplate = $unattendTemplate
        ImageArch = 'amd64'
        TimeZone = 'UTC'
        TargetPCName = 'WinMint'
        TargetUser = 'dev'
        TargetPass = 'passw0rd!'
        EditionName = 'Windows 11 Home Single Language'
        EditionMode = 'Fixed'
        AutoWipeDisk = $false
        AutoLogon = $true
        HardwareBypass = $false
        InputLocale = 'en-US'
        SystemLocale = 'en-US'
        UILanguage = 'en-US'
        UILanguageFallback = 'en-US'
        UserLocale = 'en-US'
        ScriptRoot = $root
        AgentProfile = $null
        SetupProfile = $null
        DryRun = $true
    }
    $withAutoLogon = Install-Autounattend @common
    $xmlText = [string]$withAutoLogon.AutounattendXml
    # Auto sign-in must survive the install reboots until the FirstLogon agent completes,
    # but the staged image must NOT bake in an effectively-infinite autologon. Expect a
    # small, bounded LogonCount; FirstLogon makes autologon persistent at runtime and
    # disables it + wipes the password the moment the agent run succeeds.
    if ($xmlText -match '<LogonCount>\s*(\d+)\s*</LogonCount>') {
        $logonCount = [int]$Matches[1]
        if ($logonCount -lt 1 -or $logonCount -gt 20) {
            Add-SmokeFailure "Generated autounattend AutoLogon count should be a small bounded value (1-20); got $logonCount."
        }
    }
    else {
        Add-SmokeFailure 'Generated autounattend should set a bounded AutoLogon LogonCount.'
    }

    $autounattendDoc = [xml]$xmlText
    $autounattendNs = [System.Xml.XmlNamespaceManager]::new($autounattendDoc.NameTable)
    $autounattendNs.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
    $specializeShell = $autounattendDoc.SelectSingleNode(
        '//u:settings[@pass="specialize"]/u:component[@name="Microsoft-Windows-Shell-Setup"]',
        $autounattendNs)
    $oobeShell = $autounattendDoc.SelectSingleNode(
        '//u:settings[@pass="oobeSystem"]/u:component[@name="Microsoft-Windows-Shell-Setup"]',
        $autounattendNs)
    if ($specializeShell.SelectSingleNode('u:AutoLogon', $autounattendNs)) {
        Add-SmokeFailure 'AutoLogon must not live in the specialize Microsoft-Windows-Shell-Setup component.'
    }
    if (-not $oobeShell.SelectSingleNode('u:AutoLogon', $autounattendNs)) {
        Add-SmokeFailure 'AutoLogon must be appended to the oobeSystem Microsoft-Windows-Shell-Setup component.'
    }
    $autoLogonDomain = $oobeShell.SelectSingleNode('u:AutoLogon/u:Domain', $autounattendNs)
    if (-not $autoLogonDomain -or [string]$autoLogonDomain.InnerText -ne 'WinMint') {
        Add-SmokeFailure 'Generated autounattend AutoLogon should set Domain to the target computer name (WinMint).'
    }
    if (-not $oobeShell.SelectSingleNode('u:FirstLogonCommands', $autounattendNs)) {
        Add-SmokeFailure 'FirstLogonCommands must remain in the oobeSystem Microsoft-Windows-Shell-Setup component.'
    }
    if ($xmlText -match '<Key>\s*[A-Z0-9]{5}-') {
        Add-SmokeFailure 'Fixed-edition autounattend should select images with /IMAGE/NAME metadata, not generic setup keys.'
    }
    if ($xmlText -notmatch '<Key>\s*/IMAGE/NAME\s*</Key>' -or $xmlText -notmatch '<Value>\s*Windows 11 Home Single Language\s*</Value>') {
        Add-SmokeFailure 'Fixed Windows 11 Home Single Language autounattend should select the image with official ImageInstall metadata.'
    }
}

function Assert-ProtectedPlatformPackagesArePreserved {
    $allRemovalPrefixes = @(Get-WinMintEffectiveAppxRemovalPrefix -Settings @{
            RemoveAdvertising = $true
            RemoveGaming = $true
            RemoveCommunication = $true
            RemoveMicrosoftApps = $true
        })
    foreach ($protectedPrefix in @(
            'Microsoft.DesktopAppInstaller',
            'Microsoft.WindowsStore',
            'Microsoft.StorePurchaseApp',
            'Microsoft.SecHealthUI',
            'Microsoft.ScreenSketch',
            'Microsoft.Windows.Photos',
            'Microsoft.Paint',
            'Microsoft.Edge',
            'Microsoft.EdgeWebView',
            'Microsoft.WebView2'
        )) {
        if ($allRemovalPrefixes -contains $protectedPrefix) {
            Add-SmokeFailure "Default AppX removal must preserve platform/useful package '$protectedPrefix'."
        }
    }
}

function Assert-MinimalAppxRemovalCatalogCoversPolicy {
    $allRemovalPrefixes = @(Get-WinMintEffectiveAppxRemovalPrefix -Settings @{
            RemoveAdvertising = $true
            RemoveGaming = $true
            RemoveCommunication = $true
            RemoveMicrosoftApps = $true
        })
    foreach ($expected in @(
            'Microsoft.Copilot',
            'MicrosoftWindows.Client.WebExperience',
            'Microsoft.GamingApp',
            'Microsoft.XboxGameOverlay',
            'Microsoft.XboxGamingOverlay',
            'Microsoft.XboxIdentityProvider',
            'Microsoft.XboxSpeechToTextOverlay',
            'Microsoft.Xbox.TCUI',
            'MSTeams',
            'MicrosoftTeams',
            'Clipchamp.Clipchamp',
            'Microsoft.MicrosoftSolitaireCollection',
            'Microsoft.Windows.DevHome',
            'Microsoft.OutlookForWindows',
            'Microsoft.PowerAutomateDesktop',
            'Microsoft.WindowsCalculator',
            'MicrosoftCorporationII.QuickAssist',
            'Microsoft.WindowsSoundRecorder',
            'Microsoft.MicrosoftStickyNotes',
            'Microsoft.ZuneMusic',
            'Microsoft.ZuneVideo',
            'Microsoft.Office.OneNote',
            'Microsoft.RemoteDesktop',
            'Microsoft.RemoteDesktopPreview'
        )) {
        if ($allRemovalPrefixes -notcontains $expected) {
            Add-SmokeFailure "Expected Minimal AppX removal catalog to include '$expected'."
        }
    }
    foreach ($candidateOnly in @('McAfee', 'NortonLifeLock', 'ExpressVPN', 'Surfshark', 'Piriform.CCleaner')) {
        if ($allRemovalPrefixes -contains $candidateOnly) {
            Add-SmokeFailure "DMA-on default AppX removal must not include broad third-party/OEM candidate '$candidateOnly'."
        }
    }

    $catalogPath = Join-Path $root 'config\appx-removal.json'
    $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
    foreach ($groupName in @('consumerThirdParty', 'oemConsumer')) {
        if (@($catalog.candidateOnlyGroups) -notcontains $groupName) {
            Add-SmokeFailure "AppX removal catalog should keep '$groupName' as a candidate-only group for non-DMA/OEM drift."
        }
    }
    foreach ($candidateOnly in @('McAfee', 'NortonLifeLock', 'ExpressVPN', 'Surfshark', 'Piriform.CCleaner')) {
        if (@($catalog.groups.consumerThirdParty) -notcontains $candidateOnly -and @($catalog.groups.oemConsumer) -notcontains $candidateOnly) {
            Add-SmokeFailure "Candidate AppX catalog should retain non-default fallback prefix '$candidateOnly'."
        }
    }
}

function Assert-PhoneLinkAgentDefaults {
    $profile = New-WinMintInstallPlanAgentProfile -BuildConfig (New-WinMintBuildConfig -BuildProfile (New-SmokeBuildProfile))
    if ([bool]$profile.modules.phoneLink.enabled) {
        Add-SmokeFailure 'Phone Link must be disabled by default in the agent profile; users opt in explicitly.'
    }
    $optInSettings = New-SmokeBuildProfileSettings
    $optInSettings.PhoneLink = $true
    $optInProfile = New-WinMintInstallPlanAgentProfile -BuildConfig (New-WinMintBuildConfig -BuildProfile (New-WinMintBuildProfile -Settings $optInSettings))
    if (-not [bool]$optInProfile.modules.phoneLink.enabled) {
        Add-SmokeFailure 'Phone Link opt-in should enable the agent module.'
    }
    foreach ($setting in @('showInFileExplorer', 'crossDeviceCopyPaste', 'hideCrossDeviceHomeFolder')) {
        if ([bool]$profile.modules.phoneLink.$setting) {
            Add-SmokeFailure "Phone Link default profile should leave '$setting' disabled."
        }
        if (-not [bool]$optInProfile.modules.phoneLink.$setting) {
            Add-SmokeFailure "Phone Link opt-in profile should enable '$setting'."
        }
    }

    $agentPath = Join-Path $root 'src\runtime\firstlogon\Modules\PhoneLink.ps1'
    $agentText = Get-Content -LiteralPath $agentPath -Raw
    foreach ($expected in @('CrossDevice', 'Hidden', 'System', 'EnableClipboardHistory', 'CloudClipboardAutomaticUpload')) {
        if ($agentText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Phone Link agent module should contain '$expected'."
        }
    }
}

function Assert-PhoneLinkAppxRemovedByDefault {
    $defaultConfig = New-WinMintBuildConfig -BuildProfile (New-SmokeBuildProfile)
    foreach ($prefix in @('Microsoft.YourPhone', 'MicrosoftWindows.CrossDevice')) {
        if (@($defaultConfig.AppxPackages) -notcontains $prefix) {
            Add-SmokeFailure "Default release build should remove Phone Link AppX prefix '$prefix' when Phone Link is disabled."
        }
    }

    $optInSettings = New-SmokeBuildProfileSettings
    $optInSettings.PhoneLink = $true
    $optInConfig = New-WinMintBuildConfig -BuildProfile (New-WinMintBuildProfile -Settings $optInSettings)
    foreach ($prefix in @('Microsoft.YourPhone', 'MicrosoftWindows.CrossDevice')) {
        if (@($optInConfig.AppxPackages) -contains $prefix) {
            Add-SmokeFailure "Phone Link opt-in should keep AppX prefix '$prefix' off the removal list."
        }
    }
}

function Assert-ConsumerUtilityPackagesNeverInRemovalList {
    $allRemovalPrefixes = @(Get-WinMintEffectiveAppxRemovalPrefix -Settings @{
            RemoveAdvertising = $true
            RemoveGaming = $true
            RemoveCommunication = $true
            RemoveMicrosoftApps = $true
        })
    foreach ($mustKeep in @(
            'Microsoft.WindowsCamera',
            'Microsoft.WindowsAlarms',
            'Microsoft.WindowsNotepad',
            'Microsoft.DesktopAppInstaller',
            'Microsoft.WindowsStore',
            'Microsoft.StorePurchaseApp',
            'Microsoft.SecHealthUI',
            'Microsoft.ScreenSketch',
            'Microsoft.Windows.Photos',
            'Microsoft.Paint',
            'Microsoft.Edge',
            'Microsoft.EdgeWebView',
            'Microsoft.WebView2'
        )) {
        foreach ($prefix in $allRemovalPrefixes) {
            if ($mustKeep -like "*$prefix*") {
                Add-SmokeFailure "AppX removal prefix '$prefix' must not match protected utility '$mustKeep'."
            }
        }
    }
}

function Assert-HomeFirstDefaultsAndPolicySurface {
    $defaultProfile = New-WinMintBuildProfile -Settings (New-SmokeBuildProfileSettings)
    $defaultConfig = New-WinMintBuildConfig -BuildProfile $defaultProfile

    if ([int]$defaultProfile.schemaVersion -ne 4) {
        Add-SmokeFailure 'Default generated profile must use schemaVersion 4.'
    }
    if ($defaultProfile.regional.uiLanguage -ne 'en-US' -or
        $defaultProfile.regional.uiLanguageFallback -ne 'en-US' -or
        $defaultProfile.regional.systemLocale -ne 'en-US' -or
        $defaultProfile.regional.userLocale -ne 'en-US' -or
        $defaultProfile.regional.inputLocale -ne 'en-US' -or
        [int]$defaultProfile.regional.homeLocationGeoId -ne 244) {
        Add-SmokeFailure 'Default generated profile must use en-US regional defaults and GeoID 244.'
    }
    if (-not [bool]$defaultProfile.posture.setup.dmaInterop -or
        -not [bool]$defaultConfig.DmaInterop.Enabled -or
        $defaultConfig.SetupUserLocale -ne 'en-IE' -or
        [int]$defaultConfig.SetupHomeLocationGeoId -ne 68) {
        Add-SmokeFailure 'DMA interop must be default-on and use Ireland/en-IE/GeoID 68 for setup.'
    }
    if ([string]$defaultProfile.privacy.locationServices -ne 'enabled' -or @($defaultConfig.RegistryTweaks) -contains 'location-disabled-policy') {
        Add-SmokeFailure 'Location services must default on and must not select the location-disabled policy.'
    }

    $fixedSettings = New-SmokeBuildProfileSettings
    $fixedSettings.EditionMode = 'Fixed'
    $fixedSettings.Edition = ''
    $fixedProfile = New-WinMintBuildProfile -Settings $fixedSettings
    if ($fixedProfile.target.edition -ne 'Windows 11 Home') {
        Add-SmokeFailure 'Fixed-edition generated profiles must default to Windows 11 Home.'
    }

    foreach ($expectedDefaultTweak in @(
            'home-privacy-policy', 'advertising-id-disabled-policy', 'activity-history-disabled-policy', 'storage-sense-policy', 'modern-standby-policy', 'oobe-rehydration-policy', 'wpbt-policy',
            'driver-coinstaller-policy', 'device-metadata-policy',
            # Subtractive baseline: developer QoL is now baseline, and the default
            # build removes imposed Copilot/AI surfaces, Recall, and the Game Bar.
            'developer-mode', 'gamebar-policy', 'gaming-performance-policy', 'windows-ai-features-removal', 'windows-ai-recall-policy'
        )) {
        if (@($defaultConfig.RegistryTweaks) -notcontains $expectedDefaultTweak) {
            Add-SmokeFailure "Home-first defaults must select '$expectedDefaultTweak'."
        }
    }
    foreach ($unexpectedDefaultTweak in @('dual-boot-clock-policy', 'desktopui-policy', 'location-disabled-policy')) {
        if (@($defaultConfig.RegistryTweaks) -contains $unexpectedDefaultTweak) {
            Add-SmokeFailure "Default Minimal policy must not select '$unexpectedDefaultTweak'."
        }
    }
    foreach ($unexpectedFeature in @('Microsoft-Windows-Sandbox', 'Containers-DisposableClientVM', 'Windows-Defender-ApplicationGuard')) {
        if (@($defaultConfig.Features) -contains $unexpectedFeature) {
            Add-SmokeFailure "Windows 11 Home baseline must not select Pro-only feature '$unexpectedFeature'."
        }
    }

    $locationOffSettings = New-SmokeBuildProfileSettings
    $locationOffSettings.PrivLocation = $false
    $locationOffConfig = New-WinMintBuildConfig -BuildProfile (New-WinMintBuildProfile -Settings $locationOffSettings)
    if (@($locationOffConfig.RegistryTweaks) -notcontains 'location-disabled-policy') {
        Add-SmokeFailure '-NoLocationServices/profile privacy.locationServices=disabled must select location-disabled-policy.'
    }

    $dualBootSettings = New-SmokeBuildProfileSettings
    $dualBootSettings.DiskMode = 'DualBootReserved'
    $dualBootSettings.DualBootPreset = 'Balanced'
    $dualBootConfig = New-WinMintBuildConfig -BuildProfile (New-WinMintBuildProfile -Settings $dualBootSettings)
    if (@($dualBootConfig.RegistryTweaks) -notcontains 'dual-boot-clock-policy') {
        Add-SmokeFailure 'DualBootReserved builds must set RealTimeIsUniversal through dual-boot-clock-policy.'
    }

    $gamingSettings = New-SmokeBuildProfileSettings
    $gamingSettings.KeepGaming = $true
    $gamingConfig = New-WinMintBuildConfig -BuildProfile (New-WinMintBuildProfile -Settings $gamingSettings)
    if (@($gamingConfig.RegistryTweaks) -contains 'gamebar-policy') {
        Add-SmokeFailure '-KeepGaming must suppress the Game Bar removal policy.'
    }

    $desktopSettings = New-SmokeBuildProfileSettings
    $desktopSettings.DesktopUiDefault = $true
    $desktopConfig = New-WinMintBuildConfig -BuildProfile (New-WinMintBuildProfile -Settings $desktopSettings)
    if (@($desktopConfig.RegistryTweaks) -notcontains 'desktopui-policy') {
        Add-SmokeFailure 'DesktopUI profile must select desktopui-policy.'
    }

    $catalog = Get-Content -LiteralPath (Join-Path $root 'config\appx-removal.json') -Raw | ConvertFrom-Json
    foreach ($expectedPrefix in @('Microsoft.BingFinance', 'Microsoft.BingTranslator', 'Microsoft.Windows.AIHub', 'Microsoft.Windows.PeopleExperienceHost', 'Windows.CBSPreview')) {
        if (@($catalog.groups.coreMicrosoft) -notcontains $expectedPrefix) {
            Add-SmokeFailure "AppX core catalog must include '$expectedPrefix'."
        }
    }
    foreach ($expectedCandidate in @('SpotifyAB.SpotifyMusic', 'BytedancePte.Ltd.TikTok', '4DF9E0F8.Netflix', 'king.com', 'AD2F1837.HPAIExperienceCenter', 'DellInc.DellDigitalDelivery', 'E046963F.LenovoCompanion')) {
        if (@($catalog.groups.consumerThirdParty) -notcontains $expectedCandidate -and @($catalog.groups.oemConsumer) -notcontains $expectedCandidate) {
            Add-SmokeFailure "AppX candidate catalog must include '$expectedCandidate'."
        }
    }
    foreach ($mustPreserve in @('Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', 'Microsoft.SecHealthUI', 'Microsoft.WindowsCamera', 'Microsoft.WindowsAlarms', 'Microsoft.WindowsNotepad')) {
        if (@($catalog.preserve) -notcontains $mustPreserve) {
            Add-SmokeFailure "AppX preserve catalog must include '$mustPreserve'."
        }
    }
    foreach ($optInPrefix in @('Microsoft.YourPhone', 'MicrosoftWindows.CrossDevice')) {
        if (@($catalog.optInKeep.phoneLink) -notcontains $optInPrefix) {
            Add-SmokeFailure "AppX optInKeep.phoneLink catalog must include '$optInPrefix'."
        }
        if (@($catalog.preserve) -contains $optInPrefix) {
            Add-SmokeFailure "Phone Link AppX '$optInPrefix' belongs in optInKeep.phoneLink, not the unconditional preserve list."
        }
    }

    $stagingText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Private\Image\Staging.ps1') -Raw
    foreach ($expectedCapability in @('Browser.InternetExplorer', 'Microsoft.Windows.WordPad', 'MathRecognizer', 'Media.WindowsMediaPlayer', 'Microsoft.Wallpapers.Extended')) {
        if ($stagingText -notmatch [regex]::Escape($expectedCapability)) {
            Add-SmokeFailure "Capability removal should include '$expectedCapability'."
        }
    }
    foreach ($expectedExempt in @('Microsoft.Windows.PeopleExperienceHost', 'Windows.CBSPreview')) {
        if (@($catalog.systemExemptPrefixes) -notcontains $expectedExempt) {
            Add-SmokeFailure "AppX systemExemptPrefixes catalog must include '$expectedExempt'."
        }
    }
    $profileText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Private\Config\Profile.ps1') -Raw
    $cleanupText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\FirstLogon.Cleanup.ps1') -Raw
    foreach ($expected in @('Get-WinMintAppxSystemExemptPrefixes', 'systemExempt')) {
        if ($profileText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "AppX build resolver should filter '$expected' prefixes."
        }
    }
    foreach ($expected in @(
            'Get-WinMintFirstLogonAppxSystemExemptPrefixes',
            'Get-WinMintFirstLogonAppxSystemExemptResolution',
            'skippedSystemExempt',
            'systemExemptSource',
            'leftoverMatching',
            'setup-profile',
            'missing appxSystemExemptPrefixes',
            'missing-system-exempt-prefixes'
        )) {
        if ($cleanupText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "FirstLogon live AppX cleanup should cover '$expected'."
        }
    }
    if ($cleanupText -match 'ponytail: fallback ceiling') {
        Add-SmokeFailure 'FirstLogon live AppX cleanup must not keep a hardcoded systemExempt fallback that drifts from the catalog.'
    }
    if ($cleanupText -notmatch "Source -eq 'missing'") {
        Add-SmokeFailure 'FirstLogon live AppX cleanup must fail closed when system exempt prefixes are missing from the setup profile.'
    }
    $desktopText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\FirstLogon.Desktop.ps1') -Raw
    if ($desktopText -notmatch 'Invoke-WinMintProvisioningDismissStartMenu') {
        Add-SmokeFailure 'FirstLogon desktop reload should dismiss Start via Invoke-WinMintProvisioningDismissStartMenu.'
    }
    if ($desktopText -match 'Invoke-WinMintSetupShellDismissStartMenu') {
        Add-SmokeFailure 'FirstLogon desktop reload must not call missing Invoke-WinMintSetupShellDismissStartMenu.'
    }
    $runtimeStateText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\WinMint.RuntimeState.ps1') -Raw
    foreach ($expected in @('Get-WinMintAgentStateNodeValue', 'Get-WinMintAgentStateStepEntries')) {
        if ($runtimeStateText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Runtime state projection should use '$expected' for hashtable-safe agent reads."
        }
    }
    $driftScript = Join-Path $root 'tools\vm\Test-WinMintGuestRemovalDrift.ps1'
    if (-not (Test-Path -LiteralPath $driftScript)) {
        Add-SmokeFailure 'Expected tools\vm\Test-WinMintGuestRemovalDrift.ps1 to exist.'
    }
    $acceptanceText = Get-Content -LiteralPath (Join-Path $root 'tools\vm\Invoke-WinMintVmAcceptance.ps1') -Raw
    if ($acceptanceText -notmatch 'Test-WinMintGuestRemovalDrift') {
        Add-SmokeFailure 'Invoke-WinMintVmAcceptance.ps1 must invoke Test-WinMintGuestRemovalDrift.ps1.'
    }
    foreach ($forbiddenCapability in @('Language.OCR', 'Language.Handwriting', 'Language.Speech', 'Language.TextToSpeech')) {
        if ($stagingText -match [regex]::Escape($forbiddenCapability)) {
            Add-SmokeFailure "Default capability removal must not include language feature '$forbiddenCapability'."
        }
    }
}

function Assert-LiveInstallAuditIsNonDestructive {
    $auditPath = Join-Path $root 'tools\audit\Audit-LiveInstall.ps1'
    if (-not (Test-Path -LiteralPath $auditPath)) {
        Add-SmokeFailure 'Expected tools\audit\Audit-LiveInstall.ps1 to exist.'
        return
    }
    $auditText = Get-Content -LiteralPath $auditPath -Raw
    foreach ($forbidden in @('Remove-AppxPackage', 'Remove-AppxProvisionedPackage', 'Remove-Item', 'reg.exe delete', 'Start-Process')) {
        if ($auditText -match [regex]::Escape($forbidden)) {
            Add-SmokeFailure "Audit-LiveInstall.ps1 must be non-destructive and must not contain '$forbidden'."
        }
    }
}

function Assert-LiveInstallAuditCoversPlatformGuardrails {
    $auditText = Get-Content -LiteralPath (Join-Path $root 'tools\audit\Audit-LiveInstall.ps1') -Raw
    foreach ($expected in @(
            'Microsoft.WindowsStore',
            'Microsoft.DesktopAppInstaller',
            'winget.exe',
            'EdgeWebView',
            'WinDefend',
            'mpssvc',
            'wuauserv',
            'BITS',
            'WaaSMedicSvc',
            'Tcpip6',
            'hns',
            'tzautoupdate',
            'dmaInterop',
            'setupHomeLocationGeoId',
            'restoreTimeZoneId',
            'restoreHomeLocationGeoId'
        )) {
        if ($auditText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Audit-LiveInstall.ps1 should probe platform guardrail '$expected'."
        }
    }
}

function Assert-LiveInstallAuditUsesSetupProfilePrefixes {
    $auditText = Get-Content -LiteralPath (Join-Path $root 'tools\audit\Audit-LiveInstall.ps1') -Raw
    foreach ($expected in @('WinMintSetupProfile.json', 'appxRemovalPrefixes')) {
        if ($auditText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Audit-LiveInstall.ps1 should use setup profile value '$expected'."
        }
    }
}

function Assert-OfflineFontAllowlist {
    $assetsText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Private\Image\Assets.ps1') -Raw
    if ($assetsText -notmatch [regex]::Escape("Filter '*CascadiaCodeNF*'")) {
        Add-SmokeFailure 'Install-OfflineFont should allowlist Cascadia Code NF only.'
    }
    if ($assetsText -match 'Monaspace') {
        Add-SmokeFailure 'Assets.ps1 should not sync or reference Monaspace Nerd Fonts.'
    }
    $engineText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Engine.ps1') -Raw
    if ($engineText -match 'Monaspace') {
        Add-SmokeFailure 'Engine offline payload cache checks should not reference Monaspace.'
    }
}

function Assert-LiveInstallAuditIsStaged {
    $setupPayloadText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Private\Image\SetupPayloadStaging.ps1') -Raw
    if ($setupPayloadText -notmatch [regex]::Escape('if ($LiveInstallAudit)')) {
        Add-SmokeFailure 'Setup payload staging should gate Audit-LiveInstall.ps1 behind LiveInstallAudit.'
    }
    if ($setupPayloadText -notmatch [regex]::Escape('Copy-WinMintLiveAuditPayload')) {
        Add-SmokeFailure 'Setup payload staging should stage Audit-LiveInstall.ps1 through Copy-WinMintLiveAuditPayload when opted in.'
    }
    if ($setupPayloadText -match [regex]::Escape("Join-Path `$destScripts 'WinMintSetupPlan.json'")) {
        Add-SmokeFailure 'Setup payload staging must not write WinMintSetupPlan.json onto the guest image.'
    }
    if ($setupPayloadText -notmatch [regex]::Escape("Join-Path `$ScriptRoot 'src\runtime\setup'")) {
        Add-SmokeFailure 'Setup payload staging must stage setup scripts from src\runtime\setup.'
    }
    if ($setupPayloadText -match [regex]::Escape("Join-Path `$ScriptRoot 'scripts'")) {
        Add-SmokeFailure 'Setup payload staging must not rely on the removed top-level scripts directory.'
    }
    foreach ($expected in @('SetupComplete.cmd', 'SetupComplete.ps1', 'Specialize.ps1', 'DefaultUser.ps1', 'FirstLogon.PreLock.ps1', 'WinMintLogonShell.cmd', 'WinMintLogonShell.ps1', 'FirstLogon.ps1', 'FirstLogon.Support.ps1', 'WinMint.Runtime.Common.ps1', 'WinMint.RuntimeState.ps1', 'FirstLogon.Context.ps1', 'FirstLogon.State.ps1', 'FirstLogon.Host.ps1', 'FirstLogon.Desktop.ps1', 'FirstLogon.Region.ps1', 'FirstLogon.Cleanup.ps1', 'WindowsTerminal.Profiles.ps1', 'FirstLogon.Transaction.ps1', 'FirstLogon.Runtime.ps1', 'WinMintSetupShell.Status.ps1', 'WinMint.Diagnostics.ps1', 'ProvisioningGuard.ps1')) {
        if ($setupPayloadText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Setup payload staging should stage '$expected'."
        }
    }
}

function Assert-DmaRestoreRunsBeforeOptionalFirstLogonWork {
    $firstLogonText = Get-WinMintFirstLogonText
    $regionText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\FirstLogon.Region.ps1') -Raw
    foreach ($expected in @(
            'Restore-WinMintDmaRegionalDefaults',
            'FirstLogon_RegionalRestore.json',
            'Copy-UserInternationalSettingsToSystem',
            'restoreLocationServices',
            'Get-WinMintFirstLogonLocationPostureSnapshot',
            'Test-WinMintFirstLogonLocationRestoreCompliant',
            'locationPosture',
            'New-WinMintFirstLogonTransactionPlan',
            'FirstLogon.Transaction.ps1'
        )) {
        if ($firstLogonText -notmatch [regex]::Escape($expected) -and $regionText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "FirstLogon DMA restore should contain '$expected'."
        }
    }
    foreach ($expected in @('machineConsent', 'userConsent', 'lfsvc', 'DisableLocation')) {
        if ($regionText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "FirstLogon DMA location compliance should reference '$expected'."
        }
    }
    foreach ($expected in @('Get-WinUserLanguageList', 'primaryLanguageTag', 'uiLanguageOverride', 'Get-WinMintFirstLogonUserLocaleName', 'LocaleName', 'New-WinUserLanguageList', 'Wait-WinMintFirstLogonUserCulture')) {
        if ($regionText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "FirstLogon DMA regional restore should verify configured language via '$expected'."
        }
    }
    if ($regionText -match "Current culture '\`$observedCultureText' does not match") {
        Add-SmokeFailure 'FirstLogon DMA regional restore must not gate compliance on immediate Get-Culture alone.'
    }
    if ($regionText -notmatch 'LocaleName') {
        Add-SmokeFailure 'FirstLogon DMA regional restore must gate culture compliance on HKCU LocaleName.'
    }
    $firstLogonRuntimeText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\FirstLogon.Runtime.ps1') -Raw
    if ($firstLogonRuntimeText -match 'continuing with personalization and agent') {
        Add-SmokeFailure 'DMA regional restore non-compliance must fail FirstLogon hard, not soft-continue.'
    }
    foreach ($expected in @('DmaRestoreFailed', 'hard requirement', 'Skipping WinMintAgent because DMA regional restore failed')) {
        if ($firstLogonRuntimeText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "FirstLogon DMA hard-fail path should contain '$expected'."
        }
    }
    if ($firstLogonText -match [regex]::Escape('Get-WinMintFirstLogonNestedProfileValue -Profile')) {
        Add-SmokeFailure 'FirstLogon DMA restore must not call Get-WinMintFirstLogonNestedProfileValue with the old -Profile parameter.'
    }
    $restoreIndex = $firstLogonRuntimeText.IndexOf('Restore-WinMintDmaRegionalDefaults')
    $oneDriveIndex = $firstLogonRuntimeText.IndexOf('Invoke-WinMintFirstLogonOneDriveRemoval')
    $agentIndex = $firstLogonRuntimeText.IndexOf('Invoke-WinMintFirstLogonAgentLaunch')
    if ($restoreIndex -lt 0 -or $oneDriveIndex -lt 0 -or $agentIndex -lt 0 -or -not ($restoreIndex -lt $oneDriveIndex -and $restoreIndex -lt $agentIndex)) {
        Add-SmokeFailure 'FirstLogon must restore DMA regional defaults before OneDrive cleanup and agent launch.'
    }
}

function Assert-FirstLogonDefaultsToSetupShell {
    $firstLogonText = Get-WinMintFirstLogonText
    $firstLogonRuntimeText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\FirstLogon.Runtime.ps1') -Raw
    $defaultUserText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\DefaultUser.ps1') -Raw
    $autounattendText = Get-Content -LiteralPath (Join-Path $root 'config\autounattend.xml') -Raw
    foreach ($expected in @(
        'return ''Normal''',
        'WINMINT_FIRSTLOGON_DEBUG',
        'Start-WinMintProvisioningHost',
        'Enable-WinMintProvisioningGuard',
        'engage-provisioning-lock',
        'release-provisioning-lock',
        'WinMintSetupShell',
        'Set-WinMintSetupShellControl',
        'Update-WinMintSetupShellStatus',
        'Write-WinMintRuntimeState',
        'Get-WinMintProvisioningProjection',
        'fullscreen provisioning shell',
        'Resolve-WinMintWindowsTerminalHost',
        'Wait-WinMintWindowsTerminalHost',
        'Start-WinMintFirstLogonAgentInTerminal',
        'WindowStyle Hidden',
        'Set-WinMintFirstLogonWindowsTerminalDefault',
        'DelegationConsole',
        'DelegationTerminal',
        '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}',
        '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'
    )) {
        if ($firstLogonText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "FirstLogon setup shell wiring should contain '$expected'."
        }
    }
    foreach ($expected in @('Clear-WinMintFirstLogonWindowsTerminalDelegation', 'Set-WinMintFirstLogonWindowsTerminalDefault', 'finalize-desktop-under-lock')) {
        if ($firstLogonRuntimeText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "FirstLogon should defer Windows Terminal delegation to finalize with '$expected'."
        }
    }
    if ($defaultUserText -match [regex]::Escape('Set-DefaultUserWindowsTerminalDelegation')) {
        Add-SmokeFailure 'Default user setup must not set Windows Terminal delegation before FirstLogon completes.'
    }
    if ($autounattendText -notmatch 'pwsh\.exe.*FirstLogon\.ps1' -or $autounattendText -notmatch 'WindowStyle Hidden') {
        Add-SmokeFailure 'Autounattend FirstLogonCommands should launch FirstLogon.ps1 via hidden pwsh.exe.'
    }
    if ($autounattendText -notmatch 'FirstLogon\.PreLock\.ps1') {
        Add-SmokeFailure 'Autounattend FirstLogonCommands should run FirstLogon.PreLock.ps1 before FirstLogon.ps1.'
    }
    if ($defaultUserText -notmatch 'WinMintLogonShell\.cmd') {
        Add-SmokeFailure 'DefaultUser must stamp Winlogon Shell to WinMintLogonShell.cmd so splash is first session UI.'
    }
    if ($firstLogonText -match [regex]::Escape('return ''Debug''') -and $firstLogonText -match [regex]::Escape('fullscreen provisioning shell')) {
        return
    }
    if ($firstLogonText -notmatch [regex]::Escape('return ''Normal''')) {
        Add-SmokeFailure 'FirstLogon default agent mode should resolve to Normal (fullscreen provisioning shell).'
    }
}

function Assert-SetupShellNativeDesign {
    $tokensPath = Join-Path $root 'assets\runtime\setup\setup-shell\tokens.json'
    $statusSchemaPath = Join-Path $root 'schemas\winmint.setupshellstatus.schema.json'
    $controlSchemaPath = Join-Path $root 'schemas\winmint.setupshellcontrol.schema.json'
    foreach ($path in @($tokensPath, $statusSchemaPath, $controlSchemaPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Add-SmokeFailure "Native setup shell asset is missing: $path"
        }
    }

    $tokens = Get-Content -LiteralPath $tokensPath -Raw | ConvertFrom-Json
    foreach ($tokenName in @('canvas', 'ink', 'dim', 'accent', 'warn', 'fail')) {
        if (-not $tokens.PSObject.Properties[$tokenName]) {
            Add-SmokeFailure "Setup shell tokens.json should define '$tokenName'."
        }
    }
    if ([string]$tokens.canvas -ne '#11161d') {
        Add-SmokeFailure 'Setup shell tokens.json canvas should be #11161d.'
    }

    $setupShellRuntimeText = @(
        (Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\WinMintSetupShell.Status.ps1') -Raw)
        (Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\ProvisioningGuard.ps1') -Raw)
        (Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\FirstLogon.Host.ps1') -Raw)
        (Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\FirstLogon.Runtime.ps1') -Raw)
    ) -join "`n"
    foreach ($forbidden in @('Start-WinMintSetupShellFallbackHost', 'Start-WinMintSetupShell.ps1', 'WinMintWebView2.ps1', 'WebView2Loader.dll', 'WinMintSetupShell.Native.exe')) {
        if ($setupShellRuntimeText -match [regex]::Escape($forbidden)) {
            Add-SmokeFailure "Setup shell runtime must not reference removed surface '$forbidden'."
        }
    }
    foreach ($expected in @('Resolve-WinMintProvisioningHostExePath', 'presenter=native')) {
        if ($setupShellRuntimeText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Setup shell runtime should use native presenter via '$expected'."
        }
    }
    if (Test-Path -LiteralPath (Join-Path $root 'src\runtime\setup\Start-WinMintSetupShell.ps1')) {
        Add-SmokeFailure 'Legacy Start-WinMintSetupShell.ps1 host must be removed.'
    }

    $stagingText = Get-WinMintRepositoryText -RelativePath 'src\runtime\image\Private\Image\SetupPayloadStaging.ps1'
    foreach ($expected in @('WinMintSetupShell.Native.exe', 'WinMintSetupShell.exe', 'tokens.json', 'winmint_hero_ui.png', 'winmint_hero.png', 'Resolve-WinMintSetupShellPublishFolder')) {
        if ($stagingText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Setup payload staging should stage setup shell asset '$expected'."
        }
    }

    $statusPath = Join-Path $root 'src\runtime\setup\WinMintSetupShell.Status.ps1'
    $guardPath = Join-Path $root 'src\runtime\setup\ProvisioningGuard.ps1'
    $statusText = (Get-Content -LiteralPath $statusPath -Raw) + (Get-Content -LiteralPath $guardPath -Raw)
    foreach ($expected in @(
        'Get-WinMintSetupShellStageLabel',
        'Get-WinMintSetupShellDevlogTask',
        'Get-WinMintSetupShellRuntimeTaskLabel',
        'Get-WinMintProvisioningProjection',
        'Resolve-WinMintSetupShellCurrentStageId',
        'Get-WinMintSetupShellHeadlineLabels',
        'Get-WinMintSetupShellPipelineProgress',
        'Get-WinMintSetupShellLiveTaskHint',
        'Format-WinMintSetupShellSplashDetail',
        'progressPct',
        'progressMode',
        'stageId',
        'detailLabel',
        'taskLabel',
        'preAgentStage',
        'Start-WinMintSetupShellStatusPump',
        'Invoke-WinMintSetupShellStatusPumpTick',
        'Resolve-WinMintProvisioningHostExePath'
    )) {
        if ($statusText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Setup shell status writer should expose native shell integration via '$expected'."
        }
    }
    foreach ($removed in @('headline', 'subline', 'currentStepLabel', 'heroPath', 'logoPath')) {
        if ($statusText -match "$removed\s*=") {
            Add-SmokeFailure "Setup shell status writer must not emit legacy field '$removed'."
        }
    }
    if ($statusText -match 'Register-ObjectEvent') {
        Add-SmokeFailure 'Setup shell status pump must not use Register-ObjectEvent; FirstLogon blocks on agent -Wait and never drains timer events.'
    }
    if ($statusText -match "'finishing'\s*\{\s*return\s+'Region restore") {
        Add-SmokeFailure 'Get-WinMintSetupShellDevlogTask finishing phase must not map to Region restore (finalize-desktop-under-lock applies desktop settings).'
    }

    $transactionText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\FirstLogon.Transaction.ps1') -Raw
    if ($transactionText -notmatch 'Invoke-WinMintSetupShellStatusPumpTick') {
        Add-SmokeFailure 'SetupShell agent launch must pump setup shell status while waiting for WinMintAgent.'
    }
    if ($transactionText -match "SetupShell'[\s\S]{0,400}-Wait") {
        Add-SmokeFailure 'SetupShell agent launch must not block on Start-Process -Wait without pumping setup shell status.'
    }

    $fixtureDir = Join-Path $root 'tests\fixtures\setup-shell'
    foreach ($fixture in @(Get-ChildItem -LiteralPath $fixtureDir -Filter 'status-*.json' -ErrorAction SilentlyContinue)) {
        $payload = Get-Content -LiteralPath $fixture.FullName -Raw | ConvertFrom-Json
        foreach ($required in @('phase', 'stageId', 'taskLabel', 'detailLabel', 'itemIndex', 'itemTotal', 'progressPct', 'progressMode', 'banner', 'bannerKind', 'logDir', 'updatedAt')) {
            if (-not $payload.PSObject.Properties[$required]) {
                Add-SmokeFailure "Fixture $($fixture.Name) is missing required setup shell status field '$required'."
            }
        }
        if ($payload.PSObject.Properties['steps']) {
            Add-SmokeFailure "Fixture $($fixture.Name) must not include removed steps[] field."
        }
    }

    foreach ($archFolder in @('x64', 'arm64')) {
        $nativeExe = Join-Path $root "assets\runtime\setup\setup-shell\bin\$archFolder\WinMintSetupShell.Native.exe"
        if (-not (Test-Path -LiteralPath $nativeExe -PathType Leaf)) {
            Add-SmokeFailure "Published native setup shell executable is missing: $nativeExe"
            continue
        }
        $nativeSizeMb = (Get-Item -LiteralPath $nativeExe).Length / 1MB
        if ($nativeSizeMb -gt 10) {
            Add-SmokeFailure "WinMintSetupShell.Native.exe for $archFolder is $([Math]::Round($nativeSizeMb, 2)) MB; gate is 10 MB."
        }

        $wizardExe = Join-Path $root "assets\runtime\setup\setup-shell\bin\$archFolder\WinMintSetupShell.exe"
        if (-not (Test-Path -LiteralPath $wizardExe -PathType Leaf)) {
            Add-SmokeFailure "Published WebView2 wizard host is missing: $wizardExe"
        }
    }
    $webProgramText = Get-WinMintRepositoryText -RelativePath 'apps\setup-shell-web\Program.cs'
    if ($webProgramText -notmatch 'options\.Wizard') {
        Add-SmokeFailure 'WebView2 setup shell host should support wizard mode via options.Wizard.'
    }

    $nativeHostText = Get-WinMintRepositoryText -RelativePath 'apps\setup-shell\Program.cs'
    if ($nativeHostText -notmatch 'host=native') {
        Add-SmokeFailure 'Native setup shell host should log host=native.'
    }

    $setupShellHostText = @(
        (Get-Content -LiteralPath (Join-Path $root 'apps\setup-shell\SetupShellHost.cs') -Raw)
        (Get-Content -LiteralPath (Join-Path $root 'apps\setup-shell\AppOptions.cs') -Raw)
        (Get-Content -LiteralPath (Join-Path $root 'apps\setup-shell\GdiFallbackPainter.cs') -Raw)
    ) -join "`n"
    if ($setupShellHostText -notmatch 'winmint-setup-shell-guest\.png' -or $setupShellHostText -notmatch 'TryWriteGuestCapture') {
        Add-SmokeFailure 'Setup shell host should write winmint-setup-shell-guest.png for acceptance evidence.'
    }
    if ($setupShellHostText -notmatch 'presenter=gdi-fallback' -or $setupShellHostText -notmatch 'GdiFallbackPainter') {
        Add-SmokeFailure 'Setup shell host should expose GDI fallback presenter path when Direct2D fails.'
    }
    if ($setupShellHostText -notmatch 'TryReadRuntimeState' -or $setupShellHostText -notmatch 'runtime-state\.json') {
        Add-SmokeFailure 'Setup shell host should prefer runtime-state.json with fallback to legacy control/status files.'
    }

    $vmFingerprintText = Get-WinMintRepositoryText -RelativePath 'tools\vm\lib\VmFingerprint.ps1'
    if ($vmFingerprintText -notmatch 'apps\\setup-shell') {
        Add-SmokeFailure 'VM image fingerprint should hash native setup shell host sources so host changes invalidate cached ISOs.'
    }
    if ($vmFingerprintText -notmatch 'setupShellSource=') {
        Add-SmokeFailure 'VM image fingerprint should include setupShellSource from apps\setup-shell.'
    }

    $setupShellTest = Join-Path $root 'tests\setup-shell\Test-WinMintSetupShell.ps1'
    if (-not (Test-Path -LiteralPath $setupShellTest -PathType Leaf)) {
        Add-SmokeFailure 'Expected tests\setup-shell\Test-WinMintSetupShell.ps1 integration test.'
    }
    foreach ($relativePath in @(
        'tools\dev\Show-WinMintSplash.ps1'
        'tests\setup-shell\SetupShell.TestSupport.ps1'
        'tests\integration\Test-WinMintProvisioningLockPreview.ps1'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $relativePath) -PathType Leaf)) {
            Add-SmokeFailure "Expected setup shell script: $relativePath"
        }
    }
    $splashText = Get-WinMintRepositoryText -RelativePath 'tools\dev\Show-WinMintSplash.ps1'
    if ($splashText -notmatch '\-Native' -or $splashText -notmatch '\-Wizard') {
        Add-SmokeFailure 'Show-WinMintSplash.ps1 should support -Native and -Wizard preview.'
    }
    $testSupportText = Get-WinMintRepositoryText -RelativePath 'tests\setup-shell\SetupShell.TestSupport.ps1'
    foreach ($expected in @('Get-WinMintSetupShellExePath', 'New-WinMintSetupShellTestWorkspace', 'Start-WinMintSetupShellTestHost')) {
        if ($testSupportText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "SetupShell.TestSupport.ps1 should expose '$expected'."
        }
    }
    $lockPreviewText = Get-WinMintRepositoryText -RelativePath 'tests\integration\Test-WinMintProvisioningLockPreview.ps1'
    if ($lockPreviewText -notmatch 'Enable-WinMintProvisioningGuard') {
        Add-SmokeFailure 'Test-WinMintProvisioningLockPreview.ps1 should exercise provisioning lock engage/release.'
    }
}

function Assert-WinMintVmManagedAcceptanceContract {
    foreach ($relativePath in @(
        'tools\vm\WinMint-VmConsole.ps1',
        'tools\vm\lib\VmLog.ps1',
        'tools\vm\lib\VmObserve.ps1',
        'tools\vm\lib\VmGuest.ps1',
        'tools\vm\lib\VmFingerprint.ps1',
        'tools\vm\lib\VmEvidence.ps1',
        'tools\vm\Start-WinMintVmAcceptanceManaged.ps1',
        'tools\vm\Get-WinMintVmAcceptanceStatus.ps1',
        'tools\vm\Start-WinMintVmObserve.ps1'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $relativePath) -PathType Leaf)) {
            Add-SmokeFailure "VM managed acceptance script is missing: $relativePath"
        }
    }

    . (Join-Path $root 'tools\vm\WinMint-VmConsole.ps1')
    if (-not (Test-WinMintVmLogSanitizer)) {
        Add-SmokeFailure 'WinMint-VmConsole.ps1 log sanitizer self-check failed.'
    }
    $quoted = Format-WinMintProcessArgument 'WinMint VM Acceptance'
    if ($quoted -notmatch '^".*"$') {
        Add-SmokeFailure 'Format-WinMintProcessArgument should quote multi-word Windows Terminal arguments.'
    }
    $wtLine = ConvertTo-WinMintWtCommandLine -TabTitle 'WinMint VM Acceptance' -StartingDirectory 'C:\repo root' -PwshPath 'C:\Program Files\pwsh\pwsh.exe' -PwshArguments @('-File', 'C:\repo\tools\vm\Invoke-WinMintVmAcceptance.ps1', '-ManagedRun')
    foreach ($expected in @('--title "WinMint VM Acceptance"', '-d "C:\repo root"', '-- "C:\Program Files\pwsh\pwsh.exe"', '-ManagedRun')) {
        if ($wtLine -notlike "*$expected*") {
            Add-SmokeFailure "Managed WT command line should contain '$expected'."
        }
    }
    $acceptanceText = Get-WinMintRepositoryText -RelativePath 'tools\vm\Invoke-WinMintVmAcceptance.ps1'
    foreach ($expected in @('ManagedRun', 'Update-WinMintVmManagedRun', 'Set-WinMintVmRepoRoot', 'Invoke-WinMintVmLoggedCommand', 'Test-WinMintSetupShellAcceptanceEvidence', 'Test-WinMintVmSetupCompleteLogEvidence', 'Test-WinMintVmSmokeFirstLogonActivityMinElapsed', 'TimeBudgetMinutes', 'plumbingVerdict', 'evidenceVerdict', 'ConnectBasic', 'NoObserve', 'Ensure-WinMintVmObserve', 'Start-WinMintVmObserve', 'SPLASH LIVE', 'Invoke-WinMintGuestPesterAcceptance', 'liveInstallAudit', 'Test-WinMintGuestRemovalDrift')) {
        if ($acceptanceText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Invoke-WinMintVmAcceptance.ps1 should wire managed/logged VM acceptance via '$expected'."
        }
    }
    if ($acceptanceText -match '-not \$warned') {
        Add-SmokeFailure 'Smoke plumbing should not fail solely on advisory warningSteps.'
    }
    $pushScriptsText = Get-WinMintRepositoryText -RelativePath 'tools\vm\Push-WinMintSetupScripts.ps1'
    if ($pushScriptsText -notmatch 'AgentMode') {
        Add-SmokeFailure 'Push-WinMintSetupScripts.ps1 should accept -AgentMode for splash vs headless iteration.'
    }
    $observeText = Get-WinMintRepositoryText -RelativePath 'tools\vm\lib\VmObserve.ps1'
    foreach ($expected in @('Set-WinMintVmConnectPreset', 'Start-WinMintVmObserve', 'Stop-WinMintVmConnect', 'Start-WinMintVmRunLogViewerInWindowsTerminal', 'DisableEnhancedMode', 'Open-WinMintVmConnectBasicWatch', 'Resolve-WinMintVmAcceptanceTier')) {
        if ($observeText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "VM observe lib should wire VMConnect observation via '$expected'."
        }
    }
    if ($observeText -notmatch 'Get-WinMintVmGuestWaitSnapshot') {
        $consoleText = Get-WinMintRepositoryText -RelativePath 'tools\vm\WinMint-VmConsole.ps1'
        if ($consoleText -notmatch 'Get-WinMintVmGuestWaitSnapshot') {
            Add-SmokeFailure 'WinMint-VmConsole.ps1 should dot-source Get-WinMintVmGuestWaitSnapshot.ps1.'
        }
    }
    $evidenceText = Get-WinMintRepositoryText -RelativePath 'tools\vm\lib\VmEvidence.ps1'
    if ($evidenceText -notmatch 'plumbingFailures') {
        Add-SmokeFailure 'VmEvidence.ps1 should split setup shell acceptance into plumbing vs evidence failures.'
    }
    $guestText = Get-WinMintRepositoryText -RelativePath 'tools\vm\lib\VmGuest.ps1'
    foreach ($expected in @(
            'Test-WinMintVmGuestPsDirectRetryable'
            'WinMint guest harness requires bundled PowerShell 7'
        )) {
        if ($guestText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "VmGuest.ps1 should harden guest PSDirect via '$expected'."
        }
    }
    if ($evidenceText -notmatch 'nativeLogOk = \$true') {
        Add-SmokeFailure 'VmEvidence.ps1 should score native setup shell log evidence via nativeLogOk.'
    }
    $guestSnapshotText = Get-WinMintRepositoryText -RelativePath 'tools\vm\Get-WinMintVmGuestWaitSnapshot.ps1'
    if ($guestSnapshotText -notmatch 'runtime-state\.json') {
        Add-SmokeFailure 'Get-WinMintVmGuestWaitSnapshot.ps1 should read runtime-state.json for guest polling.'
    }
    if ($guestSnapshotText -notmatch 'setup-shell-status\.json') {
        Add-SmokeFailure 'Get-WinMintVmGuestWaitSnapshot.ps1 should fall back to setup-shell-status.json when runtime-state is absent.'
    }
    $acceptanceText = Get-WinMintRepositoryText -RelativePath 'tools\vm\Invoke-WinMintVmAcceptance.ps1'
    if ($acceptanceText -notmatch 'Panther') {
        Add-SmokeFailure 'Invoke-WinMintVmAcceptance.ps1 should pull Panther setup logs into evidence.'
    }
    $logText = Get-WinMintRepositoryText -RelativePath 'tools\vm\lib\VmLog.ps1'
    if ($logText -notmatch 'Remove-WinMintVmAnsiEscape') {
        Add-SmokeFailure 'VmLog.ps1 should strip ANSI escape sequences from run.log output.'
    }
    if ($logText -notmatch 'run-events\.jsonl') {
        Add-SmokeFailure 'VmLog.ps1 should write structured run-events.jsonl for VM acceptance polling.'
    }
    if ($logText -notmatch 'Initialize-WinMintVmRunLog') {
        Add-SmokeFailure 'VmLog.ps1 should initialize structured VM acceptance run logs.'
    }
    $managedText = Get-WinMintRepositoryText -RelativePath 'tools\vm\Start-WinMintVmAcceptanceManaged.ps1'
    if ($managedText -notmatch 'Initialize-WinMintVmRunLog') {
        Add-SmokeFailure 'Start-WinMintVmAcceptanceManaged.ps1 should initialize run.log before starting the child process.'
    }
    if ($managedText -notmatch 'NoObserve') {
        Add-SmokeFailure 'Start-WinMintVmAcceptanceManaged.ps1 should forward -NoObserve to the acceptance child.'
    }
    if ($managedText -notmatch 'Start-WinMintVmAcceptanceWorkerConsole') {
        Add-SmokeFailure 'Start-WinMintVmAcceptanceManaged.ps1 should launch one live worker console (Spectre + harness).'
    }
    if ($managedText -match 'Start-WinMintVmBuildLogViewersInWindowsTerminal') {
        Add-SmokeFailure 'Start-WinMintVmAcceptanceManaged.ps1 must not open separate verbose/run.log tail tabs.'
    }
    if ($managedText -notmatch 'Get-WinMintVmBuildVerboseLogPath' -and $managedText -notmatch 'WinMint-Build\.verbose\.log') {
        Add-SmokeFailure 'Start-WinMintVmAcceptanceManaged.ps1 should surface WinMint-Build.verbose.log for Spectre dual-channel builds.'
    }
    $statusText = Get-WinMintRepositoryText -RelativePath 'tools\vm\Get-WinMintVmAcceptanceStatus.ps1'
    if ($statusText -notmatch 'complete = ') {
        Add-SmokeFailure 'Get-WinMintVmAcceptanceStatus.ps1 should expose a complete flag for agent polling.'
    }
    if ($statusText -notmatch 'significantTail') {
        Add-SmokeFailure 'Get-WinMintVmAcceptanceStatus.ps1 should expose significantTail (non-progress log lines) for agent polling.'
    }
    if ($statusText -notmatch 'runEvents') {
        Add-SmokeFailure 'Get-WinMintVmAcceptanceStatus.ps1 should expose runEvents for structured progress polling.'
    }
    if ($statusText -notmatch 'elapsedMinutes') {
        Add-SmokeFailure 'Get-WinMintVmAcceptanceStatus.ps1 should expose elapsedMinutes for time-budget monitoring.'
    }
    if ($statusText -notmatch 'observePid') {
        Add-SmokeFailure 'Get-WinMintVmAcceptanceStatus.ps1 should expose observePid for Basic VMConnect monitoring.'
    }
    if (-not (Test-WinMintVmInlineConsole -WindowsTerminal:$false -NoWindowsTerminal:$false)) {
        Add-SmokeFailure 'VM acceptance should stay inline by default (no -WindowsTerminal).'
    }
    if (Test-WinMintVmInlineConsole -WindowsTerminal -NoWindowsTerminal:$false) {
        Add-SmokeFailure 'VM acceptance should opt in to Windows Terminal only via -WindowsTerminal.'
    }
}

function Assert-WinMintVmPostSetupCheckpointContract {
    foreach ($relativePath in @('tools\vm\Build-And-TestVm.ps1', 'tools\vm\Invoke-WinMintVmCheckpoint.ps1', 'tools\vm\New-WinMintTestVm.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $relativePath) -PathType Leaf)) {
            Add-SmokeFailure "VM checkpoint script is missing: $relativePath"
        }
    }

    . (Join-Path $root 'tools\vm\WinMint-VmConsole.ps1')
    foreach ($expected in @(
            'Get-WinMintVmPostSetupCheckpointSidecarPath'
            'Get-WinMintVmImageBuildFingerprint'
            'Get-WinMintVmAgentBuildFingerprint'
            'Resolve-WinMintVmAcceptanceBuildPlan'
            'Invoke-WinMintVmAcceptanceCheckpointIteration'
            'Invoke-WinMintVmPushAgentScripts'
            'Test-WinMintVmPostSetupCheckpointReady'
            'Test-WinMintVmPostSetupCheckpointUsable'
            'Save-WinMintVmPostSetupCheckpoint'
            'Restore-WinMintVmPostSetupCheckpoint'
        )) {
        if (-not (Get-Command $expected -ErrorAction SilentlyContinue)) {
            Add-SmokeFailure "WinMint-VmConsole.ps1 should export checkpoint helper '$expected'."
        }
    }

    $buildText = Get-WinMintRepositoryText -RelativePath 'tools\vm\Build-And-TestVm.ps1'
    foreach ($expected in @('UseCheckpoint', 'Test-WinMintVmPostSetupCheckpointUsable', 'Invoke-WinMintVmAcceptanceCheckpointIteration', 'Get-WinMintVmAgentBuildFingerprint')) {
        if ($buildText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Build-And-TestVm.ps1 should wire PostSetup checkpoint via '$expected'."
        }
    }
    $fingerprintText = Get-WinMintRepositoryText -RelativePath 'tools\vm\lib\VmFingerprint.ps1'
    foreach ($expected in @('Restore-WinMintVmPostSetupCheckpoint', 'Invoke-WinMintVmPushAgentScripts')) {
        if ($fingerprintText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "VmFingerprint.ps1 checkpoint iteration should call '$expected'."
        }
    }

    $acceptanceText = Get-WinMintRepositoryText -RelativePath 'tools\vm\Invoke-WinMintVmAcceptance.ps1'
    if ($acceptanceText -notmatch 'UseCheckpoint') {
        Add-SmokeFailure 'Invoke-WinMintVmAcceptance.ps1 should pass -UseCheckpoint to Build-And-TestVm.ps1.'
    }
    if ($acceptanceText -notmatch 'Resolve-WinMintVmAcceptanceBuildPlan|build-plan') {
        Add-SmokeFailure 'Invoke-WinMintVmAcceptance.ps1 should resolve and log an acceptance build plan.'
    }
    if ($acceptanceText -notmatch 'Invoke-WinMintVmPushAgentScripts|AgentMode|AcceptanceRun') {
        Add-SmokeFailure 'Invoke-WinMintVmAcceptance.ps1 should default checkpoint iteration with AgentMode for smoke.'
    }

    $newVmText = Get-WinMintRepositoryText -RelativePath 'tools\vm\Invoke-WinMintVmAcceptance.ps1'
    if ($newVmText -notmatch 'Save-WinMintVmPostSetupCheckpoint') {
        Add-SmokeFailure 'Invoke-WinMintVmAcceptance.ps1 should auto-save PostSetup checkpoints during the FirstLogon wait.'
    }

    $pesterHarness = Join-Path $root 'tools\dev\Invoke-WinMintPesterContract.ps1'
    $pesterTests = Join-Path $root 'tests\contract\WinMint.Contract.Tests.ps1'
    foreach ($path in @($pesterHarness, $pesterTests)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Add-SmokeFailure "Pester contract harness is missing: $path"
        }
    }
}

function Assert-FirstLogonDefaultsToVisibleConsole {
    Assert-FirstLogonDefaultsToSetupShell
}

function Assert-FirstLogonDemoHarnessIsNonMutating {
    $demoPath = Join-Path $root 'tools\firstlogon\Show-WinMintFirstLogonDemo.ps1'
    if (-not (Test-Path -LiteralPath $demoPath -PathType Leaf)) {
        Add-SmokeFailure 'Expected tools\firstlogon\Show-WinMintFirstLogonDemo.ps1 to exist.'
        return
    }

    $demoText = Get-Content -LiteralPath $demoPath -Raw
    $consoleText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\firstlogon\Agent.Console.ps1') -Raw
    $agentStartText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\firstlogon\Start-WinMintAgent.ps1') -Raw
    $setupPayloadText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Private\Image\SetupPayloadStaging.ps1') -Raw
    foreach ($expected in @(
        "[ValidateSet('Success', 'Warnings', 'Failure', 'LongRun')]",
        'WinMintFirstLogonDemo-',
        'Agent.Console.ps1',
        'Agent.Context.ps1',
        'Agent.Plan.ps1',
        'New-WinMintAgentContext',
        'Set-WinMintAgentContext',
        'Get-WinMintAgentContext',
        'Show-AgentPlan',
        'Show-AgentFinalSummary',
        'Show-DemoRunOverview',
        'Show-DemoArtifacts',
        'Initialize-DemoUtf8Console',
        'wt.exe',
        'UseWindowsTerminal',
        'ForceSixel',
        'NoPause'
    )) {
        if ($demoText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "FirstLogon demo harness should contain '$expected'."
        }
    }
    foreach ($expected in @(
        'Get-SpectreImage',
        'AgentConsoleSplashImagePath',
        'AgentConsoleForceSixel',
        'AgentConsoleSplashMaxWidth',
        'Show-AgentSplashImage',
        'Format-SpectreAligned',
        "Format = 'Sixel'",
        'Force = $true',
        '$env:WT_SESSION',
        'Out-SpectreHost'
    )) {
        if ($consoleText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "FirstLogon console should support image splash rendering with '$expected'."
        }
    }
    if ($agentStartText -notmatch [regex]::Escape('Assets\Brand\winmint_logo_wordmark.png')) {
        Add-SmokeFailure 'FirstLogon agent should point the console splash at the staged WinMint logo wordmark PNG.'
    }
    foreach ($expected in @('assets\brand\winmint_hero.png', 'Assets\Brand', 'winmint_logo_wordmark.png', 'Staged WinMint logo wordmark PNG')) {
        if ($setupPayloadText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "ISO staging should include the FirstLogon splash asset with '$expected'."
        }
    }

    foreach ($forbidden in @(
        'Start-WinMintAgent.ps1',
        'Agent.Runtime.ps1',
        'Set-WinMintFirstLogonAutoLogonPersistent',
        'Clear-WinMintFirstLogonRetry',
        'Invoke-WinMintFirstLogonAppxCleanup',
        'Invoke-WinMintFirstLogonOneDriveRemoval',
        '$env:LOCALAPPDATA\WinMint'
    )) {
        if ($demoText -match [regex]::Escape($forbidden)) {
            Add-SmokeFailure "FirstLogon demo harness must not call or target mutating setup path '$forbidden'."
        }
    }

    foreach ($forbiddenPattern in @(
        '(?m)^\s*&\s*(winget|wsl|schtasks|reg)(\.exe)?\b',
        '(?m)^\s*Start-Process\s+.*\b(winget|wsl|schtasks|reg)(\.exe)?\b'
    )) {
        if ($demoText -match $forbiddenPattern) {
            Add-SmokeFailure "FirstLogon demo harness must not execute installer or setup commands matching '$forbiddenPattern'."
        }
    }
}

function Assert-FirstLogonPinsSelectedAppsToStart {
    $firstLogonText = Get-WinMintFirstLogonText
    foreach ($expected in @(
        'Set-WinMintFirstLogonStartPins',
        'Get-WinMintFirstLogonPinSelection',
        'Set-WinMintFirstLogonTaskbarPins',
        'Resolve-WinMintFirstLogonAppExecutable',
        'Resolve-WinMintFirstLogonStartShortcut',
        'Get-WinMintFirstLogonPackageDisplayNames',
        'New-WinMintFirstLogonStartShortcut',
        'desktopAppLink',
        'ConfigureStartPins',
        'Start pins applied',
        'Taskbar pins applied',
        'PinEdgeToTaskbar',
        'FirstLogon_ShellPins.json',
        'Zen Browser',
        'Helium',
        'Cursor',
        'Get-WinMintFirstLogonCliOnlyPinAppIds'
    )) {
        if ($firstLogonText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "FirstLogon should pin selected browsers/editors to Start/taskbar with '$expected'."
        }
    }
    if ($firstLogonText -match [regex]::Escape('Microsoft\Windows\Start Menu\Programs\WinMint')) {
        Add-SmokeFailure 'FirstLogon must not create a WinMint Start Menu helper folder for Start pins.'
    }
    if ($firstLogonText -match 'New-WinMintFirstLogonStartShortcut[\s\S]{0,240}neovim') {
        Add-SmokeFailure 'FirstLogon must not create or pin Neovim shortcuts; Neovim is CLI-only.'
    }
}

function Assert-FirstLogonFinalizesTerminalProfiles {
    $firstLogonText = Get-WinMintFirstLogonText
    foreach ($expected in @(
        'Set-WinMintFirstLogonTerminalProfiles',
        'Set-WinMintWindowsTerminalProfiles',
        'Get-WinMintDisabledTerminalProfileSources',
        'New-WinMintWslTerminalProfile',
        'Get-WinMintProfileWslDistros',
        'Windows.Terminal.WindowsPowerShell',
        'Windows Terminal defaults applied',
        'WindowsTerminal.Profiles.ps1'
    )) {
        if ($firstLogonText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "FirstLogon should finalize Terminal defaults with '$expected'."
        }
    }
    if ($firstLogonText -match '\$agentExitCode\s+-eq\s+0[\s\S]{0,240}Set-WinMintFirstLogonTerminalProfiles') {
        Add-SmokeFailure 'FirstLogon Terminal profile finalization must not be gated on a fully successful agent exit code.'
    }
    $terminalProfilesText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\WindowsTerminal.Profiles.ps1') -Raw
    if ($terminalProfilesText -match '(?s)function Get-WinMintDisabledTerminalProfileSources\s*\{.*?@\s*\((.*?)\)\s*\}') {
        $disabledSourcesBlock = $matches[1]
        foreach ($src in @('Windows.Terminal.Wsl', 'Windows.Terminal.SSH', 'Windows.Terminal.PowershellCore')) {
            if ($disabledSourcesBlock -notmatch [regex]::Escape($src)) {
                Add-SmokeFailure "Windows Terminal disabled profile sources must include '$src' so curated profiles stay authoritative."
            }
        }
        if ($terminalProfilesText -match "firstWindowPreference\s*=\s*'defaultNewWindow'") {
            Add-SmokeFailure 'WindowsTerminal.Profiles.ps1 must not assign invalid firstWindowPreference defaultNewWindow.'
        }
        if ($terminalProfilesText -notmatch "firstWindowPreference\s*=\s*'defaultProfile'") {
            Add-SmokeFailure 'WindowsTerminal.Profiles.ps1 must set firstWindowPreference to defaultProfile.'
        }
        foreach ($expected in @(
                'Install-WinMintTerminalIcons',
                'Get-WinMintTerminalIconSettingsPath',
                'pathTranslationStyle',
                'WinMint\TerminalIcons',
                'assets\ui\wsl'
            )) {
            if ($terminalProfilesText -notmatch [regex]::Escape($expected)) {
                Add-SmokeFailure "WindowsTerminal.Profiles.ps1 should stage asset icons with '$expected'."
            }
        }
        if ($terminalProfilesText -match "ms-appx:///ProfileIcons/(ubuntu|fedora|archlinux|nixos|pengwin)\.png") {
            Add-SmokeFailure 'WSL Terminal profiles must use staged assets/ui/wsl PNG icons, not ms-appx ProfileIcons.'
        }
        if ($terminalProfilesText -notmatch "pwsh\.exe -NoLogo") {
            Add-SmokeFailure 'PowerShell Terminal profile must use pwsh.exe -NoLogo.'
        }
    }
    else {
        Add-SmokeFailure 'Windows Terminal disabled profile sources helper is missing.'
    }
    if ($firstLogonText -match '\$agentExitCode\s+-eq\s+0[\s\S]{0,320}Set-WinMintFirstLogonStartPins') {
        Add-SmokeFailure 'FirstLogon Start pin finalization must not be gated on a fully successful agent exit code.'
    }
}

function Assert-AgentLiveInstallFailuresAreWarnings {
    $agentText = @(
            (Get-Content -LiteralPath (Join-Path $root 'src\runtime\firstlogon\Agent.Runtime.ps1') -Raw),
            (Get-Content -LiteralPath (Join-Path $root 'src\runtime\firstlogon\Agent.Host.ps1') -Raw)
        ) -join "`n"
    $consoleText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\firstlogon\Agent.Console.ps1') -Raw
    foreach ($expected in @(
        '$blockingSteps',
        'FailurePolicy',
        'warningSteps',
        'completed with warnings',
        'failed (non-blocking)',
        'Wait-AgentConsoleBeforeClose -Failed $false -Warnings'
    )) {
        if ($agentText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Agent should treat live install failures as warnings with '$expected'."
        }
    }
    foreach ($expected in @('param([bool]$Failed, [bool]$Warnings)', 'finished with warnings')) {
        if ($consoleText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Agent console should report warning-only completion with '$expected'."
        }
    }
    if ($agentText -match [regex]::Escape('$advisorySteps = @(''liveInstallAudit'', ''phone-link'')')) {
        Add-SmokeFailure 'Agent must not limit non-blocking failures to only liveInstallAudit and phone-link.'
    }
    foreach ($expected in @(
        'Remove-AgentDesktopShortcuts',
        'CommonDesktopDirectory',
        "Filter '*.lnk'",
        'Removed desktop shortcuts created by installers.'
    )) {
        if ($agentText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Agent should remove live installer-created desktop shortcuts with '$expected'."
        }
    }
}

function Assert-AgentConsolePresentationSeam {
    $consoleText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\firstlogon\Agent.Console.ps1') -Raw
    foreach ($expected in @(
        'Show-AgentEventInConsole',
        'Get-AgentConsoleStepLabel',
        'Initialize-AgentConsoleProgress',
        "'cleanup'",
        "'needsReboot'",
        "'retryable'",
        'Get-WinMintAgentModuleCatalog'
    )) {
        if ($consoleText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Agent console presentation seam should include '$expected'."
        }
    }
    foreach ($relativePath in @(
        'src\runtime\firstlogon\Agent.Runtime.ps1',
        'src\runtime\firstlogon\Agent.Plan.ps1',
        'src\runtime\firstlogon\Agent.Install.ps1'
    )) {
        $text = Get-Content -LiteralPath (Join-Path $root $relativePath) -Raw
        if ($text -match 'Write-AgentConsoleLine') {
            Add-SmokeFailure "$relativePath must emit Write-AgentEvent only; human output belongs in Agent.Console.ps1."
        }
    }
}

function Assert-SetupCompleteRegistersFirstLogonFallback {
    $setupCompleteText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\SetupComplete.ps1') -Raw
    $firstLogonText = Get-WinMintFirstLogonText

    foreach ($expected in @(
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'WinMintFirstLogon',
        'FirstLogon.ps1',
        'Registered HKLM RunOnce fallback for FirstLogon.ps1 under PowerShell 7.'
    )) {
        if ($setupCompleteText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "SetupComplete should register FirstLogon fallback with '$expected'."
        }
    }

    foreach ($expected in @(
        'Clear-WinMintFirstLogonRetry',
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'WinMintFirstLogon'
    )) {
        if ($firstLogonText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "FirstLogon should clean FirstLogon RunOnce fallback after success with '$expected'."
        }
    }
}

function Assert-SetupCompleteDoesNotDeleteWindowsOld {
    $setupCompleteText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\SetupComplete.ps1') -Raw
    if ($setupCompleteText -match [regex]::Escape('C:\Windows.old')) {
        Add-SmokeFailure 'SetupComplete must not delete C:\Windows.old; clean-install/destructive behavior must stay explicit.'
    }
}

function Assert-EdgeDebloatOnlyNoUninstallProductPath {
    # Edge stays on the image. WinMint never automates uninstall and never
    # presents a remove/keep Edge choice. Debloat policies always apply.
    $settings = New-SmokeBuildProfileSettings
    $settings.DmaInterop = $false
    $settings.KeepEdge = $false
    $profile = New-WinMintBuildProfile -Settings $settings
    if (-not [bool]$profile.keep.edge) {
        Add-SmokeFailure 'Authored profiles must always keep.edge=true (-KeepEdge is a no-op).'
    }
    $config = New-WinMintBuildConfig -BuildProfile $profile
    if (-not [bool]$config.Keep.Edge) {
        Add-SmokeFailure 'Build config Keep.Edge must always be true.'
    }
    $setupProfile = New-WinMintInstallPlanSetupProfile -BuildConfig $config
    if ([bool]$setupProfile.edge.removeEdge -or -not [bool]$setupProfile.edge.keepEdge) {
        Add-SmokeFailure 'Setup profile must never request Edge removal (removeEdge=false, keepEdge=true).'
    }
    if (@($config.RegistryTweaks) -notcontains 'edge-policy-minimal') {
        Add-SmokeFailure 'Edge debloat (edge-policy-minimal) must always apply.'
    }

    $setupActionsText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\Setup.Actions.ps1') -Raw
    if ($setupActionsText -match [regex]::Escape("'edge-removal'") -or $setupActionsText -match 'Invoke-ScEdgeRemoval') {
        Add-SmokeFailure 'Setup action catalog must not include edge-removal / Invoke-ScEdgeRemoval.'
    }
    $edgeModulePath = Join-Path $root 'src\runtime\setup\SetupComplete\Edge.ps1'
    if (Test-Path -LiteralPath $edgeModulePath -PathType Leaf) {
        Add-SmokeFailure 'SetupComplete\Edge.ps1 must not exist; Edge uninstall is not a product path.'
    }
    $setupCompleteText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\SetupComplete.ps1') -Raw
    foreach ($forbidden in @('--uninstall', 'Invoke-ScEdgeRemoval', 'AllowUninstall', 'msedge')) {
        if ($setupCompleteText -match [regex]::Escape($forbidden)) {
            Add-SmokeFailure "SetupComplete.ps1 must not automate Edge uninstall ('$forbidden')."
        }
    }

    $cliHelp = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Cli.ps1') -Raw
    if ($cliHelp -match 'Keep/restore intent for those domains' -or $cliHelp -match 'removal intent') {
        Add-SmokeFailure 'CLI help must not advertise Edge removal as a KeepEdge product choice.'
    }
    if ($cliHelp -notmatch 'Accepted no-op' -or $cliHelp -notmatch 'Edge is always kept') {
        Add-SmokeFailure 'CLI help must document -KeepEdge as an accepted no-op (Edge always kept).'
    }

    $wizardText = Get-Content -LiteralPath (Join-Path $root 'assets\runtime\setup\setup-shell\wizard.js') -Raw
    if ($wizardText -notmatch 'KeepEdge:\s*true') {
        Add-SmokeFailure 'Wizard profile payload must set KeepEdge: true.'
    }
    foreach ($forbiddenUi in @('keepEdge', 'Keep Edge', 'Remove Edge', 'removeEdge')) {
        # KeepEdge: true in the payload is required; do not treat that as UI copy.
        if ($forbiddenUi -eq 'keepEdge') { continue }
        if ($wizardText -match [regex]::Escape($forbiddenUi)) {
            Add-SmokeFailure "Wizard must not present Edge keep/remove UI copy: '$forbiddenUi'."
        }
    }
    # Gaming/copilot remain the only keep toggles in wizard state UI.
    if ($wizardText -notmatch 'keepGaming' -or $wizardText -notmatch 'keepCopilot') {
        Add-SmokeFailure 'Wizard should still expose keepGaming/keepCopilot toggles.'
    }
}

function Assert-AutoTimeZoneUpdaterFollowsLocationServices {
    $firstLogonText = Get-WinMintFirstLogonText
    foreach ($expected in @(
        'if (-not $restoreLocationServices)',
        'Disabled Auto Time Zone Updater because location services are off.',
        'Enabled Auto Time Zone Updater because location services are on.',
        'ConsentStore\location',
        'SensorPermissionState',
        "'Allow'",
        "'Deny'"
    )) {
        if ($firstLogonText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "FirstLogon Auto Time Zone Updater handling should include '$expected'."
        }
    }
    if ($firstLogonText -match [regex]::Escape('Disabled Auto Time Zone Updater after DMA setup.')) {
        Add-SmokeFailure 'FirstLogon must not unconditionally disable Auto Time Zone Updater after DMA setup.'
    }
    $specializeText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\Specialize.ps1') -Raw
    if ($specializeText -notmatch [regex]::Escape('$restoreLocationServices') -or
        $specializeText -notmatch [regex]::Escape('if (-not $restoreLocationServices)') -or
        $specializeText -match [regex]::Escape("Set-WinHomeLocation -GeoId `$dmaSetupGeoId -ErrorAction Stop`r`n            Disable-SpecializeAutoTimeZone")) {
        Add-SmokeFailure 'Specialize must not unconditionally disable Auto Time Zone Updater when location services are expected on.'
    }
    $auditText = Get-Content -LiteralPath (Join-Path $root 'tools\audit\Audit-LiveInstall.ps1') -Raw
    foreach ($expected in @('dma-auto-time-zone-disabled', 'Location services are expected on, but Auto Time Zone Updater is disabled.')) {
        if ($auditText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Live audit Auto Time Zone Updater handling should include '$expected'."
        }
    }
}

function Assert-DmaInteropUsesFixedIrelandRegion {
    $region = Resolve-WinMintDmaInteropSetupRegion
    if ($region.Country -ne 'Ireland' -or $region.Culture -ne 'en-IE' -or [int]$region.GeoId -ne 68) {
        Add-SmokeFailure "DMA interoperability must resolve Ireland/en-IE/GeoID 68, got $($region.Country)/$($region.Culture)/$($region.GeoId)."
    }

    $publicContractText = @(
        Get-Content -LiteralPath (Join-Path $root 'WinMint-CLI.ps1') -Raw
        Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Private\Headless.ps1') -Raw
        Get-Content -LiteralPath (Join-Path $root 'schemas\winmint.buildprofile.schema.json') -Raw
    ) -join "`n"
    foreach ($forbidden in @('EeaCountry', 'EEACountry', 'DmaCountry', 'DMACountry', 'SetupCountry')) {
        if ($publicContractText -match [regex]::Escape($forbidden)) {
            Add-SmokeFailure "DMA setup country must not be exposed as a public profile/CLI setting ('$forbidden')."
        }
    }
}

function Assert-BuildProfileSchemaOwnsBrowserContract {
    $schemaPath = Join-Path $root 'schemas\winmint.buildprofile.schema.json'
    $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
    $development = $schema.properties.development

    function Assert-BuildProfileSchemaEnum {
        param(
            [Parameter(Mandatory)][object[]]$Actual,
            [Parameter(Mandatory)][object[]]$Expected,
            [Parameter(Mandatory)][string]$Name
        )

        $actualText = @($Actual | ForEach-Object { [string]$_ })
        $expectedText = @($Expected | ForEach-Object { [string]$_ })
        if (($actualText -join "`n") -ne ($expectedText -join "`n")) {
            Add-SmokeFailure "BuildProfile schema enum '$Name' must match the backend option catalog. Actual: [$($actualText -join ', ')] Expected: [$($expectedText -join ', ')]"
        }
    }

    if (@($development.required) -notcontains 'browsers') {
        Add-SmokeFailure 'BuildProfile schema must require profile.development.browsers as a first-class contract field.'
    }

    $browserSchema = $development.properties.browsers
    if (-not [bool]$browserSchema.uniqueItems) {
        Add-SmokeFailure 'BuildProfile schema must require profile.development.browsers to be unique.'
    }
    foreach ($browserId in @('zen-browser', 'helium', 'firefox-developer-edition', 'brave', 'edge')) {
        if (@($browserSchema.items.enum) -notcontains $browserId) {
            Add-SmokeFailure "BuildProfile schema must allow canonical browser id '$browserId'."
        }
    }
    Assert-BuildProfileSchemaEnum -Actual $schema.properties.source.properties.architecture.enum -Expected (Get-WinMintOptionValues -Name ProfileArchitecture) -Name 'profile.source.architecture'
    Assert-BuildProfileSchemaEnum -Actual $schema.properties.target.properties.device.enum -Expected (Get-WinMintOptionValues -Name TargetDevice) -Name 'profile.target.device'
    Assert-BuildProfileSchemaEnum -Actual $schema.properties.target.properties.formFactor.enum -Expected (Get-WinMintOptionValues -Name FormFactor) -Name 'profile.target.formFactor'
    Assert-BuildProfileSchemaEnum -Actual $schema.properties.target.properties.powerPlan.enum -Expected (Get-WinMintOptionValues -Name PowerPlan) -Name 'profile.target.powerPlan'
    Assert-BuildProfileSchemaEnum -Actual $schema.properties.target.properties.editionMode.enum -Expected (Get-WinMintOptionValues -Name EditionMode) -Name 'profile.target.editionMode'
    Assert-BuildProfileSchemaEnum -Actual $schema.properties.target.properties.diskMode.enum -Expected (Get-WinMintOptionValues -Name DiskMode) -Name 'profile.target.diskMode'
    Assert-BuildProfileSchemaEnum -Actual $schema.properties.target.properties.diskLayout.properties.preset.enum -Expected (Get-WinMintOptionValues -Name DiskLayoutPreset) -Name 'profile.target.diskLayout.preset'
    Assert-BuildProfileSchemaEnum -Actual $schema.properties.identity.properties.accountMode.enum -Expected (Get-WinMintOptionValues -Name AccountMode) -Name 'profile.identity.accountMode'
    Assert-BuildProfileSchemaEnum -Actual $schema.properties.drivers.properties.source.enum -Expected (Get-WinMintOptionValues -Name DriverSource) -Name 'profile.drivers.source'
    Assert-BuildProfileSchemaEnum -Actual @($schema.properties.desktop.properties.cursorPack.const) -Expected (Get-WinMintOptionValues -Name DesktopCursorPack) -Name 'profile.desktop.cursorPack'
    Assert-BuildProfileSchemaEnum -Actual $schema.properties.desktop.properties.layers.items.enum -Expected (Get-WinMintOptionValues -Name DesktopLayer) -Name 'profile.desktop.layers[]'
    Assert-BuildProfileSchemaEnum -Actual $development.properties.editors.items.enum -Expected (Get-WinMintOptionValues -Name Editor) -Name 'profile.development.editors[]'
    Assert-BuildProfileSchemaEnum -Actual $development.properties.browsers.items.enum -Expected (Get-WinMintOptionValues -Name Browser) -Name 'profile.development.browsers[]'
    Assert-BuildProfileSchemaEnum -Actual $development.properties.wsl.properties.distros.items.enum -Expected (Get-WinMintOptionValues -Name WslDistro) -Name 'profile.development.wsl.distros[]'
    Assert-BuildProfileSchemaEnum -Actual $schema.properties.features.properties.launcher.enum -Expected (Get-WinMintOptionValues -Name Launcher) -Name 'profile.features.launcher'
    Assert-BuildProfileSchemaEnum -Actual $schema.properties.updates.properties.mode.enum -Expected (Get-WinMintOptionValues -Name UpdateMode) -Name 'profile.updates.mode'
    Assert-BuildProfileSchemaEnum -Actual @($schema.properties.updates.properties.targetFeatureVersion.const) -Expected (Get-WinMintOptionValues -Name UpdateTargetFeatureVersion) -Name 'profile.updates.targetFeatureVersion'
    Assert-BuildProfileSchemaEnum -Actual @($schema.properties.updates.properties.releaseCadence.const) -Expected (Get-WinMintOptionValues -Name UpdateReleaseCadence) -Name 'profile.updates.releaseCadence'
    Assert-BuildProfileSchemaEnum -Actual $schema.properties.removals.properties.aiPolicy.enum -Expected (Get-WinMintOptionValues -Name AiPolicy) -Name 'profile.removals.aiPolicy'

    $wslDistrosSchema = $development.properties.wsl.properties.distros
    if ($null -eq $wslDistrosSchema) {
        Add-SmokeFailure 'BuildProfile schema must require profile.development.wsl.distros in v4.'
    }
    if ($development.properties.wsl.properties.PSObject.Properties['enabled']) {
        Add-SmokeFailure 'BuildProfile schema must not expose profile.development.wsl.enabled in v4.'
    }

    $conditionalJson = $schema.allOf | ConvertTo-Json -Depth 30 -Compress
    foreach ($expected in @('"contains":{"const":"edge"}', '"required":["keep"]', '"edge":{"const":true}')) {
        if ($conditionalJson -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "BuildProfile schema must enforce edge browser selection implies keep.edge=true ('$expected')."
        }
    }
}

function Assert-LiveAuditDistinguishesDmaSetupFromVisibleRegion {
    $auditText = Get-Content -LiteralPath (Join-Path $root 'tools\audit\Audit-LiveInstall.ps1') -Raw
    foreach ($expected in @(
            'knownEeaSetupGeoId',
            'current.homeLocationGeoId',
            'restore.homeLocationGeoId',
            'locationServices',
            'ai-appx-provisioned-drift',
            'windows-update-service'
        )) {
        if ($auditText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Live audit should distinguish DMA setup/current visible region and AI/platform checks ('$expected')."
        }
    }
}

function Assert-AiRemovalCatalogAndGuardrails {
    $catalogPath = Join-Path $root 'config\ai-removal.json'
    if (-not (Test-Path -LiteralPath $catalogPath)) {
        Add-SmokeFailure 'Expected config\ai-removal.json to exist.'
        return
    }
    $catalogText = Get-Content -LiteralPath $catalogPath -Raw
    foreach ($expected in @(
            'MicrosoftWindows.Client.AIX',
            'MicrosoftWindows.Client.CoreAI',
            'Microsoft.Windows.Ai.Copilot.Provider',
            'Microsoft.Edge.GameAssist',
            'Microsoft.Windows.AIHub',
            'WindowsAI'
        )) {
        if ($catalogText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "AI removal catalog should include '$expected'."
        }
    }
    foreach ($forbidden in @('Microsoft.Office.ActionsServer', 'Microsoft.WritingAssistant', 'Office Actions Server')) {
        if ($catalogText -match [regex]::Escape($forbidden)) {
            Add-SmokeFailure "AI removal catalog should not touch Office-dependent AI surface '$forbidden'."
        }
    }

    $publicAiText = @(
        Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Private\Image\AiRemoval.ps1') -Raw
        Get-WinMintSetupCompleteText
        Get-Content -LiteralPath (Join-Path $root 'tools\audit\Audit-LiveInstall.ps1') -Raw
    ) -join "`n"
    foreach ($forbidden in @('TrustedInstaller', 'IntegratedServicesRegionPolicySet.json', 'Remove-WindowsPackage', 'Remove-Package', 'Owners', 'DefVis')) {
        if ($publicAiText -match [regex]::Escape($forbidden)) {
            Add-SmokeFailure "Serviceable AI removal path must not contain '$forbidden'."
        }
    }
    if ($publicAiText -match '\bRegister-ScheduledTask\b') {
        Add-SmokeFailure "Serviceable AI removal path must not register scheduled maintenance tasks."
    }
}

function Assert-RecoveryBundleIsOutputOnly {
    $manifestText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Private\Manifest.ps1') -Raw
    foreach ($expected in @(
            'Save-WinMintRecoveryBundle',
            "Join-Path `$OutputDir 'recovery'",
            'Recover-WinMintAiPolicy.ps1',
            'Recover-WinMintDmaRegion.ps1',
            'WinMint-Recovery.json'
        )) {
        if ($manifestText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Recovery bundle output should include '$expected'."
        }
    }

    $setupStagingText = @(
        Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Private\Image\Unattend.ps1') -Raw
        Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Private\Image\SetupPayloadStaging.ps1') -Raw
    ) -join [Environment]::NewLine
    foreach ($forbidden in @('Recover-WinMintAiPolicy.ps1', 'Recover-WinMintDmaRegion.ps1', 'WinMint-Recovery.json')) {
        if ($setupStagingText -match [regex]::Escape($forbidden)) {
            Add-SmokeFailure "Recovery bundle file '$forbidden' must not be staged into the installed OS."
        }
    }
}

function Assert-AgentRunsLiveInstallAudit {
    $profile = New-WinMintInstallPlanAgentProfile -BuildConfig (New-WinMintBuildConfig -BuildProfile (New-SmokeBuildProfile))
    if ([bool]$profile.modules.liveInstallAudit.enabled) {
        Add-SmokeFailure 'Live install audit must be disabled by default in the agent profile; users opt in explicitly.'
    }
    $optInSettings = New-SmokeBuildProfileSettings
    $optInSettings.LiveInstallAudit = $true
    $optInProfile = New-WinMintInstallPlanAgentProfile -BuildConfig (New-WinMintBuildConfig -BuildProfile (New-WinMintBuildProfile -Settings $optInSettings))
    if (-not [bool]$optInProfile.modules.liveInstallAudit.enabled) {
        Add-SmokeFailure 'Live install audit opt-in should enable the agent module.'
    }
    $agentModulePath = Join-Path $root 'src\runtime\firstlogon\Modules\LiveInstallAudit.ps1'
    if (-not (Test-Path -LiteralPath $agentModulePath)) {
        Add-SmokeFailure 'Expected LiveInstallAudit agent module to exist.'
        return
    }
    $agentModuleText = Get-Content -LiteralPath $agentModulePath -Raw
    foreach ($expected in @('Invoke-WinMintAgentLiveInstallAuditBootstrap', 'liveInstallAudit', 'Audit-LiveInstall.ps1', '-IncludeInventory')) {
        if ($agentModuleText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "LiveInstallAudit agent module should contain '$expected'."
        }
    }
    $auditScriptText = Get-Content -LiteralPath (Join-Path $root 'tools\audit\Audit-LiveInstall.ps1') -Raw
    foreach ($expected in @('IncludeInventory', 'debugInventory', 'Get-AuditServiceInventory', 'Get-AuditScheduledTaskInventory', 'Get-AuditStartupInventory')) {
        if ($auditScriptText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Live install audit should expose debug inventory through the opt-in report with '$expected'."
        }
    }
    $agentRuntimeText = @(
            (Get-Content -LiteralPath (Join-Path $root 'src\runtime\firstlogon\Agent.Runtime.ps1') -Raw),
            (Get-Content -LiteralPath (Join-Path $root 'src\runtime\firstlogon\Agent.Plan.ps1') -Raw),
            (Get-Content -LiteralPath (Join-Path $root 'src\runtime\firstlogon\agent-module-catalog.json') -Raw)
        ) -join "`n"
    $agentCatalogText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\firstlogon\agent-module-catalog.json') -Raw
    foreach ($expected in @(
        'New-WinMintAgentRuntimeStepPlan',
        'FailurePolicy',
        'blocking',
        'advisory',
        'finalValidation',
        '$blockingSteps = @($runtimePlan'
    )) {
        if ($agentRuntimeText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Agent runtime should expose plan-driven ordering and failure policy with '$expected'."
        }
    }
    $catalog = Get-Content -LiteralPath (Join-Path $root 'src\runtime\firstlogon\agent-module-catalog.json') -Raw | ConvertFrom-Json
    $stepNames = @($catalog | ForEach-Object { [string]$_.RuntimeStepName })
    $profilesIndex = [array]::IndexOf($stepNames, 'profiles')
    $packageManagersIndex = [array]::IndexOf($stepNames, 'package-managers')
    $editorsIndex = [array]::IndexOf($stepNames, 'editors')
    $auditIndex = [array]::IndexOf($stepNames, 'liveInstallAudit')
    $failedIndex = $agentRuntimeText.IndexOf('$failed = @')
    if ($profilesIndex -lt 0 -or $packageManagersIndex -lt 0 -or $editorsIndex -lt 0 -or $auditIndex -lt 0 -or $failedIndex -lt 0 -or
        -not ($profilesIndex -lt $packageManagersIndex -and $packageManagersIndex -lt $editorsIndex -and $editorsIndex -lt $auditIndex)) {
        Add-SmokeFailure 'Agent step runtime should run liveInstallAudit during final validation before failed-step evaluation.'
    }
    if ($agentCatalogText -notmatch '"RuntimeStepName": "liveInstallAudit"') {
        Add-SmokeFailure 'Agent module catalog should declare the liveInstallAudit runtime step.'
    }
}

function Assert-GitBootstrapDoesNotInstallFullGitByDefault {
    $agentProfile = New-WinMintInstallPlanAgentProfile -BuildConfig (New-WinMintBuildConfig -BuildProfile (New-SmokeBuildProfile))
    if ([bool]$agentProfile.modules.git.enabled) {
        Add-SmokeFailure 'Git bootstrap must remain disabled by default; users configure Git themselves unless a future FirstLogon dependency requires it.'
    }

    $gitModuleText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\firstlogon\Modules\Git.ps1') -Raw
    if ($gitModuleText -notmatch 'MinGit') {
        Add-SmokeFailure 'Git module scaffold should document MinGit as the only acceptable FirstLogon Git dependency.'
    }
    foreach ($forbidden in @('Git.Git', 'GitForWindows', 'usr\bin\bash.exe')) {
        if ($gitModuleText -match [regex]::Escape($forbidden)) {
            Add-SmokeFailure "Git module must not install or depend on full Git for Windows/Git Bash: '$forbidden'."
        }
    }

    $packagesText = Get-Content -LiteralPath (Join-Path $root 'config\packages.json') -Raw
    foreach ($forbidden in @('Git.Git', 'GitForWindows')) {
        if ($packagesText -match [regex]::Escape($forbidden)) {
            Add-SmokeFailure "Package catalog must not default to full Git for Windows: '$forbidden'."
        }
    }
}

function Assert-StarshipPromptUsesNerdFontTerminalDefaults {
    $packagesText = Get-Content -LiteralPath (Join-Path $root 'config\packages.json') -Raw
    if ($packagesText -notmatch '(?s)"displayName"\s*:\s*"Starship".*"source"\s*:\s*"scoop"') {
        Add-SmokeFailure 'Starship catalog entry must be Scoop-owned.'
    }
    if ($packagesText -notmatch '(?s)"displayName"\s*:\s*"Coreutils".*"source"\s*:\s*"winget".*"id"\s*:\s*"Microsoft\.Coreutils"') {
        Add-SmokeFailure 'Coreutils catalog entry must be winget-owned as Microsoft.Coreutils.'
    }

    $packageManagerText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\firstlogon\Modules\PackageManagers.ps1') -Raw
    foreach ($expected in @(
            'Install-AgentManifestTool -ToolId ''mingit''',
            'Install-AgentManifestTool -ToolId ''coreutils''',
            'Install-AgentManifestTool -ToolId ''starship''',
            'preset'', ''nerd-font-symbols''',
            'Invoke-Expression (&starship init powershell)',
            'Get-WinMintAgentStarshipConfigPath',
            'Cascadia Code NF'
        )) {
        if ($packageManagerText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Starship package-manager bootstrap should contain '$expected'."
        }
    }

    $firstLogonText = Get-WinMintFirstLogonText
    $terminalProfilesText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\WindowsTerminal.Profiles.ps1') -Raw
    foreach ($expected in @(
            'profiles.defaults.font.face',
            'profiles.defaults.colorScheme',
            'profiles.defaults.bellStyle',
            'profiles.defaults.opacity',
            'centerOnLaunch',
            'launchMode',
            'Cascadia Code NF'
        )) {
        if ($firstLogonText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "FirstLogon terminal finalizer should enforce '$expected'."
        }
        if ($terminalProfilesText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Windows Terminal defaults helper should preserve '$expected'."
        }
    }
}

function Assert-AgentWingetUsesDefaultInstallerSelection {
    $runtimeText = @(
            (Get-Content -LiteralPath (Join-Path $root 'src\runtime\firstlogon\Agent.Install.ps1') -Raw),
            (Get-Content -LiteralPath (Join-Path $root 'src\runtime\firstlogon\Agent.Host.ps1') -Raw)
        ) -join "`n"
    $packageManagerText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\firstlogon\Modules\PackageManagers.ps1') -Raw
    $packagesText = Get-Content -LiteralPath (Join-Path $root 'config\packages.json') -Raw

    foreach ($expected in @(
        'Start-Process @startArgs',
        'winget.exe',
        '--architecture',
        'Save-AgentDirectToolInstaller',
        'Get-FileHash -LiteralPath $installerPath -Algorithm SHA256',
        'Invoke-WebRequest -Uri $url -OutFile $installerPath',
        '''direct'''
    )) {
        if ($runtimeText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Agent runtime should carry package install primitive '$expected'."
        }
    }
    foreach ($expected in @(
        'Invoke-WinMintAgentWingetBootstrapUpgrades',
        'Invoke-WinMintAgentWingetCatchUpAll',
        'Invoke-WinMintAgentWingetRepairAndSourceUpdate',
        'Repair-WinGetPackageManager',
        '''source'', ''update''',
        'Microsoft.AppInstaller',
        'Microsoft.EdgeWebView2Runtime',
        'Microsoft.WindowsTerminal',
        '''upgrade''',
        '''--all''',
        '''--id''',
        '''--scope'', ''machine''',
        '''--accept-source-agreements''',
        '''--accept-package-agreements''',
        'package-manager:winget-bootstrap',
        'package-manager:winget-upgrade-all',
        'package-manager:winget-repair',
        '0x8A15002C',
        '0x8A15002D',
        '-1978335189',
        'Test-WinMintAgentWingetNoUpgradeAvailable',
        'No available upgrade found',
        'incomplete = $partial',
        'phase = ''post-main'''
    )) {
        if ($packageManagerText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Package manager winget hardening should contain '$expected'."
        }
    }
    if ($packageManagerText -match "if \(\`$partial\) \{ 'ok' \}") {
        Add-SmokeFailure 'winget upgrade --all partial failure must not be recorded as clean ok.'
    }
    if ($packageManagerText -like "*'pin', 'add'*") {
        Add-SmokeFailure 'Package manager bootstrap should not pin Edge/WebView2 before upgrades.'
    }
    $agentRuntimeText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\firstlogon\Agent.Runtime.ps1') -Raw
    if ($agentRuntimeText -notmatch 'Invoke-WinMintAgentWingetCatchUpAll') {
        Add-SmokeFailure 'Agent runtime should run winget upgrade --all catch-up after main modules.'
    }

    foreach ($forbidden in @(
        'Invoke-AgentLimitedUserCommand',
        'Join-AgentCommandLine',
        'ConvertTo-AgentPowerShellLiteral',
        '/RL LIMITED',
        '/RP $password',
        'WinMintAgentLimited',
        '--scope',
        '--ignore-dependencies',
        'installScope',
        'ignoreDependencies'
    )) {
        if ($runtimeText -match [regex]::Escape($forbidden)) {
            Add-SmokeFailure "Agent runtime should not carry brittle winget override '$forbidden'."
        }
        if ($packagesText -match [regex]::Escape($forbidden)) {
            Add-SmokeFailure "Package catalog should not carry brittle winget override '$forbidden'."
        }
    }
}

function Assert-OfficialUpdatePayloadAcquisition {
    $moduleText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Private\UpdatePayloads.ps1') -Raw
    $engineText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Engine.ps1') -Raw
    $entryText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\WinMint.ps1') -Raw
    foreach ($expected in @(
        'catalog.update.microsoft.com/Search.aspx',
        'catalog.update.microsoft.com/DownloadDialog.aspx',
        'ConvertFrom-WinMintCatalogBase64Sha256',
        'Save-WinMintVerifiedDownload',
        'Invoke-WinMintUpdatePayloadDownload',
        'Start-BitsTransfer',
        'definitionupdates.microsoft.com/packages?package=dismpackage',
        'Get-AuthenticodeSignature',
        'UpdatePayloadManifest.json',
        'Optional preview update acquisition is not allowed'
    )) {
        if ($moduleText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Official update payload acquisition should contain '$expected'."
        }
    }
    if ($engineText -notmatch 'Invoke-WinMintStable25H2UpdatePayloadAcquisition') {
        Add-SmokeFailure 'Engine must acquire official Stable25H2 payloads before enforcing update payload preflight.'
    }
    if ($entryText -notmatch 'Private\\UpdatePayloads\.ps1') {
        Add-SmokeFailure 'WinMint.ps1 must dot-source the update payload acquisition module.'
    }
}

function Assert-ElevationChecksUseInstanceMarshalSize {
    $text = Get-Content -LiteralPath (Join-Path $root 'src\runtime\common\WinMint.Runtime.Common.ps1') -Raw
    if ($text -match 'Marshal\]::SizeOf\(\[WinMint\.TokenElevation\+TOKEN_ELEVATION\]\)') {
        Add-SmokeFailure 'WinMint.Runtime.Common.ps1 should marshal the TOKEN_ELEVATION instance, not the RuntimeType.'
    }
    if ($text -notmatch [regex]::Escape('$size = [System.Runtime.InteropServices.Marshal]::SizeOf($elevation)')) {
        Add-SmokeFailure 'WinMint.Runtime.Common.ps1 should compute TOKEN_ELEVATION size from the struct instance.'
    }
}

function Assert-WinMintRuntimeCommonContracts {
    $setupCommon = Join-Path $root 'src\runtime\setup\WinMint.Runtime.Common.ps1'
    $agentCommon = Join-Path $root 'src\runtime\firstlogon\WinMint.Runtime.Common.ps1'
    $canonicalCommon = Join-Path $root 'src\runtime\common\WinMint.Runtime.Common.ps1'
    if (-not (Test-Path -LiteralPath $canonicalCommon -PathType Leaf)) {
        Add-SmokeFailure "Canonical WinMint.Runtime.Common.ps1 is missing: $canonicalCommon"
        return
    }
    if (-not (Test-Path -LiteralPath $setupCommon -PathType Leaf) -or -not (Test-Path -LiteralPath $agentCommon -PathType Leaf)) {
        Add-SmokeFailure 'WinMint.Runtime.Common.ps1 must exist under setup and firstlogon.'
        return
    }
    $canonicalHash = (Get-FileHash -LiteralPath $canonicalCommon -Algorithm SHA256).Hash
    $setupHash = (Get-FileHash -LiteralPath $setupCommon -Algorithm SHA256).Hash
    $agentHash = (Get-FileHash -LiteralPath $agentCommon -Algorithm SHA256).Hash
    if ($setupHash -ne $agentHash) {
        Add-SmokeFailure 'WinMint.Runtime.Common.ps1 re-exporters must be byte-identical in setup and firstlogon.'
    }
    $expectedReExport = ". (Join-Path (Split-Path -Parent `$PSScriptRoot) 'common\WinMint.Runtime.Common.ps1')"
    foreach ($reExportPath in @($setupCommon, $agentCommon)) {
        $reExportText = Get-Content -LiteralPath $reExportPath -Raw
        if ($reExportText -notmatch [regex]::Escape($expectedReExport)) {
            Add-SmokeFailure "WinMint.Runtime.Common.ps1 re-exporter must dot-source canonical common: $reExportPath"
        }
    }

    $commonText = Get-Content -LiteralPath $canonicalCommon -Raw
    foreach ($expected in @(
        'function Initialize-WinMintConsoleEncoding',
        'function Get-WinMintMinimumPowerShellVersion',
        'function Get-WinMintPowerShellHostVersion',
        'function Test-WinMintPowerShellHostMeetsMinimum',
        'function Resolve-WinMintPowerShell7Host',
        'function Test-WinMintProcessElevated',
        'function Save-WinMintAtomicJson',
        'function Read-WinMintJsonFile',
        'function Import-WinMintRuntimeCommon',
        "[version]'7.6.0'"
    )) {
        if ($commonText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "WinMint.Runtime.Common.ps1 should define '$expected'."
        }
    }

    foreach ($relativePath in @(
        'src\runtime\setup\FirstLogon.Host.ps1',
        'src\runtime\firstlogon\Agent.Host.ps1',
        'src\runtime\setup\FirstLogon.ps1',
        'src\runtime\firstlogon\Start-WinMintAgent.ps1'
    )) {
        $text = Get-Content -LiteralPath (Join-Path $root $relativePath) -Raw
        if ($text -match 'Add-Type\s+-Namespace\s+WinMint\s+-Name\s+TokenElevation') {
            Add-SmokeFailure "$relativePath must not define WinMint.TokenElevation; use WinMint.Runtime.Common.ps1."
        }
    }

    $firstLogonPs = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\FirstLogon.ps1') -Raw
    $startAgent = Get-Content -LiteralPath (Join-Path $root 'src\runtime\firstlogon\Start-WinMintAgent.ps1') -Raw
    if ($firstLogonPs -notmatch 'Initialize-WinMintConsoleEncoding') {
        Add-SmokeFailure 'FirstLogon.ps1 should call Initialize-WinMintConsoleEncoding from WinMint.Runtime.Common.ps1.'
    }
    if ($startAgent -notmatch 'Initialize-WinMintConsoleEncoding') {
        Add-SmokeFailure 'Start-WinMintAgent.ps1 should call Initialize-WinMintConsoleEncoding from WinMint.Runtime.Common.ps1.'
    }

    $stateText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\firstlogon\Agent.State.ps1') -Raw
    $setupStateText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\FirstLogon.State.ps1') -Raw
    if ($stateText -notmatch 'Save-WinMintAtomicJson') {
        Add-SmokeFailure 'Save-AgentState should delegate to Save-WinMintAtomicJson.'
    }
    if ($stateText -notmatch 'Write-WinMintRuntimeState') {
        Add-SmokeFailure 'Save-AgentState should dual-write runtime-state.json agent display section.'
    }
    if ($setupStateText -notmatch 'Save-WinMintAtomicJson') {
        Add-SmokeFailure 'Save-WinMintFirstLogonState should delegate to Save-WinMintAtomicJson.'
    }

    $supportText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\FirstLogon.Support.ps1') -Raw
    if ($supportText -notmatch 'WinMint\.Runtime\.Common\.ps1') {
        Add-SmokeFailure 'FirstLogon.Support.ps1 should dot-source WinMint.Runtime.Common.ps1.'
    }
    if ($supportText -notmatch 'WinMint\.RuntimeState\.ps1') {
        Add-SmokeFailure 'FirstLogon.Support.ps1 should dot-source WinMint.RuntimeState.ps1.'
    }

    $contextPath = Join-Path $root 'src\runtime\firstlogon\Agent.Context.ps1'
    if (-not (Test-Path -LiteralPath $contextPath -PathType Leaf)) {
        Add-SmokeFailure 'Agent.Context.ps1 must exist for explicit agent runtime context.'
    }
    else {
        $agentContextText = Get-Content -LiteralPath $contextPath -Raw
        if ($agentContextText -match 'Sync-AgentLegacyContext') {
            Add-SmokeFailure 'Agent.Context.ps1 must not keep Sync-AgentLegacyContext after agent context migration.'
        }
    }

    $setupContextPath = Join-Path $root 'src\runtime\setup\FirstLogon.Context.ps1'
    if (-not (Test-Path -LiteralPath $setupContextPath -PathType Leaf)) {
        Add-SmokeFailure 'FirstLogon.Context.ps1 must exist for explicit setup runtime context.'
    }
    else {
        $setupContextText = Get-Content -LiteralPath $setupContextPath -Raw
        if ($setupContextText -match 'Sync-FirstLogonLegacyContext') {
            Add-SmokeFailure 'FirstLogon.Context.ps1 must not keep Sync-FirstLogonLegacyContext after setup context migration.'
        }
    }
    $firstLogonEntryText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\FirstLogon.ps1') -Raw
    if ($firstLogonEntryText -notmatch 'Set-WinMintFirstLogonContext') {
        Add-SmokeFailure 'FirstLogon.ps1 should initialize setup context via Set-WinMintFirstLogonContext.'
    }
    if ($setupStateText -notmatch 'Get-WinMintFirstLogonContext') {
        Add-SmokeFailure 'FirstLogon.State.ps1 should read paths from Get-WinMintFirstLogonContext.'
    }
    foreach ($relativePath in @(
        'src\runtime\setup\FirstLogon.Desktop.ps1',
        'src\runtime\setup\FirstLogon.Region.ps1',
        'src\runtime\setup\FirstLogon.Cleanup.ps1',
        'src\runtime\setup\FirstLogon.Transaction.ps1',
        'src\runtime\setup\FirstLogon.Host.ps1',
        'src\runtime\setup\FirstLogon.Runtime.ps1'
    )) {
        $moduleText = Get-Content -LiteralPath (Join-Path $root $relativePath) -Raw
        if ($moduleText -match '(?<![.\w])\$logDir\b') {
            Add-SmokeFailure "$relativePath must not reference ambient `$logDir`; use Get-WinMintFirstLogonContext."
        }
        if ($moduleText -match '(?<![.\w])\$payloadDir\b') {
            Add-SmokeFailure "$relativePath must not reference ambient `$payloadDir`; use Get-WinMintFirstLogonContext."
        }
    }
}

function Assert-NoMaintenancePayloadOrRegistration {
    $setupCompleteText = Get-WinMintSetupCompleteText
    $firstLogonText = Get-WinMintFirstLogonText
    $engineText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Engine.ps1') -Raw
    $setupPayloadText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Private\Image\SetupPayloadStaging.ps1') -Raw
    $maintenancePayload = Join-Path $root 'src\runtime\setup\Maintain.ps1'

    if (Test-Path -LiteralPath $maintenancePayload) {
        Add-SmokeFailure 'Maintenance payload must not live under src\runtime\setup.'
    }

    foreach ($forbidden in @('WinMintSlim-Maintain', 'RegisterWinMintMaintainScheduledTask')) {
        if ($setupCompleteText -match [regex]::Escape($forbidden)) {
            Add-SmokeFailure "SetupComplete.ps1 must not include maintenance task registration hook '$forbidden'."
        }
    }
    if ($firstLogonText -match [regex]::Escape("'Maintain.ps1'")) {
        Add-SmokeFailure 'FirstLogon cleanup must not preserve Maintain.ps1 on the installed system.'
    }
    if ($engineText -match [regex]::Escape("'Maintain.ps1'") -or
        $setupPayloadText -match [regex]::Escape("'Maintain.ps1'")) {
        Add-SmokeFailure 'Maintain.ps1 must not be staged as a default setup artifact.'
    }
}

function Assert-FirstLogonFailsClosedWhenElevationIsUnavailable {
    $firstLogonText = Get-WinMintFirstLogonText
    foreach ($expected in @(
        'Stop-WinMintFirstLogonUnelevated',
        "failure'] = 'notElevated'",
        'Set-WinMintFirstLogonRetry',
        'Set-WinMintFirstLogonAutoLogonPersistent',
        "Remove-Item -LiteralPath (Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon_self-elevation.flag')",
        'exit 1',
        'aborting before machine-wide setup so RunOnce can retry'
    )) {
        if ($firstLogonText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "FirstLogon should fail closed when elevation is unavailable with '$expected'."
        }
    }
    foreach ($forbidden in @(
        'continuing with the standard token',
        'some machine-wide operations may fail'
    )) {
        if ($firstLogonText -match [regex]::Escape($forbidden)) {
            Add-SmokeFailure "FirstLogon must not continue unelevated after self-elevation failure: '$forbidden'."
        }
    }
}

function Assert-FirstLogonElevationGuaranteeIsSingleton {
    $hostText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\FirstLogon.Host.ps1') -Raw
    $taskCreates = @([regex]::Matches($hostText, "taskName\s*=\s*'WinMintFirstLogonElevated'")).Count
    if ($taskCreates -ne 1) {
        Add-SmokeFailure "FirstLogon.Host.ps1 must define exactly one self-elevation scheduled-task block (found $taskCreates)."
    }
}

function Assert-FirstLogonRecoveryIsBounded {
    $firstLogonText = Get-WinMintFirstLogonText
    foreach ($expected in @(
        'MaxAttempts = 3',
        'New-WinMintFirstLogonRunState',
        'Clear-WinMintFirstLogonRecovery',
        "recovery'] = 'exhausted'",
        'DefaultPassword',
        'AutoLogonCount',
        'retry cap reached'
    )) {
        if ($firstLogonText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "FirstLogon recovery/autologon must be bounded with '$expected'."
        }
    }
}

function Assert-FirstLogonCleanupOnlyDeletesWinMintOwnedPayload {
    $firstLogonText = Get-WinMintFirstLogonText
    $setupCompleteText = Get-WinMintSetupCompleteText
    foreach ($expected in @(
        'WinMintAgent',
        'WinMintSetupProfile.json',
        'WinMintSetupPlan.json',
        'SetupComplete.ps1',
        'Audit-LiveInstall.ps1',
        'WinMint-owned setup payloads'
    )) {
        if ($firstLogonText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "FirstLogon cleanup should explicitly remove WinMint-owned payload '$expected'."
        }
    }
    foreach ($expected in @('cleanupSpec', 'Resolve-WinMintCleanupPath', '-EncodedCommand', 'Resolve-WinMintPowerShellHost')) {
        if ($firstLogonText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "FirstLogon cleanup should use a constrained PowerShell cleanup helper with '$expected'."
        }
    }
    foreach ($expected in @(
        'Test-WinMintSetupRetainFirstLogonArtifacts',
        'retainDiagnosticState',
        'diagnostic artifacts retained'
    )) {
        if ($firstLogonText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "FirstLogon cleanup should retain diagnostic artifacts when profile diagnostics request it with '$expected'."
        }
    }
    foreach ($expected in @(
        'WinMint post-install complete',
        'Enable-ComputerRestore',
        'Checkpoint-Computer',
        'MODIFY_SETTINGS',
        'final post-install restore point'
    )) {
        if ($firstLogonText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "FirstLogon final cleanup should create the post-install restore point with '$expected'."
        }
    }
    if ($setupCompleteText -match 'Checkpoint-Computer|Invoke-ScRestorePoint|Post-install \(SetupComplete\)') {
        Add-SmokeFailure 'SetupComplete must not create the restore point before FirstLogon finishes.'
    }
    foreach ($forbidden in @('cmd.exe', 'del /f', 'rmdir /s')) {
        if ($firstLogonText -match [regex]::Escape($forbidden)) {
            Add-SmokeFailure "FirstLogon cleanup must not use shell-string deletion through '$forbidden'."
        }
    }
    if ($firstLogonText -match '\$directoryTargets\s*=\s*@\(\s*\r?\n\s*\$payloadDir\s*(?:,|\r?\n|\))') {
        Add-SmokeFailure 'FirstLogon cleanup must not include the whole Setup\Scripts payloadDir as a directory target.'
    }
}

function Assert-ExternalReferenceAuditDocumentsSparkle {
    $strategyPath = Join-Path $root 'docs\Windows-Debloat-Strategy.md'
    $strategyText = Get-Content -LiteralPath $strategyPath -Raw
    if ($strategyText -notmatch 'Sparkle') {
        Add-SmokeFailure 'Windows-Debloat-Strategy.md should include Sparkle in the external tool lessons.'
    }
    foreach ($expectedUrl in @('https://docs.getsparkle.net/', 'https://github.com/parcoil/sparkle')) {
        if ($strategyText -notmatch [regex]::Escape($expectedUrl)) {
            Add-SmokeFailure "Windows-Debloat-Strategy.md should cite Sparkle source '$expectedUrl'."
        }
    }
}

function Assert-WslFirstDefaultsAndGuards {
    $defaultProfile = New-WinMintBuildProfile -Settings (New-SmokeBuildProfileSettings)
    $defaultDistros = @($defaultProfile.development.wsl.distros)
    if ($defaultDistros.Count -ne 0) {
        Add-SmokeFailure 'WSL distros must stay empty by default.'
    }

    $emptySettings = New-SmokeBuildProfileSettings
    $emptySettings.Wsl2Distros = @()
    $emptyProfile = New-WinMintBuildProfile -Settings $emptySettings
    if (@($emptyProfile.development.wsl.distros).Count -ne 0) {
        Add-SmokeFailure 'Explicit empty Wsl2Distros must preserve the WSL2 baseline without adding a distro.'
    }

    $customSettings = New-SmokeBuildProfileSettings
    $customSettings.Wsl2Distros = @('Ubuntu', 'Fedora', 'archlinux', 'NixOS-WSL', 'Pengwin')
    $customProfile = New-WinMintBuildProfile -Settings $customSettings
    $customDistros = @($customProfile.development.wsl.distros)
    foreach ($distro in @('Ubuntu', 'FedoraLinux', 'archlinux', 'NixOS-WSL', 'pengwin')) {
        if ($customDistros -notcontains $distro) {
            Add-SmokeFailure "Expected custom WSL distro '$distro' to be preserved."
        }
    }
    $versionedFedoraSettings = New-SmokeBuildProfileSettings
    $versionedFedoraSettings.Wsl2Distros = @('FedoraLinux-44')
    $versionedFedoraProfile = New-WinMintBuildProfile -Settings $versionedFedoraSettings
    if (@($versionedFedoraProfile.development.wsl.distros) -notcontains 'FedoraLinux') {
        Add-SmokeFailure 'Versioned Fedora WSL distro selections must normalize to the latest FedoraLinux token.'
    }

    $wizardJsPath = Join-Path $root 'assets\runtime\setup\setup-shell\wizard.js'
    $wizardJsText = Get-Content -LiteralPath $wizardJsPath -Raw
    if ($wizardJsText -notmatch 'keepGaming:\s*false') {
        Add-SmokeFailure 'Build wizard must default to the subtractive keep-flag state (remove everything).'
    }
    if ($wizardJsText -notmatch 'edition:\s*"Host"') {
        Add-SmokeFailure 'Build wizard must default the edition selector to host detection.'
    }
    if ($wizardJsText -notmatch 'browsers:\s*new Set\(\)' -or
        $wizardJsText -notmatch 'editors:\s*new Set\(\)' -or
        $wizardJsText -notmatch 'wsl:\s*new Set\(\)' -or
        $wizardJsText -match 'nilesoft:\s*true') {
        Add-SmokeFailure 'Build wizard must not preselect editors, browsers, WSL distros, or Nilesoft by default.'
    }

    $wslModulePath = Join-Path $root 'src\runtime\firstlogon\Modules\Wsl.ps1'
    $wslModuleText = Get-Content -LiteralPath $wslModulePath -Raw
    foreach ($expected in @(
        'pageReporting=true',
        'networkingMode=mirrored',
        'dnsTunneling=true',
        '# localhostForwarding=true',
        '# autoProxy=true',
        'firewall=true',
        'autoMemoryReclaim=gradual',
        'sparseVhd=true',
        'Install-WinMintWslDistroCore',
        'systemd=true',
        'appendWindowsPath=false',
        'useWindowsTimezone=true',
        'Set-WinMintWindowsTerminalProfiles',
        'WindowsTerminal.Profiles.ps1',
        '-WslDistros'
    )) {
        if ($wslModuleText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "WSL module should generate .wslconfig setting '$expected'."
        }
    }
    $agentProfileSample = New-WinMintInstallPlanAgentProfile -BuildConfig (New-WinMintBuildConfig -BuildProfile (New-SmokeBuildProfile))
    if (-not $agentProfileSample.identity -or
        [string]::IsNullOrWhiteSpace([string]$agentProfileSample.identity.accountName) -or
        [string]::IsNullOrWhiteSpace([string]$agentProfileSample.identity.computerName)) {
        Add-SmokeFailure 'Agent profile must carry identity.accountName and identity.computerName for WSL core.'
    }
    foreach ($expected in @(
        'function ConvertTo-WinMintLinuxUserName',
        'function ConvertTo-WinMintWslHostname',
        'function New-WinMintWslConfContent',
        'function Install-WinMintWslDistroCore',
        'function Get-WinMintWslCoreIdentity',
        'Managed by WinMint. Re-runs replace this file.',
        'WSL core skipped for NixOS'
    )) {
        if ($wslModuleText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "WSL module should include WSL core setup '$expected'."
        }
    }
    $terminalProfilesPath = Join-Path $root 'src\runtime\setup\WindowsTerminal.Profiles.ps1'
    $terminalProfilesText = Get-Content -LiteralPath $terminalProfilesPath -Raw
    if ($terminalProfilesText -notmatch 'New-WinMintWslTerminalProfile') {
        Add-SmokeFailure 'WindowsTerminal.Profiles.ps1 should define New-WinMintWslTerminalProfile for curated WSL distros.'
    }
    if ($wslModuleText -notmatch 'Set-WinMintWindowsTerminalProfiles -WslDistros') {
        Add-SmokeFailure 'WSL module should pass selected distros into Windows Terminal profile finalization.'
    }
    if ($wslModuleText -notmatch '\$distros\.Count -gt 0') {
        Add-SmokeFailure 'WSL module should skip Windows Terminal profile updates when no distros are selected.'
    }
    $bootstrapStart = $wslModuleText.IndexOf('function Invoke-WinMintAgentWslBootstrap')
    $bootstrapEnd = if ($bootstrapStart -ge 0) { $wslModuleText.IndexOf("`nfunction ", $bootstrapStart + 1) } else { -1 }
    if ($bootstrapEnd -lt 0) { $bootstrapEnd = $wslModuleText.Length }
    $bootstrapText = if ($bootstrapStart -ge 0) { $wslModuleText.Substring($bootstrapStart, $bootstrapEnd - $bootstrapStart) } else { '' }
    if ($bootstrapText -notmatch 'Install-WinMintWslDistroCore') {
        Add-SmokeFailure 'WSL bootstrap must invoke Install-WinMintWslDistroCore for registered distros.'
    }
    if ($bootstrapText -notmatch '--shutdown') {
        Add-SmokeFailure 'WSL bootstrap must wsl --shutdown after applying managed /etc/wsl.conf.'
    }
    $skipCallIndex = $bootstrapText.IndexOf('Test-WinMintAgentWslRuntimeValidationSkipped -AgentProfile')
    $wslConfigInBootstrap = $bootstrapText.IndexOf('Install-WinMintWslConfig')
    if ($skipCallIndex -lt 0 -or $wslConfigInBootstrap -lt 0 -or $skipCallIndex -gt $wslConfigInBootstrap) {
        Add-SmokeFailure 'Profile diagnostics WSL skip must run before Install-WinMintWslConfig in Invoke-WinMintAgentWslBootstrap.'
    }
    foreach ($expected in @('--update', '--web-download', 'Updating the WSL runtime.', 'Setting WSL 2 as the default version.')) {
        if ($wslModuleText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "WSL module should handle the runtime update path '$expected'."
        }
    }
    foreach ($expected in @(
        'Test-WinMintHyperVGuestWithoutNestedVirtualization',
        'Test-WinMintAgentWslRuntimeValidationSkipped',
        'Complete-WinMintAgentWslAdvisorySkip',
        'Set-WinMintWindowsTerminalProfiles',
        'ExposeVirtualizationExtensions $true',
        'WSL2 distro installation skipped',
        'wslRuntimeValidation=skip',
        'nested virtualization is not exposed'
    )) {
        if ($wslModuleText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "WSL module should explain nested Hyper-V virtualization failures with '$expected'."
        }
    }
    if ($wslModuleText -notmatch 'WSL2 configured; no distro selected') {
        Add-SmokeFailure 'WSL module should explicitly handle the no-distro baseline.'
    }
    foreach ($expected in @(
        'function Set-WinMintWslOobeComplete',
        'OOBEComplete',
        'function Invoke-WinMintWslInstallProcess',
        'function Get-WinMintWslInstalledDistributions',
        'function Get-WinMintWslListOutput',
        'CREATE_NEW_CONSOLE',
        'WSL_UTF8'
    )) {
        if ($wslModuleText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "WSL module should include unattended install hygiene '$expected'."
        }
    }
    $nixosInstallFnStart = $wslModuleText.IndexOf('function Install-WinMintNixOsWslDistribution')
    $nixosInstallFnEnd = if ($nixosInstallFnStart -ge 0) { $wslModuleText.IndexOf("`nfunction ", $nixosInstallFnStart + 1) } else { -1 }
    if ($nixosInstallFnEnd -lt 0) { $nixosInstallFnEnd = $wslModuleText.Length }
    $nixosInstallFnText = if ($nixosInstallFnStart -ge 0) {
        $wslModuleText.Substring($nixosInstallFnStart, $nixosInstallFnEnd - $nixosInstallFnStart)
    } else { '' }
    if ($nixosInstallFnText -notmatch 'Set-WinMintWslOobeComplete' -or
        $nixosInstallFnText -notmatch 'Invoke-WinMintWslInstallProcess' -or
        $nixosInstallFnText -notmatch "--from-file") {
        Add-SmokeFailure 'NixOS WSL install must stamp OOBEComplete and use Invoke-WinMintWslInstallProcess before --from-file.'
    }
    $updateIndex = $wslModuleText.IndexOf('Update-WinMintWslRuntime -WslPath $wsl.Source')
    $wslConfigIndex = $wslModuleText.IndexOf('Install-WinMintWslConfig')
    $installIndex = $wslModuleText.IndexOf("Invoke-WinMintWslInstallProcess -WslPath `$wsl.Source -ArgumentList @('--install', '--no-launch', '-d', `$distro)")
    $oobeBeforeDistroInstall = $bootstrapText.IndexOf('Set-WinMintWslOobeComplete')
    $nixosInstallIndex = $wslModuleText.IndexOf('Install-WinMintNixOsWslDistribution -WslPath $wsl.Source')
    if ($installIndex -lt 0) {
        Add-SmokeFailure 'WSL distro install must use Invoke-WinMintWslInstallProcess for wsl --install --no-launch.'
    }
    if ($bootstrapText -notmatch 'Get-WinMintWslInstalledDistributions') {
        Add-SmokeFailure 'WSL bootstrap must list installed distros via Get-WinMintWslInstalledDistributions (isolated Start-Process).'
    }
    if ($oobeBeforeDistroInstall -lt 0 -or $installIndex -lt 0) {
        Add-SmokeFailure 'WSL bootstrap must stamp OOBEComplete before wsl --install --no-launch.'
    }
    else {
        # installIndex is absolute in $wslModuleText; compare OOBE stamp inside bootstrap to the install call relative to bootstrap start.
        $installInBootstrap = $bootstrapText.IndexOf("Invoke-WinMintWslInstallProcess -WslPath `$wsl.Source -ArgumentList @('--install', '--no-launch', '-d', `$distro)")
        if ($installInBootstrap -lt 0 -or $oobeBeforeDistroInstall -gt $installInBootstrap) {
            Add-SmokeFailure 'Set-WinMintWslOobeComplete must run before Invoke-WinMintWslInstallProcess in the bootstrap install loop.'
        }
    }
    if ($wslConfigIndex -lt 0 -or $installIndex -lt 0 -or $wslConfigIndex -gt $installIndex) {
        Add-SmokeFailure 'Install-WinMintWslConfig must occur before distro install attempts.'
    }
    if ($wslConfigIndex -lt 0 -or $nixosInstallIndex -lt 0 -or $wslConfigIndex -gt $nixosInstallIndex) {
        Add-SmokeFailure 'Install-WinMintWslConfig must occur before the NixOS WSL installer path.'
    }
    if ($updateIndex -lt 0 -or $installIndex -lt 0 -or $updateIndex -gt $installIndex) {
        Add-SmokeFailure 'WSL runtime update must occur before distro install attempts.'
    }
    if ($updateIndex -lt 0 -or $nixosInstallIndex -lt 0 -or $updateIndex -gt $nixosInstallIndex) {
        Add-SmokeFailure 'WSL runtime update must occur before the NixOS WSL installer path.'
    }
    foreach ($expected in @('nixos.aarch64.wsl', 'Get-AgentProcessorArchitecture', 'Architecture = (Get-AgentProcessorArchitecture)')) {
        if ($wslModuleText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "NixOS-WSL release selection should be architecture-aware with '$expected'."
        }
    }
    foreach ($forbiddenIcon in @('ubuntu.svg', 'fedora.svg', 'archlinux.svg', 'nixos.svg')) {
        if ($wslModuleText -match [regex]::Escape($forbiddenIcon)) {
            Add-SmokeFailure "WSL module Windows Terminal profiles must use staged PNG icons, not '$forbiddenIcon'."
        }
    }
    if ($wslModuleText -notmatch 'New-WinMintWslConfContent' -or $wslModuleText -notmatch '/etc/wsl\.conf') {
        Add-SmokeFailure 'WSL module must write managed /etc/wsl.conf via New-WinMintWslConfContent / Install-WinMintWslDistroCore.'
    }
    $vmHarnessText = Get-Content -LiteralPath (Join-Path $root 'tools\vm\New-WinMintTestVm.ps1') -Raw
    if ($vmHarnessText -notmatch 'ExposeVirtualizationExtensions\s+\$true') {
        Add-SmokeFailure 'Hyper-V test VM harness must expose virtualization extensions for nested WSL2.'
    }
    if ($vmHarnessText -match [regex]::Escape("if (`$NoConnect) { `$SwitchName = '' }")) {
        Add-SmokeFailure 'Hyper-V test VM harness must not let -NoConnect null the VM network switch; automated acceptance needs host network so the live FirstLogon payload installs.'
    }
    foreach ($expected in @(
        'if ($SwitchName) { Connect-VMNetworkAdapter -VMName $VMName -SwitchName $SwitchName }',
        'Set-WinMintVmConnectPreset -VMName $VMName -BasicSession',
        'if (-not $NoConnect)',
        'Open-WinMintVmConnectBasicWatch'
    )) {
        if ($vmHarnessText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Hyper-V test VM harness should attach host network and open Basic VMConnect via '$expected'."
        }
    }
    $buildAndTestText = Get-Content -LiteralPath (Join-Path $root 'tools\vm\Build-And-TestVm.ps1') -Raw
    if ($buildAndTestText -notmatch 'NoConnect') {
        Add-SmokeFailure 'Build-And-TestVm.ps1 should forward -NoConnect for headless automated acceptance.'
    }
    if ($buildAndTestText -notmatch 'Test-WinMintOfflineImageRemovals') {
        Add-SmokeFailure 'Build-And-TestVm.ps1 should verify offline WIM removals after build.'
    }
    foreach ($expected in @(
        '$buildStartedAt',
        '$builtIso.FullName',
        "IsoPath   = `$builtIso.FullName",
        '$profileJson.identity.accountName',
        '$profileJson.identity.password',
        '$guestUser',
        '$guestPassword'
    )) {
        if ($buildAndTestText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Build-And-TestVm.ps1 should boot the just-built ISO and use profile credentials with '$expected'."
        }
    }
    $acceptanceHarnessText = Get-Content -LiteralPath (Join-Path $root 'tools\vm\Invoke-WinMintVmAcceptance.ps1') -Raw
    foreach ($expected in @('$cred', 'identity.accountName', 'identity.password')) {
        if ($acceptanceHarnessText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Invoke-WinMintVmAcceptance.ps1 should resolve guest credentials via '$expected'."
        }
    }
    $strategyText = Get-Content -LiteralPath (Join-Path $root 'docs\Windows-Debloat-Strategy.md') -Raw
    foreach ($guard in @('WinMint is WSL2-first', 'Ubuntu LTS', '/home/<user>/code', 'networkingMode=mirrored', 'managed /etc/wsl.conf')) {
        if ($strategyText -notmatch [regex]::Escape($guard)) {
            Add-SmokeFailure "WSL strategy should document '$guard'."
        }
    }
}

function Assert-DevDriveOptInContract {
    $schemaText = Get-Content -LiteralPath (Join-Path $root 'schemas\winmint.buildprofile.schema.json') -Raw
    foreach ($expected in @('"Off"', '"Partition"', '"VhdDynamic"', '64', '128', '256', 'diskpart', 'VhdDynamic')) {
        if ($schemaText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "BuildProfile schema Dev Drive contract should mention '$expected'."
        }
    }
    if ($schemaText -match 'Partition shrinks the Windows volume at FirstLogon') {
        Add-SmokeFailure 'Partition Dev Drive must not be documented as FirstLogon shrink; it is Setup diskpart.'
    }

    $unattendText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Private\Image\Unattend.ps1') -Raw
    foreach ($expected in @(
        'function New-WinMintWindowsOnlyDiskpartPeScript',
        'function New-WinMintDualBootDiskpartPeScript',
        'function Get-WinMintDiskpartRunSynchronousPath',
        'WinMintDiskpart.ps1',
        'DevDriveSizeGb',
        'format quick fs=refs label=DevDrive',
        'partitionDevDriveGb',
        '-DevDrive'
    )) {
        if ($unattendText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Unattend Dev Drive diskpart path should include '$expected'."
        }
    }
    if ($unattendText -match '-EncodedCommand') {
        Add-SmokeFailure 'Diskpart must not use -EncodedCommand RunSynchronous paths (WCM 259-char Path limit).'
    }
    if ($unattendText -notmatch '\$useDiskpart') {
        Add-SmokeFailure 'Install-Autounattend must force diskpart when Partition Dev Drive is selected.'
    }

    $pipelineText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Private\Pipeline.ps1') -Raw
    if (($pipelineText -split '-DevDrive \$BuildConfig\.DevDrive').Count -lt 3) {
        Add-SmokeFailure 'Pipeline must pass BuildConfig.DevDrive into both Install-Autounattend call sites.'
    }

    $devDriveModule = Get-Content -LiteralPath (Join-Path $root 'src\runtime\firstlogon\Modules\DevDrive.ps1') -Raw
    foreach ($expected in @(
        'function Enable-WinMintPartitionDevDrive',
        'function New-WinMintDevDriveVhdDynamic',
        'Format-Volume -DriveLetter $letter -FileSystem ReFS -DevDrive',
        'type=expandable',
        'WinMint.vhdx'
    )) {
        if ($devDriveModule -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "DevDrive FirstLogon module should include '$expected'."
        }
    }
    if ($devDriveModule -match 'function New-WinMintDevDrivePartition' -or $devDriveModule -match 'Resize-Partition') {
        Add-SmokeFailure 'FirstLogon must not shrink C: for Partition Dev Drive (Setup diskpart owns the carve).'
    }

    $profileText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Private\Config\Profile.ps1') -Raw
    if ($profileText -notmatch 'Partition requires AutoWipeDisk0 or DualBootReserved') {
        Add-SmokeFailure 'Profile validation must reject Partition Dev Drive with Manual disk mode.'
    }

    $setupShellStatus = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\WinMintSetupShell.Status.ps1') -Raw
    if ($setupShellStatus -notmatch [regex]::Escape("'modules.devDrive.enabled'")) {
        Add-SmokeFailure 'Setup-shell status projection must understand modules.devDrive.enabled.'
    }

    $strategyText = Get-Content -LiteralPath (Join-Path $root 'docs\Windows-Debloat-Strategy.md') -Raw
    foreach ($guard in @('Off by default', 'Partition', 'VhdDynamic', 'diskpart', 'WinMint.vhdx')) {
        if ($strategyText -notmatch [regex]::Escape($guard)) {
            Add-SmokeFailure "Dev Drive strategy should document '$guard'."
        }
    }
    if ($strategyText -match 'User-managed only') {
        Add-SmokeFailure 'Dev Drive is an opt-in profile surface; strategy must not call it user-managed only.'
    }
}

function Assert-LogNoiseInvariants {
    $pipelinePath = Join-Path $root 'src\runtime\image\Private\Pipeline.ps1'
    $displayPath = Join-Path $root 'src\runtime\image\Private\Console\Display.ps1'

    $pipelineText = Get-Content -LiteralPath $pipelinePath -Raw
    $targetLicenseSummaryCount = ([regex]::Matches(
        $pipelineText,
        [regex]::Escape('edition image(s) (target license)')
    )).Count
    if ($targetLicenseSummaryCount -ne 1) {
        Add-SmokeFailure "Expected one target-license service summary log, found $targetLicenseSummaryCount."
    }

    $displayText = Get-Content -LiteralPath $displayPath -Raw
    if ($displayText -match '\$timer\.Elapsed\.TotalSeconds\s+-ge\s+1') {
        Add-SmokeFailure 'Invoke-Action must not print duration summaries for every action over one second.'
    }
    if ($displayText -notmatch 'WinMintActionTimingVisibleThresholdSeconds') {
        Add-SmokeFailure 'Expected Invoke-Action timing summaries to use a visible-duration threshold.'
    }
}

function Assert-WinPEDriverInjectionDefaultsToSetupOnly {
    $catalogPath = Join-Path $root 'src\runtime\image\Private\Catalog.ps1'
    $stagingPath = Join-Path $root 'src\runtime\image\Private\Image\Staging.ps1'
    $driversPath = Join-Path $root 'src\runtime\image\Private\Image\Drivers.ps1'
    $pipelinePath = Join-Path $root 'src\runtime\image\Private\Pipeline.ps1'
    $catalogText = Get-Content -LiteralPath $catalogPath -Raw
    $stagingText = Get-Content -LiteralPath $stagingPath -Raw
    $driversText = Get-Content -LiteralPath $driversPath -Raw
    $pipelineText = Get-Content -LiteralPath $pipelinePath -Raw

    if ($catalogText -notmatch '\$script:BootWimDriverMountIndexes\s*=\s*@\(2\)') {
        Add-SmokeFailure 'Expected default WinPE driver injection to target boot.wim index 2 only.'
    }
    if ($stagingText -match '\$forDrivers\s*=\s*@\(1,\s*2\)') {
        Add-SmokeFailure 'Expected staging readiness not to inject drivers into boot.wim indexes 1 and 2 by default.'
    }
    if ($stagingText -notmatch '\$forDrivers\s*=\s*@\(\s*@\(2\)\s*\|\s*Where-Object') {
        Add-SmokeFailure 'Expected setup-only boot.wim index selection to stay array-wrapped for StrictMode-safe Count access.'
    }
    if ($stagingText -notmatch 'Setup-only') {
        Add-SmokeFailure 'Expected staging log to make setup-only WinPE driver mode visible.'
    }
    if ($stagingText -match "@\('/English',\s*`"/Image:\$ImageMountPath`",\s*'/Add-Driver',\s*`"/Driver:\$DriverSource`",\s*'/Recurse',\s*'/ForceUnsigned'\)") {
        Add-SmokeFailure 'Driver injection must not force unsigned drivers by default.'
    }
    if ($driversText -notmatch '\[switch\]\$WinPEOnly') {
        Add-SmokeFailure 'Expected Invoke-DriverInjection to expose -WinPEOnly for serviced-WIM cache hits.'
    }
    if ($pipelineText -notmatch '-WinPEOnly') {
        Add-SmokeFailure 'Expected Pipeline cache-hit path to invoke driver injection with -WinPEOnly so boot.wim still receives Setup PE drivers.'
    }
    if ($pipelineText -match '(?s)\$driverSources\s*=\s*\[System\.Collections\.Generic\.List\[object\]\]::new\(\)\s*\r?\n\s*if\s*\(\s*\$null\s*-eq\s*\$servicedWimCacheHit\s*\)') {
        Add-SmokeFailure 'Driver source resolution must not be gated solely on serviced-WIM cache miss; PE injection needs sources on cache hits.'
    }
}

function Assert-CopilotPlusUsesFullAiRemovalPolicy {
    # Subtractive model: the default build removes Edge noise
    # (edge-policy-minimal, always on), imposed Copilot/Windows AI surfaces
    # (windows-ai-features-removal, kept only with -KeepCopilot), and Recall
    # (windows-ai-recall-policy, always on as a security baseline), while
    # preserving explicit app-local tools such as Edge Copilot page-context chat,
    # Paint AI, Click to Do, and the local Settings agent.
    $edge = $script:RegistryTweaks | Where-Object id -eq 'edge-policy-minimal' | Select-Object -First 1
    $aiFeatures = $script:RegistryTweaks | Where-Object id -eq 'windows-ai-features-removal' | Select-Object -First 1
    $recall = $script:RegistryTweaks | Where-Object id -eq 'windows-ai-recall-policy' | Select-Object -First 1
    if (-not $edge -or -not $aiFeatures -or -not $recall) {
        Add-SmokeFailure 'Expected edge-policy-minimal, windows-ai-features-removal, and windows-ai-recall-policy registry tweaks to exist.'
        return
    }
    foreach ($expected in @(
            'EdgeShoppingAssistantEnabled',
            'ShowMicrosoftRewards',
            'WebWidgetAllowed',
            'CryptoWalletEnabled',
            'HideFirstRunExperience',
            'AutoImportAtFirstRun',
            'GuidedSwitchEnabled',
            'EdgeEnhanceImagesEnabled',
            'BackgroundModeEnabled',
            'StartupBoostEnabled',
            'NewTabPageContentEnabled',
            'NewTabPageAppLauncherEnabled',
            'ComposeInlineEnabled',
            'EdgeWorkspacesEnabled',
            'SpotlightExperiencesAndRecommendationsEnabled',
            'ImportOnEachLaunch',
            'AddressBarTrendingSuggestEnabled',
            'PromotionalTabsEnabled',
            'BingAdsSuppression'
        )) {
        if (@($edge.set | Where-Object name -eq $expected).Count -eq 0) {
            Add-SmokeFailure "Expected Edge noise policy to set $expected."
        }
    }
    $autoImport = @($edge.set | Where-Object name -eq 'AutoImportAtFirstRun' | Select-Object -First 1)
    if ($autoImport.Count -gt 0 -and [string]$autoImport[0].value -ne '4') {
        Add-SmokeFailure 'AutoImportAtFirstRun must be 4 (DisabledAutoImport) per Edge ADMX docs.'
    }
    foreach ($expected in @(
            'TurnOffWindowsCopilot',
            'GenAILocalFoundationalModelSettings',
            'BuiltInAIAPIsEnabled',
            'DisableAIFeatures',
            'LetAppsAccessSystemAIModels',
            'LetAppsAccessGenerativeAI'
        )) {
        if (@($aiFeatures.set | Where-Object name -eq $expected).Count -eq 0) {
            Add-SmokeFailure "Expected default AI feature removal policy to set $expected."
        }
    }
    foreach ($expected in @('DisableAIDataAnalysis', 'AllowRecallEnablement', 'AllowRecallExport', 'TurnOffSavingSnapshots')) {
        if (@($recall.set | Where-Object name -eq $expected).Count -eq 0) {
            Add-SmokeFailure "Expected Recall removal policy to set $expected."
        }
    }
    $allAiPolicySets = @($edge.set) + @($aiFeatures.set) + @($recall.set)
    foreach ($forbidden in @(
            'HubsSidebarEnabled',
            'StandaloneHubsSidebarEnabled',
            'CopilotPageContext',
            'CopilotCDPPageContext',
            'EdgeEntraCopilotPageContext',
            'NewTabPageBingChatEnabled',
            'DisableSettingsAgent',
            'DisableClickToDo',
            'DisableCocreator',
            'DisableImageCreator',
            'DisableGenerativeFill',
            'DisableGenerativeErase',
            'DisableRemoveBackground',
            'EnableCopilot',
            'DisableAgentConnectors',
            'DisableAgentWorkspaces',
            'DisableRemoteAgentConnectors'
        )) {
        if (@($allAiPolicySets | Where-Object name -eq $forbidden).Count -ne 0) {
            Add-SmokeFailure "WinMint should preserve explicit/local AI or Office-dependent policy '$forbidden'."
        }
    }
    # Curation: by default the AI feature removal applies; -KeepCopilot suppresses
    # it, but Recall removal applies on every build regardless.
    $defaultSelected = @(Get-WinMintSelectedRegistryTweaks -Context (New-WinMintTweakContext -KeepCopilot $false))
    $keepCopilotSelected = @(Get-WinMintSelectedRegistryTweaks -Context (New-WinMintTweakContext -KeepCopilot $true))
    if ($defaultSelected -notcontains 'windows-ai-features-removal') {
        Add-SmokeFailure 'windows-ai-features-removal must apply by default (KeepCopilot off).'
    }
    if ($keepCopilotSelected -contains 'windows-ai-features-removal') {
        Add-SmokeFailure 'windows-ai-features-removal must be suppressed when -KeepCopilot is selected.'
    }
    if ($defaultSelected -notcontains 'windows-ai-recall-policy' -or $keepCopilotSelected -notcontains 'windows-ai-recall-policy') {
        Add-SmokeFailure 'Recall removal policy must apply on every build, including when -KeepCopilot is selected.'
    }
}

function Assert-OneDriveRemovalPolicyIsComplete {
    $policy = $script:RegistryTweaks | Where-Object id -eq 'onedrive-policy' | Select-Object -First 1
    if (-not $policy) {
        Add-SmokeFailure 'Expected onedrive-policy registry tweak to exist.'
        return
    }
    foreach ($expected in @(
            'DisableFileSync',
            'DisableFileSyncNGSC',
            'DisablePersonalSync',
            'DisableLibrariesDefaultSaveToOneDrive',
            'System.IsPinnedToNameSpaceTree',
            'Desktop',
            'Personal',
            'My Pictures',
            '{374DE290-123F-4565-9164-39C4925E467B}'
        )) {
        if (@($policy.set | Where-Object name -eq $expected).Count -eq 0) {
            Add-SmokeFailure "Expected OneDrive removal policy to set $expected."
        }
    }
    $values = @($policy.set | ForEach-Object { [string]$_.value })
    foreach ($forbidden in @('OneDrive\Documents', 'OneDrive\Desktop', 'OneDrive\Pictures')) {
        if (@($values | Where-Object { $_ -like "*$forbidden*" }).Count -gt 0) {
            Add-SmokeFailure "OneDrive removal policy must not point known folders at $forbidden."
        }
    }
    if (@($policy.set | Where-Object { [string]$_.path -like '*\Shell Folders' -and [string]$_.value -like 'C:\Users\Default\*' }).Count -gt 0) {
        Add-SmokeFailure 'OneDrive removal policy must not write literal C:\Users\Default shell folder values.'
    }

    $firstLogonText = Get-WinMintFirstLogonText
    $setupCompleteText = Get-WinMintSetupCompleteText
    $stagingText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Private\Image\Staging.ps1') -Raw
    $offlineOneDriveManifestText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Private\Manifest.ps1') -Raw
    $offlineOneDriveText = $stagingText + "`n" + $offlineOneDriveManifestText
    $pipelineText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Private\Pipeline.ps1') -Raw
    foreach ($expected in @(
            'FirstLogon_OneDriveAudit.json',
            'FirstLogon_KnownFolders.json',
            'OneDriveSetup.exe.bak',
            'takeown.exe /f $setupFile',
            'icacls.exe $setupFile',
            'Remove-Item -LiteralPath $setupFile',
            'Active Setup\Installed Components',
            'StartupApproved\Run',
            'SyncRootManager',
            'App Paths',
            'registryResidue',
            'runResidue',
            'Unregister-ScheduledTask',
            "oneDriveAudit['compliant']"
        )) {
        if ($firstLogonText -notlike "*$expected*") {
            Add-SmokeFailure "Expected FirstLogon OneDrive cleanup to include $expected."
        }
    }
    foreach ($expected in @(
            'OneDriveSetup.exe.bak',
            'takeown.exe /f $setupFile',
            'icacls.exe $setupFile',
            'Remove-Item -LiteralPath $setupFile',
            'Active Setup\Installed Components',
            'StartupApproved\Run',
            'SyncRootManager',
            'App Paths',
            'Unregister-ScheduledTask'
        )) {
        if ($setupCompleteText -notlike "*$expected*") {
            Add-SmokeFailure "Expected SetupComplete OneDrive cleanup to include $expected."
        }
    }
    foreach ($expected in @(
            'Remove-WinMintOneDriveSetupStub',
            'Windows\System32\OneDriveSetup.exe',
            'Windows\SysWOW64\OneDriveSetup.exe',
            'oneDriveSetupStubs',
            'users can reinstall OneDrive later'
        )) {
        if ($offlineOneDriveText -notlike "*$expected*") {
            Add-SmokeFailure "Expected offline OneDrive setup-stub removal to include $expected."
        }
    }
    if ($pipelineText -notlike '*Remove-WinMintOneDriveSetupStub -MountDir $mountDir*') {
        Add-SmokeFailure 'Expected ISO pipeline to remove OneDrive setup stubs from the offline image.'
    }
}

function Assert-CursorInstallUsesModernRegistryContract {
    $catalogPath = Join-Path $root 'src\runtime\image\Private\Catalog.ps1'
    $assetsPath = Join-Path $root 'src\runtime\image\Private\Image\Assets.ps1'
    $assetsText = Get-Content -LiteralPath $assetsPath -Raw
    $firstLogonText = Get-WinMintFirstLogonText

    $expectedOrder = @(
        'Arrow.cur', 'Help.cur', 'Work.ani', 'Busy.ani', 'Cross.cur', 'IBeam.cur', 'Handwriting.cur', 'Unavailable.cur',
        'SizeNS.cur', 'SizeWE.cur', 'SizeNWSE.cur', 'SizeNESW.cur', 'Move.cur', 'Alternate.cur', 'Link.cur',
        'Pin.cur', 'Person.cur'
    )
    if (@($script:Win11IsoCursorSchemeOrder).Count -ne 17 -or
        (@(Compare-Object -ReferenceObject $expectedOrder -DifferenceObject $script:Win11IsoCursorSchemeOrder -SyncWindow 0).Count -ne 0)) {
        Add-SmokeFailure 'Windows 11 Modern cursor scheme must use the modern 17-slot Windows cursor order.'
    }

    $expectedNames = @(
        'Arrow', 'Help', 'AppStarting', 'Wait', 'Crosshair', 'IBeam', 'NWPen', 'No',
        'SizeNS', 'SizeWE', 'SizeNWSE', 'SizeNESW', 'SizeAll', 'UpArrow', 'Hand', 'Pin', 'Person'
    )
    $actualNames = @($script:Win11IsoCursorRegistryPairs | ForEach-Object { [string]$_.Name })
    if (@(Compare-Object -ReferenceObject $expectedNames -DifferenceObject $actualNames -SyncWindow 0).Count -ne 0) {
        Add-SmokeFailure 'Cursor registry values must only use documented Windows cursor slot names.'
    }

    foreach ($forbiddenName in @('precisionhair', 'Grab', 'Grabbing', 'Pan', 'Zoom-in', 'Zoom-out')) {
        if ($actualNames -contains $forbiddenName) {
            Add-SmokeFailure "Cursor registry values must not include nonstandard cursor slot name: $forbiddenName."
        }
    }
    foreach ($forbiddenHook in @('CursorShadow', 'InstallHinfSection', 'rundll32', 'SystemParametersInfo', 'Active Setup')) {
        if ($assetsText -match [regex]::Escape($forbiddenHook)) {
            Add-SmokeFailure "Cursor installation must not rely on nonstandard cursor hooks or side effects: $forbiddenHook."
        }
    }
    foreach ($expected in @('HKLM\peNTUSER', 'Control Panel\Cursors\Schemes', 'Default user cursor scheme applied')) {
        if ($assetsText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Cursor installation must write the Windows 11 user-scheme contract field '$expected'."
        }
    }
    if ($assetsText -notmatch '/v "\$schemeName" /t REG_EXPAND_SZ') {
        Add-SmokeFailure 'Cursor scheme list must be written as REG_EXPAND_SZ because it uses %SystemRoot% paths.'
    }
    foreach ($expected in @('Set-WinMintFirstLogonCursorScheme', 'HKCU\Control Panel\Cursors\Schemes', 'HKCU\Control Panel\Cursors', 'SPI_SETCURSORS', 'Live user cursor scheme applied')) {
        if ($firstLogonText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "FirstLogon should apply the cursor scheme to the live user profile with '$expected'."
        }
    }
}

function Assert-RegistryTweakMetadataAndRollback {
    $publicPath = Join-Path $root 'config\tweaks.json'
    $public = Get-Content -LiteralPath $publicPath -Raw | ConvertFrom-Json
    $publicTweaks = @($public.tweaks)
    $publicIds = @($publicTweaks | ForEach-Object { [string]$_.id })
    $executableIds = @($script:RegistryTweaks | ForEach-Object { [string]$_.id })

    foreach ($expectedFunction in @(
            'Assert-WinMintRegistryTweakCatalog',
            'Invoke-WinMintRegistryOperation',
            'Assert-WinMintRegistryDeleteTarget'
        )) {
        if (-not (Get-Command $expectedFunction -ErrorAction SilentlyContinue)) {
            Add-SmokeFailure "Registry tweak backend should expose '$expectedFunction'."
        }
    }
    try {
        Assert-WinMintRegistryTweakCatalog
    }
    catch {
        Add-SmokeFailure "Registry tweak catalog static safety validation failed: $($_.Exception.Message)"
    }

    foreach ($group in @($script:RegistryTweaks)) {
        $id = [string]$group.id
        if ($publicIds -notcontains $id) {
            Add-SmokeFailure "Executable registry tweak '$id' must have public metadata in config\tweaks.json."
        }
        foreach ($field in @('id', 'description', 'scope', 'risk', 'reversible', 'phase', 'intent')) {
            $value = Get-WinMintProfileSetting $group $field $null
            if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
                Add-SmokeFailure "Registry tweak '$id' must define metadata field '$field'."
            }
        }
        if ([bool](Get-WinMintProfileSetting $group 'reversible' $false)) {
            foreach ($entry in @(Get-WinMintProfileSetting $group 'set' @())) {
                $setPath = [string](Get-WinMintProfileSetting $entry 'path' '')
                $setName = [string](Get-WinMintProfileSetting $entry 'name' '')
                $opLabel = if ([string]::IsNullOrWhiteSpace($setName)) { $setPath } else { "$setPath\$setName" }
                $irreversible = [bool](Get-WinMintProfileSetting $entry 'irreversible' $false)
                $irreversibleReason = [string](Get-WinMintProfileSetting $entry 'irreversibleReason' '')
                $undo = Get-WinMintProfileSetting $entry 'undo' $null
                if ($irreversible) {
                    if ([string]::IsNullOrWhiteSpace($irreversibleReason)) {
                        Add-SmokeFailure "Reversible registry tweak '$id' set op '$opLabel' marks irreversible without irreversibleReason."
                    }
                    continue
                }
                if ($null -eq $undo) {
                    Add-SmokeFailure "Reversible registry tweak '$id' set op '$opLabel' must define undo (or irreversible + irreversibleReason)."
                    continue
                }
                $undoAction = [string](Get-WinMintProfileSetting $undo 'action' '')
                $undoType = [string](Get-WinMintProfileSetting $undo 'type' '')
                $hasDelete = $undoAction -eq 'delete'
                $hasRestoreValue = -not [string]::IsNullOrWhiteSpace($undoType) -and ($null -ne (Get-WinMintProfileSetting $undo 'value' $null))
                if ($hasDelete -eq $hasRestoreValue) {
                    Add-SmokeFailure "Reversible registry tweak '$id' set op '$opLabel' undo must be action=delete XOR type+value."
                }
            }
            foreach ($entry in @(Get-WinMintProfileSetting $group 'remove' @())) {
                $removePath = [string](Get-WinMintProfileSetting $entry 'path' '')
                $irreversible = [bool](Get-WinMintProfileSetting $entry 'irreversible' $false)
                $irreversibleReason = [string](Get-WinMintProfileSetting $entry 'irreversibleReason' '')
                $restore = Get-WinMintProfileSetting $entry 'restore' $null
                if ($irreversible) {
                    if ([string]::IsNullOrWhiteSpace($irreversibleReason)) {
                        Add-SmokeFailure "Reversible registry tweak '$id' remove op '$removePath' marks irreversible without irreversibleReason."
                    }
                    continue
                }
                if ($null -eq $restore) {
                    Add-SmokeFailure "Reversible registry tweak '$id' remove op '$removePath' must define restore (or irreversible + irreversibleReason)."
                }
            }
        }
        $registryOperations = @((Get-WinMintProfileSetting (Get-WinMintProfileSetting $group 'operations' @{}) 'registry' @()))
        if ($registryOperations.Count -ne (@($group.set).Count + @($group.remove).Count)) {
            Add-SmokeFailure "Registry tweak '$id' must expose a typed operations.registry DOM matching set/remove entries."
        }
        foreach ($operation in $registryOperations) {
            foreach ($field in @('kind', 'phase', 'hive', 'subPath', 'path')) {
                $value = Get-WinMintProfileSetting $operation $field $null
                if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
                    Add-SmokeFailure "Registry tweak '$id' operation must define '$field'."
                }
            }
            if ([string](Get-WinMintProfileSetting $operation 'phase' '') -ne 'offline-image') {
                Add-SmokeFailure "Registry tweak '$id' operation phase must currently be offline-image."
            }
        }
    }

    foreach ($publicTweak in $publicTweaks) {
        $id = [string]$publicTweak.id
        $docOnly = [bool](Get-WinMintProfileSetting $publicTweak 'documentationOnly' $false)
        if ($executableIds -notcontains $id -and -not $docOnly) {
            Add-SmokeFailure "Public tweak '$id' must map to an executable tweak or be marked documentationOnly."
        }
        foreach ($field in @('id', 'description', 'scope', 'risk', 'reversible', 'phase', 'intent')) {
            $value = Get-WinMintProfileSetting $publicTweak $field $null
            if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
                Add-SmokeFailure "Public tweak '$id' must define metadata field '$field'."
            }
        }
    }

    $hardware = $script:RegistryTweaks | Where-Object id -eq 'hardware-bypass' | Select-Object -First 1
    if (-not $hardware) {
        Add-SmokeFailure 'Expected hardware-bypass registry tweak to exist.'
    }
    elseif ([string]$hardware.risk -ne 'medium') {
        Add-SmokeFailure 'hardware-bypass must remain medium risk.'
    }

    $defaultConfig = New-WinMintBuildConfig -BuildProfile (New-SmokeBuildProfile)
    if (@($defaultConfig.RegistryTweaks) -contains 'hardware-bypass') {
        Add-SmokeFailure 'hardware-bypass must remain opt-in and absent from default registry tweaks.'
    }
    if (@($defaultConfig.RegistryTweaks) -contains 'uac-no-secure-desktop') {
        Add-SmokeFailure 'Default registry tweaks must not disable UAC secure desktop.'
    }
    if (@($script:RegistryTweaks | Where-Object id -eq 'uac-no-secure-desktop').Count -gt 0) {
        Add-SmokeFailure 'uac-no-secure-desktop must not remain as an executable tweak.'
    }
    foreach ($forbiddenUacName in @('EnableLUA', 'ConsentPromptBehaviorAdmin', 'PromptOnSecureDesktop')) {
        if (@($script:RegistryTweaks | ForEach-Object { @($_.set) } | Where-Object name -eq $forbiddenUacName).Count -gt 0) {
            Add-SmokeFailure "WinMint default tweak catalog must not stamp UAC value '$forbiddenUacName'."
        }
    }

    $cloudContent = $script:RegistryTweaks | Where-Object id -eq 'cloud-content-policy' | Select-Object -First 1
    if (-not $cloudContent) {
        Add-SmokeFailure 'Expected cloud-content-policy registry tweak to exist.'
    }
    else {
        foreach ($expected in @(
                'DisableCloudOptimizedContent',
                'DisableConsumerAccountStateContent',
                'DisableSoftLanding',
                'DisableWindowsConsumerFeatures',
                'DisableWindowsSpotlightFeatures',
                'DisableWindowsSpotlightOnActionCenter',
                'DisableWindowsSpotlightOnSettings',
                'DisableWindowsSpotlightWindowsWelcomeExperience',
                'DisableShareAppPromotions',
                'DisableInlineCompose'
            )) {
            if (@($cloudContent.set | Where-Object name -eq $expected).Count -eq 0) {
                Add-SmokeFailure "Cloud content policy should stamp '$expected'."
            }
        }
        if (@($defaultConfig.RegistryTweaks) -notcontains 'cloud-content-policy') {
            Add-SmokeFailure 'cloud-content-policy must apply by default.'
        }
    }

    $quietUxText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\FirstLogon.Desktop.ps1') -Raw
    $defaultUserText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\DefaultUser.ps1') -Raw
    $specializeTextForQuiet = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\Specialize.ps1') -Raw
    $cloudTweakText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Private\Image\Tweaks\34-cloud-content-policy.ps1') -Raw
    foreach ($expected in @('Home-effective quiet UX', 'ContentDeliveryManager', 'Set-WinMintFirstLogonQuietUxDefaults')) {
        if ($quietUxText -notmatch [regex]::Escape($expected) -and $cloudTweakText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Home quiet UX source of truth should document '$expected'."
        }
    }
    if ($defaultUserText -notmatch 'ContentDeliveryManager') {
        Add-SmokeFailure 'DefaultUser must stamp ContentDeliveryManager as the Home quiet UX path.'
    }
    if ($specializeTextForQuiet -match 'DisableCloudOptimizedContent' -or $specializeTextForQuiet -match 'DisableSoftLanding') {
        Add-SmokeFailure 'Specialize must not duplicate CloudContent quiet stamps; Home quiet UX is ContentDeliveryManager.'
    }

    $driverCoInstaller = $script:RegistryTweaks | Where-Object id -eq 'driver-coinstaller-policy' | Select-Object -First 1
    if (-not $driverCoInstaller) {
        Add-SmokeFailure 'Expected driver-coinstaller-policy registry tweak to exist.'
    }
    else {
        $match = @($driverCoInstaller.set | Where-Object {
                [string]$_.path -eq 'zSOFTWARE\Microsoft\Windows\CurrentVersion\Device Installer' -and
                [string]$_.name -eq 'DisableCoInstallers' -and
                [string]$_.value -eq '1'
            })
        if ($match.Count -eq 0) {
            Add-SmokeFailure 'driver-coinstaller-policy must stamp DisableCoInstallers=1 under Device Installer.'
        }
        if (@($defaultConfig.RegistryTweaks) -notcontains 'driver-coinstaller-policy') {
            Add-SmokeFailure 'driver-coinstaller-policy must apply by default.'
        }
    }

    $deviceMetadata = $script:RegistryTweaks | Where-Object id -eq 'device-metadata-policy' | Select-Object -First 1
    if (-not $deviceMetadata) {
        Add-SmokeFailure 'Expected device-metadata-policy registry tweak to exist.'
    }
    else {
        $match = @($deviceMetadata.set | Where-Object {
                [string]$_.path -eq 'zSOFTWARE\Policies\Microsoft\Windows\Device Metadata' -and
                [string]$_.name -eq 'PreventDeviceMetadataFromNetwork' -and
                [string]$_.value -eq '1'
            })
        if ($match.Count -eq 0) {
            Add-SmokeFailure 'device-metadata-policy must stamp PreventDeviceMetadataFromNetwork=1 under Device Metadata policy.'
        }
        if (@($defaultConfig.RegistryTweaks) -notcontains 'device-metadata-policy') {
            Add-SmokeFailure 'device-metadata-policy must apply by default.'
        }
    }

    $gamebar = $script:RegistryTweaks | Where-Object id -eq 'gamebar-policy' | Select-Object -First 1
    if (-not $gamebar) {
        Add-SmokeFailure 'Expected gamebar-policy registry tweak to exist.'
    }
    else {
        foreach ($protocol in @('ms-gamebar', 'ms-gamebarservices')) {
            $rootPath = "zSOFTWARE\Classes\$protocol"
            $commandPath = "$rootPath\shell\open\command"
            foreach ($expected in @(
                    @{ path = $rootPath; name = 'URL Protocol' },
                    @{ path = $rootPath; name = 'NoOpenWith' },
                    @{ path = $commandPath; name = '' }
                )) {
                $match = @($gamebar.set | Where-Object {
                        [string]$_.path -eq [string]$expected.path -and
                        [string]$_.name -eq [string]$expected.name
                    })
                if ($match.Count -eq 0) {
                    Add-SmokeFailure "gamebar-policy must stamp '$($expected.name)' under $($expected.path)."
                }
            }
        }
    }

    $explorer = $script:RegistryTweaks | Where-Object id -eq 'explorer-qol' | Select-Object -First 1
    if (-not $explorer) {
        Add-SmokeFailure 'Expected explorer-qol registry tweak to exist.'
    }
    else {
        foreach ($expected in @(
                @{ path = 'zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; name = 'HideFileExt'; value = '0' },
                @{ path = 'zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; name = 'Hidden'; value = '1' },
                @{ path = 'zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; name = 'LaunchTo'; value = '2' },
                @{ path = 'zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; name = 'FullPathAddress'; value = '1' },
                @{ path = 'zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; name = 'ShowFrequent'; value = '0' },
                @{ path = 'zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; name = 'ShowSyncProviderNotifications'; value = '0' },
                @{ path = 'zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; name = 'NavPaneShowVersionControl'; value = '1' },
                @{ path = 'zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer'; name = 'ShowRecent'; value = '0' },
                @{ path = 'zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer'; name = 'ShowCloudFilesInQuickAccess'; value = '0' },
                @{ path = 'zNTUSER\Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}'; name = 'System.IsPinnedToNameSpaceTree'; value = '0' }
            )) {
            $match = @($explorer.set | Where-Object {
                    [string]$_.path -eq [string]$expected.path -and
                    [string]$_.name -eq [string]$expected.name -and
                    [string]$_.value -eq [string]$expected.value
                })
            if ($match.Count -eq 0) {
                Add-SmokeFailure "Explorer QoL tweak must stamp $($expected.name) at $($expected.path)."
            }
        }
        if (@($explorer.set | Where-Object { [string]$_.path -like '*{f874310e-b6b7-47dc-bc84-b9e6b38f5903}*' }).Count -gt 0) {
            Add-SmokeFailure 'Explorer QoL tweak must not hide Home from the navigation pane.'
        }
    }

    $taskbarEndTask = $script:RegistryTweaks | Where-Object id -eq 'taskbar-endtask' | Select-Object -First 1
    if (-not $taskbarEndTask) {
        Add-SmokeFailure 'Expected taskbar-endtask registry tweak to exist.'
    }
    else {
        $endTaskPath = 'zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'
        $match = @($taskbarEndTask.set | Where-Object {
                [string]$_.path -eq $endTaskPath -and
                [string]$_.name -eq 'TaskbarEndTask' -and
                [string]$_.value -eq '1'
            })
        if ($match.Count -eq 0) {
            Add-SmokeFailure 'taskbar-endtask must stamp TaskbarEndTask=1 under Explorer\Advanced\TaskbarDeveloperSettings.'
        }
        if (@($taskbarEndTask.set | Where-Object {
                    [string]$_.path -eq 'zNTUSER\Software\Microsoft\Windows\CurrentVersion\TaskbarDeveloperSettings'
                }).Count -gt 0) {
            Add-SmokeFailure 'taskbar-endtask must not use the stale CurrentVersion\TaskbarDeveloperSettings path.'
        }
    }

    $folderDiscovery = $script:RegistryTweaks | Where-Object id -eq 'explorer-folder-discovery' | Select-Object -First 1
    if (-not $folderDiscovery) {
        Add-SmokeFailure 'Expected explorer-folder-discovery registry tweak to exist.'
    }
    else {
        $folderTypePath = 'zNTUSER\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell'
        $match = @($folderDiscovery.set | Where-Object {
                [string]$_.path -eq $folderTypePath -and
                [string]$_.name -eq 'FolderType' -and
                [string]$_.type -eq 'REG_SZ' -and
                [string]$_.value -eq 'NotSpecified'
            })
        if ($match.Count -eq 0) {
            Add-SmokeFailure 'explorer-folder-discovery must stamp FolderType=NotSpecified under Bags\AllFolders\Shell.'
        }
        else {
            $undo = $match[0].undo
            $undoAction = if ($undo -is [hashtable]) { [string]$undo['action'] } else { [string]$undo.action }
            if ($undoAction -ne 'delete') {
                Add-SmokeFailure 'explorer-folder-discovery FolderType undo must be action=delete.'
            }
        }
        if (@($defaultConfig.RegistryTweaks) -notcontains 'explorer-folder-discovery') {
            Add-SmokeFailure 'explorer-folder-discovery must apply by default.'
        }
    }
}

function Assert-SetupRegistryStampsAreIdempotent {
    $defaultUserPath = Join-Path $root 'src\runtime\setup\DefaultUser.ps1'
    $specializePath = Join-Path $root 'src\runtime\setup\Specialize.ps1'
    $defaultUserText = Get-Content -LiteralPath $defaultUserPath -Raw
    $specializeText = Get-Content -LiteralPath $specializePath -Raw

    foreach ($expected in @(
            'function Set-DefaultUserRegistryValue',
            'function Set-DefaultUserRegistryDefaultValue',
            'function Remove-DefaultUserRegistryValue',
            'function Invoke-DefaultUserRegistrySet',
            'LaunchTo',
            'Start_TrackProgs',
            'SubscribedContent-310093Enabled',
            'SubscribedContent-338388Enabled',
            'SubscribedContent-338389Enabled',
            'SubscribedContent-353698Enabled',
            'SoftLandingEnabled',
            'SystemPaneSuggestionsEnabled',
            'ScoobeSystemSettingEnabled',
            'TaskbarMn',
            'ShowCopilotButton',
            'Start_AccountNotifications',
            'EnableAutoTray',
            'RotatingLockScreenEnabled',
            'RotatingLockScreenOverlayEnabled'
        )) {
        if ($defaultUserText -notlike "*$expected*") {
            Add-SmokeFailure "DefaultUser.ps1 should idempotently stamp '$expected'."
        }
    }
    # TaskbarDa (Widgets hide) is stamped via Set-DefaultUserRegistryValue which logs ACL
    # failures to DefaultUser_errors.log and continues — must stay non-fatal (script loop catch).
    if ($defaultUserText -notmatch 'TaskbarDa') {
        Add-SmokeFailure 'DefaultUser.ps1 should stamp TaskbarDa (Widgets hide).'
    }
    if ($defaultUserText -notmatch 'DefaultUser_errors\.log') {
        Add-SmokeFailure 'DefaultUser.ps1 must log registry ACL failures to DefaultUser_errors.log without aborting the stamp loop.'
    }
    if ($defaultUserText -notmatch 'try \{ & \$s \} catch') {
        Add-SmokeFailure 'DefaultUser.ps1 stamp loop must catch per-entry failures (TaskbarDa ACL noise must remain non-fatal).'
    }
    if ($defaultUserText -notmatch 'LaunchTo\s+-Type\s+REG_DWORD\s+-Data\s+2') {
        Add-SmokeFailure 'DefaultUser.ps1 LaunchTo must be Home (Data 2), matching offline explorer-qol.'
    }
    if ($defaultUserText -match 'LaunchTo\s+-Type\s+REG_DWORD\s+-Data\s+1') {
        Add-SmokeFailure 'DefaultUser.ps1 must not stamp LaunchTo=1 (This PC); Home (2) is the product default.'
    }

    foreach ($expected in @(
            'function Set-SpecializeRegistryValue',
            'function Invoke-SpecializeRegistrySet',
            'CEIPEnable',
            'AITEnable',
            'DisableInventory',
            'SettingsPageVisibility',
            'hide:home',
            'DeliveryOptimization',
            'DODownloadMode'
        )) {
        if ($specializeText -notlike "*$expected*") {
            Add-SmokeFailure "Specialize.ps1 should idempotently stamp '$expected'."
        }
    }
    if ($specializeText -notmatch 'DODownloadMode[\s\S]{0,220}-Data\s+0') {
        Add-SmokeFailure 'Specialize.ps1 should set DODownloadMode to 0 to disable Delivery Optimization peer-to-peer.'
    }

    foreach ($forbidden in @('ConsentPromptBehaviorAdmin', 'EnableLUA', 'DisableWindowsConsumerFeatures')) {
        if ($defaultUserText -like "*$forbidden*" -or $specializeText -like "*$forbidden*") {
            Add-SmokeFailure "Setup registry stamps must not include '$forbidden'."
        }
    }
}

function Assert-DefaultUserTaskbarPinsIncludeTerminal {
    $defaultUserPath = Join-Path $root 'src\runtime\setup\DefaultUser.ps1'
    $defaultUserText = Get-Content -LiteralPath $defaultUserPath -Raw
    if ($defaultUserText -notmatch 'Microsoft\.Windows\.Explorer') {
        Add-SmokeFailure 'DefaultUser taskbar layout must keep File Explorer pinned.'
    }
    if ($defaultUserText -notmatch 'Microsoft\.WindowsTerminal_8wekyb3d8bbwe!App') {
        Add-SmokeFailure 'DefaultUser taskbar layout must pin Windows Terminal.'
    }
    if ($defaultUserText -match 'stock pins .*re-pins only File Explorer') {
        Add-SmokeFailure 'DefaultUser taskbar pin comment must mention Windows Terminal as a baseline pin.'
    }
}

function Assert-WinMintBloomWallpaperCoversDesktopAndLockScreen {
    $unattendText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\image\Private\Image\Unattend.ps1') -Raw
    $specializeText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\Specialize.ps1') -Raw
    $defaultUserText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\DefaultUser.ps1') -Raw
    $firstLogonText = Get-WinMintFirstLogonText

    foreach ($expected in @(
        'assets\runtime\wallpaper\img0.jpg',
        'assets\runtime\wallpaper\img100.jpg',
        'Windows\Web\Wallpaper\Windows\WinMint-Bloom.jpg',
        'Windows\Web\Screen\WinMint-Lock.jpg',
        'LockScreenImage',
        'WallpaperStyle',
        'TileWallpaper',
        'user.bmp'
    )) {
        if ($unattendText -notmatch [regex]::Escape($expected) -and
            $specializeText -notmatch [regex]::Escape($expected) -and
            $defaultUserText -notmatch [regex]::Escape($expected) -and
            $firstLogonText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Desktop/lock/account imagery should be staged through stock Windows locations: '$expected'."
        }
    }
    foreach ($forbidden in @(
        'Windows\Web\Wallpaper\WinMint',
        'WinMint-Bloom-OLED.png',
        'WslIcons',
        'AccountPictures',
        'SetUserTile'
    )) {
        if ($unattendText -match [regex]::Escape($forbidden) -or
            $specializeText -match [regex]::Escape($forbidden) -or
            $defaultUserText -match [regex]::Escape($forbidden) -or
            $firstLogonText -match [regex]::Escape($forbidden)) {
            Add-SmokeFailure "Installed system imagery must not create WinMint-specific system folders or names: '$forbidden'."
        }
    }

    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $expectedPictures = @{
            'user.bmp' = 448
            'user.png' = 448
            'user-192.png' = 192
            'user-48.png' = 48
            'user-40.png' = 40
            'user-32.png' = 32
        }
        foreach ($name in $expectedPictures.Keys) {
            $path = Join-Path $root "assets\runtime\accountpicture\$name"
            if (-not (Test-Path -LiteralPath $path)) {
                Add-SmokeFailure "Default account picture asset is missing: $name."
                continue
            }
            $image = [System.Drawing.Image]::FromFile($path)
            try {
                $size = [int]$expectedPictures[$name]
                if ($image.Width -ne $size -or $image.Height -ne $size) {
                    Add-SmokeFailure "Default account picture '$name' should be ${size}x${size}; got $($image.Width)x$($image.Height)."
                }
            }
            finally {
                $image.Dispose()
            }
        }
    }
    catch {
        Add-SmokeFailure "Default account picture dimensions could not be verified: $($_.Exception.Message)"
    }
}

function Assert-WindowsTerminalDefaultsPwsh7NoLogo {
    $settingsPath = Join-Path $root 'assets\runtime\windows-terminal\settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        Add-SmokeFailure 'Windows Terminal settings asset is missing.'
        return
    }
    $settingsText = Get-Content -LiteralPath $settingsPath -Raw
    foreach ($expected in @(
        'PowerShell',
        'defaultProfile',
        '-NoLogo',
        'pwsh.exe',
        'Cascadia Code NF',
        'One Half Dark',
        'bellStyle',
        'centerOnLaunch',
        '"launchMode": "default"',
        '"opacity": 80',
        '"useAcrylic": false',
        '"trimPaste": true',
        '"snapOnInput": true',
        '"font"',
        'disabledProfileSources',
        'Windows.Terminal.PowershellCore',
        'Windows.Terminal.Wsl',
        'Windows.Terminal.Azure',
        'Windows.Terminal.SSH',
        'Windows.Terminal.WindowsPowerShell',
        'Windows.Terminal.VisualStudio',
        '"firstWindowPreference": "defaultProfile"'
    )) {
        if ($settingsText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Windows Terminal settings should contain '$expected'."
        }
    }
    if ($settingsText -match 'defaultNewWindow') {
        Add-SmokeFailure 'Windows Terminal settings must not use invalid firstWindowPreference defaultNewWindow.'
    }
    foreach ($forbidden in @('"hidden": true', 'Command Prompt', 'Windows PowerShell', 'Azure Cloud Shell')) {
        if ($settingsText -match [regex]::Escape($forbidden)) {
            Add-SmokeFailure "Windows Terminal settings should not contain stock profile '$forbidden'."
        }
    }
    try {
        $settings = $settingsText | ConvertFrom-Json
        if ([string]$settings.profiles.defaults.colorScheme -ne 'One Half Dark') {
            Add-SmokeFailure 'Windows Terminal default profile color scheme should be One Half Dark.'
        }
        if ([string]$settings.profiles.defaults.bellStyle -ne 'none') {
            Add-SmokeFailure 'Windows Terminal audible bell should be disabled by default.'
        }
        if (-not [bool]$settings.centerOnLaunch) {
            Add-SmokeFailure 'Windows Terminal should be centered on launch by default.'
        }
        if ([string]$settings.launchMode -ne 'default') {
            Add-SmokeFailure 'Windows Terminal launchMode should be default (windowed), not maximized/fullscreen.'
        }
        if ([int]$settings.profiles.defaults.opacity -ne 80) {
            Add-SmokeFailure 'Windows Terminal default opacity should be 80.'
        }
        $profiles = @($settings.profiles.list)
        if ($profiles.Count -ne 1 -or [string]$profiles[0].name -ne 'PowerShell') {
            Add-SmokeFailure 'Windows Terminal settings should ship exactly one base profile named PowerShell.'
        }
    }
    catch {
        Add-SmokeFailure "Windows Terminal settings should be valid JSON: $($_.Exception.Message)"
    }
}

function Assert-StaticTextContainsAll {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$FailurePrefix
    )

    foreach ($expected in @(
        $Expected
    )) {
        if ($Text -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "$FailurePrefix '$expected'."
        }
    }
}

function Assert-OfflinePowerShell7StagingContract {
    param([Parameter(Mandatory)][string]$PackagesText)

    Assert-StaticTextContainsAll -Text $PackagesText -FailurePrefix 'Offline PowerShell 7 staging should contain' -Expected @(
        'function Assert-OfflinePowerShell7Staged',
        'function Add-OfflineMachinePathEntry',
        '%ProgramFiles%\PowerShell\7',
        'Resolve-WinMintGitHubReleasePayload',
        'PowerShell/PowerShell',
        'PowerShell-\d+\.\d+\.\d+-',
        "[version]'7.6.0'",
        'PowerShell 7.6.0+ staged',
        'PowerShell 7.6.0+ is missing from the offline image',
        'PowerShell 7.6.0+ staging failed; build cannot continue',
        'Prefer newest release',
        'Staged PowerShell'
    )
    if ($PackagesText -match 'fall back to Windows PowerShell') {
        Add-SmokeFailure 'PowerShell 7 staging must fail the build instead of falling back to Windows PowerShell.'
    }
}

function Assert-ServiceWimRequiresBundledPowerShell7 {
    $pipelineText = Get-WinMintRepositoryText 'src\runtime\image\Private\Pipeline.ps1'
    if ($pipelineText -notmatch 'Assert-OfflinePowerShell7Staged\s+-MountDir\s+\$mountDir') {
        Add-SmokeFailure 'Service WIM pipeline must assert bundled PowerShell 7 after servicing or serviced-WIM cache restore.'
    }

    $cacheText = Get-WinMintRepositoryText 'src\runtime\image\Private\IntermediatesCache.ps1'
    if ($cacheText -notmatch '\$script:WinMintServicedWimCacheSchemaVersion\s*=\s*18') {
        Add-SmokeFailure 'Serviced-WIM cache schema should be 18 (ImageCompression/cleanup lane in fingerprint).'
    }
    if ($cacheText -notmatch 'ImageCompression') {
        Add-SmokeFailure 'Serviced-WIM fingerprint must include ImageCompression so Max cleanup is not reused across quality lanes.'
    }
    $packagesText = Get-WinMintRepositoryText 'src\runtime\image\Private\Image\Packages.ps1'
    if ($packagesText -notmatch '\[switch\]\$SkipComponentCleanup') {
        Add-SmokeFailure 'Save-ImageWithCleanup must support -SkipComponentCleanup for serviced-WIM cache hits.'
    }
    $pipelineTextForCache = Get-WinMintRepositoryText 'src\runtime\image\Private\Pipeline.ps1'
    if ($pipelineTextForCache -notmatch 'SkipComponentCleanup:\(\$null\s*-ne\s*\$servicedWimCacheHit\)') {
        Add-SmokeFailure 'Pipeline must skip Max component cleanup on serviced-WIM cache hits.'
    }
}

function Assert-SetupCompleteCmdRequiresBundledPowerShell7 {
    param([Parameter(Mandatory)][string]$SetupCompleteCmd)

    Assert-StaticTextContainsAll -Text $SetupCompleteCmd -FailurePrefix 'SetupComplete.cmd should require staged PowerShell 7 with' -Expected @(
        '%ProgramFiles%\PowerShell\7\pwsh.exe',
        'PowerShell 7.6.0+ is required',
        'exit /b 1'
    )
    if ($SetupCompleteCmd -match 'powershell\.exe[\s\S]{0,160}SetupComplete\.ps1') {
        Add-SmokeFailure 'SetupComplete.cmd must not run SetupComplete.ps1 under Windows PowerShell when PowerShell 7 is missing.'
    }
}

function Assert-SetupCompleteRegistersFirstLogonUnderPowerShell7 {
    param([Parameter(Mandatory)][string]$SetupCompleteText)

    Assert-StaticTextContainsAll -Text $SetupCompleteText -FailurePrefix 'SetupComplete.ps1 should register FirstLogon under PowerShell 7 with' -Expected @(
        "Join-Path `$env:ProgramFiles 'PowerShell\7\pwsh.exe'",
        'PowerShell 7.6.0+ is required for FirstLogon',
        '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File',
        'under PowerShell 7.6.0+'
    )
    if ($SetupCompleteText -match 'runOnceCommand\s*=\s*"powershell\.exe') {
        Add-SmokeFailure 'SetupComplete.ps1 must not register FirstLogon RunOnce under Windows PowerShell.'
    }
}

function Assert-SetupCompleteToolchainDoesNotInstallPowerShell7Fallback {
    param([Parameter(Mandatory)][string]$ToolchainText)

    if ($ToolchainText -match 'Microsoft\.PowerShell') {
        Add-SmokeFailure 'SetupComplete toolchain must not install PowerShell 7 via winget; PowerShell 7 is bundled offline and required before SetupComplete.ps1 runs.'
    }
}

function Assert-FirstLogonRuntimeRequiresPowerShell7 {
    param([Parameter(Mandatory)][string]$FirstLogonBootstrapText)

    Assert-StaticTextContainsAll -Text $FirstLogonBootstrapText -FailurePrefix 'FirstLogon bootstrap should fail closed around PowerShell 7.6.0+ with' -Expected @(
        'Get-WinMintMinimumPowerShellVersion',
        'Test-WinMintPowerShellHostMeetsMinimum',
        'Install-WinMintFirstLogonPowerShellMinimum',
        'PowerShell $minimum+ is required for FirstLogon',
        're-launch failed',
        'ExitCode = 1'
    )
    if ($FirstLogonBootstrapText -match 'continuing under Windows PowerShell') {
        Add-SmokeFailure 'FirstLogon bootstrap must not continue under Windows PowerShell after PowerShell 7 handoff fails.'
    }
    if ($FirstLogonBootstrapText -match 'PSVersion\.Major\s+-lt\s+7') {
        Add-SmokeFailure 'FirstLogon bootstrap must require PowerShell 7.6.0+, not only Major -lt 7.'
    }
}

function Assert-FirstLogonSupportRequiresPowerShell7 {
    param([Parameter(Mandatory)][string]$FirstLogonSupportText)

    Assert-StaticTextContainsAll -Text $FirstLogonSupportText -FailurePrefix 'FirstLogon host resolution should delegate PowerShell 7 with' -Expected @(
        'function Resolve-WinMintPowerShellHost',
        'Resolve-WinMintPowerShell7Host'
    )
}

function Assert-AgentRuntimeRequiresPowerShell7 {
    param([Parameter(Mandatory)][string]$AgentRuntimeText)

    Assert-StaticTextContainsAll -Text $AgentRuntimeText -FailurePrefix 'Agent host resolution should delegate PowerShell 7 with' -Expected @(
        'function Resolve-AgentPowerShellHost',
        'Resolve-WinMintPowerShell7Host'
    )
}

function Assert-AgentModuleCatalogParity {
    $catalogPath = Join-Path $root 'src\runtime\firstlogon\agent-module-catalog.json'
    if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
        Add-SmokeFailure 'Agent module catalog JSON is missing.'
        return
    }

    $catalog = @(Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    $modulesDir = Join-Path $root 'src\runtime\firstlogon\Modules'
    $validShellGroups = @('tools', 'dev', 'desktop')
    foreach ($entry in $catalog) {
        $modulePath = Join-Path $root ('src\runtime\firstlogon\' + ([string]$entry.RelativePath -replace '\\', '\'))
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            Add-SmokeFailure "Agent catalog module '$($entry.Id)' points to missing file '$($entry.RelativePath)'."
        }
        $group = [string]$entry.Group
        if ([string]::IsNullOrWhiteSpace($group) -or $group -notin $validShellGroups) {
            Add-SmokeFailure "Agent catalog module '$($entry.Id)' must declare Group as one of: $($validShellGroups -join ', ')."
        }
        if ([string]::IsNullOrWhiteSpace([string]$entry.ShellLabel)) {
            Add-SmokeFailure "Agent catalog module '$($entry.Id)' is missing ShellLabel."
        }
        $bootstrap = [string]$entry.BootstrapFunction
        if ([string]::IsNullOrWhiteSpace($bootstrap)) {
            Add-SmokeFailure "Agent catalog module '$($entry.Id)' is missing BootstrapFunction."
        }
        else {
            $moduleText = Get-Content -LiteralPath $modulePath -Raw
            if ($moduleText -notmatch [regex]::Escape("function $bootstrap")) {
                Add-SmokeFailure "Agent catalog module '$($entry.Id)' requires bootstrap function '$bootstrap' in '$($entry.RelativePath)'."
            }
        }
    }

    $catalogIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $catalog) { $null = $catalogIds.Add([string]$entry.Id) }
    foreach ($moduleFile in @(Get-ChildItem -LiteralPath $modulesDir -Filter '*.ps1' -File)) {
        $relative = 'Modules\' + $moduleFile.Name
        $matched = @($catalog | Where-Object { ([string]$_.RelativePath) -ieq $relative })
        if ($matched.Count -eq 0) {
            Add-SmokeFailure "FirstLogon module '$($moduleFile.Name)' is not registered in agent-module-catalog.json."
        }
    }
}

function Assert-SetupAndFirstLogonCatalogsAreExplicit {
    $setupActionsText = Get-WinMintRepositoryText 'src\runtime\setup\Setup.Actions.ps1'
    $setupCompleteText = Get-WinMintRepositoryText 'src\runtime\setup\SetupComplete.ps1'
    $agentRuntimeText = @(
            (Get-WinMintRepositoryText 'src\runtime\firstlogon\Agent.Plan.ps1'),
            (Get-WinMintRepositoryText 'src\runtime\firstlogon\agent-module-catalog.json')
        ) -join "`n"

    Assert-StaticTextContainsAll -Text $setupActionsText -FailurePrefix 'Setup action catalog should contain' -Expected @(
        'function Get-WinMintSetupActionCatalog',
        'Import-WinMintSetupActionModules',
        'hyperv-guest-basic-console',
        'autologon-stamp',
        'Invoke-ScAutoLogonStamp',
        'inline-secret-cleanup',
        'first-logon-runonce'
    )
    if ($setupActionsText -match 'edge-removal') {
        Add-SmokeFailure 'Setup action catalog must not list edge-removal (Edge uninstall is not a product path).'
    }
    Assert-StaticTextContainsAll -Text $setupCompleteText -FailurePrefix 'SetupComplete orchestrator should use the explicit setup action catalog with' -Expected @(
        'Import-WinMintSetupActionModules',
        'Get-WinMintSetupActionCatalog'
    )
    if ($setupCompleteText -match 'Get-ChildItem\s+-LiteralPath\s+\(Join-Path \$payloadDir ''SetupComplete''\)') {
        Add-SmokeFailure 'SetupComplete.ps1 must not discover action modules by folder globbing.'
    }

    Assert-StaticTextContainsAll -Text $agentRuntimeText -FailurePrefix 'FirstLogon runtime should use the explicit module catalog with' -Expected @(
        'function Get-WinMintAgentModuleCatalog',
        'function Get-WinMintAgentModuleRuntimeState',
        'RuntimeStepName',
        'Group',
        'ShellLabel',
        'FailurePolicy',
        'PostStepHook'
    )
}

function Assert-PowerShell7IsBundledAndRequired {
    Assert-OfflinePowerShell7StagingContract -PackagesText (Get-WinMintRepositoryText 'src\runtime\image\Private\Image\Packages.ps1')
    Assert-ServiceWimRequiresBundledPowerShell7
    Assert-SetupCompleteCmdRequiresBundledPowerShell7 -SetupCompleteCmd (Get-WinMintRepositoryText 'src\runtime\setup\SetupComplete.cmd')
    Assert-SetupCompleteRegistersFirstLogonUnderPowerShell7 -SetupCompleteText (Get-WinMintRepositoryText 'src\runtime\setup\SetupComplete.ps1')
    Assert-SetupCompleteToolchainDoesNotInstallPowerShell7Fallback -ToolchainText (Get-WinMintRepositoryText 'src\runtime\setup\SetupComplete\Toolchain.ps1')
    Assert-FirstLogonRuntimeRequiresPowerShell7 -FirstLogonBootstrapText (Get-WinMintRepositoryText 'src\runtime\setup\FirstLogon.Host.ps1')
    Assert-FirstLogonSupportRequiresPowerShell7 -FirstLogonSupportText (Get-WinMintRepositoryText 'src\runtime\setup\FirstLogon.Host.ps1')
    Assert-AgentRuntimeRequiresPowerShell7 -AgentRuntimeText (Get-WinMintRepositoryText 'src\runtime\firstlogon\Agent.Host.ps1')
    Assert-AgentModuleCatalogParity
}

function Assert-PSScriptAnalyzerHonorsProjectSettings {
    $validationCoreText = Get-Content -LiteralPath (Join-Path $root 'tools\validation\Modules\Core.ps1') -Raw
    foreach ($expected in @(
        'PSScriptAnalyzerSettings.psd1',
        '$analyzerArgs.Settings = $settings',
        "@('Error', 'Warning')"
    )) {
        if ($validationCoreText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Validation analyzer pass should honor project settings and warning fallback with '$expected'."
        }
    }
    if ($validationCoreText -match [regex]::Escape('@{ Path = $target; Recurse = $true; Severity = @(''Error'') }')) {
        Add-SmokeFailure 'Validation analyzer pass must not force errors-only severity when project settings request warnings.'
    }
}

function Assert-XdgDefaultsAreStaged {
    $defaultUserPath = Join-Path $root 'src\runtime\setup\DefaultUser.ps1'
    $defaultUserText = Get-Content -LiteralPath $defaultUserPath -Raw
    $firstLogonText = Get-WinMintFirstLogonText
    foreach ($expected in @(
        'XDG_CONFIG_HOME',
        'XDG_DATA_HOME',
        'XDG_STATE_HOME',
        'XDG_CACHE_HOME',
        'XDG_RUNTIME_DIR',
        '%USERPROFILE%\.config',
        '%USERPROFILE%\.local\share',
        '%USERPROFILE%\.local\state',
        '%USERPROFILE%\.cache',
        '%USERPROFILE%\bin',
        '%USERPROFILE%\.local\bin',
        '%LOCALAPPDATA%\Temp\xdg-runtime'
    )) {
        if ($defaultUserText -notmatch [regex]::Escape($expected) -and $firstLogonText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "XDG defaults should stage '$expected'."
        }
    }
    foreach ($expected in @(
        'Add-WinMintFirstLogonUserPath',
        'bin',
        '.local\bin',
        'EnableClipboardHistory',
        'CloudClipboardAutomaticUpload',
        'Set-WinMintFirstLogonQuietUxDefaults',
        'Windows.SystemToast.BackupReminder',
        'Windows.SystemToast.Suggested',
        'TaskbarMn',
        'ShowCopilotButton',
        'Start_AccountNotifications',
        'EnableAutoTray',
        'RotatingLockScreenEnabled',
        'RotatingLockScreenOverlayEnabled'
    )) {
        if ($defaultUserText -notmatch [regex]::Escape($expected) -and $firstLogonText -notmatch [regex]::Escape($expected)) {
            Add-SmokeFailure "Default profile and FirstLogon should stage user QoL default '$expected'."
        }
    }
    if ($defaultUserText -match [regex]::Escape('%LOCALAPPDATA%\Temp\WinMint\xdg-runtime') -or
        $firstLogonText -match [regex]::Escape('Temp\WinMint\xdg-runtime')) {
        Add-SmokeFailure 'XDG_RUNTIME_DIR must not leave a WinMint-named temp folder behind.'
    }
}

