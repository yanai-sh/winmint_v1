#Requires -Version 7.6
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Probe whether this host can Start-VM a Gen2 VM with Hyper-V vTPM enabled.

.DESCRIPTION
  Diagnoses the host-side gate used by New-WinMintTestVm.ps1 (Secure Boot +
  Enable-VMTPM + Start-VM). Prints NUMA/HGS/binary hardlink facts and runs a
  short-lived probe VM. Exit 0 = TPM Start-VM OK; 1 = fail.

  Does not uninstall updates or change Windows features.
#>
[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 35
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop

function Write-Fact([string]$Name, [string]$Value) {
    Write-Host ("{0,-28} {1}" -f $Name, $Value)
}

$os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Fact 'OS' ("{0} {1}.{2}" -f $os.DisplayVersion, $os.CurrentBuild, $os.UBR)
Write-Fact 'NumaSpanning' ([string](Get-VMHost).NumaSpanningEnabled)

try {
    Import-Module HgsClient -ErrorAction Stop
    $g = Get-HgsGuardian -Name UntrustedGuardian -ErrorAction Stop
    Write-Fact 'UntrustedGuardian' ("HasPrivateSigningKey={0}" -f $g.HasPrivateSigningKey)
}
catch {
    Write-Fact 'UntrustedGuardian' ("ERR: {0}" -f $_.Exception.Message)
}

foreach ($bin in @('vmwp.exe', 'vmcompute.exe', 'vmms.exe')) {
    $path = Join-Path $env:SystemRoot "System32\$bin"
    $item = Get-Item -LiteralPath $path
    $links = @(fsutil hardlink list $path 2>$null)
    $sx = ($links | Where-Object { $_ -match 'WinSxS' } | Select-Object -First 1)
    Write-Fact $bin ("ver={0}; sx={1}" -f $item.VersionInfo.FileVersion, ($sx ?? 'none'))
}

$probe = "WinMint-VtpmProbe-$(Get-Date -Format HHmmss)"
$vhdx = Join-Path $env:TEMP "$probe.vhdx"
$started = $false
try {
    $null = New-VM -Name $probe -Generation 2 -MemoryStartupBytes 2GB -NewVHDPath $vhdx -NewVHDSizeBytes 20GB
    Set-VMFirmware -VMName $probe -SecureBootTemplate MicrosoftWindows
    Set-VMKeyProtector -VMName $probe -NewLocalKeyProtector
    Enable-VMTPM -VMName $probe

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Start-VM -Name $probe -ErrorAction Stop
        $sw.Stop()
        $started = $true
        Write-Fact 'TPM_StartVM' ("OK in {0:N1}s" -f $sw.Elapsed.TotalSeconds)
        Stop-VM -Name $probe -Force -TurnOff -ErrorAction SilentlyContinue
    }
    catch {
        $sw.Stop()
        Write-Fact 'TPM_StartVM' ("FAIL after {0:N1}s :: {1}" -f $sw.Elapsed.TotalSeconds, ($_.Exception.Message -split "`n")[0])
    }
}
finally {
    Remove-VM -Name $probe -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $vhdx -Force -ErrorAction SilentlyContinue
}

if ($started) { exit 0 }
exit 1
