Describe 'Capsulenv portable workflow contracts' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force
        $script:Module = @(Get-Module Capsulenv)[-1]
    }

    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }

    It 'keeps identity, managed path state, Git config, and scratch independent of drive letter' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-workflow-' + [Guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $temporaryRoot 'config/capsulenv.psd1')

            & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                [void](Get-CapsulenvConfiguration -Refresh)
                $identity1 = Get-CapsulenvIdentity
                $identity2 = Get-CapsulenvIdentity
                $identity1 | Should -Be $identity2

                $plan = Get-CapsulenvEnvironmentPlan
                $plan.Variables.SCOOP_CACHE | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $CapsuleRoot 'cache/scoop')))
                $plan.Variables.GIT_CONFIG_GLOBAL | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $CapsuleRoot 'tool-data/git/config')))
                $plan.Variables.UV_CONFIG_FILE | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $CapsuleRoot 'tool-data/uv/uv.toml')))
                $plan.Variables.NPM_CONFIG_USERCONFIG | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $CapsuleRoot 'tool-data/npm/npmrc')))
                $plan.Variables.CAPSULENV_SCRATCH.StartsWith($CapsuleRoot, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeFalse

                Set-CapsulenvInstallMode -Mode User -ManagedPathEntries $plan.PathEntries
                $modePath = Get-CapsulenvInstallModeStatePath
                $modeText = Get-Content -LiteralPath $modePath -Raw
                $mode = $modeText | ConvertFrom-Json
                [int]$mode.SchemaVersion | Should -Be 3
                [string]$mode.CapsuleId | Should -Be $identity1
                [string]$mode.HostIntegrationKey | Should -Not -BeNullOrEmpty
                $modePath.Replace('\', '/') | Should -Match '/\.capsulenv/user-integrations/[^/]+/install-mode\.json$'
                @($mode.ManagedPathEntries | Where-Object { $_ -notlike 'capsule://*' }).Count | Should -Be 0
                $modeText.Contains($CapsuleRoot) | Should -BeFalse
                Resolve-CapsulenvStatePathReference -Reference 'capsule://bin' -CapsuleRoot $CapsuleRoot | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $CapsuleRoot 'bin')))
            } $temporaryRoot
        } finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

    It 'detects local Scoop version drift and reports offline run readiness without network access' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-offline-' + [Guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $temporaryRoot 'config/capsulenv.psd1')
            foreach ($path in @(
                'scoop/apps/scoop/current/bin',
                'scoop/apps/git/current',
                'scoop/buckets/main/bucket',
                'cache/scoop'
            )) {
                [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot $path) -Force)
            }
            'param()' | Set-Content -LiteralPath (Join-Path $temporaryRoot 'scoop/apps/scoop/current/bin/scoop.ps1') -Encoding UTF8
            '{"version":"1.0.0"}' | Set-Content -LiteralPath (Join-Path $temporaryRoot 'scoop/apps/git/current/manifest.json') -Encoding UTF8
            '{"bucket":"main"}' | Set-Content -LiteralPath (Join-Path $temporaryRoot 'scoop/apps/git/current/install.json') -Encoding UTF8
            '{"version":"2.0.0"}' | Set-Content -LiteralPath (Join-Path $temporaryRoot 'scoop/buckets/main/bucket/git.json') -Encoding UTF8
            'cache' | Set-Content -LiteralPath (Join-Path $temporaryRoot 'cache/scoop/test.cache') -Encoding UTF8

            & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                [void](Get-CapsulenvConfiguration -Refresh)
                $drift = @(Get-CapsulenvVersionDrift)
                $drift.Count | Should -Be 1
                $drift[0].Name | Should -Be 'git'
                $drift[0].Installed | Should -Be '1.0.0'
                $drift[0].Available | Should -Be '2.0.0'
                $drift[0].Status | Should -Be 'Drift'

                $offline = Get-CapsulenvOfflineReadiness
                $offline.RunReady | Should -BeTrue
                $offline.InstalledApps | Should -Be 1
                $offline.MissingInstalledManifests | Should -Be 0
                $offline.CacheFiles | Should -Be 1

                '{"Version":"0.13.0-test"}' | Set-Content -LiteralPath (Join-Path $CapsuleRoot '.capsulenv-runtime.json') -Encoding UTF8
                $status = Get-CapsulenvStatus
                $status.Version | Should -Be '0.13.0-test'
                $status.Root | Should -Be ([System.IO.Path]::GetFullPath($CapsuleRoot))
                $status.ScoopApps | Should -Be 1
                $status.Relocation | Should -Be 'Pending'
                $status.ProjectLinks | Should -Be 0
                $status.ToolWorkspaces | Should -Be 0
                $status.OfflineRunReady | Should -BeTrue
            } $temporaryRoot
        } finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

    It 'makes user-shell idempotent and keeps eject separate from restore-user' {
        $environmentSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/30-Environment.ps1') -Raw
        $commandsSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/90-Commands.ps1') -Raw
        $lifecycleSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/72-Lifecycle.ps1') -Raw

        $environmentSource | Should -Match '\$ledgerWasUser = \(\$backupExists -and \$null -ne \$ledgerState -and \[string\]\$ledgerState\.Mode -eq ''User''\)'
        $environmentSource | Should -Match '\$alreadyUser = \(\$backupExists -and \$currentMode -eq ''User''\)'
        $environmentSource | Should -Match '\$RefreshBackup = \$true'
        $commandsSource | Should -Match "'user-shell'"
        $commandsSource | Should -Match 'Enter-CapsulenvUserShell -Force:'
        $environmentSource | Should -Match 'Install-CapsulenvUserEnvironment -Force:\$Force -RefreshBackup:\$refreshBackup'
        $environmentSource | Should -Match 'Invoke-CapsulenvChildShell'
        $commandsSource | Should -Match "'eject'"
        $commandsSource | Should -Match "'status'"
        $commandsSource | Should -Match 'help <topic>'
        $commandsSource | Should -Match 'No separate init step is required'
        $lifecycleSource | Should -Match 'Get-CapsulenvDirtyRepositories'
        $lifecycleSource | Should -Match 'Stop-CapsulenvOwnedProcesses'
        $lifecycleSource | Should -Match 'CAPSULENV_SCRATCH|Get-CapsulenvScratchPath'
        $lifecycleSource | Should -Match "'download', '--no-update-scoop'"
        $lifecycleSource | Should -Not -Match "arguments \+= '-g'"
        $lifecycleSource | Should -Not -Match 'Restore-CapsulenvUserEnvironment\s*(-|\()'
    }
}
