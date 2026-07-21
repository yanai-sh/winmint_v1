#Requires -Version 7.6
<#
.SYNOPSIS
    Write-WinMintVmManagedRunState must survive concurrent starter/worker writes
    without ERROR_ALREADY_EXISTS (shared Path.tmp + Move-Item -Force race).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'tools\vm\lib\VmObserve.ps1')

$dir = Join-Path $env:TEMP ("winmint-managed-run-write-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $dir -Force
$path = Join-Path $dir 'managed-run.json'
$failFile = Join-Path $dir 'fails.txt'
try {
    Write-WinMintVmManagedRunState -Path $path -State ([ordered]@{ status = 'seed'; pid = 1 })

    1..2 | ForEach-Object -Parallel {
        $path = $using:path
        $failFile = $using:failFile
        $root = $using:root
        . (Join-Path $root 'tools\vm\lib\VmObserve.ps1')
        for ($i = 1; $i -le 80; $i++) {
            try {
                Write-WinMintVmManagedRunState -Path $path -State ([ordered]@{
                        status = 'running'
                        pid    = $PID
                        i      = $i
                    })
            }
            catch {
                Add-Content -LiteralPath $failFile -Value $_.Exception.Message
            }
        }
    } -ThrottleLimit 2

    $fails = @(Get-Content -LiteralPath $failFile -ErrorAction SilentlyContinue)
    $alreadyExists = @($fails | Where-Object { $_ -match 'already exists' })
    if ($alreadyExists.Count -gt 0) {
        Write-Host "FAIL concurrent Write-WinMintVmManagedRunState hit ERROR_ALREADY_EXISTS ($($alreadyExists.Count))"
        $alreadyExists | Select-Object -First 5 | ForEach-Object { Write-Host "  $_" }
        exit 1
    }
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host 'FAIL managed-run.json missing after concurrent writes'
        exit 1
    }
    $null = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Write-Host 'OK Write-WinMintVmManagedRunState concurrent overwrite'
    exit 0
}
finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
