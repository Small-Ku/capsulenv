Describe 'Capsulenv install-mode isolation contracts' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:ScoopSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/40-Scoop.ps1') -Raw
        $script:EnvironmentSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/30-Environment.ps1') -Raw
        $script:BitwardenSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/50-Bitwarden.ps1') -Raw
        $script:BitwardenAgentSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/55-BitwardenSshAgent.ps1') -Raw
        $script:BrowserSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/60-Browser.ps1') -Raw
        $script:DefaultBrowserSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/62-DefaultBrowser.ps1') -Raw
        $script:DoctorSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/70-Doctor.ps1') -Raw
        $script:ProjectCacheSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/36-ProjectCacheRegistry.ps1') -Raw
        $script:BootstrapSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/41-ScoopBootstrap.ps1') -Raw
        $script:PortableResetSource = Get-Content -LiteralPath (Join-Path $script:Root 'module-runtime/scoop-capsulenv-portable-reset.ps1') -Raw
        $script:UserResetSource = Get-Content -LiteralPath (Join-Path $script:Root 'module-runtime/scoop-capsulenv-user-reset.ps1') -Raw
        $script:ResetGuardSource = Get-Content -LiteralPath (Join-Path $script:Root 'module-runtime/scoop-capsulenv-process-guard.ps1') -Raw
        $script:ScoopGatewaySource = Get-Content -LiteralPath (Join-Path $script:Root 'module-runtime/scoop-capsulenv-gateway.ps1') -Raw
        $script:ScoopShellOnlyPolicySource = Get-Content -LiteralPath (Join-Path $script:Root 'module-runtime/scoop-capsulenv-shellonly-policy.ps1') -Raw
        $script:ScoopUserPolicySource = Get-Content -LiteralPath (Join-Path $script:Root 'module-runtime/scoop-capsulenv-user-policy.ps1') -Raw
        . (Join-Path $script:Root 'src/05-DataFile.ps1')
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
        $script:PortableResetSource | Should -Not -Match '(?s)SetEnvironmentVariable\([^)]*?,\s*''User''\s*\)'
        $script:PortableResetSource | Should -Not -Match '(?s)SetEnvironmentVariable\([^)]*?,\s*''Machine''\s*\)'
        $script:PortableResetSource | Should -Not -Match 'create_startmenu_shortcuts'
        $script:PortableResetSource | Should -Not -Match '\benv_add_path\b'
        $script:PortableResetSource | Should -Not -Match '\benv_set\b'
        $script:PortableResetSource | Should -Match 'Test-CapsulenvResetHasBlockingProcesses'
        $script:ResetGuardSource | Should -Match '\$_.Id -ne \$PID'
        $script:ResetGuardSource | Should -Match 'test_running_process \$App \$Global'
        $script:UserResetSource | Should -Match 'Test-CapsulenvResetHasBlockingProcesses'
        $script:UserResetSource.Contains("':defer' { `$deferRunningApps = `$true }") | Should -BeTrue
        $script:UserResetSource | Should -Match '\$deferred = \$true'
        $script:UserResetSource | Should -Match 'if \(\$deferred\) \{ exit 2 \}'
        $script:UserResetSource | Should -Match 'scoop-capsulenv-user-policy.ps1'
        $script:UserResetSource | Should -Match 'create_startmenu_shortcuts'
        $script:UserResetSource | Should -Match 'env_add_path'
        $script:UserResetSource | Should -Match 'env_set'
        $script:ScoopSource | Should -Match 'Invoke-CapsulenvUserScoopReset'
        $script:ScoopSource | Should -Match '-DeferRunningApps:\(\$IntegrationMode -eq ''User''\)'
        $script:ScoopSource | Should -Match "IntegrationMode -eq 'ShellOnly'"
        $script:ScoopSource | Should -Match 'Invoke-CapsulenvPortableScoopReset'
        $script:ScoopSource | Should -Match "IntegrationMode -eq 'User'"
        $script:ScoopSource | Should -Match 'Invoke-CapsulenvConfiguredHookReplay'
        $script:ScoopSource | Should -Match 'lifecycle hook replay is disabled in ShellOnly mode'
        $script:ScoopGatewaySource | Should -Match "'install', 'update', 'uninstall', 'reset', 'shim'"
        $script:ScoopGatewaySource | Should -Match "'install', 'download', 'virustotal', 'import'"
        $script:ScoopGatewaySource | Should -Match 'could not guard its nested Scoop update'
        $script:ScoopGatewaySource | Should -Match 'could not guard its nested Scoop install'
        $script:ScoopGatewaySource | Should -Match "scoop-capsulenv-user-policy\.ps1"
        $script:ScoopGatewaySource | Should -Match "integrationMode -eq 'User'"
        $script:ScoopUserPolicySource | Should -Match "'Capsulenv Apps'"
        $script:ScoopUserPolicySource | Should -Not -Match "'Scoop Apps'"
        $script:ScoopGatewaySource.Contains('$script:CapsulenvGatewayPath = [System.IO.Path]::GetFullPath($PSCommandPath)') | Should -BeTrue
        $script:ScoopGatewaySource.Contains('$gatewayPath = $script:CapsulenvGatewayPath') | Should -BeTrue
        $script:ScoopGatewaySource.Contains("`$ps1Text = ('# {0}{1}' -f `$gatewayPath") | Should -BeTrue
        $script:ScoopGatewaySource.Contains("`$cmdText = ('@rem {0}{1}' -f `$gatewayPath") | Should -BeTrue
        $script:ScoopShellOnlyPolicySource.Contains("[Environment]::SetEnvironmentVariable(`$Name, `$Value, 'Process')") | Should -BeTrue
        $script:ScoopShellOnlyPolicySource | Should -Not -Match "SetEnvironmentVariable\(.*?'User'"
        $script:ScoopShellOnlyPolicySource | Should -Not -Match "SetEnvironmentVariable\(.*?'Machine'"
        $script:ScoopShellOnlyPolicySource | Should -Match 'function create_startmenu_shortcuts'
        $script:ScoopShellOnlyPolicySource | Should -Match 'skipping Scoop Start Menu shortcuts'
        $script:ScoopShellOnlyPolicySource | Should -Match "'Block'"
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
        $script:EnvironmentSource | Should -Match 'ShellOnlyLifecyclePolicy \| ConvertTo-Json -Compress'
        $script:EnvironmentSource.Contains('[string]$IntegrationMode = (Get-CapsulenvInstallMode)') | Should -BeTrue
        $script:EnvironmentSource.Contains("SetEnvironmentVariable('CAPSULENV_MODE', `$IntegrationMode, 'Process')") | Should -BeTrue
        $script:EnvironmentSource.Contains("if ([string]`$env:CAPSULENV_MODE -eq 'User')") | Should -BeTrue
        $script:EnvironmentSource | Should -Match "CAPSULENV_SCOOP_LIFECYCLE_POLICY.*'Process'"
        $script:BootstrapSource.Contains('set "CAPSULENV_SCOOP_GATEWAY=%CAPSULENV_ROOT%\modules\Capsulenv\runtime\scoop-capsulenv-gateway.ps1"') | Should -BeTrue
        $script:BootstrapSource.Contains('set "CAPSULENV_CONTROL_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"') | Should -BeTrue
        $script:BootstrapSource.Contains("Join-Path `$env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'") | Should -BeTrue
        $script:BootstrapSource | Should -Not -Match 'where pwsh\.exe'
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
        $script:EnvironmentSource | Should -Match 'Sync-CapsulenvConfiguredDefaultBrowser'
        $script:EnvironmentSource | Should -Match 'Assert-CapsulenvDefaultBrowserRestorable'
        $script:EnvironmentSource | Should -Match 'Restore-CapsulenvDefaultBrowserRegistration'
        $script:EnvironmentSource | Should -Match 'Remove-CapsulenvUserStartMenuShortcuts'
        $script:EnvironmentSource | Should -Match "'Capsulenv Apps'"
        $script:DefaultBrowserSource | Should -Match 'registeredAppUser='
        $script:DefaultBrowserSource | Should -Match 'UserChoice hashes'
        $script:DefaultBrowserSource | Should -Match 'HostIntegrationKey'
        $script:BitwardenSource | Should -Match 'Set-CapsulenvGitOpenSshIntent'
        $script:BitwardenSource | Should -Match 'function Restore-CapsulenvGitOpenSshGlobal'
    }

    It 'binds Capsulenv browser commands to Scoop-persisted profiles' {
        $config = Import-CapsulenvPowerShellDataFile -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1')
        $config.UserIntegration.DefaultBrowser | Should -Be ''
        $config.Browsers.Firefox.App | Should -Be 'firefox'
        $config.Browsers.Zen.App | Should -Be 'zen-browser'
        $config.Browsers.LibreWolf.App | Should -Be 'librewolf'
        $config.Browsers.Firefox.ProfilePath | Should -Be 'profile'
        $config.Browsers.Zen.ProfilePath | Should -Be 'profile'
        $config.Browsers.LibreWolf.ProfilePath | Should -Be 'Profiles\Default'
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
        $script:BrowserSource | Should -Match '\$modeArguments = if \('
        $script:BrowserSource | Should -Match 'Get-CapsulenvInstallMode\) -eq ''ShellOnly'''
        $script:BrowserSource | Should -Match 'foreach \(\$modeArgument in @\(\$modeArguments\)\)'
    }

    It 'records enough ownership evidence to repair copied file hardlinks safely' {
        $script:ProjectCacheSource | Should -Match 'LastFileFingerprint'
        $script:ProjectCacheSource | Should -Match 'SHA256'
        $script:ProjectCacheSource | Should -Match 'Managed hard-link copies diverged after relocation'
        $script:ProjectCacheSource | Should -Match 'Refusing to replace an unrecognized file after hard-link relocation'
    }
}
