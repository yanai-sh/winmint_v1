#Requires -Version 7.6
# Dot-sourced by WinMint-VmConsole.ps1 — not a standalone entrypoint.
function Test-WinMintVmGuestPsDirectTimedOut {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    return $Message -match '(?i)operation has timed out|operationtimeout|deadline exceeded|the operation timed out|wsman.*timed\s*out'
}

function Test-WinMintVmGuestPsDirectRetryable {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    return $Message -match '(?i)remote session might have ended|vmicvmsession|connection.*broken|broken session|starting the vmconnect|cannot connect to the virtual machine'
}

function Invoke-WinMintVmGuestCommand {
    [CmdletBinding(DefaultParameterSetName = 'ScriptBlock')]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(ParameterSetName = 'ScriptBlock', Mandatory)][scriptblock]$ScriptBlock,
        [Parameter(ParameterSetName = 'FilePath', Mandatory)][string]$FilePath,
        [int]$TimeoutSeconds = 45,
        $ArgumentList
    )

    $started = Get-Date
    $outcome = [ordered]@{
        Ok = $false
        Result = $null
        TimedOut = $false
        Error = ''
        DurationMs = 0
    }

    $scriptContent = $null
    if ($PSCmdlet.ParameterSetName -eq 'FilePath') {
        if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
            $outcome.Error = "Guest script not found on host: $FilePath"
            $outcome.DurationMs = [int][math]::Round(((Get-Date) - $started).TotalMilliseconds)
            return [pscustomobject]$outcome
        }
        $scriptContent = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8
    }

    $maxAttempts = 2
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            if ($PSCmdlet.ParameterSetName -eq 'FilePath') {
                $outcome.Result = Invoke-Command -VMName $VMName -Credential $Credential `
                    -ErrorAction Stop -ScriptBlock {
                    param($Content, $ArgList)
                    $guestPath = Join-Path $env:TEMP ("winmint-harness-{0}.ps1" -f [Guid]::NewGuid().ToString('n'))
                    try {
                        [IO.File]::WriteAllText($guestPath, $Content)
                        $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
                        if (-not (Test-Path -LiteralPath $pwsh)) {
                            throw "WinMint guest harness requires bundled PowerShell 7 at $pwsh."
                        }
                        $invokeArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $guestPath)
                        $configJson = if ($ArgList -is [string]) { $ArgList } elseif ($null -ne $ArgList -and @($ArgList).Count -eq 1 -and $ArgList[0] -is [string]) { [string]$ArgList[0] } else { $null }
                        if ($configJson -and $configJson.StartsWith('{')) {
                            $cfgPath = "$guestPath.json"
                            [IO.File]::WriteAllText($cfgPath, $configJson)
                            return & $pwsh @invokeArgs -ConfigPath $cfgPath
                        }
                        if ($null -ne $ArgList -and @($ArgList).Count -gt 0) {
                            return & $pwsh @invokeArgs @ArgList
                        }
                        return & $pwsh @invokeArgs
                    }
                    finally {
                        Remove-Item -LiteralPath $guestPath -Force -ErrorAction SilentlyContinue
                    }
                } -ArgumentList @($scriptContent, $ArgumentList)
            }
            else {
                $invokeParams = @{
                    VMName = $VMName
                    Credential = $Credential
                    ScriptBlock = $ScriptBlock
                    ErrorAction = 'Stop'
                }
                if ($null -ne $ArgumentList) { $invokeParams['ArgumentList'] = $ArgumentList }
                $outcome.Result = Invoke-Command @invokeParams
            }
            $outcome.Ok = $true
            break
        }
        catch {
            $msg = $_.Exception.Message
            if (Test-WinMintVmGuestPsDirectTimedOut -Message $msg) {
                $outcome.TimedOut = $true
                $outcome.Error = $msg
                break
            }
            if ($attempt -lt $maxAttempts -and (Test-WinMintVmGuestPsDirectRetryable -Message $msg)) {
                Start-Sleep -Seconds 5
                continue
            }
            $outcome.Error = $msg
            break
        }
    }

    $outcome.DurationMs = [int][math]::Round(((Get-Date) - $started).TotalMilliseconds)
    return [pscustomobject]$outcome
}

function ConvertTo-WinMintVmGuestWaitSnapshot {
    param($Raw)

    if ($null -eq $Raw) { return $null }
    if ($Raw -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
        return $Raw | ConvertFrom-Json
    }
    return $Raw
}

function Get-WinMintVmAgentRunSnapshot {
    param($Run)

    $snapshot = [ordered]@{
        status = ''
        exitCode = 0
        completedAt = ''
        failedSteps = @()
        warningSteps = @()
        rebootPending = $false
    }
    if (-not $Run) { return $snapshot }

    if ($Run.PSObject.Properties['status']) { $snapshot.status = [string]$Run.status }
    if ($Run.PSObject.Properties['exitCode']) { $snapshot.exitCode = [int]$Run.exitCode }
    if ($Run.PSObject.Properties['completedAt']) { $snapshot.completedAt = [string]$Run.completedAt }
    if ($Run.PSObject.Properties['failedSteps'] -and $null -ne $Run.failedSteps) {
        $snapshot.failedSteps = @($Run.failedSteps)
    }
    if ($Run.PSObject.Properties['warningSteps'] -and $null -ne $Run.warningSteps) {
        $snapshot.warningSteps = @($Run.warningSteps)
    }
    if ($Run.PSObject.Properties['rebootPending']) { $snapshot.rebootPending = [bool]$Run.rebootPending }
    return $snapshot
}

function Format-WinMintVmWaitProgressLine {
    param(
        $Snapshot,
        [TimeSpan]$Elapsed,
        [TimeSpan]$Remaining,
        [string]$VmState,
        $NetworkConnected,
        [switch]$SeenAgentActivity,
        [switch]$GuestPollTimedOut,
        [string]$GuestPollError = ''
    )

    $parts = @(
        ('[{0} elapsed, {1} left]' -f (Format-WinMintVmDuration $Elapsed), (Format-WinMintVmDuration $Remaining))
        "vm=$VmState"
    )
    if ($VmState -in @('Stopping', 'Off')) {
        $parts += 'guest=rebooting'
    }
    elseif ($GuestPollTimedOut) {
        $parts += 'guest=poll-timeout'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($GuestPollError)) {
        $hint = ($GuestPollError -replace '\s+', ' ').Trim()
        if ($hint.Length -gt 72) { $hint = $hint.Substring(0, 69) + '...' }
        $parts += "guest=poll-failed ($hint)"
    }
    elseif (-not $Snapshot) {
        if ($SeenAgentActivity) { $parts += 'guest=poll-unreachable' }
        else { $parts += 'guest=waiting (install/OOBE/autologon)' }
    }
    elseif (-not $Snapshot.stateExists) {
        if ($SeenAgentActivity) { $parts += 'firstlogon=active-no-state' }
        elseif ($Snapshot.breadcrumb) { $parts += 'firstlogon=starting (no agent state yet)' }
        elseif ($Snapshot.setupPhase -in @('running', 'finishing') -or -not [string]::IsNullOrWhiteSpace([string]$Snapshot.setupShellTaskLabel)) {
            # Splash/control can be live before state.json exists — do not say agent=not started.
            $parts += 'firstlogon=under-splash'
            if ($Snapshot.setupPhase) { $parts += "shell=$($Snapshot.setupPhase)" }
            if ($Snapshot.setupShellTaskLabel) { $parts += "task=$($Snapshot.setupShellTaskLabel)" }
        }
        else { $parts += 'agent=not started' }
    }
    else {
        $parts += "run=$($Snapshot.runStatus)"
        if ($Snapshot.setupPhase) { $parts += "shell=$($Snapshot.setupPhase)" }
        if ($Snapshot.setupShellProgressPct -gt 0) { $parts += "pct=$($Snapshot.setupShellProgressPct)" }
        if ($Snapshot.setupShellTaskLabel) { $parts += "task=$($Snapshot.setupShellTaskLabel)" }
        if ($Snapshot.currentStep) { $parts += "step=$($Snapshot.currentStep)" }
        elseif ($Snapshot.totalSteps -gt 0) {
            $parts += "steps=$($Snapshot.completedSteps)/$($Snapshot.totalSteps)"
        }
    }
    if ($null -ne $NetworkConnected) {
        $parts += "net=$(if ($NetworkConnected) { 'up' } else { 'delayed' })"
    }
    return '  ' + ($parts -join ' | ')
}
function Wait-WinMintVmGuestDirectReady {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscredential]$Credential,
        [int]$TimeoutMinutes = 15
    )

    $startedAt = Get-Date
    $deadline = $startedAt.AddMinutes($TimeoutMinutes)
    $pollSeconds = 5
    while ((Get-Date) -lt $deadline) {
        $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if (-not $vm -or $vm.State -ne 'Running') {
            Start-Sleep -Seconds $pollSeconds
            continue
        }
        $probe = Invoke-WinMintVmGuestCommand -VMName $VMName -Credential $Credential -TimeoutSeconds 30 -ScriptBlock {
            $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
            if (-not (Test-Path -LiteralPath $pwsh)) {
                throw "Bundled PowerShell 7 is missing at $pwsh."
            }
            $env:COMPUTERNAME
        }
        if ($probe.Ok) { return }
        Start-Sleep -Seconds $pollSeconds
    }
    throw "PowerShell Direct to '$VMName' did not become ready within $TimeoutMinutes min."
}

function Invoke-WinMintVmPushAgentScripts {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ToolsVmRoot,
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$ProfilePath,
        [ValidateSet('Auto', 'Headless', 'Console')]
        [string]$AgentMode = 'Auto',
        [switch]$RerunFirstLogon
    )

    $pushScript = Join-Path $ToolsVmRoot 'Push-WinMintSetupScripts.ps1'
    $guestUser = $Credential.UserName
    $guestPassword = $null
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
    try {
        $guestPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    }
    finally {
        if ($bstr) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) | Out-Null }
    }

    Wait-WinMintVmGuestDirectReady -VMName $VMName -Credential $Credential
    $pushArgs = @{
        VMName = $VMName
        GuestUser = $guestUser
        GuestPassword = $guestPassword
        ProfilePath = $ProfilePath
        AgentMode = $AgentMode
        NoRerun = (-not $RerunFirstLogon)
    }
    if ($RerunFirstLogon) { $pushArgs['RerunFirstLogon'] = $true }
    & $pushScript @pushArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Push-WinMintSetupScripts failed with exit code $LASTEXITCODE."
    }
}
