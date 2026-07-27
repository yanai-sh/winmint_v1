#Requires -Version 7.6

<#
.SYNOPSIS
    TTL-bounded temp caches for expensive build intermediates (host driver export, MSI extracts,
    Cascadia Nerd Font TTFs after a successful GitHub download).
.NOTES
    Lives under %LOCALAPPDATA%\WinMint\cache\ alongside iso-stage. Default TTL 48h; maintenance
    runs on cache probes and from startup cleanup. Host-driver export uses a single-slot policy
    (one cached export per machine) to cap disk use; MSI bundle caches are keyed per MSI set.
    Cascadia cache is single-slot (replaces prior entry on publish) and skips GitHub + zip work.
#>

$script:WinMintIntermediatesCacheTtlHours = 48

function Get-WinMintBuildCacheRoot {
    return (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WinMint\cache')
}

function Get-WinMintCacheKeyHex {
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

function Test-WinMintIntermediatesCacheMarkerFileFresh {
    param([Parameter(Mandatory)][string]$MarkerJsonPath)
    if (-not (Test-Path -LiteralPath $MarkerJsonPath)) { return $false }
    try {
        $meta = Get-Content -LiteralPath $MarkerJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json
        $raw = $meta.SavedUtc
        # ConvertFrom-Json may materialize ISO stamps as DateTime; [string] then uses CurrentCulture
        # and Roundtrip Parse fails (e.g. he-IL host → "07/27/2026 …").
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
        return (([datetime]::UtcNow - $saved).TotalHours -lt $script:WinMintIntermediatesCacheTtlHours)
    }
    catch {
        return $false
    }
}

function Remove-WinMintIntermediatesCacheTree {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    }
    catch {
        LogVerbose "IntermediatesCache: could not remove '$Path': $($_.Exception.Message)"
    }
}

function Invoke-WinMintKeyedJsonMarkerCacheMaintenance {
    param([Parameter(Mandatory)][string]$CacheSubdir)

    $root = Join-Path (Get-WinMintBuildCacheRoot) $CacheSubdir
    if (-not (Test-Path -LiteralPath $root)) { return }
    foreach ($json in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        if (-not (Test-WinMintIntermediatesCacheMarkerFileFresh -MarkerJsonPath $json.FullName)) {
            $key = [IO.Path]::GetFileNameWithoutExtension($json.Name)
            Remove-WinMintIntermediatesCacheTree -Path (Join-Path $root $key)
            Remove-Item -LiteralPath $json.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        $marker = Join-Path $root ($dir.Name + '.json')
        if (-not (Test-Path -LiteralPath $marker)) {
            Remove-WinMintIntermediatesCacheTree -Path $dir.FullName
        }
    }
}

function Invoke-WinMintDriverMsiBundleCacheMaintenance {
    Invoke-WinMintKeyedJsonMarkerCacheMaintenance -CacheSubdir 'driver-msi-bundle'
}

function Invoke-WinMintDriverMsiSingleCacheMaintenance {
    Invoke-WinMintKeyedJsonMarkerCacheMaintenance -CacheSubdir 'driver-msi-single'
}

function Invoke-WinMintHostDriverExportCacheMaintenance {
    Invoke-WinMintKeyedJsonMarkerCacheMaintenance -CacheSubdir 'host-drivers'
}

function Invoke-WinMintAllBuildCachesMaintenance {
    Invoke-WinMintIsoStageCacheMaintenance
    Invoke-WinMintHostDriverExportCacheMaintenance
    Invoke-WinMintDriverMsiBundleCacheMaintenance
    Invoke-WinMintDriverMsiSingleCacheMaintenance
    Invoke-WinMintCascadiaNerdFontCacheMaintenance
    Invoke-WinMintServicedWimCacheMaintenance
}

# --- Serviced install.wim cache --------------------------------------------------
#
# Memoizes the post-Service-WIM install.wim so iterative builds can skip the
# 30-60 min DISM mount/inject/dismount loop when servicing inputs are unchanged.
# Personalization (autounattend, timezone, account) is intentionally NOT in the
# fingerprint — those are re-stamped per build in a short post-restore pass.
#
# Bump $script:WinMintServicedWimCacheSchemaVersion whenever the servicing pipeline
# changes in a way the fingerprint can't naturally observe (new helper, changed
# DISM call order, etc.). A bump invalidates all existing entries.

# Bump when the serviced-image pipeline changes in a way that can leave cached
# WIMs semantically stale even if the broad inputs look unchanged.
$script:WinMintServicedWimCacheSchemaVersion = 18

function Get-WinMintServicedWimCacheRoot {
    return (Join-Path (Get-WinMintBuildCacheRoot) 'serviced-wim')
}

function Get-WinMintServicingToolchainIdentity {
    $dism = if (Get-Command Get-WinMintDismExeVersion -ErrorAction SilentlyContinue) {
        [string](Get-WinMintDismExeVersion)
    }
    else {
        $line = (& dism.exe /English /? 2>&1 | Where-Object { $_ -match 'Version:\s*([0-9.]+)' } | Select-Object -First 1)
        if ($line -match 'Version:\s*([0-9.]+)') { $matches[1] } else { 'unknown' }
    }
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    [ordered]@{
        DismVersion = $dism
        HostBuild = if ($cv) { "$($cv.CurrentBuild).$($cv.UBR)" } else { 'unknown' }
        HostDisplayVersion = if ($cv) { [string]$cv.DisplayVersion } else { 'unknown' }
        ServicingSchema = $script:WinMintServicedWimCacheSchemaVersion
    }
}

function Get-WinMintDriverPayloadFingerprint {
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        return "$($item.FullName)|$($item.Length)|$hash"
    }

    $extensions = @('.inf', '.sys', '.cat', '.dll', '.exe', '.msi', '.zip')
    $root = $item.FullName.TrimEnd('\', '/')
    $parts = @(
        Get-ChildItem -LiteralPath $item.FullName -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } |
            Sort-Object FullName |
            ForEach-Object {
                $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/').ToLowerInvariant()
                $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                "$rel|$($_.Length)|$hash"
            }
    )
    return "dir|$($item.FullName)|$($parts -join ';')"
}

function Get-WinMintUpdatePayloadFingerprint {
    param([AllowNull()]$Updates)

    if ($null -eq $Updates -or [string]$Updates.Mode -eq 'None') { return 'None' }
    $root = [string]$Updates.PayloadRoot
    if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) {
        return "$([string]$Updates.Mode)|<unresolved>"
    }

    $parts = @(
        Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.msu', '.cab', '.msixbundle', '.appxbundle', '.msix', '.appx') } |
            Sort-Object FullName |
            ForEach-Object {
                $rel = $_.FullName.Substring($root.TrimEnd('\', '/').Length).TrimStart('\', '/').ToLowerInvariant()
                $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                "$rel|$($_.Length)|$hash"
            }
    )

    return "$([string]$Updates.Mode)|$([string]$Updates.TargetFeatureVersion)|$([string]$Updates.ReleaseCadence)|$([bool]$Updates.ProvisionedApps)|$($parts -join ';')"
}

function Get-WinMintServicedWimFingerprint {
    param(
        [Parameter(Mandatory)]$BuildConfig,
        [Parameter(Mandatory)][string]$IsoStageKey,
        [ValidateSet('Max', 'Fast', 'None')][string]$ImageCompression = 'Max'
    )

    $sortedOrEmpty = {
        param($arr)
        if ($null -eq $arr) { return @() }
        return (@($arr) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    }

    $driversFp = ''
    try {
        $src = [string]$BuildConfig.Drivers.Source
        $path = [string]$BuildConfig.Drivers.Path
        if (Test-WinMintDriverSourceUsesHostExport -Source $src) {
            $driversFp = "Host|$((Get-WinMintHostDriverExportFingerprint))"
        }
        elseif ((Test-WinMintDriverSourceUsesPath -Source $src) -and -not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
            $driversFp = "$src|$(Get-WinMintDriverPayloadFingerprint -Path $path)"
        }
        else {
            $driversFp = "$src|"
        }
    }
    catch {
        $driversFp = "$([string]$BuildConfig.Drivers.Source)|<unresolved>"
    }

    $updatesConfig = if ($BuildConfig.PSObject.Properties['Updates']) { $BuildConfig.Updates } else { $null }
    # Max implies StartComponentCleanup; Fast/None skip it. Include the lane so a
    # Max-published WIM is never reused for a Fast assemble (or the reverse).
    $componentCleanup = if ($ImageCompression -eq 'Max') { 'StartComponentCleanup' } else { 'Skipped' }
    $payload = [ordered]@{
        Schema             = $script:WinMintServicedWimCacheSchemaVersion
        Toolchain          = Get-WinMintServicingToolchainIdentity
        IsoStageKey        = $IsoStageKey
        Architecture       = [string]$BuildConfig.Architecture
        EditionMode        = [string]$BuildConfig.EditionMode
        Edition            = [string]$BuildConfig.Edition
        AppxCatalogVersion = [int]$BuildConfig.AppxCatalogVersion
        Appx               = (& $sortedOrEmpty $BuildConfig.AppxPackages)
        AiRemovalPolicy    = [string]$BuildConfig.AiRemoval.Policy
        AiCatalogVersion   = [int]$BuildConfig.AiRemoval.CatalogVersion
        AiAppx             = (& $sortedOrEmpty $BuildConfig.AiRemoval.AppxPrefixes)
        AiOptionalFeatures = (& $sortedOrEmpty $BuildConfig.AiRemoval.OptionalFeatures)
        RegistryTweaks     = (& $sortedOrEmpty $BuildConfig.RegistryTweaks)
        Features           = (& $sortedOrEmpty $BuildConfig.Features)
        CursorPackKind     = [string]$BuildConfig.CursorPackKind
        InputLocale        = [string]$BuildConfig.InputLocale
        SystemLocale       = [string]$BuildConfig.SystemLocale
        UILanguage         = [string]$BuildConfig.UILanguage
        UILanguageFallback = [string]$BuildConfig.UILanguageFallback
        UserLocale         = [string]$BuildConfig.UserLocale
        SetupUserLocale    = [string]$BuildConfig.SetupUserLocale
        Drivers            = $driversFp
        Updates            = Get-WinMintUpdatePayloadFingerprint -Updates $updatesConfig
        ImageCompression   = $ImageCompression
        ComponentCleanup   = $componentCleanup
    }
    return ($payload | ConvertTo-Json -Compress -Depth 4)
}

function Invoke-WinMintServicedWimCacheMaintenance {
    $root = Get-WinMintServicedWimCacheRoot
    if (-not (Test-Path -LiteralPath $root)) { return }
    foreach ($json in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        if (-not (Test-WinMintIntermediatesCacheMarkerFileFresh -MarkerJsonPath $json.FullName)) {
            $key = [IO.Path]::GetFileNameWithoutExtension($json.Name)
            Remove-Item -LiteralPath (Join-Path $root "$key.wim") -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $json.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($wim in @(Get-ChildItem -LiteralPath $root -Filter '*.wim' -File -ErrorAction SilentlyContinue)) {
        $marker = Join-Path $root ([IO.Path]::GetFileNameWithoutExtension($wim.Name) + '.json')
        if (-not (Test-Path -LiteralPath $marker)) {
            Remove-Item -LiteralPath $wim.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function ConvertTo-WinMintCacheMetadataJson {
    param([object[]]$Value)
    if ($null -eq $Value) { return '' }
    return ($Value | ConvertTo-Json -Compress -Depth 8)
}

function Get-WinMintServicedWimCacheHit {
    param(
        [Parameter(Mandatory)][string]$Fingerprint,
        [object[]]$ExpectedMetadata = @()
    )
    Invoke-WinMintServicedWimCacheMaintenance
    if ([string]::IsNullOrWhiteSpace($Fingerprint)) { return $null }
    $key = Get-WinMintCacheKeyHex -Fingerprint $Fingerprint
    $root = Get-WinMintServicedWimCacheRoot
    $markerPath = Join-Path $root "$key.json"
    $wimPath = Join-Path $root "$key.wim"
    if (-not (Test-Path -LiteralPath $markerPath)) { return $null }
    if (-not (Test-Path -LiteralPath $wimPath)) { return $null }
    if (-not (Test-WinMintIntermediatesCacheMarkerFileFresh -MarkerJsonPath $markerPath)) {
        Remove-Item -LiteralPath $wimPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
        return $null
    }
    try {
        $meta = Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
        return $null
    }
    if ([string]$meta.Fingerprint -ne $Fingerprint) { return $null }
    if ([int]$meta.Schema -ne $script:WinMintServicedWimCacheSchemaVersion) { return $null }
    if (@($ExpectedMetadata).Count -gt 0) {
        if (-not ($meta.PSObject.Properties.Name -contains 'ExpectedMetadata')) { return $null }
        if ((ConvertTo-WinMintCacheMetadataJson @($meta.ExpectedMetadata)) -ne (ConvertTo-WinMintCacheMetadataJson @($ExpectedMetadata))) { return $null }
    }
    return $wimPath
}

function Publish-WinMintServicedWimCache {
    param(
        [Parameter(Mandatory)][string]$Fingerprint,
        [Parameter(Mandatory)][string]$ServicedWimPath,
        [object[]]$ExpectedMetadata = @()
    )
    if ([string]::IsNullOrWhiteSpace($Fingerprint)) { return }
    if (-not (Test-Path -LiteralPath $ServicedWimPath)) { return }

    $key = $null
    $root = Get-WinMintServicedWimCacheRoot
    try {
        Invoke-WinMintServicedWimCacheMaintenance
        if (-not (Test-Path -LiteralPath $root)) {
            $null = New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop
        }
        # Single-slot policy: this cache holds one (~5 GB) WIM at a time.
        foreach ($f in @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        }
        $key = Get-WinMintCacheKeyHex -Fingerprint $Fingerprint
        $destWim = Join-Path $root "$key.wim"
        $markerPath = Join-Path $root "$key.json"

        Log "Saving temp cache of serviced install.wim for faster rebuilds (~5 GB)…"
        Copy-Item -LiteralPath $ServicedWimPath -Destination $destWim -Force -ErrorAction Stop

        $sourceItem = Get-Item -LiteralPath $ServicedWimPath
        $marker = [ordered]@{
            Schema       = $script:WinMintServicedWimCacheSchemaVersion
            Kind         = 'serviced-wim'
            Fingerprint  = $Fingerprint
            SavedUtc     = [datetime]::UtcNow.ToString('o')
            SourceBytes  = $sourceItem.Length
            Toolchain    = Get-WinMintServicingToolchainIdentity
            ExpectedMetadata = @($ExpectedMetadata)
        }
        $marker | ConvertTo-Json -Compress -Depth 8 | Set-Content -LiteralPath $markerPath -Encoding UTF8
    }
    catch {
        LogVerbose "serviced-wim cache publish skipped: $($_.Exception.Message)"
        if ($null -ne $key) {
            Remove-Item -LiteralPath (Join-Path $root "$key.wim") -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $root "$key.json") -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-WinMintDriverMsiSetFingerprint {
    param([Parameter(Mandatory)][System.IO.FileInfo[]]$MsiFiles)
    $sorted = @($MsiFiles | Sort-Object -Property FullName)
    return (($sorted | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }) -join ';')
}

function Get-WinMintDriverMsiBundleCacheHit {
    param([Parameter(Mandatory)][string]$Fingerprint)
    Invoke-WinMintDriverMsiBundleCacheMaintenance
    if ([string]::IsNullOrWhiteSpace($Fingerprint)) { return $null }
    $key = Get-WinMintCacheKeyHex -Fingerprint $Fingerprint
    $root = Join-Path (Get-WinMintBuildCacheRoot) 'driver-msi-bundle'
    $markerPath = Join-Path $root "$key.json"
    $bundleDir = Join-Path $root $key
    if (-not (Test-Path -LiteralPath $markerPath)) { return $null }
    if (-not (Test-WinMintIntermediatesCacheMarkerFileFresh -MarkerJsonPath $markerPath)) {
        Remove-WinMintIntermediatesCacheTree -Path $bundleDir
        Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
        return $null
    }
    try {
        $meta = Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
        return $null
    }
    if ([string]$meta.Fingerprint -ne $Fingerprint) { return $null }
    if (-not (Test-Path -LiteralPath $bundleDir -PathType Container)) { return $null }
    $infCount = (Get-ChildItem -LiteralPath $bundleDir -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue | Measure-Object).Count
    if ($infCount -lt 1) { return $null }
    return $bundleDir
}

function Publish-WinMintDriverMsiBundleCache {
    param(
        [Parameter(Mandatory)][string]$Fingerprint,
        [Parameter(Mandatory)][string]$SourceParentDir
    )
    if ([string]::IsNullOrWhiteSpace($Fingerprint)) { return }
    if (-not (Test-Path -LiteralPath $SourceParentDir -PathType Container)) { return }
    $infCount = (Get-ChildItem -LiteralPath $SourceParentDir -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue | Measure-Object).Count
    if ($infCount -lt 1) { return }

    $key = $null
    try {
        Invoke-WinMintDriverMsiBundleCacheMaintenance
        $key = Get-WinMintCacheKeyHex -Fingerprint $Fingerprint
        $root = Join-Path (Get-WinMintBuildCacheRoot) 'driver-msi-bundle'
        if (-not (Test-Path -LiteralPath $root)) {
            $null = New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop
        }
        $markerPath = Join-Path $root "$key.json"
        $bundleDir = Join-Path $root $key
        if (Test-Path -LiteralPath $bundleDir) { Remove-WinMintIntermediatesCacheTree -Path $bundleDir }
        if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue }
        $null = New-Item -ItemType Directory -Path $bundleDir -Force -ErrorAction Stop
        Invoke-RobocopyChecked -Source $SourceParentDir -Dest $bundleDir -UserFacingMessage 'Saving temp cache of driver MSI extracts…'
        $marker = [ordered]@{
            Schema      = 2
            Kind        = 'driver-msi-bundle'
            Fingerprint = $Fingerprint
            SavedUtc    = [datetime]::UtcNow.ToString('o')
        }
        $marker | ConvertTo-Json -Compress | Set-Content -LiteralPath $markerPath -Encoding UTF8
    }
    catch {
        LogVerbose "driver-msi-bundle cache publish skipped: $($_.Exception.Message)"
        if ($null -ne $key) {
            $root = Join-Path (Get-WinMintBuildCacheRoot) 'driver-msi-bundle'
            $bundleDir = Join-Path $root $key
            $markerPath = Join-Path $root "$key.json"
            if (Test-Path -LiteralPath $bundleDir) { Remove-WinMintIntermediatesCacheTree -Path $bundleDir }
            if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Get-WinMintDriverMsiSingleExtractCacheHit {
    param([Parameter(Mandatory)][string]$MsiPath)
    Invoke-WinMintDriverMsiSingleCacheMaintenance
    if (-not (Test-Path -LiteralPath $MsiPath)) { return $null }
    $item = Get-Item -LiteralPath $MsiPath -ErrorAction Stop
    $fingerprint = "$($item.FullName)|$($item.Length)|$($item.LastWriteTimeUtc.Ticks)"
    $key = Get-WinMintCacheKeyHex -Fingerprint $fingerprint
    $root = Join-Path (Get-WinMintBuildCacheRoot) 'driver-msi-single'
    $markerPath = Join-Path $root "$key.json"
    $payloadDir = Join-Path $root $key
    if (-not (Test-Path -LiteralPath $markerPath)) { return $null }
    if (-not (Test-WinMintIntermediatesCacheMarkerFileFresh -MarkerJsonPath $markerPath)) {
        Remove-WinMintIntermediatesCacheTree -Path $payloadDir
        Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
        return $null
    }
    try {
        $meta = Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
        return $null
    }
    if ([string]$meta.Fingerprint -ne $fingerprint) { return $null }
    if (-not (Test-Path -LiteralPath $payloadDir -PathType Container)) { return $null }
    $infCount = (Get-ChildItem -LiteralPath $payloadDir -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue | Measure-Object).Count
    if ($infCount -lt 1) { return $null }
    return $payloadDir
}

function Publish-WinMintDriverMsiSingleExtractCache {
    param(
        [Parameter(Mandatory)][string]$MsiPath,
        [Parameter(Mandatory)][string]$SourceDir
    )
    if (-not (Test-Path -LiteralPath $MsiPath)) { return }
    if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) { return }
    $infCount = (Get-ChildItem -LiteralPath $SourceDir -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue | Measure-Object).Count
    if ($infCount -lt 1) { return }

    $item = Get-Item -LiteralPath $MsiPath -ErrorAction Stop
    $fingerprint = "$($item.FullName)|$($item.Length)|$($item.LastWriteTimeUtc.Ticks)"
    $key = $null
    try {
        Invoke-WinMintDriverMsiSingleCacheMaintenance
        $key = Get-WinMintCacheKeyHex -Fingerprint $fingerprint
        $root = Join-Path (Get-WinMintBuildCacheRoot) 'driver-msi-single'
        if (-not (Test-Path -LiteralPath $root)) {
            $null = New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop
        }
        $markerPath = Join-Path $root "$key.json"
        $payloadDir = Join-Path $root $key
        if (Test-Path -LiteralPath $payloadDir) { Remove-WinMintIntermediatesCacheTree -Path $payloadDir }
        if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue }
        $null = New-Item -ItemType Directory -Path $payloadDir -Force -ErrorAction Stop
        Invoke-RobocopyChecked -Source $SourceDir -Dest $payloadDir -UserFacingMessage 'Saving temp cache of driver MSI extract…'
        $marker = [ordered]@{
            Schema      = 2
            Kind        = 'driver-msi-single'
            Fingerprint = $fingerprint
            SavedUtc    = [datetime]::UtcNow.ToString('o')
        }
        $marker | ConvertTo-Json -Compress | Set-Content -LiteralPath $markerPath -Encoding UTF8
    }
    catch {
        LogVerbose "driver-msi-single cache publish skipped: $($_.Exception.Message)"
        if ($null -ne $key) {
            $root = Join-Path (Get-WinMintBuildCacheRoot) 'driver-msi-single'
            $payloadDir = Join-Path $root $key
            $markerPath = Join-Path $root "$key.json"
            if (Test-Path -LiteralPath $payloadDir) { Remove-WinMintIntermediatesCacheTree -Path $payloadDir }
            if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Get-WinMintHostDriverExportFingerprint {
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $machine = [Environment]::MachineName
    return "${machine}|$($cv.CurrentBuild).$($cv.UBR)|$($cv.DisplayVersion)"
}

function Get-WinMintHostDriverExportCacheHit {
    Invoke-WinMintHostDriverExportCacheMaintenance
    $fingerprint = Get-WinMintHostDriverExportFingerprint
    $key = Get-WinMintCacheKeyHex -Fingerprint $fingerprint
    $root = Join-Path (Get-WinMintBuildCacheRoot) 'host-drivers'
    $markerPath = Join-Path $root "$key.json"
    $payloadDir = Join-Path $root $key
    if (-not (Test-Path -LiteralPath $markerPath)) { return $null }
    if (-not (Test-WinMintIntermediatesCacheMarkerFileFresh -MarkerJsonPath $markerPath)) {
        Remove-WinMintIntermediatesCacheTree -Path $payloadDir
        Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
        return $null
    }
    try {
        $meta = Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
        return $null
    }
    if ([string]$meta.Fingerprint -ne $fingerprint) { return $null }
    if (-not (Test-Path -LiteralPath $payloadDir -PathType Container)) { return $null }
    $infCount = (Get-ChildItem -LiteralPath $payloadDir -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue | Measure-Object).Count
    if ($infCount -lt 1) { return $null }
    return $payloadDir
}

function Publish-WinMintHostDriverExportCache {
    param([Parameter(Mandatory)][string]$SourceDir)
    if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) { return }
    $infCount = (Get-ChildItem -LiteralPath $SourceDir -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue | Measure-Object).Count
    if ($infCount -lt 1) { return }

    $fingerprint = Get-WinMintHostDriverExportFingerprint
    $key = Get-WinMintCacheKeyHex -Fingerprint $fingerprint
    $root = Join-Path (Get-WinMintBuildCacheRoot) 'host-drivers'
    try {
        if (-not (Test-Path -LiteralPath $root)) {
            $null = New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop
        }
        else {
            foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
                Remove-WinMintIntermediatesCacheTree -Path $d.FullName
            }
            foreach ($f in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        $markerPath = Join-Path $root "$key.json"
        $payloadDir = Join-Path $root $key
        $null = New-Item -ItemType Directory -Path $payloadDir -Force -ErrorAction Stop
        Invoke-RobocopyChecked -Source $SourceDir -Dest $payloadDir -UserFacingMessage 'Saving temp cache of exported host drivers…'
        $marker = [ordered]@{
            Schema      = 2
            Kind        = 'host-drivers'
            Fingerprint = $fingerprint
            SavedUtc    = [datetime]::UtcNow.ToString('o')
        }
        $marker | ConvertTo-Json -Compress | Set-Content -LiteralPath $markerPath -Encoding UTF8
    }
    catch {
        LogVerbose "host-drivers cache publish skipped: $($_.Exception.Message)"
        if (Test-Path -LiteralPath $root) {
            foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
                if ($d.Name -eq $key) { Remove-WinMintIntermediatesCacheTree -Path $d.FullName }
            }
            $orphanMarker = Join-Path $root "$key.json"
            if (Test-Path -LiteralPath $orphanMarker) { Remove-Item -LiteralPath $orphanMarker -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Invoke-WinMintCascadiaNerdFontCacheMaintenance {
    $dir = Join-Path (Get-WinMintBuildCacheRoot) 'cascadia-nerdfont'
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $marker = Join-Path $dir 'marker.json'
    if (-not (Test-Path -LiteralPath $marker)) {
        Remove-WinMintIntermediatesCacheTree -Path $dir
        return
    }
    if (-not (Test-WinMintIntermediatesCacheMarkerFileFresh -MarkerJsonPath $marker)) {
        Remove-WinMintIntermediatesCacheTree -Path $dir
    }
}

function Get-WinMintCascadiaNerdFontCachePayloadDir {
    param([Parameter(Mandatory)][string]$CacheRootDir)
    return (Join-Path $CacheRootDir 'ttf')
}

function Get-WinMintCascadiaNerdFontCacheHit {
    Invoke-WinMintCascadiaNerdFontCacheMaintenance
    $dir = Join-Path (Get-WinMintBuildCacheRoot) 'cascadia-nerdfont'
    $marker = Join-Path $dir 'marker.json'
    if (-not (Test-Path -LiteralPath $marker)) { return $null }
    if (-not (Test-WinMintIntermediatesCacheMarkerFileFresh -MarkerJsonPath $marker)) {
        Remove-WinMintIntermediatesCacheTree -Path $dir
        return $null
    }
    $ttfDir = Get-WinMintCascadiaNerdFontCachePayloadDir -CacheRootDir $dir
    if (-not (Test-Path -LiteralPath $ttfDir -PathType Container)) { return $null }
    $hasNf = @(Get-ChildItem -LiteralPath $ttfDir -Filter '*CascadiaCodeNF*.ttf' -File -ErrorAction SilentlyContinue).Count -ge 1
    if (-not $hasNf) { return $null }
    return $dir
}

function Restore-WinMintCascadiaNerdFontFromCache {
    param(
        [Parameter(Mandatory)][string]$FontDir,
        [Parameter(Mandatory)][string]$CacheRootDir
    )
    $ttfDir = Get-WinMintCascadiaNerdFontCachePayloadDir -CacheRootDir $CacheRootDir
    $marker = Join-Path $CacheRootDir 'marker.json'
    $meta = Get-Content -LiteralPath $marker -Raw -ErrorAction Stop | ConvertFrom-Json
    $null = New-Item -Path $FontDir -ItemType Directory -Force
    Get-ChildItem -LiteralPath $ttfDir -Filter '*CascadiaCodeNF*.ttf' -File -ErrorAction Stop |
        Copy-Item -Destination $FontDir -Force
    Add-WinMintManifestPayload -Name 'Cascadia Code (Nerd Font)' -SourceUrl ([string]$meta.SourceUrl) `
        -Version ([string]$meta.Version) -Sha256 ([string]$meta.Sha256) -SizeBytes ([long]$meta.SizeBytes)
}

function Publish-WinMintCascadiaNerdFontCache {
    param(
        [Parameter(Mandatory)][string]$FontDir,
        [Parameter(Mandatory)][string]$TagName,
        [Parameter(Mandatory)][string]$AssetName,
        [Parameter(Mandatory)][string]$SourceUrl,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][long]$SizeBytes
    )
    $nf = @(Get-ChildItem -LiteralPath $FontDir -Filter '*CascadiaCodeNF*.ttf' -File -ErrorAction SilentlyContinue)
    if ($nf.Count -lt 1) { return }

    $dir = Join-Path (Get-WinMintBuildCacheRoot) 'cascadia-nerdfont'
    try {
        if (Test-Path -LiteralPath $dir) {
            Remove-WinMintIntermediatesCacheTree -Path $dir
        }
        $ttfDir = Get-WinMintCascadiaNerdFontCachePayloadDir -CacheRootDir $dir
        $null = New-Item -ItemType Directory -Path $ttfDir -Force -ErrorAction Stop
        Get-ChildItem -LiteralPath $FontDir -Filter '*CascadiaCodeNF*.ttf' -File -ErrorAction Stop |
            Copy-Item -Destination $ttfDir -Force
        $marker = [ordered]@{
            Schema      = 4
            Kind        = 'cascadia-nerdfont'
            SavedUtc    = [datetime]::UtcNow.ToString('o')
            TagName     = $TagName
            AssetName   = $AssetName
            SourceUrl   = $SourceUrl
            Version     = $TagName
            Sha256      = $Sha256
            SizeBytes   = $SizeBytes
        }
        $marker | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $dir 'marker.json') -Encoding UTF8
    }
    catch {
        LogVerbose "cascadia-nerdfont cache publish skipped: $($_.Exception.Message)"
        if (Test-Path -LiteralPath $dir) { Remove-WinMintIntermediatesCacheTree -Path $dir }
    }
}

