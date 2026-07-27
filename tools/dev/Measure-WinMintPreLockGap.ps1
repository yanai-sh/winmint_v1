#Requires -Version 7.6
<#
.SYNOPSIS
  High-resolution PreLock step timings (keys → host → chrome → dismiss).
#>
[CmdletBinding()]
param(
    [string]$PayloadRoot = 'C:\Windows\Setup\Scripts',
    [switch]$SkipHostStart
)

$ErrorActionPreference = 'Stop'
$markers = [System.Collections.Generic.List[object]]::new()
$swTotal = [System.Diagnostics.Stopwatch]::StartNew()

function Add-Marker([string]$Name) {
    $markers.Add([pscustomobject]@{
            name      = $Name
            elapsedMs = $swTotal.ElapsedMilliseconds
            at        = (Get-Date -Format 'o')
        }) | Out-Null
    Write-Host ("{0,8} ms  {1}" -f $swTotal.ElapsedMilliseconds, $Name)
}

Add-Marker 'prelock:enter'

$guardPath = Join-Path $PayloadRoot 'ProvisioningGuard.ps1'
if (-not (Test-Path -LiteralPath $guardPath)) {
    $repoGuard = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\runtime\setup\ProvisioningGuard.ps1'
    if (Test-Path -LiteralPath $repoGuard) {
        $guardPath = $repoGuard
        $PayloadRoot = Split-Path -Parent $guardPath
    }
    else {
        throw "ProvisioningGuard.ps1 not found under $PayloadRoot"
    }
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
. $guardPath
Add-Marker ("after-dot-source-guard sourceMs={0}" -f $sw.ElapsedMilliseconds)

$sw.Restart()
Enable-WinMintProvisioningGuard
Add-Marker ("after-guard-engage stepMs={0}" -f $sw.ElapsedMilliseconds)

$sw.Restart()
Set-WinMintProvisioningDarkThemeKeys
Add-Marker ("after-dark-theme-keys stepMs={0}" -f $sw.ElapsedMilliseconds)

if (-not $SkipHostStart) {
    Get-Process -Name 'WinMintSetupShell' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 200
    $sw.Restart()
    $proc = Start-WinMintProvisioningHostEarly -PayloadRoot $PayloadRoot
    Add-Marker ("after-host-start stepMs={0} pid={1}" -f $sw.ElapsedMilliseconds, $(if ($proc) { $proc.Id } else { 0 }))
}

$sw.Restart()
Set-WinMintProvisioningDarkChrome
Add-Marker ("after-dark-chrome-broadcast stepMs={0}" -f $sw.ElapsedMilliseconds)

$sw.Restart()
Invoke-WinMintProvisioningDismissStartMenu
Add-Marker ("after-dismiss-start stepMs={0}" -f $sw.ElapsedMilliseconds)

if (-not $SkipHostStart) {
    Start-Sleep -Milliseconds 400
    Get-Process -Name 'WinMintSetupShell' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    try { Disable-WinMintProvisioningGuard } catch { }
}

$report = [ordered]@{
    payloadRoot = $PayloadRoot
    totalMs     = $swTotal.ElapsedMilliseconds
    markers     = @($markers)
}
$outDir = Join-Path $env:TEMP 'winmint-prelock-gap'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$outPath = Join-Path $outDir 'prelock-gap.json'
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $outPath -Encoding utf8
Write-Host "Wrote $outPath"
$report | ConvertTo-Json -Depth 6
