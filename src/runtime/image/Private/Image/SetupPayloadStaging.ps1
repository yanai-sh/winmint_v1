#Requires -Version 7.6

function Get-WinMintSetupPayloadRequiredScriptNames {
    @(
        'SetupComplete.cmd'
        'SetupComplete.ps1'
        'Setup.Actions.ps1'
        'Specialize.ps1'
        'DefaultUser.ps1'
        'FirstLogon.ps1'
        'FirstLogon.PreLock.ps1'
        'WinMintLogonShell.cmd'
        'WinMintLogonShell.ps1'
        'FirstLogon.Support.ps1'
        'WinMint.Runtime.Common.ps1'
        'WinMint.RuntimeState.ps1'
        'FirstLogon.Context.ps1'
        'FirstLogon.State.ps1'
        'FirstLogon.Host.ps1'
        'FirstLogon.Desktop.ps1'
        'FirstLogon.Region.ps1'
        'FirstLogon.Cleanup.ps1'
        'WindowsTerminal.Profiles.ps1'
        'FirstLogon.Transaction.ps1'
        'FirstLogon.Runtime.ps1'
        'WinMintSetupShell.Status.ps1'
        'ProvisioningGuard.ps1'
        'WinMint.Diagnostics.ps1'
    )
}

function Get-WinMintSetupPayloadRequiredArtifacts {
    param(
        [bool]$LiveInstallAudit = $false
    )

    $scriptRoot = 'C:\Windows\Setup\Scripts'
    $artifacts = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @(Get-WinMintSetupPayloadRequiredScriptNames)) {
        $artifacts.Add((Join-Path $scriptRoot $name)) | Out-Null
    }
    $artifacts.Add((Join-Path $scriptRoot 'SetupComplete\*.ps1')) | Out-Null
    if ($LiveInstallAudit) {
        $artifacts.Add((Join-Path $scriptRoot 'Audit-LiveInstall.ps1')) | Out-Null
    }
    $artifacts.Add((Join-Path $scriptRoot 'WinMintSetupProfile.json')) | Out-Null
    $artifacts.Add((Join-Path $scriptRoot 'WinMintAgent\WinMintAgentProfile.json')) | Out-Null
    $artifacts.Add((Join-Path $scriptRoot 'WinMintAgent\packages.json')) | Out-Null
    $artifacts.Add((Join-Path $scriptRoot 'setup-shell\WinMintSetupShell.exe')) | Out-Null
    $artifacts.Add((Join-Path $scriptRoot 'setup-shell\tokens.json')) | Out-Null
    $artifacts.Add((Join-Path $scriptRoot 'setup-shell\winmint_hero_ui.png')) | Out-Null
    $artifacts.Add((Join-Path $scriptRoot 'setup-shell\winmint_hero.png')) | Out-Null
    $artifacts.Add((Join-Path $scriptRoot 'WinMintSetupShell.Status.ps1')) | Out-Null
    $artifacts.Add((Join-Path $scriptRoot 'TerminalIcons\fedora.png')) | Out-Null
    @($artifacts)
}

function Assert-WinMintAgentToolSources {
    # WinMint installs first-logon tools through explicit package-manager owners:
    # winget/msstore for GUI/system apps, Scoop for developer CLI tools. Validate
    # the catalog at build time so an unsupported source fails the build here, with a
    # clear message, rather than silently failing per-tool on the user's first logon.
    param([Parameter(Mandatory)][string]$ManifestPath)

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $manifest.PSObject.Properties['tools']) { return }
    foreach ($toolProp in $manifest.tools.PSObject.Properties) {
        $tool = $toolProp.Value
        $toolSource = [string]$toolProp.Value.source
        if (-not [string]::IsNullOrWhiteSpace($toolSource) -and $toolSource -notin @('winget', 'store', 'scoop', 'direct')) {
            throw "Unsupported install source '$toolSource' for tool '$($toolProp.Name)' in packages.json. WinMint only supports the 'winget', 'store', 'scoop', and approved 'direct' install sources."
        }
        if ($toolSource -eq 'direct') {
            # Reserved for future pinned exceptions; none currently approved.
            throw "Direct install source is not currently approved for any tool. Invalid tool '$($toolProp.Name)' in packages.json."
        }
    }
}

function Copy-WinMintSetupPayloadTextFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    if ([IO.Path]::GetExtension($Source) -ieq '.cmd') {
        # Batch files must be ASCII with no BOM because a UTF-8 BOM makes
        # cmd.exe fail on the first line.
        [System.IO.File]::WriteAllBytes(
            $Destination,
            [System.Text.Encoding]::ASCII.GetBytes((Get-Content -LiteralPath $Source -Raw))
        )
        return
    }

    $utf8Bom = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllText($Destination, (Get-Content -LiteralPath $Source -Raw), $utf8Bom)
}

function Get-WinMintRuntimeCommonSourcePath {
    param([Parameter(Mandatory)][string]$RepositoryRoot)

    return Join-Path $RepositoryRoot 'src\runtime\common\WinMint.Runtime.Common.ps1'
}

function Copy-WinMintRuntimeCommonPayload {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Destination
    )

    $source = Get-WinMintRuntimeCommonSourcePath -RepositoryRoot $RepositoryRoot
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "WinMint runtime common script is missing: $source"
    }

    $destinationPath = Join-Path $Destination 'WinMint.Runtime.Common.ps1'
    Copy-WinMintSetupPayloadTextFile -Source $source -Destination $destinationPath
    if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
        throw "Failed to stage WinMint.Runtime.Common.ps1 into the offline image at $Destination."
    }
}

function Copy-WinMintTerminalIconPayload {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Destination
    )

    $sourceDir = Join-Path $RepositoryRoot 'assets\ui\wsl'
    if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) {
        throw "WinMint WSL Terminal icon assets are missing: $sourceDir"
    }

    $destDir = Join-Path $Destination 'TerminalIcons'
    $null = New-Item -ItemType Directory -Path $destDir -Force
    $copied = 0
    foreach ($name in @('ubuntu.png', 'fedora.png', 'archlinux.png', 'nixos.png', 'pengwin.png')) {
        $from = Join-Path $sourceDir $name
        if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { continue }
        Copy-Item -LiteralPath $from -Destination (Join-Path $destDir $name) -Force
        $copied++
    }
    if ($copied -eq 0) {
        throw "WinMint WSL Terminal icon assets produced no PNG copies from: $sourceDir"
    }
}

function Copy-WinMintSetupScriptPayloads {
    param(
        [Parameter(Mandatory)][string]$BundleDir,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )

    foreach ($name in @(Get-WinMintSetupPayloadRequiredScriptNames)) {
        if ($name -eq 'WinMint.Runtime.Common.ps1') { continue }

        $source = Join-Path $BundleDir $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "WinMint setup payload missing from the repository: $source. Cannot guarantee FirstLogon/SetupComplete will run."
        }

        $destinationPath = Join-Path $Destination $name
        Copy-WinMintSetupPayloadTextFile -Source $source -Destination $destinationPath
        if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
            throw "Failed to stage '$name' into the offline image at $Destination. SetupComplete/FirstLogon would not run on the installed system; aborting before producing a broken ISO."
        }
    }

    Copy-WinMintRuntimeCommonPayload -RepositoryRoot $RepositoryRoot -Destination $Destination

    LogVerbose 'Verified SetupComplete / FirstLogon / specialize scripts are staged into the offline image.'
}

function Copy-WinMintSetupCompleteModulePayloads {
    param(
        [Parameter(Mandatory)][string]$BundleDir,
        [Parameter(Mandatory)][string]$Destination
    )

    $sourceDir = Join-Path $BundleDir 'SetupComplete'
    if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) {
        throw "SetupComplete module directory is missing: $sourceDir"
    }

    $moduleFiles = @(Get-ChildItem -LiteralPath $sourceDir -Filter '*.ps1' -File)
    if ($moduleFiles.Count -lt 1) {
        throw "SetupComplete module directory has no .ps1 modules: $sourceDir"
    }

    $destinationDir = Join-Path $Destination 'SetupComplete'
    $null = New-Item -ItemType Directory -Path $destinationDir -Force -ErrorAction SilentlyContinue
    foreach ($moduleFile in $moduleFiles) {
        Copy-WinMintSetupPayloadTextFile -Source $moduleFile.FullName -Destination (Join-Path $destinationDir $moduleFile.Name)
    }
}

function Copy-WinMintLiveAuditPayload {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Destination
    )

    $auditSource = Join-Path $RepositoryRoot 'tools\audit\Audit-LiveInstall.ps1'
    if (Test-Path -LiteralPath $auditSource -PathType Leaf) {
        Copy-WinMintSetupPayloadTextFile -Source $auditSource -Destination (Join-Path $Destination 'Audit-LiveInstall.ps1')
    }
}

function Save-WinMintSetupPayloadJson {
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$Depth
    )

    $json = $Value | ConvertTo-Json -Depth $Depth
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Test-WinMintAgentProfileSelection {
    param(
        [AllowNull()]$AgentProfile,
        [Parameter(Mandatory)][string]$Path
    )

    if ($null -eq $AgentProfile) { return $false }

    $value = $AgentProfile
    foreach ($segment in @($Path -split '\.')) {
        if ($null -eq $value) { return $false }
        if ($value -is [System.Collections.IDictionary]) {
            if (-not $value.Contains($segment)) { return $false }
            $value = $value[$segment]
            continue
        }
        $property = $value.PSObject.Properties[$segment]
        if (-not $property) { return $false }
        $value = $property.Value
    }

    return [bool]$value
}

function Copy-WinMintAgentRuntimePayload {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Destination,
        [AllowNull()]$AgentProfile
    )

    $agentSource = Join-Path $RepositoryRoot 'src\runtime\firstlogon'
    if (-not (Test-Path -LiteralPath $agentSource -PathType Container)) {
        throw "WinMintAgent source directory is missing: $agentSource"
    }

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    Copy-Item -LiteralPath $agentSource -Destination $Destination -Recurse -Force
    Copy-WinMintRuntimeCommonPayload -RepositoryRoot $RepositoryRoot -Destination $Destination

    $agentEntry = Join-Path $Destination 'Start-WinMintAgent.ps1'
    if (-not (Test-Path -LiteralPath $agentEntry -PathType Leaf)) {
        throw "WinMintAgent entrypoint missing after staging: $agentEntry. FirstLogon would have no agent to run; aborting before producing a broken ISO."
    }
    if (Test-Path -LiteralPath (Join-Path $Destination 'agent')) {
        throw "WinMintAgent was staged nested (WinMintAgent\agent\). FirstLogon would launch the wrong (stale) entrypoint; aborting before producing a broken ISO."
    }

    $pkgManifest = Get-WinMintPath -Name ConfigRoot -ChildPath 'packages.json'
    if (Test-Path -LiteralPath $pkgManifest -PathType Leaf) {
        Assert-WinMintAgentToolSources -ManifestPath $pkgManifest
        Copy-Item -LiteralPath $pkgManifest -Destination (Join-Path $Destination 'packages.json') -Force
    }

    if ($null -eq $AgentProfile) {
        throw 'WinMintAgent payload staging requires a generated agent profile. Refusing to fall back to a checked-in WinMintAgentProfile.json sample.'
    }

    Save-WinMintSetupPayloadJson -Value $AgentProfile -Path (Join-Path $Destination 'WinMintAgentProfile.json') -Depth 12
    LogVerbose 'Generated WinMintAgent profile from the selected wizard options.'
}

function Resolve-WinMintSetupShellPublishFolder {
    param([Parameter(Mandatory)][string]$ImageArch)

    switch ([string]$ImageArch.ToLowerInvariant()) {
        'arm64' { return 'arm64' }
        'amd64' { return 'x64' }
        'x64' { return 'x64' }
        default { throw "Unsupported image architecture for WinMintSetupShell.exe staging: $ImageArch" }
    }
}

function Copy-WinMintSetupShellPayload {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ImageArch
    )

    $sourceDir = Join-Path $RepositoryRoot 'assets\runtime\setup\setup-shell'
    if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) {
        throw "WinMint setup shell assets are missing: $sourceDir"
    }

    $publishFolder = Resolve-WinMintSetupShellPublishFolder -ImageArch $ImageArch
    $exeSource = Join-Path $sourceDir "bin\$publishFolder\WinMintSetupShell.Native.exe"
    if (-not (Test-Path -LiteralPath $exeSource -PathType Leaf)) {
        $exeSource = Join-Path $sourceDir "bin\$publishFolder\WinMintSetupShell.exe"
    }
    if (-not (Test-Path -LiteralPath $exeSource -PathType Leaf)) {
        throw "WinMintSetupShell.Native.exe is missing for $ImageArch under bin\$publishFolder. Run tools\release\Build-WinMintSetupShell.ps1 before building the ISO."
    }

    $destDir = Join-Path $Destination 'setup-shell'
    $null = New-Item -ItemType Directory -Path $destDir -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $exeSource -Destination (Join-Path $destDir 'WinMintSetupShell.exe') -Force

    foreach ($assetName in @('tokens.json', 'winmint_hero_ui.png', 'winmint_hero.png')) {
        $assetSource = Join-Path $sourceDir $assetName
        if (-not (Test-Path -LiteralPath $assetSource -PathType Leaf)) {
            if ($assetName -match '^winmint_hero') {
                $assetSource = Join-Path $RepositoryRoot "assets\brand\$assetName"
            }
        }
        if (-not (Test-Path -LiteralPath $assetSource -PathType Leaf)) {
            throw "WinMint setup shell asset is missing: $assetName (run tools\release\Build-WinMintSetupShell.ps1)"
        }
        Copy-Item -LiteralPath $assetSource -Destination (Join-Path $destDir $assetName) -Force
    }

    LogVerbose 'Staged WinMintSetupShell.exe (native Direct2D), tokens, and hero brand assets.'
}

function Copy-WinMintAgentBrandAssets {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$AgentDestination
    )

    $brandImageSource = Join-Path $RepositoryRoot 'assets\brand\winmint_hero.png'
    if (Test-Path -LiteralPath $brandImageSource -PathType Leaf) {
        $brandAssetDir = Join-Path $AgentDestination 'Assets\Brand'
        $null = New-Item -ItemType Directory -Path $brandAssetDir -Force
        Copy-Item -LiteralPath $brandImageSource -Destination (Join-Path $brandAssetDir 'winmint_logo_wordmark.png') -Force
        LogVerbose 'Staged WinMint logo wordmark PNG for the first-logon console splash.'
    }
}

function Get-WinMintDesktopPresetManifest {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$ToolId
    )

    $sourceDir = Join-Path $RepositoryRoot "assets\runtime\desktop\$ToolId"
    $manifestPath = Join-Path $sourceDir 'preset.manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Desktop preset manifest is missing for '$ToolId': $manifestPath"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$manifest.schemaVersion -ne 1) { throw "Unsupported desktop preset manifest schema for '$ToolId': $manifestPath" }
    if ([string]$manifest.tool -ne $ToolId) { throw "Desktop preset manifest tool mismatch for '$ToolId': $manifestPath" }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.displayName)) { throw "Desktop preset manifest has no displayName: $manifestPath" }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.stageDirectory)) { throw "Desktop preset manifest has no stageDirectory: $manifestPath" }
    if (-not $manifest.files -or @($manifest.files).Count -eq 0) { throw "Desktop preset manifest has no files: $manifestPath" }

    [pscustomobject]@{
        ToolId = $ToolId
        SourceDir = $sourceDir
        ManifestPath = $manifestPath
        DisplayName = [string]$manifest.displayName
        StageDirectory = [string]$manifest.stageDirectory
        Files = @($manifest.files)
    }
}

function Get-WinMintDesktopPresetSourceFiles {
    param([Parameter(Mandatory)]$Manifest)

    $files = [System.Collections.Generic.List[object]]::new()
    $files.Add([pscustomobject]@{
        Source = [string]$Manifest.ManifestPath
        Destination = 'preset.manifest.json'
        Role = 'manifest'
    }) | Out-Null

    foreach ($file in @($Manifest.Files)) {
        $sourceName = [string]$file.source
        if ([string]::IsNullOrWhiteSpace($sourceName)) {
            throw "Desktop preset manifest has a file without source: $($Manifest.ManifestPath)"
        }
        $destinationName = if ($file.PSObject.Properties['destination'] -and -not [string]::IsNullOrWhiteSpace([string]$file.destination)) {
            [string]$file.destination
        } else {
            $sourceName
        }
        $files.Add([pscustomobject]@{
            Source = (Join-Path $Manifest.SourceDir $sourceName)
            Destination = $destinationName
            Role = if ($file.PSObject.Properties['role']) { [string]$file.role } else { '' }
        }) | Out-Null
    }

    return @($files)
}

function Copy-WinMintAgentDesktopPresetAssets {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$AgentDestination,
        [Parameter(Mandatory)][string]$ToolId
    )

    $manifest = Get-WinMintDesktopPresetManifest -RepositoryRoot $RepositoryRoot -ToolId $ToolId
    $assetDir = Join-Path $AgentDestination "Assets\$($manifest.StageDirectory)"
    $null = New-Item -ItemType Directory -Path $assetDir -Force

    foreach ($file in @(Get-WinMintDesktopPresetSourceFiles -Manifest $manifest)) {
        if (-not (Test-Path -LiteralPath $file.Source -PathType Leaf)) {
            throw "$($manifest.DisplayName) preset asset is missing: $($file.Source)"
        }
        $destination = Join-Path $assetDir ([string]$file.Destination)
        $destinationParent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationParent)) {
            $null = New-Item -ItemType Directory -Path $destinationParent -Force
        }
        Copy-Item -LiteralPath $file.Source -Destination $destination -Force
    }

    LogVerbose "Staged $($manifest.DisplayName) curated preset for first-logon setup."
}

function Copy-WinMintAgentWindhawkAssets {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$AgentDestination,
        [AllowNull()]$AgentProfile
    )

    if (-not (Test-WinMintAgentProfileSelection -AgentProfile $AgentProfile -Path 'modules.windhawk.enabled')) {
        return
    }

    $windhawkAssetDir = Join-Path $AgentDestination 'Assets\Windhawk'
    $null = New-Item -ItemType Directory -Path $windhawkAssetDir -Force
    Copy-Item -LiteralPath (Get-WinMintPath -Name RuntimeSetupRoot -ChildPath 'WindhawkBootstrap.ps1') -Destination (Join-Path $windhawkAssetDir 'WindhawkBootstrap.ps1') -Force
    Copy-Item -LiteralPath (Get-WinMintPath -Name RuntimeSetupRoot -ChildPath 'WindhawkBootstrap.Helpers.ps1') -Destination (Join-Path $windhawkAssetDir 'WindhawkBootstrap.Helpers.ps1') -Force
    Copy-WinMintAgentDesktopPresetAssets -RepositoryRoot $RepositoryRoot -AgentDestination $AgentDestination -ToolId 'windhawk'
}

function Copy-WinMintAgentYasbAssets {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$AgentDestination,
        [AllowNull()]$AgentProfile
    )

    if (-not (Test-WinMintAgentProfileSelection -AgentProfile $AgentProfile -Path 'modules.shell.yasb')) {
        return
    }

    Copy-WinMintAgentDesktopPresetAssets -RepositoryRoot $RepositoryRoot -AgentDestination $AgentDestination -ToolId 'yasb'
}

function Copy-WinMintAgentKomorebiAssets {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$AgentDestination,
        [AllowNull()]$AgentProfile
    )

    if (-not (Test-WinMintAgentProfileSelection -AgentProfile $AgentProfile -Path 'modules.shell.komorebi')) {
        return
    }

    $komorebiSourceDir = Join-Path $RepositoryRoot 'assets\runtime\desktop\komorebi'
    if (-not (Test-Path -LiteralPath $komorebiSourceDir -PathType Container)) {
        throw "Komorebi preset assets are missing: $komorebiSourceDir"
    }

    $komorebiAssetDir = Join-Path $AgentDestination 'Assets\Komorebi'
    $null = New-Item -ItemType Directory -Path $komorebiAssetDir -Force
    foreach ($name in @('komorebi.json', 'applications.json', 'whkdrc')) {
        Copy-Item -LiteralPath (Join-Path $komorebiSourceDir $name) -Destination (Join-Path $komorebiAssetDir $name) -Force
    }
    LogVerbose 'Staged Komorebi preset for first-logon setup.'
}

function Copy-WinMintAgentAssetPayloads {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$AgentDestination,
        [AllowNull()]$AgentProfile
    )

    Copy-WinMintAgentBrandAssets -RepositoryRoot $RepositoryRoot -AgentDestination $AgentDestination
    Copy-WinMintAgentWindhawkAssets -RepositoryRoot $RepositoryRoot -AgentDestination $AgentDestination -AgentProfile $AgentProfile
    Copy-WinMintAgentYasbAssets -RepositoryRoot $RepositoryRoot -AgentDestination $AgentDestination -AgentProfile $AgentProfile
    Copy-WinMintAgentKomorebiAssets -RepositoryRoot $RepositoryRoot -AgentDestination $AgentDestination -AgentProfile $AgentProfile
}

function Invoke-WinMintSetupPayloadStaging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MountDir,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [AllowNull()]$AgentProfile,
        [AllowNull()]$SetupProfile,
        [AllowNull()]$SetupPlan,
        [string]$ImageArch = '',
        [bool]$LiveInstallAudit = $false
    )

    $bundleDir = Join-Path $ScriptRoot 'src\runtime\setup'
    if (-not (Test-Path -LiteralPath $bundleDir -PathType Container)) {
        throw "WinMint setup script directory is missing: $bundleDir"
    }

    $destScripts = Join-Path $MountDir 'Windows\Setup\Scripts'
    $null = New-Item -ItemType Directory -Path $destScripts -Force -ErrorAction SilentlyContinue

    if ([string]::IsNullOrWhiteSpace($ImageArch) -and $null -ne $AgentProfile) {
        if ($AgentProfile -is [System.Collections.IDictionary] -and $AgentProfile.Contains('targetArchitecture')) {
            $ImageArch = [string]$AgentProfile['targetArchitecture']
        }
        elseif ($AgentProfile.PSObject.Properties['targetArchitecture']) {
            $ImageArch = [string]$AgentProfile.targetArchitecture
        }
    }
    if ([string]::IsNullOrWhiteSpace($ImageArch) -and $null -ne $SetupProfile -and $SetupProfile.PSObject.Properties['source'] -and $SetupProfile.source.PSObject.Properties['architecture']) {
        $ImageArch = [string]$SetupProfile.source.architecture
    }
    if ([string]::IsNullOrWhiteSpace($ImageArch)) {
        throw 'WinMint setup shell staging requires image architecture (profile.source.architecture or -ImageArch).'
    }

    Copy-WinMintSetupScriptPayloads -BundleDir $bundleDir -Destination $destScripts -RepositoryRoot $ScriptRoot
    Copy-WinMintTerminalIconPayload -RepositoryRoot $ScriptRoot -Destination $destScripts
    Copy-WinMintSetupShellPayload -RepositoryRoot $ScriptRoot -Destination $destScripts -ImageArch $ImageArch
    Copy-WinMintSetupCompleteModulePayloads -BundleDir $bundleDir -Destination $destScripts
    if ($LiveInstallAudit) {
        Copy-WinMintLiveAuditPayload -RepositoryRoot $ScriptRoot -Destination $destScripts
    }

    if ($null -ne $SetupProfile) {
        Save-WinMintSetupPayloadJson -Value $SetupProfile -Path (Join-Path $destScripts 'WinMintSetupProfile.json') -Depth 12
        LogVerbose 'Generated setup profile for specialize, SetupComplete, and FirstLogon scripts.'
    }

    if ($null -ne $SetupPlan) {
        LogVerbose 'Setup plan retained for host output artifacts only (not staged on the guest image).'
    }

    $agentDest = Join-Path $destScripts 'WinMintAgent'
    Copy-WinMintAgentRuntimePayload -RepositoryRoot $ScriptRoot -Destination $agentDest -AgentProfile $AgentProfile
    Copy-WinMintAgentAssetPayloads -RepositoryRoot $ScriptRoot -AgentDestination $agentDest -AgentProfile $AgentProfile

    LogOK 'Staged setup scripts and FirstLogon payload into the offline image.'
    LogVerbose 'Copied setup scripts into the offline image (matching files only).'
    [pscustomobject]@{
        Destination = $destScripts
        AgentDestination = $agentDest
        RequiredArtifacts = @(Get-WinMintSetupPayloadRequiredArtifacts -LiveInstallAudit $LiveInstallAudit)
    }
}

