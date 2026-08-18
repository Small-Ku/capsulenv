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
            $AllowFailure -and $Arguments -contains ':defer' -and $Arguments -notcontains '-DeferRunningApps'
        }
    }


    It 'keeps deferred mode intact through Scoop-style string-array dispatch' {
        $fakeRoot = Join-Path $TestDrive 'dispatch-root'
        $fakeScoop = Join-Path $fakeRoot 'scoop'
        $fakeShims = Join-Path $fakeScoop 'shims'
        $fakeLib = Join-Path $fakeScoop 'apps/scoop/current/lib'
        $fakeScripts = Join-Path $fakeRoot 'modules/Capsulenv/runtime'
        New-Item -ItemType Directory -Path $fakeShims, $fakeLib, $fakeScripts -Force | Out-Null

        @'
function installed_apps($global) { if (-not $global) { 'librewolf' } }
function parse_app($requested) { @($requested, $null, $null) }
function installed($app, $global) { return (-not $global -and $app -eq 'librewolf') }
function Select-CurrentVersion { '1.0' }
function installed_manifest { [pscustomobject]@{} }
function install_info { [pscustomobject]@{ architecture = '64bit' } }
function is_admin { $false }
'@ | Set-Content -LiteralPath (Join-Path $fakeLib 'manifest.ps1') -Encoding UTF8
        foreach ($name in @('system.ps1', 'install.ps1', 'versions.ps1', 'shortcuts.ps1')) {
            Set-Content -LiteralPath (Join-Path $fakeLib $name) -Value '' -Encoding UTF8
        }
        Copy-Item -LiteralPath (Join-Path $script:Root 'module-runtime/scoop-capsulenv-user-policy.ps1') -Destination (Join-Path $fakeScripts 'scoop-capsulenv-user-policy.ps1')
        @'
function Test-CapsulenvResetHasBlockingProcesses {
    param([string]$App, [bool]$Global)
    return $true
}
'@ | Set-Content -LiteralPath (Join-Path $fakeScripts 'scoop-capsulenv-process-guard.ps1') -Encoding UTF8

        $helper = Join-Path $fakeShims 'scoop-capsulenv-user-reset-test.ps1'
        Copy-Item -LiteralPath (Join-Path $script:Root 'module-runtime/scoop-capsulenv-user-reset.ps1') -Destination $helper
        $oldRoot = $env:CAPSULENV_ROOT
        try {
            $env:CAPSULENV_ROOT = $fakeRoot
            Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
            [string[]]$dispatchArguments = @(':defer', 'librewolf')
            & $helper @dispatchArguments
            $LASTEXITCODE | Should -Be 2
        } finally {
            $env:CAPSULENV_ROOT = $oldRoot
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
            $AllowFailure -and $Arguments -contains ':strict' -and $Arguments -notcontains '-DeferRunningApps'
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
