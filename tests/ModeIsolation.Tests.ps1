Describe 'Capsulenv install-mode isolation contracts' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:ScoopSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/40-Scoop.ps1') -Raw
        $script:EnvironmentSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/30-Environment.ps1') -Raw
        $script:BitwardenSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/50-Bitwarden.ps1') -Raw
        $script:BitwardenAgentSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/55-BitwardenSshAgent.ps1') -Raw
        $script:BrowserSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/60-Browser.ps1') -Raw
        $script:DoctorSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/70-Doctor.ps1') -Raw
        $script:ProjectCacheSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/36-ProjectCacheRegistry.ps1') -Raw
        $script:BootstrapSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/41-ScoopBootstrap.ps1') -Raw
        $script:PortableResetSource = Get-Content -LiteralPath (Join-Path $script:Root 'scripts/scoop-capsulenv-portable-reset.ps1') -Raw
    }

    It 'has one Pester-only test path with no duplicated smoke suite' {
        (Test-Path -LiteralPath (Join-Path $script:Root 'tests/smoke')) | Should -BeFalse
        $runner = Get-Content -LiteralPath (Join-Path $script:Root 'scripts/Test-Capsulenv.ps1') -Raw
        $runner | Should -Match 'Invoke-Pester'
        $runner | Should -Not -Match '\.Smoke\.ps1'
    }

    It 'keeps ShellOnly Scoop repair capsule-owned and reserves user integration for User mode' {
        $script:PortableResetSource | Should -Match 'link_current'
        $script:PortableResetSource | Should -Match 'create_shims'
        $script:PortableResetSource | Should -Match 'persist_data'
        $script:PortableResetSource | Should -Match 'function Add-Path'
        $script:PortableResetSource | Should -Match '(?s)SetEnvironmentVariable\(\s*\$TargetEnvVar,.*?''Process'''
        $script:PortableResetSource | Should -Not -Match '(?s)SetEnvironmentVariable\(.*?''User'''
        $script:PortableResetSource | Should -Not -Match '(?s)SetEnvironmentVariable\(.*?''Machine'''
        $script:PortableResetSource | Should -Not -Match 'create_startmenu_shortcuts'
        $script:PortableResetSource | Should -Not -Match '\benv_add_path\b'
        $script:PortableResetSource | Should -Not -Match '\benv_set\b'
        $script:ScoopSource | Should -Match "IntegrationMode -eq 'ShellOnly'"
        $script:ScoopSource | Should -Match 'Invoke-CapsulenvPortableScoopReset'
        $script:ScoopSource | Should -Match "IntegrationMode -eq 'User'"
        $script:ScoopSource | Should -Match 'Invoke-CapsulenvConfiguredHookReplay'
        $script:ScoopSource | Should -Match 'lifecycle hook replay is disabled in ShellOnly mode'
    }

    It 'puts local and portable-global Scoop shims on only the Capsulenv environment plan' {
        $script:EnvironmentSource.Contains('(Join-Path $variables.SCOOP ''shims'')') | Should -BeTrue
        $script:EnvironmentSource.Contains('(Join-Path $variables.SCOOP_GLOBAL ''shims'')') | Should -BeTrue
        $script:EnvironmentSource | Should -Match 'SetEnvironmentVariable\(\$name, \[string\]\$plan\.Variables\[\$name\], ''Process''\)' 
        $script:EnvironmentSource | Should -Match 'Sync-CapsulenvUserEnvironment'
        $script:EnvironmentSource | Should -Match 'ManagedPathEntries'
        $script:EnvironmentSource | Should -Match 'Remove-CapsulenvPathEntries'
        $script:EnvironmentSource | Should -Match 'Get-CapsulenvRelocatedScoopPathEntries'
        $script:EnvironmentSource | Should -Match 'Get-CapsulenvScoopPathEnvironmentVariable'
        $script:EnvironmentSource | Should -Match "'ScoopRoot', 'ScoopGlobalRoot'"
        $script:EnvironmentSource | Should -Match 'SCOOP_CACHE'
        $script:BootstrapSource.Contains('set "SCOOP_PS1=%~dp0..\apps\scoop\current\bin\scoop.ps1"') | Should -BeTrue
        $script:BootstrapSource | Should -Match 'ReadAllText\(\$cmdPath\)'
    }

    It 'uses process Git config and leaves the Windows ssh-agent service alone in ShellOnly mode' {
        $script:BitwardenSource | Should -Match 'GIT_CONFIG_COUNT'
        $script:BitwardenSource | Should -Match 'GIT_CONFIG_KEY_\$index'
        $script:BitwardenSource | Should -Match 'if \(\$mode -eq ''ShellOnly''\)' 
        $script:BitwardenSource | Should -Match 'Git uses Microsoft OpenSSH through a Capsulenv process-only config overlay'
        $script:BitwardenSource | Should -Match 'git config --global'
        $script:BitwardenSource | Should -Match 'ShellOnly mode cannot change the Windows ssh-agent service'
        $script:BitwardenAgentSource | Should -Match 'ShellOnly mode leaves the Windows ssh-agent service unchanged'
        $script:BitwardenSource | Should -Match 'function Get-CapsulenvBitwardenProcesses'
        $script:BitwardenSource | Should -Match 'A non-capsule Bitwarden process is running'
        $script:BitwardenSource | Should -Match 'Capsulenv will not reuse, stop, or patch it'
        $script:BitwardenAgentSource | Should -Match 'Get-CapsulenvBitwardenProcesses'
        $script:DoctorSource | Should -Match 'Bitwarden process ownership'
    }


    It 'restores Capsulenv-owned persistent integrations when leaving User mode' {
        $script:EnvironmentSource | Should -Match 'Restore-CapsulenvGitOpenSshGlobal -IfPresent'
        $script:EnvironmentSource | Should -Match 'Restore-CapsulenvWindowsSshAgent -Confirm:\$false'
        $script:EnvironmentSource | Should -Match 'Run restore-user from an elevated terminal'
        $script:EnvironmentSource | Should -Match 'Initialize-CapsulenvGitOpenSshSession'
        $script:EnvironmentSource | Should -Match 'Sync-CapsulenvUserEnvironment -RelocationContext \$relocationContext'
        $script:BitwardenSource | Should -Match 'Set-CapsulenvGitOpenSshIntent'
        $script:BitwardenSource | Should -Match 'function Restore-CapsulenvGitOpenSshGlobal'
    }

    It 'binds Capsulenv browser commands to Scoop-persisted profiles' {
        $config = Import-PowerShellDataFile (Join-Path $script:Root 'config/capsulenv.psd1')
        @($config.Browsers.Firefox.ProfileCandidates).Count | Should -BeGreaterThan 0
        @($config.Browsers.Zen.ProfileCandidates).Count | Should -BeGreaterThan 0
        @($config.Browsers.LibreWolf.ProfileCandidates).Count | Should -BeGreaterThan 0
        $config.Browsers.Firefox.ProfileArgument | Should -Be '-profile'
        $config.Browsers.Zen.ProfileArgument | Should -Be '-profile'
        $config.Browsers.LibreWolf.ProfileArgument | Should -Be '-profile'
        @($config.Browsers.Firefox.ShellOnlyArguments) | Should -Contain '-no-remote'
        @($config.Browsers.Zen.ShellOnlyArguments) | Should -Contain '-no-remote'
        @($config.Browsers.LibreWolf.ShellOnlyArguments) | Should -Contain '-no-remote'
        $script:BrowserSource | Should -Match 'never fall back to an unrelated host profile'
        $script:BrowserSource | Should -Match '--host never falls back to a different Gecko product'
        $script:BrowserSource | Should -Match 'Test-CapsulenvPathUnderPortableScoop'
        $script:BrowserSource | Should -Match 'App Paths'
        $script:BrowserSource | Should -Match '\$modeArguments = if \(\$UseHostExecutable -or \(Get-CapsulenvInstallMode\) -eq ''ShellOnly''\)'
        $script:BrowserSource | Should -Match 'foreach \(\$modeArgument in @\(\$modeArguments\)\)'
    }

    It 'records enough ownership evidence to repair copied file hardlinks safely' {
        $script:ProjectCacheSource | Should -Match 'LastFileFingerprint'
        $script:ProjectCacheSource | Should -Match 'SHA256'
        $script:ProjectCacheSource | Should -Match 'Managed hard-link copies diverged after relocation'
        $script:ProjectCacheSource | Should -Match 'Refusing to replace an unrecognized file after hard-link relocation'
    }
}
