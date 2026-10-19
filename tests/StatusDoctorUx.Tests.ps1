Describe 'Capsulenv fast status and deferred Scoop diagnostics' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:OriginalRoot = $env:CAPSULENV_ROOT
        $env:CAPSULENV_ROOT = $script:Root
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = Get-CapsulenvTestModuleBuild -Root $script:Root
        Import-Module $script:Build.ModulePath -Force -DisableNameChecking
        $script:Module = Get-Module Capsulenv
    }
    AfterAll {
        if ($null -eq $script:OriginalRoot) { Remove-Item Env:CAPSULENV_ROOT -ErrorAction SilentlyContinue } else { $env:CAPSULENV_ROOT = $script:OriginalRoot }
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }

    It 'renders the CLI overview without enumerating Scoop apps, caches, or repair plans' {
        Mock Get-CapsulenvContext { [pscustomobject]@{ Root = 'C:\test-capsule' } } -ModuleName Capsulenv
        Mock Get-CapsulenvRuntimeVersion { 'test' } -ModuleName Capsulenv
        Mock Get-CapsulenvInstallMode { 'ShellOnly' } -ModuleName Capsulenv
        Mock Get-CapsulenvUserIntegrationStatus {
            [pscustomobject]@{
                PlacementRetention='ephemeral'
                UserIntegration='isolated'
                OwnedUserIntegration='none'
                IntegrationLease='none'
                IntegrationDiagnostic=''
                DefaultBrowserUserConfirmationRequired=$false
            }
        } -ModuleName Capsulenv
        $hasPreparation = & $script:Module {
            $null -ne (Get-Command Get-CapsulenvShellPreparationSummary -CommandType Function -ErrorAction SilentlyContinue)
        }
        if ($hasPreparation) {
            Mock Get-CapsulenvShellPreparationSummary {
                [pscustomobject]@{ State='running'; Prepared=@(); Errors=@() }
            } -ModuleName Capsulenv
        }        Mock Get-CapsulenvScoopProvisioningState { [pscustomobject]@{ State='not-started' } } -ModuleName Capsulenv
        Mock Get-CapsulenvInstalledScoopApps { throw 'expensive installed Scoop scan' } -ModuleName Capsulenv
        Mock Get-CapsulenvInstalledPackageStates { throw 'expensive package scan' } -ModuleName Capsulenv
        Mock Read-CapsulenvProjectCacheRegistry { throw 'expensive registry scan' } -ModuleName Capsulenv
        Mock Read-CapsulenvToolWorkspaceRegistry { throw 'expensive workspace scan' } -ModuleName Capsulenv
        Mock Get-CapsulenvOfflineReadiness { throw 'recursive offline scan' } -ModuleName Capsulenv
        Mock Test-CapsulenvScoopRehydrationRequired { throw 'expensive shim repair plan' } -ModuleName Capsulenv
        Mock Ensure-CapsulenvProgramGeneration { throw 'acquisition must never occur' } -ModuleName Capsulenv
        $summary = & $script:Module { Get-CapsulenvStatus -Quick }
        $summary.Mode | Should -Be 'ShellOnly'
        $summary.ScoopProvisioning | Should -Be 'not-started'
        if ($hasPreparation) {
            $summary.ShellPreparation.State | Should -Be 'running'
        }
        $summary.PSObject.Properties['ScoopApps'] | Should -BeNullOrEmpty
        $output = & $script:Module { Invoke-Capsulenv -Arguments @('status') 6>&1 | Out-String }
        $output | Should -Match 'ScoopProvisioning\s+:\s+not-started'
        Should -Invoke Get-CapsulenvInstalledScoopApps -ModuleName Capsulenv -Times 0 -Exactly
        Should -Invoke Get-CapsulenvInstalledPackageStates -ModuleName Capsulenv -Times 0 -Exactly
        Should -Invoke Read-CapsulenvProjectCacheRegistry -ModuleName Capsulenv -Times 0 -Exactly
        Should -Invoke Read-CapsulenvToolWorkspaceRegistry -ModuleName Capsulenv -Times 0 -Exactly
        Should -Invoke Get-CapsulenvOfflineReadiness -ModuleName Capsulenv -Times 0 -Exactly
        Should -Invoke Test-CapsulenvScoopRehydrationRequired -ModuleName Capsulenv -Times 0 -Exactly
        Should -Invoke Ensure-CapsulenvProgramGeneration -ModuleName Capsulenv -Times 0 -Exactly
    }

    It 'treats absent Scoop root and command as deferred, optional capability' {
        $path = Join-Path $TestDrive 'fresh-scoop'
        Mock Get-CapsulenvScoopRoot { $path } -ModuleName Capsulenv
        $results = @(& $script:Module { Invoke-CapsulenvDoctorChecks -Ids @('Capsulenv.Doctor.Scoop.Root', 'Capsulenv.Doctor.Scoop.Command') })
        $results.Count | Should -Be 2
        $results[0].Status | Should -Be 'Advisory'
        $results[0].Importance | Should -Be 'Optional'
        $results[1].Status | Should -Be 'Unavailable'
        $results[1].Importance | Should -Be 'Optional'
        $results[0].Data.State | Should -Be 'not-started'
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'keeps missing upstream Scoop executable a required failure after root materialization' {
        $path = Join-Path $TestDrive 'incomplete-scoop'
        [void](New-Item -ItemType Directory -Path (Join-Path $path 'apps/scoop/current') -Force)
        Mock Get-CapsulenvScoopRoot { $path } -ModuleName Capsulenv
        $results = @(& $script:Module { Invoke-CapsulenvDoctorChecks -Ids @('Capsulenv.Doctor.Scoop.Root', 'Capsulenv.Doctor.Scoop.Command') })
        $results[0].Status | Should -Be 'Healthy'
        $results[0].Importance | Should -Be 'Required'
        $results[1].Status | Should -Be 'Unavailable'
        $results[1].Importance | Should -Be 'Required'
        $results[1].Data.State | Should -Be 'incomplete'
        ($results[1].Remediation -join ' ') | Should -Match 'Inspect the existing Scoop root'
    }

    It 'treats an existing file blocking the Scoop root as incomplete, not deferred' {
        $path = Join-Path $TestDrive 'blocked-scoop'
        'not a directory' | Set-Content -LiteralPath $path -Encoding UTF8
        Mock Get-CapsulenvScoopRoot { $path } -ModuleName Capsulenv
        $results = @(& $script:Module { Invoke-CapsulenvDoctorChecks -Ids @('Capsulenv.Doctor.Scoop.Root', 'Capsulenv.Doctor.Scoop.Command') })
        $results[1].Importance | Should -Be 'Required'
        $results[1].Status | Should -Be 'Unavailable'
        $results[1].Data.State | Should -Be 'incomplete'
    }
    It 'recognizes a materialized Scoop dispatcher without invoking upstream code' {
        $path = Join-Path $TestDrive 'ready-scoop'
        $dispatcher = Join-Path $path 'apps/scoop/current/bin/scoop.ps1'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $dispatcher) -Force)
        '# Do not execute me' | Set-Content -LiteralPath $dispatcher -Encoding UTF8
        Mock Get-CapsulenvScoopRoot { $path } -ModuleName Capsulenv
        $results = @(& $script:Module { Invoke-CapsulenvDoctorChecks -Ids @('Capsulenv.Doctor.Scoop.Root', 'Capsulenv.Doctor.Scoop.Command') })
        $results[0].Status | Should -Be 'Healthy'
        $results[1].Status | Should -Be 'Healthy'
        $results[1].Importance | Should -Be 'Required'
        $results[1].Data.State | Should -Be 'ready'
    }
}