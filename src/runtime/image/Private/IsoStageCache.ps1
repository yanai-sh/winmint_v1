#Requires -Version 7.6

<#
.SYNOPSIS
    Temp cache of the post-stage ISO folder (sources\install.wim|esd) to speed repeat builds.
.NOTES
    - One active slot under %LOCALAPPDATA%\WinMint\cache\iso-stage (publishing replaces any prior entry).
    - Identity = full path + length + SHA256 of the source ISO.
    - Default max age 48h; stale entries removed on maintenance and on read miss.
#>

$script:WinMintIsoStageCacheTtlHours = 48
$script:WinMintIsoStageCacheMarkerName = '.winmint-iso-stage.json'

function Get-WinMintIsoStageCacheRoot {
    $root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WinMint\cache\iso-stage'
    return $root
}

function New-WinMintIsoStageCacheRoot {
    $root = Get-WinMintIsoStageCacheRoot
    if (-not (Test-Path -LiteralPath $root)) {
        $null = New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop
    }
    return $root
}

function Get-WinMintIsoStageCacheKeyHex {
    param([Parameter(Mandatory)][string]$Fingerprint)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Fingerprint))
    }
    finally {
        $sha.Dispose()
    }
    return ([System.BitConverter]::ToString($bytes) -replace '-', '').Substring(0, 24).ToLowerInvariant()
}

function Get-WinMintIsoStageCacheFingerprint {
    param([Parameter(Mandatory)][string]$SourceIsoPath)
    $item = Get-Item -LiteralPath $SourceIsoPath -ErrorAction Stop
    $full = $item.FullName
    $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    return "$full|$($item.Length)|$hash"
}

function Test-WinMintIsoStageCacheMarkerFresh {
    param([Parameter(Mandatory)][string]$MarkerPath)
    if (-not (Test-Path -LiteralPath $MarkerPath)) { return $false }
    try {
        $meta = Get-Content -LiteralPath $MarkerPath -Raw -ErrorAction Stop | ConvertFrom-Json
        $raw = $meta.SavedUtc
        if ($raw -is [datetime]) {
            $saved = [datetime]$raw
            if ($saved.Kind -eq [DateTimeKind]::Unspecified) {
                $saved = [datetime]::SpecifyKind($saved, [DateTimeKind]::Utc)
            }
            else {
                $saved = $saved.ToUniversalTime()
            }
        }
        else {
            $saved = [datetime]::Parse(
                [string]$raw,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind
            ).ToUniversalTime()
        }
        $age = [datetime]::UtcNow - $saved
        return ($age.TotalHours -lt $script:WinMintIsoStageCacheTtlHours)
    }
    catch {
        return $false
    }
}

function Remove-WinMintIsoStageCacheDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    }
    catch {
        LogVerbose "IsoStageCache: could not remove '$Path': $($_.Exception.Message)"
    }
}

function Invoke-WinMintIsoStageCacheMaintenance {
    <#
    .SYNOPSIS
        Drops expired cache folders (TTL) and broken markers. Safe to call from startup cleanup.
    #>
    $root = Get-WinMintIsoStageCacheRoot
    if (-not (Test-Path -LiteralPath $root)) { return }
    foreach ($child in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        $marker = Join-Path $child.FullName $script:WinMintIsoStageCacheMarkerName
        if (-not (Test-Path -LiteralPath $marker)) {
            Remove-WinMintIsoStageCacheDirectory -Path $child.FullName
            continue
        }
        if (-not (Test-WinMintIsoStageCacheMarkerFresh -MarkerPath $marker)) {
            Remove-WinMintIsoStageCacheDirectory -Path $child.FullName
        }
    }
}

function Test-WinMintIsoStageCacheBootLayout {
    param([Parameter(Mandatory)][string]$CacheDir)

    $efisysRel = if (Test-Path -LiteralPath (Join-Path $CacheDir 'efi\microsoft\boot\efisys_noprompt.bin')) {
        'efi\microsoft\boot\efisys_noprompt.bin'
    }
    else {
        'efi\microsoft\boot\efisys.bin'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $CacheDir $efisysRel))) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $CacheDir 'sources\boot.wim'))) { return $false }
    return $true
}

function Get-WinMintIsoStageCacheHit {
    param([Parameter(Mandatory)][string]$SourceIsoPath)
    Invoke-WinMintIsoStageCacheMaintenance

    if (-not (Test-Path -LiteralPath $SourceIsoPath)) { return $null }

    $fp = Get-WinMintIsoStageCacheFingerprint -SourceIsoPath $SourceIsoPath
    $key = Get-WinMintIsoStageCacheKeyHex -Fingerprint $fp
    $dir = Join-Path (Get-WinMintIsoStageCacheRoot) $key
    $marker = Join-Path $dir $script:WinMintIsoStageCacheMarkerName

    if (-not (Test-Path -LiteralPath $marker)) { return $null }
    if (-not (Test-WinMintIsoStageCacheMarkerFresh -MarkerPath $marker)) {
        Remove-WinMintIsoStageCacheDirectory -Path $dir
        return $null
    }

    try {
        $meta = Get-Content -LiteralPath $marker -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
        Remove-WinMintIsoStageCacheDirectory -Path $dir
        return $null
    }

    $item = Get-Item -LiteralPath $SourceIsoPath -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    if ([string]$meta.FullPath -ne $item.FullName) { return $null }
    if ([long]$meta.Length -ne $item.Length) { return $null }
    $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ([string]$meta.Sha256 -ne $hash) { return $null }

    # Cache is published only after ESD→WIM so DISM-serviced layout is always install.wim.
    $wim = Join-Path $dir 'sources\install.wim'
    if (-not (Test-Path -LiteralPath $wim)) { return $null }
    if (-not (Test-WinMintIsoStageCacheBootLayout -CacheDir $dir)) {
        Remove-WinMintIsoStageCacheDirectory -Path $dir
        return $null
    }

    return $dir
}

function Publish-WinMintIsoStageCache {
    param(
        [Parameter(Mandatory)][string]$SourceIsoPath,
        [Parameter(Mandatory)][string]$IsoContentsPath
    )

    if (-not (Test-Path -LiteralPath $SourceIsoPath)) { return }
    if (-not (Test-Path -LiteralPath $IsoContentsPath)) { return }

    $wim = Join-Path $IsoContentsPath 'sources\install.wim'
    if (-not (Test-Path -LiteralPath $wim)) { return }

    $dest = $null
    try {
        $root = New-WinMintIsoStageCacheRoot
        foreach ($child in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            Remove-WinMintIsoStageCacheDirectory -Path $child.FullName
        }

        $fp = Get-WinMintIsoStageCacheFingerprint -SourceIsoPath $SourceIsoPath
        $key = Get-WinMintIsoStageCacheKeyHex -Fingerprint $fp
        $dest = Join-Path $root $key
        if (Test-Path -LiteralPath $dest) { Remove-WinMintIsoStageCacheDirectory -Path $dest }
        $null = New-Item -ItemType Directory -Path $dest -Force -ErrorAction Stop

        Invoke-RobocopyChecked -Source $IsoContentsPath -Dest $dest -UserFacingMessage 'Saving staged ISO cache...'

        $item = Get-Item -LiteralPath $SourceIsoPath -ErrorAction Stop
        $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $marker = [ordered]@{
            FullPath          = $item.FullName
            Length            = $item.Length
            Sha256            = $hash
            SavedUtc          = [datetime]::UtcNow.ToString('o')
            Schema            = 2
        }
        $markerPath = Join-Path $dest $script:WinMintIsoStageCacheMarkerName
        [System.IO.File]::WriteAllText(
            $markerPath,
            ($marker | ConvertTo-Json -Compress),
            [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        LogVerbose "IsoStageCache publish skipped: $($_.Exception.Message)"
        if ($null -ne $dest -and (Test-Path -LiteralPath $dest)) { Remove-WinMintIsoStageCacheDirectory -Path $dest }
    }
}

