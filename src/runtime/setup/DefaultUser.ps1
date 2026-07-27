# Default user hive tweaks (loaded as HKU\DefaultUser during specialize).
$ErrorActionPreference = 'Continue'
$logDir = Join-Path $env:ProgramData 'WinMint\Logs'
$null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue
$payloadDir = 'C:\Windows\Setup\Scripts'
$setupProfilePath = Join-Path $payloadDir 'WinMintSetupProfile.json'
$setupProfile = $null
try {
    if (Test-Path -LiteralPath $setupProfilePath) {
        $setupProfile = Get-Content -LiteralPath $setupProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
} catch {
    "DefaultUser profile read failed: $_" | Out-File (Join-Path $logDir 'DefaultUser_errors.log') -Append
}

# The specialize pass loads C:\Users\Default\NTUSER.DAT as HKU\DefaultUser before
# this script runs. If that load failed, every reg.exe HKU\DefaultUser write below
# silently no-ops and the new user inherits nothing (vanilla desktop). Detect it and
# log loudly so the failure is visible rather than silent.
$null = & reg.exe query 'HKU\DefaultUser' 2>$null
if ($LASTEXITCODE -ne 0) {
    "HKU\DefaultUser hive is NOT loaded; default-user tweaks (dark mode, wallpaper, taskbar, environment) will not apply. Check the specialize 'reg.exe load HKU\DefaultUser' step." |
        Out-File (Join-Path $logDir 'DefaultUser_errors.log') -Append
}

function Get-SetupProfileBool {
    param(
        [string]$Section,
        [string]$Name,
        [bool]$Default
    )
    if (-not $setupProfile) { return $Default }
    $sectionProp = $setupProfile.PSObject.Properties[$Section]
    if (-not $sectionProp) { return $Default }
    $valueProp = $sectionProp.Value.PSObject.Properties[$Name]
    if (-not $valueProp) { return $Default }
    return [bool]$valueProp.Value
}

function Set-DefaultUserRegistryValue {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Type,
        [Parameter(Mandatory)]
        [string]$Data
    )
    $out = & reg.exe add $Path /v $Name /t $Type /d $Data /f 2>&1
    if ($LASTEXITCODE -ne 0) {
        "reg.exe add '$Path' /v '$Name' failed (exit $LASTEXITCODE): $out" | Out-File (Join-Path $logDir 'DefaultUser_errors.log') -Append
    }
}

function Set-DefaultUserRegistryDefaultValue {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Type,
        [Parameter(Mandatory)]
        [string]$Data
    )
    $out = & reg.exe add $Path /ve /t $Type /d $Data /f 2>&1
    if ($LASTEXITCODE -ne 0) {
        "reg.exe add '$Path' /ve failed (exit $LASTEXITCODE): $out" | Out-File (Join-Path $logDir 'DefaultUser_errors.log') -Append
    }
}

function Remove-DefaultUserRegistryValue {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Name
    )
    $null = & reg.exe delete $Path /v $Name /f 2>$null
}

function Invoke-DefaultUserRegistrySet {
    param(
        [Parameter(Mandatory)]
        [object[]]$Entries
    )
    foreach ($entry in $Entries) {
        Set-DefaultUserRegistryValue -Path $entry.Path -Name $entry.Name -Type $entry.Type -Data $entry.Data
    }
}

$xdgRuntimeDir = '%LOCALAPPDATA%\Temp\xdg-runtime'
$stickyKeysOff = Get-SetupProfileBool -Section 'defaultUser' -Name 'stickyKeysOff' -Default $true
$defaultUserDarkMode = Get-SetupProfileBool -Section 'defaultUser' -Name 'darkMode' -Default $true
$advertisingIdDisabled = Get-SetupProfileBool -Section 'defaultUser' -Name 'advertisingIdDisabled' -Default $true
$defaultWallpaperPath = 'C:\Windows\Web\Wallpaper\Windows\WinMint-Bloom.jpg'

$scripts = @(
    {
        foreach ($folder in @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos')) {
            New-Item -ItemType Directory -Path (Join-Path 'C:\Users\Default' $folder) -Force -ErrorAction SilentlyContinue | Out-Null
        }
        foreach ($folder in @('.config', '.cache', '.local', '.local\share', '.local\state')) {
            New-Item -ItemType Directory -Path (Join-Path 'C:\Users\Default' $folder) -Force -ErrorAction SilentlyContinue | Out-Null
        }
        foreach ($folder in @('bin', '.local\bin')) {
            New-Item -ItemType Directory -Path (Join-Path 'C:\Users\Default' $folder) -Force -ErrorAction SilentlyContinue | Out-Null
        }
        $userShellFolders = 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        foreach ($known in @(
                @{ Name = 'Desktop'; Local = 'Desktop' },
                @{ Name = 'Personal'; Local = 'Documents' },
                @{ Name = 'My Pictures'; Local = 'Pictures' },
                @{ Name = 'My Music'; Local = 'Music' },
                @{ Name = 'My Video'; Local = 'Videos' },
                @{ Name = '{374DE290-123F-4565-9164-39C4925E467B}'; Local = 'Downloads' }
            )) {
            Set-DefaultUserRegistryValue -Path $userShellFolders -Name $known.Name -Type REG_EXPAND_SZ -Data "%USERPROFILE%\$($known.Local)"
        }
        Invoke-DefaultUserRegistrySet -Entries @(
            @{ Path = 'HKU\DefaultUser\Environment'; Name = 'XDG_CONFIG_HOME'; Type = 'REG_EXPAND_SZ'; Data = '%USERPROFILE%\.config' },
            @{ Path = 'HKU\DefaultUser\Environment'; Name = 'XDG_DATA_HOME'; Type = 'REG_EXPAND_SZ'; Data = '%USERPROFILE%\.local\share' },
            @{ Path = 'HKU\DefaultUser\Environment'; Name = 'XDG_STATE_HOME'; Type = 'REG_EXPAND_SZ'; Data = '%USERPROFILE%\.local\state' },
            @{ Path = 'HKU\DefaultUser\Environment'; Name = 'XDG_CACHE_HOME'; Type = 'REG_EXPAND_SZ'; Data = '%USERPROFILE%\.cache' },
            @{ Path = 'HKU\DefaultUser\Environment'; Name = 'XDG_RUNTIME_DIR'; Type = 'REG_EXPAND_SZ'; Data = $xdgRuntimeDir },
            @{ Path = 'HKU\DefaultUser\Environment'; Name = 'Path'; Type = 'REG_EXPAND_SZ'; Data = '%USERPROFILE%\bin;%USERPROFILE%\.local\bin' }
        )
        foreach ($runKey in @(
                'HKU\DefaultUser\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
                'HKU\DefaultUser\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
            )) {
            foreach ($value in @('OneDrive', 'OneDriveSetup')) {
                Remove-DefaultUserRegistryValue -Path $runKey -Name $value
            }
        }
    }
    { Set-DefaultUserRegistryValue -Path 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name ShowTaskViewButton -Type REG_DWORD -Data 0 }
    {
        # Use reg.exe (auto-creates intermediate keys, and a missing hive logs rather
        # than throwing) instead of the registry provider, which throws on a missing
        # parent key and aborts this block.
        foreach ($root in 'HKU\.DEFAULT', 'HKU\DefaultUser') {
            Set-DefaultUserRegistryValue -Path "$root\Control Panel\Keyboard" -Name 'InitialKeyboardIndicators' -Type 'REG_SZ' -Data '2'
        }
    }
    { Set-DefaultUserRegistryValue -Path 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings' -Name TaskbarEndTask -Type REG_DWORD -Data 1 }
    {
        if (-not $stickyKeysOff) { return }
        foreach ($root in 'HKU\.DEFAULT', 'HKU\DefaultUser') {
            Set-DefaultUserRegistryValue -Path "$root\Control Panel\Accessibility\StickyKeys" -Name Flags -Type REG_SZ -Data 506
        }
    }
    {
        if (-not $defaultUserDarkMode) { return }
        $desktopKey = 'HKU\DefaultUser\Control Panel\Desktop'
        Invoke-DefaultUserRegistrySet -Entries @(
            @{ Path = $desktopKey; Name = 'Wallpaper'; Type = 'REG_SZ'; Data = $defaultWallpaperPath },
            @{ Path = $desktopKey; Name = 'WallpaperStyle'; Type = 'REG_SZ'; Data = '10' },
            @{ Path = $desktopKey; Name = 'TileWallpaper'; Type = 'REG_SZ'; Data = '0' }
        )
        Invoke-DefaultUserRegistrySet -Entries @(
            @{ Path = 'HKU\DefaultUser\Software\Microsoft\Windows\DWM'; Name = 'ColorPrevalence'; Type = 'REG_DWORD'; Data = '0' },
            @{ Path = 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'AppsUseLightTheme'; Type = 'REG_DWORD'; Data = '0' },
            @{ Path = 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'SystemUsesLightTheme'; Type = 'REG_DWORD'; Data = '0' }
        )
    }
    # First interactive logon: Winlogon Shell is WinMint splash wrapper, not explorer.exe,
    # so the provisioning cover is the first session UI (fail-open restores explorer).
    {
        Set-DefaultUserRegistryValue -Path 'HKU\DefaultUser\Software\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name Shell -Type REG_SZ -Data 'C:\Windows\Setup\Scripts\WinMintLogonShell.cmd'
    }
    # NOTE: the SVG default-app association is NOT set here anymore. Writing
    # FileExts\.svg\UserChoice\ProgId without the protective per-extension hash is rejected/
    # reset by Windows 11 (and can pop the "an app default was reset" toast). It is now applied
    # the supported way - DISM /Import-DefaultAppAssociations against the offline image (see
    # Import-WinMintDefaultAppAssociations in the build pipeline).

    # Privacy: advertising ID (when profile keeps it disabled).
    {
        if (-not $advertisingIdDisabled) { return }
        Set-DefaultUserRegistryValue -Path 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name Enabled -Type REG_DWORD -Data 0
    }

    # Privacy: feedback frequency.
    { Set-DefaultUserRegistryValue -Path 'HKU\DefaultUser\Software\Microsoft\Siuf\Rules' -Name NumberOfSIUFInPeriod -Type REG_DWORD -Data 0 }

    # Clipboard: keep local history useful, but keep cross-device cloud upload off
    # unless the opt-in Phone Link module enables it for the live user.
    {
        Invoke-DefaultUserRegistrySet -Entries @(
            @{ Path = 'HKU\DefaultUser\Software\Microsoft\Clipboard'; Name = 'EnableClipboardHistory'; Type = 'REG_DWORD'; Data = '1' },
            @{ Path = 'HKU\DefaultUser\Software\Microsoft\Clipboard'; Name = 'CloudClipboardAutomaticUpload'; Type = 'REG_DWORD'; Data = '0' }
        )
    }

    # Privacy: contact harvesting. People/Mail are removed; key is inert.
    { Set-DefaultUserRegistryValue -Path 'HKU\DefaultUser\Software\Microsoft\InputPersonalization\TrainedDataStore' -Name HarvestContacts -Type REG_DWORD -Data 0 }

    # Search: disable Bing in Start and search box web suggestions.
    {
        Invoke-DefaultUserRegistrySet -Entries @(
            @{ Path = 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'BingSearchEnabled'; Type = 'REG_DWORD'; Data = '0' },
            @{ Path = 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'CortanaConsent'; Type = 'REG_DWORD'; Data = '0' },
            @{ Path = 'HKU\DefaultUser\Software\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Type = 'REG_DWORD'; Data = '1' }
        )
    }

    # Taskbar: hide the search box/icon (0 = hidden).
    { Set-DefaultUserRegistryValue -Path 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Type REG_DWORD -Data 0 }

    # Desktop: hide the Recycle Bin icon.
    {
        foreach ($view in 'NewStartPanel', 'ClassicStartMenu') {
            Set-DefaultUserRegistryValue -Path "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\$view" -Name '{645FF040-5081-101B-9F08-00AA002F954E}' -Type REG_DWORD -Data 1
        }
    }

    # Taskbar: replace the default pins so the Microsoft Store pin is gone.
    # A taskbar LayoutModification.xml staged into the Default profile is read on the new
    # user's FIRST explorer start (no reboot needed). PinListPlacement="Replace" clears the
    # stock pins (File Explorer, Edge, Store) and re-pins File Explorer + Windows Terminal.
    {
        $shellDir = 'C:\Users\Default\AppData\Local\Microsoft\Windows\Shell'
        try {
            $null = New-Item -ItemType Directory -Path $shellDir -Force -ErrorAction Stop
            $layout = @(
                '<?xml version="1.0" encoding="utf-8"?>',
                '<LayoutModificationTemplate',
                ' xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"',
                ' xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"',
                ' xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout"',
                ' xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"',
                ' Version="1">',
                '  <CustomTaskbarLayoutCollection PinListPlacement="Replace">',
                '    <defaultlayout:TaskbarLayout>',
                '      <taskbar:TaskbarPinList>',
                '        <taskbar:DesktopApp DesktopApplicationID="Microsoft.Windows.Explorer" />',
                '        <taskbar:UWA AppUserModelID="Microsoft.WindowsTerminal_8wekyb3d8bbwe!App" />',
                '      </taskbar:TaskbarPinList>',
                '    </defaultlayout:TaskbarLayout>',
                '  </CustomTaskbarLayoutCollection>',
                '</LayoutModificationTemplate>'
            ) -join "`r`n"
            Set-Content -LiteralPath (Join-Path $shellDir 'LayoutModification.xml') -Value $layout -Encoding UTF8
        }
        catch { }
    }

    # UX: instant menus.
    { Set-DefaultUserRegistryValue -Path 'HKU\DefaultUser\Control Panel\Desktop' -Name MenuShowDelay -Type REG_SZ -Data '0' }

    # Explorer: disable date-grouping (Today/Yesterday/Last week).
    { Set-DefaultUserRegistryValue -Path 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name GroupByDateModified -Type REG_DWORD -Data 0 }

    # Explorer: open Win+E/File Explorer to Home (matches offline explorer-qol LaunchTo=2).
    { Set-DefaultUserRegistryValue -Path 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name LaunchTo -Type REG_DWORD -Data 2 }

    # Search: disable search highlights (news/seasonal images in search).
    { Set-DefaultUserRegistryValue -Path 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\SearchSettings' -Name IsDynamicSearchBoxEnabled -Type REG_DWORD -Data 0 }

    # Start: hide Recommended section (recent files, suggested content).
    { Set-DefaultUserRegistryValue -Path 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name Start_IrisRecommendations -Type REG_DWORD -Data 0 }

    # Privacy: disable app launch tracking for Start/search suggestions.
    { Set-DefaultUserRegistryValue -Path 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name Start_TrackProgs -Type REG_DWORD -Data 0 }

    # Start: stop seeding recent documents into Recommended.
    { Set-DefaultUserRegistryValue -Path 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name Start_TrackDocs -Type REG_DWORD -Data 0 }

    # Taskbar: hide the Widgets (weather) button (0 = hidden).
    { Set-DefaultUserRegistryValue -Path 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name TaskbarDa -Type REG_DWORD -Data 0 }

    # Taskbar/tray: hide nonessential affordances and keep inactive tray icons collapsed.
    {
        Invoke-DefaultUserRegistrySet -Entries @(
            @{ Path = 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarMn'; Type = 'REG_DWORD'; Data = '0' },
            @{ Path = 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowCopilotButton'; Type = 'REG_DWORD'; Data = '0' },
            @{ Path = 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_AccountNotifications'; Type = 'REG_DWORD'; Data = '0' },
            @{ Path = 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'EnableAutoTray'; Type = 'REG_DWORD'; Data = '1' }
        )
    }

    # Settings/notifications: disable suggestions and setup prompts.
    {
        $contentDeliveryPath = 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        Invoke-DefaultUserRegistrySet -Entries @(
            @{ Path = $contentDeliveryPath; Name = 'SubscribedContent-310093Enabled'; Type = 'REG_DWORD'; Data = '0' },
            @{ Path = $contentDeliveryPath; Name = 'SubscribedContent-338388Enabled'; Type = 'REG_DWORD'; Data = '0' },
            @{ Path = $contentDeliveryPath; Name = 'SubscribedContent-338389Enabled'; Type = 'REG_DWORD'; Data = '0' },
            @{ Path = $contentDeliveryPath; Name = 'SubscribedContent-338393Enabled'; Type = 'REG_DWORD'; Data = '0' },
            @{ Path = $contentDeliveryPath; Name = 'SubscribedContent-353694Enabled'; Type = 'REG_DWORD'; Data = '0' },
            @{ Path = $contentDeliveryPath; Name = 'SubscribedContent-353696Enabled'; Type = 'REG_DWORD'; Data = '0' },
            @{ Path = $contentDeliveryPath; Name = 'SubscribedContent-353698Enabled'; Type = 'REG_DWORD'; Data = '0' },
            @{ Path = $contentDeliveryPath; Name = 'SoftLandingEnabled'; Type = 'REG_DWORD'; Data = '0' },
            @{ Path = $contentDeliveryPath; Name = 'SystemPaneSuggestionsEnabled'; Type = 'REG_DWORD'; Data = '0' }
        )
        Set-DefaultUserRegistryValue -Path 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' -Name ScoobeSystemSettingEnabled -Type REG_DWORD -Data 0
    }

    # Content delivery: prevent silent app installs from CDM.
    {
        Invoke-DefaultUserRegistrySet -Entries @(
            @{ Path = 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SilentInstalledAppsEnabled'; Type = 'REG_DWORD'; Data = '0' },
            @{ Path = 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'PreInstalledAppsEnabled'; Type = 'REG_DWORD'; Data = '0' },
            @{ Path = 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'OemPreInstalledAppsEnabled'; Type = 'REG_DWORD'; Data = '0' }
        )
    }

    # Lock screen: disable Spotlight rotating ads and overlay.
    {
        Invoke-DefaultUserRegistrySet -Entries @(
            @{ Path = 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'RotatingLockScreenEnabled'; Type = 'REG_DWORD'; Data = '0' },
            @{ Path = 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'RotatingLockScreenOverlayEnabled'; Type = 'REG_DWORD'; Data = '0' }
        )
    }

    # Privacy: tailored experiences from diagnostic data.
    { Set-DefaultUserRegistryValue -Path 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Privacy' -Name TailoredExperiencesWithDiagnosticDataEnabled -Type REG_DWORD -Data 0 }

    # F1 key: disable launching browser help page on accidental press.
    { Set-DefaultUserRegistryDefaultValue -Path 'HKU\DefaultUser\SOFTWARE\Classes\TypeLib\{8cec5860-07a1-11d9-b15e-000d56bfe6ee}\1.0\0\win32' -Type REG_SZ -Data '' }
    { Set-DefaultUserRegistryDefaultValue -Path 'HKU\DefaultUser\SOFTWARE\Classes\TypeLib\{8cec5860-07a1-11d9-b15e-000d56bfe6ee}\1.0\0\win64' -Type REG_SZ -Data '' }

    # Windows Terminal default-host delegation is applied at FirstLogon finalize so the
    # setup shell OOBE surface is not interrupted by a stray empty Terminal tab.
)

$errors = [System.Collections.Generic.List[string]]::new()
foreach ($s in $scripts) {
    try { & $s } catch { $errors.Add("DefaultUser: $_") | Out-Null }
}
if ($errors.Count -gt 0) {
    ($errors.ToArray() -join "`n") | Out-File (Join-Path $logDir 'DefaultUser_errors.log') -Append
}
