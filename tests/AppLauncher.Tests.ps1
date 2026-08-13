Describe 'Capsulenv installed Scoop shortcut launcher' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force
        $script:Module = @(Get-Module Capsulenv)[-1]
    }

    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }

    It 'uses installed architecture shortcuts and expands portable Scoop variables' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-app-' + [Guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $temporaryRoot 'config/capsulenv.psd1')
            $current = Join-Path $temporaryRoot 'scoop/apps/demo/current'
            [void](New-Item -ItemType Directory -Path $current -Force)
            '' | Set-Content -LiteralPath (Join-Path $current 'demo.exe') -Encoding UTF8
            @{
                version = '1.0.0'
                shortcuts = @(@('demo.exe', 'Generic Demo', '--generic'))
                architecture = @{
                    '64bit' = @{
                        shortcuts = @(
                            @('demo.exe', 'Demo', '--data "$persist_dir\data" --root "$dir" --original "$original_dir"'),
                            @('demo.exe', 'Demo Tools')
                        )
                    }
                }
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $current 'manifest.json') -Encoding UTF8
            @{ architecture = '64bit'; bucket = 'main' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $current 'install.json') -Encoding UTF8

            & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                [void](Get-CapsulenvConfiguration -Refresh)
            } $temporaryRoot

            $shortcuts = @(Get-CapsulenvScoopAppShortcuts -App demo)
            $shortcuts.Count | Should -Be 2
            @($shortcuts.Name) | Should -Contain 'Demo'
            @($shortcuts.Name) | Should -Not -Contain 'Generic Demo'
            $demo = $shortcuts | Where-Object Name -eq 'Demo'
            $demo.Scope | Should -Be 'User'
            $demo.Selector | Should -Be 'user/demo'
            $demo.Architecture | Should -Be '64bit'
            $demo.Target | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $current 'demo.exe')))
            $demo.WorkingDirectory | Should -Be ([System.IO.Path]::GetFullPath($current))
            $demo.Arguments | Should -Match ([regex]::Escape((Join-Path $temporaryRoot 'scoop/persist/demo')))
            $demo.Arguments | Should -Match ([regex]::Escape($current))
            $demo.Arguments | Should -Not -Match '\$persist_dir|\$original_dir|\$dir'
        } finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

    It 'falls back to generic shortcuts when the installed architecture shortcut list is empty' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-app-fallback-' + [Guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $temporaryRoot 'config/capsulenv.psd1')
            $current = Join-Path $temporaryRoot 'scoop/apps/demo/current'
            [void](New-Item -ItemType Directory -Path $current -Force)
            '' | Set-Content -LiteralPath (Join-Path $current 'demo.exe') -Encoding UTF8
            '{"shortcuts":[["demo.exe","Generic Demo"]],"architecture":{"64bit":{"shortcuts":[]}}}' |
                Set-Content -LiteralPath (Join-Path $current 'manifest.json') -Encoding UTF8
            @{ architecture = '64bit' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $current 'install.json') -Encoding UTF8

            & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                [void](Get-CapsulenvConfiguration -Refresh)
            } $temporaryRoot

            $shortcuts = @(Get-CapsulenvScoopAppShortcuts -App demo)
            $shortcuts.Count | Should -Be 1
            $shortcuts[0].Name | Should -Be 'Generic Demo'
        } finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

    It 'requires an explicit scope when the same app exists in user and global roots' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-app-scope-' + [Guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $temporaryRoot 'config/capsulenv.psd1')
            foreach ($scopeRoot in @('scoop', 'scoop-global')) {
                $current = Join-Path $temporaryRoot ($scopeRoot + '/apps/demo/current')
                [void](New-Item -ItemType Directory -Path $current -Force)
                '' | Set-Content -LiteralPath (Join-Path $current 'demo.exe') -Encoding UTF8
                '{"shortcuts":[["demo.exe","Demo"]]}' | Set-Content -LiteralPath (Join-Path $current 'manifest.json') -Encoding UTF8
                @{ architecture = '64bit' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $current 'install.json') -Encoding UTF8
            }

            & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                [void](Get-CapsulenvConfiguration -Refresh)
            } $temporaryRoot

            { Get-CapsulenvScoopAppShortcuts -App demo } | Should -Throw '*both user and global roots*'
            @(Get-CapsulenvScoopAppShortcuts -App user/demo).Count | Should -Be 1
            @(Get-CapsulenvScoopAppShortcuts -App global/demo).Count | Should -Be 1
        } finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

    It 'requires a shortcut name when an installed app exposes more than one shortcut' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-app-choice-' + [Guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $temporaryRoot 'config/capsulenv.psd1')
            $current = Join-Path $temporaryRoot 'scoop/apps/demo/current'
            [void](New-Item -ItemType Directory -Path $current -Force)
            '' | Set-Content -LiteralPath (Join-Path $current 'demo.exe') -Encoding UTF8
            '{"shortcuts":[["demo.exe","Demo"],["demo.exe","Demo Tools"]]}' | Set-Content -LiteralPath (Join-Path $current 'manifest.json') -Encoding UTF8
            '{"architecture":"64bit"}' | Set-Content -LiteralPath (Join-Path $current 'install.json') -Encoding UTF8

            & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                [void](Get-CapsulenvConfiguration -Refresh)
            } $temporaryRoot

            { Start-CapsulenvScoopShortcut -App demo } | Should -Throw '*multiple shortcuts*'
            { Start-CapsulenvScoopShortcut -App demo -ShortcutName Missing } | Should -Throw '*Available shortcuts*'
        } finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

    It 'parses app run shortcut selection and runtime arguments after the separator' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-app-dispatch-' + [Guid]::NewGuid().ToString('N'))
        $previousRoot = $env:CAPSULENV_ROOT
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $temporaryRoot 'config/capsulenv.psd1')
            $env:CAPSULENV_ROOT = $temporaryRoot

            Mock -CommandName Start-CapsulenvScoopShortcut -ModuleName Capsulenv -MockWith { }
            Invoke-Capsulenv -Arguments @('app', 'run', 'user/demo', 'Demo Tools', '--', '--flag', 'value with spaces')

            Should -Invoke -CommandName Start-CapsulenvScoopShortcut -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
                $App -eq 'user/demo' -and
                $ShortcutName -eq 'Demo Tools' -and
                $Arguments.Count -eq 2 -and
                $Arguments[0] -eq '--flag' -and
                $Arguments[1] -eq 'value with spaces'
            }
        } finally {
            $env:CAPSULENV_ROOT = $previousRoot
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

    It 'keeps the launcher free of Start Menu and shortcut file integration' {
        $source = Get-Content -LiteralPath (Join-Path $script:Root 'src/42-AppLauncher.ps1') -Raw
        $source | Should -Not -Match 'WScript\.Shell|CreateShortcut|\.lnk|Start Menu|StartMenu'
        $source | Should -Match 'current.*manifest\.json|ManifestPath'
        $source | Should -Match 'install\.json|InstallPath'
    }
}
