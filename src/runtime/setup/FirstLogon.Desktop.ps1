#Requires -Version 5.1

function Set-WinMintFirstLogonEnvironmentValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    Invoke-WinMintFirstLogonReg -Arguments @('add', 'HKCU\Environment', '/v', $Name, '/t', 'REG_EXPAND_SZ', '/d', $Value, '/f') -AllowFailure
}


function Set-WinMintFirstLogonDesktopDefaults {
    $wallpaperPath = 'C:\Windows\Web\Wallpaper\Windows\WinMint-Bloom.jpg'
    $desktopKey = 'HKCU\Control Panel\Desktop'
    $personalizeKey = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $dwmKey = 'HKCU\Software\Microsoft\Windows\DWM'

    Invoke-WinMintFirstLogonReg -Arguments @('add', $personalizeKey, '/v', 'AppsUseLightTheme', '/t', 'REG_DWORD', '/d', '0', '/f') -AllowFailure
    Invoke-WinMintFirstLogonReg -Arguments @('add', $personalizeKey, '/v', 'SystemUsesLightTheme', '/t', 'REG_DWORD', '/d', '0', '/f') -AllowFailure
    Invoke-WinMintFirstLogonReg -Arguments @('add', $dwmKey, '/v', 'ColorPrevalence', '/t', 'REG_DWORD', '/d', '0', '/f') -AllowFailure

    # Aesthetic defaults for the live user (mirror of the Default-hive values, applied to
    # HKCU so they are guaranteed set for this account): hide the taskbar search box and
    # remove the Recycle Bin desktop icon.
    $searchKey = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search'
    Invoke-WinMintFirstLogonReg -Arguments @('add', $searchKey, '/v', 'SearchboxTaskbarMode', '/t', 'REG_DWORD', '/d', '0', '/f') -AllowFailure
    foreach ($view in 'NewStartPanel', 'ClassicStartMenu') {
        $hideKey = "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\$view"
        Invoke-WinMintFirstLogonReg -Arguments @('add', $hideKey, '/v', '{645FF040-5081-101B-9F08-00AA002F954E}', '/t', 'REG_DWORD', '/d', '1', '/f') -AllowFailure
    }

    if (Test-Path -LiteralPath $wallpaperPath) {
        Invoke-WinMintFirstLogonReg -Arguments @('add', $desktopKey, '/v', 'Wallpaper', '/t', 'REG_SZ', '/d', $wallpaperPath, '/f') -AllowFailure
        Invoke-WinMintFirstLogonReg -Arguments @('add', $desktopKey, '/v', 'WallpaperStyle', '/t', 'REG_SZ', '/d', '10', '/f') -AllowFailure
        Invoke-WinMintFirstLogonReg -Arguments @('add', $desktopKey, '/v', 'TileWallpaper', '/t', 'REG_SZ', '/d', '0', '/f') -AllowFailure
        try {
            Initialize-WinMintShellNative
            [void][WinMint.Native.Shell]::SystemParametersInfo(20, 0, $wallpaperPath, 3)
        }
        catch { }
    }

    # Windows applies the light default theme at first logon; registry alone is not enough for
    # an already-running shell. Shared helper (also used by PreLock before early splash host).
    try {
        Broadcast-WinMintThemeChange
    }
    catch { Write-WinMintFirstLogonError "Theme-change broadcast failed: $_" }
}


function Set-WinMintFirstLogonCursorScheme {
    $schemeName = 'Windows 11 Modern'
    $destSeg = 'Windows11Modern'
    $base = "%SystemRoot%\Cursors\$destSeg"
    $cursorDir = Join-Path $env:SystemRoot "Cursors\$destSeg"
    $schemeOrder = @(
        'Arrow.cur', 'Help.cur', 'Work.ani', 'Busy.ani', 'Cross.cur', 'IBeam.cur', 'Handwriting.cur', 'Unavailable.cur',
        'SizeNS.cur', 'SizeWE.cur', 'SizeNWSE.cur', 'SizeNESW.cur', 'Move.cur', 'Alternate.cur', 'Link.cur',
        'Pin.cur', 'Person.cur'
    )
    $cursorPairs = @(
        @{ Name = 'Arrow'; File = 'Arrow.cur' }
        @{ Name = 'Help'; File = 'Help.cur' }
        @{ Name = 'AppStarting'; File = 'Work.ani' }
        @{ Name = 'Wait'; File = 'Busy.ani' }
        @{ Name = 'Crosshair'; File = 'Cross.cur' }
        @{ Name = 'IBeam'; File = 'IBeam.cur' }
        @{ Name = 'NWPen'; File = 'Handwriting.cur' }
        @{ Name = 'No'; File = 'Unavailable.cur' }
        @{ Name = 'SizeNS'; File = 'SizeNS.cur' }
        @{ Name = 'SizeWE'; File = 'SizeWE.cur' }
        @{ Name = 'SizeNWSE'; File = 'SizeNWSE.cur' }
        @{ Name = 'SizeNESW'; File = 'SizeNESW.cur' }
        @{ Name = 'SizeAll'; File = 'Move.cur' }
        @{ Name = 'UpArrow'; File = 'Alternate.cur' }
        @{ Name = 'Hand'; File = 'Link.cur' }
        @{ Name = 'Pin'; File = 'Pin.cur' }
        @{ Name = 'Person'; File = 'Person.cur' }
    )

    foreach ($file in $schemeOrder) {
        if (-not (Test-Path -LiteralPath (Join-Path $cursorDir $file))) {
            Write-WinMintFirstLogonError "Cursor scheme file missing; live cursor apply skipped: $(Join-Path $cursorDir $file)"
            return
        }
    }

    $schemeList = ($schemeOrder | ForEach-Object { "$base\$_" }) -join ','
    $schemesKey = 'HKCU\Control Panel\Cursors\Schemes'
    $cursorsKey = 'HKCU\Control Panel\Cursors'
    Invoke-WinMintFirstLogonReg -Arguments @('add', $schemesKey, '/v', $schemeName, '/t', 'REG_EXPAND_SZ', '/d', $schemeList, '/f') -AllowFailure
    Invoke-WinMintFirstLogonReg -Arguments @('add', $cursorsKey, '/ve', '/t', 'REG_SZ', '/d', $schemeName, '/f') -AllowFailure
    foreach ($pair in $cursorPairs) {
        Invoke-WinMintFirstLogonReg -Arguments @('add', $cursorsKey, '/v', $pair.Name, '/t', 'REG_EXPAND_SZ', '/d', "$base\$($pair.File)", '/f') -AllowFailure
    }

    Add-Type -Namespace WinMint.Native -Name Cursor -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool SystemParametersInfo(int uiAction, int uiParam, System.IntPtr pvParam, int fWinIni);
'@ -ErrorAction SilentlyContinue

    try {
        # SPI_SETCURSORS reloads the active cursor set from HKCU after first-logon writes.
        $spiSetCursors = 0x0057
        $spifUpdateIniFile = 0x01
        $spifSendChange = 0x02
        [void][WinMint.Native.Cursor]::SystemParametersInfo($spiSetCursors, 0, [IntPtr]::Zero, ($spifUpdateIniFile -bor $spifSendChange))
        "$(Get-Date -Format 'o') Live user cursor scheme applied: $schemeName" | Out-File (Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon.log') -Append
    }
    catch {
        Write-WinMintFirstLogonError "Cursor refresh failed: $_"
    }
}


function Resolve-WinMintFirstLogonAppExecutable {
    param([Parameter(Mandatory)][string]$Id)

    $candidates = switch ($Id) {
        'zen-browser' {
            @(
                (Join-Path $env:ProgramFiles 'Zen Browser\zen.exe'),
                (Join-Path ${env:ProgramFiles(x86)} 'Zen Browser\zen.exe'),
                (Join-Path $env:LOCALAPPDATA 'Programs\Zen Browser\zen.exe')
            )
            break
        }
        'cursor' {
            @(
                (Join-Path $env:LOCALAPPDATA 'Programs\cursor\Cursor.exe'),
                (Join-Path $env:LOCALAPPDATA 'Programs\Cursor\Cursor.exe'),
                (Join-Path $env:ProgramFiles 'Cursor\Cursor.exe')
            )
            break
        }
        'helium' {
            @(
                (Join-Path $env:LOCALAPPDATA 'imput\Helium\Application\chrome.exe'),
                (Join-Path $env:ProgramFiles 'Helium\Application\chrome.exe'),
                (Join-Path ${env:ProgramFiles(x86)} 'Helium\Application\chrome.exe')
            )
            break
        }
        'vscode' {
            @(
                (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'),
                (Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe')
            )
            break
        }
        'zed' {
            @(
                (Join-Path $env:LOCALAPPDATA 'Programs\Zed\Zed.exe'),
                (Join-Path $env:ProgramFiles 'Zed\Zed.exe')
            )
            break
        }
        'antigravity' {
            @(
                (Join-Path $env:LOCALAPPDATA 'Programs\Antigravity\Antigravity.exe'),
                (Join-Path $env:ProgramFiles 'Antigravity\Antigravity.exe')
            )
            break
        }
        'edge' {
            @(
                (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
                (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
            )
            break
        }
        'brave' {
            @(
                (Join-Path $env:ProgramFiles 'BraveSoftware\Brave-Browser\Application\brave.exe'),
                (Join-Path ${env:ProgramFiles(x86)} 'BraveSoftware\Brave-Browser\Application\brave.exe'),
                (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\Application\brave.exe')
            )
            break
        }
        'firefox-developer-edition' {
            @(
                (Join-Path $env:ProgramFiles 'Firefox Developer Edition\firefox.exe'),
                (Join-Path ${env:ProgramFiles(x86)} 'Firefox Developer Edition\firefox.exe')
            )
            break
        }
        default { @() }
    }

    foreach ($candidate in @($candidates)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate) -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }
    return $null
}


function Get-WinMintFirstLogonAppDisplayName {
    param(
        [Parameter(Mandatory)][string]$Id,
        [hashtable]$DisplayNames = @{}
    )

    switch ($Id) {
        'zen-browser' { 'Zen Browser' }
        'helium' { 'Helium' }
        'firefox-developer-edition' { 'Firefox Developer Edition' }
        'brave' { 'Brave' }
        'edge' { 'Microsoft Edge' }
        'cursor' { 'Cursor' }
        'vscode' { 'Visual Studio Code' }
        'zed' { 'Zed' }
        'antigravity' { 'Antigravity' }
        default {
            if ($DisplayNames.ContainsKey($Id)) { $DisplayNames[$Id] } else { $Id }
        }
    }
}


function Get-WinMintFirstLogonPackageDisplayNames {
    param([Parameter(Mandatory)][string]$AgentProfilePath)

    $names = @{}
    $packagesPath = Join-Path (Split-Path -Parent $AgentProfilePath) 'packages.json'
    if (-not (Test-Path -LiteralPath $packagesPath -PathType Leaf)) { return $names }

    try {
        $packages = Get-Content -LiteralPath $packagesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($toolProperty in @($packages.tools.PSObject.Properties)) {
            $displayName = [string]$toolProperty.Value.displayName
            if (-not [string]::IsNullOrWhiteSpace($displayName)) {
                $names[[string]$toolProperty.Name] = $displayName
            }
        }
    }
    catch {
        Write-WinMintFirstLogonError "Start pin package display-name lookup failed: $_"
    }
    return $names
}


function Resolve-WinMintFirstLogonStartShortcut {
    param([Parameter(Mandatory)][string]$DisplayName)

    $roots = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
    )
    $escaped = [regex]::Escape($DisplayName)
    foreach ($rootPath in $roots) {
        if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) { continue }
        $shortcut = Get-ChildItem -LiteralPath $rootPath -Recurse -Filter '*.lnk' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -match "^$escaped(?:\s|$)" -and $_.BaseName -notmatch '^(?i)uninstall\s' } |
            Sort-Object @{ Expression = { if ($_.BaseName -eq $DisplayName) { 0 } else { 1 } } }, FullName |
            Select-Object -First 1
        if ($shortcut) { return $shortcut.FullName }
    }
    return $null
}


function New-WinMintFirstLogonStartShortcut {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$TargetPath
    )

    $shortcutDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    $null = New-Item -ItemType Directory -Path $shortcutDir -Force -ErrorAction Stop
    $shortcutPath = Join-Path $shortcutDir "$Name.lnk"
    $wsh = New-Object -ComObject WScript.Shell
    $shortcut = $wsh.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $TargetPath
    $shortcut.WorkingDirectory = Split-Path -Parent $TargetPath
    $shortcut.IconLocation = "$TargetPath,0"
    $shortcut.Save()
    return $shortcutPath
}


function Get-WinMintFirstLogonCliOnlyPinAppIds {
    @('neovim')
}

function Get-WinMintFirstLogonPinSelection {
    <#
    .SYNOPSIS
        Pure pin-policy selection for Start + taskbar from profile arrays.
    #>
    param(
        [string[]]$Browsers = @(),
        [string[]]$Editors = @(),
        # Obsolete: Edge pinning follows development.browsers containing 'edge'.
        [bool]$KeepEdge = $false
    )

    $cliOnly = @(Get-WinMintFirstLogonCliOnlyPinAppIds)
    $includeEdge = @($Browsers | ForEach-Object { [string]$_ }) -contains 'edge'
    $null = $KeepEdge # accepted for call-site compat; pinning ignores keep.edge
    $browserIds = @(
        @($Browsers) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -ne 'edge' -and $cliOnly -notcontains $_ } |
            Select-Object -Unique
    )
    $editorIds = @(
        @($Editors) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $cliOnly -notcontains $_ } |
            Select-Object -Unique
    )
    $pinEdgeToStart = [bool]$includeEdge
    $pinEdgeToTaskbar = [bool]$includeEdge -and ($browserIds.Count -eq 0)
    $startAppIds = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $browserIds) { $startAppIds.Add($id) | Out-Null }
    if ($pinEdgeToStart) { $startAppIds.Add('edge') | Out-Null }
    foreach ($id in $editorIds) { $startAppIds.Add($id) | Out-Null }
    $taskbarAppIds = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $browserIds) { $taskbarAppIds.Add($id) | Out-Null }
    if ($pinEdgeToTaskbar) { $taskbarAppIds.Add('edge') | Out-Null }
    foreach ($id in $editorIds) { $taskbarAppIds.Add($id) | Out-Null }

    [pscustomobject]@{
        BrowserIds         = @($browserIds)
        EditorIds          = @($editorIds)
        StartAppIds        = @($startAppIds)
        TaskbarAppIds      = @($taskbarAppIds)
        PinEdgeToStart     = $pinEdgeToStart
        PinEdgeToTaskbar   = $pinEdgeToTaskbar
    }
}

function Resolve-WinMintFirstLogonAppShortcut {
    param(
        [Parameter(Mandatory)][string]$AppId,
        [hashtable]$DisplayNames = @{}
    )

    $displayName = Get-WinMintFirstLogonAppDisplayName -Id $AppId -DisplayNames $DisplayNames
    $shortcutPath = Resolve-WinMintFirstLogonStartShortcut -DisplayName $displayName
    if (-not $shortcutPath) {
        $exe = Resolve-WinMintFirstLogonAppExecutable -Id $AppId
        if ($exe) {
            $shortcutPath = New-WinMintFirstLogonStartShortcut -Name $displayName -TargetPath $exe
        }
    }
    return $shortcutPath
}

function Set-WinMintFirstLogonTaskbarPins {
    param(
        # Optional extra .lnk paths; empty is valid (Explorer + Terminal baseline only).
        [string[]]$AppShortcutPaths = @()
    )

    # Live-user LayoutModification.xml with PinListPlacement=Replace. Explorer reload
    # (finalize-success) picks this up after provisioning lock release.
    $shellDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Shell'
    $null = New-Item -ItemType Directory -Path $shellDir -Force -ErrorAction Stop
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('<?xml version="1.0" encoding="utf-8"?>') | Out-Null
    $lines.Add('<LayoutModificationTemplate') | Out-Null
    $lines.Add(' xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"') | Out-Null
    $lines.Add(' xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"') | Out-Null
    $lines.Add(' xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout"') | Out-Null
    $lines.Add(' xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"') | Out-Null
    $lines.Add(' Version="1">') | Out-Null
    $lines.Add('  <CustomTaskbarLayoutCollection PinListPlacement="Replace">') | Out-Null
    $lines.Add('    <defaultlayout:TaskbarLayout>') | Out-Null
    $lines.Add('      <taskbar:TaskbarPinList>') | Out-Null
    $lines.Add('        <taskbar:DesktopApp DesktopApplicationID="Microsoft.Windows.Explorer" />') | Out-Null
    $lines.Add('        <taskbar:UWA AppUserModelID="Microsoft.WindowsTerminal_8wekyb3d8bbwe!App" />') | Out-Null
    foreach ($shortcutPath in @($AppShortcutPaths)) {
        if ([string]::IsNullOrWhiteSpace([string]$shortcutPath)) { continue }
        $escaped = ([string]$shortcutPath).Replace('&', '&amp;').Replace('"', '&quot;')
        $lines.Add("        <taskbar:DesktopApp DesktopApplicationLinkPath=`"$escaped`" />") | Out-Null
    }
    $lines.Add('      </taskbar:TaskbarPinList>') | Out-Null
    $lines.Add('    </defaultlayout:TaskbarLayout>') | Out-Null
    $lines.Add('  </CustomTaskbarLayoutCollection>') | Out-Null
    $lines.Add('</LayoutModificationTemplate>') | Out-Null
    $layoutPath = Join-Path $shellDir 'LayoutModification.xml'
    Set-Content -LiteralPath $layoutPath -Value ($lines -join "`r`n") -Encoding UTF8
    return $layoutPath
}

function Set-WinMintFirstLogonStartPins {
    param([Parameter(Mandatory)][string]$AgentProfilePath)

    if (-not (Test-Path -LiteralPath $AgentProfilePath)) { return }
    $agentProfile = Get-Content -LiteralPath $AgentProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $selection = Get-WinMintFirstLogonPinSelection `
        -Browsers @($agentProfile.browsers) `
        -Editors @($agentProfile.editors)

    $pinnedList = [System.Collections.Generic.List[object]]::new()
    $pinnedList.Add([ordered]@{ desktopAppId = 'Microsoft.Windows.Explorer' }) | Out-Null
    $pinnedList.Add([ordered]@{ packagedAppId = 'windows.immutablecontrolpanel' }) | Out-Null
    $pinnedList.Add([ordered]@{ packagedAppId = 'Microsoft.WindowsTerminal_8wekyb3d8bbwe!App' }) | Out-Null

    $skipped = [System.Collections.Generic.List[string]]::new()
    $appliedById = [ordered]@{}
    $taskbarShortcuts = [System.Collections.Generic.List[string]]::new()
    $displayNames = Get-WinMintFirstLogonPackageDisplayNames -AgentProfilePath $AgentProfilePath
    $resolvedShortcuts = @{}
    foreach ($id in @($selection.StartAppIds)) {
        $appId = [string]$id
        $shortcutPath = Resolve-WinMintFirstLogonAppShortcut -AppId $appId -DisplayNames $displayNames
        if (-not $shortcutPath) {
            $skipped.Add($appId) | Out-Null
            continue
        }
        $resolvedShortcuts[$appId] = $shortcutPath
        $pinnedList.Add([ordered]@{ desktopAppLink = $shortcutPath }) | Out-Null
        $appliedById[$appId] = [ordered]@{
            appId        = $appId
            shortcutPath = $shortcutPath
            surfaces     = [System.Collections.Generic.List[string]]::new()
        }
        $appliedById[$appId].surfaces.Add('start') | Out-Null
    }
    foreach ($id in @($selection.TaskbarAppIds)) {
        $appId = [string]$id
        if ($resolvedShortcuts.ContainsKey($appId)) {
            $taskbarShortcuts.Add([string]$resolvedShortcuts[$appId]) | Out-Null
            if (-not $appliedById.Contains($appId)) {
                $appliedById[$appId] = [ordered]@{
                    appId        = $appId
                    shortcutPath = [string]$resolvedShortcuts[$appId]
                    surfaces     = [System.Collections.Generic.List[string]]::new()
                }
            }
            if ($appliedById[$appId].surfaces -notcontains 'taskbar') {
                $appliedById[$appId].surfaces.Add('taskbar') | Out-Null
            }
        }
        elseif ($skipped -notcontains $appId) {
            $skipped.Add($appId) | Out-Null
        }
    }
    $applied = @(
        foreach ($entry in @($appliedById.Values)) {
            [ordered]@{
                appId        = [string]$entry.appId
                shortcutPath = [string]$entry.shortcutPath
                surfaces     = @($entry.surfaces)
            }
        }
    )

    $layoutJson = ([ordered]@{ pinnedList = @($pinnedList) } | ConvertTo-Json -Compress -Depth 8)
    Invoke-WinMintFirstLogonReg -Arguments @('add', 'HKCU\Software\Policies\Microsoft\Windows\Explorer', '/v', 'ConfigureStartPins', '/t', 'REG_SZ', '/d', $layoutJson, '/f') -AllowFailure
    Invoke-WinMintFirstLogonReg -Arguments @('add', 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer', '/v', 'ConfigureStartPins', '/t', 'REG_SZ', '/d', $layoutJson, '/f') -AllowFailure

    $taskbarLayoutPath = $null
    $optionalTaskbarRequested = @($selection.TaskbarAppIds).Count -gt 0
    if ($optionalTaskbarRequested -and $taskbarShortcuts.Count -eq 0) {
        "$(Get-Date -Format 'o') Taskbar optional AppShortcutPaths empty — writing Explorer+Terminal baseline only (skipped: $($skipped -join ', '))" |
            Out-File -LiteralPath (Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon.log') -Append
    }
    try {
        # Empty optional shortcuts is OK — helper writes Explorer + Terminal baseline pins.
        $taskbarLayoutPath = Set-WinMintFirstLogonTaskbarPins -AppShortcutPaths @($taskbarShortcuts)
    }
    catch {
        Write-WinMintFirstLogonError "Taskbar pin layout write failed: $_"
    }

    $firstLogonLog = Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon.log'
    "$(Get-Date -Format 'o') Start pins applied: $layoutJson" | Out-File -LiteralPath $firstLogonLog -Append
    if ($taskbarLayoutPath) {
        "$(Get-Date -Format 'o') Taskbar pins applied ($($taskbarShortcuts.Count) app link(s); EdgeTaskbar=$($selection.PinEdgeToTaskbar)): $taskbarLayoutPath" |
            Out-File -LiteralPath $firstLogonLog -Append
    }
    if ($skipped.Count -gt 0) {
        $skippedText = $skipped -join ', '
        "$(Get-Date -Format 'o') Start/taskbar pins skipped because no Start Menu shortcut or app executable was found: $skippedText" |
            Out-File -LiteralPath $firstLogonLog -Append
    }

    # Durable report for VM acceptance — LayoutModification.xml may be consumed by
    # explorer after reload, so do not rely on that file alone.
    $shellPinsReport = [ordered]@{
        generatedAt          = Get-Date -Format o
        startAppIds          = @($selection.StartAppIds)
        taskbarAppIds        = @($selection.TaskbarAppIds)
        pinEdgeToStart       = [bool]$selection.PinEdgeToStart
        pinEdgeToTaskbar     = [bool]$selection.PinEdgeToTaskbar
        startPinsJson        = $layoutJson
        taskbarLayoutPath    = [string]$taskbarLayoutPath
        taskbarShortcutCount = @($taskbarShortcuts).Count
        applied              = @($applied)
        skipped              = @($skipped)
        baselineStart        = @('Explorer', 'Settings', 'WindowsTerminal')
        baselineTaskbar      = @('Explorer', 'WindowsTerminal')
        appliedAfterAgent    = $true
        underProvisioningLock = $true
    }
    $shellPinsReport | ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath (Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon_ShellPins.json') -Encoding UTF8
}


function Invoke-WinMintFirstLogonReloadExplorerShell {
    # Reload the shell so the new Start pin layout takes effect. Only valid once explorer.exe
    # is the registered Winlogon Shell (after Unlock-WinMintProvisioningLogonShell).
    if (Get-Command Test-WinMintProvisioningLogonShellActive -ErrorAction SilentlyContinue) {
        if (Test-WinMintProvisioningLogonShellActive) {
            Unlock-WinMintProvisioningLogonShell -Reason 'reload-explorer-preflight'
        }
    }
    try {
        Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline) {
            if (Get-Process -Name explorer -ErrorAction SilentlyContinue) { break }
            Start-Sleep -Milliseconds 200
        }
        Start-Sleep -Milliseconds 750
        Invoke-WinMintProvisioningDismissStartMenu
    }
    catch {
        Write-WinMintFirstLogonError "Explorer reload for Start pins failed: $_"
    }
}


function Set-WinMintFirstLogonXdgDefaults {
    $xdgRuntimeDir = Join-Path $env:LOCALAPPDATA 'Temp\xdg-runtime'
    foreach ($folder in @('.config', '.cache', '.local', '.local\share', '.local\state', 'bin', '.local\bin')) {
        New-Item -ItemType Directory -Path (Join-Path $env:USERPROFILE $folder) -Force -ErrorAction SilentlyContinue | Out-Null
    }
    New-Item -ItemType Directory -Path $xdgRuntimeDir -Force -ErrorAction SilentlyContinue | Out-Null
    Set-WinMintFirstLogonEnvironmentValue -Name 'XDG_CONFIG_HOME' -Value '%USERPROFILE%\.config'
    Set-WinMintFirstLogonEnvironmentValue -Name 'XDG_DATA_HOME' -Value '%USERPROFILE%\.local\share'
    Set-WinMintFirstLogonEnvironmentValue -Name 'XDG_STATE_HOME' -Value '%USERPROFILE%\.local\state'
    Set-WinMintFirstLogonEnvironmentValue -Name 'XDG_CACHE_HOME' -Value '%USERPROFILE%\.cache'
    Set-WinMintFirstLogonEnvironmentValue -Name 'XDG_RUNTIME_DIR' -Value $xdgRuntimeDir
    Add-WinMintFirstLogonUserPath -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
    Add-WinMintFirstLogonUserPath -Path (Join-Path $env:USERPROFILE 'bin')
    Add-WinMintFirstLogonUserPath -Path (Join-Path $env:USERPROFILE '.local\bin')
    "$(Get-Date -Format 'o') Set XDG defaults: config/data/state/cache + runtime dir; preserved WindowsApps and added user bin paths." | Out-File (Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon.log') -Append
}


function Add-WinMintFirstLogonUserPath {
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($part in ([string]$current -split ';')) {
        if (-not [string]::IsNullOrWhiteSpace($part)) { $parts.Add($part.Trim()) | Out-Null }
    }
    if (@($parts | Where-Object { $_ -ieq $Path }).Count -eq 0) {
        $parts.Add($Path) | Out-Null
        [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
        $env:PATH = "$env:PATH;$Path"
    }
}


function Set-WinMintFirstLogonClipboardDefaults {
    $clipboardKey = 'HKCU\Software\Microsoft\Clipboard'
    Invoke-WinMintFirstLogonReg -Arguments @('add', $clipboardKey, '/v', 'EnableClipboardHistory', '/t', 'REG_DWORD', '/d', '1', '/f') -AllowFailure
    Invoke-WinMintFirstLogonReg -Arguments @('add', $clipboardKey, '/v', 'CloudClipboardAutomaticUpload', '/t', 'REG_DWORD', '/d', '0', '/f') -AllowFailure
    "$(Get-Date -Format 'o') Clipboard defaults applied: local history on, cloud upload off." | Out-File (Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon.log') -Append
}


function Set-WinMintFirstLogonQuietUxDefaults {
    # Home-effective quiet UX source of truth (with DefaultUser ContentDeliveryManager).
    # Do not rely on Enterprise CloudContent policies for Home tips/suggestions silence.
    $contentDeliveryKey = 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($name in @(
            'SubscribedContent-310093Enabled',
            'SubscribedContent-338388Enabled',
            'SubscribedContent-338389Enabled',
            'SubscribedContent-338393Enabled',
            'SubscribedContent-353694Enabled',
            'SubscribedContent-353696Enabled',
            'SubscribedContent-353698Enabled',
            'SoftLandingEnabled',
            'SystemPaneSuggestionsEnabled',
            'SilentInstalledAppsEnabled',
            'PreInstalledAppsEnabled',
            'OemPreInstalledAppsEnabled',
            'RotatingLockScreenEnabled',
            'RotatingLockScreenOverlayEnabled'
        )) {
        Invoke-WinMintFirstLogonReg -Arguments @('add', $contentDeliveryKey, '/v', $name, '/t', 'REG_DWORD', '/d', '0', '/f') -AllowFailure
    }

    $advancedKey = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    foreach ($entry in @(
            @{ Name = 'ShowTaskViewButton'; Data = '0' },
            @{ Name = 'TaskbarDa'; Data = '0' },
            @{ Name = 'TaskbarMn'; Data = '0' },
            @{ Name = 'ShowCopilotButton'; Data = '0' },
            @{ Name = 'Start_AccountNotifications'; Data = '0' }
        )) {
        Invoke-WinMintFirstLogonReg -Arguments @('add', $advancedKey, '/v', $entry.Name, '/t', 'REG_DWORD', '/d', $entry.Data, '/f') -AllowFailure
    }

    Invoke-WinMintFirstLogonReg -Arguments @('add', 'HKCU\Software\Microsoft\Windows\CurrentVersion\SearchSettings', '/v', 'IsDynamicSearchBoxEnabled', '/t', 'REG_DWORD', '/d', '0', '/f') -AllowFailure
    Invoke-WinMintFirstLogonReg -Arguments @('add', 'HKCU\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement', '/v', 'ScoobeSystemSettingEnabled', '/t', 'REG_DWORD', '/d', '0', '/f') -AllowFailure
    foreach ($toastId in @('Windows.SystemToast.BackupReminder', 'Windows.SystemToast.Suggested')) {
        $toastKey = "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\$toastId"
        Invoke-WinMintFirstLogonReg -Arguments @('add', $toastKey, '/v', 'Enabled', '/t', 'REG_DWORD', '/d', '0', '/f') -AllowFailure
    }
    Invoke-WinMintFirstLogonReg -Arguments @('add', 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer', '/v', 'EnableAutoTray', '/t', 'REG_DWORD', '/d', '1', '/f') -AllowFailure
    "$(Get-Date -Format 'o') Quiet UX defaults applied: setup prompts, Spotlight, taskbar affordances, and noisy system toasts disabled." |
        Out-File (Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon.log') -Append
}


function Set-WinMintFirstLogonWindowsTerminalDefault {
    $terminalKey = 'HKCU\Console\%%Startup'
    Invoke-WinMintFirstLogonReg -Arguments @('add', $terminalKey, '/v', 'DelegationConsole', '/t', 'REG_SZ', '/d', '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}', '/f') -AllowFailure
    Invoke-WinMintFirstLogonReg -Arguments @('add', $terminalKey, '/v', 'DelegationTerminal', '/t', 'REG_SZ', '/d', '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}', '/f') -AllowFailure
    "$(Get-Date -Format 'o') Windows Terminal set as the live user's default terminal host." |
        Out-File (Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon.log') -Append
}


function Clear-WinMintFirstLogonWindowsTerminalDelegation {
    $terminalKey = 'HKCU\Console\%%Startup'
    foreach ($name in @('DelegationConsole', 'DelegationTerminal')) {
        Invoke-WinMintFirstLogonReg -Arguments @('delete', $terminalKey, '/v', $name, '/f') -AllowFailure
    }
}


function Set-WinMintFirstLogonTerminalProfiles {
    param([Parameter()][string]$AgentProfilePath)

    $distros = Get-WinMintProfileWslDistros -AgentProfilePath $AgentProfilePath
    $mockWsl = $false
    if (-not [string]::IsNullOrWhiteSpace($AgentProfilePath) -and (Test-Path -LiteralPath $AgentProfilePath)) {
        try {
            $agentProfile = Get-Content -LiteralPath $AgentProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $mockWsl = Test-WinMintAgentWslRuntimeValidationSkipped -AgentProfile $agentProfile
        }
        catch { $mockWsl = $false }
    }
    $status = if ($mockWsl) {
        Set-WinMintWindowsTerminalProfiles -WslDistros $distros -MockWslProfiles
    }
    else {
        Set-WinMintWindowsTerminalProfiles -WslDistros $distros
    }
    if ($status -eq 'missing-terminal-settings') { return }

    $settingsPath = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
    $profileNames = try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        @($settings.profiles.list | ForEach-Object { [string]$_.name }) -join ', '
    }
    catch {
        'PowerShell'
    }
    $firstLogonLog = Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon.log'
    "$(Get-Date -Format 'o') Windows Terminal defaults applied; profiles present: $profileNames" |
        Out-File -LiteralPath $firstLogonLog -Append
    if ($status -eq 'updated-with-wsl-mock') {
        "$(Get-Date -Format 'o') terminalProfile=mock WSL Terminal profile(s) staged for diagnostics.wslRuntimeValidation=skip: $($distros -join ', ')" |
            Out-File -LiteralPath $firstLogonLog -Append
    }
}

