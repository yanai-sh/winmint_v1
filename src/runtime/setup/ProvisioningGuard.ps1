#Requires -Version 7.6

function Resolve-WinMintProvisioningHostExePath {
    param([string]$ShellRoot = '')

    if ([string]::IsNullOrWhiteSpace($ShellRoot)) {
        $ShellRoot = Get-WinMintSetupShellRoot
    }

    $exe = Join-Path $ShellRoot 'WinMintSetupShell.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "Provisioning host executable is missing under $ShellRoot"
    }
    return $exe
}

function Write-WinMintProvisioningGuardLog {
    param([Parameter(Mandatory)][string]$Marker)

    try {
        $logDir = 'C:\ProgramData\WinMint\Logs'
        if (Get-Command Get-WinMintFirstLogonContext -ErrorAction SilentlyContinue) {
            try {
                $ctxLog = [string](Get-WinMintFirstLogonContext).LogDir
                if (-not [string]::IsNullOrWhiteSpace($ctxLog)) { $logDir = $ctxLog }
            }
            catch { }
        }
        if (-not (Test-Path -LiteralPath $logDir)) {
            $null = New-Item -ItemType Directory -Path $logDir -Force
        }
        $logPath = Join-Path $logDir 'FirstLogon.log'
        "$(Get-Date -Format 'o') provisioning-lock:$Marker" | Out-File -LiteralPath $logPath -Append
    }
    catch { }
}

function Enable-WinMintProvisioningGuard {
    param(
        # Preview/dev harness only — production engage must leave this off so Alt+Tab is blocked.
        [switch]$AllowTaskSwitch
    )

    try {
        & reg.exe add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' /v NoWinKeys /t REG_DWORD /d 1 /f 2>&1 | Out-Null
    }
    catch { }
    if (-not $AllowTaskSwitch) {
        try {
            & reg.exe add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System' /v DisableTaskSwitching /t REG_DWORD /d 1 /f 2>&1 | Out-Null
        }
        catch { }
    }
    Write-WinMintProvisioningGuardLog -Marker 'guard-engage'
}

function Disable-WinMintProvisioningGuard {
    try {
        & reg.exe delete 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' /v NoWinKeys /f 2>&1 | Out-Null
    }
    catch { }
    try {
        & reg.exe delete 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System' /v DisableTaskSwitching /f 2>&1 | Out-Null
    }
    catch { }
    Write-WinMintProvisioningGuardLog -Marker 'guard-release'
}

function Initialize-WinMintShellNative {
    # Shared user32 helpers for theme broadcast + wallpaper SPI (PreLock + FirstLogon.Desktop).
    if ('WinMint.Native.Shell' -as [type]) { return }
    Add-Type -Namespace WinMint.Native -Name Shell -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool SystemParametersInfo(int uiAction, int uiParam, string pvParam, int fWinIni);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, string lParam, uint flags, uint timeout, out System.IntPtr result);
'@ -ErrorAction Stop
}

function Broadcast-WinMintThemeChange {
    <#
    .SYNOPSIS
        WM_SETTINGCHANGE ImmersiveColorSet so a live shell re-reads dark/light Personalize keys.
    #>
    param([switch]$Quiet)

    Initialize-WinMintShellNative
    $hwndBroadcast = [IntPtr]0xffff
    $wmSettingChange = 0x001A
    $smtoAbortIfHung = 0x0002
    $res = [IntPtr]::Zero
    foreach ($payload in 'ImmersiveColorSet', 'WindowsThemeElement', 'Policy') {
        [void][WinMint.Native.Shell]::SendMessageTimeout($hwndBroadcast, $wmSettingChange, [IntPtr]::Zero, $payload, $smtoAbortIfHung, 1000, [ref]$res)
    }
    if ($Quiet) { return }
    try {
        if (Get-Command Get-WinMintFirstLogonContext -ErrorAction SilentlyContinue) {
            "$(Get-Date -Format 'o') Broadcast theme-change (ImmersiveColorSet) so the shell applies dark mode." |
                Out-File (Join-Path (Get-WinMintFirstLogonContext).LogDir 'FirstLogon.log') -Append
        }
        else {
            Write-WinMintProvisioningGuardLog -Marker 'theme-broadcast ImmersiveColorSet'
        }
    }
    catch {
        Write-WinMintProvisioningGuardLog -Marker 'theme-broadcast ImmersiveColorSet'
    }
}

function Set-WinMintProvisioningDarkThemeKeys {
    # Instant registry-only dark Personalize (no Add-Type / SPI — safe before early host).
    & reg.exe add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' /v AppsUseLightTheme /t REG_DWORD /d 0 /f 2>&1 | Out-Null
    & reg.exe add 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' /v SystemUsesLightTheme /t REG_DWORD /d 0 /f 2>&1 | Out-Null
}

function Set-WinMintProvisioningDarkChrome {
    <#
    .SYNOPSIS
        Dark Personalize keys + optional wallpaper + ImmersiveColorSet broadcast.
        Call AFTER early host when used from PreLock — Add-Type/SPI/broadcast can take seconds
        on first logon and must not gate splash cover.
    #>
    param(
        # Skip wallpaper SystemParametersInfo (still writes Personalize + broadcast).
        [switch]$SkipWallpaper
    )

    Set-WinMintProvisioningDarkThemeKeys
    $wallpaper = 'C:\Windows\Web\Wallpaper\Windows\WinMint-Bloom.jpg'
    if (-not $SkipWallpaper -and (Test-Path -LiteralPath $wallpaper)) {
        & reg.exe add 'HKCU\Control Panel\Desktop' /v Wallpaper /t REG_SZ /d $wallpaper /f 2>&1 | Out-Null
        & reg.exe add 'HKCU\Control Panel\Desktop' /v WallpaperStyle /t REG_SZ /d 10 /f 2>&1 | Out-Null
        & reg.exe add 'HKCU\Control Panel\Desktop' /v TileWallpaper /t REG_SZ /d 0 /f 2>&1 | Out-Null
        try {
            Initialize-WinMintShellNative
            [void][WinMint.Native.Shell]::SystemParametersInfo(20, 0, $wallpaper, 3)
        }
        catch { }
    }
    Broadcast-WinMintThemeChange
}

function Invoke-WinMintProvisioningDismissStartMenu {
    # Prefer COM SendKeys — avoids a multi-second first-logon Add-Type JIT on the PreLock critical path.
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shell.SendKeys('{ESC}')
        return
    }
    catch { }

    if (-not ('WinMint.StartDismiss' -as [type])) {
        $null = Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
namespace WinMint {
    public static class StartDismiss {
        [DllImport("user32.dll")]
        static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, uint dwExtraInfo);
        const byte VK_ESCAPE = 0x1B;
        const uint KEYUP = 0x0002;
        public static void Dismiss() {
            keybd_event(VK_ESCAPE, 0, 0, 0);
            keybd_event(VK_ESCAPE, 0, KEYUP, 0);
        }
    }
}
'@
    }
    [WinMint.StartDismiss]::Dismiss()
}

function Restore-WinMintProvisioningDesktop {
    if (-not ('WinMint.DesktopRestore' -as [type])) {
        $null = Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace WinMint {
    public static class DesktopRestore {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr FindWindow(string className, string windowName);
        [DllImport("user32.dll")]
        static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        public static void ShowTaskbars() {
            foreach (var cls in new[] { "Shell_TrayWnd", "Shell_SecondaryTrayWnd" }) {
                var h = FindWindow(cls, null);
                if (h != IntPtr.Zero) {
                    ShowWindow(h, 5);
                }
            }
        }
    }
}
'@
    }
    [WinMint.DesktopRestore]::ShowTaskbars()
    Invoke-WinMintProvisioningDismissStartMenu
}

function Stop-WinMintSetupShellHostProcesses {
    Get-Process -Name 'WinMintSetupShell' -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_ | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Stop-WinMintProvisioningHostResidual {
    Disable-WinMintProvisioningGuard
    Stop-WinMintSetupShellHostProcesses
    Restore-WinMintProvisioningDesktop
}

function Get-WinMintProvisioningHostProcess {
    return @(Get-Process -Name 'WinMintSetupShell' -ErrorAction SilentlyContinue | Sort-Object StartTime -Descending)[0]
}

function Write-WinMintProvisioningHostBootstrapFiles {
    param(
        [Parameter(Mandatory)][string]$ShellRoot,
        [Parameter(Mandatory)][string]$ControlPath,
        [Parameter(Mandatory)][string]$StatusPath,
        [string]$ProfileName = 'WinMint',
        [string]$TaskLabel = 'Starting WinMint setup…'
    )

    $startedAt = Get-Date -Format o
    $control = [ordered]@{
        phase = 'running'
        startedAt = $startedAt
        updatedAt = $startedAt
        profileName = $ProfileName
        message = ''
        preAgentStage = 'locked'
    }
    $status = [ordered]@{
        phase = 'running'
        stageId = 'ready'
        taskLabel = 'Getting things ready'
        detailLabel = if ($TaskLabel -and $TaskLabel -ne 'Starting WinMint setup…') { $TaskLabel } else { 'This may take a few minutes' }
        itemIndex = 0
        itemTotal = 0
        progressPct = 0
        progressMode = 'indeterminate'
        profileName = $ProfileName
        elapsedMs = 0
        groupLabel = ''
        banner = ''
        bannerKind = ''
        logDir = 'C:\ProgramData\WinMint\Logs'
        updatedAt = $startedAt
    }

    foreach ($path in @($ControlPath, $StatusPath)) {
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -ItemType Directory -Path $dir -Force
        }
    }
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($ControlPath, ($control | ConvertTo-Json -Depth 8), $utf8)
    [System.IO.File]::WriteAllText($StatusPath, ($status | ConvertTo-Json -Depth 8), $utf8)
    $mirror = Join-Path $ShellRoot 'setup-shell-status.json'
    try { [System.IO.File]::WriteAllText($mirror, ($status | ConvertTo-Json -Depth 8), $utf8) } catch { }
}

function Start-WinMintProvisioningHostEarly {
    <#
    .SYNOPSIS
        PreLock entry: cover the desktop before FirstLogon.ps1 loads modules.
    #>
    param(
        [string]$PayloadRoot = $PSScriptRoot,
        [int]$PollIntervalMs = 1500
    )

    $existing = Get-WinMintProvisioningHostProcess
    if ($existing) {
        Write-WinMintProvisioningGuardLog -Marker "host-adopt presenter=native pid=$($existing.Id) early=1"
        return $existing
    }

    $shellRoot = Join-Path $PayloadRoot 'setup-shell'
    $exePath = Join-Path $shellRoot 'WinMintSetupShell.exe'
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        Write-WinMintProvisioningGuardLog -Marker "host-early-skip missing=$exePath"
        return $null
    }

    $winMintDir = Join-Path $env:LOCALAPPDATA 'WinMint'
    $controlPath = Join-Path $winMintDir 'setup-shell-control.json'
    $statusPath = Join-Path $winMintDir 'setup-shell-status.json'
    $profileName = 'WinMint'
    try {
        $setupProfile = Join-Path $PayloadRoot 'WinMintSetupProfile.json'
        if (Test-Path -LiteralPath $setupProfile) {
            $sp = Get-Content -LiteralPath $setupProfile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($sp.PSObject.Properties['profileName'] -and $sp.profileName) {
                $profileName = [string]$sp.profileName
            }
        }
    }
    catch { }

    Write-WinMintProvisioningHostBootstrapFiles `
        -ShellRoot $shellRoot `
        -ControlPath $controlPath `
        -StatusPath $statusPath `
        -ProfileName $profileName `
        -TaskLabel 'Lock desktop and open setup shell'

    $minStartDwellMs = 5000
    $minCompleteDwellMs = 5000
    if (Get-Command Get-WinMintSetupProvisioningShellDwellOverrideMs -ErrorAction SilentlyContinue) {
        $dwellOverride = Get-WinMintSetupProvisioningShellDwellOverrideMs
        if ($dwellOverride) {
            $minStartDwellMs = $dwellOverride
            $minCompleteDwellMs = $dwellOverride
        }
    }

    $hostArgs = @(
        '--shell-root', "`"$shellRoot`"",
        '--status', "`"$statusPath`"",
        '--control', "`"$controlPath`"",
        '--poll-ms', $PollIntervalMs,
        '--min-start-dwell-ms', $minStartDwellMs,
        '--min-complete-dwell-ms', $minCompleteDwellMs,
        '--log'
    )
    $proc = Start-Process -FilePath $exePath -ArgumentList $hostArgs -PassThru
    Write-WinMintProvisioningGuardLog -Marker "host-start presenter=native pid=$($proc.Id) early=1"
    return $proc
}

function Start-WinMintProvisioningHost {
    param(
        [int]$PollIntervalMs = 1500,
        [string]$HostExePath = '',
        [int]$MinStartDwellMs = 0,
        [int]$MinCompleteDwellMs = 0,
        [switch]$AdoptIfRunning
    )

    if ($AdoptIfRunning) {
        $existing = Get-WinMintProvisioningHostProcess
        if ($existing) {
            Write-WinMintProvisioningGuardLog -Marker "host-adopt presenter=native pid=$($existing.Id)"
            return $existing
        }
    }

    $paths = Get-WinMintSetupShellLocalPaths
    $shellRoot = Get-WinMintSetupShellRoot
    $exePath = if (-not [string]::IsNullOrWhiteSpace($HostExePath)) { $HostExePath } else { Resolve-WinMintProvisioningHostExePath -ShellRoot $shellRoot }
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        throw "Provisioning host executable is missing: $exePath"
    }

    Stop-WinMintSetupShellHostProcesses
    # Brief yield only when replacing a prior host; PreLock early start skips this path.
    Start-Sleep -Milliseconds 200

    if ($MinStartDwellMs -le 0) { $MinStartDwellMs = 5000 }
    if ($MinCompleteDwellMs -le 0) { $MinCompleteDwellMs = 5000 }
    if ($MinStartDwellMs -eq 5000) {
        $dwellOverride = Get-WinMintSetupProvisioningShellDwellOverrideMs
        if ($dwellOverride) {
            $MinStartDwellMs = $dwellOverride
            $MinCompleteDwellMs = $dwellOverride
        }
    }

    $hostArgs = @(
        '--shell-root', "`"$shellRoot`"",
        '--status', "`"$($paths.StatusPath)`"",
        '--control', "`"$($paths.ControlPath)`"",
        '--poll-ms', $PollIntervalMs,
        '--min-start-dwell-ms', $MinStartDwellMs,
        '--min-complete-dwell-ms', $MinCompleteDwellMs,
        '--log'
    )
    $proc = Start-Process -FilePath $exePath -ArgumentList $hostArgs -PassThru
    Write-WinMintProvisioningGuardLog -Marker "host-start presenter=native pid=$($proc.Id)"
    return $proc
}

function Wait-WinMintProvisioningHost {
    param(
        [Parameter(Mandatory)]$Process,
        [int]$TimeoutSeconds = 120
    )

    if (-not $Process) { return }
    $deadline = (Get-Date).AddSeconds([Math]::Max(5, $TimeoutSeconds))
    while ((Get-Date) -lt $deadline) {
        if ($Process.HasExited) {
            Stop-WinMintSetupShellStatusPump
            Stop-WinMintProvisioningHostResidual
            Write-WinMintProvisioningGuardLog -Marker 'host-exit'
            return
        }
        Invoke-WinMintSetupShellStatusPumpTick
        Start-Sleep -Milliseconds 250
    }
    try {
        if (-not $Process.HasExited) { $Process | Stop-Process -Force -ErrorAction SilentlyContinue }
    }
    catch { }
    Stop-WinMintSetupShellStatusPump
    Stop-WinMintProvisioningHostResidual
    Write-WinMintProvisioningGuardLog -Marker 'host-timeout'
}

function Stop-WinMintProvisioningHost {
    param([Parameter(Mandatory)]$Process)

    if (-not $Process -or $Process.HasExited) {
        Stop-WinMintSetupShellStatusPump
        Stop-WinMintProvisioningHostResidual
        return
    }
    try { $Process | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
    Stop-WinMintSetupShellStatusPump
    Stop-WinMintProvisioningHostResidual
}

function Get-WinMintLogonShellCmdPath {
    param([string]$PayloadRoot = '')

    if ([string]::IsNullOrWhiteSpace($PayloadRoot)) {
        $PayloadRoot = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Windows\Setup\Scripts' }
    }
    return (Join-Path $PayloadRoot 'WinMintLogonShell.cmd')
}

function Get-WinMintRegisteredWinlogonShell {
    try {
        return [string](Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name Shell -ErrorAction Stop).Shell
    }
    catch {
        return 'explorer.exe'
    }
}

function Test-WinMintProvisioningLogonShellActive {
    return ((Get-WinMintRegisteredWinlogonShell) -match 'WinMintLogonShell')
}

function Set-WinMintRegisteredWinlogonShell {
    param([Parameter(Mandatory)][string]$ShellValue)

    $key = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon'
    try {
        if (-not (Test-Path -LiteralPath $key)) { $null = New-Item -Path $key -Force }
        Set-ItemProperty -LiteralPath $key -Name Shell -Value $ShellValue -Type String -Force
    }
    catch {
        & reg.exe add 'HKCU\Software\Microsoft\Windows NT\CurrentVersion\Winlogon' /v Shell /t REG_SZ /d $ShellValue /f 2>&1 | Out-Null
    }
}

function Unlock-WinMintProvisioningLogonShell {
    <#
    .SYNOPSIS
        Restore explorer.exe as Winlogon Shell and start Explorer (idempotent fail-open / success handoff).
    #>
    param([string]$Reason = 'unlock')

    $wasActive = Test-WinMintProvisioningLogonShellActive
    Set-WinMintRegisteredWinlogonShell -ShellValue 'explorer.exe'
    try { Disable-WinMintProvisioningGuard } catch { }
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath 'explorer.exe'
    }
    if ($wasActive) {
        Write-WinMintProvisioningGuardLog -Marker "logon-shell-unlock reason=$Reason"
    }
}
