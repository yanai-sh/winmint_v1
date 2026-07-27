#Requires -Version 7.6
<#
.SYNOPSIS
    Run the full WinMint Hyper-V VM acceptance pass and emit a single pass/fail
    verdict plus an evidence folder.

.DESCRIPTION
    Sequences build + boot, wait for FirstLogon, inspect, and evidence collection.
    Use -Phase to run a single step, -SkipBuild to attach to a running VM, or
    -EvidenceDir to resume into an existing evidence folder. Runs in the current
    console by default; pass -WindowsTerminal to open a new WT tab instead.

.EXAMPLE
    # Elevated Windows Terminal at the repo root (recommended):
    cd C:\path\to\winmint
    pwsh -NoProfile -File .\tools\vm\Invoke-WinMintVmAcceptance.ps1 -ProfilePath .\tests\profiles\hyper-v-smoke-arm64.json

.EXAMPLE
    pwsh -NoProfile -File .\tools\vm\Invoke-WinMintVmAcceptance.ps1 -ProfilePath .\tests\profiles\hyper-v-install-arm64.json -SkipBuild

.EXAMPLE
    pwsh -NoProfile -File .\tools\vm\Invoke-WinMintVmAcceptance.ps1 -ProfilePath .\tests\profiles\hyper-v-smoke-arm64.json -Phase BuildBoot
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
    [ValidateSet('All', 'BuildBoot', 'Wait', 'Inspect', 'Evidence')]
    [string]$Phase = 'All',
    [ValidateSet('Auto', 'Full', 'Smoke')]
    [string]$Tier = 'Auto',
    [int]$TimeoutMinutes = 0,
    [int]$TimeBudgetMinutes = 0,
    # Fail Wait early when splash/control is live but agent never starts (Shell/RunOnce deadlock, etc.).
    # 0 = tier default (Smoke 12, Full 15). Ceiling remains TimeoutMinutes.
    [int]$StallMinutes = 0,
    [string]$SourceIso = '',
    [string]$EvidenceRoot,
    [string]$EvidenceDir,
    [switch]$WindowsTerminal,
    [switch]$NoWindowsTerminal,
    [switch]$NoObserve,
    [switch]$ManagedRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WinMint-VmConsole.ps1')
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $repoRoot 'tools\acceptance\New-WinMintAcceptanceResult.ps1')
. (Join-Path $repoRoot 'src\runtime\image\WinMint.ps1')

$repoRoot = Set-WinMintVmRepoRoot -ToolsVmRoot $PSScriptRoot
$script:managedRun = $ManagedRun.IsPresent -or $env:WINMINT_VM_MANAGED -eq '1'
$script:managedRunPath = Get-WinMintVmManagedRunPath -RepoRoot $repoRoot

trap {
    $err = $_
    if ($EvidenceDir) {
        $rLog = Join-Path $EvidenceDir 'run.log'
        Add-Content -Path $rLog -Value "[$((Get-Date).ToString('o'))] [ERROR] FATAL: $($err.Exception.Message)"
    }
    if ($script:managedRunPath -and (Test-Path -LiteralPath $script:managedRunPath)) {
        $st = Get-Content -LiteralPath $script:managedRunPath | ConvertFrom-Json
        $st.status = 'failed'
        $st.currentPhase = 'boot-failed'
        $st | Add-Member -MemberType NoteProperty -Name 'error' -Value $err.Exception.Message -Force
        $st | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $script:managedRunPath -Encoding utf8
    }
    throw $err
}
if ($script:managedRun) {
    $WindowsTerminal = $false
    $NoWindowsTerminal = $true
}
elseif (-not (Test-WinMintVmInlineConsole -WindowsTerminal:$WindowsTerminal -NoWindowsTerminal:$NoWindowsTerminal)) {
    $tabTitle = 'WinMint VM Acceptance'
    if (Start-WinMintVmScriptInWindowsTerminal -ScriptPath $PSCommandPath -StartingDirectory $repoRoot -BoundParameters $PSBoundParameters -TabTitle $tabTitle) {
        exit 0
    }
}

Write-Host "WinMint VM acceptance (repo: $repoRoot)" -ForegroundColor DarkGray

function Write-WinMintVmAcceptanceNextStep {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$RunLog
    )

    Write-WinMintVmLogLine -Message $Message -LogPath $RunLog -Color 'DarkGray' -Level 'INFO'
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw 'Run from an elevated PowerShell session. Hyper-V and WIM servicing require Administrator. Working directory is set to the WinMint repo automatically.'
}
if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
    throw 'Hyper-V PowerShell module not found. Enable it: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All'
}

$resolvedProfile = if ([IO.Path]::IsPathRooted($ProfilePath)) { $ProfilePath } else { Join-Path $repoRoot $ProfilePath }
if (-not (Test-Path -LiteralPath $resolvedProfile)) { throw "Build profile not found: $resolvedProfile" }
$profileJson = Get-Content -LiteralPath $resolvedProfile -Raw | ConvertFrom-Json
$acceptanceTier = Resolve-WinMintVmAcceptanceTier -RequestedTier $Tier -ProfileJson $profileJson
if ($TimeoutMinutes -le 0) {
    # Smoke Wait must outlast SL7 agent work under splash (align with WinMintLogonShell fail-open).
    $TimeoutMinutes = if ($acceptanceTier -eq 'Smoke') { 90 } else { 60 }
}
if ($TimeBudgetMinutes -le 0) {
    $TimeBudgetMinutes = if ($acceptanceTier -eq 'Smoke') { 60 } else { 55 }
}
if ($StallMinutes -le 0) {
    $StallMinutes = if ($acceptanceTier -eq 'Smoke') { 12 } else { 15 }
}
$script:setupShellWatch = New-WinMintVmSetupShellWatch
$script:observePid = 0
$script:observeMode = ''
$acceptanceStartedAt = Get-Date

$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
& $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Test-WinMintHyperVProfile.ps1') -ProfilePath $resolvedProfile -Tier $acceptanceTier
if ($LASTEXITCODE -ne 0) {
    throw "Hyper-V profile validation failed with exit code $LASTEXITCODE."
}

if (-not $profileJson.identity -or [string]$profileJson.identity.accountMode -ne 'Local') {
    throw 'VM acceptance requires a Local-account profile so the install is unattended and PowerShell Direct can sign in.'
}
$guestUser = [string]$profileJson.identity.accountName
$guestPassword = [string]$profileJson.identity.password
if ([string]::IsNullOrWhiteSpace($guestUser) -or [string]::IsNullOrWhiteSpace($guestPassword)) {
    throw 'The profile must set identity.accountName and identity.password for unattended VM acceptance.'
}
$cred = [pscredential]::new($guestUser, (ConvertTo-SecureString $guestPassword -AsPlainText -Force))
$agentMode = if ($acceptanceTier -eq 'Smoke') { 'Auto' } else { 'Headless' }

$runBuildBoot = ($Phase -in @('All', 'BuildBoot')) -and -not ($SkipBuild -and $Phase -eq 'All')
if (-not $PSBoundParameters.ContainsKey('UseCheckpoint') -and -not $ForceBuild -and $runBuildBoot) {
    $UseCheckpoint = $true
}
if ($script:managedRun -and -not $PSBoundParameters.ContainsKey('SmartBuild')) {
    # Default SmartBuild on for managed runs, but never when -ForceBuild was requested.
    $SmartBuild = -not $ForceBuild
}
$imageQuality = if ($FullImage) { 'max' } else { 'fast' }
$buildPlan = $null
if ($runBuildBoot -or $PushOnly) {
    $buildPlan = Resolve-WinMintVmAcceptanceBuildPlan -RepoRoot $repoRoot -ProfilePath $resolvedProfile `
        -ProfileJson $profileJson -VMName $VMName -ForceBuild:$ForceBuild -UseCheckpoint:$UseCheckpoint `
        -PushOnly:$PushOnly -SmartBuild:$SmartBuild -Quality $imageQuality
    $ForceBuild = [bool]$buildPlan.ForceBuild
    if ($PushOnly) { $runBuildBoot = $false }
}
$runWait = $Phase -in @('All', 'Wait', 'Inspect', 'Evidence')
$runInspect = $Phase -in @('All', 'Inspect', 'Evidence')
$runEvidence = $Phase -in @('All', 'Evidence')

$startedAt = Get-Date
if (-not $EvidenceRoot) { $EvidenceRoot = Join-Path $repoRoot 'output\vm-acceptance' }
if ([string]::IsNullOrWhiteSpace($EvidenceDir)) {
    $EvidenceDir = Join-Path $EvidenceRoot ("$VMName-" + $startedAt.ToString('yyyyMMdd-HHmmss'))
    $null = New-Item -ItemType Directory -Path $EvidenceDir -Force
}
elseif (-not (Test-Path -LiteralPath $EvidenceDir)) {
    $null = New-Item -ItemType Directory -Path $EvidenceDir -Force
}

$setupShellWatchPath = Join-Path $EvidenceDir 'setup-shell-watch.json'
$script:setupShellWatch = Import-WinMintVmSetupShellWatch -Watch $script:setupShellWatch -Path $setupShellWatchPath

$result = [ordered]@{
    vmName = $VMName
    profile = $resolvedProfile
    acceptanceTier = $acceptanceTier
    phase = $Phase
    startedAt = $startedAt.ToString('o')
    reachable = $false
    firstLogon = $null
    inspect = $null
    verdict = 'unknown'
    plumbingVerdict = 'unknown'
    evidenceVerdict = 'unknown'
    warnings = @()
    reasons = @()
    evidenceDir = $EvidenceDir
}

$runLog = Join-Path $EvidenceDir 'run.log'
$runEvents = Join-Path $EvidenceDir 'run-events.jsonl'
Set-WinMintVmRunLogContext -LogPath $runLog -EventsPath $runEvents -StartedAt $startedAt
if (-not (Test-Path -LiteralPath $runLog)) {
    $null = Initialize-WinMintVmRunLog -LogPath $runLog -Meta ([ordered]@{
            startedAt = $startedAt.ToString('o')
            runId = Split-Path -Leaf $EvidenceDir
            vmName = $VMName
            tier = $acceptanceTier
            profile = $resolvedProfile
            managedRun = [string]$script:managedRun
            hostPid = $PID
            evidenceDir = $EvidenceDir
            eventsFile = $runEvents
            timeBudgetMinutes = $TimeBudgetMinutes
            timeoutMinutes = $TimeoutMinutes
        })
}
else {
    Write-WinMintVmLogLine -Message "Acceptance worker attached (pid=$PID, tier=$acceptanceTier, phase=$Phase)." -LogPath $runLog -Level 'INFO'
    Write-WinMintVmRunEvent -Kind 'worker-start' -Payload @{
        pid = $PID
        tier = $acceptanceTier
        phase = $Phase
    }
}

function Update-WinMintVmManagedRun {
    param(
        [string]$Status,
        [string]$CurrentPhase,
        [int]$ExitCode = -1,
        [string]$ErrorMessage
    )

    if (-not $script:managedRun) { return }
    $payload = [ordered]@{
        status = $Status
        pid = $PID
        profile = $resolvedProfile
        vmName = $VMName
        acceptanceTier = $acceptanceTier
        evidenceDir = $EvidenceDir
        runLog = $runLog
        runEvents = $runEvents
        managedRunPath = $script:managedRunPath
        acceptanceResult = Join-Path $EvidenceDir 'acceptance-result.json'
        startedAt = $startedAt.ToString('o')
        currentPhase = $CurrentPhase
        pollCommand = 'pwsh -NoProfile -File .\tools\vm\Get-WinMintVmAcceptanceStatus.ps1'
        tailCommand = "Get-Content '$runLog' -Wait -Tail 20"
    }
    if ($ExitCode -ge 0) { $payload.exitCode = $ExitCode }
    if ($ErrorMessage) { $payload.error = $ErrorMessage }
    if ($script:observePid -gt 0) { $payload.observePid = $script:observePid }
    if ($script:observeMode) { $payload.observeMode = $script:observeMode }
    if ($buildPlan) {
        $payload.buildStrategy = [string]$buildPlan.Strategy
        $payload.buildEstimatedMinutes = [string]$buildPlan.EstimatedMinutes
    }
    Write-WinMintVmManagedRunState -Path $script:managedRunPath -State $payload
}

function Ensure-WinMintVmObserve {
    if ($NoObserve) { return }
    try {
        $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if (-not $vm -or $vm.State -ne 'Running') { return }
        $obs = Start-WinMintVmObserve -VMName $VMName -AllowReuse
        $script:observePid = [int]$obs.observePid
        $script:observeMode = [string]$obs.observeMode
        $reused = if ($obs.reused) { 'reused' } elseif ($obs.refreshed) { 'refreshed' } else { 'new' }
        Say "VMConnect Basic monitor: pid=$($script:observePid) ($reused)" 'DarkGray'
        Update-WinMintVmManagedRun -Status 'running' -CurrentPhase 'observe'
    }
    catch {
        Say "VMConnect observe skipped: $($_.Exception.Message)" 'Yellow'
    }
}

function Say {
    param([string]$Message, [string]$Color)
    Write-WinMintVmLogLine -Message $Message -LogPath $runLog -Color $Color
    if ($script:managedRun -and $Message -match '===\s*(.+?)\s*===') {
        Update-WinMintVmManagedRun -Status 'running' -CurrentPhase $Matches[1]
    }
}
if (-not (Test-Path -LiteralPath $runLog)) {
    Write-WinMintVmLogLine -Message "Run log: $runLog  (poll: pwsh -NoProfile -File .\tools\vm\Get-WinMintVmAcceptanceStatus.ps1)" -LogPath $runLog -Level 'META'
}
Update-WinMintVmManagedRun -Status 'running' -CurrentPhase 'init'

if ($buildPlan) {
    $planLine = "Build plan: $($buildPlan.Strategy) (~$($buildPlan.EstimatedMinutes) min; isoCached=$($buildPlan.IsoCached); checkpoint=$($buildPlan.CheckpointUsable))"
    Write-WinMintVmLogLine -Message $planLine -LogPath $runLog -Color 'DarkGray' -Level 'INFO'
    Write-WinMintVmRunEvent -Kind 'build-plan' -Payload @{
        strategy = [string]$buildPlan.Strategy
        estimatedMinutes = [string]$buildPlan.EstimatedMinutes
        isoCached = [bool]$buildPlan.IsoCached
        checkpointUsable = [bool]$buildPlan.CheckpointUsable
        agentChanged = [bool]$buildPlan.AgentChanged
        forceBuild = [bool]$buildPlan.ForceBuild
        pushOnly = [bool]$buildPlan.PushOnly
    }
    foreach ($note in @($buildPlan.Notes)) {
        Write-WinMintVmLogLine -Message $note -LogPath $runLog -Color 'Yellow' -Level 'WARN'
    }
}

try {
if ($PushOnly) {
    Say "`n=== Push-only iteration ===" 'Cyan'
    Invoke-WinMintVmAcceptanceCheckpointIteration -VMName $VMName -Credential $cred -RepoRoot $repoRoot `
        -ToolsVmRoot $PSScriptRoot -ProfilePath $resolvedProfile -ImageFingerprint $buildPlan.ImageFingerprint `
        -AgentMode $agentMode -SwitchName $SwitchName -AlwaysPushAgent
    Write-WinMintVmRunEvent -Kind 'milestone' -Payload @{ label = 'checkpoint-push-complete' }
    Ensure-WinMintVmObserve
}
elseif ($runBuildBoot) {
    Say "`n=== Build ===" 'Cyan'
    $buildArgs = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'Build-And-TestVm.ps1'),
        '-ProfilePath', $resolvedProfile, '-VMName', $VMName,
        '-MemoryGB', $MemoryGB, '-DiskGB', $DiskGB, '-CpuCount', $CpuCount)
    if ($NoObserve) { $buildArgs += '-NoConnect' }
    else { $buildArgs += '-ConnectBasic' }
    if ($SwitchName) { $buildArgs += @('-SwitchName', $SwitchName) }
    if ($ForceBuild) { $buildArgs += '-ForceBuild' }
    if ($UseCheckpoint) { $buildArgs += '-UseCheckpoint' }
    $buildArgs += '-AcceptanceRun'
    if ($FullImage) { $buildArgs += '-FullImage' }
    if ($Tier -ne 'Auto') { $buildArgs += @('-Tier', $Tier) }
    if (-not [string]::IsNullOrWhiteSpace($SourceIso)) { $buildArgs += @('-SourceIso', $SourceIso) }
    $buildArgs += @('-AgentMode', $agentMode)
    # Dual-channel Spectre build (777a722): do not wrap through [SUB] pipe capture.
    $buildExit = Invoke-WinMintVmSpectreBuildCommand -LogPath $runLog -RepoRoot $repoRoot -FilePath $pwsh -ArgumentList $buildArgs
    if ($buildExit -ne 0) { throw "Build/boot phase failed with exit code $buildExit." }
    Write-WinMintVmRunEvent -Kind 'milestone' -Payload @{ label = 'build-complete' }
    Ensure-WinMintVmObserve

    if ($Phase -eq 'BuildBoot') {
        $next = @(
            "Build + boot complete. Install and FirstLogon are running in the guest.",
            "Next: pwsh -NoProfile -File tools\vm\Invoke-WinMintVmAcceptance.ps1 -ProfilePath '$ProfilePath' -Phase Wait -EvidenceDir '$EvidenceDir'"
        ) -join ' '
        Write-WinMintVmAcceptanceNextStep -Message $next -RunLog $runLog
        Update-WinMintVmManagedRun -Status 'running' -CurrentPhase 'BuildBoot-complete' -ExitCode 0
        exit 0
    }
}
elseif ($runWait -or $runInspect -or $runEvidence) {
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) { throw "VM '$VMName' not found; run -Phase BuildBoot first or drop -SkipBuild." }
    if ($vm.State -ne 'Running') { throw "VM '$VMName' is not running (state: $($vm.State))." }
    Ensure-WinMintVmObserve
}

$finalState = $null
if ($runWait) {
    Say "`n=== Wait for FirstLogon ===" 'Cyan'
    $waitStartedAt = Get-Date
    $deadline = $waitStartedAt.AddMinutes($TimeoutMinutes)
    $timeBudgetDeadline = $acceptanceStartedAt.AddMinutes($TimeBudgetMinutes)
    $pollSeconds = 5
    $guestSnapshot = $null
    $timeBudgetWarned = $false
    $seenAgentActivity = $false
    $firstLogonActivityAt = $null
    $smokeMinHoldAnnounced = $false
    $firstLogonActivityMilestone = $false
    $setupShellLiveMilestone = $false
    $vmConnectSplashRefresh = $false
    $shellCompleteWaitAnnounced = $false
    $guestPollFailures = 0
    $guestPollFailureWarnEvery = 6
    $guestSnapshotScript = Join-Path $PSScriptRoot 'Get-WinMintVmGuestWaitSnapshot.ps1'
    $checkpointSaved = $false
    $checkpointSaveFinished = $false
    $checkpointSaveAttempts = 0
    $checkpointSaveMaxAttempts = 3
    $autologonLiveProbed = $false
    $wantsLocalAutoLogon = [bool]$profileJson.identity.autoLogon
    $vmMissingPolls = 0
    $firstLogonStallStartedAt = $null
    $firstLogonStallWarned = $false
    while ((Get-Date) -lt $deadline) {
        $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if (-not $vm) {
            $vmMissingPolls++
            if ($vmMissingPolls -ge 2) {
                throw "VM '$VMName' not found during FirstLogon wait (deleted or never created)."
            }
            $vmState = 'Missing'
        }
        else {
            $vmMissingPolls = 0
            $vmState = $vm.State
        }
        $networkConnected = $null
        try {
            $adapter = Get-VMNetworkAdapter -VMName $VMName -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($adapter) { $networkConnected = [bool]$adapter.Connected }
        }
        catch { }

        if (-not $timeBudgetWarned -and (Get-Date) -gt $timeBudgetDeadline) {
            $timeBudgetWarned = $true
            Say "Time budget exceeded (${TimeBudgetMinutes} min target for $acceptanceTier tier); continuing until timeout." 'Yellow'
        }

        $guestPollMs = 0
        $guestPollTimedOut = $false
        $guestPollError = ''
        if ($vmState -ne 'Running') {
            $guestSnapshot = $null
        }
        else {
            if (-not $checkpointSaved -and -not $checkpointSaveFinished -and $buildPlan -and -not $PushOnly) {
                # Retry while Ready (SetupComplete, no agent state.json); give up after N failures.
                try {
                    $postSetupReady = Test-WinMintVmPostSetupCheckpointReady -VmName $VMName -Credential $cred
                    if ($null -eq $postSetupReady) {
                        # Guest not pollable yet — retry next loop.
                    }
                    elseif (-not [bool]$postSetupReady.Ready) {
                        # Window closed or not open yet (Setup incomplete, or agent state already present).
                        if ([bool]$postSetupReady.SetupComplete -and [bool]$postSetupReady.AgentStateExists -and $checkpointSaveAttempts -eq 0) {
                            $checkpointSaveFinished = $true
                            Say 'PostSetup checkpoint skipped: agent state.json already present (pre-agent window missed).' 'Yellow'
                            Write-WinMintVmRunEvent -Kind 'warning' -Payload @{
                                label = 'postsetup-checkpoint-skipped'
                                reason = 'pre-agent-window-missed'
                            }
                        }
                    }
                    else {
                        $agentFp = Get-WinMintVmAgentBuildFingerprint -RepoRoot $repoRoot
                        if (Save-WinMintVmPostSetupCheckpoint -VMName $VMName -Credential $cred `
                                -Fingerprint ([string]$buildPlan.ImageFingerprint) -AgentFingerprint $agentFp -RepoRoot $repoRoot) {
                            $checkpointSaved = $true
                            $checkpointSaveFinished = $true
                            Say "PostSetup checkpoint saved on '$VMName'." 'Green'
                            Write-WinMintVmRunEvent -Kind 'milestone' -Payload @{ label = 'postsetup-checkpoint' }
                        }
                        else {
                            $checkpointSaveAttempts++
                            $reason = "save-returned-false (attempt $checkpointSaveAttempts/$checkpointSaveMaxAttempts)"
                            if ($checkpointSaveAttempts -ge $checkpointSaveMaxAttempts) {
                                $checkpointSaveFinished = $true
                                Say "PostSetup checkpoint gave up after $checkpointSaveMaxAttempts attempts ($reason)." 'Yellow'
                                Write-WinMintVmRunEvent -Kind 'warning' -Payload @{
                                    label = 'postsetup-checkpoint-skipped'
                                    reason = $reason
                                }
                            }
                            else {
                                Say "PostSetup checkpoint retry: $reason" 'Yellow'
                            }
                        }
                    }
                }
                catch {
                    $checkpointSaveAttempts++
                    $reason = [string]$_.Exception.Message
                    if ($checkpointSaveAttempts -ge $checkpointSaveMaxAttempts) {
                        $checkpointSaveFinished = $true
                        Say "PostSetup checkpoint FAILED after $checkpointSaveMaxAttempts attempts: $reason" 'Yellow'
                        Write-WinMintVmRunEvent -Kind 'warning' -Payload @{
                            label = 'postsetup-checkpoint-skipped'
                            reason = $reason
                            attempts = $checkpointSaveAttempts
                        }
                    }
                    else {
                        Say "PostSetup checkpoint error (attempt $checkpointSaveAttempts/$checkpointSaveMaxAttempts): $reason" 'Yellow'
                    }
                }
            }
            $pollResult = Invoke-WinMintVmGuestCommand -VMName $VMName -Credential $cred -FilePath $guestSnapshotScript -TimeoutSeconds 60
            $guestPollMs = $pollResult.DurationMs
            $guestPollTimedOut = [bool]$pollResult.TimedOut
            if ($pollResult.Ok) {
                $guestSnapshot = ConvertTo-WinMintVmGuestWaitSnapshot -Raw $pollResult.Result
                $result.reachable = $true
                if (-not $autologonLiveProbed -and $wantsLocalAutoLogon) {
                    $autologonLiveProbed = $true
                    try {
                        $liveAl = Invoke-WinMintVmGuestCommand -VMName $VMName -Credential $cred -TimeoutSeconds 30 -ScriptBlock {
                            $wl = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction Stop
                            [pscustomobject]@{
                                AutoAdminLogon = [string]$wl.AutoAdminLogon
                                DefaultUserName = [string]$wl.DefaultUserName
                            }
                        }
                        if ($liveAl.Ok -and $null -ne $liveAl.Result) {
                            $al = $liveAl.Result
                            if ($al -is [string]) { $al = $al | ConvertFrom-Json }
                            $wantUser = [string]$profileJson.identity.accountName
                            $gotUser = [string]$al.DefaultUserName
                            $autoOn = [string]$al.AutoAdminLogon -eq '1'
                            if ($autoOn -and $gotUser -and $gotUser -ieq $wantUser) {
                                Say "AutoLogon live OK (DefaultUserName=$gotUser)." 'DarkGray'
                                Write-WinMintVmRunEvent -Kind 'milestone' -Payload @{
                                    label = 'autologon-ok'
                                    DefaultUserName = $gotUser
                                }
                            }
                            else {
                                Say "AutoLogon live mismatch (AutoAdminLogon=$($al.AutoAdminLogon), DefaultUserName=$gotUser, want=$wantUser). Enhanced Session password prompts are unrelated." 'Yellow'
                                Write-WinMintVmRunEvent -Kind 'warning' -Payload @{
                                    label = 'autologon-mismatch'
                                    AutoAdminLogon = [string]$al.AutoAdminLogon
                                    DefaultUserName = $gotUser
                                    wantUser = $wantUser
                                }
                                if ($gotUser -ieq 'defaultuser0' -or [string]::IsNullOrWhiteSpace($gotUser)) {
                                    throw "AutoLogon fail-fast: DefaultUserName='$gotUser' (want '$wantUser') — SetupComplete Autologon stamp did not take; not waiting out TimeoutMinutes."
                                }
                            }
                        }
                    }
                    catch {
                        if ($_.Exception.Message -match 'AutoLogon fail-fast') { throw }
                        Say "AutoLogon live probe skipped: $($_.Exception.Message)" 'DarkGray'
                    }
                }
                if ($guestSnapshot.stateExists -or $guestSnapshot.breadcrumb) {
                    $seenAgentActivity = $true
                    if (-not $firstLogonActivityAt) { $firstLogonActivityAt = Get-Date }
                    if (-not $firstLogonActivityMilestone) {
                        $firstLogonActivityMilestone = $true
                        Write-WinMintVmRunEvent -Kind 'milestone' -Payload @{ label = 'firstlogon-activity' }
                        if (-not $NoObserve -and -not $vmConnectSplashRefresh) {
                            $vmConnectSplashRefresh = $true
                            try {
                                $proc = Open-WinMintVmConnectBasicWatch -VMName $VMName
                                $script:observePid = [int]$proc.Id
                                $script:observeMode = 'basic'
                                Say "VMConnect Basic refreshed for splash (pid=$($proc.Id)) — do not use Hyper-V Manager Enhanced Session." 'Cyan'
                            }
                            catch {
                                Say "VMConnect splash refresh skipped: $($_.Exception.Message)" 'Yellow'
                            }
                        }
                    }
                }
                Register-WinMintVmSetupShellWatchSample -Watch $script:setupShellWatch -GuestSnapshot $guestSnapshot
                if ($script:setupShellWatch.liveUi -and -not $setupShellLiveMilestone) {
                    $setupShellLiveMilestone = $true
                    Say 'SPLASH LIVE — VMConnect should show WinMint Setup fullscreen.' 'Cyan'
                    Write-WinMintVmRunEvent -Kind 'milestone' -Payload @{ label = 'setup-shell-live' }
                }

                # Stall fail-fast: splash/control live but FirstLogon never starts (Shell↔RunOnce deadlock, etc.).
                $hasSplashOrControl = [bool]$script:setupShellWatch.liveUi -or
                    (-not [string]::IsNullOrWhiteSpace([string]$guestSnapshot.setupPhase))
                $hasAgentProgress = [bool]$guestSnapshot.stateExists -or [bool]$guestSnapshot.breadcrumb
                if ($hasSplashOrControl -and -not $hasAgentProgress) {
                    if (-not $firstLogonStallStartedAt) {
                        $firstLogonStallStartedAt = Get-Date
                        Write-WinMintVmRunEvent -Kind 'milestone' -Payload @{
                            label = 'firstlogon-stall-clock'
                            stallMinutes = $StallMinutes
                        }
                    }
                    $stallElapsed = ((Get-Date) - $firstLogonStallStartedAt).TotalMinutes
                    if (-not $firstLogonStallWarned -and $stallElapsed -ge [Math]::Max(1, [Math]::Floor($StallMinutes / 2))) {
                        $firstLogonStallWarned = $true
                        Say ("FirstLogon stall warning: splash/control live for {0:N0}m with no state.json/breadcrumb (fail at {1}m)." -f $stallElapsed, $StallMinutes) 'Yellow'
                        Write-WinMintVmRunEvent -Kind 'warning' -Payload @{
                            label = 'firstlogon-stall-warning'
                            elapsedMinutes = [Math]::Round($stallElapsed, 1)
                            stallMinutes = $StallMinutes
                        }
                    }
                    if ($stallElapsed -ge $StallMinutes) {
                        throw ("FirstLogon stall fail-fast: splash/control live for {0:N0}m without agent progress (StallMinutes={1}). Likely Shell↔RunOnce deadlock or PreLock never handed off — not waiting out TimeoutMinutes={2}." -f $stallElapsed, $StallMinutes, $TimeoutMinutes)
                    }
                }
                else {
                    $firstLogonStallStartedAt = $null
                    $firstLogonStallWarned = $false
                }

                if ($guestSnapshot.stateExists) {
                    $runStatus = [string]$guestSnapshot.runStatus
                    if ($runStatus -in @('ok', 'failed')) {
                        $acceptTerminal = Test-WinMintVmSmokeFirstLogonActivityMinElapsed `
                            -AcceptanceTier $acceptanceTier `
                            -ActivityStartedAt $firstLogonActivityAt
                        if (-not $acceptTerminal) {
                            if (-not $smokeMinHoldAnnounced) {
                                $minSec = Get-WinMintVmSmokeFirstLogonMinElapsedSeconds
                                Say "FirstLogon reached $runStatus; holding smoke poll until ${minSec}s FirstLogon activity elapsed." 'DarkGray'
                                $smokeMinHoldAnnounced = $true
                            }
                        }
                        else {
                            $statePoll = Invoke-WinMintVmGuestCommand -VMName $VMName -Credential $cred -ScriptBlock {
                                Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'WinMint\state.json') -Raw
                            }
                            if (-not $statePoll.Ok) {
                                throw "Guest state fetch failed: $(if ($statePoll.TimedOut) { 'timed out' } else { $statePoll.Error })"
                            }
                            $finalState = $statePoll.Result | ConvertFrom-Json
                            break
                        }
                    }
                }
            }
            else {
                $guestSnapshot = $null
                $guestPollFailures++
                $guestPollError = if ($pollResult.TimedOut) { 'timed out' } elseif ($pollResult.Error) { $pollResult.Error } else { 'unknown poll failure' }
                if ($guestPollFailures -eq 1 -or ($guestPollFailures % $guestPollFailureWarnEvery) -eq 0) {
                    $reason = $guestPollError
                    if (-not $seenAgentActivity -and $reason -match 'credential is invalid') {
                        Say "Waiting for FirstLogon (account not yet ready)..." 'DarkGray'
                    }
                    else {
                        $warn = "Guest poll failed ($reason, ${guestPollMs}ms, attempt $guestPollFailures)"
                        Say $warn 'Yellow'
                        Write-WinMintVmRunEvent -Kind 'warning' -Payload @{
                            label = 'guest-poll-failed'
                            reason = $reason
                            durationMs = $guestPollMs
                            attempt = $guestPollFailures
                            timedOut = [bool]$pollResult.TimedOut
                        }
                    }
                }
            }
        }

        $now = Get-Date
        $elapsed = $now - $waitStartedAt
        $remaining = $deadline - $now
        if ($remaining -lt [TimeSpan]::Zero) { $remaining = [TimeSpan]::Zero }

        $progressLine = Format-WinMintVmWaitProgressLine -Snapshot $guestSnapshot -Elapsed $elapsed -Remaining $remaining -VmState $vmState -NetworkConnected $networkConnected -SeenAgentActivity:$seenAgentActivity -GuestPollTimedOut:$guestPollTimedOut -GuestPollError $guestPollError
        Write-WinMintVmProgressEvent -Snapshot @{
            vmState = [string]$vmState
            guestRunStatus = if ($guestSnapshot) { [string]$guestSnapshot.runStatus } else { '' }
            setupShellPhase = if ($guestSnapshot) { [string]$guestSnapshot.setupPhase } else { '' }
            currentStep = if ($guestSnapshot) { [string]$guestSnapshot.currentStep } else { '' }
            stepsCompleted = if ($guestSnapshot) { [int]$guestSnapshot.completedSteps } else { 0 }
            stepsTotal = if ($guestSnapshot) { [int]$guestSnapshot.totalSteps } else { 0 }
            elapsedSec = [int][math]::Floor($elapsed.TotalSeconds)
            remainingSec = [int][math]::Floor($remaining.TotalSeconds)
            guestPollMs = $guestPollMs
            guestPollTimedOut = [bool]$guestPollTimedOut
        }
        Say $progressLine
        Start-Sleep -Seconds $pollSeconds
    }

    # Plumbing signal when FirstLogon never starts: Local+autoLogon left on defaultuser0.
    $autoLogonHangReason = ''
    $wantsLocalAutoLogon = [bool]$profileJson.identity.autoLogon
    if ($wantsLocalAutoLogon -and (-not $finalState -or -not $result.reachable)) {
        try {
            $autoLogonProbe = Invoke-WinMintVmGuestCommand -VMName $VMName -Credential $cred -TimeoutSeconds 30 -ScriptBlock {
                $paths = @(
                    'C:\ProgramData\WinMint\Logs\SetupComplete_AutoLogon.final.json',
                    'C:\ProgramData\WinMint\Logs\SetupComplete_AutoLogon.json'
                )
                $artifact = $null
                $pathUsed = ''
                foreach ($p in $paths) {
                    if (Test-Path -LiteralPath $p) {
                        $artifact = Get-Content -LiteralPath $p -Raw -ErrorAction Stop | ConvertFrom-Json
                        $pathUsed = $p
                        break
                    }
                }
                $wlUser = ''
                try {
                    $wlUser = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction Stop).DefaultUserName
                }
                catch { }
                [pscustomobject]@{
                    artifactPath = $pathUsed
                    stamped = if ($null -ne $artifact -and $artifact.PSObject.Properties['stamped']) { [bool]$artifact.stamped } else { $false }
                    afterUser = if ($null -ne $artifact -and $artifact.after) { [string]$artifact.after.DefaultUserName } else { '' }
                    winlogonUser = $wlUser
                }
            }
            if ($autoLogonProbe.Ok -and $null -ne $autoLogonProbe.Result) {
                $probe = $autoLogonProbe.Result
                if ($probe -is [string]) { $probe = $probe | ConvertFrom-Json }
                $afterUser = [string]$probe.afterUser
                $wlUser = [string]$probe.winlogonUser
                $stamped = [bool]$probe.stamped
                $missingArtifact = [string]::IsNullOrWhiteSpace([string]$probe.artifactPath)
                if ($missingArtifact -or -not $stamped -or $afterUser -ieq 'defaultuser0' -or $wlUser -ieq 'defaultuser0') {
                    $autoLogonHangReason = 'Winlogon Autologon not restamped off defaultuser0 (SetupComplete Autologon stamp missing or failed).'
                    Say $autoLogonHangReason 'Red'
                    Write-WinMintVmRunEvent -Kind 'warning' -Payload @{
                        label = 'autologon-defaultuser0'
                        artifactPath = [string]$probe.artifactPath
                        stamped = $stamped
                        afterUser = $afterUser
                        winlogonUser = $wlUser
                    }
                    if ($EvidenceDir) {
                        $probePath = Join-Path $EvidenceDir 'SetupComplete_AutoLogon.probe.json'
                        $probe | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $probePath -Encoding UTF8
                    }
                }
            }
            elseif ($wantsLocalAutoLogon) {
                # Guest may still be on FirstLogonAnim as defaultuser0 — profile creds fail PS Direct.
                $autoLogonHangReason = 'Winlogon Autologon not restamped off defaultuser0 (SetupComplete Autologon stamp missing or failed).'
                Say "$autoLogonHangReason (guest AutoLogon probe unreachable: $($autoLogonProbe.Error))" 'Yellow'
            }
        }
        catch {
            Say "AutoLogon hang probe skipped: $($_.Exception.Message)" 'DarkGray'
        }
    }

    if (-not $result.reachable -or -not $finalState) {
        if ($autoLogonHangReason -and $EvidenceDir) {
            # Persist plumbing signal so managed status / evidence show Autologon, not a bare timeout.
            try {
                $hangResult = [ordered]@{
                    vmName = $VMName
                    profile = $ProfilePath
                    acceptanceTier = $acceptanceTier
                    phase = 'Wait'
                    startedAt = $result.startedAt
                    finishedAt = (Get-Date).ToString('o')
                    reachable = [bool]$result.reachable
                    firstLogon = $result.firstLogon
                    reasons = @("Plumbing check failed: $autoLogonHangReason.")
                    warnings = @()
                    acceptanceMode = 'vm'
                }
                $hangSignals = @(
                    New-WinMintAcceptanceSignalResult -Id 'vm.autologon' -Ok $false -Severity plumbing -Message $autoLogonHangReason
                )
                $hangResult = Complete-WinMintAcceptanceResult -Result $hangResult -Signals $hangSignals -AcceptanceTier $acceptanceTier
                Write-WinMintAcceptanceResult -Result $hangResult -Path (Join-Path $EvidenceDir 'acceptance-result.json')
            }
            catch {
                Say "Failed to write Autologon hang acceptance-result: $($_.Exception.Message)" 'DarkGray'
            }
            throw $autoLogonHangReason
        }
        if (-not $result.reachable) {
            throw "Guest '$VMName' was not reachable over PowerShell Direct within $TimeoutMinutes min (install/autologon did not complete)."
        }
        throw "FirstLogon did not reach a terminal run.status within $TimeoutMinutes min."
    }

    Save-WinMintVmSetupShellWatch -Watch $script:setupShellWatch -Path $setupShellWatchPath

    $result.firstLogon = Get-WinMintVmAgentRunSnapshot -Run $finalState.run
    if ($result.firstLogon.status -eq 'ok') {
        Say "FirstLogon completed (exitCode $($result.firstLogon.exitCode))." 'Green'
        Write-WinMintVmRunEvent -Kind 'milestone' -Payload @{ label = 'firstlogon-complete'; status = 'ok' }
    }
    else {
        $result.reasons += "FirstLogon failed: $($result.firstLogon.failedSteps -join ', ')."
        Say "FirstLogon failed: $($result.firstLogon.failedSteps -join ', ')." 'Red'
        Write-WinMintVmRunEvent -Kind 'milestone' -Payload @{ label = 'firstlogon-complete'; status = 'failed' }
    }

    if ($Phase -eq 'Wait') {
        $next = "Next: pwsh -NoProfile -File tools\vm\Invoke-WinMintVmAcceptance.ps1 -ProfilePath '$ProfilePath' -Phase Inspect -EvidenceDir '$EvidenceDir'"
        Write-WinMintVmAcceptanceNextStep -Message $next -RunLog $runLog
        exit 0
    }
}
elseif ($runInspect -or $runEvidence) {
    try {
        $statePoll = Invoke-WinMintVmGuestCommand -VMName $VMName -Credential $cred -ScriptBlock {
            $p = Join-Path $env:LOCALAPPDATA 'WinMint\state.json'
            if (Test-Path -LiteralPath $p) { Get-Content -LiteralPath $p -Raw } else { '' }
        }
        if (-not $statePoll.Ok) {
            throw "Guest state fetch failed: $(if ($statePoll.TimedOut) { 'timed out' } else { $statePoll.Error })"
        }
        $stateText = [string]$statePoll.Result
        $result.reachable = $true
        if (-not [string]::IsNullOrWhiteSpace($stateText)) {
            $stateObj = $stateText | ConvertFrom-Json
            $result.firstLogon = Get-WinMintVmAgentRunSnapshot -Run $stateObj.run
        }
    }
    catch {
        throw "Guest '$VMName' is not reachable over PowerShell Direct; run -Phase Wait first."
    }
}

$inspectOk = $false
if ($runInspect) {
    Say "`n=== Inspect ===" 'Cyan'
    try {
        $inspectLines = [System.Collections.Generic.List[string]]::new()
        $inspectExit = Invoke-WinMintVmLoggedCommand -LogPath $runLog -Command {
            $expectDevDrive = $false
            if ($profileJson.target -and $profileJson.target.PSObject.Properties['devDrive'] -and $profileJson.target.devDrive) {
                $ddMode = [string]$profileJson.target.devDrive.mode
                $expectDevDrive = ($ddMode -in @('Partition', 'VhdDynamic'))
            }
            $inspectParams = @{
                VMName           = $VMName
                GuestUser        = $guestUser
                GuestPassword    = $guestPassword
                AcceptanceTier   = $acceptanceTier
                WslDistros       = @($profileJson.development.wsl.distros)
                ExpectDevDrive   = $expectDevDrive
            }
            & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Invoke-WinMintGuestPesterAcceptance.ps1') @inspectParams |
                ForEach-Object {
                    $line = [string]$_
                    $inspectLines.Add($line) | Out-Null
                    $line
                }
        }
        if ($inspectExit -ne 0) { throw "inspector exited $inspectExit" }
        $jsonStart = -1
        for ($i = 0; $i -lt $inspectLines.Count; $i++) {
            if ([string]$inspectLines[$i] -match '^\s*\{') {
                $jsonStart = $i
                break
            }
        }
        if ($jsonStart -lt 0) { throw 'inspector did not emit JSON payload' }
        $inspectPayload = (($inspectLines[$jsonStart..($inspectLines.Count - 1)] -join "`n") | ConvertFrom-Json)
        $result.inspect = if ($inspectPayload.inspect) { $inspectPayload.inspect } else { $inspectPayload }
        $inspectOk = [bool]$inspectPayload.pester.passed
        if (-not $inspectOk -and $inspectPayload.pester) {
            foreach ($failure in @($inspectPayload.pester.failures)) {
                $result.reasons += "Guest inspect failed: $failure"
            }
        }
    }
    catch {
        $result.reasons += "Inspect could not gather guest signals: $($_.Exception.Message)"
        Say "Inspect failed: $($_.Exception.Message)" 'Red'
    }

    if ($Phase -eq 'Inspect') {
        $next = "Next: pwsh -NoProfile -File tools\vm\Invoke-WinMintVmAcceptance.ps1 -ProfilePath '$ProfilePath' -Phase Evidence -EvidenceDir '$EvidenceDir'"
        Write-WinMintVmAcceptanceNextStep -Message $next -RunLog $runLog
        exit 0
    }
}

if ($runEvidence) {
    Say "`n=== Evidence ===" 'Cyan'
    try {
        $session = New-PSSession -VMName $VMName -Credential $cred -ErrorAction Stop
        try {
            Invoke-Command -Session $session -ScriptBlock {
                $dst = 'C:\Windows\Temp\winmint-acceptance-pull'
                Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction SilentlyContinue
                $null = New-Item -ItemType Directory -Path $dst -Force
                Copy-Item -LiteralPath 'C:\ProgramData\WinMint\Logs' -Destination (Join-Path $dst 'ProgramData-Logs') -Recurse -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath "$env:LOCALAPPDATA\WinMint") {
                    Copy-Item -LiteralPath "$env:LOCALAPPDATA\WinMint" -Destination (Join-Path $dst 'LocalAppData-WinMint') -Recurse -Force -ErrorAction SilentlyContinue
                }
                # Durable Terminal + taskbar layout evidence (not under LocalAppData\WinMint).
                $termSrc = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
                if (Test-Path -LiteralPath $termSrc -PathType Leaf) {
                    $termDst = Join-Path $dst 'LocalAppData-Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
                    $null = New-Item -ItemType Directory -Path $termDst -Force
                    Copy-Item -LiteralPath $termSrc -Destination (Join-Path $termDst 'settings.json') -Force
                }
                $shellSrc = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Shell\LayoutModification.xml'
                if (Test-Path -LiteralPath $shellSrc -PathType Leaf) {
                    $shellDst = Join-Path $dst 'LocalAppData-Shell'
                    $null = New-Item -ItemType Directory -Path $shellDst -Force
                    Copy-Item -LiteralPath $shellSrc -Destination (Join-Path $shellDst 'LayoutModification.xml') -Force
                }
                $pantherDir = Join-Path $dst 'Panther'
                $null = New-Item -ItemType Directory -Path $pantherDir -Force
                foreach ($name in @('setupact.log', 'setupcomplete.log', 'setuperr.log', 'unattend.xml')) {
                    $src = Join-Path 'C:\Windows\Panther' $name
                    if (Test-Path -LiteralPath $src) {
                        Copy-Item -LiteralPath $src -Destination $pantherDir -Force -ErrorAction SilentlyContinue
                    }
                }
                $guestTemp = Join-Path $dst 'guest-temp'
                $null = New-Item -ItemType Directory -Path $guestTemp -Force
                foreach ($shot in @(
                        'C:\Windows\Temp\winmint-oobe-capture.png'
                        'C:\Windows\Temp\winmint-setup-shell-guest.png'
                    )) {
                    if (Test-Path -LiteralPath $shot -PathType Leaf) {
                        Copy-Item -LiteralPath $shot -Destination $guestTemp -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            Copy-Item -FromSession $session -Path 'C:\Windows\Temp\winmint-acceptance-pull\*' -Destination $EvidenceDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        finally { Remove-PSSession $session -ErrorAction SilentlyContinue }
    }
    catch {
        $result.reasons += "Could not pull guest logs: $($_.Exception.Message)"
        Say "Guest log pull failed (non-fatal): $($_.Exception.Message)" 'Yellow'
    }

    $setupErrLog = Get-ChildItem -LiteralPath $EvidenceDir -Recurse -File -Filter 'setuperr.log' -ErrorAction SilentlyContinue |
        Sort-Object FullName | Select-Object -First 1
    if ($setupErrLog -and (Get-Item -LiteralPath $setupErrLog.FullName).Length -gt 0) {
        $result.warnings += "Panther setuperr.log is non-empty (see evidence Panther/setuperr.log)."
    }

    $manifest = Get-ChildItem -LiteralPath (Join-Path $repoRoot 'output') -Filter 'WinMint-BuildManifest.json' -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $manifest) {
        $manifest = Get-ChildItem -LiteralPath (Join-Path $repoRoot 'output') -Filter 'BuildManifest.json' -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if ($manifest) {
        $hostDir = Join-Path $EvidenceDir 'host-build'
        $null = New-Item -ItemType Directory -Path $hostDir -Force
        foreach ($pair in @(
                @{ Src = 'WinMint-BuildManifest.json'; Dst = 'BuildManifest.json' }
                @{ Src = 'WinMint-BuildDelta.json'; Dst = 'BuildDelta.json' }
                @{ Src = 'WinMint-BuildProfile.json'; Dst = 'BuildProfile.json' }
                @{ Src = 'BuildManifest.json'; Dst = 'BuildManifest.json' }
                @{ Src = 'BuildDelta.json'; Dst = 'BuildDelta.json' }
                @{ Src = 'BuildProfile.json'; Dst = 'BuildProfile.json' }
            )) {
            $src = Join-Path $manifest.Directory.FullName $pair.Src
            if (Test-Path -LiteralPath $src) {
                Copy-Item -LiteralPath $src -Destination (Join-Path $hostDir $pair.Dst) -Force
            }
        }
        $offlineDrift = Join-Path $manifest.Directory.FullName 'offline-removal-drift.json'
        if (Test-Path -LiteralPath $offlineDrift) {
            Copy-Item -LiteralPath $offlineDrift -Destination (Join-Path $hostDir 'offline-removal-drift.json') -Force
        }
    }

    if (-not $result.firstLogon) {
        $result.reasons += 'Evidence phase ran without FirstLogon state; run -Phase Wait first.'
    }

    $warnSteps = @()
    if ($result.firstLogon) {
        $warnSteps = @((Get-WinMintVmAgentRunSnapshot -Run $result.firstLogon).warningSteps) | Where-Object { $_ }
    }
    $warned = @($warnSteps).Count -gt 0
    if ($warned) {
        $result.warnings += "Advisory FirstLogon step(s): $($warnSteps -join ', ')."
    }

    $signalPlumbingFail = [System.Collections.Generic.List[string]]::new()
    $signalEvidenceFail = [System.Collections.Generic.List[string]]::new()
    Save-WinMintVmSetupShellWatch -Watch $script:setupShellWatch -Path $setupShellWatchPath
    $setupShellEvidence = Test-WinMintSetupShellAcceptanceEvidence -Watch $script:setupShellWatch -EvidenceDir $EvidenceDir -AcceptanceTier $acceptanceTier
    $result.setupShell = [ordered]@{}
    foreach ($entry in $setupShellEvidence.meta.GetEnumerator()) {
        $result.setupShell[$entry.Key] = $entry.Value
    }
    $result.setupShell.plumbingOk = [bool]$setupShellEvidence.plumbingOk
    $result.setupShell.evidenceOk = [bool]$setupShellEvidence.evidenceOk
    foreach ($f in $setupShellEvidence.plumbingFailures) {
        $signalPlumbingFail.Add("Setup shell: $f") | Out-Null
    }
    foreach ($f in $setupShellEvidence.evidenceFailures) {
        $signalEvidenceFail.Add("Setup shell: $f") | Out-Null
    }

    $setupCompleteLogs = Test-WinMintVmSetupCompleteLogEvidence -EvidenceDir $EvidenceDir
    $result.setupComplete = [ordered]@{
        errorLineCount = [int]$setupCompleteLogs.errorLineCount
        warningLineCount = [int]$setupCompleteLogs.warningLineCount
        plumbingOk = [bool]$setupCompleteLogs.plumbingOk
    }
    foreach ($f in @($setupCompleteLogs.plumbingFailures)) {
        $signalPlumbingFail.Add([string]$f) | Out-Null
    }
    foreach ($w in @($setupCompleteLogs.softWarnings)) {
        $result.warnings += [string]$w
    }
    if ($result.reachable -and $result.firstLogon -and $setupCompleteLogs.errorLineCount -eq 0) {
        # Healthy runs may leave no errors file. Prefer positive SetupComplete.log proof
        # over requiring the errors file to exist.
        $setupCompleteLogPath = Join-Path $EvidenceDir 'ProgramData-Logs\SetupComplete.log'
        if (-not (Test-Path -LiteralPath $setupCompleteLogPath -PathType Leaf)) {
            $signalPlumbingFail.Add('SetupComplete.log missing after FirstLogon (SetupComplete may not have run)') | Out-Null
        }
    }

    if (-not $inspectOk -and $runInspect) {
        $signalEvidenceFail.Add('guest inspection failed; desktop signals unverified') | Out-Null
    }
    elseif ($result.inspect) {
        $insp = $result.inspect
        $wslDistros = @($profileJson.development.wsl.distros)
        if ($wslDistros -contains 'Ubuntu' -and -not $insp.UbuntuProfileExists) {
            $signalEvidenceFail.Add('Windows Terminal Ubuntu profile missing') | Out-Null
        }
        if ($wslDistros -contains 'NixOS-WSL' -and -not $insp.NixProfileExists) {
            $signalEvidenceFail.Add('Windows Terminal NixOS profile missing') | Out-Null
        }
        if (-not $insp.AccountPictureBmpExists) {
            $signalEvidenceFail.Add('Account picture bitmap missing') | Out-Null
        }
    }

    # Terminal hard-replace + Start/taskbar pins are Smoke plumbing (evidence-only
    # would still green-light Smoke). Prefer pulled evidence; inspect is fallback.
    if ($result.reachable -and $result.firstLogon) {
        $shellDesktop = Test-WinMintVmShellDesktopEvidence -BuildProfile $profileJson -EvidenceDir $EvidenceDir -Inspect $result.inspect
        $result.shellDesktop = [ordered]@{
            plumbingOk = [bool]$shellDesktop.plumbingOk
            expectedTerminalProfiles = @($shellDesktop.meta.expectedTerminalProfiles)
            observedTerminalProfiles = @($shellDesktop.meta.observedTerminalProfiles)
            wslSkip = [bool]$shellDesktop.meta.wslSkip
            shellPinsPresent = [bool]$shellDesktop.meta.shellPinsPresent
        }
        foreach ($f in @($shellDesktop.plumbingFailures)) {
            $signalPlumbingFail.Add([string]$f) | Out-Null
        }
        foreach ($w in @($shellDesktop.warnings)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$w)) {
                $result.warnings += "Shell desktop: $w"
            }
        }
    }

    $dmaRestoreReportPath = Join-Path $EvidenceDir 'ProgramData-Logs\FirstLogon_RegionalRestore.json'
    if (Test-Path -LiteralPath $dmaRestoreReportPath) {
        try {
            $dmaRestoreReport = Get-Content -LiteralPath $dmaRestoreReportPath -Raw | ConvertFrom-Json
            $result.dmaRegionalRestore = [ordered]@{
                enabled = [bool]$dmaRestoreReport.enabled
                compliant = [bool]$dmaRestoreReport.compliant
                errors = @($dmaRestoreReport.errors)
                localeName = if ($dmaRestoreReport.observed) { [string]$dmaRestoreReport.observed.localeName } else { '' }
                culture = if ($dmaRestoreReport.observed) { [string]$dmaRestoreReport.observed.culture } else { '' }
                reportPath = $dmaRestoreReportPath
            }
            if ([bool]$dmaRestoreReport.enabled -and -not [bool]$dmaRestoreReport.compliant) {
                $dmaErr = (@($dmaRestoreReport.errors) -join ' | ')
                if ([string]::IsNullOrWhiteSpace($dmaErr)) { $dmaErr = 'see FirstLogon_RegionalRestore.json' }
                $signalPlumbingFail.Add("DMA regional restore non-compliant: $dmaErr") | Out-Null
            }
        }
        catch {
            $signalPlumbingFail.Add("DMA regional restore report unreadable: $($_.Exception.Message)") | Out-Null
        }
    }
    elseif ($result.reachable -and $result.firstLogon) {
        $signalPlumbingFail.Add('DMA regional restore report missing (FirstLogon_RegionalRestore.json)') | Out-Null
    }

    if ($result.reachable -and $result.firstLogon) {
        $agentState = Get-WinMintVmPulledAgentState -EvidenceDir $EvidenceDir
        $stepCheck = Test-WinMintVmFirstLogonRequiredSteps -AgentState $agentState
        $result.firstLogonSteps = [ordered]@{
            plumbingOk = [bool]$stepCheck.plumbingOk
            checkedKeys = @($stepCheck.meta.checkedKeys)
            observed = $stepCheck.meta.observed
        }
        foreach ($f in @($stepCheck.plumbingFailures)) {
            $signalPlumbingFail.Add("FirstLogon steps: $f") | Out-Null
        }

        $diskMode = if ($profileJson.target) { [string]$profileJson.target.diskMode } else { '' }
        $devDriveMode = 'Off'
        if ($profileJson.target -and $profileJson.target.PSObject.Properties['devDrive'] -and $profileJson.target.devDrive) {
            $devDriveMode = [string]$profileJson.target.devDrive.mode
            if ([string]::IsNullOrWhiteSpace($devDriveMode)) { $devDriveMode = 'Off' }
        }
        $diskProbe = $null
        try {
            $probeScript = Get-WinMintVmDiskLayoutProbeScript
            $probePoll = Invoke-WinMintVmGuestCommand -VMName $VMName -Credential $cred -ScriptBlock ([scriptblock]::Create($probeScript)) -TimeoutSeconds 60
            if ($probePoll.Ok -and -not [string]::IsNullOrWhiteSpace([string]$probePoll.Result)) {
                $diskProbe = [string]$probePoll.Result | ConvertFrom-Json
            }
            else {
                $result.warnings += "Disk layout probe skipped: $(if ($probePoll.TimedOut) { 'timed out' } else { $probePoll.Error })"
            }
        }
        catch {
            $result.warnings += "Disk layout probe failed: $($_.Exception.Message)"
        }
        $diskEvidence = Test-WinMintVmDiskLayoutEvidence -Probe $diskProbe -DiskMode $diskMode -DevDriveMode $devDriveMode
        $result.diskLayout = [ordered]@{
            plumbingOk   = [bool]$diskEvidence.plumbingOk
            diskMode     = $diskMode
            devDriveMode = $devDriveMode
            probe        = $diskProbe
        }
        foreach ($f in @($diskEvidence.plumbingFailures)) {
            $signalPlumbingFail.Add("Disk layout: $f") | Out-Null
        }
        foreach ($w in @($diskEvidence.softWarnings)) {
            $result.warnings += "Disk layout: $w"
        }
    }

    $removalDrift = $null
    if ($result.reachable) {
        try {
            $keepBlock = Get-WinMintProfileKeepBlock -BuildProfile $profileJson
            $expectedPrefixes = @(Get-WinMintProfileAppxRemovalPrefixFromKeep -Keep $keepBlock)
            $driftScript = Join-Path $PSScriptRoot 'Test-WinMintGuestRemovalDrift.ps1'
            $driftConfigJson = (@{
                ExpectedPrefixes = $expectedPrefixes
                RehydratedPrefixes = @('Microsoft.Edge.GameAssist')
                ExpectedRemovedCapabilities = @('Media.WindowsMediaPlayer', 'Microsoft.Wallpapers.Extended')
                AsJson = $true
            } | ConvertTo-Json -Compress -Depth 5)
            $driftPoll = Invoke-WinMintVmGuestCommand -VMName $VMName -Credential $cred -FilePath $driftScript `
                -TimeoutSeconds 120 -ArgumentList $driftConfigJson
            if (-not $driftPoll.Ok) {
                throw $(if ($driftPoll.TimedOut) { 'removal drift check timed out' } else { $driftPoll.Error })
            }
            $driftRaw = $driftPoll.Result
            if ($driftRaw -is [System.Collections.IEnumerable] -and $driftRaw -isnot [string]) {
                $driftRaw = ($driftRaw | ForEach-Object { [string]$_ }) -join "`n"
            }
            $removalDrift = if ($driftRaw -is [string]) { $driftRaw | ConvertFrom-Json } else { $driftRaw }
            $result.removalDrift = [ordered]@{
                ok                = [bool]$removalDrift.ok
                driftInstalled    = @($removalDrift.driftInstalled)
                driftProvisioned  = @($removalDrift.driftProvisioned)
                systemRemnants    = @($removalDrift.systemRemnants)
                rehydratedPresent = @($removalDrift.rehydratedPresent)
                capabilityDrift   = @($removalDrift.capabilityDrift)
            }
            foreach ($hit in @($removalDrift.driftInstalled | Where-Object { $_ })) {
                $signalPlumbingFail.Add("AppX drift installed: $($hit.prefix) ($($hit.name))") | Out-Null
            }
            foreach ($hit in @($removalDrift.driftProvisioned | Where-Object { $_ })) {
                $signalPlumbingFail.Add("AppX drift provisioned: $($hit.prefix) ($($hit.packageName))") | Out-Null
            }
            foreach ($hit in @($removalDrift.capabilityDrift | Where-Object { $_ })) {
                $signalPlumbingFail.Add("Capability drift: $($hit.token) still installed ($($hit.name))") | Out-Null
            }
        }
        catch {
            $signalPlumbingFail.Add("Removal drift check failed: $($_.Exception.Message)") | Out-Null
            $result.removalDrift = [ordered]@{ ok = $false; error = [string]$_.Exception.Message }
        }
    }

    $result.liveInstallAudit = $null
    if ($acceptanceTier -eq 'Full') {
        $auditPath = Get-ChildItem -LiteralPath $EvidenceDir -Recurse -File -Filter 'LiveInstallAudit.json' -ErrorAction SilentlyContinue |
            Sort-Object FullName | Select-Object -First 1
        if (-not $auditPath) {
            $signalEvidenceFail.Add('LiveInstallAudit.json was not pulled into evidence (full tier requires live install audit).') | Out-Null
            $result.liveInstallAudit = [ordered]@{ ok = $false; error = 'report missing' }
        }
        else {
            try {
                $auditReport = Get-Content -LiteralPath $auditPath.FullName -Raw | ConvertFrom-Json
                $errorCount = [int]$auditReport.summary.error
                $warningCount = [int]$auditReport.summary.warning
                $auditOk = ($errorCount -eq 0)
                $result.liveInstallAudit = [ordered]@{
                    ok = $auditOk
                    path = $auditPath.FullName
                    errorCount = $errorCount
                    warningCount = $warningCount
                    summary = $auditReport.summary
                }
                if (-not $auditOk) {
                    $signalEvidenceFail.Add("Live install audit reported $errorCount error(s) (see LiveInstallAudit.json).") | Out-Null
                }
                elseif ($warningCount -gt 0) {
                    $result.warnings += "Live install audit reported $warningCount warning(s) (non-fatal)."
                }
            }
            catch {
                $signalEvidenceFail.Add("Live install audit report could not be parsed: $($_.Exception.Message)") | Out-Null
                $result.liveInstallAudit = [ordered]@{ ok = $false; error = [string]$_.Exception.Message }
            }
        }
    }

    # Freeze reasons/warnings only after every plumbing/evidence collector has run
    # (drift + live audit used to append failures after reasons were already written).
    foreach ($s in $signalPlumbingFail) { $result.reasons += "Plumbing check failed: $s." }
    foreach ($s in $signalEvidenceFail) { $result.warnings += "Evidence check failed: $s." }

    $vmSignals = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $signalPlumbingFail) {
        $vmSignals.Add((New-WinMintAcceptanceSignalResult -Id 'vm.plumbing' -Ok $false -Severity plumbing -Message ([string]$f))) | Out-Null
    }
    foreach ($f in $signalEvidenceFail) {
        $vmSignals.Add((New-WinMintAcceptanceSignalResult -Id 'vm.evidence' -Ok $false -Severity evidence -Message ([string]$f))) | Out-Null
    }
    $result.acceptanceMode = 'vm'
    $result = Complete-WinMintAcceptanceResult -Result $result -Signals @($vmSignals) -AcceptanceTier $acceptanceTier
    $plumbingPass = ($result.plumbingVerdict -eq 'pass')
    $evidencePass = ($result.evidenceVerdict -eq 'pass')
    $passed = ($result.verdict -eq 'pass')
    if (-not $evidencePass -and $plumbingPass -and $acceptanceTier -eq 'Smoke') {
        $result.reasons += 'Smoke plumbing passed; evidence checks had warnings (see warnings).'
    }
    Write-WinMintAcceptanceResult -Result $result -Path (Join-Path $EvidenceDir 'acceptance-result.json')

    Say "`n=== Plumbing verdict: $($result.plumbingVerdict.ToUpper()) | Evidence verdict: $($result.evidenceVerdict.ToUpper()) ===" ($plumbingPass ? 'Green' : 'Red')
    Say "=== Overall verdict: $($result.verdict.ToUpper()) ($acceptanceTier tier) ===" ($passed ? 'Green' : 'Red')
    foreach ($r in $result.reasons) { Say "  - $r" }
    foreach ($w in $result.warnings) { Say "  ! $w" 'Yellow' }
    $finishedAt = Get-Date
    $duration = $finishedAt - $acceptanceStartedAt
    Say "Duration: $('{0:mm\:ss}' -f $duration) | Evidence: $EvidenceDir"
    Write-WinMintVmRunEvent -Kind 'verdict' -Payload @{
        verdict = [string]$result.verdict
        plumbingVerdict = [string]$result.plumbingVerdict
        evidenceVerdict = [string]$result.evidenceVerdict
        acceptanceTier = $acceptanceTier
        durationSec = [int][math]::Floor($duration.TotalSeconds)
        reasonCount = @($result.reasons).Count
        warningCount = @($result.warnings).Count
    }
    Update-WinMintVmManagedRun -Status $(if ($passed) { 'passed' } else { 'failed' }) -CurrentPhase 'Complete' -ExitCode $(if ($passed) { 0 } else { 1 })
    if (-not $passed) { exit 1 }
}
}
catch {
    Write-WinMintVmRunEvent -Kind 'error' -Payload @{ message = $_.Exception.Message }
    Update-WinMintVmManagedRun -Status 'failed' -CurrentPhase 'error' -ExitCode 1 -ErrorMessage $_.Exception.Message
    throw
}
