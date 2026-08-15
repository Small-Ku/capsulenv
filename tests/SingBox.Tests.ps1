Describe 'Capsulenv sing-box integration contracts' {
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

    It 'builds run and check plans from the configured Scoop app manifest and persist root' {
        Mock Get-CapsulenvSingBoxDefinition {
            @{
                Enabled = $true
                AutoConnect = $true
                App = 'global/private-network'
                BinName = 'private-net'
                ConfigPath = 'profiles\home.json'
                ConfigDirectory = ''
                ExtraArguments = @('--disable-color')
            }
        } -ModuleName Capsulenv
        Mock Resolve-CapsulenvScoopAppExecutable { 'X:\apps\private-network\current\private-net.exe' } -ModuleName Capsulenv
        Mock Resolve-CapsulenvScoopAppPersistPath { 'X:\persist\private-network\profiles\home.json' } -ModuleName Capsulenv
        Mock Test-Path { $true } -ModuleName Capsulenv

        $run = & $script:Module { Get-CapsulenvSingBoxLaunchPlan -Action Run }
        $check = & $script:Module { Get-CapsulenvSingBoxLaunchPlan -Action Check }

        $run.App | Should -Be 'global/private-network'
        ($run.Arguments -join '|') | Should -Be 'run|-c|X:\persist\private-network\profiles\home.json|--disable-color'
        ($check.Arguments -join '|') | Should -Be 'check|-c|X:\persist\private-network\profiles\home.json'
        Should -Invoke Resolve-CapsulenvScoopAppExecutable -ModuleName Capsulenv -Times 2 -Exactly -ParameterFilter {
            $App -eq 'global/private-network' -and $BinName -eq 'private-net'
        }
        Should -Invoke Resolve-CapsulenvScoopAppPersistPath -ModuleName Capsulenv -Times 2 -Exactly -ParameterFilter {
            $App -eq 'global/private-network' -and $RelativePath -eq 'profiles\home.json'
        }
    }

    It 'skips automatic connection when the configured Scoop app is not installed' {
        Mock Get-CapsulenvSingBoxDefinition {
            @{ Enabled = $true; AutoConnect = $true; App = 'custom-sing-box' }
        } -ModuleName Capsulenv
        Mock Get-CapsulenvInstalledScoopApp { throw 'not installed' } -ModuleName Capsulenv
        Mock Start-CapsulenvSingBox {} -ModuleName Capsulenv
        Mock Write-CapsulenvMessage {} -ModuleName Capsulenv

        & $script:Module { Initialize-CapsulenvSingBox }

        Should -Invoke Start-CapsulenvSingBox -ModuleName Capsulenv -Times 0 -Exactly
        Should -Invoke Write-CapsulenvMessage -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            $Level -eq 'Detail' -and $Message -like '*custom-sing-box*not installed*'
        }
    }
}
