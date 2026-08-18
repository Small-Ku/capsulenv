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
        $relocatedInstallRoot = Join-Path $temporaryRoot 'relocated-install'
        $prebuiltInstallRoot = Join-Path $temporaryRoot 'prebuilt-install'

        try {
            [void](New-Item -ItemType Directory -Path $temporaryRoot -Force)

            $build = & (Join-Path (Join-Path $root 'scripts') 'Build-Capsulenv.ps1') -OutputPath $buildRoot
            Assert-CapsulenvBuildInstallTest `
                -Condition (Test-Path -LiteralPath $build.ModulePath -PathType Leaf) `
                -Message 'Runtime build did not create the generated module manifest.'
            Assert-CapsulenvBuildInstallTest `
                -Condition (Test-Path -LiteralPath (Join-Path $buildRoot '.capsulenv-runtime.json') -PathType Leaf) `
                -Message 'Runtime build metadata was not created.'
            Assert-CapsulenvBuildInstallTest `
                -Condition (Test-Path -LiteralPath (Join-Path $buildRoot 'install.cmd') -PathType Leaf) `
                -Message 'Minimal runtime is not directly installable: install.cmd is missing.'
            Assert-CapsulenvBuildInstallTest `
                -Condition (Test-Path -LiteralPath (Join-Path $buildRoot 'scripts/Install-Capsulenv.ps1') -PathType Leaf) `
                -Message 'Minimal runtime is not directly installable: installer script is missing.'
            Assert-CapsulenvBuildInstallTest `
                -Condition (Test-Path -LiteralPath (Join-Path $buildRoot 'modules/Capsulenv/runtime/Initialize-CapsulenvControlHost.ps1') -PathType Leaf) `
                -Message 'Runtime build did not include the isolated control-host bootstrap.'
            $runtimeMetadata = Get-Content -LiteralPath (Join-Path $buildRoot '.capsulenv-runtime.json') -Raw | ConvertFrom-Json
            Assert-CapsulenvBuildInstallTest `
                -Condition ([int]$runtimeMetadata.SchemaVersion -eq 3) `
                -Message 'Runtime build did not write the separated bundle/install metadata schema.'
            Assert-CapsulenvBuildInstallTest `
                -Condition (@($runtimeMetadata.ManagedFiles) -contains 'install.cmd') `
                -Message 'Runtime manifest does not own its installer entry point.'
            Assert-CapsulenvBuildInstallTest `
                -Condition (@($runtimeMetadata.ManagedFiles) -contains '.capsulenv-runtime.json') `
                -Message 'Runtime bundle manifest does not own its own metadata file.'
            Assert-CapsulenvBuildInstallTest `
                -Condition (@($runtimeMetadata.InstallFiles) -contains 'capsulenv.cmd') `
                -Message 'Runtime install payload does not include the portable launcher.'
            Assert-CapsulenvBuildInstallTest `
                -Condition (@($runtimeMetadata.InstallFiles) -contains 'modules/Capsulenv/Capsulenv.psm1') `
                -Message 'Runtime install payload does not include the generated module.'
            foreach ($bundleOnlyFile in @('install.cmd', 'README.md', 'scripts/Install-Capsulenv.ps1', '.capsulenv-runtime.json')) {
                Assert-CapsulenvBuildInstallTest `
                    -Condition (@($runtimeMetadata.InstallFiles) -notcontains $bundleOnlyFile) `
                    -Message "Runtime install payload unexpectedly includes bundle-only file: $bundleOnlyFile"
            }

            $forceRebuildOriginal = [Environment]::GetEnvironmentVariable('CAPSULENV_FORCE_REBUILD', 'Process')
            try {
                [Environment]::SetEnvironmentVariable('CAPSULENV_FORCE_REBUILD', '1', 'Process')
                & (Join-Path $buildRoot 'modules/Capsulenv/runtime/Invoke-Capsulenv.ps1') help
            } finally {
                [Environment]::SetEnvironmentVariable('CAPSULENV_FORCE_REBUILD', $forceRebuildOriginal, 'Process')
            }

            $runtimeMetadataPathForLaunch = Join-Path $buildRoot '.capsulenv-runtime.json'
            $runtimeMetadataLaunchBackup = Get-Content -LiteralPath $runtimeMetadataPathForLaunch -Raw
            try {
                Remove-Item -LiteralPath $runtimeMetadataPathForLaunch -Force
                & (Join-Path $buildRoot 'modules/Capsulenv/runtime/Invoke-Capsulenv.ps1') help
            } finally {
                [System.IO.File]::WriteAllText($runtimeMetadataPathForLaunch, $runtimeMetadataLaunchBackup)
            }

            $prebuiltInstaller = Join-Path $buildRoot 'scripts/Install-Capsulenv.ps1'
            $prebuiltInstall = & $prebuiltInstaller $prebuiltInstallRoot
            Assert-CapsulenvBuildInstallTest `
                -Condition (Test-Path -LiteralPath $prebuiltInstall.Launcher -PathType Leaf) `
                -Message 'Prebuilt runtime bundle could not install a new capsule.'
            $prebuiltMarker = Get-Content -LiteralPath (Join-Path $prebuiltInstallRoot '.capsulenv-install.json') -Raw | ConvertFrom-Json
            Assert-CapsulenvBuildInstallTest `
                -Condition ([string]$prebuiltMarker.Version -eq [string]$runtimeMetadata.Version) `
                -Message 'Prebuilt runtime installation did not preserve bundle version metadata.'
            foreach ($bundleOnlyFile in @('install.cmd', 'README.md', 'scripts/Install-Capsulenv.ps1', '.capsulenv-runtime.json')) {
                Assert-CapsulenvBuildInstallTest `
                    -Condition (-not (Test-Path -LiteralPath (Join-Path $prebuiltInstallRoot $bundleOnlyFile))) `
                    -Message "Prebuilt deployment copied bundle-only file into capsule: $bundleOnlyFile"
            }
            foreach ($runtimeScript in @(
                'modules/Capsulenv/runtime/scoop-capsulenv-gateway.ps1',
                'modules/Capsulenv/runtime/scoop-capsulenv-shellonly-policy.ps1'
            )) {
                Assert-CapsulenvBuildInstallTest `
                    -Condition (Test-Path -LiteralPath (Join-Path $buildRoot $runtimeScript) -PathType Leaf) `
                    -Message "Runtime build did not include Scoop ShellOnly policy component: $runtimeScript"
            }

            foreach ($runtimeDoc in @(
                'README.md',
                'docs/ARCHITECTURE.md',
                'docs/DEVELOPMENT.md',
                'docs/DEPLOYMENT.md',
                'docs/MIGRATION.md',
                'docs/TOOLS.md'
            )) {
                Assert-CapsulenvBuildInstallTest `
                    -Condition (Test-Path -LiteralPath (Join-Path $buildRoot $runtimeDoc) -PathType Leaf) `
                    -Message "Runtime build did not include documentation: $runtimeDoc"
            }

            $installerPath = Join-Path (Join-Path $root 'scripts') 'Install-Capsulenv.ps1'
            function Import-PowerShellDataFile {
                throw 'sentinel: Capsulenv installer/runtime must not depend on Import-PowerShellDataFile'
            }
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
                -Condition (-not (Test-Path -LiteralPath $runtimeMetadataPath)) `
                -Message 'Deployment copied bundle metadata into the portable capsule.'
            $installMarker = Get-Content -LiteralPath $installMarkerPath -Raw | ConvertFrom-Json
            Assert-CapsulenvBuildInstallTest `
                -Condition (@($installMarker.ManagedFiles) -notcontains '.capsulenv-runtime.json') `
                -Message 'Install marker must own only destination runtime files.'
            foreach ($bundleOnlyFile in @('install.cmd', 'README.md', 'scripts/Install-Capsulenv.ps1')) {
                Assert-CapsulenvBuildInstallTest `
                    -Condition (-not (Test-Path -LiteralPath (Join-Path $installRoot $bundleOnlyFile))) `
                    -Message "Deployment copied bundle-only file into capsule: $bundleOnlyFile"
            }
            Assert-CapsulenvBuildInstallTest `
                -Condition ([int]$installMarker.SchemaVersion -eq 3) `
                -Message 'Installer did not write the deployment-only marker schema.'
            Assert-CapsulenvBuildInstallTest `
                -Condition ($null -eq $installMarker.PSObject.Properties['InstallMode']) `
                -Message 'Deployment metadata must not own host/user integration mode.'
            Assert-CapsulenvBuildInstallTest `
                -Condition (-not (Test-Path -LiteralPath (Join-Path $installRoot 'scoop'))) `
                -Message 'Deployment unexpectedly bootstrapped mutable Scoop state.'
            Assert-CapsulenvBuildInstallTest `
                -Condition (-not (Test-Path -LiteralPath (Join-Path $installRoot '.capsulenv'))) `
                -Message 'Deployment unexpectedly created host-scoped Capsulenv state.'

            [void](New-Item -ItemType Directory -Path $relocatedInstallRoot -Force)
            Get-ChildItem -LiteralPath $installRoot -Force | Copy-Item -Destination $relocatedInstallRoot -Recurse -Force
            $relocationRootOriginal = $env:CAPSULENV_ROOT
            try {
                $env:CAPSULENV_ROOT = $installRoot
                & (Join-Path $relocatedInstallRoot 'modules/Capsulenv/runtime/Invoke-Capsulenv.ps1') help
                Assert-CapsulenvBuildInstallTest `
                    -Condition ([System.IO.Path]::GetFullPath($env:CAPSULENV_ROOT) -eq [System.IO.Path]::GetFullPath($relocatedInstallRoot)) `
                    -Message 'Relocated installed runtime trusted inherited CAPSULENV_ROOT instead of its new module location.'
            } finally {
                $env:CAPSULENV_ROOT = $relocationRootOriginal
            }

            $unmanagedPath = Join-Path $installRoot 'unmanaged.txt'
            $localConfigPath = Join-Path (Join-Path $installRoot 'config') 'capsulenv.local.psd1'
            $cacheStatePath = Join-Path (Join-Path $installRoot 'cache') 'preserved.txt'
            $privateModuleStatePath = Join-Path (Join-Path (Join-Path (Join-Path $installRoot 'PowerShell') 'Modules') 'PrivateTest') 'preserved.txt'
            'keep-me' | Set-Content -LiteralPath $unmanagedPath -Encoding UTF8
'@{ ToolStorage = @{ Enabled = $false } }' | Set-Content -LiteralPath $localConfigPath -Encoding UTF8
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $cacheStatePath) -Force)
            'cache-state' | Set-Content -LiteralPath $cacheStatePath -Encoding UTF8
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $privateModuleStatePath) -Force)
            'module-state' | Set-Content -LiteralPath $privateModuleStatePath -Encoding UTF8

            $legacyManagedPath = Join-Path $installRoot 'scripts/legacy-runtime.ps1'
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $legacyManagedPath) -Force)
            '# legacy managed runtime' | Set-Content -LiteralPath $legacyManagedPath -Encoding UTF8
            $installMarkerForMigration = Get-Content -LiteralPath $installMarkerPath -Raw | ConvertFrom-Json
            $installMarkerForMigration.ManagedFiles = @($installMarkerForMigration.ManagedFiles) + 'scripts/legacy-runtime.ps1'
            $installMarkerForMigration | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $installMarkerPath -Encoding UTF8

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
            Assert-CapsulenvBuildInstallTest `
                -Condition (-not (Test-Path -LiteralPath $legacyManagedPath)) `
                -Message 'Installer update did not remove a legacy managed root script.'

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

            & (Join-Path $installRoot 'modules/Capsulenv/runtime/Invoke-Capsulenv.ps1') help
            Write-Host 'capsulenv build/install Pester checks passed.' -ForegroundColor Green
        } finally {
            Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }
}
