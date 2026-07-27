#Requires -Version 7.6
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param([string]$Message)

    $failures.Add($Message) | Out-Null
    Write-Error $Message -ErrorAction Continue
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) { Add-Failure $Message }
}

$guardText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\ProvisioningGuard.ps1') -Raw

foreach ($marker in @('guard-engage', 'guard-release', 'host-exit')) {
    Assert-True ($guardText -match "Write-WinMintProvisioningGuardLog[\s\S]{0,80}-Marker\s+'$marker'") "ProvisioningGuard.ps1 should log provisioning-lock:$marker marker."
}
Assert-True ($guardText -match 'Write-WinMintProvisioningGuardLog[\s\S]{0,80}-Marker\s+"host-start') 'ProvisioningGuard.ps1 should log provisioning-lock:host-start marker.'

foreach ($expected in @(
        'Enable-WinMintProvisioningGuard'
        'Stop-WinMintProvisioningHostResidual'
        'Start-WinMintProvisioningHost'
        'Wait-WinMintProvisioningHost'
        'Disable-WinMintProvisioningGuard'
        'DisableTaskSwitching'
    )) {
    Assert-True ($guardText -match [regex]::Escape($expected)) "ProvisioningGuard.ps1 should expose '$expected'."
}

Assert-True ($guardText -match 'Stop-WinMintSetupShellHostProcesses') 'Start-WinMintProvisioningHost should kill stale hosts without clearing an engaged guard.'
Assert-True ($guardText -match 'presenter=native') 'Start-WinMintProvisioningHost should log native presenter selection.'
Assert-True ($guardText -match 'function Start-WinMintProvisioningHostEarly') 'ProvisioningGuard should expose Start-WinMintProvisioningHostEarly for PreLock.'
Assert-True ($guardText -match 'AdoptIfRunning') 'Start-WinMintProvisioningHost should adopt a PreLock-started host.'
Assert-True ($guardText -match 'host-adopt') 'ProvisioningGuard should log host-adopt when reusing a live splash.'

Assert-True ($guardText -match 'function Broadcast-WinMintThemeChange') 'ProvisioningGuard should expose Broadcast-WinMintThemeChange for PreLock + Desktop.'
Assert-True ($guardText -match 'ImmersiveColorSet') 'Broadcast-WinMintThemeChange should send ImmersiveColorSet.'
Assert-True ($guardText -match 'function Set-WinMintProvisioningDarkChrome') 'ProvisioningGuard should expose Set-WinMintProvisioningDarkChrome for PreLock.'
Assert-True ($guardText -match 'function Set-WinMintProvisioningDarkThemeKeys') 'ProvisioningGuard should expose instant dark theme key writes for PreLock before host.'
Assert-True ($guardText -match 'WScript\.Shell') 'Start-menu dismiss should prefer COM SendKeys over Add-Type on the PreLock path.'

$preLockText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\FirstLogon.PreLock.ps1') -Raw
Assert-True ($preLockText -match 'Start-WinMintProvisioningHostEarly') 'FirstLogon.PreLock.ps1 should start the provisioning splash early.'
Assert-True ($preLockText -match 'Set-WinMintProvisioningDarkThemeKeys') 'FirstLogon.PreLock.ps1 should write dark Personalize keys before early host.'
Assert-True ($preLockText -match 'Set-WinMintProvisioningDarkChrome') 'FirstLogon.PreLock.ps1 should apply wallpaper + ImmersiveColorSet under splash cover.'
$hostIdx = $preLockText.IndexOf('Start-WinMintProvisioningHostEarly')
$chromeIdx = $preLockText.IndexOf('Set-WinMintProvisioningDarkChrome')
$keysIdx = $preLockText.IndexOf('Set-WinMintProvisioningDarkThemeKeys')
$dismissIdx = $preLockText.IndexOf('Invoke-WinMintProvisioningDismissStartMenu')
Assert-True ($keysIdx -ge 0 -and $hostIdx -gt $keysIdx) 'PreLock must write dark theme keys before starting the host.'
Assert-True ($hostIdx -ge 0 -and $chromeIdx -gt $hostIdx) 'PreLock must start the host before wallpaper/ImmersiveColorSet (avoid bloom flash on light desktop).'
Assert-True ($hostIdx -ge 0 -and $dismissIdx -gt $hostIdx) 'PreLock must start the host before Start-menu dismiss so dismiss cannot gate splash.'

$desktopText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\FirstLogon.Desktop.ps1') -Raw
Assert-True ($desktopText -match 'Broadcast-WinMintThemeChange') 'FirstLogon.Desktop.ps1 should reuse Broadcast-WinMintThemeChange (no second P/Invoke block).'

$regionText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\FirstLogon.Region.ps1') -Raw
Assert-True ($regionText -match 'function Wait-WinMintFirstLogonUserCulture') 'FirstLogon.Region.ps1 should settle culture with Wait-WinMintFirstLogonUserCulture.'
Assert-True ($regionText -match 'TimeoutMs\s*=\s*1000') 'Culture settle should use a bounded ~1000ms backoff.'

Assert-True ($guardText -match 'function Unlock-WinMintProvisioningLogonShell') 'ProvisioningGuard should expose Unlock-WinMintProvisioningLogonShell for Explorer handoff.'
Assert-True ($guardText -match 'function Test-WinMintProvisioningLogonShellActive') 'ProvisioningGuard should expose Test-WinMintProvisioningLogonShellActive.'

$logonShellCmd = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\WinMintLogonShell.cmd') -Raw
$logonShellPs1 = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\WinMintLogonShell.ps1') -Raw
Assert-True ($logonShellCmd -match 'WinMintLogonShell\.ps1') 'WinMintLogonShell.cmd should launch WinMintLogonShell.ps1.'
Assert-True ($logonShellCmd -match 'explorer\.exe') 'WinMintLogonShell.cmd should fail-open to explorer.exe when pwsh is missing.'
Assert-True ($logonShellPs1 -match 'Start-WinMintProvisioningHostEarly') 'WinMintLogonShell.ps1 should start the splash host immediately.'
Assert-True ($logonShellPs1 -match 'Unlock-WinMintProvisioningLogonShell') 'WinMintLogonShell.ps1 should unlock to explorer on terminal phase or timeout.'
Assert-True ($logonShellPs1 -match 'timeoutMinutes\s*=\s*90') 'WinMintLogonShell.ps1 should fail-open after a bounded wait.'
Assert-True ($logonShellPs1 -match 'Start-WinMintLogonShellFirstLogonIfNeeded') 'WinMintLogonShell.ps1 must self-start FirstLogon when RunOnce cannot fire under a custom Shell.'
Assert-True ($logonShellPs1 -match 'Clear-WinMintUnattendRunOnceEntries') 'WinMintLogonShell.ps1 must clear Unattend RunOnce keys after self-starting FirstLogon.'
Assert-True ($logonShellPs1 -match 'FirstLogonCommands-fired') 'WinMintLogonShell.ps1 should gate on FirstLogonCommands-fired breadcrumb.'

$defaultUserText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\DefaultUser.ps1') -Raw
Assert-True ($defaultUserText -match 'WinMintLogonShell\.cmd') 'DefaultUser.ps1 must stamp Winlogon Shell to WinMintLogonShell.cmd.'

$runtimeText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\FirstLogon.Runtime.ps1') -Raw
Assert-True ($runtimeText -match 'engage-provisioning-lock') 'FirstLogon runtime should wire engage-provisioning-lock.'
Assert-True ($runtimeText -match 'release-provisioning-lock') 'FirstLogon runtime should wire release-provisioning-lock.'
Assert-True ($runtimeText -match 'Resolve-WinMintProvisioningReleasePhase') 'Release step should derive terminal phase from agent outcome.'
Assert-True ($runtimeText -match 'AdoptIfRunning') 'engage-provisioning-lock should AdoptIfRunning the PreLock host.'
Assert-True ($runtimeText -match 'Unlock-WinMintProvisioningLogonShell') 'FirstLogon release/finalize should unlock WinMint logon shell to explorer.'
Assert-True ($runtimeText -match "releasePhase -ne 'reboot'") 'Release must not clear custom Shell on reboot-resume.'

$unlockIdx = $runtimeText.IndexOf("Unlock-WinMintProvisioningLogonShell -Reason 'finalize-success'")
$residualIdx = $runtimeText.IndexOf('Remove-WinMintResidualPayload')
Assert-True ($unlockIdx -ge 0 -and $residualIdx -gt $unlockIdx) 'finalize-success must unlock logon Shell before residual payload cleanup.'

$cleanupText = Get-Content -LiteralPath (Join-Path $root 'src\runtime\setup\FirstLogon.Cleanup.ps1') -Raw
Assert-True ($cleanupText -match 'function Remove-WinMintResidualPayload') 'FirstLogon.Cleanup.ps1 should expose Remove-WinMintResidualPayload.'
# Residual cleanup is an allowlist of FirstLogon setup names only — never the logon-shell fail-open path.
foreach ($forbidden in @('WinMintLogonShell.cmd', 'WinMintLogonShell.ps1', 'ProvisioningGuard.ps1', 'setup-shell')) {
    Assert-True ($cleanupText -notmatch [regex]::Escape($forbidden)) "Remove-WinMintResidualPayload / Cleanup must not reference '$forbidden' (unlock/fail-open depends on it)."
}

$recoveryPath = Join-Path $root 'tools\dev\Recover-WinMintLogonShell.ps1'
Assert-True (Test-Path -LiteralPath $recoveryPath) 'tools/dev/Recover-WinMintLogonShell.ps1 must exist for stuck-Shell recovery.'
$recoveryText = Get-Content -LiteralPath $recoveryPath -Raw
Assert-True ($recoveryText -match 'Shell') 'Recover-WinMintLogonShell.ps1 should restore Winlogon Shell.'
Assert-True ($recoveryText -match 'explorer\.exe') 'Recover-WinMintLogonShell.ps1 should hand off to explorer.exe.'

if ($failures.Count -gt 0) {
    throw "Provisioning guard contract tests failed with $($failures.Count) failure(s)."
}

Write-Host 'Provisioning guard contract tests passed.'
