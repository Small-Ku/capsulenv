Describe 'Capsulenv PowerShell and seed ownership' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force
        $script:Module = @(Get-Module Capsulenv)[-1]
    }

    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }

    It 'keeps PSReadLine history portable and loads only capsule pwsh profiles in ShellOnly' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-pwsh-' + [Guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $temporaryRoot 'config/capsulenv.psd1')
            $pwshHome = Join-Path $temporaryRoot 'scoop/apps/pwsh/7.6.4'
            [void](New-Item -ItemType Directory -Path $pwshHome -Force)
            $pwsh = Join-Path $pwshHome 'pwsh.exe'
            '' | Set-Content -LiteralPath $pwsh -Encoding UTF8
            'all-hosts' | Set-Content -LiteralPath (Join-Path $pwshHome 'profile.ps1') -Encoding UTF8
            'console' | Set-Content -LiteralPath (Join-Path $pwshHome 'Microsoft.PowerShell_profile.ps1') -Encoding UTF8

            & $script:Module {
                param($CapsuleRoot, $Pwsh)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                [void](Get-CapsulenvConfiguration -Refresh)
                $environment = Get-CapsulenvEnvironmentPlan
                $environment.Variables.CAPSULENV_PSREADLINE_HISTORY | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $CapsuleRoot 'tool-data/powershell/PSReadLine/ConsoleHost_history.txt')))

                $shellOnly = Get-CapsulenvPowerShellChildLaunchPlan -ShellPath $Pwsh -IntegrationMode ShellOnly
                @($shellOnly.Arguments) | Should -Contain '-NoProfile'
                $shellCommand = [string]$shellOnly.Arguments[-1]
                $shellCommand | Should -Match ([regex]::Escape((Join-Path (Split-Path -Parent $Pwsh) 'profile.ps1')))
                $shellCommand | Should -Match ([regex]::Escape((Join-Path (Split-Path -Parent $Pwsh) 'Microsoft.PowerShell_profile.ps1')))
                $shellCommand | Should -Match 'CAPSULENV_PSREADLINE_HISTORY'

                $user = Get-CapsulenvPowerShellChildLaunchPlan -ShellPath $Pwsh -IntegrationMode User
                @($user.Arguments) | Should -Not -Contain '-NoProfile'
                [string]$user.Arguments[-1] | Should -Match 'CAPSULENV_PSREADLINE_HISTORY'
                [string]$user.Arguments[-1] | Should -Not -Match ([regex]::Escape((Join-Path (Split-Path -Parent $Pwsh) 'profile.ps1')))

                $foreign = Join-Path (Split-Path -Parent $CapsuleRoot) 'foreign/pwsh.exe'
                @(Get-CapsulenvPortablePowerShellProfilePaths -ShellPath $foreign).Count | Should -Be 0
            } $temporaryRoot $pwsh
        } finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

    It 'seeds CurrentUser PowerShell profiles into the Scoop pwsh persist contract' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-pwsh-seed-' + [Guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $temporaryRoot 'config/capsulenv.psd1')
            [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'scoop/apps/pwsh/current') -Force)
            [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'scoop/persist/pwsh') -Force)
            $sourceAll = Join-Path $temporaryRoot 'host-profile.ps1'
            $sourceHost = Join-Path $temporaryRoot 'host-pwsh-profile.ps1'
            'Set-Alias ll Get-ChildItem' | Set-Content -LiteralPath $sourceAll -Encoding UTF8
            'Import-Module NyaModule' | Set-Content -LiteralPath $sourceHost -Encoding UTF8
            '' | Set-Content -LiteralPath (Join-Path $temporaryRoot 'scoop/persist/pwsh/profile.ps1') -Encoding UTF8 -NoNewline
            '' | Set-Content -LiteralPath (Join-Path $temporaryRoot 'scoop/persist/pwsh/Microsoft.PowerShell_profile.ps1') -Encoding UTF8 -NoNewline

            & $script:Module {
                param($CapsuleRoot, $AllHosts, $CurrentHost)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                [void](Get-CapsulenvConfiguration -Refresh)
                $result = @(Seed-CapsulenvPowerShellProfiles -CurrentUserAllHosts $AllHosts -CurrentUserCurrentHost $CurrentHost)
                $result.Count | Should -Be 2
                ($result | Where-Object Status -eq 'Seeded').Count | Should -Be 2
                (Get-Content -LiteralPath (Join-Path $CapsuleRoot 'scoop/persist/pwsh/profile.ps1') -Raw) | Should -Match 'Set-Alias ll'
                (Get-Content -LiteralPath (Join-Path $CapsuleRoot 'scoop/persist/pwsh/Microsoft.PowerShell_profile.ps1') -Raw) | Should -Match 'Import-Module NyaModule'

                { Seed-CapsulenvPowerShellProfiles -CurrentUserAllHosts $AllHosts -CurrentUserCurrentHost $CurrentHost } | Should -Throw '*--force*'
                { Seed-CapsulenvPowerShellProfiles -Force -CurrentUserAllHosts $AllHosts -CurrentUserCurrentHost $CurrentHost } | Should -Not -Throw
            } $temporaryRoot $sourceAll $sourceHost
        } finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

    It 'reads host Git global config without Capsulenv overrides and identifies filtered keys' {
        $git = @(Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($git.Count -eq 0) {
            Set-ItResult -Skipped -Because 'git is not available on this test host'
            return
        }
        $temporaryHome = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-git-seed-' + [Guid]::NewGuid().ToString('N'))
        $previousHome = $env:HOME
        $previousGlobal = $env:GIT_CONFIG_GLOBAL
        $previousCount = $env:GIT_CONFIG_COUNT
        $previousKey = $env:GIT_CONFIG_KEY_0
        $previousValue = $env:GIT_CONFIG_VALUE_0
        try {
            [void](New-Item -ItemType Directory -Path $temporaryHome -Force)
            $env:HOME = $temporaryHome
            # Earlier suites intentionally leave a capsule environment active in
            # the shared Pester process. Build the synthetic host config without
            # inheriting that capsule's Git-global/process overlay.
            $env:GIT_CONFIG_GLOBAL = $null
            $env:GIT_CONFIG_COUNT = $null
            $env:GIT_CONFIG_KEY_0 = $null
            $env:GIT_CONFIG_VALUE_0 = $null
            & $git[0].Source config --global user.name 'Daily Host'
            & $git[0].Source config --global credential.helper manager
            & $git[0].Source config --global core.sshCommand 'C:/host/ssh.exe'
            $fakeGlobal = Join-Path $temporaryHome 'capsule-config'
            "[user]`nname = Wrong Override" | Set-Content -LiteralPath $fakeGlobal -Encoding UTF8
            $env:GIT_CONFIG_GLOBAL = $fakeGlobal
            $env:GIT_CONFIG_COUNT = '1'
            $env:GIT_CONFIG_KEY_0 = 'user.email'
            $env:GIT_CONFIG_VALUE_0 = 'overlay@example.invalid'

            & $script:Module {
                param($Git)
                $entries = @(Invoke-CapsulenvGitGlobalConfigCapture -Git $Git)
                ($entries | Where-Object { $_.Key -eq 'user.name' }).Value | Should -Be 'Daily Host'
                @($entries | Where-Object { $_.Key -eq 'user.email' }).Count | Should -Be 0
                Get-CapsulenvSeedGitFilteredReason -Key 'credential.helper' | Should -Be 'credential setting'
                Get-CapsulenvSeedGitFilteredReason -Key 'core.sshCommand' | Should -Be 'Capsulenv-owned SSH integration'
                Get-CapsulenvSeedGitFilteredReason -Key 'credential.helper' -IncludeSensitive | Should -BeNullOrEmpty
            } $git[0].Source
        } finally {
            $env:HOME = $previousHome
            $env:GIT_CONFIG_GLOBAL = $previousGlobal
            $env:GIT_CONFIG_COUNT = $previousCount
            $env:GIT_CONFIG_KEY_0 = $previousKey
            $env:GIT_CONFIG_VALUE_0 = $previousValue
            if (Test-Path -LiteralPath $temporaryHome) {
                Remove-Item -LiteralPath $temporaryHome -Recurse -Force
            }
        }
    }

    It 'stores only apps and buckets in a Scoop seed inventory' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-scoop-seed-' + [Guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Path $temporaryRoot -Force)
            [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $temporaryRoot 'config/capsulenv.psd1')
            $destination = Join-Path $temporaryRoot 'Scoopfile.json'
            $export = [pscustomobject]@{
                config = [pscustomobject]@{ proxy = 'host-only' }
                apps = @([pscustomobject]@{ Name = 'git'; Version = '1.0'; Source = 'main' })
                buckets = @([pscustomobject]@{ Name = 'main'; Source = 'https://github.com/ScoopInstaller/Main' })
            }
            & $script:Module {
                param($CapsuleRoot, $Export, $Destination)
                [void](Save-CapsulenvScoopSeedInventory -Export $Export -Destination $Destination)
                $saved = Get-Content -LiteralPath $Destination -Raw | ConvertFrom-Json
                $null -ne $saved.PSObject.Properties['apps'] | Should -BeTrue
                $null -ne $saved.PSObject.Properties['buckets'] | Should -BeTrue
                $null -eq $saved.PSObject.Properties['config'] | Should -BeTrue

                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                [void](Get-CapsulenvConfiguration -Refresh)
            } $temporaryRoot $export $destination

            $hostRoot = Join-Path $temporaryRoot 'host-scoop'
            $hostGlobalRoot = Join-Path $temporaryRoot 'host-global-scoop'
            foreach ($path in @(
                'apps/git/1.0',
                'persist/git',
                'buckets/main/bucket'
            )) {
                [void](New-Item -ItemType Directory -Path (Join-Path $hostRoot $path) -Force)
            }
            '{"version":"1.0","persist":"settings.json"}' | Set-Content -LiteralPath (Join-Path $hostRoot 'apps/git/1.0/manifest.json') -Encoding UTF8
            '{"bucket":"main","architecture":"64bit"}' | Set-Content -LiteralPath (Join-Path $hostRoot 'apps/git/1.0/install.json') -Encoding UTF8
            'git.exe snapshot' | Set-Content -LiteralPath (Join-Path $hostRoot 'apps/git/1.0/git.exe') -Encoding UTF8
            'portable-state' | Set-Content -LiteralPath (Join-Path $hostRoot 'persist/git/settings.json') -Encoding UTF8
            '{"version":"1.0"}' | Set-Content -LiteralPath (Join-Path $hostRoot 'buckets/main/bucket/git.json') -Encoding UTF8

            $hostScoop = [pscustomobject]@{ Root = $hostRoot; GlobalRoot = $hostGlobalRoot; Command = 'unused' }
            Mock Initialize-CapsulenvScoopBootstrap { [pscustomobject]@{ Status = 'Mocked' } } -ModuleName Capsulenv
            Mock Reset-CapsulenvScoop { $true } -ModuleName Capsulenv
            Mock Invoke-CapsulenvScoopCommand { throw 'Native Scoop import/install must not run during ShellOnly snapshot apply.' } -ModuleName Capsulenv

            $snapshot = & $script:Module {
                param($Export, $HostScoop)
                Copy-CapsulenvShellOnlyScoopSeedSnapshot -Inventory $Export -HostScoop $HostScoop
            } $export $hostScoop
            $snapshot.Strategy | Should -Be 'ShellOnlySnapshot'
            $snapshot.CopiedApps | Should -Be 1
            $snapshot.CopiedBuckets | Should -Be 1
            (Get-Content -LiteralPath (Join-Path $temporaryRoot 'scoop/apps/git/1.0/git.exe') -Raw) | Should -Match 'snapshot'
            (Get-Content -LiteralPath (Join-Path $temporaryRoot 'scoop/persist/git/settings.json') -Raw) | Should -Match 'portable-state'
            Test-Path -LiteralPath (Join-Path $temporaryRoot 'scoop/buckets/main/bucket/git.json') | Should -BeTrue
            Should -Invoke Reset-CapsulenvScoop -ModuleName Capsulenv -Times 1 -Exactly
            Should -Invoke Invoke-CapsulenvScoopCommand -ModuleName Capsulenv -Times 0 -Exactly
        } finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

    It 'fails ShellOnly Scoop snapshot before mutation when a planned global app needs elevation' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-scoop-global-seed-' + [Guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $temporaryRoot 'config/capsulenv.psd1')
            $hostRoot = Join-Path $temporaryRoot 'host-scoop'
            $hostGlobalRoot = Join-Path $temporaryRoot 'host-global-scoop'
            [void](New-Item -ItemType Directory -Path (Join-Path $hostGlobalRoot 'apps/ripgrep/14.1.0') -Force)
            '{"version":"14.1.0"}' | Set-Content -LiteralPath (Join-Path $hostGlobalRoot 'apps/ripgrep/14.1.0/manifest.json') -Encoding UTF8
            'rg.exe snapshot' | Set-Content -LiteralPath (Join-Path $hostGlobalRoot 'apps/ripgrep/14.1.0/rg.exe') -Encoding UTF8

            $inventory = [pscustomobject]@{
                apps = @([pscustomobject]@{ Name = 'ripgrep'; Version = '14.1.0'; Global = $true })
                buckets = @()
            }
            $hostScoop = [pscustomobject]@{ Root = $hostRoot; GlobalRoot = $hostGlobalRoot; Command = 'unused' }

            Mock Assert-CapsulenvGlobalScoopResetAccess {} -ModuleName Capsulenv
            Mock Test-CapsulenvAdministrator { $false } -ModuleName Capsulenv
            Mock Initialize-CapsulenvScoopBootstrap { throw 'Mutation must not start before elevation preflight.' } -ModuleName Capsulenv

            & $script:Module {
                param($CapsuleRoot, $Inventory, $HostScoop)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                [void](Get-CapsulenvConfiguration -Refresh)
                { Copy-CapsulenvShellOnlyScoopSeedSnapshot -Inventory $Inventory -HostScoop $HostScoop } |
                    Should -Throw '*global apps*elevated terminal*'
            } $temporaryRoot $inventory $hostScoop

            Test-Path -LiteralPath (Join-Path $temporaryRoot 'scoop-global/apps/ripgrep/14.1.0') | Should -BeFalse
            Should -Invoke Initialize-CapsulenvScoopBootstrap -ModuleName Capsulenv -Times 0 -Exactly
        } finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

}
