Describe 'Capsulenv core static contracts' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $env:CAPSULENV_ROOT = $script:Root
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = Get-CapsulenvTestModuleBuild -Root $script:Root
        Import-Module $script:Build.ModulePath -Force -DisableNameChecking
        $script:Module = @(Get-Module Capsulenv)[-1]
    }

    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }

    It 'parses every shipped PowerShell source file and emits a marker-free merged module' {
        foreach ($file in @(Get-ChildItem -LiteralPath $script:Root -Recurse -Filter '*.ps1' -File | Where-Object {
            $_.FullName -notlike "$(Join-Path $script:Root '.build')*"
        })) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            @($errors).Count | Should -Be 0 -Because "PowerShell source must parse: $($file.FullName)"
        }

        Test-Path -LiteralPath $script:Build.ModulePath -PathType Leaf | Should -BeTrue
        $generatedModulePath = Join-Path (Split-Path -Parent $script:Build.ModulePath) 'Capsulenv.psm1'
        [System.IO.File]::ReadAllText($generatedModulePath) | Should -Not -Match '##MOD_EXEC##'
        [System.IO.File]::ReadAllText($script:Build.ModulePath) | Should -Not -Match '__GENERATED_'
    }

    It 'keeps development and release entrypoints unambiguous' {
        Test-Path -LiteralPath (Join-Path $script:Root 'capsulenv.cmd') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Root 'install.cmd') | Should -BeFalse
        foreach ($relative in @('scripts/capsulenv-dev.cmd', 'scripts/install.cmd', 'packaging/capsulenv.cmd', 'packaging/install.cmd')) {
            Test-Path -LiteralPath (Join-Path $script:Root $relative) -PathType Leaf | Should -BeTrue -Because "$relative is an explicit source/release entrypoint"
        }

        $launcherSource = [System.IO.File]::ReadAllText((Join-Path $script:Root 'packaging/capsulenv.cmd'))
        foreach ($required in @(
            'call :SelectWindowsPowerShell "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"',
            'for /f "delims=" %%P in (''where powershell.exe 2^>nul'') do call :SelectWindowsPowerShell "%%P"',
            '$PSVersionTable.PSEdition -eq ''Desktop''',
            '$PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -ge 1',
            '"%CAPSULENV_CONTROL_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass',
            '.capsulenv-runtime.json',
            'this directory is a release bundle, not an installed capsule',
            'install.cmd ^<destination^>',
            'modules\Capsulenv\runtime\Invoke-Capsulenv.ps1'
        )) {
            $launcherSource | Should -Match ([regex]::Escape($required)) -Because "batch launcher must preserve control-host/release behavior: $required"
        }
        $launcherSource | Should -Not -Match ([regex]::Escape('module-runtime\Invoke-Capsulenv.ps1'))
        $launcherSource | Should -Not -Match 'FindScoopPwsh|where pwsh\.exe|\\shims\\pwsh\.exe|\\apps\\pwsh\\current\\pwsh\.exe'
    }

    It 'keeps the PowerShell 5.1 analyzer policy as structured configuration' {
        $settings = Import-PowerShellDataFile -LiteralPath (Join-Path $script:Root 'PSScriptAnalyzerSettings.psd1')
        @($settings.IncludeRules) | Should -Contain 'PSUseCompatibleSyntax'
        @($settings.IncludeRules) | Should -Contain 'PSUseCompatibleCommands'
        @($settings.Rules.PSUseCompatibleSyntax.TargetVersions) | Should -Contain '5.1'
        @($settings.Rules.PSUseCompatibleCommands.TargetProfiles) | Should -Contain 'win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework'
    }

    It 'exports the supported public API from the generated module' {
        $required = @(
            'Invoke-Capsulenv', 'Initialize-Capsulenv', 'Invoke-CapsulenvDoctor',
            'Invoke-CapsulenvScoopRehydrate', 'Reset-CapsulenvScoop', 'Repair-CapsulenvInstalledAppProjections',
            'Get-CapsulenvPackageManifestPlan', 'Get-CapsulenvPackageInstallPlan', 'Install-CapsulenvPortablePackage',
            'Test-CapsulenvScoopRehydrationRequired', 'Get-CapsulenvRelocationContext', 'Invoke-CapsulenvPersistRelocationRepair',
            'Start-CapsulenvBrowser', 'Get-CapsulenvHostBrowserExecutable', 'Save-CapsulenvWeaselSeed', 'Restore-CapsulenvWeaselSeed',
            'Start-CapsulenvBitwarden', 'Set-CapsulenvBitwardenDesktopSshAgent', 'Restore-CapsulenvBitwardenDesktopSettings',
            'Get-CapsulenvBitwardenSshAgentStatus', 'Invoke-CapsulenvBitwardenSshAgentSetup', 'Restore-CapsulenvBitwardenSshAgentSetup',
            'Test-CapsulenvBitwardenSshAgent', 'Initialize-CapsulenvScoopBootstrap', 'Ensure-CapsulenvScoopPortableConfig',
            'Get-CapsulenvInstallMode', 'Set-CapsulenvInstallMode', 'Install-CapsulenvUserEnvironment', 'Enter-CapsulenvUserShell',
            'Enable-CapsulenvUserEnvironment', 'Restore-CapsulenvUserEnvironment', 'Initialize-CapsulenvToolStorage',
            'New-CapsulenvProjectCacheLink', 'Remove-CapsulenvProjectCacheLink', 'Get-CapsulenvToolStorageStatus',
            'Get-CapsulenvProjectCacheStatus', 'Repair-CapsulenvProjectCacheLinks', 'Get-CapsulenvManagedProjectCacheLinks',
            'Invoke-CapsulenvToolRelocationRepair', 'Repair-CapsulenvUvRelocation', 'Repair-CapsulenvPixiRelocation',
            'Register-CapsulenvToolWorkspace', 'Unregister-CapsulenvToolWorkspace', 'Get-CapsulenvToolWorkspaces',
            'Get-CapsulenvToolRelocationStatus', 'Get-CapsulenvIdentity', 'Get-CapsulenvScratchPath', 'Invoke-CapsulenvEject',
            'Get-CapsulenvOfflineReadiness', 'Invoke-CapsulenvOfflinePrefetch', 'Get-CapsulenvVersionDrift',
            'Get-CapsulenvScoopAppShortcuts', 'Get-CapsulenvScoopShortcutCatalog', 'Start-CapsulenvScoopShortcut'
        )
        foreach ($name in $required) {
            Get-Command $name -Module Capsulenv -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because "$name is part of the public API contract"
        }
    }

    It 'resolves core configuration and PowerShell launch state behaviorally' {
        $config = Get-CapsulenvConfiguration -Refresh
        $config.SchemaVersion | Should -Be 12
        [bool]$config.Scoop.Bootstrap.Enabled | Should -BeTrue
        [int]$config.Scoop.Bootstrap.GitDepth | Should -Be 1
        [string]$config.Bitwarden.Authorization | Should -Be 'always'

        $environmentPlan = & $script:Module { Get-CapsulenvEnvironmentPlan }
        $expectedModuleRoot = [System.IO.Path]::GetFullPath((Join-Path $script:Root 'PowerShell/Modules'))
        [string]$environmentPlan.Variables.CAPSULENV_MODULE_ROOT | Should -Be $expectedModuleRoot
        @($environmentPlan.ModulePathEntries) | Should -Contain $expectedModuleRoot

        $childPlan = & $script:Module { Get-CapsulenvPowerShellChildLaunchPlan -ShellPath 'pwsh.exe' -IntegrationMode ShellOnly -Command 'Get-Date' }
        @($childPlan.Arguments) | Should -Contain '-NoProfile'
        @($childPlan.Arguments) | Should -Contain '-ExecutionPolicy'
        @($childPlan.Arguments) | Should -Contain 'Bypass'
        [string]$environmentPlan.Variables.CAPSULENV_PSREADLINE_HISTORY | Should -Not -BeNullOrEmpty
    }

    It 'dispatches the help command through the built module' {
        { Invoke-Capsulenv help | Out-Host } | Should -Not -Throw
    }
}
