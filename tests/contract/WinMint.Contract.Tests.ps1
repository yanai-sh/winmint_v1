#Requires -Version 7.6
# Pester 5 contract suite — wraps legacy invariant scripts and adds focused gates.

BeforeAll {
    $script:Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:FixtureDir = Join-Path $script:Root 'tests\fixtures\setup-shell'
    $script:StatusRequiredFields = @(
        'phase', 'stageId', 'taskLabel', 'detailLabel', 'itemIndex', 'itemTotal',
        'progressPct', 'progressMode', 'banner', 'bannerKind', 'logDir', 'updatedAt'
    )
}

Describe 'Legacy profile invariant script' {
    It 'Test-ProfileInvariants.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-ProfileInvariants.ps1')
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Setup shell status fixtures' {
    It 'status-*.json carries the trimmed status contract fields' {
        $fixtures = @(Get-ChildItem -LiteralPath $script:FixtureDir -Filter 'status-*.json' -ErrorAction Stop)
        $fixtures.Count | Should -BeGreaterThan 0
        foreach ($fixture in $fixtures) {
            $payload = Get-Content -LiteralPath $fixture.FullName -Raw | ConvertFrom-Json
            foreach ($required in $script:StatusRequiredFields) {
                $payload.PSObject.Properties[$required] | Should -Not -BeNullOrEmpty -Because "fixture $($fixture.Name) must expose '$required'"
            }
        }
    }
}

Describe 'Setup shell status pump wiring' {
    It 'does not use Register-ObjectEvent (blocks under Start-Process -Wait)' {
        $statusText = Get-Content -LiteralPath (Join-Path $script:Root 'src\runtime\setup\WinMintSetupShell.Status.ps1') -Raw
        $statusText | Should -Not -Match 'Register-ObjectEvent'
    }

    It 'pumps status ticks while waiting for the agent' {
        $transactionText = Get-Content -LiteralPath (Join-Path $script:Root 'src\runtime\setup\FirstLogon.Transaction.ps1') -Raw
        $transactionText | Should -Match 'Invoke-WinMintSetupShellStatusPumpTick'
    }
}

Describe 'Runtime state projection' {
    It 'Test-WinMintRuntimeStateAgentDisplay.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-WinMintRuntimeStateAgentDisplay.ps1')
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'VM acceptance harness contracts' {
    It 'guest wait snapshot avoids Win32_Process enumeration' {
        & (Join-Path $script:Root 'tests\vm\Test-WinMintVmGuestWaitSnapshotContract.ps1')
        $LASTEXITCODE | Should -Be 0
    }

    It 'wait progress line labels distinguish poll failures from cleanup' {
        & (Join-Path $script:Root 'tests\vm\Test-WinMintVmWaitProgressLine.ps1')
        $LASTEXITCODE | Should -Be 0
    }

    It 'guest PSDirect file scripts run under bundled pwsh 7' {
        & (Join-Path $script:Root 'tests\vm\Test-WinMintVmGuestCommandContract.ps1')
        $LASTEXITCODE | Should -Be 0
    }

    It 'exposes bounded guest invoke helper' {
        $consoleText = Get-Content -LiteralPath (Join-Path $script:Root 'tools\vm\lib\VmGuest.ps1') -Raw
        $consoleText | Should -Match 'function Invoke-WinMintVmGuestCommand'
        $consoleText | Should -Match 'Test-WinMintVmGuestPsDirectRetryable'
    }

    It 'resolves acceptance build plans for efficient iteration' {
        & (Join-Path $script:Root 'tests\vm\Test-WinMintVmAcceptanceBuildPlan.ps1')
        $LASTEXITCODE | Should -Be 0
    }

    It 'infers run phase from log tail when managed state is stale' {
        & (Join-Path $script:Root 'tests\vm\Test-WinMintVmRunPhaseInference.ps1')
        $LASTEXITCODE | Should -Be 0
    }
}
Describe 'FirstLogon transaction plan' {
    It 'Test-FirstLogonTransactionPlan.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-FirstLogonTransactionPlan.ps1')
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Launcher contract' {
    It 'Test-Launchers.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-Launchers.ps1')
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Setup shell native host' {
    It 'Test-WinMintSetupShell.ps1 asset contract passes (headless)' {
        & (Join-Path $script:Root 'tests\setup-shell\Test-WinMintSetupShell.ps1') -SkipLaunch
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Provisioning projection contract' {
    It 'Test-WinMintProvisioningProjection.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-WinMintProvisioningProjection.ps1')
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Provisioning guard contract' {
    It 'Test-ProvisioningGuardContract.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-ProvisioningGuardContract.ps1')
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'SetupComplete action dispatch contract' {
    It 'Test-SetupCompleteActionDispatch.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-SetupCompleteActionDispatch.ps1')
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Shell pins and Terminal profiles contract' {
    It 'Test-ShellPinsAndTerminalProfiles.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-ShellPinsAndTerminalProfiles.ps1')
        $LASTEXITCODE | Should -Be 0
    }

    It 'Test-VmShellDesktopEvidence.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-VmShellDesktopEvidence.ps1')
        $LASTEXITCODE | Should -Be 0
    }

    It 'Test-VmSpectreBuildChannels.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-VmSpectreBuildChannels.ps1')
        $LASTEXITCODE | Should -Be 0
    }

    It 'Test-VmFingerprint.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-VmFingerprint.ps1')
        $LASTEXITCODE | Should -Be 0
    }

    It 'Test-VmManagedRunStateWrite.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-VmManagedRunStateWrite.ps1')
        $LASTEXITCODE | Should -Be 0
    }

    It 'Test-VmSetupCompleteEvidence.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-VmSetupCompleteEvidence.ps1')
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'DMA location compliance contract' {
    It 'Test-DmaLocationCompliance.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-DmaLocationCompliance.ps1')
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'OOBE rehydration suppression contract' {
    It 'Test-OobeRehydrationSuppression.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-OobeRehydrationSuppression.ps1')
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Setup-shell presenter acceptance signal contract' {
    It 'Test-SetupShellPresenterSignal.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-SetupShellPresenterSignal.ps1')
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Wizard ui-bridge protocol contract' {
    It 'Test-WizardBridgeProtocol.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-WizardBridgeProtocol.ps1')
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Acceptance result contract' {
    It 'Test-WinMintAcceptanceResultSchema.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-WinMintAcceptanceResultSchema.ps1')
        $LASTEXITCODE | Should -Be 0
    }

    It 'Test-WinMintHardwareAcceptanceSignals.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-WinMintHardwareAcceptanceSignals.ps1')
        $LASTEXITCODE | Should -Be 0
    }

    It 'Test-WinMintHostDriverMirrorFilter.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-WinMintHostDriverMirrorFilter.ps1')
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'VM PostSetup checkpoint tooling' {
    It 'exposes shared checkpoint helpers in VM console lib modules' {
        $observeText = Get-Content -LiteralPath (Join-Path $script:Root 'tools\vm\lib\VmObserve.ps1') -Raw
        foreach ($expected in @(
                'Get-WinMintVmPostSetupCheckpointSidecarPath'
                'Test-WinMintVmPostSetupCheckpointUsable'
                'Save-WinMintVmPostSetupCheckpoint'
                'Restore-WinMintVmPostSetupCheckpoint'
            )) {
            $observeText | Should -Match ([regex]::Escape($expected))
        }
    }

    It 'Build-And-TestVm.ps1 supports -UseCheckpoint and acceptance saves PostSetup checkpoints' {
        $buildText = Get-Content -LiteralPath (Join-Path $script:Root 'tools\vm\Build-And-TestVm.ps1') -Raw
        $acceptanceText = Get-Content -LiteralPath (Join-Path $script:Root 'tools\vm\Invoke-WinMintVmAcceptance.ps1') -Raw
        $buildText | Should -Match 'UseCheckpoint'
        $acceptanceText | Should -Match 'Save-WinMintVmPostSetupCheckpoint'
    }
}

Describe 'Install-plan and agent host contracts' {
    It 'Test-InstallPlanContract.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-InstallPlanContract.ps1')
        $LASTEXITCODE | Should -Be 0
    }

    It 'Test-AgentStateTransitions.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-AgentStateTransitions.ps1')
        $LASTEXITCODE | Should -Be 0
    }

    It 'Test-CliMatrix.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-CliMatrix.ps1')
        $LASTEXITCODE | Should -Be 0
    }

    It 'Test-AgentEventsSchema.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-AgentEventsSchema.ps1')
        $LASTEXITCODE | Should -Be 0
    }

    It 'Test-BootstrapContract.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-BootstrapContract.ps1')
        $LASTEXITCODE | Should -Be 0
    }

    It 'Test-PayloadStoreContract.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-PayloadStoreContract.ps1')
        $LASTEXITCODE | Should -Be 0
    }

    It 'Test-ServicedWimCache.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-ServicedWimCache.ps1')
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Autounattend generation contract' {
    It 'Test-AutounattendGeneration.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-AutounattendGeneration.ps1')
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'VM post-install evidence contract' {
    It 'Test-VmPostInstallEvidence.ps1 exits 0' {
        & (Join-Path $script:Root 'tests\contract\Test-VmPostInstallEvidence.ps1')
        $LASTEXITCODE | Should -Be 0
    }
}
