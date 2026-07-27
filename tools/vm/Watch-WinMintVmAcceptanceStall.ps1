#Requires -Version 7.6
<#
.SYNOPSIS
    External stall watchdog for an already-running managed VM acceptance worker.

.DESCRIPTION
    In-process StallMinutes only applies to workers started after that code landed.
    This script watches managed-run.json + run-events.jsonl and kills the worker when:
      - AutoLogon is defaultuser0 / empty (from events or live probe)
      - setup-shell-live (or Wait progress with splash) without firstlogon-activity
        for StallMinutes

.EXAMPLE
    pwsh -NoProfile -File .\tools\vm\Watch-WinMintVmAcceptanceStall.ps1 -StallMinutes 12
#>
[CmdletBinding()]
param(
    [int]$StallMinutes = 12,
    [int]$PollSeconds = 20,
    [string]$ManagedRunPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WinMint-VmConsole.ps1')

$repoRoot = Set-WinMintVmRepoRoot -ToolsVmRoot $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ManagedRunPath)) {
    $ManagedRunPath = Get-WinMintVmManagedRunPath -RepoRoot $repoRoot
}

$guestSnapshotScript = Join-Path $PSScriptRoot 'Get-WinMintVmGuestWaitSnapshot.ps1'
$stallStartedAt = $null
$warned = $false

function Get-WinMintVmRunEventLabels {
    param([string]$Path)
    $labels = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $times = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Labels = $labels; Times = $times }
    }
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $ev = $line | ConvertFrom-Json
        }
        catch { continue }
        $label = ''
        if ($ev.label) { $label = [string]$ev.label }
        elseif ($ev.Payload -and $ev.Payload.label) { $label = [string]$ev.Payload.label }
        elseif ($ev.payload -and $ev.payload.label) { $label = [string]$ev.payload.label }
        if ([string]::IsNullOrWhiteSpace($label)) { continue }
        [void]$labels.Add($label)
        $ts = $null
        foreach ($k in @('ts', 'at', 'time', 'timestamp')) {
            if ($ev.PSObject.Properties[$k] -and $ev.$k) {
                try { $ts = [datetime]$ev.$k } catch { }
                if ($ts) { break }
            }
        }
        if (-not $ts) { $ts = Get-Date }
        if (-not $times.ContainsKey($label)) { $times[$label] = $ts }
    }
    [pscustomobject]@{ Labels = $labels; Times = $times }
}

function Stop-WinMintManagedWorker {
    param([object]$Run, [string]$Reason)
    Write-Host "STALL WATCHDOG: $Reason" -ForegroundColor Red
    if ($Run.pid -and (Test-WinMintVmProcessAlive -ProcessId ([int]$Run.pid))) {
        Stop-WinMintVmProcessTree -ProcessId ([int]$Run.pid)
    }
    $Run.status = 'failed'
    $Run.complete = $true
    $Run.finishedAt = (Get-Date).ToString('o')
    $Run.failReason = $Reason
    $Run | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ManagedRunPath -Encoding utf8
    $eventsPath = [string]$Run.runEvents
    if ($eventsPath -and (Test-Path -LiteralPath (Split-Path -Parent $eventsPath) -PathType Container)) {
        $line = (@{
                ts = (Get-Date).ToString('o')
                kind = 'error'
                label = 'external-stall-watchdog'
                reason = $Reason
            } | ConvertTo-Json -Compress)
        Add-Content -LiteralPath $eventsPath -Value $line -Encoding utf8
    }
    exit 1
}

Write-Host "Watching managed run for stall (StallMinutes=$StallMinutes)..." -ForegroundColor Cyan

while ($true) {
    $run = Read-WinMintVmManagedRunState -Path $ManagedRunPath
    if (-not $run -or -not $run.pid) {
        Write-Host 'No managed run; exiting.' -ForegroundColor DarkGray
        break
    }
    if (-not (Test-WinMintVmProcessAlive -ProcessId ([int]$run.pid))) {
        Write-Host "Worker pid $($run.pid) gone; exiting." -ForegroundColor DarkGray
        break
    }
    if ($run.status -in @('passed', 'failed', 'stopped') -or $run.complete -eq $true) {
        Write-Host "Managed run terminal ($($run.status)); exiting." -ForegroundColor DarkGray
        break
    }

    $events = Get-WinMintVmRunEventLabels -Path ([string]$run.runEvents)

    if ($events.Labels.Contains('autologon-mismatch')) {
        # Confirm with live probe when possible; events alone are enough to warn,
        # but only kill when DefaultUserName is defaultuser0/empty.
        $killAutologon = $false
        try {
            $profileJson = Get-Content -LiteralPath ([string]$run.profile) -Raw | ConvertFrom-Json
            $user = [string]$profileJson.identity.accountName
            $pass = [string]$profileJson.identity.password
            $cred = New-Object System.Management.Automation.PSCredential(
                $user, (ConvertTo-SecureString $pass -AsPlainText -Force))
            $al = Invoke-WinMintVmGuestCommand -VMName ([string]$run.vmName) -Credential $cred -TimeoutSeconds 30 -ScriptBlock {
                $p = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
                [pscustomobject]@{
                    AutoAdminLogon = [string]$p.AutoAdminLogon
                    DefaultUserName = [string]$p.DefaultUserName
                }
            }
            $got = [string]$al.Result.DefaultUserName
            if (-not $got -and $al.DefaultUserName) { $got = [string]$al.DefaultUserName }
            if ($got -ieq 'defaultuser0' -or [string]::IsNullOrWhiteSpace($got)) {
                $killAutologon = $true
                Stop-WinMintManagedWorker -Run $run -Reason "AutoLogon fail-fast: DefaultUserName='$got' (want '$user')"
            }
        }
        catch {
            Write-Host "AutoLogon confirm skipped: $($_.Exception.Message)" -ForegroundColor DarkGray
        }
        if ($killAutologon) { break }
    }

    $hasProgress = $events.Labels.Contains('firstlogon-activity') -or
        $events.Labels.Contains('agent-complete') -or
        $events.Labels.Contains('acceptance-passed')
    $splashLive = $events.Labels.Contains('setup-shell-live') -or
        $events.Labels.Contains('firstlogon-stall-clock')

    # Live guest snapshot when Wait/reachable (covers runs that emit progress lines only).
    $liveSplash = $splashLive
    $liveProgress = $hasProgress
    $phase = [string]$run.currentPhase
    if ($phase -in @('Wait', 'Boot', 'PostSetup') -and -not $hasProgress) {
        try {
            $profileJson = Get-Content -LiteralPath ([string]$run.profile) -Raw | ConvertFrom-Json
            $cred = New-Object System.Management.Automation.PSCredential(
                [string]$profileJson.identity.accountName,
                (ConvertTo-SecureString ([string]$profileJson.identity.password) -AsPlainText -Force))
            $poll = Invoke-WinMintVmGuestCommand -VMName ([string]$run.vmName) -Credential $cred `
                -FilePath $guestSnapshotScript -TimeoutSeconds 45
            if ($poll -and $poll.Result) {
                $snap = ConvertTo-WinMintVmGuestWaitSnapshot -Raw $poll.Result
                if ($snap.stateExists -or $snap.breadcrumb) { $liveProgress = $true }
                if ($snap.setupShellProcessRunning -or $snap.desktopGuardActive -or
                    -not [string]::IsNullOrWhiteSpace([string]$snap.setupPhase)) {
                    $liveSplash = $true
                }
            }
        }
        catch {
            # Guest not reachable yet — keep waiting.
        }
    }

    if ($liveSplash -and -not $liveProgress) {
        if (-not $stallStartedAt) {
            if ($events.Times.ContainsKey('setup-shell-live')) {
                $stallStartedAt = [datetime]$events.Times['setup-shell-live']
            }
            else {
                $stallStartedAt = Get-Date
            }
            Write-Host ("Stall clock armed at {0:HH:mm:ss} (fail after {1}m)." -f $stallStartedAt, $StallMinutes) -ForegroundColor Yellow
        }
        $elapsed = ((Get-Date) - $stallStartedAt).TotalMinutes
        if (-not $warned -and $elapsed -ge [Math]::Max(1, [Math]::Floor($StallMinutes / 2))) {
            $warned = $true
            Write-Host ("Stall warning: {0:N1}m without FirstLogon progress." -f $elapsed) -ForegroundColor Yellow
        }
        if ($elapsed -ge $StallMinutes) {
            Stop-WinMintManagedWorker -Run $run -Reason ("FirstLogon stall fail-fast: {0:N0}m splash/control without agent progress (StallMinutes={1})" -f $elapsed, $StallMinutes)
        }
    }
    else {
        if ($liveProgress -and $stallStartedAt) {
            Write-Host 'Agent progress seen; stall clock cleared.' -ForegroundColor DarkGray
        }
        $stallStartedAt = $null
        $warned = $false
    }

    Start-Sleep -Seconds $PollSeconds
}
