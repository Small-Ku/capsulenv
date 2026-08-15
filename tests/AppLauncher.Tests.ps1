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

    It 'restores the outer shortcut list when a single tuple arrives flattened' {
        $result = & $script:Module {
            $app = [pscustomobject]@{
                Scope = 'User'
                Name = 'vscode'
                Selector = 'user/vscode'
                Current = 'C:\capsulenv\scoop\apps\vscode\current'
                Persist = 'C:\capsulenv\scoop\persist\vscode'
                ManifestPath = 'C:\capsulenv\scoop\apps\vscode\current\manifest.json'
                InstallPath = 'C:\capsulenv\scoop\apps\vscode\current\install.json'
                Manifest = [pscustomobject]@{
                    shortcuts = @('code.exe', 'Visual Studio Code')
                }
                Install = [pscustomobject]@{
                    architecture = '64bit'
                }
            }

            $entrySet = Get-CapsulenvInstalledShortcutEntries -App $app
            $entries = @($entrySet.Entries)
            $parts = @($entries[0])
            [pscustomobject]@{
                EntryCount = $entries.Count
                PartCount = $parts.Count
                Target = [string]$parts[0]
                Name = [string]$parts[1]
            }
        }

        $result.EntryCount | Should -Be 1
        $result.PartCount | Should -Be 2
        $result.Target | Should -Be 'code.exe'
        $result.Name | Should -Be 'Visual Studio Code'
    }

    It 'launches the single shortcut shape used by the Scoop Extras vscode manifest' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-vscode-' + [Guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $temporaryRoot 'config/capsulenv.psd1')
            $current = Join-Path $temporaryRoot 'scoop/apps/vscode/current'
            [void](New-Item -ItemType Directory -Path $current -Force)
            '' | Set-Content -LiteralPath (Join-Path $current 'code.exe') -Encoding UTF8
            '{"version":"1.133.0","shortcuts":[["code.exe","Visual Studio Code"]]}' |
                Set-Content -LiteralPath (Join-Path $current 'manifest.json') -Encoding UTF8
            '{"architecture":"64bit","bucket":"extras"}' |
                Set-Content -LiteralPath (Join-Path $current 'install.json') -Encoding UTF8

            & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                [void](Get-CapsulenvConfiguration -Refresh)
            } $temporaryRoot

            Mock -CommandName Start-Process -ModuleName Capsulenv -MockWith { }
            { Start-CapsulenvScoopShortcut -App vscode } | Should -Not -Throw
            Should -Invoke -CommandName Start-Process -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq ([System.IO.Path]::GetFullPath((Join-Path $current 'code.exe'))) -and
                $WorkingDirectory -eq ([System.IO.Path]::GetFullPath($current))
            }
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
            '' | Set-Content -LiteralPath (Join-Path $current 'generic.exe') -Encoding UTF8
            '{"shortcuts":[["demo.exe","Generic Demo"]],"bin":"generic.exe","architecture":{"64bit":{"shortcuts":[],"bin":[]}}}' |
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
            $bins = @(Get-CapsulenvScoopAppBins -App demo)
            $bins.Count | Should -Be 1
            $bins[0].Name | Should -Be 'generic'
        } finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

    It 'preserves a one-entry nested bin alias tuple from the installed manifest' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-bin-single-' + [Guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $temporaryRoot 'config/capsulenv.psd1')
            $current = Join-Path $temporaryRoot 'scoop/apps/demo/current'
            [void](New-Item -ItemType Directory -Path (Join-Path $current 'bin') -Force)
            '' | Set-Content -LiteralPath (Join-Path $current 'bin/demo.cmd') -Encoding UTF8
            '{"bin":[["bin/demo.cmd","demo"]]}' |
                Set-Content -LiteralPath (Join-Path $current 'manifest.json') -Encoding UTF8
            '{"architecture":"64bit"}' |
                Set-Content -LiteralPath (Join-Path $current 'install.json') -Encoding UTF8

            & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                [void](Get-CapsulenvConfiguration -Refresh)
            } $temporaryRoot

            $bins = @(Get-CapsulenvScoopAppBins -App demo)
            $bins.Count | Should -Be 1
            $bins[0].Name | Should -Be 'demo'
            $bins[0].Target | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $current 'bin/demo.cmd')))
        } finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

    It 'resolves architecture-specific bin entries and persist paths from the installed manifest' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-app-bin-' + [Guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $temporaryRoot 'config/capsulenv.psd1')
            $current = Join-Path $temporaryRoot 'scoop/apps/custom-gecko/current'
            $persist = Join-Path $temporaryRoot 'scoop/persist/custom-gecko'
            [void](New-Item -ItemType Directory -Path $current -Force)
            [void](New-Item -ItemType Directory -Path (Join-Path $persist 'profile') -Force)
            '' | Set-Content -LiteralPath (Join-Path $current 'browser.exe') -Encoding UTF8
            '' | Set-Content -LiteralPath (Join-Path $current 'helper.exe') -Encoding UTF8
            @{
                bin = @('generic.exe')
                architecture = @{
                    '64bit' = @{
                        bin = @(
                            @('browser.exe', 'gecko'),
                            @('helper.exe', 'helper')
                        )
                    }
                }
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $current 'manifest.json') -Encoding UTF8
            @{ architecture = '64bit' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $current 'install.json') -Encoding UTF8

            & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                [void](Get-CapsulenvConfiguration -Refresh)
            } $temporaryRoot

            $bins = @(Get-CapsulenvScoopAppBins -App custom-gecko)
            $bins.Count | Should -Be 2
            @($bins.Name) | Should -Contain 'gecko'
            @($bins.Name) | Should -Not -Contain 'generic'
            Resolve-CapsulenvScoopAppExecutable -App custom-gecko -BinName gecko |
                Should -Be ([System.IO.Path]::GetFullPath((Join-Path $current 'browser.exe')))
            Resolve-CapsulenvScoopAppPersistPath -App custom-gecko -RelativePath profile |
                Should -Be ([System.IO.Path]::GetFullPath((Join-Path $persist 'profile')))
            { Resolve-CapsulenvScoopAppExecutable -App custom-gecko } | Should -Throw '*multiple executable targets*'
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

    It 'keeps persist relocation scope bound to the selected Scoop root' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-persist-scope-' + [Guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $temporaryRoot 'config/capsulenv.psd1')
            $userPersist = Join-Path $temporaryRoot 'scoop/persist/demo'
            $globalPersist = Join-Path $temporaryRoot 'scoop-global/persist/demo'
            [void](New-Item -ItemType Directory -Path $userPersist, $globalPersist -Force)

            & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                [void](Get-CapsulenvConfiguration -Refresh)
            } $temporaryRoot

            $allRoots = @(& $script:Module { Get-CapsulenvPersistRootsForApp -App demo })
            $userRoots = @(& $script:Module { Get-CapsulenvPersistRootsForApp -App user/demo })
            $globalRoots = @(& $script:Module { Get-CapsulenvPersistRootsForApp -App global/demo })

            $allRoots.Count | Should -Be 2
            $userRoots.Count | Should -Be 1
            $globalRoots.Count | Should -Be 1
            $userRoots[0] | Should -Be ([System.IO.Path]::GetFullPath($userPersist))
            $globalRoots[0] | Should -Be ([System.IO.Path]::GetFullPath($globalPersist))
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
