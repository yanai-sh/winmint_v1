#Requires -Version 7.6

function Convert-WinMintInstallEsdToWim {
    param(
        [Parameter(Mandatory)][string]$IsoContentsRoot,
        [switch]$DryRun
    )

    $sources = Join-Path $IsoContentsRoot 'sources'
    $wim = Join-Path $sources 'install.wim'
    if (Test-Path -LiteralPath $wim) { return $wim }
    $esd = Join-Path $sources 'install.esd'
    if (-not (Test-Path -LiteralPath $esd)) {
        $uup = Join-Path $sources 'uup'
        if (Test-Path -LiteralPath $uup) {
            throw "This ISO uses a UUP source layout under sources\uup. This builder currently requires sources\install.wim or sources\install.esd; convert the UUP payload to a WIM/ESD ISO before building."
        }
        throw "Neither install.wim nor install.esd was found under $sources."
    }

    Log 'Converting install.esd -> install.wim...'
    LogVerbose 'ESD->WIM export in the staged ISO copy for DISM servicing.'
    if ($DryRun) { LogVerbose 'Dry run still converts the temporary staged ESD so WIM metadata validation is complete.' }
    $images = @(Get-WindowsImage -ImagePath $esd -ErrorAction Stop | Sort-Object ImageIndex)
    Assert-WinMintDismCanServiceImages -ImagePath $esd -Images $images
    foreach ($image in $images) {
        $arguments = @(
            '/English',
            '/Export-Image',
            "/SourceImageFile:`"$esd`"",
            "/SourceIndex:$($image.ImageIndex)",
            "/DestinationImageFile:`"$wim`"",
            '/Compress:max',
            '/CheckIntegrity'
        )
        Invoke-DismExe -Arguments $arguments | Out-Null
    }
    Remove-Item -LiteralPath $esd -Force
    return $wim
}

function Mount-WinMintIsoToWorkTree {
    param(
        [Parameter(Mandatory)][string]$SourceIso,
        [Parameter(Mandatory)][string]$IsoContents,
        [switch]$DryRun
    )

    $resolvedSourceIso = (Resolve-Path -LiteralPath $SourceIso -ErrorAction Stop).Path
    [object[]]$autoPlayState = @(Push-Win11IsoAutoPlaySuppression)
    try {
        Log 'Mounting source ISO...'
        if ($DryRun) { LogVerbose 'Dry-run staging mount (ISO is copied into the work tree).' }
        # Use a drive letter for build staging so Invoke-RobocopyChecked can use
        # robocopy. Copy-Item from a no-drive-letter volume GUID is much slower
        # and can appear hung on large UUP-generated ISOs.
        $iso = Mount-DiskImage -ImagePath $resolvedSourceIso -Access ReadOnly -PassThru -ErrorAction Stop
        $volume = $iso | Get-Volume -ErrorAction Stop | Select-Object -First 1
        if (-not $volume) { throw 'Mounted ISO did not expose a readable volume.' }
        $root = if ($volume.DriveLetter) {
            "$($volume.DriveLetter):\"
        }
        elseif ($volume.Path) {
            $volume.Path
        }
        else {
            throw 'Mounted ISO did not expose a drive letter or volume path.'
        }
        LogVerbose "Mounted ISO root: $root"
        Invoke-RobocopyChecked -Source $root -Dest $IsoContents
        # Files copied from a read-only ISO inherit FILE_ATTRIBUTE_READONLY. DISM's
        # Mount-WindowsImage checks the WIM's file attributes before validating the
        # process token and throws "You do not have permissions to mount and modify
        # this image" on a read-only WIM — regardless of admin elevation. Clear the
        # attribute recursively on the staged tree so DISM and the rest of the
        # pipeline (autounattend write, setup script staging) can modify files.
        if (-not $DryRun) {
            Clear-WinMintReadOnlyAttribute -Path $IsoContents
        }
    }
    finally {
        Pop-Win11IsoAutoPlaySuppression -State $autoPlayState
    }
}

function Get-WinMintSelectedInstallImage {
    param(
        [Parameter(Mandatory)][string]$InstallWim,
        [Parameter(Mandatory)][string]$EditionName
    )

    $images = @(Get-WindowsImage -ImagePath $InstallWim -ErrorAction Stop | Sort-Object ImageIndex)
    if ($images.Count -eq 0) { throw "No install images found in $InstallWim." }
    $selected = $images | Where-Object { $_.ImageName -eq $EditionName } | Select-Object -First 1
    if (-not $selected) {
        $imageMatches = @($images | Where-Object { $_.ImageName -like "*$EditionName*" })
        if ($imageMatches.Count -eq 1) {
            $selected = $imageMatches[0]
        }
        elseif ($imageMatches.Count -gt 1) {
            $available = ($imageMatches | ForEach-Object { $_.ImageName }) -join ', '
            throw "Fixed edition '$EditionName' matched more than one install image. Choose the exact edition name. Matches: $available"
        }
    }
    if (-not $selected) {
        $available = ($images | ForEach-Object { $_.ImageName }) -join ', '
        throw "Fixed edition '$EditionName' was not found in install.wim. WinMint will not silently fall back to another edition. Available editions: $available"
    }
    return $selected
}

function Get-WinMintInstallImagesForBuild {
    param(
        [Parameter(Mandatory)][string]$InstallWim,
        [ValidateSet('TargetLicense', 'Fixed')][string]$EditionMode = 'TargetLicense',
        [string]$EditionName = ''
    )

    $images = @(Get-WindowsImage -ImagePath $InstallWim -ErrorAction Stop | Sort-Object ImageIndex)
    if ($images.Count -eq 0) { throw "No install images found in $InstallWim." }
    if ($EditionMode -eq 'Fixed') {
        if ([string]::IsNullOrWhiteSpace($EditionName)) {
            throw 'Fixed edition mode requires an edition name.'
        }
        try {
            return @(Get-WinMintSelectedInstallImage -InstallWim $InstallWim -EditionName $EditionName)
        }
        catch {
            # The default edition (Windows 11 Home) falls back to servicing all
            # editions when absent (robust default); any other explicitly chosen
            # edition still fails hard so the user is never silently given a
            # different edition than they asked for.
            if ($EditionName -eq (Get-WinMintDefaultEditionName)) {
                LogWarn "Default edition '$EditionName' is not present in this ISO; servicing all $($images.Count) edition(s) so Windows Setup can choose. ($($_.Exception.Message))"
                return $images
            }
            throw
        }
    }

    LogVerbose "Available editions: $(@($images | ForEach-Object { $_.ImageName }) -join ', ')"
    return $images
}

function New-WinMintIsoImage {
    param(
        [Parameter(Mandatory)][string]$IsoContents,
        [Parameter(Mandatory)][string]$ImageArch,
        [Parameter(Mandatory)][string]$OutputIso
    )

    Write-SectionHeader 'Output ISO'
    Invoke-Action "Creating bootable ISO: $OutputIso" {
        $oscdimg = Resolve-OscdimgPath
        $bootData = Get-OscdimgBootDataValue -IsoContentsRoot $IsoContents -ImageArch $ImageArch

        # Defense-in-depth: confirm the architecture-specific UEFI loader is
        # actually present in the staged tree before oscdimg builds the ISO.
        # oscdimg sets the boot sector based on $ImageArch, but if the source
        # ISO was mislabeled (e.g., x64 ISO mistaken for ARM64) the resulting
        # ISO won't boot the target firmware and the user only finds out at
        # install time.
        $efiLoader = switch ($ImageArch) {
            'arm64' { 'efi\boot\bootaa64.efi' }
            'amd64' { 'efi\boot\bootx64.efi' }
            default { $null }
        }
        if ($efiLoader) {
            $efiLoaderPath = Join-Path $IsoContents $efiLoader
            if (-not (Test-Path -LiteralPath $efiLoaderPath)) {
                throw ("$ImageArch ISO build requires '$efiLoader' in the source ISO. " +
                       "The staged tree at '$IsoContents' is missing this file — " +
                       'the source ISO may not be a real ' + $ImageArch + ' Windows installer.')
            }
            LogVerbose "EFI loader present for $ImageArch`: $efiLoaderPath"
        }

        $arguments = @(
            '-m',
            '-o',
            '-u2',
            '-udfver102',
            "-bootdata:$bootData",
            "-l$script:Win11IsoVolumeLabel",
            $IsoContents,
            $OutputIso
        )
        Log 'Assembling bootable ISO...'
        LogVerbose "oscdimg: $oscdimg $($arguments -join ' ')"
        # Start-Process — do not `& $oscdimg` inside Spectre Status/Quiet scopes.
        # Those wrappers rebind scriptblock scope so `$oscdimg` becomes invalid and
        # PowerShell throws: "expression after '&' ... was not valid" (exit in ~100ms).
        $oscdProc = Start-Process -FilePath $oscdimg -ArgumentList $arguments -Wait -PassThru -NoNewWindow
        $code = if ($null -ne $oscdProc.ExitCode) { [int]$oscdProc.ExitCode } else { -1 }
        if ($code -ne 0) {
            throw "oscdimg failed with exit code $code."
        }
        if (-not (Test-Path -LiteralPath $OutputIso -PathType Leaf)) {
            throw "oscdimg exited 0 but output ISO is missing: $OutputIso"
        }
        LogOK "ISO written: $OutputIso"
    }
}

function Invoke-WinMintIsoPipeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$BuildConfig,
        [switch]$DryRun,
        [switch]$ExportHostDrivers,
        [switch]$NoServicedWimCache,
        [AllowNull()]$InstallPlan = $null,
        [switch]$WriteUsb,
        [int]$UsbDiskNumber = -1,
        [int]$ConfirmUsbDiskNumber = -1,
        [switch]$AllowFixedUsbDisk,
        [ValidateSet('Max', 'Fast', 'None')][string]$ImageCompression = 'Max'
    )

    $script:DryRun = [bool]$DryRun
    $script:ExportHostDrivers = [bool]$ExportHostDrivers
    $root = Get-WinMintRepositoryRoot
    $workDir = Join-Path (Get-Win11IsoProcessTempPath) ('WinMint_ISO_' + [Guid]::NewGuid().ToString('n'))
    $isoContents = Join-Path $workDir 'iso'
    $mountDir = Join-Path $workDir 'mount'
    $outputIso = Join-Path (Get-WinMintOutputDirectory) ('WinMint-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.iso')
    $mountedImage = $false

    try {
        # Create $workDir first and stamp the restricted ACL on it BEFORE any
        # children exist. New children inherit the ACL — if we created iso\ and
        # mount\ first, they'd keep the loose %TEMP% ACL (Users:Read), exposing
        # the staged WIM (which contains the autounattend with the password
        # before SetupComplete cleanup) to non-admin users on the build host.
        $null = New-Item -ItemType Directory -Path $workDir -Force
        Protect-WorkDirectory -Path $workDir
        $null = New-Item -ItemType Directory -Path $isoContents, $mountDir -Force
        if (Get-Command Write-WinMintHeadlessWorkMarker -ErrorAction SilentlyContinue) {
            Write-WinMintHeadlessWorkMarker -WorkDir $workDir -MountDir $mountDir -IsoContents $isoContents
        }
        if (Get-Command Set-WinMintHeadlessJournalPhase -ErrorAction SilentlyContinue) {
            Set-WinMintHeadlessJournalPhase -Phase 'StageIso' -WorkDir $workDir -MountDir $mountDir -IsoContents $isoContents
        }
        Start-PipelinePhase 'Stage ISO'
        $usedStageCache = $false
        $stageCacheDir = Get-WinMintIsoStageCacheHit -SourceIsoPath $BuildConfig.SourceIso
        if ($null -ne $stageCacheDir) {
            $usedStageCache = $true
            Log 'Restoring staged ISO from cache...'
            if ($DryRun) {
                LogVerbose 'Dry-run validation restore from temp ISO stage cache (skips ISO mount).'
            }
            else {
                LogVerbose 'Skipping ISO mount and ESD->WIM conversion (temp ISO stage cache hit).'
            }
            Invoke-RobocopyChecked -Source $stageCacheDir -Dest $isoContents -UserFacingMessage 'Copying cached staged ISO...'
            if (-not $DryRun) { Clear-WinMintReadOnlyAttribute -Path $isoContents }
        }
        else {
            Mount-WinMintIsoToWorkTree -SourceIso $BuildConfig.SourceIso -IsoContents $isoContents -DryRun:$DryRun
            $null = Convert-WinMintInstallEsdToWim -IsoContentsRoot $isoContents -DryRun:$DryRun
        }
        $installWim = Join-Path $isoContents 'sources\install.wim'
        Set-WinMintManifestSizeDeltaFromPath -Name 'sourceIsoBytes' -Path $BuildConfig.SourceIso
        Set-WinMintManifestSizeDeltaFromPath -Name 'installWimBeforeServicingBytes' -Path $installWim
        $readiness = Test-OfflineStagingReadiness `
            -LocalInstallWim $installWim `
            -IsoContentsRoot $isoContents `
            -ExpectedArchHint $BuildConfig.Architecture `
            -ScriptDirForChecks $root `
            -DriverSource ([string]$BuildConfig.Drivers.Source) `
            -CustomDriverPath ([string]$BuildConfig.Drivers.Path) `
            -ExportHostDrivers ([bool]$ExportHostDrivers)
        $imageArch = $readiness.Architecture
        Test-RemoteBuildPrerequisite `
            -TargetArch $imageArch `
            -IsoContentsRoot $isoContents `
            -AutounattendPath (Get-WinMintPath -Name ConfigRoot -ChildPath 'autounattend.xml') `
            -ExportHostDriversRequested:$ExportHostDrivers
        Complete-PipelinePhase 'Stage ISO'
        if (-not $DryRun -and -not $usedStageCache) {
            Publish-WinMintIsoStageCache -SourceIsoPath $BuildConfig.SourceIso -IsoContentsPath $isoContents
        }

        $editionMode = if ([string]::IsNullOrWhiteSpace([string]$BuildConfig.EditionMode)) { 'TargetLicense' } else { [string]$BuildConfig.EditionMode }
        if ($editionMode -notin @('TargetLicense', 'Fixed')) { $editionMode = 'TargetLicense' }
        $installImages = @(Get-WinMintInstallImagesForBuild -InstallWim $installWim -EditionMode $editionMode -EditionName $BuildConfig.Edition)
        if ($editionMode -eq 'Fixed' -and $installImages.Count -gt 1) {
            # The default-edition fallback returned all editions (Fixed otherwise
            # services exactly one). Treat the rest of the build as target-license
            # so the per-image autounattend does not stamp a single edition.
            $editionMode = 'TargetLicense'
        }
        Assert-WinMintDismCanServiceImages -ImagePath $installWim -Images $installImages
        $expectedWimMetadata = @(Get-WinMintSelectedWimMetadata -ImagePath $installWim -Images $installImages)
        $sourceWindowsBuild = 0
        foreach ($meta in $expectedWimMetadata) {
            if ([int]$meta.Build -gt $sourceWindowsBuild) { $sourceWindowsBuild = [int]$meta.Build }
        }
        if ($editionMode -eq 'TargetLicense') {
            Log "Servicing $($installImages.Count) edition image(s) (target license)."
            LogVerbose 'Edition mode TargetLicense: Windows Setup chooses the SKU on the target device.'
            if ($installImages.Count -gt 1) {
                LogVerbose 'Fixed Home/Pro edition mode would service one image and skip the other edition passes.'
            }
        } else {
            $fixedEdition = [string]$BuildConfig.Edition
            if ([string]::IsNullOrWhiteSpace($fixedEdition)) { $fixedEdition = 'selected edition' }
            Log "Servicing fixed edition: $fixedEdition"
            LogVerbose "Edition mode Fixed: servicing only '$fixedEdition'."
        }

        # Defensive: Get-WindowsImage in some PS7+DISM compat-session combos returns
        # objects whose ImageName lookup fails under StrictMode v2. Fall back to the
        # alternative property names DISM uses, and finally to a dism.exe re-query.
        function Get-WimImageName { param($img)
            foreach ($prop in 'ImageName', 'Name', 'WimImageName') {
                if ($img.PSObject.Properties.Name -contains $prop) {
                    $val = [string]$img.$prop
                    if (-not [string]::IsNullOrWhiteSpace($val)) { return $val }
                }
            }
            return ''
        }

        $editionNames = @($installImages | ForEach-Object { Get-WimImageName -img $_ } | Where-Object { $_ })
        if ($editionNames.Count -lt $installImages.Count) {
            $firstImagePropertyNames = (@($installImages)[0].PSObject.Properties.Name) -join ', '
            LogWarn "Get-WindowsImage returned $($installImages.Count) image(s) but only $($editionNames.Count) had a readable ImageName. Properties on first object: $firstImagePropertyNames"
        }
        Set-WinMintManifestSourceEditionsFact -EditionNames $editionNames

        $installPlan = Get-WinMintInstallPlanForBuildConfig -BuildConfig $BuildConfig -ExistingPlan $InstallPlan

        if ($DryRun) {
            $dryRunImage = $installImages | Select-Object -First 1
            $preparedSetup = Install-Autounattend `
                -MountDir $mountDir `
                -IsoContents $isoContents `
                -AutounattendTemplate (Get-Content -LiteralPath (Get-WinMintPath -Name ConfigRoot -ChildPath 'autounattend.xml') -Raw) `
                -ImageArch $imageArch `
                -TimeZone $BuildConfig.TimeZoneId `
                -TargetPCName $BuildConfig.ComputerName `
                -TargetUser $BuildConfig.AccountName `
                -AccountMode $BuildConfig.AccountMode `
                -TargetPass $BuildConfig.Password `
                -EditionName $dryRunImage.ImageName `
                -EditionMode $editionMode `
                -InstallImageCount $installImages.Count `
                -AutoWipeDisk:$BuildConfig.AutoWipeDisk `
                -AutoLogon:$BuildConfig.AutoLogon `
                -DiskLayout $BuildConfig.DiskLayout `
                -DevDrive $BuildConfig.DevDrive `
                -HardwareBypass:$BuildConfig.Tweaks.HardwareBypass `
                -InputLocale $BuildConfig.InputLocale `
                -SystemLocale $BuildConfig.SystemLocale `
                -UILanguage $BuildConfig.UILanguage `
                -UILanguageFallback $BuildConfig.UILanguageFallback `
                -UserLocale $BuildConfig.SetupUserLocale `
                -ScriptRoot $root `
                -AgentProfile $installPlan.AgentProfile `
                -SetupProfile $installPlan.SetupProfile `
                -SetupPlan $installPlan.SetupPlan `
                -LiveInstallAudit:$BuildConfig.LiveInstallAudit `
                -DryRun
            $dryRunArtifacts = Save-WinMintDryRunArtifacts `
                -Config $BuildConfig `
                -DetectedArchitecture $imageArch `
                -InstallImages $installImages `
                -PreparedSetup $preparedSetup `
                -WorkDir $workDir `
                -IsoContents $isoContents `
                -InstallWim $installWim
            Write-WinMintDryRunArtifactSummary -Artifacts $dryRunArtifacts
            LogOK 'Dry run completed. No WIM customization, output ISO, disk prep, or USB write was performed.'
            return [pscustomobject]@{ OutputIsoPath = $null; WorkDir = $workDir; DryRun = $true; DryRunArtifacts = $dryRunArtifacts }
        }

        # Probe the serviced-install.wim cache before any expensive servicing work.
        # On hit we restore the cached wim over the freshly-staged one and skip the
        # 30-60 min DISM mount/inject/dismount loop. Per-image mount still happens
        # so autounattend/setup scripts can be re-stamped per build.
        $servicedWimCacheHit = $null
        $servicedWimFingerprint = $null
        $updatesRequested = ($BuildConfig.Updates -and [string]$BuildConfig.Updates.Mode -ne 'None')
        if ($updatesRequested) {
            Log 'Stable image updates selected; serviced WIM cache disabled.'
            LogVerbose 'Serviced WIM cache is disabled so update payload application remains auditable.'
        }
        if (-not $NoServicedWimCache -and -not $updatesRequested) {
            try {
                $isoStageKey = Get-WinMintIsoStageCacheKeyHex -Fingerprint (Get-WinMintIsoStageCacheFingerprint -SourceIsoPath $BuildConfig.SourceIso)
                $servicedWimFingerprint = Get-WinMintServicedWimFingerprint -BuildConfig $BuildConfig -IsoStageKey $isoStageKey -ImageCompression $ImageCompression
                $servicedWimCacheHit = Get-WinMintServicedWimCacheHit -Fingerprint $servicedWimFingerprint -ExpectedMetadata $expectedWimMetadata
                if (Get-Command Set-WinMintHeadlessJournalCacheFacts -ErrorAction SilentlyContinue) {
                    $cacheKey = if (-not [string]::IsNullOrWhiteSpace($servicedWimFingerprint)) {
                        Get-WinMintCacheKeyHex -Fingerprint $servicedWimFingerprint
                    } else { '' }
                    Set-WinMintHeadlessJournalCacheFacts `
                        -ServicedWimCacheKey $cacheKey `
                        -ReadyForAssemble:($null -ne $servicedWimCacheHit)
                }
            }
            catch {
                LogVerbose "Serviced WIM cache probe skipped: $($_.Exception.Message)"
                $servicedWimCacheHit = $null
            }
        }
        if ($null -ne $servicedWimCacheHit) {
            Log 'Restoring serviced install.wim from cache...'
            LogVerbose 'Skipping driver injection, appx removal, and package install (serviced WIM cache hit).'
            Copy-Item -LiteralPath $servicedWimCacheHit -Destination $installWim -Force -ErrorAction Stop
            Assert-WinMintWimMetadataHealthy -ImagePath $installWim -ExpectedMetadata $expectedWimMetadata -ExpectedArchitecture $imageArch
            Set-WinMintManifestServicedWimCacheFact -Restored $true
        }

        Sync-NerdFont -FontDir (Join-Path $root 'assets\runtime\fonts')
        Sync-Cursor -CursorsDir (Join-Path $root 'assets\runtime\cursors') -PackKind $BuildConfig.CursorPackKind

        # Resolve drivers even on serviced-WIM cache hits so Setup boot.wim (PE)
        # still receives setup-critical INFs; install.wim injection stays cache-skipped.
        $driverSources = [System.Collections.Generic.List[object]]::new()
        if (Test-WinMintDriverSourceUsesPath -Source ([string]$BuildConfig.Drivers.Source)) {
            $customDrivers = Resolve-Win11IsoCustomDriverSource `
                -Path $BuildConfig.Drivers.Path `
                -WorkDir $workDir `
                -DriverSource ([string]$BuildConfig.Drivers.Source) `
                -TargetDevice ([string]$BuildConfig.TargetDevice) `
                -TargetArchitecture $imageArch `
                -WindowsBuild $sourceWindowsBuild
            if ($customDrivers -and $customDrivers.Ready) {
                $driverSources.Add($customDrivers)
            }
        }
        if ($ExportHostDrivers) {
            $hostDriverDir = Join-Path $workDir 'host_drivers'
            $hostDriverCache = Get-WinMintHostDriverExportCacheHit
            if ($null -ne $hostDriverCache) {
                Log 'Restoring host drivers from cache...'
                LogVerbose 'Skipping Export-WindowsDriver (temp host-driver cache hit).'
                $null = New-Item -ItemType Directory -Path $hostDriverDir -Force
                Invoke-RobocopyChecked -Source $hostDriverCache -Dest $hostDriverDir -UserFacingMessage 'Copying cached host driver export into the work folder…'
                Clear-WinMintReadOnlyAttribute -Path $hostDriverDir
            }
            else {
                Invoke-Action 'Exporting host drivers for injection' {
                    Export-WinMintHostDrivers -Destination $hostDriverDir | Out-Null
                }
                Publish-WinMintHostDriverExportCache -SourceDir $hostDriverDir
            }
            $hostMirrorFilter = [string]$BuildConfig.HostMirrorFilter
            if ([string]::IsNullOrWhiteSpace($hostMirrorFilter)) { $hostMirrorFilter = 'setup-critical' }
            $hostSource = $hostDriverDir
            $hostLabel = 'Host export'
            if ($hostMirrorFilter -eq 'setup-critical') {
                $filteredHostDir = Join-Path $workDir 'host_drivers_filtered'
                $filteredCount = Export-WinMintFilteredHostDrivers -Source $hostDriverDir -Destination $filteredHostDir -Filter setup-critical
                if ($filteredCount -lt 1) {
                    LogWarn 'Host driver mirror filter produced no setup-critical INFs; skipping host mirror injection.'
                }
                else {
                    $hostSource = $filteredHostDir
                    $hostLabel = "Host export ($hostMirrorFilter, $filteredCount .inf)"
                    LogOK "Host driver mirror filtered to $filteredCount setup-critical .inf file(s)."
                }
            }
            if ($hostSource -eq $hostDriverDir -or (Get-ChildItem -LiteralPath $hostSource -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
                $driverSources.Add([pscustomobject]@{ Source = $hostSource; Label = $hostLabel })
            }
        }

        Start-PipelinePhase 'Service WIM'
        if (Get-Command Set-WinMintHeadlessJournalPhase -ErrorAction SilentlyContinue) {
            Set-WinMintHeadlessJournalPhase -Phase 'ServiceWim' -WorkDir $workDir -MountDir $mountDir -IsoContents $isoContents
        }
        $firstServicedImage = $true
        $imageOrdinal = 0
        $imageTotal = @($installImages).Count
        foreach ($image in $installImages) {
            $imageOrdinal++
            $imgName = Get-WimImageName -img $image
            if ([string]::IsNullOrWhiteSpace($imgName)) { $imgName = "index $($image.ImageIndex)" }
            Write-SectionHeader "Image ${imageOrdinal}/${imageTotal}: service $imgName"
            Log "Mounting $imgName ($imageOrdinal/$imageTotal)..."
            LogVerbose "Mounting install.wim index $($image.ImageIndex) ($imgName) into $mountDir"
            $mountTimer = [System.Diagnostics.Stopwatch]::StartNew()
            Mount-WinMintImage -ImagePath $installWim -Index $image.ImageIndex -MountDir $mountDir
            $mountTimer.Stop()
            LogOK "Mounted $imgName in $(Format-WinMintDuration -Duration $mountTimer.Elapsed)."
            LogVerbose "install.wim index $($image.ImageIndex) mounted; proceeding to servicing."
            $mountedImage = $true
            $null = Save-WinMintWingetConfigurationHandoff -Config $BuildConfig -OutputDir (Get-WinMintOutputDirectory)
            Install-Autounattend `
                -MountDir $mountDir `
                -IsoContents $isoContents `
                -AutounattendTemplate (Get-Content -LiteralPath (Get-WinMintPath -Name ConfigRoot -ChildPath 'autounattend.xml') -Raw) `
                -ImageArch $imageArch `
                -TimeZone $BuildConfig.TimeZoneId `
                -TargetPCName $BuildConfig.ComputerName `
                -TargetUser $BuildConfig.AccountName `
                -AccountMode $BuildConfig.AccountMode `
                -TargetPass $BuildConfig.Password `
                -EditionName $imgName `
                -EditionMode $editionMode `
                -ProductKey $(if ($editionMode -eq 'Fixed') { [string]$BuildConfig.ProductKey } else { '' }) `
                -InstallImageCount $installImages.Count `
                -AutoWipeDisk:$BuildConfig.AutoWipeDisk `
                -AutoLogon:$BuildConfig.AutoLogon `
                -DiskLayout $BuildConfig.DiskLayout `
                -DevDrive $BuildConfig.DevDrive `
                -HardwareBypass:$BuildConfig.Tweaks.HardwareBypass `
                -InputLocale $BuildConfig.InputLocale `
                -SystemLocale $BuildConfig.SystemLocale `
                -UILanguage $BuildConfig.UILanguage `
                -UILanguageFallback $BuildConfig.UILanguageFallback `
                -UserLocale $BuildConfig.SetupUserLocale `
                -ScriptRoot $root `
                -AgentProfile $installPlan.AgentProfile `
                -SetupProfile $installPlan.SetupProfile `
                -SetupPlan $installPlan.SetupPlan `
                -LiveInstallAudit:$BuildConfig.LiveInstallAudit

            if ($null -eq $servicedWimCacheHit) {
                Invoke-AppxRemoval -MountDir $mountDir -PackagePrefixes $BuildConfig.AppxPackages -AiPackagePrefixes $BuildConfig.AiRemoval.AppxPrefixes
                Invoke-WinMintOfflineAiFeatureRemoval -MountDir $mountDir -AiRemoval $BuildConfig.AiRemoval
                Remove-WinMintCapabilities -MountDir $mountDir
                # Preserve only the display language(s); en-us is always kept by the
                # function. System/user/setup locales are formats/region (and the
                # DMA setup locale is en-IE), not display-language packs — including
                # them here would leave non-US English packs behind. The default
                # en-US build therefore keeps only the US English language packs.
                Remove-NonEnglishLanguageFeature `
                    -MountDir $mountDir `
                    -PreserveLanguages @($BuildConfig.UILanguage, $BuildConfig.UILanguageFallback) `
                    -InputLanguages @($BuildConfig.SecondaryInputLanguages) `
                    -Confirm:$false
                Invoke-RegistryTweak -MountDir $mountDir -GroupIds $BuildConfig.RegistryTweaks
                Import-WinMintDefaultAppAssociations -MountDir $mountDir -XmlPath (Join-Path $root 'assets\runtime\defaultapps\WinMint-DefaultAppAssociations.xml')
                Remove-WinMintOneDriveSetupStub -MountDir $mountDir
                Enable-WinMintOptionalFeature -MountDir $mountDir -Features $BuildConfig.Features
                Install-OfflinePowerShell7 -MountDir $mountDir -TargetArch $imageArch
                Install-OfflineFont -MountDir $mountDir -ScriptDir $root
                Install-OfflineCursor -MountDir $mountDir -ScriptDir $root -CursorPackKind $BuildConfig.CursorPackKind
                Install-OfflineWindowsTerminalSettings -MountDir $mountDir -ScriptDir $root
                Install-OfflineWinget -MountDir $mountDir -TargetArch $imageArch
                Invoke-WinMintOfflineImageUpdates -MountDir $mountDir -Updates $BuildConfig.Updates -TargetArch $imageArch

                foreach ($driverSource in $driverSources) {
                    Invoke-DriverInjection `
                        -MountDir $mountDir `
                        -IsoContents $isoContents `
                        -DriverSource $driverSource.Source `
                        -SourceLabel $driverSource.Label `
                        -InjectWinPE:$firstServicedImage
                }
            }
            else {
                Log "Using cached serviced image for $imgName."
                LogVerbose "Serviced WIM cache hit: skipping appx removal, package install, and install.wim driver injection for $imgName."
                if ($firstServicedImage -and $driverSources.Count -gt 0) {
                    Log 'Serviced WIM cache hit: injecting setup-critical drivers into boot.wim (WinPE) only.'
                    foreach ($driverSource in $driverSources) {
                        Invoke-DriverInjection `
                            -MountDir $mountDir `
                            -IsoContents $isoContents `
                            -DriverSource $driverSource.Source `
                            -SourceLabel $driverSource.Label `
                            -InjectWinPE:$true `
                            -WinPEOnly
                    }
                }
                elseif ($firstServicedImage -and (Get-Command Set-WinMintManifestWinPeDriverFact -ErrorAction SilentlyContinue)) {
                    Set-WinMintManifestWinPeDriverFact -Attempted:$false -Injected:$false -Reason 'no-driver-sources' -Indexes @() -InfCount 0
                }
            }
            Assert-OfflinePowerShell7Staged -MountDir $mountDir

            Save-ImageWithCleanup `
                -MountDir $mountDir `
                -ImageCompression $ImageCompression `
                -SkipComponentCleanup:($null -ne $servicedWimCacheHit)
            $mountedImage = $false
            $firstServicedImage = $false
        }
        Complete-PipelinePhase 'Service WIM'
        Set-WinMintManifestSizeDeltaFromPath -Name 'installWimAfterServicingBytes' -Path $installWim
        Assert-WinMintWimMetadataHealthy -ImagePath $installWim -ExpectedMetadata $expectedWimMetadata -ExpectedArchitecture $imageArch
        if (-not $NoServicedWimCache -and -not $updatesRequested -and $null -eq $servicedWimCacheHit -and -not [string]::IsNullOrWhiteSpace($servicedWimFingerprint) -and (Test-Path -LiteralPath $installWim)) {
            Publish-WinMintServicedWimCache -Fingerprint $servicedWimFingerprint -ServicedWimPath $installWim -ExpectedMetadata $expectedWimMetadata
            if (Get-Command Set-WinMintHeadlessJournalCacheFacts -ErrorAction SilentlyContinue) {
                Set-WinMintHeadlessJournalCacheFacts `
                    -ServicedWimCacheKey (Get-WinMintCacheKeyHex -Fingerprint $servicedWimFingerprint) `
                    -ReadyForAssemble
            }
        }

        $infNames = @(
            foreach ($ds in $driverSources) {
                if ($ds.Source -and (Test-Path -LiteralPath $ds.Source)) {
                    Get-ChildItem -LiteralPath $ds.Source -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue |
                        Select-Object -ExpandProperty Name
                }
            }
        )
        $driverInventories = @($driverSources | ForEach-Object {
                if ($_.PSObject.Properties['Inventory']) { $_.Inventory }
            } | Where-Object { $null -ne $_ })
        $driverInventoryPath = Save-WinMintDriverInventory -Inventories $driverInventories -OutputDir (Get-WinMintOutputDirectory)
        Set-WinMintManifestDriverFacts -InfNames $infNames -Inventories $driverInventories -InventoryPath $driverInventoryPath

        Install-WinPEUtility -IsoContents $isoContents -AutoWipeDisk:$BuildConfig.AutoWipeDisk
        if ($editionMode -eq 'Fixed') {
            $selectedImage = $installImages | Select-Object -First 1
            Export-SingleEdition -LocalWim $installWim -SelectedWimIndex $selectedImage.ImageIndex -SelectedEdition $selectedImage.ImageName -ImageCompression $ImageCompression
            Assert-WinMintWimMetadataHealthy -ImagePath $installWim -ExpectedMetadata $expectedWimMetadata -ExpectedArchitecture $imageArch -AllowIndexRenumber
        }
        Set-WinMintManifestSizeDeltaFromPath -Name 'installWimAfterExportBytes' -Path $installWim
        Start-PipelinePhase 'Assemble ISO'
        if (Get-Command Set-WinMintHeadlessJournalPhase -ErrorAction SilentlyContinue) {
            Set-WinMintHeadlessJournalPhase -Phase 'AssembleIso' -WorkDir $workDir -MountDir $mountDir -IsoContents $isoContents
        }
        New-WinMintIsoImage -IsoContents $isoContents -ImageArch $imageArch -OutputIso $outputIso
        if (Test-Path -LiteralPath $outputIso) {
            $isoItem = Get-Item -LiteralPath $outputIso
            $isoHash = (Get-FileHash -LiteralPath $outputIso -Algorithm SHA256).Hash
            Set-WinMintManifestOutputIsoSizeFact -SizeBytes ([long]$isoItem.Length)
            LogOK "Final ISO: $outputIso ($(Format-WinMintByteSize -Bytes $isoItem.Length))"
            LogVerbose "Final ISO size: $($isoItem.Length) bytes"
            LogVerbose "Final ISO SHA256: $isoHash"
        }
        Complete-PipelinePhase 'Assemble ISO'
        if ($WriteUsb) {
            if ($UsbDiskNumber -lt 0) { throw '-WriteUsb requires -UsbDiskNumber.' }
            Invoke-FlashWindowsInstallMediaToUsb `
                -IsoPath $outputIso `
                -UsbDiskNumber $UsbDiskNumber `
                -ConfirmUsbDiskNumber $ConfirmUsbDiskNumber `
                -Architecture $imageArch `
                -AllowFixedUsbDisk:$AllowFixedUsbDisk
        }
        return [pscustomobject]@{ OutputIsoPath = $outputIso; WorkDir = $workDir; DryRun = $false }
    }
    catch {
        if ($mountedImage) {
            Dismount-WinMintImageMount -MountDir $mountDir
        }
        throw
    }
    finally {
        if (Get-Command Set-WinMintHeadlessJournalPhase -ErrorAction SilentlyContinue) {
            Set-WinMintHeadlessJournalPhase -Phase 'Cleanup' -WorkDir $workDir -MountDir $mountDir -IsoContents $isoContents
        }
        Invoke-Cleanup -MountDir $mountDir -SourceIso $BuildConfig.SourceIso -WorkDir $workDir
    }
}

