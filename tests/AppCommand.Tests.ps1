Describe 'Capsulenv app command trust boundary' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force
        $script:Module = Get-Module Capsulenv
    }

    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }

    It 'emits a bounded machine-readable package plan without source manifest internals' {
        Mock Get-CapsulenvPackageInstallPlan {
            [pscustomobject]@{
                SchemaVersion = 1
                Reference = 'main/demo'
                Classification = 'PortableSafe'
                Packages = @([pscustomobject]@{
                    Reference = 'main/demo'
                    Version = '1.2.3'
                    Architecture = '64bit'
                    Classification = 'PortableSafe'
                    Capabilities = @('Bin', 'Persist')
                    Bin = @(@('bin\demo.exe','demo'))
                    Reasons = @()
                    Dependencies = @('helper')
                    SourceManifest = [pscustomobject]@{ secret = 'must-not-cross-contract' }
                })
                BlockedPackages = @()
            }
        } -ModuleName Capsulenv

        $json = & $script:Module { Invoke-CapsulenvAppCommand -Arguments @('plan', 'demo', '--json') }
        $contract = $json | ConvertFrom-Json
        $contract.SchemaVersion | Should -Be 2
        $contract.Reference | Should -Be 'main/demo'
        $contract.Classification | Should -Be 'PortableSafe'
        $contract.PortableSafe | Should -BeTrue
        $contract.Packages | Should -HaveCount 1
        $contract.Packages[0].Capabilities | Should -Contain 'Persist'
        $contract.Executables | Should -Contain 'demo'
        $contract.Packages[0].Executables | Should -Contain 'demo'
        $contract.Packages[0].PSObject.Properties.Name | Should -Not -Contain 'SourceManifest'
        $json | Should -Not -Match 'must-not-cross-contract'
    }

    It 'uses the Capsulenv executor for PortableSafe plans without invoking Scoop' {
        Mock Get-CapsulenvPackageInstallPlan {
            [pscustomobject]@{ Classification = 'PortableSafe'; Packages = @(); BlockedPackages = @() }
        } -ModuleName Capsulenv
        Mock Install-CapsulenvPortablePackage { @() } -ModuleName Capsulenv
        Mock Invoke-CapsulenvScoopCommand { throw 'upstream Scoop must not run for PortableSafe' } -ModuleName Capsulenv

        & $script:Module { Invoke-CapsulenvAppCommand -Arguments @('install', 'demo') }

        Should -Invoke Install-CapsulenvPortablePackage -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter { $Reference -eq 'demo' }
        Should -Invoke Invoke-CapsulenvScoopCommand -ModuleName Capsulenv -Times 0 -Exactly
    }

    It 'blocks non-PortableSafe plans unless trusted execution is explicit' {
        Mock Get-CapsulenvPackageInstallPlan {
            [pscustomobject]@{
                Classification = 'TrustedExecutionRequired'
                Packages = @()
                BlockedPackages = @([pscustomobject]@{
                    Reference = 'main/demo'
                    Classification = 'TrustedScript'
                    Reasons = @('post_install')
                })
            }
        } -ModuleName Capsulenv
        Mock Invoke-CapsulenvScoopCommand { 0 } -ModuleName Capsulenv

        $errorRecord = $null
        try {
            & $script:Module { Invoke-CapsulenvAppCommand -Arguments @('install', 'demo') }
        } catch {
            $errorRecord = $_
        }
        $errorRecord | Should -Not -BeNullOrEmpty
        $errorRecord.FullyQualifiedErrorId | Should -Be 'Capsulenv.Package.TrustedExecutionRequired'
        $remediation = & $script:Module {
            param($ErrorRecord)
            Get-CapsulenvDiagnosticRemediation -ErrorRecord $ErrorRecord
        } $errorRecord
        ($remediation -join ' ') | Should -Match '--allow-trusted'
        Should -Invoke Invoke-CapsulenvScoopCommand -ModuleName Capsulenv -Times 0 -Exactly
    }

    It 'delegates only the explicit trusted request to unmodified upstream Scoop' {
        Mock Get-CapsulenvPackageInstallPlan {
            [pscustomobject]@{
                Classification = 'TrustedExecutionRequired'
                Packages = @()
                BlockedPackages = @([pscustomobject]@{
                    Reference = 'main/demo'
                    Classification = 'TrustedScript'
                    Reasons = @('post_install')
                })
            }
        } -ModuleName Capsulenv
        Mock Set-CapsulenvSessionEnvironment {} -ModuleName Capsulenv
        Mock Write-CapsulenvMessage {} -ModuleName Capsulenv
        Mock Invoke-CapsulenvScoopCommand { 0 } -ModuleName Capsulenv

        & $script:Module { Invoke-CapsulenvAppCommand -Arguments @('install', 'demo', '--allow-trusted') }

        Should -Invoke Invoke-CapsulenvScoopCommand -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            $Arguments.Count -eq 2 -and $Arguments[0] -eq 'install' -and $Arguments[1] -eq 'demo'
        }
    }

    It 'refreshes metadata and uses the Capsulenv updater for PortableSafe ownership' {
        Mock Update-CapsulenvAppMetadata {} -ModuleName Capsulenv
        Mock Resolve-CapsulenvAppUpdateTarget {
            [pscustomobject]@{ Scope='Capsule'; Name='demo'; Reference='main/demo' }
        } -ModuleName Capsulenv
        Mock Update-CapsulenvPortablePackage { @() } -ModuleName Capsulenv
        Mock Invoke-CapsulenvScoopCommand { throw 'app lifecycle must stay inside the PortableSafe executor' } -ModuleName Capsulenv

        & $script:Module { Invoke-CapsulenvAppCommand -Arguments @('update', 'demo') }

        Should -Invoke Update-CapsulenvAppMetadata -ModuleName Capsulenv -Times 1 -Exactly
        Should -Invoke Update-CapsulenvPortablePackage -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter { $Reference -eq 'main/demo' }
        Should -Invoke Invoke-CapsulenvScoopCommand -ModuleName Capsulenv -Times 0 -Exactly
    }

    It 'supports local-only PortableSafe updates without refreshing bucket metadata' {
        Mock Update-CapsulenvAppMetadata {} -ModuleName Capsulenv
        Mock Resolve-CapsulenvAppUpdateTarget {
            [pscustomobject]@{ Scope='Capsule'; Name='demo'; Reference='main/demo' }
        } -ModuleName Capsulenv
        Mock Update-CapsulenvPortablePackage { @() } -ModuleName Capsulenv

        & $script:Module { Invoke-CapsulenvAppCommand -Arguments @('update', 'demo', '--local') }

        Should -Invoke Update-CapsulenvAppMetadata -ModuleName Capsulenv -Times 0 -Exactly
        Should -Invoke Update-CapsulenvPortablePackage -ModuleName Capsulenv -Times 1 -Exactly
    }

    It 'requires explicit trust before updating an upstream Scoop-owned app' {
        Mock Update-CapsulenvAppMetadata {} -ModuleName Capsulenv
        Mock Resolve-CapsulenvAppUpdateTarget {
            [pscustomobject]@{ Scope='User'; Name='demo'; Reference='user/demo' }
        } -ModuleName Capsulenv
        Mock Invoke-CapsulenvScoopCommand { 0 } -ModuleName Capsulenv

        $errorRecord = $null
        try {
            & $script:Module { Invoke-CapsulenvAppCommand -Arguments @('update', 'user/demo', '--local') }
        } catch {
            $errorRecord = $_
        }

        $errorRecord.FullyQualifiedErrorId | Should -Be 'Capsulenv.Package.TrustedUpdateRequired'
        Should -Invoke Invoke-CapsulenvScoopCommand -ModuleName Capsulenv -Times 0 -Exactly
    }

    It 'delegates an explicit trusted global update with upstream Scoop semantics' {
        Mock Update-CapsulenvAppMetadata {} -ModuleName Capsulenv
        Mock Resolve-CapsulenvAppUpdateTarget {
            [pscustomobject]@{ Scope='Global'; Name='demo'; Reference='global/demo' }
        } -ModuleName Capsulenv
        Mock Set-CapsulenvSessionEnvironment {} -ModuleName Capsulenv
        Mock Write-CapsulenvMessage {} -ModuleName Capsulenv
        Mock Invoke-CapsulenvScoopCommand { 0 } -ModuleName Capsulenv

        & $script:Module { Invoke-CapsulenvAppCommand -Arguments @('update', 'global/demo', '--allow-trusted', '--local') }

        Should -Invoke Invoke-CapsulenvScoopCommand -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            $Arguments.Count -eq 3 -and $Arguments[0] -eq 'update' -and $Arguments[1] -eq 'demo' -and $Arguments[2] -eq '--global'
        }
    }



    It 'keeps bucket management as a thin stock Scoop facade' {
        Mock Set-CapsulenvSessionEnvironment {} -ModuleName Capsulenv
        Mock Invoke-CapsulenvScoopCommand { 0 } -ModuleName Capsulenv

        & $script:Module { Invoke-CapsulenvBucketCommand -Arguments @('add', 'extras') }
        & $script:Module { Invoke-CapsulenvBucketCommand -Arguments @('remove', 'extras') }
        & $script:Module { Invoke-CapsulenvBucketCommand -Arguments @('update') }

        Should -Invoke Invoke-CapsulenvScoopCommand -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            $Arguments.Count -eq 3 -and $Arguments[0] -eq 'bucket' -and $Arguments[1] -eq 'add' -and $Arguments[2] -eq 'extras'
        }
        Should -Invoke Invoke-CapsulenvScoopCommand -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            $Arguments.Count -eq 3 -and $Arguments[0] -eq 'bucket' -and $Arguments[1] -eq 'rm' -and $Arguments[2] -eq 'extras'
        }
        Should -Invoke Invoke-CapsulenvScoopCommand -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            $Arguments.Count -eq 1 -and $Arguments[0] -eq 'update'
        }
    }


}
