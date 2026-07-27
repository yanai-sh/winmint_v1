#Requires -Version 7.6
<#
.SYNOPSIS
    Build a WinMint ISO from a profile and boot it in a fresh Hyper-V test VM, in
    one elevated run.

.DESCRIPTION
    Orchestrates the full local acceptance loop:

      1. Stop (and remove) any existing test VM FIRST, before building. A running
         VM holds its full startup RAM; servicing a multi-GB WIM with DISM at the
         same time can starve the host and make the Hyper-V management service
         (vmms) shut down mid-build (event 14090), which leaves the VM unmanageable
         and vmconnect unable to reach the host. Freeing the VM's memory before the
         build avoids that contention.
      2. Build the ISO from the profile via `WinMint-CLI.ps1 build`.
      3. Create + boot a Gen 2 (UEFI + Secure Boot + vTPM by default) VM from the
         new ISO via New-WinMintTestVm.ps1 -Recreate. When the profile sets
         posture.setup.hardwareBypass, vTPM is skipped so host TPM regressions
         can still exercise Setup/FirstLogon.

    Requires an elevated PowerShell (WIM servicing and Hyper-V both need admin).

.EXAMPLE
    pwsh -NoProfile -File .\tools\vm\Build-And-TestVm.ps1 -ProfilePath .\output\vm-test.json

.EXAMPLE
    pwsh -NoProfile -File .\tools\vm\Build-And-TestVm.ps1 -ProfilePath .\tests\profiles\hyper-v-install-arm64.json -MemoryGB 4 -NoConnect
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProfilePath,
    [string]$VMName = 'WinMint-ARM-Test',
    [int]$MemoryGB = 6,
    [int]$DiskGB = 100,
    [int]$CpuCount = 4,
    [string]$SwitchName,
    [switch]$NoConnect,
    [switch]$ConnectBasic,
    [switch]$ForceBuild,
    [switch]$FullImage,
    [switch]$UseCheckpoint,
    [switch]$AcceptanceRun,
    [ValidateSet('Auto', 'Headless', 'Console')]
    [string]$AgentMode = 'Auto',
    [ValidateSet('Auto', 'Full', 'Smoke')]
    [string]$Tier = 'Auto',
    [string]$SourceIso = '',
    [switch]$SkipOfflineVerify
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WinMint-VmConsole.ps1')
$repoRoot = Set-WinMintVmRepoRoot -ToolsVmRoot $PSScriptRoot

if ($NoConnect -and $ConnectBasic) {
    throw 'Use only one of -NoConnect or -ConnectBasic.'
}

# Image fingerprint covers ISO/WIM servicing and staged setup payloads. Agent
# fingerprint covers live-pushable setup/firstlogon scripts only.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw 'Run this in an elevated PowerShell - building (WIM servicing) and Hyper-V both require Administrator.'
}
if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
    throw 'Hyper-V PowerShell module not found. Enable it: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All'
}

$resolvedProfile = if ([IO.Path]::IsPathRooted($ProfilePath)) { $ProfilePath } else { Join-Path $repoRoot $ProfilePath }
if (-not (Test-Path -LiteralPath $resolvedProfile)) {
    throw "Build profile not found: $resolvedProfile"
}
$profileJson = Get-Content -LiteralPath $resolvedProfile -Raw | ConvertFrom-Json
$profileTier = Resolve-WinMintVmAcceptanceTier -RequestedTier $Tier -ProfileJson $profileJson
$guestUser = ''
$guestPassword = ''
if ($profileJson.identity -and [string]$profileJson.identity.accountMode -eq 'Local') {
    $guestUser = [string]$profileJson.identity.accountName
    $guestPassword = [string]$profileJson.identity.password
    if ([string]::IsNullOrWhiteSpace($guestUser) -or [string]::IsNullOrWhiteSpace($guestPassword)) {
        throw 'Local-account VM acceptance requires identity.accountName and identity.password in the profile.'
    }
}

$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
& $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Test-WinMintHyperVProfile.ps1') -ProfilePath $resolvedProfile -Tier $profileTier
if ($LASTEXITCODE -ne 0) {
    throw "Hyper-V profile validation failed with exit code $LASTEXITCODE."
}

$outputDir = Join-Path $repoRoot 'output'
$imageQuality = if ($FullImage) { 'max' } else { 'fast' }
$imageFp = Get-WinMintVmImageBuildFingerprint -ProfilePath $resolvedProfile -ProfileJson $profileJson -RepoRoot $repoRoot -Quality $imageQuality
$agentFp = Get-WinMintVmAgentBuildFingerprint -RepoRoot $repoRoot
$cred = $null
if (-not [string]::IsNullOrWhiteSpace($guestUser) -and -not [string]::IsNullOrWhiteSpace($guestPassword)) {
    $cred = [pscredential]::new($guestUser, (ConvertTo-SecureString $guestPassword -AsPlainText -Force))
}

if ($UseCheckpoint -and -not $ForceBuild -and (Test-WinMintVmPostSetupCheckpointUsable -VMName $VMName -Fingerprint $imageFp -RepoRoot $repoRoot)) {
    if (-not $cred) {
        throw 'Checkpoint iteration requires a Local-account profile with identity.accountName and identity.password.'
    }
    Invoke-WinMintVmAcceptanceCheckpointIteration -VMName $VMName -Credential $cred -RepoRoot $repoRoot `
        -ToolsVmRoot $PSScriptRoot -ProfilePath $resolvedProfile -ImageFingerprint $imageFp `
        -AgentMode $AgentMode -SwitchName $SwitchName -AlwaysPushAgent:$AcceptanceRun.IsPresent
    exit 0
}

# 1. Free the host before building: stop the existing test VM so it is not holding
#    RAM while DISM services the image. Remove it too so the build starts clean.
$existing = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($existing) {
    if ($existing.State -ne 'Off') {
        Write-Host "Stopping running test VM '$VMName' before build (frees RAM for DISM servicing)."
        Stop-VM -Name $VMName -TurnOff -Force
    }
    $oldVhds = @($existing.HardDrives.Path)
    Remove-VM -Name $VMName -Force
    foreach ($p in $oldVhds) { if ($p -and (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } }
    Write-Host "Removed prior '$VMName' so the build runs with no VM competing for resources."
}

# 2. Build the ISO from the profile (verb CLI) - unless nothing that affects the
#    ISO changed since the last build and that ISO is still on disk, in which case
#    boot it as-is and skip the multi-minute rebuild.
$cli = Join-Path $repoRoot 'WinMint-CLI.ps1'
$fingerprintPath = Join-Path $outputDir '.vm-build-fingerprint.json'

$builtIso = $null
$isoReused = $false
if (-not $ForceBuild -and (Test-Path -LiteralPath $fingerprintPath)) {
    try {
        $prev = Get-Content -LiteralPath $fingerprintPath -Raw | ConvertFrom-Json
        $prevImage = if ($prev.PSObject.Properties['imageFingerprint'] -and -not [string]::IsNullOrWhiteSpace([string]$prev.imageFingerprint)) {
            [string]$prev.imageFingerprint
        }
        else {
            [string]$prev.fingerprint
        }
        if ($prev.isoPath -and (Test-Path -LiteralPath ([string]$prev.isoPath))) {
            if ($prevImage -eq $imageFp) {
                $builtIso = Get-Item -LiteralPath ([string]$prev.isoPath)
                $isoReused = $true
                Write-Host "No build-affecting changes since the last run - reusing existing ISO (skipping build):"
                Write-Host "  $($builtIso.FullName)"
            }
            elseif (-not $prev.PSObject.Properties['imageFingerprint']) {
                $builtIso = Get-Item -LiteralPath ([string]$prev.isoPath)
                $isoReused = $true
                Write-Host 'Reusing cached ISO from legacy fingerprint sidecar (image layer assumed unchanged).'
                Write-Host "  $($builtIso.FullName)"
            }
        }
    }
    catch { }  # unreadable sidecar -> fall through to a normal build
}

if (-not $builtIso) {
    $setupShellRoot = Join-Path $repoRoot 'assets\runtime\setup\setup-shell\bin'
    $needsSetupShellPublish = @('x64', 'arm64') | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $setupShellRoot "$_\WinMintSetupShell.exe") -PathType Leaf)
    }
    if ($needsSetupShellPublish) {
        Write-Host 'Publishing WinMintSetupShell.exe (missing staged binary for one or more arches).'
        & (Join-Path $repoRoot 'tools\release\Build-WinMintSetupShell.ps1') -AllArch
    }

    $buildStartedAtUtc = [datetime]::UtcNow.AddSeconds(-15)
    # Default to -FastImage (skip recompression + WinSxS cleanup): WinMint is alpha
    # and the VM loop runs many times - install/FirstLogon behavior is identical, only
    # the final image size differs. Pass -FullImage for a production-quality ISO.
    Write-Host "Building ISO from profile ($imageQuality image): $resolvedProfile"
    $buildCliArgs = @($resolvedProfile, '-Yes')
    if (-not $FullImage) { $buildCliArgs += '-FastImage' }
    if (-not [string]::IsNullOrWhiteSpace($SourceIso)) {
        $resolvedSourceIso = if ([IO.Path]::IsPathRooted($SourceIso)) { $SourceIso } else { Join-Path $repoRoot $SourceIso }
        if (-not (Test-Path -LiteralPath $resolvedSourceIso -PathType Leaf)) {
            throw "Source ISO not found: $resolvedSourceIso"
        }
        if ((Get-Item -LiteralPath $resolvedSourceIso).Length -lt 1MB) {
            throw "Source ISO appears invalid (too small): $resolvedSourceIso"
        }
        $buildCliArgs += @('-SourceIso', $resolvedSourceIso)
        Write-Host "Using source ISO override: $resolvedSourceIso"
    }
    & $cli build @buildCliArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Build failed (exit code $LASTEXITCODE). See the WinMint build report in .\output."
    }
    # Resolve the ISO this build just wrote. Do NOT pick "newest LastWriteTime":
    # Hyper-V / Mount-DiskImage can touch an older ISO's mtime and win the race
    # (seen: ForceBuild wrote WinMint-…-184334.iso but booted stale …-161242.iso).
    $builtIso = $null
    $verboseLog = Get-WinMintVmBuildVerboseLogPath -RepoRoot $repoRoot
    if (Test-Path -LiteralPath $verboseLog) {
        $finalMatch = Select-String -LiteralPath $verboseLog -Pattern 'Final ISO:\s+(.+?\.iso)\b' |
            Select-Object -Last 1
        if ($finalMatch) {
            $finalPath = $finalMatch.Matches[0].Groups[1].Value.Trim()
            if ($finalPath -and (Test-Path -LiteralPath $finalPath -PathType Leaf)) {
                $candidate = Get-Item -LiteralPath $finalPath
                if ($candidate.CreationTimeUtc -ge $buildStartedAtUtc.AddMinutes(-5) -or $candidate.LastWriteTimeUtc -ge $buildStartedAtUtc) {
                    $builtIso = $candidate
                    Write-Host "Using Final ISO from build log: $($builtIso.FullName)"
                }
            }
        }
    }
    if (-not $builtIso) {
        $builtIso = Get-ChildItem -LiteralPath $outputDir -Filter 'WinMint-*.iso' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.CreationTimeUtc -ge $buildStartedAtUtc } |
            Sort-Object CreationTimeUtc -Descending |
            Select-Object -First 1
    }
    if (-not $builtIso) {
        throw "Build completed but no WinMint-*.iso created after $($buildStartedAtUtc.ToString('o')) (UTC) was found in $outputDir."
    }
    # Record what we just built so an unchanged next run can skip straight to boot.
    ([ordered]@{
            fingerprint = $imageFp
            imageFingerprint = $imageFp
            agentFingerprint = $agentFp
            isoPath = $builtIso.FullName
            builtUtc = [datetime]::UtcNow.ToString('o')
        } |
        ConvertTo-Json) | Set-Content -LiteralPath $fingerprintPath -Encoding UTF8
}

if (-not $SkipOfflineVerify) {
    $offlineOut = Join-Path (Split-Path -Parent $builtIso.FullName) 'offline-removal-drift.json'
    $skipOffline = $isoReused -and (Test-Path -LiteralPath $offlineOut)
    if ($skipOffline) {
        Write-Host "Skipping offline WIM removal verify (reused ISO; prior report: $offlineOut)."
    }
    else {
        $offlineArgs = @(
            '-NoProfile', '-File', (Join-Path $PSScriptRoot 'Test-WinMintOfflineImageRemovals.ps1'),
            '-IsoPath', $builtIso.FullName,
            '-ProfilePath', $resolvedProfile,
            '-OutputPath', $offlineOut
        )
        & $pwsh @offlineArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Offline WIM removal verification failed (exit code $LASTEXITCODE). See $offlineOut"
        }
    }
}

# 3. Create + boot the VM from the ISO produced by this build.
$profileJson = Get-Content -LiteralPath $resolvedProfile -Raw | ConvertFrom-Json
$skipVtpm = $false
try {
    $skipVtpm = [bool]$profileJson.posture.setup.hardwareBypass
}
catch {
    $skipVtpm = $false
}
$vmArgs = @{
    VMName    = $VMName
    IsoPath   = $builtIso.FullName
    MemoryGB  = $MemoryGB
    DiskGB    = $DiskGB
    CpuCount  = $CpuCount
    Recreate  = $true
}
if ($SwitchName) { $vmArgs['SwitchName'] = $SwitchName }
if ($ConnectBasic) { $vmArgs['ConnectBasic'] = $true }
elseif ($NoConnect) { $vmArgs['NoConnect'] = $true }
if ($skipVtpm) {
    $vmArgs['SkipVtpm'] = $true
    Write-Host 'Profile hardwareBypass=true: creating Gen2 VM without Enable-VMTPM.'
}
& (Join-Path $PSScriptRoot 'New-WinMintTestVm.ps1') @vmArgs

