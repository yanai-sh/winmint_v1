#Requires -Version 7.6

function Resolve-AgentWindhawkInstallRoot {
    if ($script:WinMintWindhawkInstallRootOverride) {
        return [string]$script:WinMintWindhawkInstallRootOverride
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles 'Windhawk')) }
    if (${env:ProgramFiles(x86)}) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Windhawk')) }

    if (-not $script:WinMintAgentFastWaits) {
        $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='Windhawk'" -ErrorAction SilentlyContinue
        if ($svc -and $svc.PathName) {
            $pathName = [string]$svc.PathName
            $exePath = if ($pathName -match '^\s*"([^"]+)"') { $matches[1] } else { ($pathName -split '\s+', 2)[0] }
            if ($exePath -and (Split-Path -Parent $exePath)) {
                $candidates.Add((Split-Path -Parent $exePath))
            }
        }

        foreach ($root in @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
            )) {
            Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.PSObject.Properties['DisplayName'] -and
                    $_.PSObject.Properties['InstallLocation'] -and
                    $_.DisplayName -eq 'Windhawk' -and
                    $_.InstallLocation
                } |
                ForEach-Object { $candidates.Add([string]$_.InstallLocation) }
        }
    }

    foreach ($candidate in ($candidates.ToArray() | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'windhawk.exe')) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

function Test-AgentWindhawkInstalled {
    param([string]$InstallRoot)

    $programWindhawk = if ($InstallRoot) { Join-Path $InstallRoot 'windhawk.exe' } else { $null }
    if ($programWindhawk -and (Test-Path -LiteralPath $programWindhawk)) { return $true }
    if ($script:WinMintAgentFastWaits -or $script:WinMintWindhawkInstallRootOverride) { return $false }
    return [bool](Get-Service -Name 'Windhawk' -ErrorAction SilentlyContinue)
}

function Get-WinMintWindhawkPresetEvidencePath {
    param([Parameter(Mandatory)][string]$WindhawkRoot)

    return (Join-Path $WindhawkRoot 'WinMint\preset-application.json')
}

function Read-WinMintWindhawkPresetEvidence {
    param(
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][string]$PresetFile,
        [Parameter(Mandatory)][string]$InstallRoot
    )

    if (-not (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) {
        throw "Windhawk preset evidence marker was not written: $EvidencePath"
    }

    $evidence = Get-Content -LiteralPath $EvidencePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $evidence -or [string]$evidence.status -ne 'ok') {
        throw "Windhawk preset evidence marker is not ok: $EvidencePath"
    }

    $expectedPreset = [System.IO.Path]::GetFullPath($PresetFile)
    $actualPreset = [System.IO.Path]::GetFullPath([string]$evidence.presetPath)
    if (-not [string]::Equals($actualPreset, $expectedPreset, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Windhawk preset evidence points at an unexpected preset: $actualPreset"
    }

    $expectedInstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
    $actualInstallRoot = [System.IO.Path]::GetFullPath([string]$evidence.installRoot)
    if (-not [string]::Equals($actualInstallRoot, $expectedInstallRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Windhawk preset evidence points at an unexpected install root: $actualInstallRoot"
    }

    $rawTs = $evidence.timestamp
    if ($null -eq $rawTs) {
        throw "Windhawk preset evidence marker has no timestamp: $EvidencePath"
    }
    # ConvertFrom-Json may materialize ISO stamps as DateTime; casting to string then uses CurrentCulture.
    if ($rawTs -is [datetime] -or $rawTs -is [datetimeoffset]) {
        return $evidence
    }
    if ([string]::IsNullOrWhiteSpace([string]$rawTs)) {
        throw "Windhawk preset evidence marker has no timestamp: $EvidencePath"
    }
    $parsed = [datetimeoffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
            [string]$rawTs,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed)) {
        throw "Windhawk preset evidence timestamp is not parseable: $rawTs"
    }

    return $evidence
}

function Invoke-WinMintAgentWindhawkBootstrap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$AgentProfile,
        [Parameter(Mandatory)][hashtable]$State
    )

    $cfg = if ($AgentProfile.modules -and $AgentProfile.modules.PSObject.Properties['windhawk']) {
        $AgentProfile.modules.windhawk
    } else {
        $null
    }
    if (-not $cfg -or -not [bool]$cfg.enabled) {
        return [pscustomobject]@{
            Id      = 'windhawk'
            Status  = 'skipped'
            Message = 'Windhawk was not selected.'
        }
    }

    $payloadDir = Join-Path (Get-WinMintAgentContext).AgentRoot 'Assets\Windhawk'
    $restoreScript = Join-Path $payloadDir 'WindhawkBootstrap.ps1'
    $presetFile = Join-Path $payloadDir 'preset.json'
    if (-not (Test-Path -LiteralPath $restoreScript)) { throw "Windhawk restore script missing: $restoreScript" }
    if (-not (Test-Path -LiteralPath $presetFile)) { throw "Windhawk preset missing: $presetFile" }

    $windhawkRoot = Join-Path $env:PROGRAMDATA 'Windhawk'
    $windhawkInstallRoot = Resolve-AgentWindhawkInstallRoot
    $installed = Test-AgentWindhawkInstalled -InstallRoot $windhawkInstallRoot
    if (-not $installed) {
        Install-AgentManifestTool -ToolId 'windhawk' -State $State
    }

    $ready = $false
    $waitAttempts = if ($script:WinMintAgentFastWaits) { 1 } else { 30 }
    for ($i = 0; $i -lt $waitAttempts; $i++) {
        $windhawkInstallRoot = Resolve-AgentWindhawkInstallRoot
        if (Test-AgentWindhawkInstalled -InstallRoot $windhawkInstallRoot) {
            $ready = $true
            break
        }
        if (-not $script:WinMintAgentFastWaits) { Start-Sleep -Seconds 2 }
    }
    if (-not $ready) { throw 'Windhawk did not appear to install within the expected wait window.' }
    if (-not $windhawkInstallRoot) { throw 'Windhawk install path could not be resolved.' }

    $exe = Resolve-AgentPowerShellHost
    $evidencePath = Get-WinMintWindhawkPresetEvidencePath -WindhawkRoot $windhawkRoot
    Remove-Item -LiteralPath $evidencePath -Force -ErrorAction SilentlyContinue
    Invoke-AgentNative -FilePath $exe -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $restoreScript,
        '-PresetFile', $presetFile,
        '-WindhawkRoot', $windhawkRoot,
        '-WindhawkInstallRoot', $windhawkInstallRoot,
        '-EvidencePath', $evidencePath
    )
    $evidence = Read-WinMintWindhawkPresetEvidence -EvidencePath $evidencePath -PresetFile $presetFile -InstallRoot $windhawkInstallRoot

    $requiredStateSteps = @('shell:windhawk-preset')
    $State.steps['shell:windhawk-preset'] = @{
        status = 'ok'
        updatedAt = (Get-Date -Format o)
        installRoot = $windhawkInstallRoot
        windhawkRoot = $windhawkRoot
        presetFile = $presetFile
        evidencePath = $evidencePath
        evidenceTimestamp = [string]$evidence.timestamp
    }
    Save-AgentState -State $State

    [pscustomobject]@{
        Id                 = 'windhawk'
        Status             = 'ok'
        Message            = 'Windhawk installed with the WinMint preset.'
        RequiredStateSteps = $requiredStateSteps
    }
}

