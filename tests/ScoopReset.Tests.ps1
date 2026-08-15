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
        Mock Invoke-CapsulenvUserScoopReset {} -ModuleName Capsulenv
        Mock Invoke-CapsulenvScoopCommand { throw 'native scoop command must not be used for User reset' } -ModuleName Capsulenv

        Reset-CapsulenvScoop -Apps @('*') -IntegrationMode User -Quiet | Should -BeTrue

        Should -Invoke Invoke-CapsulenvUserScoopReset -ModuleName Capsulenv -Times 1 -Exactly
        Should -Invoke Invoke-CapsulenvPortableScoopReset -ModuleName Capsulenv -Times 0 -Exactly
        Should -Invoke Invoke-CapsulenvScoopCommand -ModuleName Capsulenv -Times 0 -Exactly
    }

    It 'keeps ShellOnly on the non-persistent portable reset helper' {
        Mock Invoke-CapsulenvPortableScoopReset {} -ModuleName Capsulenv
        Mock Invoke-CapsulenvUserScoopReset { throw 'User reset helper must not run in ShellOnly' } -ModuleName Capsulenv

        Reset-CapsulenvScoop -Apps @('*') -IntegrationMode ShellOnly -Quiet | Should -BeTrue

        Should -Invoke Invoke-CapsulenvPortableScoopReset -ModuleName Capsulenv -Times 1 -Exactly
        Should -Invoke Invoke-CapsulenvUserScoopReset -ModuleName Capsulenv -Times 0 -Exactly
    }
}
