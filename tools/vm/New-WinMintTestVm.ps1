#Requires -Version 7.6
<#
.SYNOPSIS
    Create and boot a Hyper-V Gen 2 VM (UEFI + Secure Boot, vTPM by default) from a
    WinMint ISO to test the install end to end.

.DESCRIPTION
    Builds the kind of VM Windows 11 normally requires (Generation 2, Secure Boot
    with the Microsoft Windows template, and a virtual TPM) from the newest ISO in
    .\output (or a -IsoPath you pass). Pass -SkipVtpm when the profile uses
    hardwareBypass and the host cannot start TPM-enabled VMs; Setup then relies on
    LabConfig instead of a vTPM.

    The guest architecture follows the Hyper-V host (an ARM64 host produces ARM64
    guests), so run this on the same architecture as the ISO you built.

    Requires an elevated PowerShell (Hyper-V management needs Administrator).

.EXAMPLE
    pwsh -NoProfile -File .\tools\vm\New-WinMintTestVm.ps1

.EXAMPLE
    pwsh -NoProfile -File .\tools\vm\New-WinMintTestVm.ps1 -Recreate -DiskGB 128 -MemoryGB 8
#>
[CmdletBinding()]
param(
    [string]$IsoPath,
    [string]$VMName = 'WinMint-ARM-Test',
    [int]$MemoryGB = 6,
    [int]$DiskGB = 100,
    [int]$CpuCount = 4,
    [string]$SwitchName,
    [switch]$ExposeNestedVirtualization,
    [switch]$Recreate,
    [switch]$NoConnect,
    [switch]$ConnectBasic,
    [switch]$SkipVtpm
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WinMint-VmConsole.ps1')

if ($NoConnect -and $ConnectBasic) {
    throw 'Use only one of -NoConnect or -ConnectBasic.'
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw 'Run this in an elevated PowerShell — Hyper-V management requires Administrator.'
}
if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
    throw 'Hyper-V PowerShell module not found. Enable it: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All'
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# Resolve the ISO: explicit -IsoPath, else the newest WinMint-*.iso in .\output.
if (-not $IsoPath) {
    $outputDir = Join-Path $repoRoot 'output'
    $latest = Get-ChildItem -LiteralPath $outputDir -Filter 'WinMint-*.iso' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { throw "No WinMint-*.iso found in $outputDir. Pass -IsoPath explicitly." }
    $IsoPath = $latest.FullName
}
if (-not (Test-Path -LiteralPath $IsoPath)) { throw "ISO not found: $IsoPath" }

# Recreate or refuse if the VM already exists.
$existing = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($existing) {
    if (-not $Recreate) {
        throw "VM '$VMName' already exists. Re-run with -Recreate to delete and rebuild it (this destroys its disk)."
    }
    if ($existing.State -ne 'Off') { Stop-VM -Name $VMName -TurnOff -Force }
    $oldVhds = @($existing.HardDrives.Path)
    Remove-VM -Name $VMName -Force
    foreach ($p in $oldVhds) { if ($p -and (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $p -Force } }
}

$vhdDir = Join-Path $env:USERPROFILE 'Hyper-V'
New-Item -ItemType Directory -Force -Path $vhdDir | Out-Null
$vhd = Join-Path $vhdDir "$VMName.vhdx"
if (Test-Path -LiteralPath $vhd) { Remove-Item -LiteralPath $vhd -Force }

# Attach the NAT "Default Switch" so the guest reaches the internet through the
# host. First-logon polling and PostSetup checkpoints live in Invoke-WinMintVmAcceptance.ps1.
# ponytail: NoConnect suppresses vmconnect only; default opens Basic session (no Enhanced Session password).
# Automated acceptance passes -ConnectBasic by default. Network and GUI are separate.
if (-not $SwitchName) {
    if (Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue) { $SwitchName = 'Default Switch' }
}

Write-Host "Creating $VMName from $IsoPath"
$null = New-VM -Name $VMName -Generation 2 -MemoryStartupBytes ($MemoryGB * 1GB) -NewVHDPath $vhd -NewVHDSizeBytes ($DiskGB * 1GB)
Set-VMProcessor -VMName $VMName -Count $CpuCount
if ($ExposeNestedVirtualization) {
    # WSL2 in a guest VM requires nested virtualization. Keep this opt-in so
    # hosts that do not support nested virtualization can still boot the test VM.
    try {
        Set-VMProcessor -VMName $VMName -ExposeVirtualizationExtensions $true
    }
    catch {
        Write-Warning "Could not expose virtualization extensions for nested WSL2: $($_.Exception.Message)"
    }
}
# Static memory: Windows Setup is happier with a fixed allocation than dynamic.
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false -StartupBytes ($MemoryGB * 1GB)
if ($SwitchName) { Connect-VMNetworkAdapter -VMName $VMName -SwitchName $SwitchName }
Add-VMDvdDrive -VMName $VMName -Path $IsoPath
# Windows 11 prerequisites: Secure Boot (Windows template) + virtual TPM by default.
Set-VMFirmware -VMName $VMName -SecureBootTemplate MicrosoftWindows
if ($SkipVtpm) {
    Write-Warning "Skipping Enable-VMTPM for '$VMName' (-SkipVtpm). Profile must set posture.setup.hardwareBypass = true or Setup will refuse the guest."
}
else {
    Set-VMKeyProtector -VMName $VMName -NewLocalKeyProtector
    Enable-VMTPM -VMName $VMName
}
Set-VMFirmware -VMName $VMName -FirstBootDevice (Get-VMDvdDrive -VMName $VMName)

Set-WinMintVmConnectVideo -VMName $VMName
Set-WinMintVmConnectPreset -VMName $VMName -BasicSession
Start-VM -Name $VMName
if (-not $NoConnect) {
    $null = Open-WinMintVmConnectBasicWatch -VMName $VMName
    Write-Host 'Opened VMConnect Basic session (no password — watch Setup and FirstLogon here).'
}
Write-Host ("Started {0}: {1} GB RAM, {2} vCPU, {3} GB disk, switch '{4}'." -f `
    $VMName, $MemoryGB, $CpuCount, $DiskGB, ($SwitchName ? $SwitchName : 'none'))
Write-Host "Logs after install: C:\ProgramData\WinMint\Logs (inside the guest)."

