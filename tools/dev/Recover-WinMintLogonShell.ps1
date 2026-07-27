#Requires -Version 7.6
<#
.SYNOPSIS
  Fail-open: restore explorer.exe as Winlogon Shell after a stuck WinMint logon shell.

.DESCRIPTION
  Idempotent. Clears WinMintLogonShell as the registered Shell, drops provisioning
  guard policies when ProvisioningGuard is available, and starts explorer if missing.
  Run elevated in the affected user session (or via PowerShell Direct as that user).
#>
[CmdletBinding()]
param(
    [string]$PayloadRoot = 'C:\Windows\Setup\Scripts'
)

$ErrorActionPreference = 'Continue'
$winlogonKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon'

$guardPath = Join-Path $PayloadRoot 'ProvisioningGuard.ps1'
if (Test-Path -LiteralPath $guardPath) {
    . $guardPath
    if (Get-Command Unlock-WinMintProvisioningLogonShell -ErrorAction SilentlyContinue) {
        Unlock-WinMintProvisioningLogonShell -Reason 'manual-recovery'
        Write-Host 'Recover-WinMintLogonShell: Unlock-WinMintProvisioningLogonShell completed.'
        exit 0
    }
}

try {
    if (-not (Test-Path -LiteralPath $winlogonKey)) {
        $null = New-Item -Path $winlogonKey -Force
    }
    Set-ItemProperty -LiteralPath $winlogonKey -Name Shell -Value 'explorer.exe' -Type String -Force
}
catch {
    & reg.exe add 'HKCU\Software\Microsoft\Windows NT\CurrentVersion\Winlogon' /v Shell /t REG_SZ /d explorer.exe /f | Out-Null
}

foreach ($pair in @(
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoWinKeys' },
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'DisableTaskSwitching' }
    )) {
    try {
        Remove-ItemProperty -LiteralPath $pair.Path -Name $pair.Name -Force -ErrorAction SilentlyContinue
    }
    catch { }
}

if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath 'explorer.exe'
}

Write-Host 'Recover-WinMintLogonShell: Shell=explorer.exe; explorer started if missing.'
exit 0
