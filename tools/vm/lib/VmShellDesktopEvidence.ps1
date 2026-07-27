#Requires -Version 7.6
# Dot-sourced by WinMint-VmConsole.ps1 — shell desktop (Terminal + pins) acceptance scoring.

function Get-WinMintVmExpectedWslTerminalDisplayName {
    param([string]$Distro)

    switch -Regex ([string]$Distro) {
        '^(NixOS-WSL|NixOS|nixos-wsl)$' { return 'NixOS' }
        '^(Fedora|FedoraLinux|FedoraLinux-\d+)$' { return 'Fedora' }
        '^(Arch(?: Linux)?|archlinux)$' { return 'Arch Linux' }
        '^(Pengwin|pengwin)$' { return 'pengwin' }
        '^Ubuntu(-\d+\.\d+)?$' { return 'Ubuntu' }
        default {
            $t = ([string]$Distro).Trim()
            if ([string]::IsNullOrWhiteSpace($t)) { return $null }
            return $t
        }
    }
}

function Get-WinMintVmExpectedTerminalProfileNames {
    param([string[]]$WslDistros = @())

    $names = [System.Collections.Generic.List[string]]::new()
    $names.Add('PowerShell') | Out-Null
    foreach ($distro in @($WslDistros)) {
        $display = Get-WinMintVmExpectedWslTerminalDisplayName -Distro $distro
        if ($display -and $names -notcontains $display) { $names.Add($display) | Out-Null }
    }
    return @($names)
}

function Get-WinMintVmPinDisplayName {
    param([Parameter(Mandatory)][string]$Id)

    switch ([string]$Id) {
        'zen-browser' { 'Zen Browser' }
        'helium' { 'Helium' }
        'firefox-developer-edition' { 'Firefox Developer Edition' }
        'brave' { 'Brave' }
        'edge' { 'Microsoft Edge' }
        'cursor' { 'Cursor' }
        'vscode' { 'Visual Studio Code' }
        'zed' { 'Zed' }
        'antigravity' { 'Antigravity' }
        default { $Id }
    }
}

function Get-WinMintVmShellDesktopEvidencePaths {
    param([Parameter(Mandatory)][string]$EvidenceDir)

    [ordered]@{
        FirstLogonLog = Join-Path $EvidenceDir 'ProgramData-Logs\FirstLogon.log'
        ShellPinsJson = Join-Path $EvidenceDir 'ProgramData-Logs\FirstLogon_ShellPins.json'
        TerminalSettings = Join-Path $EvidenceDir 'LocalAppData-Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
        TaskbarLayout = Join-Path $EvidenceDir 'LocalAppData-Shell\LayoutModification.xml'
    }
}

function Test-WinMintVmShellDesktopEvidence {
    <#
    .SYNOPSIS
        Score Terminal hard-replace + Start/taskbar pin evidence.
        Baseline Explorer/Terminal and pin-selection intent are plumbing;
        missing optional app shortcuts are warnings (soft-skip).
    #>
    param(
        [Parameter(Mandatory)]$BuildProfile,
        [string]$EvidenceDir = '',
        $Inspect = $null,
        $TerminalSettings = $null,
        $ShellPins = $null,
        [string]$FirstLogonLogText = ''
    )

    $plumbing = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $meta = [ordered]@{
        expectedTerminalProfiles = @()
        observedTerminalProfiles = @()
        wslSkip = $false
        shellPinsPresent = $false
    }

    $browsers = @()
    $editors = @()
    $wslDistros = @()
    $wslSkip = $false
    try {
        if ($BuildProfile.development) {
            if ($BuildProfile.development.PSObject.Properties['browsers']) { $browsers = @($BuildProfile.development.browsers) }
            if ($BuildProfile.development.PSObject.Properties['editors']) { $editors = @($BuildProfile.development.editors) }
            if ($BuildProfile.development.wsl -and $BuildProfile.development.wsl.PSObject.Properties['distros']) {
                $wslDistros = @($BuildProfile.development.wsl.distros)
            }
        }
        if ($BuildProfile.diagnostics -and $BuildProfile.diagnostics.PSObject.Properties['wslRuntimeValidation']) {
            $wslSkip = ([string]$BuildProfile.diagnostics.wslRuntimeValidation -eq 'skip')
        }
    }
    catch { }
    $meta.wslSkip = $wslSkip

    $paths = $null
    if (-not [string]::IsNullOrWhiteSpace($EvidenceDir) -and (Test-Path -LiteralPath $EvidenceDir -PathType Container)) {
        $paths = Get-WinMintVmShellDesktopEvidencePaths -EvidenceDir $EvidenceDir
        if (-not $TerminalSettings -and (Test-Path -LiteralPath $paths.TerminalSettings -PathType Leaf)) {
            try { $TerminalSettings = Get-Content -LiteralPath $paths.TerminalSettings -Raw | ConvertFrom-Json } catch { }
        }
        if (-not $ShellPins -and (Test-Path -LiteralPath $paths.ShellPinsJson -PathType Leaf)) {
            try { $ShellPins = Get-Content -LiteralPath $paths.ShellPinsJson -Raw | ConvertFrom-Json } catch { }
        }
        if ([string]::IsNullOrWhiteSpace($FirstLogonLogText) -and (Test-Path -LiteralPath $paths.FirstLogonLog -PathType Leaf)) {
            $FirstLogonLogText = Get-Content -LiteralPath $paths.FirstLogonLog -Raw -ErrorAction SilentlyContinue
        }
    }

    if (-not $TerminalSettings -and $Inspect) {
        # Prefer durable settings file; fall back to inspect summary fields only when needed.
        if ($Inspect.PSObject.Properties['TerminalLaunchMode'] -or $Inspect.PSObject.Properties['TerminalProfiles']) {
            $TerminalSettings = [pscustomobject]@{
                centerOnLaunch = if ($Inspect.PSObject.Properties['TerminalCenterOnLaunch']) { $Inspect.TerminalCenterOnLaunch } else { $null }
                launchMode     = if ($Inspect.PSObject.Properties['TerminalLaunchMode']) { $Inspect.TerminalLaunchMode } else { $null }
                profiles       = [pscustomobject]@{
                    defaults = [pscustomobject]@{
                        opacity     = if ($Inspect.PSObject.Properties['TerminalOpacity']) { $Inspect.TerminalOpacity } else { $null }
                        colorScheme = if ($Inspect.PSObject.Properties['TerminalColorScheme']) { $Inspect.TerminalColorScheme } else { $null }
                    }
                    list = @(
                        foreach ($name in @($Inspect.TerminalProfiles)) {
                            [pscustomobject]@{ name = [string]$name }
                        }
                    )
                }
            }
        }
    }

    $expectedProfiles = @(Get-WinMintVmExpectedTerminalProfileNames -WslDistros $wslDistros)
    $meta.expectedTerminalProfiles = $expectedProfiles

    if (-not $TerminalSettings) {
        $plumbing.Add('Windows Terminal settings.json missing from evidence/inspect') | Out-Null
    }
    else {
        $observed = @($TerminalSettings.profiles.list | ForEach-Object { [string]$_.name })
        $meta.observedTerminalProfiles = $observed
        if (($observed -join '|') -ne ($expectedProfiles -join '|')) {
            $plumbing.Add("Terminal profiles hard-replace mismatch: expected [$($expectedProfiles -join ', ')] got [$($observed -join ', ')]") | Out-Null
        }
        if ($TerminalSettings.PSObject.Properties['launchMode'] -and [string]$TerminalSettings.launchMode -ne 'default') {
            $plumbing.Add("Terminal launchMode must be default (windowed), got '$($TerminalSettings.launchMode)'") | Out-Null
        }
        elseif (-not $TerminalSettings.PSObject.Properties['launchMode'] -or [string]::IsNullOrWhiteSpace([string]$TerminalSettings.launchMode)) {
            $plumbing.Add('Terminal launchMode missing (expected default)') | Out-Null
        }
        if ($TerminalSettings.PSObject.Properties['centerOnLaunch'] -and -not [bool]$TerminalSettings.centerOnLaunch) {
            $plumbing.Add('Terminal centerOnLaunch must be true') | Out-Null
        }
        $opacity = $null
        try { $opacity = [int]$TerminalSettings.profiles.defaults.opacity } catch { }
        if ($opacity -ne 80) {
            $plumbing.Add("Terminal opacity must be 80, got '$opacity'") | Out-Null
        }
        $scheme = try { [string]$TerminalSettings.profiles.defaults.colorScheme } catch { '' }
        if ($scheme -ne 'One Half Dark') {
            $plumbing.Add("Terminal colorScheme must be One Half Dark, got '$scheme'") | Out-Null
        }
    }

    if ($wslSkip -and @($wslDistros | Where-Object { $_ }).Count -gt 0) {
        if ($FirstLogonLogText -notmatch 'terminalProfile=mock') {
            $plumbing.Add('WSL validation skip selected distros but FirstLogon.log lacks terminalProfile=mock') | Out-Null
        }
    }

    $selection = $null
    try {
        # Selection helper lives in FirstLogon.Desktop; when unavailable (pure unit test of
        # this file alone), reconstruct the same Edge/taskbar rules inline.
        if (Get-Command Get-WinMintFirstLogonPinSelection -ErrorAction SilentlyContinue) {
            $selection = Get-WinMintFirstLogonPinSelection -Browsers $browsers -Editors $editors
        }
        else {
            $cliOnly = @('neovim')
            $includeEdge = @($browsers | ForEach-Object { [string]$_ }) -contains 'edge'
            $browserIds = @($browsers | ForEach-Object { [string]$_ } | Where-Object { $_ -and $_ -ne 'edge' -and $cliOnly -notcontains $_ } | Select-Object -Unique)
            $editorIds = @($editors | ForEach-Object { [string]$_ } | Where-Object { $_ -and $cliOnly -notcontains $_ } | Select-Object -Unique)
            $pinEdgeStart = [bool]$includeEdge
            $pinEdgeTaskbar = [bool]$includeEdge -and ($browserIds.Count -eq 0)
            $startIds = @($browserIds + $(if ($pinEdgeStart) { @('edge') } else { @() }) + $editorIds)
            $taskIds = @($browserIds + $(if ($pinEdgeTaskbar) { @('edge') } else { @() }) + $editorIds)
            $selection = [pscustomobject]@{
                StartAppIds      = $startIds
                TaskbarAppIds    = $taskIds
                PinEdgeToStart   = $pinEdgeStart
                PinEdgeToTaskbar = $pinEdgeTaskbar
            }
        }
    }
    catch {
        $plumbing.Add("Pin selection could not be derived from profile: $($_.Exception.Message)") | Out-Null
    }

    if (-not $ShellPins) {
        $plumbing.Add('FirstLogon_ShellPins.json missing (Start/taskbar pin report never written)') | Out-Null
    }
    elseif ($selection) {
        $meta.shellPinsPresent = $true
        $reportedStart = @($ShellPins.startAppIds | ForEach-Object { [string]$_ })
        $reportedTaskbar = @($ShellPins.taskbarAppIds | ForEach-Object { [string]$_ })
        $expectedStart = @($selection.StartAppIds | ForEach-Object { [string]$_ })
        $expectedTaskbar = @($selection.TaskbarAppIds | ForEach-Object { [string]$_ })
        if (($reportedStart -join '|') -ne ($expectedStart -join '|')) {
            $plumbing.Add("ShellPins startAppIds mismatch: expected [$($expectedStart -join ', ')] got [$($reportedStart -join ', ')]") | Out-Null
        }
        if (($reportedTaskbar -join '|') -ne ($expectedTaskbar -join '|')) {
            $plumbing.Add("ShellPins taskbarAppIds mismatch: expected [$($expectedTaskbar -join ', ')] got [$($reportedTaskbar -join ', ')]") | Out-Null
        }
        if ([bool]$ShellPins.pinEdgeToTaskbar -ne [bool]$selection.PinEdgeToTaskbar) {
            $plumbing.Add("ShellPins pinEdgeToTaskbar=$($ShellPins.pinEdgeToTaskbar) expected $($selection.PinEdgeToTaskbar)") | Out-Null
        }
        $startPinsJson = [string]$ShellPins.startPinsJson
        if ($startPinsJson -notmatch 'Microsoft\.Windows\.Explorer') {
            $plumbing.Add('ConfigureStartPins JSON missing File Explorer baseline') | Out-Null
        }
        if ($startPinsJson -notmatch 'Microsoft\.WindowsTerminal_8wekyb3d8bbwe!App') {
            $plumbing.Add('ConfigureStartPins JSON missing Windows Terminal baseline') | Out-Null
        }
        # Optional app shortcuts may be missing (install lag / soft-skip) — warn, do not fail Smoke.
        foreach ($appId in $expectedStart) {
            $display = Get-WinMintVmPinDisplayName -Id $appId
            if ($startPinsJson -notmatch [regex]::Escape($display) -and $startPinsJson -notmatch [regex]::Escape($appId)) {
                $warnings.Add("ConfigureStartPins JSON missing selected app '$appId' ($display)") | Out-Null
            }
        }
        $skipped = @($ShellPins.skipped | ForEach-Object { [string]$_ } | Where-Object { $_ })
        if ($skipped.Count -gt 0) {
            $warnings.Add("Shell pins skipped (no shortcut/exe): $($skipped -join ', ')") | Out-Null
        }
        if ([int]$ShellPins.taskbarShortcutCount -lt @($expectedTaskbar).Count) {
            $warnings.Add("Taskbar shortcut count $($ShellPins.taskbarShortcutCount) < expected $($expectedTaskbar.Count)") | Out-Null
        }
    }

    [pscustomobject]@{
        plumbingOk       = ($plumbing.Count -eq 0)
        plumbingFailures = @($plumbing)
        warnings         = @($warnings)
        meta             = $meta
    }
}
