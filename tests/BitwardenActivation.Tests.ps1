Describe 'Capsulenv Bitwarden activation contracts' {
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

    It 'keeps automatic Bitwarden startup disabled by default' {
        $config = Import-PowerShellDataFile (Join-Path $script:Root 'config/capsulenv.psd1')
        $config.Bitwarden.StartOnEnter | Should -BeFalse
    }

    It 'does not abort shell activation when optional auto-start meets a foreign Bitwarden' {
        Mock Get-CapsulenvConfiguration {
            @{
                Bitwarden = @{
                    Enabled = $true
                    SetSshAuthSock = $false
                    StartOnEnter = $true
                }
            }
        } -ModuleName Capsulenv
        Mock Initialize-CapsulenvGitOpenSshSession {} -ModuleName Capsulenv
        Mock Get-CapsulenvBitwardenProcesses {
            [pscustomobject]@{
                Process = [pscustomobject]@{ Id = 1234 }
                Path = 'C:\Program Files\Bitwarden\Bitwarden.exe'
                CapsuleOwned = $false
            }
        } -ModuleName Capsulenv
        Mock Start-CapsulenvBitwarden {} -ModuleName Capsulenv
        Mock Write-CapsulenvMessage {} -ModuleName Capsulenv

        & $script:Module { Initialize-CapsulenvBitwarden }

        Should -Invoke Start-CapsulenvBitwarden -ModuleName Capsulenv -Times 0 -Exactly
        Should -Invoke Write-CapsulenvMessage -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            $Level -eq 'Warning' -and $Message -like '*Automatic capsule Bitwarden start skipped*'
        }
    }

    It 'keeps explicit Bitwarden start strict around foreign processes' {
        Mock Get-CapsulenvConfiguration {
            @{ Bitwarden = @{ Enabled = $true } }
        } -ModuleName Capsulenv
        Mock Get-CapsulenvBitwardenProcesses {
            [pscustomobject]@{
                Process = [pscustomobject]@{ Id = 4321 }
                Path = 'C:\Program Files\Bitwarden\Bitwarden.exe'
                CapsuleOwned = $false
            }
        } -ModuleName Capsulenv

        & $script:Module {
            { Start-CapsulenvBitwarden } | Should -Throw '*A non-capsule Bitwarden process is running*'
        }
    }
}
