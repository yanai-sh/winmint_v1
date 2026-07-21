#Requires -Version 7.6
# Dot-sourced by WinMint-VmConsole.ps1 — not a standalone entrypoint.
# Smoke tier: keep polling after agent terminal status until FirstLogon activity is
# at least this old (~9Ã—5s polls) so setup-shell OOBE evidence is collected.
$script:WinMintVmSmokeFirstLogonMinElapsedSeconds = 45

function Get-WinMintVmSmokeFirstLogonMinElapsedSeconds {
    return $script:WinMintVmSmokeFirstLogonMinElapsedSeconds
}

function Test-WinMintVmSmokeFirstLogonActivityMinElapsed {
    param(
        [Parameter(Mandatory)][string]$AcceptanceTier,
        [Nullable[datetime]]$ActivityStartedAt,
        [datetime]$Now = (Get-Date)
    )

    if ($AcceptanceTier -ne 'Smoke') { return $true }
    # Late attach / manual FirstLogon kick: no activity timestamp means we cannot
    # enforce the splash hold — do not block Inspect forever on a finished run.
    if (-not $ActivityStartedAt) { return $true }
    return (($Now - $ActivityStartedAt).TotalSeconds -ge (Get-WinMintVmSmokeFirstLogonMinElapsedSeconds))
}

function Resolve-WinMintVmAcceptanceTier {
    param(
        [string]$RequestedTier = 'Auto',
        $ProfileJson
    )

    if ($RequestedTier -ne 'Auto') { return $RequestedTier }
    if ($ProfileJson) {
        return Resolve-WinMintVmAcceptanceTierFromProfile -ProfileJson $ProfileJson
    }
    return 'Full'
}

function Set-WinMintVmConnectPreset {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [switch]$BasicSession
    )

    $vmGuid = (Get-VM -Name $VMName -ErrorAction Stop).Id.Guid
    $vc = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Select-Object -First 1
    $hostW = if ($vc) { [int]$vc.CurrentHorizontalResolution } else { 1920 }
    $hostH = if ($vc) { [int]$vc.CurrentVerticalResolution } else { 1080 }
    $vmcKey = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Virtualization\$vmGuid"
    $null = New-Item -Path $vmcKey -Force
    $entries = @(
        @{ N = 'DesktopWidth'; V = $hostW }
        @{ N = 'DesktopHeight'; V = $hostH }
        @{ N = 'FullScreen'; V = 0 }
        @{ N = 'SmartSizing'; V = 1 }
        @{ N = 'UseAllMonitors'; V = 0 }
    )
    if ($BasicSession) {
        $entries += @{ N = 'DisableEnhancedMode'; V = 1 }
    }
    else {
        $entries += @(
            @{ N = 'RedirectClipboard'; V = 1 }
            @{ N = 'RedirectDrives'; V = 1 }
        )
    }
    foreach ($kv in $entries) {
        $null = New-ItemProperty -Path $vmcKey -Name $kv.N -PropertyType DWord -Value $kv.V -Force
    }
}

function Get-WinMintVmConnectProcess {
    param([Parameter(Mandatory)][string]$VMName)

    foreach ($proc in @(Get-Process -Name 'vmconnect' -ErrorAction SilentlyContinue)) {
        try {
            $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)" -ErrorAction Stop).CommandLine
            if ($cmd -and $cmd -like "*$VMName*") { return $proc }
        }
        catch { }
    }
    return $null
}

function Stop-WinMintVmConnect {
    param([Parameter(Mandatory)][string]$VMName)

    $stopped = 0
    foreach ($proc in @(Get-Process -Name 'vmconnect' -ErrorAction SilentlyContinue)) {
        try {
            $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)" -ErrorAction SilentlyContinue).CommandLine
            if ($cmd -and $cmd -like "*$VMName*") {
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                $stopped++
            }
        }
        catch { }
    }
    return $stopped
}

function Set-WinMintVmConnectVideo {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$HorizontalResolution = 1920,
        [int]$VerticalResolution = 1080
    )

    try {
        Set-VMVideo -VMName $VMName `
            -HorizontalResolution $HorizontalResolution `
            -VerticalResolution $VerticalResolution `
            -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Warning "Set-VMVideo failed for '$VMName': $($_.Exception.Message)"
    }
}

function Maximize-WinMintVmConnectWindow {
    try {
        if (-not ('WinMint.Vmc' -as [type])) {
            Add-Type -Namespace WinMint -Name Vmc -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int n);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
'@
        }
        $SW_MAXIMIZE = 3
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            foreach ($p in @(Get-Process -Name 'vmconnect' -ErrorAction SilentlyContinue)) {
                if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
                    [WinMint.Vmc]::ShowWindow($p.MainWindowHandle, $SW_MAXIMIZE) | Out-Null
                    [WinMint.Vmc]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
                    return $true
                }
            }
        }
    }
    catch { }
    return $false
}

function Open-WinMintVmConnectBasicWatch {
    param([Parameter(Mandatory)][string]$VMName)

    Set-WinMintVmConnectPreset -VMName $VMName -BasicSession
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($vm -and $vm.State -eq 'Off') {
        Set-WinMintVmConnectVideo -VMName $VMName
    }
    if (Stop-WinMintVmConnect -VMName $VMName) {
        Start-Sleep -Milliseconds 800
    }
    return Start-WinMintVmConnect -VMName $VMName -MaximizeWindow
}

function Start-WinMintVmConnect {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [switch]$MaximizeWindow
    )

    $proc = Start-Process -FilePath 'vmconnect.exe' -ArgumentList @('localhost', $VMName) -PassThru
    if ($MaximizeWindow) {
        Maximize-WinMintVmConnectWindow | Out-Null
    }
    return $proc
}

function Start-WinMintVmObserve {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [switch]$EnhancedSession,
        [switch]$AllowReuse
    )

    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ($vm.State -ne 'Running') {
        throw "VM '$VMName' is not running (state: $($vm.State))."
    }

    $useBasic = -not $EnhancedSession.IsPresent
    Set-WinMintVmConnectPreset -VMName $VMName -BasicSession:$useBasic
    if ($vm.State -eq 'Off') {
        Set-WinMintVmConnectVideo -VMName $VMName
    }
    $mode = if ($useBasic) { 'basic' } else { 'enhanced' }

    $refreshed = $false
    if (-not $AllowReuse) {
        $stopped = Stop-WinMintVmConnect -VMName $VMName
        if ($stopped -gt 0) {
            $refreshed = $true
            Start-Sleep -Milliseconds 800
        }
    }
    else {
        $existing = Get-WinMintVmConnectProcess -VMName $VMName
        if ($existing) {
            return [ordered]@{
                observeMode = $mode
                observePid = $existing.Id
                reused = $true
                refreshed = $false
            }
        }
    }

    $proc = Start-WinMintVmConnect -VMName $VMName -MaximizeWindow
    return [ordered]@{
        observeMode = $mode
        observePid = $proc.Id
        reused = $false
        refreshed = $refreshed
    }
}

function Test-WinMintVmInlineConsole {
    param(
        [switch]$WindowsTerminal,
        [switch]$NoWindowsTerminal
    )

    # Default: run in the current console (elevated WT/pwsh at repo root). WT relaunch is opt-in.
    if ($NoWindowsTerminal -or -not $WindowsTerminal) { return $true }
    if ($env:CI -eq 'true' -or $env:GITHUB_ACTIONS -eq 'true' -or $env:TF_BUILD -eq 'true') { return $true }
    if (-not [Environment]::UserInteractive) { return $true }
    if (-not [string]::IsNullOrWhiteSpace($env:WT_SESSION)) { return $true }
    return $false
}

function Set-WinMintVmRepoRoot {
    param([Parameter(Mandatory)][string]$ToolsVmRoot)

    $repoRoot = Split-Path -Parent (Split-Path -Parent $ToolsVmRoot)
    Set-Location -LiteralPath $repoRoot
    return $repoRoot
}

function Resolve-WinMintWindowsTerminalPath {
    $command = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($candidate in @(
            (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe')
            (Join-Path ${env:ProgramFiles} 'WindowsApps\wt.exe')
        )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return $null
}

function ConvertTo-WinMintPwshCliArguments {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [hashtable]$BoundParameters
    )

    $args = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)
    foreach ($entry in ($BoundParameters.GetEnumerator() | Sort-Object Key)) {
        $name = [string]$entry.Key
        $value = $entry.Value
        if ($name -in @('NoWindowsTerminal', 'WindowsTerminal', 'ManagedRun')) { continue }
        if ($value -is [switch]) {
            if ($value.IsPresent) { $args += "-$name" }
            continue
        }
        $args += "-$name"
        if ($null -ne $value) { $args += [string]$value }
    }
    $args += '-NoWindowsTerminal'
    return $args
}

function Resolve-WinMintPwshHostPath {
    $command = Get-Command pwsh -ErrorAction Stop
    if ($command.Source -like '*WindowsApps*') {
        $direct = Join-Path ${env:ProgramFiles} 'PowerShell\7\pwsh.exe'
        if (Test-Path -LiteralPath $direct -PathType Leaf) { return $direct }
    }
    return $command.Source
}

function Format-WinMintProcessArgument {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '"', '""') + '"'
}

function ConvertTo-WinMintWtCommandLine {
    param(
        [Parameter(Mandatory)][string]$TabTitle,
        [Parameter(Mandatory)][string]$StartingDirectory,
        [Parameter(Mandatory)][string]$PwshPath,
        [Parameter(Mandatory)][string[]]$PwshArguments,
        # -1 = new window (managed worker default); 0 = last-used window
        [int]$WindowId = 0
    )

    $parts = @(
        '-w', [string]$WindowId, 'new-tab',
        '--title', (Format-WinMintProcessArgument $TabTitle),
        '-d', (Format-WinMintProcessArgument $StartingDirectory),
        '--',
        (Format-WinMintProcessArgument $PwshPath)
    )
    foreach ($arg in $PwshArguments) {
        $parts += Format-WinMintProcessArgument $arg
    }
    return ($parts -join ' ')
}

function Start-WinMintVmAcceptanceWorkerConsole {
    <#
    .SYNOPSIS
        Launch the acceptance worker in one live console (Windows Terminal by default).

    .DESCRIPTION
        Spectre build UI and harness Wait/Inspect lines share that single session.
        Pass -NoConsole for a minimized detached pwsh (agents/CI without a watch window).
        Do not open separate verbose/run.log tail tabs — those race the live console.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$PwshPath,
        [Parameter(Mandatory)][string[]]$PwshArguments,
        [string]$ErrLog = '',
        [string]$TabTitle = 'WinMint VM Acceptance',
        [switch]$NoConsole
    )

    if ($NoConsole) {
        $start = @{
            FilePath         = $PwshPath
            ArgumentList     = $PwshArguments
            WorkingDirectory = $RepoRoot
            PassThru         = $true
            WindowStyle      = 'Minimized'
        }
        if ($ErrLog) { $start.RedirectStandardError = $ErrLog }
        $proc = Start-Process @start
        return [pscustomobject]@{
            Mode           = 'minimized'
            Process        = $proc
            ConsoleOpened  = $false
            WorkerPidKnown = $true
        }
    }

    $terminalPath = Resolve-WinMintWindowsTerminalPath
    if ($terminalPath) {
        $commandLine = ConvertTo-WinMintWtCommandLine `
            -TabTitle $TabTitle `
            -StartingDirectory $RepoRoot `
            -PwshPath $PwshPath `
            -PwshArguments $PwshArguments `
            -WindowId -1
        Start-Process -FilePath $terminalPath -ArgumentList $commandLine -WindowStyle Normal | Out-Null
        Write-Host "Opened Windows Terminal '$TabTitle' (Spectre build + acceptance harness in one session)."
        return [pscustomobject]@{
            Mode           = 'windows-terminal'
            Process        = $null
            ConsoleOpened  = $true
            WorkerPidKnown = $false
        }
    }

    Write-Warning 'Windows Terminal (wt.exe) was not found; falling back to a visible pwsh window.'
    $start = @{
        FilePath         = $PwshPath
        ArgumentList     = $PwshArguments
        WorkingDirectory = $RepoRoot
        PassThru         = $true
        WindowStyle      = 'Normal'
    }
    if ($ErrLog) { $start.RedirectStandardError = $ErrLog }
    $proc = Start-Process @start
    return [pscustomobject]@{
        Mode           = 'pwsh'
        Process        = $proc
        ConsoleOpened  = $true
        WorkerPidKnown = $true
    }
}

function Wait-WinMintVmManagedWorkerReady {
    param(
        [Parameter(Mandatory)][string]$ManagedPath,
        [int]$TimeoutSeconds = 45,
        [System.Diagnostics.Process]$LaunchProcess
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($LaunchProcess -and $LaunchProcess.HasExited) {
            return [pscustomobject]@{
                Ok = $false
                Pid = [int]$LaunchProcess.Id
                ExitCode = [int]$LaunchProcess.ExitCode
                State = $null
                Reason = 'launch-process-exited'
            }
        }
        $state = Read-WinMintVmManagedRunState -Path $ManagedPath
        if ($state -and $state.pid -and [int]$state.pid -gt 0) {
            $phase = [string]$state.currentPhase
            if ($phase -and $phase -ne 'starting' -and (Test-WinMintVmProcessAlive -ProcessId ([int]$state.pid))) {
                return [pscustomobject]@{
                    Ok = $true
                    Pid = [int]$state.pid
                    ExitCode = -1
                    State = $state
                    Reason = 'worker-ready'
                }
            }
        }
        Start-Sleep -Milliseconds 400
    }

    $state = Read-WinMintVmManagedRunState -Path $ManagedPath
    $pid = if ($state -and $state.pid) { [int]$state.pid } elseif ($LaunchProcess) { [int]$LaunchProcess.Id } else { 0 }
    return [pscustomobject]@{
        Ok = $false
        Pid = $pid
        ExitCode = -1
        State = $state
        Reason = 'timeout'
    }
}

function Start-WinMintVmScriptInWindowsTerminal {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$StartingDirectory,
        [hashtable]$BoundParameters,
        [string]$TabTitle = 'WinMint VM Acceptance'
    )

    $terminalPath = Resolve-WinMintWindowsTerminalPath
    if (-not $terminalPath) {
        Write-Warning 'Windows Terminal (wt.exe) was not found. Continuing in the current console.'
        return $false
    }

    $pwshPath = Resolve-WinMintPwshHostPath
    $pwshArgs = ConvertTo-WinMintPwshCliArguments -ScriptPath $ScriptPath -BoundParameters $BoundParameters
    $commandLine = ConvertTo-WinMintWtCommandLine -TabTitle $TabTitle -StartingDirectory $StartingDirectory -PwshPath $pwshPath -PwshArguments $pwshArgs
    Start-Process -FilePath $terminalPath -ArgumentList $commandLine -WindowStyle Normal | Out-Null
    Write-Host "Opened Windows Terminal tab '$TabTitle'. Follow live output there; run.log is still written under the evidence folder."
    return $true
}

function Start-WinMintVmRunLogViewerInWindowsTerminal {
    param(
        [Parameter(Mandatory)][string]$RunLog,
        [Parameter(Mandatory)][string]$StartingDirectory,
        [string]$TabTitle = 'WinMint VM run.log',
        [int]$Tail = 20
    )

    if (-not [Environment]::UserInteractive) { return $false }
    if ($env:CI -eq 'true' -or $env:GITHUB_ACTIONS -eq 'true' -or $env:TF_BUILD -eq 'true') { return $false }

    $terminalPath = Resolve-WinMintWindowsTerminalPath
    if (-not $terminalPath) {
        Write-Warning "Windows Terminal (wt.exe) was not found. Tail the log manually: Get-Content -LiteralPath '$RunLog' -Wait -Tail $Tail"
        return $false
    }

    $logDir = Split-Path -Parent $RunLog
    if (-not (Test-Path -LiteralPath $logDir)) {
        $null = New-Item -ItemType Directory -Path $logDir -Force
    }
    if (-not (Test-Path -LiteralPath $RunLog)) {
        $null = New-Item -ItemType File -Path $RunLog -Force
    }

    $pwshPath = Resolve-WinMintPwshHostPath
    $escapedLog = $RunLog.Replace("'", "''")
    $tailScript = "Get-Content -LiteralPath '$escapedLog' -Wait -Tail $Tail"
    $pwshArgs = @('-NoLogo', '-NoProfile', '-Command', $tailScript)
    $commandLine = ConvertTo-WinMintWtCommandLine -TabTitle $TabTitle -StartingDirectory $StartingDirectory -PwshPath $pwshPath -PwshArguments $pwshArgs
    Start-Process -FilePath $terminalPath -ArgumentList $commandLine -WindowStyle Normal | Out-Null
    Write-Host "Opened Windows Terminal tab '$TabTitle' tailing $RunLog."
    return $true
}

function Start-WinMintVmBuildLogViewersInWindowsTerminal {
    <#
    .SYNOPSIS
        Legacy helper: open verbose + run.log tail tabs. Managed acceptance no
        longer calls this — use Start-WinMintVmAcceptanceWorkerConsole instead.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RunLog,
        [Parameter(Mandatory)][string]$StartingDirectory,
        [switch]$NoLogViewer
    )

    if ($NoLogViewer) { return [ordered]@{ verboseOpened = $false; runLogOpened = $false; verboseLog = (Get-WinMintVmBuildVerboseLogPath -RepoRoot $RepoRoot) } }

    $verboseLog = Get-WinMintVmBuildVerboseLogPath -RepoRoot $RepoRoot
    $outDir = Split-Path -Parent $verboseLog
    if (-not (Test-Path -LiteralPath $outDir)) { $null = New-Item -ItemType Directory -Path $outDir -Force }
    if (-not (Test-Path -LiteralPath $verboseLog -PathType Leaf)) {
        Set-Content -LiteralPath $verboseLog -Value "WinMint verbose build log (waiting for build) $(Get-Date -Format o)" -Encoding utf8
    }

    $verboseOpened = Start-WinMintVmRunLogViewerInWindowsTerminal `
        -RunLog $verboseLog `
        -StartingDirectory $StartingDirectory `
        -TabTitle 'WinMint Build verbose' `
        -Tail 40
    # Harness phases (Wait/Inspect/Evidence) still land in run.log.
    $runLogOpened = Start-WinMintVmRunLogViewerInWindowsTerminal `
        -RunLog $RunLog `
        -StartingDirectory $StartingDirectory `
        -TabTitle 'WinMint VM run.log' `
        -Tail 30
    return [ordered]@{
        verboseOpened = [bool]$verboseOpened
        runLogOpened  = [bool]$runLogOpened
        verboseLog    = $verboseLog
    }
}

function Get-WinMintVmManagedRunPath {
    param([Parameter(Mandatory)][string]$RepoRoot)
    return Join-Path $RepoRoot 'output\vm-acceptance\managed-run.json'
}

function Read-WinMintVmManagedRunState {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { return $null }
}

function Write-WinMintVmManagedRunState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$State
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    if ($State -is [hashtable]) { $State['updatedAt'] = (Get-Date).ToString('o') }
    # Unique tmp + File.Move overwrite: starter and worker both write managed-run.json.
    # A shared "$Path.tmp" makes Move-Item -Force throw ERROR_ALREADY_EXISTS under race.
    $tmp = Join-Path $dir ("managed-run.{0}.{1}.tmp" -f $PID, [guid]::NewGuid().ToString('N'))
    ($State | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $tmp -Encoding UTF8
    try {
        [System.IO.File]::Move($tmp, $Path, $true)
    }
    catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Stop-WinMintVmProcessTree {
    param([int]$ProcessId)

    if ($ProcessId -le 0) { return }
    $children = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ParentProcessId -eq $ProcessId }
    foreach ($child in $children) {
        Stop-WinMintVmProcessTree -ProcessId ([int]$child.ProcessId)
    }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Test-WinMintVmProcessAlive {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Get-WinMintVmRunLogTail {
    param(
        [string]$RunLog,
        [int]$Tail = 20
    )

    if (-not $RunLog -or -not (Test-Path -LiteralPath $RunLog)) { return @() }
    return @(Get-Content -LiteralPath $RunLog -Tail $Tail -ErrorAction SilentlyContinue)
}
function Get-WinMintVmPostSetupCheckpointSidecarPath {
    param([Parameter(Mandatory)][string]$RepoRoot)

    return Join-Path $RepoRoot 'output\.vm-postsetup-checkpoint.json'
}

function Get-WinMintVmCheckpointSnapshot {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$SnapshotName
    )

    return Get-VMSnapshot -VMName $VMName -Name $SnapshotName -ErrorAction SilentlyContinue
}

function Test-WinMintVmPostSetupCheckpointReady {
    param(
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][pscredential]$Credential,
        [int]$TimeoutSeconds = 45
    )

    $poll = Invoke-WinMintVmGuestCommand -VMName $VmName -Credential $Credential -TimeoutSeconds $TimeoutSeconds -ScriptBlock {
        $setupComplete = Test-Path -LiteralPath 'C:\Windows\Panther\setupcomplete.log'
        $statePath = Join-Path $env:LOCALAPPDATA 'WinMint\state.json'
        $terminal = $false
        if (Test-Path -LiteralPath $statePath) {
            try {
                $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
                $terminal = [string]$state.run.status -in @('ok', 'failed')
            }
            catch { $terminal = $false }
        }
        [pscustomobject]@{
            SetupComplete = $setupComplete
            AgentTerminal = $terminal
            Ready = ($setupComplete -and -not $terminal)
        }
    }
    if (-not $poll.Ok) { return $null }
    return $poll.Result
}

function Test-WinMintVmPostSetupCheckpointUsable {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Fingerprint,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$CheckpointName = 'PostSetup'
    )

    $sidecarPath = Get-WinMintVmPostSetupCheckpointSidecarPath -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $sidecarPath)) { return $false }
    try {
        $sidecar = Get-Content -LiteralPath $sidecarPath -Raw | ConvertFrom-Json
        $storedImage = if ($sidecar.PSObject.Properties['imageFingerprint'] -and -not [string]::IsNullOrWhiteSpace([string]$sidecar.imageFingerprint)) {
            [string]$sidecar.imageFingerprint
        }
        else {
            [string]$sidecar.fingerprint
        }
        if ($storedImage -ne $Fingerprint) {
            # ponytail: legacy sidecars stored the full runtime hash; reuse when the
            # checkpoint still exists and the cached ISO sidecar is present (harness upgrade).
            if (-not [string]::IsNullOrWhiteSpace($storedImage)) { return $false }
            $buildSidecar = Join-Path $RepoRoot 'output\.vm-build-fingerprint.json'
            if (-not (Test-Path -LiteralPath $buildSidecar)) { return $false }
            try {
                $build = Get-Content -LiteralPath $buildSidecar -Raw | ConvertFrom-Json
                if (-not $build.isoPath -or -not (Test-Path -LiteralPath ([string]$build.isoPath))) { return $false }
            }
            catch { return $false }
        }
        if ([string]$sidecar.vmName -and [string]$sidecar.vmName -ne $VMName) { return $false }
        if ([string]$sidecar.checkpointName -and [string]$sidecar.checkpointName -ne $CheckpointName) { return $false }
    }
    catch { return $false }

    if (-not (Get-VM -Name $VMName -ErrorAction SilentlyContinue)) { return $false }
    return $null -ne (Get-WinMintVmCheckpointSnapshot -VMName $VMName -SnapshotName $CheckpointName)
}

function Save-WinMintVmPostSetupCheckpoint {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$Fingerprint,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$AgentFingerprint = '',
        [string]$CheckpointName = 'PostSetup'
    )

    $ready = Test-WinMintVmPostSetupCheckpointReady -VmName $VMName -Credential $Credential
    if (-not $ready -or -not $ready.Ready) { return $false }

    $existing = Get-WinMintVmCheckpointSnapshot -VMName $VMName -SnapshotName $CheckpointName
    if ($existing) {
        Remove-VMSnapshot -VMSnapshot $existing -Confirm:$false
    }
    Checkpoint-VM -Name $VMName -SnapshotName $CheckpointName
    $sidecarPath = Get-WinMintVmPostSetupCheckpointSidecarPath -RepoRoot $RepoRoot
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sidecarPath)
    $sidecar = [ordered]@{
        fingerprint = $Fingerprint
        imageFingerprint = $Fingerprint
        vmName = $VMName
        checkpointName = $CheckpointName
        savedUtc = [datetime]::UtcNow.ToString('o')
    }
    if (-not [string]::IsNullOrWhiteSpace($AgentFingerprint)) {
        $sidecar.agentFingerprint = $AgentFingerprint
    }
    ($sidecar | ConvertTo-Json) | Set-Content -LiteralPath $sidecarPath -Encoding UTF8
    Write-Host "Saved PostSetup checkpoint '$CheckpointName' on '$VMName' (fingerprint sidecar: $sidecarPath)."
    return $true
}

function Restore-WinMintVmPostSetupCheckpoint {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [string]$CheckpointName = 'PostSetup',
        [string]$SwitchName
    )

    $snapshot = Get-WinMintVmCheckpointSnapshot -VMName $VMName -SnapshotName $CheckpointName
    if (-not $snapshot) {
        throw "Checkpoint '$CheckpointName' not found on '$VMName'."
    }
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ($vm.State -ne 'Off') {
        Stop-VM -Name $VMName -TurnOff -Force
    }
    Restore-VMSnapshot -VMSnapshot $snapshot -Confirm:$false
    Start-VM -Name $VMName
    if ($SwitchName) {
        $adapter = Get-VMNetworkAdapter -VMName $VMName | Select-Object -First 1
        if ($adapter -and -not $adapter.Connected) {
            Connect-VMNetworkAdapter -VMName $VMName -SwitchName $SwitchName
            Write-Host "Reconnected '$VMName' to '$SwitchName' after checkpoint restore (post-Setup boundary is safe for network)."
        }
    }
    Write-Host "Restored checkpoint '$CheckpointName' on '$VMName' and started the VM."
}
