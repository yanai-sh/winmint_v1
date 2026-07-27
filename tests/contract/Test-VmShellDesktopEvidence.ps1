#Requires -Version 7.6
<#
.SYNOPSIS
    Host-side Terminal/pin acceptance scorer must fail closed on bad evidence.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$failures = [System.Collections.Generic.List[string]]::new()

function Add-ShellEvidenceFailure {
    param([string]$Message)
    $script:failures.Add($Message) | Out-Null
}

. (Join-Path $root 'tools\vm\lib\VmShellDesktopEvidence.ps1')

$sl7 = Get-Content -LiteralPath (Join-Path $root 'tests\profiles\hyper-v-sl7-smoke-arm64.json') -Raw | ConvertFrom-Json

# --- Red: empty evidence must fail plumbing ---
$empty = Test-WinMintVmShellDesktopEvidence -BuildProfile $sl7 -EvidenceDir ''
if ($empty.plumbingOk) {
    Add-ShellEvidenceFailure 'Empty evidence must not pass SL7 shell-desktop plumbing.'
}
foreach ($needle in @(
        'Terminal settings.json missing'
        'FirstLogon_ShellPins.json missing'
        'terminalProfile=mock'
    )) {
    if (-not (@($empty.plumbingFailures) -match [regex]::Escape($needle)).Count) {
        Add-ShellEvidenceFailure "Empty SL7 score should mention '$needle'."
    }
}

# --- Green: fixture matching SL7 expectations ---
$fx = Join-Path ([System.IO.Path]::GetTempPath()) ("winmint-shell-ev-" + [guid]::NewGuid().ToString('n'))
$logs = Join-Path $fx 'ProgramData-Logs'
$termDir = Join-Path $fx 'LocalAppData-Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
$null = New-Item -ItemType Directory -Path $logs -Force
$null = New-Item -ItemType Directory -Path $termDir -Force

$startPinsJson = (@{
        pinnedList = @(
            @{ desktopAppId = 'Microsoft.Windows.Explorer' }
            @{ packagedAppId = 'windows.immutablecontrolpanel' }
            @{ packagedAppId = 'Microsoft.WindowsTerminal_8wekyb3d8bbwe!App' }
            @{ desktopAppLink = 'C:\Users\dev\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Zen Browser.lnk' }
            @{ desktopAppLink = 'C:\Users\dev\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Cursor.lnk' }
        )
    } | ConvertTo-Json -Compress -Depth 6)

@{
    startAppIds          = @('zen-browser', 'cursor')
    taskbarAppIds        = @('zen-browser', 'cursor')
    pinEdgeToStart       = $false
    pinEdgeToTaskbar     = $false
    startPinsJson        = $startPinsJson
    taskbarLayoutPath    = 'C:\Users\dev\AppData\Local\Microsoft\Windows\Shell\LayoutModification.xml'
    taskbarShortcutCount = 2
    skipped              = @()
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $logs 'FirstLogon_ShellPins.json') -Encoding UTF8

'2026-07-19T00:00:00 terminalProfile=mock WSL Terminal profile(s) staged for diagnostics.wslRuntimeValidation=skip: FedoraLinux' |
    Set-Content -LiteralPath (Join-Path $logs 'FirstLogon.log') -Encoding UTF8

@{
    centerOnLaunch = $true
    launchMode     = 'default'
    profiles       = @{
        defaults = @{
            opacity     = 80
            colorScheme = 'One Half Dark'
            bellStyle   = 'none'
        }
        list     = @(
            @{ name = 'PowerShell'; commandline = 'pwsh.exe -NoLogo' }
            @{ name = 'Fedora'; commandline = 'wsl.exe -d FedoraLinux'; icon = '%LOCALAPPDATA%\WinMint\TerminalIcons\fedora.png'; pathTranslationStyle = 'wsl' }
        )
    }
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $termDir 'settings.json') -Encoding UTF8

try {
    $green = Test-WinMintVmShellDesktopEvidence -BuildProfile $sl7 -EvidenceDir $fx
    if (-not $green.plumbingOk) {
        Add-ShellEvidenceFailure ("Green SL7 fixture should pass plumbing; failures: " + ($green.plumbingFailures -join ' | '))
    }

    # --- Red: leftover Terminal profiles must fail ---
    $badTerm = Get-Content -LiteralPath (Join-Path $termDir 'settings.json') -Raw | ConvertFrom-Json
    $badTerm.profiles.list = @(
        $badTerm.profiles.list
        @{ name = 'Command Prompt' }
    )
    $badTerm | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $termDir 'settings.json') -Encoding UTF8
    $leftover = Test-WinMintVmShellDesktopEvidence -BuildProfile $sl7 -EvidenceDir $fx
    if ($leftover.plumbingOk -or -not (@($leftover.plumbingFailures) -match 'hard-replace mismatch').Count) {
        Add-ShellEvidenceFailure 'Leftover Command Prompt profile must fail hard-replace plumbing.'
    }

    # --- Red: Edge on taskbar when zen also selected ---
    $pins = Get-Content -LiteralPath (Join-Path $logs 'FirstLogon_ShellPins.json') -Raw | ConvertFrom-Json
    $pins.taskbarAppIds = @('zen-browser', 'edge', 'cursor')
    $pins.pinEdgeToTaskbar = $true
    $pins | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $logs 'FirstLogon_ShellPins.json') -Encoding UTF8
    # restore good terminal for this case
    @{
        centerOnLaunch = $true
        launchMode     = 'default'
        profiles       = @{
            defaults = @{ opacity = 80; colorScheme = 'One Half Dark' }
            list     = @(
                @{ name = 'PowerShell' }
                @{ name = 'Fedora' }
            )
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $termDir 'settings.json') -Encoding UTF8
    $edgeBad = Test-WinMintVmShellDesktopEvidence -BuildProfile $sl7 -EvidenceDir $fx
    if ($edgeBad.plumbingOk -or -not (@($edgeBad.plumbingFailures) -match 'taskbarAppIds|pinEdgeToTaskbar').Count) {
        Add-ShellEvidenceFailure 'Edge on taskbar with zen-browser must fail pin plumbing.'
    }

    # --- Soft: optional shortcuts skipped must warn, not fail plumbing ---
    $pins = Get-Content -LiteralPath (Join-Path $logs 'FirstLogon_ShellPins.json') -Raw | ConvertFrom-Json
    $pins.taskbarAppIds = @('zen-browser', 'cursor')
    $pins.pinEdgeToTaskbar = $false
    $pins.startPinsJson = (@{
            pinnedList = @(
                @{ desktopAppId = 'Microsoft.Windows.Explorer' }
                @{ packagedAppId = 'windows.immutablecontrolpanel' }
                @{ packagedAppId = 'Microsoft.WindowsTerminal_8wekyb3d8bbwe!App' }
            )
        } | ConvertTo-Json -Compress -Depth 6)
    $pins.taskbarShortcutCount = 0
    $pins.skipped = @('zen-browser', 'cursor')
    $pins | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $logs 'FirstLogon_ShellPins.json') -Encoding UTF8
    $softSkip = Test-WinMintVmShellDesktopEvidence -BuildProfile $sl7 -EvidenceDir $fx
    if (-not $softSkip.plumbingOk) {
        Add-ShellEvidenceFailure ("Optional pin soft-skip should keep plumbing OK; failures: " + ($softSkip.plumbingFailures -join ' | '))
    }
    if (-not (@($softSkip.warnings) -match 'skipped|shortcut count|missing selected app').Count) {
        Add-ShellEvidenceFailure 'Optional pin soft-skip should emit warnings for skipped apps / missing shortcuts.'
    }
}
finally {
    Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
}

# Lean smoke (no WSL distros): mock log not required
$lean = Get-Content -LiteralPath (Join-Path $root 'tests\profiles\hyper-v-smoke-arm64.json') -Raw | ConvertFrom-Json
$leanEmpty = Test-WinMintVmShellDesktopEvidence -BuildProfile $lean -EvidenceDir ''
if ((@($leanEmpty.plumbingFailures) -match 'terminalProfile=mock').Count -gt 0) {
    Add-ShellEvidenceFailure 'Lean smoke with empty WSL distros must not require terminalProfile=mock.'
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "FAIL $_" }
    exit 1
}

Write-Host 'VM shell desktop evidence contract: OK'
exit 0
