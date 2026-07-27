#Requires -Version 7.6
# Runs from autounattend FirstLogonCommands after WinMintLogonShell has already started
# the splash as the Winlogon Shell (Explorer is not the first session UI).
# Order: lock → instant dark theme keys → adopt/start host → wallpaper/ImmersiveColorSet under cover → dismiss.
$ErrorActionPreference = 'SilentlyContinue'
$payloadRoot = $PSScriptRoot
. (Join-Path $payloadRoot 'ProvisioningGuard.ps1')

Enable-WinMintProvisioningGuard

try {
    Set-WinMintProvisioningDarkThemeKeys
}
catch { }

Start-WinMintProvisioningHostEarly -PayloadRoot $payloadRoot | Out-Null

try {
    Set-WinMintProvisioningDarkChrome
}
catch { }

try {
    Invoke-WinMintProvisioningDismissStartMenu
}
catch { }
