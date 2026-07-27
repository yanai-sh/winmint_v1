#Requires -Version 7.6
<#
.SYNOPSIS
  Red/green: PreLock covers with early host before wallpaper/ImmersiveColorSet work.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure([string]$Message) {
    $failures.Add($Message) | Out-Null
    Write-Host "FAIL: $Message" -ForegroundColor Red
}

$preLockText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\FirstLogon.PreLock.ps1') -Raw
$guardText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\ProvisioningGuard.ps1') -Raw
$desktopText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\FirstLogon.Desktop.ps1') -Raw

if ($guardText -notmatch 'function Broadcast-WinMintThemeChange' -or $guardText -notmatch 'ImmersiveColorSet') {
    Add-Failure 'ProvisioningGuard.ps1 must expose Broadcast-WinMintThemeChange with ImmersiveColorSet.'
}
if ($guardText -notmatch 'function Set-WinMintProvisioningDarkThemeKeys') {
    Add-Failure 'ProvisioningGuard.ps1 must expose Set-WinMintProvisioningDarkThemeKeys.'
}
if ($desktopText -notmatch 'Broadcast-WinMintThemeChange') {
    Add-Failure 'FirstLogon.Desktop.ps1 should call Broadcast-WinMintThemeChange (shared helper).'
}
if ($preLockText -notmatch 'Set-WinMintProvisioningDarkThemeKeys') {
    Add-Failure 'PreLock must write dark theme keys before early host.'
}
if ($preLockText -notmatch 'Set-WinMintProvisioningDarkChrome') {
    Add-Failure 'PreLock must call Set-WinMintProvisioningDarkChrome under splash cover.'
}

$hostIdx = $preLockText.IndexOf('Start-WinMintProvisioningHostEarly')
$chromeIdx = $preLockText.IndexOf('Set-WinMintProvisioningDarkChrome')
$keysIdx = $preLockText.IndexOf('Set-WinMintProvisioningDarkThemeKeys')
$dismissIdx = $preLockText.IndexOf('Invoke-WinMintProvisioningDismissStartMenu')
if ($keysIdx -lt 0 -or $hostIdx -lt 0 -or $keysIdx -gt $hostIdx) {
    Add-Failure 'PreLock order: DarkThemeKeys before host-start.'
}
if ($chromeIdx -lt 0 -or $hostIdx -gt $chromeIdx) {
    Add-Failure 'PreLock order: host-start before DarkChrome (wallpaper/broadcast) — avoids bloom flash on light Explorer.'
}
if ($dismissIdx -lt 0 -or $hostIdx -gt $dismissIdx) {
    Add-Failure 'PreLock order: host-start before Start-menu dismiss.'
}

if ($failures.Count -gt 0) {
    Write-Host "Assert-WinMintPreLockThemeBroadcast: $($failures.Count) failure(s) (RED)." -ForegroundColor Red
    exit 1
}

Write-Host 'Assert-WinMintPreLockThemeBroadcast: OK (GREEN).'
exit 0
