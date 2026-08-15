Describe 'Capsulenv Scoop reset mode dispatch' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force
    }

    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }

    It 'uses the self-host-safe User reset helper instead of native scoop reset' {
        Mock Invoke-CapsulenvPortableScoopReset {} -ModuleName Capsulenv
        Mock Invoke-CapsulenvUserScoopReset { $true } -ModuleName Capsulenv
        Mock Invoke-CapsulenvScoopCommand { throw 'native scoop command must not be used for User reset' } -ModuleName Capsulenv

        Reset-CapsulenvScoop -Apps @('*') -IntegrationMode User -Quiet | Should -BeTrue

        Should -Invoke Invoke-CapsulenvUserScoopReset -ModuleName Capsulenv -Times 1 -Exactly
        Should -Invoke Invoke-CapsulenvPortableScoopReset -ModuleName Capsulenv -Times 0 -Exactly
        Should -Invoke Invoke-CapsulenvScoopCommand -ModuleName Capsulenv -Times 0 -Exactly
    }


    It 'keeps Scoop command output out of the returned exit-code value' {
        $fakeScoop = Join-Path $TestDrive 'fake-scoop.ps1'
        @'
Write-Output 'Creating shim for pwsh.'
$global:LASTEXITCODE = 0
'@ | Set-Content -LiteralPath $fakeScoop -Encoding UTF8
        Mock Get-CapsulenvScoopExecutable { $fakeScoop } -ModuleName Capsulenv

        $exitCode = & (Get-Module Capsulenv) { Invoke-CapsulenvScoopCommand -Arguments @('noop') -AllowFailure }

        @($exitCode).Count | Should -Be 1
        $exitCode | Should -BeOfType ([int])
        $exitCode | Should -Be 0
    }

    It 'keeps a deferred running app non-fatal and reports the User reset as incomplete' {
        Mock Set-CapsulenvSessionEnvironment {} -ModuleName Capsulenv
        Mock Get-CapsulenvScoopUserResetScriptPath { 'mock-user-reset.ps1' } -ModuleName Capsulenv
        Mock Install-CapsulenvTemporaryScoopCommand {
            [pscustomobject]@{ Command = 'capsulenv-user-reset-test'; Path = (Join-Path $TestDrive 'temporary-reset.ps1') }
        } -ModuleName Capsulenv
        Mock Invoke-CapsulenvScoopCommand { 2 } -ModuleName Capsulenv
        Mock Test-Path { $false } -ModuleName Capsulenv

        $result = & (Get-Module Capsulenv) { Invoke-CapsulenvUserScoopReset -Apps @('*') -DeferRunningApps }

        $result | Should -BeFalse
        Should -Invoke Invoke-CapsulenvScoopCommand -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            $AllowFailure -and $Arguments -contains '-DeferRunningApps'
        }
    }

    It 'keeps explicit User reset strict when deferred mode is not requested' {
        Mock Set-CapsulenvSessionEnvironment {} -ModuleName Capsulenv
        Mock Get-CapsulenvScoopUserResetScriptPath { 'mock-user-reset.ps1' } -ModuleName Capsulenv
        Mock Install-CapsulenvTemporaryScoopCommand {
            [pscustomobject]@{ Command = 'capsulenv-user-reset-test'; Path = (Join-Path $TestDrive 'temporary-reset.ps1') }
        } -ModuleName Capsulenv
        Mock Invoke-CapsulenvScoopCommand { 1 } -ModuleName Capsulenv
        Mock Test-Path { $false } -ModuleName Capsulenv

        { & (Get-Module Capsulenv) { Invoke-CapsulenvUserScoopReset -Apps @('librewolf') } } |
            Should -Throw '*failed with exit code 1*'
        Should -Invoke Invoke-CapsulenvScoopCommand -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            $AllowFailure -and $Arguments -notcontains '-DeferRunningApps'
        }
    }

    It 'keeps ShellOnly on the non-persistent portable reset helper' {
        Mock Invoke-CapsulenvPortableScoopReset {} -ModuleName Capsulenv
        Mock Invoke-CapsulenvUserScoopReset { throw 'User reset helper must not run in ShellOnly' } -ModuleName Capsulenv

        Reset-CapsulenvScoop -Apps @('*') -IntegrationMode ShellOnly -Quiet | Should -BeTrue

        Should -Invoke Invoke-CapsulenvPortableScoopReset -ModuleName Capsulenv -Times 1 -Exactly
        Should -Invoke Invoke-CapsulenvUserScoopReset -ModuleName Capsulenv -Times 0 -Exactly
    }
}
