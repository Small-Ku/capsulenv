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

        { & $script:Module { Invoke-CapsulenvAppCommand -Arguments @('install', 'demo') } } |
            Should -Throw '*--allow-trusted*'
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
