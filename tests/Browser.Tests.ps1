Describe 'Capsulenv Gecko browser configuration selection' {
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

    It 'resolves a scoped installed app through one unscoped built-in definition' {
        $configPath = Join-Path $script:Root 'config/capsulenv.psd1'
        $configuration = & $script:Module { param($dataPath) Import-CapsulenvPowerShellDataFile -LiteralPath $dataPath } $configPath

        $definition = & $script:Module {
            param($Configuration)
            Get-CapsulenvBrowserDefinitionFromConfiguration -Configuration $Configuration -App 'user/librewolf'
        } $configuration

        $definition.App | Should -Be 'librewolf'
        $definition.ProfilePath | Should -Be 'Profiles\Default'
    }

    It 'prefers an exact scoped definition over an unscoped same-app fallback' {
        $configuration = @{
            Browsers = @{
                Generic = @{ App = 'librewolf'; ProfilePath = 'generic'; ProfileArgument = '-profile' }
                UserSpecific = @{ App = 'user/librewolf'; ProfilePath = 'user-profile'; ProfileArgument = '-profile' }
            }
        }

        $definition = & $script:Module {
            param($Configuration)
            Get-CapsulenvBrowserDefinitionFromConfiguration -Configuration $Configuration -App 'user/librewolf'
        } $configuration

        $definition.ProfilePath | Should -Be 'user-profile'
    }

    It 'still rejects genuinely ambiguous unscoped definitions for one app' {
        $configuration = @{
            Browsers = @{
                First = @{ App = 'librewolf'; ProfilePath = 'one'; ProfileArgument = '-profile' }
                Second = @{ App = 'librewolf'; ProfilePath = 'two'; ProfileArgument = '-profile' }
            }
        }

        & $script:Module {
            param($Configuration)
            { Get-CapsulenvBrowserDefinitionFromConfiguration -Configuration $Configuration -App 'global/librewolf' } |
                Should -Throw "Multiple Browsers entries select Scoop app 'global/librewolf'."
        } $configuration
    }
}

Describe 'Capsulenv Gecko browser launch contracts' {
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

    It 'uses the manifest launcher for LibreWolf interactive launch but the inner Gecko executable for default delegation' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-librewolf-entrypoints-' + [Guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $temporaryRoot 'config/capsulenv.psd1')
            $current = Join-Path $temporaryRoot 'scoop/apps/librewolf/current'
            $persist = Join-Path $temporaryRoot 'scoop/persist/librewolf'
            [void](New-Item -ItemType Directory -Path (Join-Path $current 'LibreWolf') -Force)
            [void](New-Item -ItemType Directory -Path (Join-Path $current 'Profiles/Default') -Force)
            [void](New-Item -ItemType Directory -Path (Join-Path $persist 'Profiles/Default') -Force)
            '' | Set-Content -LiteralPath (Join-Path $current 'LibreWolf-Portable.exe') -Encoding UTF8
            '' | Set-Content -LiteralPath (Join-Path $current 'LibreWolf/librewolf.exe') -Encoding UTF8
            '{"version":"1.0","bin":[["LibreWolf-Portable.exe","librewolf"]],"shortcuts":[["LibreWolf-Portable.exe","LibreWolf"]],"persist":"Profiles"}' |
                Set-Content -LiteralPath (Join-Path $current 'manifest.json') -Encoding UTF8
            '{"architecture":"64bit","bucket":"extras"}' |
                Set-Content -LiteralPath (Join-Path $current 'install.json') -Encoding UTF8

            $resolved = & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                [void](Get-CapsulenvConfiguration -Refresh)
                [pscustomobject]@{
                    Interactive = Get-CapsulenvBrowserExecutable -App librewolf
                    Default = Get-CapsulenvBrowserDefaultExecutable -App librewolf
                    Profile = Get-CapsulenvBrowserProfilePath -App librewolf
                }
            } $temporaryRoot

            $resolved.Interactive | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $current 'LibreWolf-Portable.exe')))
            $resolved.Default | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $current 'LibreWolf/librewolf.exe')))
            $resolved.Profile | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $current 'Profiles/Default')))
        } finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

    It 'resolves an explicit same-product host executable without relaxing capsule executable lookup' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-browser-host-' + [Guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $temporaryRoot 'config/capsulenv.psd1')
            $hostFirefox = Join-Path $temporaryRoot 'machine-browser/firefox.exe'
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $hostFirefox) -Force)
            '' | Set-Content -LiteralPath $hostFirefox -Encoding UTF8
            @"
@{
    Browsers = @{
        Firefox = @{
            HostExecutableCandidates = @('$($hostFirefox.Replace("'", "''"))')
            HostCommandNames = @()
        }
    }
}
"@ | Set-Content -LiteralPath (Join-Path $temporaryRoot 'config/capsulenv.local.psd1') -Encoding UTF8

            Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
            $resolved = & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                [void](Get-CapsulenvConfiguration -Refresh)
                Get-CapsulenvHostBrowserExecutable -App firefox
            } $temporaryRoot
            $resolved | Should -Be ([System.IO.Path]::GetFullPath($hostFirefox))
        } finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

    It 'dispatches the primary browser command by Scoop app selector without a preset ValidateSet' {
        Mock Start-CapsulenvBrowser {} -ModuleName Capsulenv
        $previousRoot = $env:CAPSULENV_ROOT
        try {
            $env:CAPSULENV_ROOT = $script:Root
            Invoke-Capsulenv -Arguments @('browser', 'global/my-gecko', 'https://example.invalid/')

            Should -Invoke Start-CapsulenvBrowser -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
                $App -eq 'global/my-gecko' -and
                -not $UseHostExecutable -and
                @($Arguments).Count -eq 1 -and
                $Arguments[0] -eq 'https://example.invalid/'
            }
        } finally {
            $env:CAPSULENV_ROOT = $previousRoot
        }
    }

    It 'treats --host as a Capsulenv-only leading browser option' {
        Mock Start-CapsulenvBrowser {} -ModuleName Capsulenv
        & $script:Module {
            Invoke-CapsulenvBrowserCommand -App librewolf -Arguments @('--host', 'https://example.invalid/')
        }
        Should -Invoke Start-CapsulenvBrowser -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            $App -eq 'librewolf' -and $UseHostExecutable -and @($Arguments).Count -eq 1 -and $Arguments[0] -eq 'https://example.invalid/'
        }

        & $script:Module {
            { Invoke-CapsulenvBrowserCommand -App firefox -Arguments @('https://example.invalid/', '--host') } |
                Should -Throw '*--host must be the first browser argument*'
        }
    }
}

Describe 'Capsulenv User default-browser integration' {
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

    It 'registers URL and HTML handlers against the real Gecko executable with the Scoop-persisted profile' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-default-browser-' + [Guid]::NewGuid().ToString('N'))
        try {
            $executable = Join-Path $temporaryRoot 'LibreWolf/librewolf.exe'
            $profile = Join-Path $temporaryRoot 'Profiles/Default'
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $executable) -Force)
            [void](New-Item -ItemType Directory -Path $profile -Force)
            '' | Set-Content -LiteralPath $executable -Encoding UTF8

            Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
            Mock Get-CapsulenvIdentity { '11111111-2222-3333-4444-555555555555' } -ModuleName Capsulenv
            Mock Get-CapsulenvHostIntegrationKey { 'host-key' } -ModuleName Capsulenv
            Mock Get-CapsulenvBrowserDefaultExecutable { $executable } -ModuleName Capsulenv
            Mock Get-CapsulenvBrowserProfilePath { $profile } -ModuleName Capsulenv
            Mock Get-CapsulenvBrowserDefinition { @{ ProfileArgument = '-profile'; DisplayName = 'LibreWolf' } } -ModuleName Capsulenv
            Mock Get-CapsulenvDefaultBrowserState { $null } -ModuleName Capsulenv
            Mock Test-CapsulenvCurrentUserRegistryKey { $false } -ModuleName Capsulenv
            Mock Get-CapsulenvCurrentUserRegistryRawValue { [pscustomobject]@{ Exists = $false; Value = $null } } -ModuleName Capsulenv
            Mock Write-CapsulenvDefaultBrowserState {} -ModuleName Capsulenv
            Mock Set-CapsulenvCurrentUserRegistryStringValue {} -ModuleName Capsulenv
            Mock Send-CapsulenvAssociationChanged {} -ModuleName Capsulenv

            $registration = & $script:Module { Install-CapsulenvDefaultBrowserRegistration -App librewolf }

            $registration.RegisteredName | Should -Match '^Capsulenv LibreWolf'
            Should -Invoke Set-CapsulenvCurrentUserRegistryStringValue -ModuleName Capsulenv -Times 1 -ParameterFilter {
                $SubKey -like '*\URLAssociations' -and $Name -eq 'https' -and $Value -eq $registration.UrlProgId
            }
            Should -Invoke Set-CapsulenvCurrentUserRegistryStringValue -ModuleName Capsulenv -Times 1 -ParameterFilter {
                $SubKey -eq $registration.CapabilitiesPath -and
                $Name -eq 'ApplicationName' -and
                $Value -eq $registration.RegisteredName
            }
            Should -Invoke Set-CapsulenvCurrentUserRegistryStringValue -ModuleName Capsulenv -Times 1 -ParameterFilter {
                $SubKey -eq ($registration.UrlClassPath + '\shell\open\command') -and
                $Name -eq '' -and
                $Value -like ('*' + $executable + '*') -and
                $Value -like ('*' + $profile + '*') -and
                $Value -notlike '*-osint*' -and
                $Value -like '*-url*' -and
                $Value -notlike '*LibreWolf-Portable.exe*'
            }
            Should -Invoke Set-CapsulenvCurrentUserRegistryStringValue -ModuleName Capsulenv -Times 1 -ParameterFilter {
                $SubKey -eq ($registration.HtmlClassPath + '\shell\open\command') -and
                $Name -eq '' -and
                $Value -like ('*' + $executable + '*') -and
                $Value -like ('*' + $profile + '*') -and
                $Value -notlike '*-url*'
            }
        } finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

    It 'does not combine Gecko -osint with an explicit portable profile' {
        $command = & $script:Module {
            ConvertTo-CapsulenvDefaultBrowserCommand `
                -Executable 'F:\Capsule Root\LibreWolf\librewolf.exe' `
                -Profile 'F:\Capsule Root\scoop\persist\librewolf\Profiles\Default' `
                -ProfileArgument '-profile' `
                -Kind Url
        }

        $command | Should -Not -Match '(?i)(^|\s)-{1,2}osint(\s|$)'
        $command | Should -Match '(?i)(^|\s)-profile\s'
        $command | Should -Match '(?i)(^|\s)-url\s+"%1"$'
    }

    It 'reuses exact schema-1 registration paths when the old preset maps to the selected Scoop app' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-default-browser-legacy-' + [Guid]::NewGuid().ToString('N'))
        try {
            $executable = Join-Path $temporaryRoot 'LibreWolf/librewolf.exe'
            $profile = Join-Path $temporaryRoot 'Profiles/Default'
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $executable) -Force)
            [void](New-Item -ItemType Directory -Path $profile -Force)
            '' | Set-Content -LiteralPath $executable -Encoding UTF8
            $legacyState = [pscustomobject]@{
                SchemaVersion = 1
                Browser = 'LibreWolf'
                RegisteredName = 'Capsulenv LibreWolf (legacy)'
                ClientPath = 'Software\Clients\StartMenuInternet\Capsulenv.Legacy.LibreWolf'
                UrlClassPath = 'Software\Classes\Capsulenv.Legacy.LibreWolf.URL'
                HtmlClassPath = 'Software\Classes\Capsulenv.Legacy.LibreWolf.HTML'
                UrlProgId = 'Capsulenv.Legacy.LibreWolf.URL'
                HtmlProgId = 'Capsulenv.Legacy.LibreWolf.HTML'
            }

            Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
            Mock Get-CapsulenvIdentity { '11111111-2222-3333-4444-555555555555' } -ModuleName Capsulenv
            Mock Get-CapsulenvBrowserDefaultExecutable { $executable } -ModuleName Capsulenv
            Mock Get-CapsulenvBrowserProfilePath { $profile } -ModuleName Capsulenv
            Mock Get-CapsulenvBrowserDefinition { @{ ProfileArgument = '-profile'; DisplayName = 'LibreWolf' } } -ModuleName Capsulenv
            Mock Get-CapsulenvDefaultBrowserState { $legacyState } -ModuleName Capsulenv
            Mock Set-CapsulenvCurrentUserRegistryStringValue {} -ModuleName Capsulenv
            Mock Send-CapsulenvAssociationChanged {} -ModuleName Capsulenv

            $registration = & $script:Module { Install-CapsulenvDefaultBrowserRegistration -App librewolf }

            $registration.UrlProgId | Should -Be $legacyState.UrlProgId
            $registration.HtmlProgId | Should -Be $legacyState.HtmlProgId
            $registration.ClientPath | Should -Be $legacyState.ClientPath
            Should -Invoke Set-CapsulenvCurrentUserRegistryStringValue -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
                $SubKey -like '*\URLAssociations' -and $Name -eq 'https' -and $Value -eq $legacyState.UrlProgId
            }
        } finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

    It 'checks the Shell effective ProgIDs instead of reading legacy UserChoice directly' {
        Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
        Mock Get-CapsulenvEffectiveAssociationProgId {
            param($Association, $Type)
            if ($Type -eq 'Protocol') { return 'Capsulenv.URL' }
            return 'Capsulenv.HTML'
        } -ModuleName Capsulenv

        $selected = & $script:Module {
            Test-CapsulenvDefaultBrowserProgIdsSelected `
                -UrlProgId 'Capsulenv.URL' `
                -HtmlProgId 'Capsulenv.HTML'
        }

        $selected | Should -BeTrue
        Should -Invoke Get-CapsulenvEffectiveAssociationProgId -ModuleName Capsulenv -Times 4 -Exactly
    }

    It 'prefers rotated UserChoiceLatest in the registry fallback when COM lookup is unavailable' {
        Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
        Mock Get-CapsulenvRegistryStringValue {
            param($Hive, $SubKey, $Name)
            if ($SubKey -like '*\UserChoiceLatest\ProgId') {
                return 'Capsulenv.Latest.URL'
            }
            return 'MSEdgeHTM'
        } -ModuleName Capsulenv

        $progId = & $script:Module {
            Get-CapsulenvEffectiveAssociationProgId -Association 'https' -Type Protocol
        }

        $progId | Should -Be 'Capsulenv.Latest.URL'
        Should -Invoke Get-CapsulenvRegistryStringValue -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            $SubKey -eq 'Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoiceLatest\ProgId' -and
            $Name -eq 'ProgId'
        }
    }

    It 'opens the targeted Windows Default Apps page only when the configured browser is not already selected' {
        Mock Get-CapsulenvConfiguredDefaultBrowser { 'librewolf' } -ModuleName Capsulenv
        Mock Get-CapsulenvInstallMode { 'User' } -ModuleName Capsulenv
        Mock Install-CapsulenvDefaultBrowserRegistration {
            [pscustomobject]@{ RegisteredName = 'Capsulenv LibreWolf (111111111111)'; DisplayName = 'LibreWolf (Capsulenv)'; UrlProgId = 'Capsulenv.URL'; HtmlProgId = 'Capsulenv.HTML' }
        } -ModuleName Capsulenv
        Mock Test-CapsulenvDefaultBrowserProgIdsSelected { $false } -ModuleName Capsulenv
        Mock Get-CapsulenvBrowserDisplayName { 'LibreWolf' } -ModuleName Capsulenv
        Mock Open-CapsulenvDefaultAppsSettings {} -ModuleName Capsulenv
        Mock Write-CapsulenvMessage {} -ModuleName Capsulenv

        & $script:Module { Sync-CapsulenvConfiguredDefaultBrowser }
        Should -Invoke Open-CapsulenvDefaultAppsSettings -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            $RegisteredName -eq 'Capsulenv LibreWolf (111111111111)'
        }

        Mock Test-CapsulenvDefaultBrowserProgIdsSelected { $true } -ModuleName Capsulenv
        & $script:Module { Sync-CapsulenvConfiguredDefaultBrowser }
        Should -Invoke Open-CapsulenvDefaultAppsSettings -ModuleName Capsulenv -Times 1 -Exactly
    }

    It 'repairs an owned tracked registration even when DefaultBrowser is currently blank' {
        Mock Get-CapsulenvConfiguredDefaultBrowser { '' } -ModuleName Capsulenv
        Mock Get-CapsulenvInstallMode { 'User' } -ModuleName Capsulenv
        Mock Get-CapsulenvDefaultBrowserState {
            [pscustomobject]@{
                SchemaVersion = 2
                App = 'librewolf'
                UrlProgId = 'Capsulenv.URL'
                HtmlProgId = 'Capsulenv.HTML'
            }
        } -ModuleName Capsulenv
        Mock Get-CapsulenvDefaultBrowserStateApp { 'librewolf' } -ModuleName Capsulenv
        Mock Install-CapsulenvDefaultBrowserRegistration {
            [pscustomobject]@{
                RegisteredName = 'Capsulenv LibreWolf'
                DisplayName = 'LibreWolf'
                UrlProgId = 'Capsulenv.URL'
                HtmlProgId = 'Capsulenv.HTML'
            }
        } -ModuleName Capsulenv
        Mock Open-CapsulenvDefaultAppsSettings {} -ModuleName Capsulenv
        Mock Write-CapsulenvMessage {} -ModuleName Capsulenv

        & $script:Module { Sync-CapsulenvConfiguredDefaultBrowser }

        Should -Invoke Install-CapsulenvDefaultBrowserRegistration -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            $App -eq 'librewolf'
        }
        Should -Invoke Open-CapsulenvDefaultAppsSettings -ModuleName Capsulenv -Times 0 -Exactly
    }

    It 'reports a stale tracked URL command against the command generated by the current runtime' {
        Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
        Mock Get-CapsulenvDefaultBrowserState {
            [pscustomobject]@{
                SchemaVersion = 2
                App = 'librewolf'
                UrlProgId = 'Capsulenv.URL'
                UrlClassPath = 'Software\Classes\Capsulenv.URL'
            }
        } -ModuleName Capsulenv
        Mock Get-CapsulenvDefaultBrowserStateApp { 'librewolf' } -ModuleName Capsulenv
        Mock Get-CapsulenvBrowserDefinition { @{ ProfileArgument = '-profile' } } -ModuleName Capsulenv
        Mock Get-CapsulenvBrowserDefaultExecutable { 'F:\capenv\scoop\apps\librewolf\current\LibreWolf\librewolf.exe' } -ModuleName Capsulenv
        Mock Get-CapsulenvBrowserProfilePath { 'F:\capenv\scoop\apps\librewolf\current\Profiles\Default' } -ModuleName Capsulenv
        Mock Get-CapsulenvRegistryStringValue {
            'F:\capenv\scoop\apps\librewolf\current\LibreWolf\librewolf.exe -profile F:\capenv\scoop\persist\librewolf\Profiles\Default -osint -url "%1"'
        } -ModuleName Capsulenv

        $status = & $script:Module { Get-CapsulenvTrackedDefaultBrowserCommandStatus }

        $status.App | Should -Be 'librewolf'
        $status.ProgId | Should -Be 'Capsulenv.URL'
        $status.Matches | Should -BeFalse
        $status.ActualCommand | Should -Match '(?i)-osint'
        $status.ExpectedCommand | Should -Not -Match '(?i)-osint'
        $status.ExpectedCommand | Should -Match ([regex]::Escape('F:\capenv\scoop\apps\librewolf\current\Profiles\Default'))
    }


    It 'restores only its tracked registration and the exact prior RegisteredApplications value' {
        $temporaryState = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-default-browser-state-' + [Guid]::NewGuid().ToString('N') + '.json')
        '{}' | Set-Content -LiteralPath $temporaryState -Encoding UTF8
        try {
            Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
            Mock Get-CapsulenvDefaultBrowserState {
                [pscustomobject]@{
                    Browser = 'LibreWolf'
                    RegisteredName = 'Capsulenv LibreWolf (111111111111)'
                    ClientPath = 'Software\Clients\StartMenuInternet\Capsulenv.Librewolf'
                    UrlClassPath = 'Software\Classes\Capsulenv.Librewolf.URL'
                    HtmlClassPath = 'Software\Classes\Capsulenv.Librewolf.HTML'
                    PreviousRegisteredApplication = [pscustomobject]@{ Exists = $true; Value = 'Software\Previous\Capabilities' }
                }
            } -ModuleName Capsulenv
            Mock Get-CapsulenvDefaultBrowserStatePath { $temporaryState } -ModuleName Capsulenv
            Mock Assert-CapsulenvDefaultBrowserRestorable {} -ModuleName Capsulenv
            Mock Remove-CapsulenvCurrentUserRegistryTree {} -ModuleName Capsulenv
            Mock Remove-CapsulenvCurrentUserRegistryValue {} -ModuleName Capsulenv
            Mock Set-CapsulenvCurrentUserRegistryStringValue {} -ModuleName Capsulenv
            Mock Send-CapsulenvAssociationChanged {} -ModuleName Capsulenv

            & $script:Module { Restore-CapsulenvDefaultBrowserRegistration }

            Should -Invoke Remove-CapsulenvCurrentUserRegistryTree -ModuleName Capsulenv -Times 3 -Exactly
            Should -Invoke Set-CapsulenvCurrentUserRegistryStringValue -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
                $SubKey -eq 'Software\RegisteredApplications' -and
                $Name -eq 'Capsulenv LibreWolf (111111111111)' -and
                $Value -eq 'Software\Previous\Capabilities'
            }
            Should -Invoke Remove-CapsulenvCurrentUserRegistryValue -ModuleName Capsulenv -Times 0 -Exactly
            Test-Path -LiteralPath $temporaryState | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $temporaryState -Force -ErrorAction SilentlyContinue
        }
    }

    It 'refuses to unregister a portable browser while Windows still uses its UserChoice ProgIDs' {
        Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
        Mock Get-CapsulenvDefaultBrowserState {
            [pscustomobject]@{ Browser = 'LibreWolf'; RegisteredName = 'Capsulenv LibreWolf (111111111111)'; UrlProgId = 'Legacy.URL'; HtmlProgId = 'Legacy.HTML' }
        } -ModuleName Capsulenv
        Mock Test-CapsulenvDefaultBrowserProgIdsSelected { $true } -ModuleName Capsulenv
        Mock Open-CapsulenvDefaultAppsSettings {} -ModuleName Capsulenv

        & $script:Module {
            { Assert-CapsulenvDefaultBrowserRestorable } | Should -Throw '*still the Windows default browser*UserChoice hashes*'
        }
        Should -Invoke Open-CapsulenvDefaultAppsSettings -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            [string]::IsNullOrWhiteSpace([string]$RegisteredName)
        }
    }
}
