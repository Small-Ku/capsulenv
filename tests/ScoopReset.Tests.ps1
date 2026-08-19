Describe 'Capsulenv package projection repair boundary' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force
        $script:Module = Get-Module Capsulenv
    }

    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }

    It 'delegates the compatibility reset command to bounded projection repair only' {
        Mock Repair-CapsulenvInstalledAppProjections { $true } -ModuleName Capsulenv
        Mock Invoke-CapsulenvScoopCommand { throw 'upstream Scoop must not be invoked by Capsulenv projection repair' } -ModuleName Capsulenv

        Reset-CapsulenvScoop -Apps @('user/git') -IntegrationMode ShellOnly -Quiet | Should -BeTrue

        Should -Invoke Repair-CapsulenvInstalledAppProjections -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            $Apps.Count -eq 1 -and $Apps[0] -eq 'user/git' -and $IntegrationMode -eq 'ShellOnly'
        }
        Should -Invoke Invoke-CapsulenvScoopCommand -ModuleName Capsulenv -Times 0 -Exactly
    }

    It 'keeps Scoop command output out of the returned exit-code value' {
        $fakeScoop = Join-Path $TestDrive 'fake-scoop.ps1'
        @'
Write-Output 'upstream output'
$global:LASTEXITCODE = 0
'@ | Set-Content -LiteralPath $fakeScoop -Encoding UTF8
        Mock Get-CapsulenvScoopExecutable { $fakeScoop } -ModuleName Capsulenv

        $exitCode = & $script:Module { Invoke-CapsulenvScoopCommand -Arguments @('noop') -AllowFailure }

        @($exitCode).Count | Should -Be 1
        $exitCode | Should -BeOfType ([int])
        $exitCode | Should -Be 0
    }

    It 'selects the only metadata-bearing legacy version when current is unavailable' {
        $appRoot = Join-Path $TestDrive 'single/apps/tool'
        $versionRoot = Join-Path $appRoot '1.0.0'
        New-Item -ItemType Directory -Path $versionRoot -Force | Out-Null
        '{}' | Set-Content -LiteralPath (Join-Path $versionRoot 'manifest.json') -Encoding UTF8
        '{}' | Set-Content -LiteralPath (Join-Path $versionRoot 'install.json') -Encoding UTF8
        $location = [pscustomobject]@{
            Selector = 'user/tool'
            Name = 'tool'
            AppRoot = $appRoot
            CurrentRoot = (Join-Path $appRoot 'current')
        }

        $resolved = & $script:Module { param($Location) Resolve-CapsulenvLegacyScoopVersionRoot -Location $Location } $location
        $resolved | Should -Be $versionRoot
    }

    It 'fails closed when multiple legacy versions exist without active-version evidence' {
        $appRoot = Join-Path $TestDrive 'ambiguous/apps/tool'
        foreach ($version in @('1.0.0', '2.0.0')) {
            $versionRoot = Join-Path $appRoot $version
            New-Item -ItemType Directory -Path $versionRoot -Force | Out-Null
            '{}' | Set-Content -LiteralPath (Join-Path $versionRoot 'manifest.json') -Encoding UTF8
            '{}' | Set-Content -LiteralPath (Join-Path $versionRoot 'install.json') -Encoding UTF8
        }
        $location = [pscustomobject]@{
            Selector = 'user/tool'
            Name = 'tool'
            AppRoot = $appRoot
            CurrentRoot = (Join-Path $appRoot 'current')
        }

        { & $script:Module { param($Location) Resolve-CapsulenvLegacyScoopVersionRoot -Location $Location } $location } |
            Should -Throw '*Cannot prove the active version*upstream*'
    }

    It 'rejects legacy selectors that could escape the Scoop app root' {
        { & $script:Module { Get-CapsulenvLegacyScoopLocation -Selector 'user/..' } } |
            Should -Throw '*Invalid installed app name*'
    }

    It 'does not trust a legacy current link whose target is outside the app root' {
        $appRoot = Join-Path $TestDrive 'outside-target/apps/tool'
        $outside = Join-Path $TestDrive 'outside-target/foreign/1.0.0'
        New-Item -ItemType Directory -Path $appRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        '{}' | Set-Content -LiteralPath (Join-Path $outside 'manifest.json') -Encoding UTF8
        '{}' | Set-Content -LiteralPath (Join-Path $outside 'install.json') -Encoding UTF8
        $location = [pscustomobject]@{
            Selector = 'user/tool'
            Name = 'tool'
            AppRoot = $appRoot
            CurrentRoot = (Join-Path $appRoot 'current')
        }

        Mock Get-CapsulenvReparseTarget { $outside } -ModuleName Capsulenv -ParameterFilter {
            $Path -eq $location.CurrentRoot
        }
        Mock Get-CapsulenvReparseTarget { $null } -ModuleName Capsulenv -ParameterFilter {
            $Path -ne $location.CurrentRoot
        }

        { & $script:Module { param($Location) Resolve-CapsulenvLegacyScoopVersionRoot -Location $Location } $location } |
            Should -Throw '*No installed version metadata*'
    }
}
