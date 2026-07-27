#Requires -Version 7.6
<#
.SYNOPSIS
  Red/green: culture settle after language-list rebuild (DMA restore race).

.DESCRIPTION
  Default (-Policy Settle) matches Wait-WinMintFirstLogonUserCulture: must stay green.
  -Policy ImmediateRetry reproduces the pre-fix one-shot retry (expect red on guest).
#>
[CmdletBinding()]
param(
    [ValidateSet('Settle', 'ImmediateRetry')]
    [string]$Policy = 'Settle',
    [string]$DisplayLanguage = 'en-US',
    [string]$RestoreUserLocale = 'he-IL',
    [string]$DmaSetupCulture = 'en-IE',
    [int]$Trials = 16,
    [int]$SettleMs = 1000,
    [switch]$RequireSettle
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command Set-WinUserLanguageList -ErrorAction SilentlyContinue)) {
    throw 'Set-WinUserLanguageList is required (Windows International module).'
}
if (-not (Get-Command Set-Culture -ErrorAction SilentlyContinue)) {
    throw 'Set-Culture is required.'
}

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'src\runtime\setup\FirstLogon.Region.ps1')

function Invoke-WinMintImmediateRetryCultureSet {
    param([Parameter(Mandatory)][string]$CultureName)

    Set-WinMintFirstLogonUserCulture -CultureName $CultureName
    $localeAfterSet = Get-WinMintFirstLogonUserLocaleName
    if ($localeAfterSet -ne $CultureName) {
        Set-WinMintFirstLogonUserCulture -CultureName $CultureName
        $localeAfterSet = Get-WinMintFirstLogonUserLocaleName
    }
    return $localeAfterSet
}

$raceLosses = 0
$settleFailures = 0
$results = [System.Collections.Generic.List[object]]::new()

for ($i = 0; $i -lt $Trials; $i++) {
    try {
        Set-Culture -CultureInfo $DmaSetupCulture -ErrorAction Stop
    }
    catch {
        Set-Culture -CultureInfo 'en-US' -ErrorAction Stop
    }

    $list = New-WinUserLanguageList -Language $DisplayLanguage
    if ($RestoreUserLocale -and (($RestoreUserLocale -split '-')[0]).ToLowerInvariant() -ne (($DisplayLanguage -split '-')[0]).ToLowerInvariant()) {
        $list.Add($RestoreUserLocale) | Out-Null
    }
    Set-WinUserLanguageList -LanguageList $list -Force -ErrorAction Stop

    if ($Policy -eq 'Settle') {
        $afterPolicy = Wait-WinMintFirstLogonUserCulture -CultureName $RestoreUserLocale -TimeoutMs $SettleMs
    }
    else {
        $afterPolicy = Invoke-WinMintImmediateRetryCultureSet -CultureName $RestoreUserLocale
    }
    $lostRace = ($afterPolicy -ne $RestoreUserLocale)
    if ($lostRace) { $raceLosses++ }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $settled = Get-WinMintFirstLogonUserLocaleName
    while ($settled -ne $RestoreUserLocale -and $sw.ElapsedMilliseconds -lt $SettleMs) {
        Start-Sleep -Milliseconds 50
        try { Set-WinMintFirstLogonUserCulture -CultureName $RestoreUserLocale } catch { }
        $settled = Get-WinMintFirstLogonUserLocaleName
    }
    if ($settled -ne $RestoreUserLocale) { $settleFailures++ }

    $results.Add([pscustomobject]@{
            trial       = $i
            afterPolicy = $afterPolicy
            lostRace    = $lostRace
            settled     = $settled
            settleMs    = $sw.ElapsedMilliseconds
        }) | Out-Null
}

Write-Host ($results | Format-Table -AutoSize | Out-String)
Write-Host "Policy=$Policy race losses: $raceLosses / $Trials"
Write-Host "Settle failures within ${SettleMs}ms: $settleFailures / $Trials"

if ($RequireSettle -and $settleFailures -gt 0) {
    Write-Host 'Assert-WinMintDmaCultureRestoreRace: RED (culture did not settle).' -ForegroundColor Red
    exit 1
}

if ($raceLosses -gt 0) {
    Write-Host "Assert-WinMintDmaCultureRestoreRace: RED (policy=$Policy insufficient after language-list rebuild)." -ForegroundColor Red
    exit 1
}

Write-Host "Assert-WinMintDmaCultureRestoreRace: OK (GREEN, policy=$Policy)."
exit 0
