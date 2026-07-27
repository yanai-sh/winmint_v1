#Requires -Version 7.6
# Winlogon Shell replacement for first interactive logon.
# Starts WinMintSetupShell immediately (Explorer is not the shell), waits for a terminal
# provisioning phase or timeout, then restores explorer.exe (fail-open).
$ErrorActionPreference = 'SilentlyContinue'
$payloadRoot = $PSScriptRoot
$logDir = 'C:\ProgramData\WinMint\Logs'
try { $null = New-Item -ItemType Directory -Path $logDir -Force } catch { }

function Write-WinMintLogonShellLog([string]$Message) {
    try {
        "$(Get-Date -Format 'o') logon-shell:$Message" | Out-File -LiteralPath (Join-Path $logDir 'FirstLogon.log') -Append
    }
    catch { }
}

. (Join-Path $payloadRoot 'ProvisioningGuard.ps1')

$timeoutMinutes = 90
$pollMs = 1500

function Get-WinMintLogonShellPhase {
    foreach ($path in @(
            (Join-Path $env:LOCALAPPDATA 'WinMint\setup-shell-control.json'),
            (Join-Path $env:LOCALAPPDATA 'WinMint\setup-shell-status.json'),
            (Join-Path $payloadRoot 'setup-shell\setup-shell-status.json')
        )) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            $phase = [string]$json.phase
            if (-not [string]::IsNullOrWhiteSpace($phase)) { return $phase.Trim().ToLowerInvariant() }
        }
        catch { }
    }
    return ''
}

function Clear-WinMintUnattendRunOnceEntries {
    # FirstLogonCommands were parked in RunOnce; Explorer never starts while we are Shell,
    # so those keys would otherwise sit forever (or double-fire after unlock).
    $runOnce = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    if (-not (Test-Path -LiteralPath $runOnce)) { return }
    try {
        $names = @(Get-Item -LiteralPath $runOnce -ErrorAction Stop | Select-Object -ExpandProperty Property)
    }
    catch { return }
    foreach ($name in $names) {
        if ($name -like 'Unattend*' -or $name -eq 'WinMintFirstLogon') {
            try {
                Remove-ItemProperty -LiteralPath $runOnce -Name $name -Force -ErrorAction SilentlyContinue
            }
            catch { }
        }
    }
}

function Start-WinMintLogonShellFirstLogonIfNeeded {
    # RunOnce does not run under a custom Winlogon Shell. While we own Shell, we must
    # drive FirstLogon ourselves on first boot AND on reboot-resume (agent needsReboot).
    $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwsh)) {
        Write-WinMintLogonShellLog 'firstlogon-skip-no-pwsh'
        return
    }

    $phase = Get-WinMintLogonShellPhase
    if ($phase -in @('complete', 'failed')) {
        Clear-WinMintUnattendRunOnceEntries
        return
    }

    $already = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'pwsh.exe' -and $_.CommandLine -and $_.CommandLine -match 'FirstLogon\.ps1' })
    if ($already.Count -gt 0) {
        Write-WinMintLogonShellLog 'firstlogon-already-running'
        Clear-WinMintUnattendRunOnceEntries
        return
    }

    $firedPath = Join-Path $logDir 'FirstLogonCommands-fired.txt'
    $preLock = Join-Path $payloadRoot 'FirstLogon.PreLock.ps1'
    $firstLogon = Join-Path $payloadRoot 'FirstLogon.ps1'

    # PreLock only on the first self-drive (breadcrumb missing). Later boots still need FirstLogon.ps1.
    if (-not (Test-Path -LiteralPath $firedPath)) {
        try {
            Set-Content -LiteralPath $firedPath -Value ((Get-Date).ToString('o') + ' logon-shell') -Encoding utf8
        }
        catch { }
        if (Test-Path -LiteralPath $preLock) {
            try {
                Write-WinMintLogonShellLog 'starting-prelock'
                Start-Process -FilePath $pwsh -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $preLock
                ) -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null
            }
            catch {
                Write-WinMintLogonShellLog "prelock-failed $_"
            }
        }
    }

    if (-not (Test-Path -LiteralPath $firstLogon)) {
        Write-WinMintLogonShellLog 'firstlogon-missing'
        return
    }

    try {
        Write-WinMintLogonShellLog "starting-firstlogon phase=$phase"
        Start-Process -FilePath $pwsh -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $firstLogon
        ) -WindowStyle Hidden -ErrorAction Stop | Out-Null
    }
    catch {
        Write-WinMintLogonShellLog "firstlogon-start-failed $_"
    }

    Clear-WinMintUnattendRunOnceEntries
}


if (-not (Test-WinMintProvisioningLogonShellActive)) {
    Write-WinMintLogonShellLog ("exit shell-already={0}" -f (Get-WinMintRegisteredWinlogonShell))
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath 'explorer.exe'
    }
    exit 0
}

try {
    Enable-WinMintProvisioningGuard
    Set-WinMintProvisioningDarkThemeKeys
}
catch { }

$hostProc = $null
try {
    $hostProc = Start-WinMintProvisioningHostEarly -PayloadRoot $payloadRoot
}
catch {
    Write-WinMintLogonShellLog "host-start-failed $_"
}

if (-not $hostProc -and -not (Get-WinMintProvisioningHostProcess)) {
    Unlock-WinMintProvisioningLogonShell -Reason 'host-missing'
    exit 1
}

try {
    Set-WinMintProvisioningDarkChrome
}
catch { }

# Unblock FirstLogonCommands that Windows parked in RunOnce (never fires without Explorer).
Start-WinMintLogonShellFirstLogonIfNeeded

Write-WinMintLogonShellLog 'waiting-for-terminal-phase'
$deadline = (Get-Date).AddMinutes($timeoutMinutes)
while ((Get-Date) -lt $deadline) {
    if (-not (Test-WinMintProvisioningLogonShellActive)) {
        Write-WinMintLogonShellLog 'exit shell-cleared-by-firstlogon'
        exit 0
    }

    $phase = Get-WinMintLogonShellPhase
    if ($phase -eq 'reboot') {
        Write-WinMintLogonShellLog 'hold-for-reboot'
        Start-Sleep -Seconds 3600
        continue
    }
    if ($phase -in @('complete', 'failed')) {
        Unlock-WinMintProvisioningLogonShell -Reason "phase-$phase"
        exit 0
    }

    Start-Sleep -Milliseconds $pollMs
}

Unlock-WinMintProvisioningLogonShell -Reason "timeout-${timeoutMinutes}m"
exit 1
