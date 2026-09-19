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
        $script:PackageExecutorSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/44-PackageExecutor.ps1') -Raw
        $script:PackageHostIntegrationSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/45-PackageHostIntegration.ps1') -Raw
        $script:LegacyProjectionSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/46-LegacyScoopProjection.ps1') -Raw
        . (Join-Path $script:Root 'src/05-DataFile.ps1')
    }

    It 'has one Pester-only test path with no duplicated smoke suite' {
        (Test-Path -LiteralPath (Join-Path $script:Root 'tests/smoke')) | Should -BeFalse
        $runner = Get-Content -LiteralPath (Join-Path $script:Root 'scripts/Test-Capsulenv.ps1') -Raw
        $runner | Should -Match 'Invoke-Pester'
        $runner | Should -Match 'Get-ChildItem -LiteralPath \$testsRoot -Filter ''\*\.Tests\.ps1'''
        $runner | Should -Match '\$config\.Run\.Path = \$testPath'
        $runner | Should -Not -Match '\.Smoke\.ps1'
    }

    It 'keeps package repair bounded and reserves explicit host integration for User mode' {
        $script:LegacyProjectionSource | Should -Match 'Repair-CapsulenvLegacyPersistProjection'
        $script:LegacyProjectionSource | Should -Match 'Cannot prove the active version'
        $script:LegacyProjectionSource | Should -Match 'Refusing to replace a normal directory'
        $script:LegacyProjectionSource | Should -Match 'Repair-CapsulenvPackageFileProjection'
        $script:LegacyProjectionSource | Should -Not -Match ([regex]::Escape('apps\scoop\current\lib'))
        $script:LegacyProjectionSource | Should -Not -Match 'shortcut_folder'
        $script:ScoopSource | Should -Match 'Repair-CapsulenvInstalledAppProjections'
        $script:ScoopSource | Should -Not -Match 'Invoke-CapsulenvPortableScoopReset|Invoke-CapsulenvUserScoopReset'
        $script:ScoopSource | Should -Not -Match 'Invoke-CapsulenvConfiguredHookReplay'
        $script:PackageExecutorSource | Should -Match 'PortableSafe'
        $script:PackageExecutorSource | Should -Match 'Get-CapsulenvPackageShimRoot'
        $script:PackageHostIntegrationSource | Should -Match "Get-CapsulenvInstallMode\) -ne 'User'"
        $script:PackageHostIntegrationSource | Should -Match "'capsule/'"
        $script:PackageHostIntegrationSource | Should -Match 'New-CapsulenvUserIntegrationPackageBridge'
        $runtimeAdapters = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'module-runtime') -Filter 'scoop-capsulenv-*' -File -ErrorAction SilentlyContinue)
        $runtimeAdapters.Count | Should -Be 0
    }

    It 'puts local and portable-global Scoop shims on only the Capsulenv environment plan' {
        $script:EnvironmentSource.Contains('(Join-Path $variables.SCOOP ''shims'')') | Should -BeTrue
        $script:EnvironmentSource.Contains('(Join-Path $variables.SCOOP_GLOBAL ''shims'')') | Should -BeTrue
        $script:EnvironmentSource | Should -Match 'Get-CapsulenvPackageShimRoot'
        $script:BootstrapSource | Should -Match '\.\.\\apps\\scoop\\current\\bin\\scoop\.ps1'
        $script:BootstrapSource | Should -Not -Match 'scoop-capsulenv-gateway|scoop-capsulenv-shellonly-policy'
        $script:EnvironmentSource | Should -Match 'SetEnvironmentVariable\(\$name, \[string\]\$plan\.Variables\[\$name\], ''Process''\)' 
        $script:EnvironmentSource | Should -Match 'Sync-CapsulenvUserEnvironment'
        $script:EnvironmentSource | Should -Match 'ManagedPathEntries'
        $script:EnvironmentSource | Should -Match 'Remove-CapsulenvPathEntries'
        $script:EnvironmentSource | Should -Match 'Get-CapsulenvRelocatedScoopPathEntries'
        $script:EnvironmentSource | Should -Match 'Get-CapsulenvScoopPathEnvironmentVariable'
        $script:EnvironmentSource | Should -Match "'ScoopRoot', 'ScoopGlobalRoot'"
        $script:EnvironmentSource | Should -Match 'SCOOP_CACHE'
        $script:EnvironmentSource.Contains('[string]$IntegrationMode = (Get-CapsulenvInstallMode)') | Should -BeTrue
        $script:EnvironmentSource.Contains("SetEnvironmentVariable('CAPSULENV_MODE', `$IntegrationMode, 'Process')") | Should -BeTrue
        $script:EnvironmentSource.Contains("if ([string]`$env:CAPSULENV_MODE -eq 'User')") | Should -BeTrue
        $script:BootstrapSource.Contains('set "CAPSULENV_CONTROL_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"') | Should -BeTrue
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
        $script:DefaultBrowserSource | Should -Match 'Persistent default-browser registration requires a valid host-local UserIntegration bridge'
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

    It 'binds Capsulenv browser commands to persisted runtime profiles' {
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
