#Requires -Version 7.6
<#
.SYNOPSIS
    Start a VM acceptance run for Cursor/agents — detached, logged, pollable.

.DESCRIPTION
    Writes output\vm-acceptance\managed-run.json and launches Invoke-WinMintVmAcceptance.ps1
    in one Windows Terminal window (Spectre build + harness Wait/Inspect/Evidence in the
    same session). The starter returns a JSON handle immediately; poll with
    Get-WinMintVmAcceptanceStatus.ps1. Requires an already-elevated shell (no UAC relaunch).

    Reuses cached ISO/checkpoint when fingerprints match (SmartBuild on by default).
    Use -PushOnly for fast FirstLogon iteration. Pass -ForceBuild when image staging
    changed and you need to bypass SmartBuild's ISO cache. Pass -NoLogViewer for a
    minimized headless worker. Pass -Observe for VMConnect Basic; default -NoObserve.
    Smoke Wait defaults to 90 minutes (agent under splash); pass -TimeoutMinutes 90
    explicitly on ForceBuild runs. Stall fail-fast defaults to 12 minutes
    (Splash/control live with no FirstLogon progress). Do not use Hyper-V
    Enhanced Session to judge AutoLogon — a password prompt there is the
    session channel, not Winlogon.

.EXAMPLE
    pwsh -NoProfile -File .\tools\vm\Start-WinMintVmAcceptanceManaged.ps1 `
        -ProfilePath .\tests\profiles\hyper-v-smoke-arm64.json

.EXAMPLE
    pwsh -NoProfile -File .\tools\vm\Start-WinMintVmAcceptanceManaged.ps1 `
        -ProfilePath .\tests\profiles\hyper-v-sl7-smoke-arm64.json `
        -ForceBuild -SmartBuild:$false -TimeoutMinutes 90 -Force -NoLogViewer -NoObserve
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProfilePath,
    [string]$VMName = 'WinMint-ARM-Test',
    [int]$MemoryGB = 6,
    [int]$DiskGB = 100,
    [int]$CpuCount = 4,
    [string]$SwitchName,
    [switch]$SkipBuild,
    [switch]$ForceBuild,
    [switch]$UseCheckpoint,
    [switch]$PushOnly,
    [switch]$SmartBuild,
    [switch]$FullImage,
    [ValidateSet('Auto', 'Full', 'Smoke')]
    [string]$Tier = 'Auto',
    [int]$TimeoutMinutes = 0,
    [int]$TimeBudgetMinutes = 0,
    [int]$StallMinutes = 0,
    [string]$SourceIso = '',
    [switch]$NoObserve,
    [switch]$Observe,
    [switch]$NoLogViewer,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WinMint-VmConsole.ps1')

if ($Observe) { $NoObserve = $false }
elseif (-not $PSBoundParameters.ContainsKey('NoObserve')) {
    $NoObserve = $true
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw 'VM acceptance requires an elevated PowerShell session (Hyper-V and DISM). Open an elevated terminal — UAC relaunch is not used.'
}

$repoRoot = Set-WinMintVmRepoRoot -ToolsVmRoot $PSScriptRoot
$managedPath = Get-WinMintVmManagedRunPath -RepoRoot $repoRoot
$acceptanceScript = Join-Path $PSScriptRoot 'Invoke-WinMintVmAcceptance.ps1'
$resolvedProfile = if ([IO.Path]::IsPathRooted($ProfilePath)) { $ProfilePath } else { Join-Path $repoRoot $ProfilePath }
if (-not (Test-Path -LiteralPath $resolvedProfile)) { throw "Build profile not found: $resolvedProfile" }

if (-not $PSBoundParameters.ContainsKey('SmartBuild')) { $SmartBuild = $true }
$profileJson = Get-Content -LiteralPath $resolvedProfile -Raw | ConvertFrom-Json
$buildPlan = $null
if (-not $SkipBuild) {
    $useCheckpointEffective = $UseCheckpoint.IsPresent -or (-not $ForceBuild -and -not $PushOnly)
    $buildPlan = Resolve-WinMintVmAcceptanceBuildPlan -RepoRoot $repoRoot -ProfilePath $resolvedProfile `
        -ProfileJson $profileJson -VMName $VMName -ForceBuild:$ForceBuild `
        -UseCheckpoint:$useCheckpointEffective -PushOnly:$PushOnly -SmartBuild:$SmartBuild `
        -Quality $(if ($FullImage) { 'max' } else { 'fast' })
    $ForceBuild = [bool]$buildPlan.ForceBuild
}

$prev = Read-WinMintVmManagedRunState -Path $managedPath
if ($prev -and $prev.pid -and (Test-WinMintVmProcessAlive -ProcessId ([int]$prev.pid))) {
    if (-not $Force) {
        throw "VM acceptance already running (pid $($prev.pid)). Pass -Force to stop it and start a new run."
    }
    Stop-WinMintVmProcessTree -ProcessId ([int]$prev.pid)
}

$startedAt = Get-Date
$evidenceDir = Join-Path $repoRoot ("output\vm-acceptance\$VMName-" + $startedAt.ToString('yyyyMMdd-HHmmss'))
$null = New-Item -ItemType Directory -Path $evidenceDir -Force
$runLog = Join-Path $evidenceDir 'run.log'
$null = New-Item -ItemType File -Path $runLog -Force

$timeBudget = if ($TimeBudgetMinutes -gt 0) { $TimeBudgetMinutes } else { 60 }
$runEvents = Initialize-WinMintVmRunLog -LogPath $runLog -Meta ([ordered]@{
        startedAt = $startedAt.ToString('o')
        runId = Split-Path -Leaf $evidenceDir
        vmName = $VMName
        tier = $Tier
        profile = $resolvedProfile
        managedRun = 'true'
        hostPid = $PID
        evidenceDir = $evidenceDir
        eventsFile = (Join-Path $evidenceDir 'run-events.jsonl')
        timeBudgetMinutes = $timeBudget
        pollCommand = 'pwsh -NoProfile -File .\tools\vm\Get-WinMintVmAcceptanceStatus.ps1'
    })
if ($buildPlan) {
    Write-WinMintVmRunEvent -Kind 'build-plan' -Payload @{
        strategy = [string]$buildPlan.Strategy
        estimatedMinutes = [string]$buildPlan.EstimatedMinutes
        isoCached = [bool]$buildPlan.IsoCached
        checkpointUsable = [bool]$buildPlan.CheckpointUsable
        agentChanged = [bool]$buildPlan.AgentChanged
    }
}

$verboseLog = Get-WinMintVmBuildVerboseLogPath -RepoRoot $repoRoot
$pwsh = Resolve-WinMintPwshHostPath
$childArgs = @(
    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', $acceptanceScript,
    '-ManagedRun',
    '-ProfilePath', $resolvedProfile,
    '-VMName', $VMName,
    '-MemoryGB', $MemoryGB,
    '-DiskGB', $DiskGB,
    '-CpuCount', $CpuCount,
    '-Tier', $Tier,
    '-EvidenceDir', $evidenceDir
)
if ($TimeoutMinutes -gt 0) { $childArgs += @('-TimeoutMinutes', $TimeoutMinutes) }
if ($TimeBudgetMinutes -gt 0) { $childArgs += @('-TimeBudgetMinutes', $TimeBudgetMinutes) }
if ($StallMinutes -gt 0) { $childArgs += @('-StallMinutes', $StallMinutes) }
if ($SwitchName) { $childArgs += @('-SwitchName', $SwitchName) }
if ($SkipBuild) { $childArgs += '-SkipBuild' }
if ($ForceBuild) { $childArgs += '-ForceBuild' }
if ($UseCheckpoint) { $childArgs += '-UseCheckpoint' }
if ($PushOnly) { $childArgs += '-PushOnly' }
# Always forward SmartBuild so -SmartBuild:$false survives into the worker.
# Omitting the switch made Invoke default managed runs back to SmartBuild=on,
# which then ignored -ForceBuild and reused a stale ISO.
if ($SmartBuild) { $childArgs += '-SmartBuild' }
else { $childArgs += '-SmartBuild:$false' }
if ($FullImage) { $childArgs += '-FullImage' }
if (-not [string]::IsNullOrWhiteSpace($SourceIso)) { $childArgs += @('-SourceIso', $SourceIso) }
if ($NoObserve) { $childArgs += '-NoObserve' }

$errLog = Join-Path $evidenceDir 'run.err.log'
# One live console: Spectre build + harness phases. Do not RedirectStandardOutput
# (flattens Spectre). Do not open separate verbose/run.log tail tabs.
$launch = Start-WinMintVmAcceptanceWorkerConsole `
    -RepoRoot $repoRoot `
    -PwshPath $pwsh `
    -PwshArguments $childArgs `
    -ErrLog $errLog `
    -NoConsole:$NoLogViewer

$handle = [ordered]@{
    status = 'starting'
    pid = 0
    profile = $resolvedProfile
    vmName = $VMName
    evidenceDir = $evidenceDir
    runLog = $runLog
    verboseLog = $verboseLog
    runEvents = $runEvents
    managedRunPath = $managedPath
    acceptanceResult = Join-Path $evidenceDir 'acceptance-result.json'
    startedAt = $startedAt.ToString('o')
    currentPhase = 'starting'
    timeBudgetMinutes = $timeBudget
    consoleMode = [string]$launch.Mode
    logViewerOpened = [bool]$launch.ConsoleOpened
    observeMode = if ($NoObserve) { 'headless' } else { 'basic' }
    pollCommand = "pwsh -NoProfile -File .\tools\vm\Get-WinMintVmAcceptanceStatus.ps1"
    tailCommand = "Get-Content -LiteralPath '$verboseLog' -Wait -Tail 40"
    runLogTailCommand = "Get-Content -LiteralPath '$runLog' -Wait -Tail 30"
}
if ($buildPlan) {
    $handle.buildStrategy = [string]$buildPlan.Strategy
    $handle.buildEstimatedMinutes = [string]$buildPlan.EstimatedMinutes
    $handle.isoCached = [bool]$buildPlan.IsoCached
    $handle.checkpointUsable = [bool]$buildPlan.CheckpointUsable
}
if ($launch.WorkerPidKnown -and $launch.Process) {
    $handle.pid = [int]$launch.Process.Id
}
Write-WinMintVmManagedRunState -Path $managedPath -State $handle

$ready = Wait-WinMintVmManagedWorkerReady `
    -ManagedPath $managedPath `
    -TimeoutSeconds 45 `
    -LaunchProcess $launch.Process

if (-not $ready.Ok) {
    $currentState = Read-WinMintVmManagedRunState -Path $managedPath
    if ($ready.Reason -eq 'launch-process-exited') {
        $bootError = "Acceptance process exited immediately (exit code $($ready.ExitCode))."
        Write-WinMintVmLogLine -Message $bootError -LogPath $runLog -Level 'ERROR'
        Write-WinMintVmRunEvent -Kind 'verdict' -Payload @{ verdict = 'fail'; reason = 'boot-failed'; exitCode = $ready.ExitCode }
        if (-not $currentState) { $currentState = [pscustomobject]$handle }
        $currentState | Add-Member -MemberType NoteProperty -Name 'status' -Value 'failed' -Force
        $currentState | Add-Member -MemberType NoteProperty -Name 'currentPhase' -Value 'boot-failed' -Force
        $currentState | Add-Member -MemberType NoteProperty -Name 'error' -Value $bootError -Force
        Write-WinMintVmManagedRunState -Path $managedPath -State $currentState
        throw $bootError
    }
    if ($currentState -and [string]$currentState.status -eq 'failed') {
        throw "Acceptance process failed during start. Reason: $($currentState.error)"
    }
    if ($ready.Pid -gt 0) {
        $handle.pid = $ready.Pid
        Write-WinMintVmManagedRunState -Path $managedPath -State $handle
    }
    else {
        throw 'Acceptance worker did not publish a managed-run pid within 45s (Windows Terminal / pwsh launch failed?).'
    }
}
else {
    $handle.pid = $ready.Pid
    $handle.status = 'running'
    if ($ready.State -and $ready.State.currentPhase) {
        $handle.currentPhase = [string]$ready.State.currentPhase
    }
    # Preserve starter fields the worker may omit on first Update-WinMintVmManagedRun.
    $merged = Read-WinMintVmManagedRunState -Path $managedPath
    if ($merged) {
        foreach ($key in @('verboseLog', 'consoleMode', 'logViewerOpened', 'buildStrategy', 'buildEstimatedMinutes', 'isoCached', 'checkpointUsable', 'tailCommand', 'runLogTailCommand', 'timeBudgetMinutes')) {
            if ($handle.Contains($key) -and -not ($merged.PSObject.Properties[$key] -and $null -ne $merged.$key -and "$($merged.$key)" -ne '')) {
                $merged | Add-Member -MemberType NoteProperty -Name $key -Value $handle[$key] -Force
            }
        }
        if (-not $merged.PSObject.Properties['pid'] -or [int]$merged.pid -le 0) {
            $merged | Add-Member -MemberType NoteProperty -Name 'pid' -Value $handle.pid -Force
        }
        Write-WinMintVmManagedRunState -Path $managedPath -State $merged
        $handle = [ordered]@{}
        foreach ($p in $merged.PSObject.Properties) { $handle[$p.Name] = $p.Value }
    }
    else {
        Write-WinMintVmManagedRunState -Path $managedPath -State $handle
    }
}

$handle | ConvertTo-Json -Depth 6
