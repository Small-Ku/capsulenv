Describe 'Capsulenv build and install' {
    It 'passes runtime build, shell-only install, update preservation, and installed-module checks' {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        function Assert-CapsulenvBuildInstallTest {
            param(
                [Parameter(Mandatory = $true)][bool]$Condition,
                [Parameter(Mandatory = $true)][string]$Message
            )

            if (-not $Condition) {
                throw $Message
            }
        }

        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("capsulenv-build-install-test-{0}" -f [Guid]::NewGuid().ToString('N'))
        $buildRoot = Join-Path $temporaryRoot 'build'
        $installRoot = Join-Path $temporaryRoot 'install'

        try {
            [void](New-Item -ItemType Directory -Path $temporaryRoot -Force)

            $build = & (Join-Path (Join-Path $root 'scripts') 'Build-Capsulenv.ps1') -OutputPath $buildRoot
            Assert-CapsulenvBuildInstallTest `
                -Condition (Test-Path -LiteralPath $build.ModulePath -PathType Leaf) `
                -Message 'Runtime build did not create the generated module manifest.'
            Assert-CapsulenvBuildInstallTest `
                -Condition (Test-Path -LiteralPath (Join-Path $buildRoot '.capsulenv-runtime.json') -PathType Leaf) `
                -Message 'Runtime build metadata was not created.'
            foreach ($runtimeDoc in @(
                'README.md',
                'docs/ARCHITECTURE.md',
                'docs/DEVELOPMENT.md',
                'docs/INSTALL.md',
                'docs/MIGRATION.md',
                'docs/TOOLS.md'
            )) {
                Assert-CapsulenvBuildInstallTest `
                    -Condition (Test-Path -LiteralPath (Join-Path $buildRoot $runtimeDoc) -PathType Leaf) `
                    -Message "Runtime build did not include documentation: $runtimeDoc"
            }

            $installerPath = Join-Path (Join-Path $root 'scripts') 'Install-Capsulenv.ps1'
            $environmentSentinels = [ordered]@{
                CAPSULENV_ROOT = 'caller-capsulenv-root'
                SCOOP = 'caller-scoop-root'
                SCOOP_GLOBAL = 'caller-scoop-global-root'
                SCOOP_CACHE = 'caller-scoop-cache'
                CAPSULENV_MODULE_ROOT = 'caller-module-root'
            }
            $environmentOriginals = @{}
            foreach ($name in $environmentSentinels.Keys) {
                $environmentOriginals[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
                [Environment]::SetEnvironmentVariable($name, [string]$environmentSentinels[$name], 'Process')
            }
            try {
                $install = & $installerPath $installRoot
                foreach ($name in $environmentSentinels.Keys) {
                    Assert-CapsulenvBuildInstallTest `
                        -Condition ([Environment]::GetEnvironmentVariable($name, 'Process') -eq [string]$environmentSentinels[$name]) `
                        -Message "Installer leaked process environment variable $name into its caller."
                }
            } finally {
                foreach ($name in $environmentOriginals.Keys) {
                    [Environment]::SetEnvironmentVariable($name, $environmentOriginals[$name], 'Process')
                }
            }
            Assert-CapsulenvBuildInstallTest `
                -Condition (Test-Path -LiteralPath $install.Launcher -PathType Leaf) `
                -Message 'Installer did not create the capsulenv launcher.'

            $installMarkerPath = Join-Path $installRoot '.capsulenv-install.json'
            $runtimeMetadataPath = Join-Path $installRoot '.capsulenv-runtime.json'
            Assert-CapsulenvBuildInstallTest `
                -Condition (Test-Path -LiteralPath $runtimeMetadataPath -PathType Leaf) `
                -Message 'Installer did not copy runtime metadata.'
            $installMarker = Get-Content -LiteralPath $installMarkerPath -Raw | ConvertFrom-Json
            Assert-CapsulenvBuildInstallTest `
                -Condition (@($installMarker.ManagedFiles) -contains '.capsulenv-runtime.json') `
                -Message 'Installer does not own the runtime metadata file.'
            Assert-CapsulenvBuildInstallTest `
                -Condition ([int]$installMarker.SchemaVersion -eq 2) `
                -Message 'Installer did not write the install-mode-aware marker schema.'
            Assert-CapsulenvBuildInstallTest `
                -Condition ([string]$installMarker.InstallMode -eq 'ShellOnly') `
                -Message 'Fresh installation must default to ShellOnly mode.'
            Assert-CapsulenvBuildInstallTest `
                -Condition ((Get-Content -LiteralPath (Join-Path $installRoot 'scoop/config.json') -Raw).Trim() -eq '{}') `
                -Message 'Installer did not establish the portable Scoop config boundary.'
            $modeStatePaths = @(Get-ChildItem -LiteralPath (Join-Path (Join-Path $installRoot '.capsulenv') 'user-integrations') -Filter 'install-mode.json' -File -Recurse -ErrorAction SilentlyContinue)
            Assert-CapsulenvBuildInstallTest `
                -Condition ($modeStatePaths.Count -eq 1) `
                -Message 'Fresh installation did not create exactly one host-scoped integration ledger.'
            $modeState = Get-Content -LiteralPath $modeStatePaths[0].FullName -Raw | ConvertFrom-Json
            Assert-CapsulenvBuildInstallTest `
                -Condition ([string]$modeState.Mode -eq 'ShellOnly') `
                -Message 'Fresh installation did not persist ShellOnly mode state for the current host/user.'

            $unmanagedPath = Join-Path $installRoot 'unmanaged.txt'
            $localConfigPath = Join-Path (Join-Path $installRoot 'config') 'capsulenv.local.psd1'
            $cacheStatePath = Join-Path (Join-Path $installRoot 'cache') 'preserved.txt'
            $privateModuleStatePath = Join-Path (Join-Path (Join-Path (Join-Path $installRoot 'PowerShell') 'Modules') 'PrivateTest') 'preserved.txt'
            'keep-me' | Set-Content -LiteralPath $unmanagedPath -Encoding UTF8
'@{ ToolStorage = @{ Enabled = $false } }' | Set-Content -LiteralPath $localConfigPath -Encoding UTF8
            'cache-state' | Set-Content -LiteralPath $cacheStatePath -Encoding UTF8
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $privateModuleStatePath) -Force)
            'module-state' | Set-Content -LiteralPath $privateModuleStatePath -Encoding UTF8

            [void](& $installerPath $installRoot)
            Assert-CapsulenvBuildInstallTest `
                -Condition ((Get-Content -LiteralPath $unmanagedPath -Raw).Trim() -eq 'keep-me') `
                -Message 'Installer update changed an unmanaged destination file.'
            Assert-CapsulenvBuildInstallTest `
                -Condition ((Get-Content -LiteralPath $localConfigPath -Raw).Contains('Enabled = $false')) `
                -Message 'Installer update replaced the local capsulenv configuration.'
            Assert-CapsulenvBuildInstallTest `
                -Condition ((Get-Content -LiteralPath $cacheStatePath -Raw).Trim() -eq 'cache-state') `
                -Message 'Installer update changed mutable cache state.'
            Assert-CapsulenvBuildInstallTest `
                -Condition ((Get-Content -LiteralPath $privateModuleStatePath -Raw).Trim() -eq 'module-state') `
                -Message 'Installer update changed the portable private-module store.'

            Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
            $installedModulePath = Join-Path (Join-Path (Join-Path $installRoot 'modules') 'Capsulenv') 'Capsulenv.psd1'
            Import-Module $installedModulePath -Force
            Assert-CapsulenvBuildInstallTest `
                -Condition ($null -ne (Get-Command Invoke-Capsulenv -Module Capsulenv -ErrorAction SilentlyContinue)) `
                -Message 'Installed prebuilt module does not export Invoke-Capsulenv.'
            Assert-CapsulenvBuildInstallTest `
                -Condition ((Get-Alias cenv -ErrorAction Stop).Definition -eq 'Invoke-Capsulenv') `
                -Message 'Installed prebuilt module does not export the cenv alias.'

            $previousCapsulenvRoot = $env:CAPSULENV_ROOT
            $previousModulePath = $env:PSModulePath
            try {
                $env:CAPSULENV_ROOT = $installRoot
                [void](Set-CapsulenvSessionEnvironment)
                $expectedPrivateModuleRoot = [System.IO.Path]::GetFullPath((Join-Path $installRoot 'PowerShell/Modules'))
                Assert-CapsulenvBuildInstallTest `
                    -Condition ([string]$env:CAPSULENV_MODULE_ROOT -eq $expectedPrivateModuleRoot) `
                    -Message 'Installed runtime did not expose CAPSULENV_MODULE_ROOT.'
                $effectiveModulePaths = @($env:PSModulePath -split [regex]::Escape([string][System.IO.Path]::PathSeparator))
                Assert-CapsulenvBuildInstallTest `
                    -Condition ($effectiveModulePaths -contains $expectedPrivateModuleRoot) `
                    -Message 'Installed runtime did not prepend the portable private-module root to PSModulePath.'
            } finally {
                $env:CAPSULENV_ROOT = $previousCapsulenvRoot
                $env:PSModulePath = $previousModulePath
            }

            & (Join-Path (Join-Path $installRoot 'scripts') 'Invoke-Capsulenv.ps1') help
            Write-Host 'capsulenv build/install Pester checks passed.' -ForegroundColor Green
        } finally {
            Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }
}
