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
}
