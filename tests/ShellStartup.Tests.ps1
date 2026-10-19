Describe 'Capsulenv shell startup hotpath and preparation' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force
        $script:Module = @(Get-Module Capsulenv)[-1]
    }

    BeforeEach {
        $script:CapturedChildPlan = $null
        Mock Set-CapsulenvSessionEnvironment {} -ModuleName Capsulenv
        Mock Write-CapsulenvMessage {} -ModuleName Capsulenv
        Mock Find-CapsulenvHostScoop { $null } -ModuleName Capsulenv
        Mock Invoke-CapsulenvOwnedProcessPlan { $script:CapturedChildPlan = $Plan } -ModuleName Capsulenv
    }
    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }

    It 'launches a clearly marked WinPS 5.1 fallback without synchronous acquisition or optional activation' -Skip:(-not ($env:OS -eq 'Windows_NT')) {
        Mock Get-CapsulenvIdentity { 'testcapsule' } -ModuleName Capsulenv
        Mock Get-CapsulenvProgramProviderCandidatesWithBootstrap { throw 'Foreground network acquisition forbidden' } -ModuleName Capsulenv
        Mock Get-CapsulenvActiveGeneration { $null } -ModuleName Capsulenv
        Mock Get-CapsulenvProgramCandidates { @() } -ModuleName Capsulenv
        Mock Get-CapsulenvShellPreparationPending { @('pwsh') } -ModuleName Capsulenv
        Mock Start-CapsulenvShellPreparationWorker { $true } -ModuleName Capsulenv
        Mock Initialize-CapsulenvHostPlacement { [pscustomobject]@{ Valid=$true } } -ModuleName Capsulenv
        Mock Initialize-CapsulenvSession { [pscustomobject]@{ SessionId='test-session' } } -ModuleName Capsulenv
        Mock Get-CapsulenvPowerShellStatePaths {
            [pscustomobject]@{ HistoryPath=(Join-Path $TestDrive 'history.txt') }
        } -ModuleName Capsulenv
        Mock Initialize-CapsulenvIntegrations { throw 'optional integration on degraded path' } -ModuleName Capsulenv

        & $script:Module { Invoke-CapsulenvChildShell -Command 'Write-Output healthy' }
        $script:CapturedChildPlan | Should -Not -BeNullOrEmpty
        $script:CapturedChildPlan.Environment['CAPSULENV_SHELL_STATUS'] | Should -Be 'degraded'
        $script:CapturedChildPlan.Executable | Should -BeLike '*WindowsPowerShell*v1.0*powershell.exe'
        $script:CapturedChildPlan.Arguments[-1] | Should -Match 'Write-Output healthy'
        Should -Invoke Start-CapsulenvShellPreparationWorker -ModuleName Capsulenv -Times 1 -Exactly
        Should -Invoke Get-CapsulenvProgramProviderCandidatesWithBootstrap -ModuleName Capsulenv -Times 0 -Exactly
        Should -Invoke Initialize-CapsulenvIntegrations -ModuleName Capsulenv -Times 0 -Exactly
    }

    It 'uses one active snapshot and does not invoke foreground provider acquisition' {
        Mock Get-CapsulenvProgramProviderCandidatesWithBootstrap { throw 'Foreground network acquisition forbidden' } -ModuleName Capsulenv
        Mock Get-CapsulenvActiveGeneration { [pscustomobject]@{ Generation = [pscustomobject]@{ GenerationId='test' } } } -ModuleName Capsulenv
        Mock New-CapsulenvActivationSnapshot { [pscustomobject]@{ GenerationId='test'; Programs=@{} } } -ModuleName Capsulenv
        Mock Get-CapsulenvActiveGenerationProgram { [pscustomobject]@{ Executable='pwsh.exe' } } -ModuleName Capsulenv
        Mock Get-CapsulenvShellPreparationPending { @() } -ModuleName Capsulenv
        Mock Start-CapsulenvShellPreparationWorker { throw 'Nothing to prepare' } -ModuleName Capsulenv
        Mock Initialize-CapsulenvIntegrations {} -ModuleName Capsulenv
        Mock Resolve-CapsulenvPowerShellBinding {
            [pscustomobject]@{
                Succeeded=$true
                Program=[pscustomobject]@{ Executable='pwsh.exe' }
                LaunchArguments=@('-NoLogo','-NoExit','-Command','Write-Output bootstrap')
                BootstrapCommand='Write-Output bootstrap'
                Environment=[pscustomobject]@{ PSModulePath='portable-test' }
                ProfilePath='';HistoryPath='';PSModulePath='';BootstrapPath=''
            }
        } -ModuleName Capsulenv
        Mock Invoke-CapsulenvRoutines { @() } -ModuleName Capsulenv
        Mock Stop-CapsulenvActiveSessionServices { @() } -ModuleName Capsulenv

        & $script:Module { Invoke-CapsulenvChildShell -Command 'Write-Output ready' }
        $script:CapturedChildPlan.Environment['CAPSULENV_SHELL_STATUS'] | Should -Be 'ready'
        $script:CapturedChildPlan.Executable | Should -Be 'pwsh.exe'
        Should -Invoke New-CapsulenvActivationSnapshot -ModuleName Capsulenv -Times 1 -Exactly
        Should -Invoke Start-CapsulenvShellPreparationWorker -ModuleName Capsulenv -Times 0 -Exactly
        Should -Invoke Get-CapsulenvProgramProviderCandidatesWithBootstrap -ModuleName Capsulenv -Times 0 -Exactly
    }

    It 'does not retry a non-network provider failure through bootstrap networking' {
        $global:CapsulenvTransportRetryCount = 0
        Mock Get-CapsulenvProgramProviderCandidates {
            throw ([System.IO.DirectoryNotFoundException]::new('missing local ZIP extraction destination'))
        } -ModuleName Capsulenv
        & $script:Module {
            Set-CapsulenvBootstrapNetworkInvoker -Invoker {
                param($Requirement,$Operation)
                $global:CapsulenvTransportRetryCount++
                & $Operation
            }
        }
        { & $script:Module { Get-CapsulenvProgramProviderCandidatesWithBootstrap -Requirement (New-CapsulenvProgramRequirement -Name pwsh) } } | Should -Throw '*missing local ZIP*'
        $global:CapsulenvTransportRetryCount | Should -Be 0
        Remove-Variable CapsulenvTransportRetryCount -Scope Global
    }

    It 'persists a completed preparation result and releases the execution lock' {
        Mock Get-CapsulenvIdentity { 'testcapsule' } -ModuleName Capsulenv
        Mock Initialize-CapsulenvHostPlacement { [pscustomobject]@{ Valid=$true } } -ModuleName Capsulenv
        $directory = Join-Path $TestDrive 'worker-state'
        [void](New-Item -ItemType Directory -Path $directory -Force)
        Mock Get-CapsulenvShellPreparationPaths {
            [pscustomobject]@{ Lock=(Join-Path $TestDrive 'worker-state/preparation.lock'); Status=(Join-Path $TestDrive 'worker-state/preparation.json') }
        } -ModuleName Capsulenv
        Mock Get-CapsulenvShellPreparationRequirements {
            @((New-CapsulenvProgramRequirement -Name pwsh))
        } -ModuleName Capsulenv
        Mock Ensure-CapsulenvProgramGeneration { [pscustomobject]@{ Succeeded=$true } } -ModuleName Capsulenv
        $completed = & $script:Module { Invoke-CapsulenvShellPreparation }
        $completed.State | Should -Be 'completed'
        $completed.Prepared | Should -Contain 'pwsh'
        $saved = & $script:Module { Get-CapsulenvShellPreparationStatus }
        $saved.State | Should -Be 'completed'
        { $fs = [IO.File]::Open((Join-Path $directory 'preparation.lock'),'Open','ReadWrite','None'); $fs.Dispose() } | Should -Not -Throw
    }
    It 'dispatches prepare status without provisioning through the public CLI' {
        Mock Initialize-CapsulenvContext { [pscustomobject]@{} } -ModuleName Capsulenv
        Mock Invoke-CapsulenvPrepareCommand {} -ModuleName Capsulenv
        Mock Ensure-CapsulenvProgramGeneration { throw 'status must not deploy' } -ModuleName Capsulenv
        & $script:Module { Invoke-Capsulenv -Arguments @('prepare', 'status') }
        Should -Invoke Invoke-CapsulenvPrepareCommand -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            @($Arguments).Count -eq 1 -and $Arguments[0] -eq 'status'
        }
        Should -Invoke Ensure-CapsulenvProgramGeneration -ModuleName Capsulenv -Times 0 -Exactly
    }

    It 'reads preparation state without starting acquisition or creating lock/status files' {
        $directory = Join-Path $TestDrive 'read-only-state'
        [void](New-Item -ItemType Directory -Path $directory -Force)
        $lockPath = Join-Path $directory 'preparation.lock'
        $statusPath = Join-Path $directory 'preparation.json'
        Mock Get-CapsulenvShellPreparationPaths {
            [pscustomobject]@{ Lock=$lockPath; Status=$statusPath }
        } -ModuleName Capsulenv
        Mock Ensure-CapsulenvProgramGeneration { throw 'status must not acquire programs' } -ModuleName Capsulenv
        Mock Initialize-CapsulenvHostPlacement { throw 'status must not mutate host placement' } -ModuleName Capsulenv

        $initial = & $script:Module { Get-CapsulenvShellPreparationSummary }
        $initial.State | Should -Be 'not-started'
        (Test-Path -LiteralPath $lockPath) | Should -BeFalse
        (Test-Path -LiteralPath $statusPath) | Should -BeFalse

        $held = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            $running = & $script:Module { Get-CapsulenvShellPreparationSummary }
            $running.State | Should -Be 'running'
        } finally {
            $held.Dispose()
        }

        @{
            SchemaVersion = 1
            State = 'failed'
            AttemptedAtUtc = '2026-10-17T00:00:00Z'
            FinishedAtUtc = '2026-10-17T00:01:00Z'
            Prepared = @()
            Errors = @('pwsh: network unavailable')
        } | ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding UTF8
        $failed = & $script:Module { Get-CapsulenvShellPreparationSummary }
        $failed.State | Should -Be 'failed'
        $failed.Errors | Should -Contain 'pwsh: network unavailable'
        $diagnosis = & $script:Module { Get-CapsulenvShellPreparationDoctorResult }
        $diagnosis.Status | Should -Be 'Advisory'
        $diagnosis.Detail | Should -Match 'network unavailable'
        ($diagnosis.Remediation -join ' ') | Should -Match 'help advanced'
        Should -Invoke Ensure-CapsulenvProgramGeneration -ModuleName Capsulenv -Times 0 -Exactly
        Should -Invoke Initialize-CapsulenvHostPlacement -ModuleName Capsulenv -Times 0 -Exactly
    }

    It 'adds preparation state to the existing public status without starting acquisition' {
        Mock Get-CapsulenvContext { [pscustomobject]@{ Root=$TestDrive } } -ModuleName Capsulenv
        Mock Get-CapsulenvInstalledScoopApps { @() } -ModuleName Capsulenv
        Mock Get-CapsulenvInstalledPackageStates { @() } -ModuleName Capsulenv
        Mock Read-CapsulenvProjectCacheRegistry { @() } -ModuleName Capsulenv
        Mock Read-CapsulenvToolWorkspaceRegistry { @() } -ModuleName Capsulenv
        Mock Get-CapsulenvOfflineReadiness { [pscustomobject]@{ RunReady=$false } } -ModuleName Capsulenv
        Mock Test-CapsulenvScoopRehydrationRequired { $false } -ModuleName Capsulenv
        Mock Get-CapsulenvUserIntegrationStatus { [pscustomobject]@{ PlacementRetention='ephemeral'; UserIntegration='isolated'; OwnedUserIntegration='none'; IntegrationLease='none'; IntegrationDiagnostic=''; DefaultBrowserUserConfirmationRequired=$false } } -ModuleName Capsulenv
        Mock Get-CapsulenvShellPreparationSummary { [pscustomobject]@{ State='running' } } -ModuleName Capsulenv
        Mock Get-CapsulenvRuntimeVersion { 'test' } -ModuleName Capsulenv
        Mock Get-CapsulenvInstallMode { 'ShellOnly' } -ModuleName Capsulenv
        Mock Ensure-CapsulenvProgramGeneration { throw 'status must not acquire programs' } -ModuleName Capsulenv

        $summary = & $script:Module { Get-CapsulenvStatus }
        $summary.ShellPreparation.State | Should -Be 'running'
        $summary.Mode | Should -Be 'ShellOnly'
        Should -Invoke Ensure-CapsulenvProgramGeneration -ModuleName Capsulenv -Times 0 -Exactly
    }
    It 'rejects overlapping worker execution while another instance holds its lock' {
        $directory = Join-Path $TestDrive 'worker-lock'
        [void](New-Item -ItemType Directory -Path $directory -Force)
        $lockFile = Join-Path $directory 'preparation.lock'
        Mock Get-CapsulenvIdentity { 'testcapsule' } -ModuleName Capsulenv
        Mock Initialize-CapsulenvHostPlacement { [pscustomobject]@{ Valid=$true } } -ModuleName Capsulenv
        Mock Get-CapsulenvShellPreparationPaths {
            [pscustomobject]@{ Lock=$lockFile; Status=(Join-Path $directory 'preparation.json') }
        } -ModuleName Capsulenv
        Mock Ensure-CapsulenvProgramGeneration { throw 'Overlapping worker attempted acquisition' } -ModuleName Capsulenv
        $held = [IO.File]::Open($lockFile, 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            $result = & $script:Module { Invoke-CapsulenvShellPreparation }
            $result | Should -BeNullOrEmpty
            Should -Invoke Ensure-CapsulenvProgramGeneration -ModuleName Capsulenv -Times 0 -Exactly
        } finally {
            $held.Dispose()
        }
    }
}
