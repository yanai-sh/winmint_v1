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
