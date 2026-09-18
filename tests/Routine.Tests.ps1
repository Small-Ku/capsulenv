Describe 'Capsulenv lifecycle routine contracts' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force -DisableNameChecking
        $script:Module = @(Get-Module Capsulenv)[-1]
    }

    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }

    It 'keeps the default capsule configuration workload-neutral' {
        $config = Import-PowerShellDataFile (Join-Path $script:Root 'config/capsulenv.psd1')
        $config.ContainsKey('Routines') | Should -BeTrue
        $config.ContainsKey('SingBox') | Should -BeFalse
        $config.Routines.Count | Should -Be 0
    }

    It 'builds an installed-app routine through the provider-neutral process-plan boundary' {
        Mock Get-CapsulenvConfiguration {
            @{
                Routines = @{
                    Network = @{
                        Enabled = $true
                        Trigger = @('OnEnter')
                        App = 'scoop/private-network'
                        BinName = 'sing-box'
                        Arguments = @('run', '-c', 'config.json')
                        Mode = 'Detached'
                    }
                }
            }
        } -ModuleName Capsulenv
        Mock Get-CapsulenvInstalledAppProcessPlan {
            [pscustomobject]@{ App=$App; BinName=$BinName; Arguments=@($Arguments); ExecutionMode=$ExecutionMode }
        } -ModuleName Capsulenv

        $plan = & $script:Module {
            $routine = @(Get-CapsulenvRoutineDefinitions -Trigger OnEnter)[0]
            Get-CapsulenvRoutineProcessPlan -Routine $routine
        }

        $plan.App | Should -Be 'scoop/private-network'
        $plan.BinName | Should -Be 'sing-box'
        $plan.ExecutionMode | Should -Be 'Detached'
        $plan.Arguments | Should -Be @('run', '-c', 'config.json')
        Should -Invoke Get-CapsulenvInstalledAppProcessPlan -ModuleName Capsulenv -Times 1 -Exactly
    }

    It 'throttles a successful routine until its minimum interval expires' {
        $now = [DateTime]::UtcNow
        $routine = [pscustomobject]@{ Name='Sync'; MinimumIntervalSeconds=600 }
        $state = [ordered]@{
            Sync = [pscustomobject]@{ LastSuccessUtc=$now.AddSeconds(-120).ToString('o') }
        }
        $due = & $script:Module {
            param($Routine, $State, $Now)
            Test-CapsulenvRoutineDue -Routine $Routine -State $State -NowUtc $Now
        } $routine $state $now
        $due | Should -BeFalse
    }

    It 'runs shell lifecycle triggers around the resolved binding and carries portable state into the child plan' {
        Mock Set-CapsulenvSessionEnvironment {} -ModuleName Capsulenv
        Mock Initialize-CapsulenvIntegrations {} -ModuleName Capsulenv
        Mock Resolve-CapsulenvPowerShellBinding {
            [pscustomobject][ordered]@{
                Succeeded = $true
                Program = [pscustomobject]@{ Executable = 'pwsh.exe' }
                LaunchArguments = @('-NoLogo', '-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-Command', 'bootstrap')
                BootstrapCommand = 'bootstrap'
                ProfilePath = '/capsule/profile.ps1'
                HistoryPath = '/capsule/history.txt'
                BootstrapPath = '/capsule/bootstrap.ps1'
                PSModulePath = '/capsule/modules:/host/modules'
                Environment = [ordered]@{
                    PSModulePath = '/capsule/modules:/host/modules'
                    CAPSULENV_POWERSHELL_PROFILE = '/capsule/profile.ps1'
                    CAPSULENV_POWERSHELL_HISTORY = '/capsule/history.txt'
                }
            }
        } -ModuleName Capsulenv
        Mock Write-CapsulenvMessage {} -ModuleName Capsulenv
        Mock Invoke-CapsulenvProcessPlan {} -ModuleName Capsulenv
        Mock Invoke-CapsulenvRoutines {} -ModuleName Capsulenv

        & $script:Module { Invoke-CapsulenvChildShell -Command 'Write-Output ok' }

        Should -Invoke Invoke-CapsulenvRoutines -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter { $Trigger -eq 'OnEnter' }
        Should -Invoke Invoke-CapsulenvRoutines -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter { $Trigger -eq 'OnExit' }
        Should -Invoke Invoke-CapsulenvProcessPlan -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            $Plan.Executable -eq 'pwsh.exe' -and
            $Plan.Environment['CAPSULENV_POWERSHELL_PROFILE'] -eq '/capsule/profile.ps1' -and
            $Plan.Environment['CAPSULENV_POWERSHELL_HISTORY'] -eq '/capsule/history.txt' -and
            $Plan.Environment['PSModulePath'] -eq '/capsule/modules:/host/modules' -and
            @($Plan.Arguments) -contains 'Write-Output ok'
        }
    }

    It 'runs the rehydrate lifecycle trigger after projection reconciliation' {
        Mock Get-CapsulenvScoopRehydratePlan {
            [pscustomobject]@{ Context=@{}; Plan=[pscustomobject]@{} }
        } -ModuleName Capsulenv
        Mock Invoke-CapsulenvDesiredStatePlan {
            @([pscustomobject]@{ Id='rehydration-state'; Output=[pscustomobject]@{ ProjectionRepairComplete=$true } })
        } -ModuleName Capsulenv
        Mock Write-CapsulenvMessage {} -ModuleName Capsulenv
        Mock Invoke-CapsulenvRoutines {} -ModuleName Capsulenv

        & $script:Module { Invoke-CapsulenvScoopRehydrate } | Out-Null

        Should -Invoke Invoke-CapsulenvRoutines -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter { $Trigger -eq 'OnRehydrate' }
    }
}
