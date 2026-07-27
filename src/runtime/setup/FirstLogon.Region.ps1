#Requires -Version 5.1

function Get-WinMintFirstLogonUserLocaleName {
    # Persistable user locale (formats). Prefer the International hive over in-process Get-Culture:
    # Set-Culture updates the hive immediately but leaves the FirstLogon process culture on the
    # DMA setup value (en-IE) until thread defaults are repinned.
    try {
        $name = [string](Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\International' -Name LocaleName -ErrorAction Stop).LocaleName
        if (-not [string]::IsNullOrWhiteSpace($name)) { return $name.Trim() }
    }
    catch { }
    return ''
}

function Set-WinMintFirstLogonUserCulture {
    param([Parameter(Mandatory)][string]$CultureName)

    Set-Culture -CultureInfo $CultureName -ErrorAction Stop
    # ponytail: pin process/thread culture so same-session Copy/verify see the restore; hive is source of truth.
    $ci = [cultureinfo]::GetCultureInfo($CultureName)
    [cultureinfo]::CurrentCulture = $ci
    [cultureinfo]::DefaultThreadCurrentCulture = $ci
}

function Wait-WinMintFirstLogonUserCulture {
    # Language-list rebuild races Set-Culture; retry with short backoff until LocaleName matches.
    param(
        [Parameter(Mandatory)][string]$CultureName,
        [int]$TimeoutMs = 1000,
        [int]$PollMs = 50
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $localeAfterSet = ''
    do {
        Set-WinMintFirstLogonUserCulture -CultureName $CultureName
        $localeAfterSet = Get-WinMintFirstLogonUserLocaleName
        if ($localeAfterSet -eq $CultureName) { return $localeAfterSet }
        if ($sw.ElapsedMilliseconds -ge $TimeoutMs) { break }
        Start-Sleep -Milliseconds $PollMs
    } while ($true)

    return $localeAfterSet
}

function Set-WinMintFirstLogonInputLanguages {
    # Set the user language list to [display language] + [secondary input languages], with the
    # display language ALWAYS first (primary) and explicitly pinned as the UI language. This is
    # how a secondary keyboard (e.g. Hebrew) is added without ever changing the display/system
    # language. Uses the official International cmdlets, not registry pokes.
    param(
        [string]$DisplayLanguage = 'en-US',
        [string[]]$SecondaryInputLanguages = @()
    )
    if (-not (Get-Command Set-WinUserLanguageList -ErrorAction SilentlyContinue)) { return }
    if (-not (Get-Command New-WinUserLanguageList -ErrorAction SilentlyContinue)) { return }
    if ([string]::IsNullOrWhiteSpace($DisplayLanguage)) { $DisplayLanguage = 'en-US' }
    $displayPrimary = (($DisplayLanguage -split '-')[0]).ToLowerInvariant()
    $list = New-WinUserLanguageList -Language $DisplayLanguage
    $applied = [System.Collections.Generic.List[string]]::new()
    $applied.Add($DisplayLanguage)
    foreach ($lang in @($SecondaryInputLanguages)) {
        $tag = [string]$lang
        if ([string]::IsNullOrWhiteSpace($tag)) { continue }
        if ((($tag -split '-')[0]).ToLowerInvariant() -eq $displayPrimary) { continue }  # never displace the display language
        if ($applied -contains $tag) { continue }
        $list.Add($tag)
        $applied.Add($tag)
    }
    Set-WinUserLanguageList -LanguageList $list -Force -ErrorAction Stop
    # Hard-pin the UI/display language so a secondary input language can never become the
    # display language (the user requirement: type Hebrew, but the system stays English).
    try { Set-WinUILanguageOverride -Language $DisplayLanguage -ErrorAction SilentlyContinue } catch { }
    "$(Get-Date -Format 'o') Set user language list to: $(@($applied) -join ', ') (display pinned to $DisplayLanguage)." |
        Out-File (Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon.log') -Append
}


function Get-WinMintFirstLogonRegistryValueText {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$Name
    )

    try {
        if (-not (Test-Path -LiteralPath $LiteralPath)) { return $null }
        $item = Get-ItemProperty -LiteralPath $LiteralPath -Name $Name -ErrorAction Stop
        return [string]$item.$Name
    }
    catch {
        return $null
    }
}

function Get-WinMintFirstLogonLocationPostureSnapshot {
    $machineConsent = Get-WinMintFirstLogonRegistryValueText -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' -Name 'Value'
    $userConsent = Get-WinMintFirstLogonRegistryValueText -LiteralPath 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' -Name 'Value'
    $disableLocation = Get-WinMintFirstLogonRegistryValueText -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' -Name 'DisableLocation'
    $sensorPermission = Get-WinMintFirstLogonRegistryValueText -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}' -Name 'SensorPermissionState'
    $lfsvc = Get-WinMintFirstLogonServiceSnapshot -Name 'lfsvc'
    return [ordered]@{
        machineConsent        = if ($null -eq $machineConsent) { '' } else { $machineConsent }
        userConsent           = if ($null -eq $userConsent) { '' } else { $userConsent }
        disableLocationPolicy = if ($null -eq $disableLocation) { $null } else { try { [int]$disableLocation } catch { $disableLocation } }
        sensorPermissionState = if ($null -eq $sensorPermission) { $null } else { try { [int]$sensorPermission } catch { $sensorPermission } }
        locationService       = $lfsvc
    }
}

function Test-WinMintFirstLogonLocationRestoreCompliant {
    param(
        [Parameter(Mandatory)][bool]$RestoreLocationServices,
        [Parameter(Mandatory)]$LocationPosture
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    if (-not $RestoreLocationServices) {
        return @($errors)
    }

    $machineAllow = [string]$LocationPosture.machineConsent -eq 'Allow'
    $userAllow = [string]$LocationPosture.userConsent -eq 'Allow'
    if (-not $machineAllow -and -not $userAllow) {
        $errors.Add("Location consent is not Allow (machine='$($LocationPosture.machineConsent)', user='$($LocationPosture.userConsent)') while restoreLocationServices is enabled.") | Out-Null
    }
    if ($null -ne $LocationPosture.disableLocationPolicy -and [int]$LocationPosture.disableLocationPolicy -eq 1) {
        $errors.Add('DisableLocation policy is still enabled while restoreLocationServices is enabled.') | Out-Null
    }
    $lfsvc = $LocationPosture.locationService
    if (-not $lfsvc -or -not [bool]$lfsvc.present) {
        $errors.Add('Location service (lfsvc) is not present while restoreLocationServices is enabled.') | Out-Null
    }
    elseif ($null -ne $lfsvc.start -and [int]$lfsvc.start -eq 4) {
        $errors.Add("Location service (lfsvc) Start=$($lfsvc.start) (disabled) while restoreLocationServices is enabled.") | Out-Null
    }
    return @($errors)
}

function Set-WinMintFirstLogonLocationServicesPolicy {
    param([bool]$Enabled)

    $policyPath = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'
    $findMyDevicePath = 'HKLM\SOFTWARE\Policies\Microsoft\FindMyDevice'
    $machineConsentPath = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
    $userConsentPath = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
    $sensorOverridePath = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}'
    if ($Enabled) {
        foreach ($name in @('DisableLocation', 'DisableWindowsLocationProvider', 'DisableLocationScripting')) {
            Invoke-WinMintFirstLogonReg -Arguments @('delete', $policyPath, '/v', $name, '/f') -AllowFailure
        }
        Invoke-WinMintFirstLogonReg -Arguments @('delete', $findMyDevicePath, '/v', 'AllowFindMyDevice', '/f') -AllowFailure
        Invoke-WinMintFirstLogonReg -Arguments @('add', $machineConsentPath, '/v', 'Value', '/t', 'REG_SZ', '/d', 'Allow', '/f') -AllowFailure
        Invoke-WinMintFirstLogonReg -Arguments @('add', $userConsentPath, '/v', 'Value', '/t', 'REG_SZ', '/d', 'Allow', '/f') -AllowFailure
        Invoke-WinMintFirstLogonReg -Arguments @('add', $sensorOverridePath, '/v', 'SensorPermissionState', '/t', 'REG_DWORD', '/d', '1', '/f') -AllowFailure
        Invoke-WinMintFirstLogonReg -Arguments @('add', 'HKLM\SYSTEM\CurrentControlSet\Services\lfsvc', '/v', 'Start', '/t', 'REG_DWORD', '/d', '3', '/f') -AllowFailure
        try { Set-Service -Name lfsvc -StartupType Manual -ErrorAction SilentlyContinue } catch { }
    }
    else {
        Invoke-WinMintFirstLogonReg -Arguments @('add', $policyPath, '/v', 'DisableLocation', '/t', 'REG_DWORD', '/d', '1', '/f') -AllowFailure
        Invoke-WinMintFirstLogonReg -Arguments @('add', $policyPath, '/v', 'DisableWindowsLocationProvider', '/t', 'REG_DWORD', '/d', '1', '/f') -AllowFailure
        Invoke-WinMintFirstLogonReg -Arguments @('add', $policyPath, '/v', 'DisableLocationScripting', '/t', 'REG_DWORD', '/d', '1', '/f') -AllowFailure
        Invoke-WinMintFirstLogonReg -Arguments @('add', $findMyDevicePath, '/v', 'AllowFindMyDevice', '/t', 'REG_DWORD', '/d', '0', '/f') -AllowFailure
        Invoke-WinMintFirstLogonReg -Arguments @('add', $machineConsentPath, '/v', 'Value', '/t', 'REG_SZ', '/d', 'Deny', '/f') -AllowFailure
        Invoke-WinMintFirstLogonReg -Arguments @('add', $userConsentPath, '/v', 'Value', '/t', 'REG_SZ', '/d', 'Deny', '/f') -AllowFailure
        Invoke-WinMintFirstLogonReg -Arguments @('add', $sensorOverridePath, '/v', 'SensorPermissionState', '/t', 'REG_DWORD', '/d', '0', '/f') -AllowFailure
    }
}


function Restore-WinMintDmaRegionalDefaults {
    $setupProfile = Read-WinMintFirstLogonSetupProfile
    $dmaInterop = [bool](Get-WinMintFirstLogonNestedProfileValue -BuildProfile $setupProfile -Section 'regional' -Nested 'dmaInterop' -Name 'enabled' -Default $false)
    $reportPath = Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon_RegionalRestore.json'
    if (-not $dmaInterop) {
        $report = [ordered]@{
            enabled = $false
            compliant = $true
            errors = @()
        }
        $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
        return [pscustomobject]@{ Enabled = $false; Compliant = $true; Report = $reportPath }
    }

    $errors = [System.Collections.Generic.List[string]]::new()
    $setupCountry = [string](Get-WinMintFirstLogonNestedProfileValue -BuildProfile $setupProfile -Section 'regional' -Nested 'dmaInterop' -Name 'setupCountry' -Default 'Ireland')
    $setupUserLocale = [string](Get-WinMintFirstLogonNestedProfileValue -BuildProfile $setupProfile -Section 'regional' -Nested 'dmaInterop' -Name 'setupUserLocale' -Default 'en-IE')
    $setupGeoId = [int](Get-WinMintFirstLogonNestedProfileValue -BuildProfile $setupProfile -Section 'regional' -Nested 'dmaInterop' -Name 'setupHomeLocationGeoId' -Default 68)
    $restoreTimeZoneId = [string](Get-WinMintFirstLogonNestedProfileValue -BuildProfile $setupProfile -Section 'regional' -Nested 'dmaInterop' -Name 'restoreTimeZoneId' -Default '')
    $restoreGeoId = [int](Get-WinMintFirstLogonNestedProfileValue -BuildProfile $setupProfile -Section 'regional' -Nested 'dmaInterop' -Name 'restoreHomeLocationGeoId' -Default 244)
    $restoreUiLanguage = [string](Get-WinMintFirstLogonNestedProfileValue -BuildProfile $setupProfile -Section 'regional' -Nested 'dmaInterop' -Name 'restoreUiLanguage' -Default '')
    $restoreUserLocale = [string](Get-WinMintFirstLogonNestedProfileValue -BuildProfile $setupProfile -Section 'regional' -Nested 'dmaInterop' -Name 'restoreUserLocale' -Default '')
    $restoreLocationServices = [bool](Get-WinMintFirstLogonNestedProfileValue -BuildProfile $setupProfile -Section 'regional' -Nested 'dmaInterop' -Name 'restoreLocationServices' -Default $true)
    if ([string]::IsNullOrWhiteSpace($restoreTimeZoneId) -and $setupProfile -and $setupProfile.PSObject.Properties['regional']) {
        $regionalTimeZoneProp = $setupProfile.regional.PSObject.Properties['timeZoneId']
        if ($regionalTimeZoneProp) { $restoreTimeZoneId = [string]$regionalTimeZoneProp.Value }
    }
    if (-not [string]::IsNullOrWhiteSpace($restoreTimeZoneId)) {
        try {
            Set-TimeZone -Id $restoreTimeZoneId -ErrorAction Stop
            "$(Get-Date -Format 'o') Restored Windows time zone to $restoreTimeZoneId after DMA setup." |
                Out-File (Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon.log') -Append
        }
        catch {
            $errors.Add("Time zone restore failed for ${restoreTimeZoneId}: $_") | Out-Null
            Write-WinMintFirstLogonError "Time zone restore failed for ${restoreTimeZoneId}: $_"
        }
        
        try {
            Start-Service w32time -ErrorAction SilentlyContinue
            w32tm /resync /force | Out-Null
            "$(Get-Date -Format 'o') Resynced hardware clock to $restoreTimeZoneId local time." |
                Out-File (Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon.log') -Append
        }
        catch {
            "$(Get-Date -Format 'o') Warning: Clock resync failed: $_" |
                Out-File (Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon.log') -Append
        }
    }
    try {
        Set-WinHomeLocation -GeoId $restoreGeoId -ErrorAction Stop
        "$(Get-Date -Format 'o') Restored Windows home location GeoID to $restoreGeoId after DMA setup." |
            Out-File (Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon.log') -Append
    }
    catch {
        $errors.Add("Home location restore failed for GeoID ${restoreGeoId}: $_") | Out-Null
        Write-WinMintFirstLogonError "Home location restore failed for GeoID ${restoreGeoId}: $_"
    }
    if (-not [string]::IsNullOrWhiteSpace($restoreUiLanguage)) {
        # Rebuild the user language list as [display language] + [secondary input languages].
        # This drops the DMA en-IE entry AND adds any configured secondary keyboards (e.g.
        # he-IL), with the display language pinned so it can never switch. Done BEFORE the
        # system/new-user copy below so the result propagates to the welcome screen + new-user
        # defaults.
        $secondaryInputLanguages = @()
        if ($setupProfile -and $setupProfile.PSObject.Properties['regional'] -and $setupProfile.regional.PSObject.Properties['secondaryInputLanguages']) {
            $secondaryInputLanguages = @($setupProfile.regional.secondaryInputLanguages)
        }
        try {
            Set-WinMintFirstLogonInputLanguages -DisplayLanguage $restoreUiLanguage -SecondaryInputLanguages $secondaryInputLanguages
        }
        catch {
            $errors.Add("Language list rebuild failed: $_") | Out-Null
            Write-WinMintFirstLogonError "Language list rebuild failed: $_"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($restoreUserLocale)) {
        # Settle with backoff after language-list rebuild. Do not sticky-fail here — final
        # LocaleName verify below is the fail-closed gate (intermediate races are expected).
        try {
            $localeAfterSet = Wait-WinMintFirstLogonUserCulture -CultureName $restoreUserLocale -TimeoutMs 1000
            if ($localeAfterSet -eq $restoreUserLocale) {
                "$(Get-Date -Format 'o') Restored user culture to $restoreUserLocale after DMA setup (LocaleName=$localeAfterSet)." |
                    Out-File (Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon.log') -Append
            }
            else {
                "$(Get-Date -Format 'o') User culture settle pending for $restoreUserLocale (LocaleName=$localeAfterSet); will re-pin after international copy." |
                    Out-File (Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon.log') -Append
            }
        }
        catch {
            Write-WinMintFirstLogonError "User culture restore attempt for ${restoreUserLocale}: $_"
        }
    }
    try {
        if (Get-Command Copy-UserInternationalSettingsToSystem -ErrorAction SilentlyContinue) {
            Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true -ErrorAction Stop
            "$(Get-Date -Format 'o') Copied restored international settings to system and new-user defaults." |
                Out-File (Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon.log') -Append
        }
    }
    catch {
        $errors.Add("International settings copy failed: $_") | Out-Null
        Write-WinMintFirstLogonError "International settings copy failed: $_"
    }
    if (-not [string]::IsNullOrWhiteSpace($restoreUserLocale)) {
        # Final pin after system copy — Copy can re-normalize formats from the language list.
        try {
            $localeAfterCopy = Get-WinMintFirstLogonUserLocaleName
            if ($localeAfterCopy -ne $restoreUserLocale) {
                $localeAfterCopy = Wait-WinMintFirstLogonUserCulture -CultureName $restoreUserLocale -TimeoutMs 1000
                if (Get-Command Copy-UserInternationalSettingsToSystem -ErrorAction SilentlyContinue) {
                    Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true -ErrorAction Stop
                }
                "$(Get-Date -Format 'o') Re-applied user culture $restoreUserLocale after international settings copy (LocaleName=$localeAfterCopy)." |
                    Out-File (Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon.log') -Append
            }
        }
        catch {
            # Final LocaleName check below remains fail-closed; avoid double-counting race noise.
            Write-WinMintFirstLogonError "User culture re-pin after international copy failed for ${restoreUserLocale}: $_"
        }
    }
    try { Set-WinMintFirstLogonLocationServicesPolicy -Enabled $restoreLocationServices }
    catch {
        $errors.Add("Location services policy restore failed: $_") | Out-Null
        Write-WinMintFirstLogonError "Location services policy restore failed: $_"
    }
    if (-not $restoreLocationServices) {
        try {
            Invoke-WinMintFirstLogonReg -Arguments @('add', 'HKLM\SYSTEM\CurrentControlSet\Services\tzautoupdate', '/v', 'Start', '/t', 'REG_DWORD', '/d', '4', '/f') -AllowFailure
            Stop-Service -Name tzautoupdate -ErrorAction SilentlyContinue
            Set-Service -Name tzautoupdate -StartupType Disabled -ErrorAction Stop
            "$(Get-Date -Format 'o') Disabled Auto Time Zone Updater because location services are off." |
                Out-File (Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon.log') -Append
        }
        catch {
            $errors.Add("Auto Time Zone Updater disable failed after DMA setup: $_") | Out-Null
            Write-WinMintFirstLogonError "Auto Time Zone Updater disable failed after DMA setup: $_"
        }
    }
    else {
        try {
            Invoke-WinMintFirstLogonReg -Arguments @('add', 'HKLM\SYSTEM\CurrentControlSet\Services\tzautoupdate', '/v', 'Start', '/t', 'REG_DWORD', '/d', '3', '/f') -AllowFailure
            Set-Service -Name tzautoupdate -StartupType Manual -ErrorAction Stop
        }
        catch {
            $errors.Add("Auto Time Zone Updater enable failed after DMA setup: $_") | Out-Null
            Write-WinMintFirstLogonError "Auto Time Zone Updater enable failed after DMA setup: $_"
        }
        "$(Get-Date -Format 'o') Enabled Auto Time Zone Updater because location services are on." |
            Out-File (Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon.log') -Append
    }

    $observedTimeZone = $null
    $observedHomeLocation = $null
    $observedLocaleName = Get-WinMintFirstLogonUserLocaleName
    $observedProcessCulture = ''
    $observedPrimaryLanguageTag = ''
    $observedUiLanguageOverride = ''
    try { $observedTimeZone = Get-TimeZone } catch { $errors.Add("Time zone verification failed: $_") | Out-Null }
    try { $observedHomeLocation = Get-WinHomeLocation } catch { $errors.Add("Home location verification failed: $_") | Out-Null }
    try { $observedProcessCulture = [string](Get-Culture).Name } catch { }
    try {
        if (Get-Command Get-WinUserLanguageList -ErrorAction SilentlyContinue) {
            $primaryLanguage = Get-WinUserLanguageList -ErrorAction Stop | Select-Object -First 1
            if ($null -ne $primaryLanguage) {
                $observedPrimaryLanguageTag = [string]$primaryLanguage.LanguageTag
            }
        }
    }
    catch {
        $errors.Add("Primary language list verification failed: $_") | Out-Null
    }
    try {
        if (Get-Command Get-WinUILanguageOverride -ErrorAction SilentlyContinue) {
            $uiOverride = Get-WinUILanguageOverride -ErrorAction Stop
            if ($uiOverride) { $observedUiLanguageOverride = [string]$uiOverride }
        }
    }
    catch {
        $errors.Add("UI language override verification failed: $_") | Out-Null
    }

    $observedGeoIdText = if ($observedHomeLocation) { [string]([int]$observedHomeLocation.GeoId) } else { '0' }
    $observedTimeZoneText = if ($observedTimeZone) { [string]$observedTimeZone.Id } else { '' }
    if ($restoreGeoId -gt 0 -and (-not $observedHomeLocation -or [int]$observedHomeLocation.GeoId -ne $restoreGeoId)) {
        $errors.Add("Current home location GeoID '$observedGeoIdText' does not match restore GeoID '$restoreGeoId'.") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($restoreTimeZoneId) -and (-not $observedTimeZone -or [string]$observedTimeZone.Id -ne $restoreTimeZoneId)) {
        $errors.Add("Current time zone '$observedTimeZoneText' does not match restore time zone '$restoreTimeZoneId'.") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($restoreUiLanguage)) {
        $languageConfigured = (-not [string]::IsNullOrWhiteSpace($observedPrimaryLanguageTag) -and $observedPrimaryLanguageTag -eq $restoreUiLanguage)
        $overrideConfigured = (-not [string]::IsNullOrWhiteSpace($observedUiLanguageOverride) -and $observedUiLanguageOverride -eq $restoreUiLanguage)
        if (-not $languageConfigured -and -not $overrideConfigured) {
            $errors.Add("Configured display language '$observedPrimaryLanguageTag' / UI override '$observedUiLanguageOverride' does not match restore UI language '$restoreUiLanguage'.") | Out-Null
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($restoreUserLocale) -and ($observedLocaleName -ne $restoreUserLocale)) {
        $errors.Add("Current LocaleName '$observedLocaleName' (process culture '$observedProcessCulture') does not match configured restore culture '$restoreUserLocale'.") | Out-Null
    }

    $locationPosture = Get-WinMintFirstLogonLocationPostureSnapshot
    foreach ($locationError in @(Test-WinMintFirstLogonLocationRestoreCompliant -RestoreLocationServices $restoreLocationServices -LocationPosture $locationPosture)) {
        $errors.Add([string]$locationError) | Out-Null
    }

    $report = [ordered]@{
        enabled = $true
        requested = [ordered]@{
            setupCountry = $setupCountry
            setupUserLocale = $setupUserLocale
            setupHomeLocationGeoId = $setupGeoId
            restoreTimeZoneId = $restoreTimeZoneId
            restoreUiLanguage = $restoreUiLanguage
            restoreUserLocale = $restoreUserLocale
            restoreHomeLocationGeoId = $restoreGeoId
            restoreLocationServices = $restoreLocationServices
        }
        observed = [ordered]@{
            timeZoneId = if ($observedTimeZone) { [string]$observedTimeZone.Id } else { '' }
            localeName = $observedLocaleName
            culture = $observedLocaleName
            processCulture = $observedProcessCulture
            primaryLanguageTag = $observedPrimaryLanguageTag
            uiLanguageOverride = $observedUiLanguageOverride
            homeLocationGeoId = if ($observedHomeLocation) { [int]$observedHomeLocation.GeoId } else { 0 }
            homeLocation = if ($observedHomeLocation) { [string]$observedHomeLocation.HomeLocation } else { '' }
            tzautoupdate = Get-WinMintFirstLogonServiceSnapshot -Name 'tzautoupdate'
            locationService = $locationPosture.locationService
            locationPosture = $locationPosture
        }
        compliant = ($errors.Count -eq 0)
        errors = $errors.ToArray()
    }
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    return [pscustomobject]@{ Enabled = $true; Compliant = [bool]$report.compliant; Report = $reportPath; Errors = $errors.ToArray() }
}


function Repair-WinMintFirstLogonKnownFolders {
    $errors = [System.Collections.Generic.List[string]]::new()
    $userShellFolders = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $shellFolders = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
    $knownFolders = @(
        @{ Name = 'Desktop'; Local = 'Desktop' },
        @{ Name = 'Personal'; Local = 'Documents' },
        @{ Name = 'My Pictures'; Local = 'Pictures' },
        @{ Name = 'My Music'; Local = 'Music' },
        @{ Name = 'My Video'; Local = 'Videos' },
        @{ Name = '{374DE290-123F-4565-9164-39C4925E467B}'; Local = 'Downloads' }
    )

    foreach ($folder in @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos')) {
        New-Item -ItemType Directory -Path (Join-Path $env:USERPROFILE $folder) -Force -ErrorAction SilentlyContinue | Out-Null
    }

    foreach ($known in $knownFolders) {
        $expandValue = "%USERPROFILE%\$($known.Local)"
        $absoluteValue = Join-Path $env:USERPROFILE $known.Local
        try {
            Invoke-WinMintFirstLogonReg -Arguments @('add', $userShellFolders, '/v', $known.Name, '/t', 'REG_EXPAND_SZ', '/d', $expandValue, '/f') -AllowFailure
            Invoke-WinMintFirstLogonReg -Arguments @('add', $shellFolders, '/v', $known.Name, '/t', 'REG_SZ', '/d', $absoluteValue, '/f') -AllowFailure
        }
        catch {
            $errors.Add("Known folder repair failed for $($known.Name): $_") | Out-Null
        }
    }

    $userShell = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue
    $shell = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' -ErrorAction SilentlyContinue
    $observed = [ordered]@{}
    foreach ($known in $knownFolders) {
        $userProp = if ($userShell) { $userShell.PSObject.Properties[$known.Name] } else { $null }
        $shellProp = if ($shell) { $shell.PSObject.Properties[$known.Name] } else { $null }
        $observed[$known.Name] = [ordered]@{
            userShellFolder = if ($userProp) { [string]$userProp.Value } else { '' }
            shellFolder = if ($shellProp) { [string]$shellProp.Value } else { '' }
        }
    }

    $report = [ordered]@{
        timestamp = Get-Date -Format o
        expectedRoot = '%USERPROFILE%'
        observed = $observed
        compliant = ($errors.Count -eq 0)
        errors = $errors.ToArray()
    }
    $path = Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon_KnownFolders.json'
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    "$(Get-Date -Format 'o') Known folder verification written to $path" | Out-File (Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon.log') -Append
}


