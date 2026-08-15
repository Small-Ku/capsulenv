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
                Get-CapsulenvHostBrowserExecutable -Browser Firefox
            } $temporaryRoot
            $resolved | Should -Be ([System.IO.Path]::GetFullPath($hostFirefox))
        } finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

    It 'treats --host as a Capsulenv-only leading browser option' {
        Mock Start-CapsulenvBrowser {} -ModuleName Capsulenv
        & $script:Module {
            Invoke-CapsulenvBrowserCommand -Browser LibreWolf -Arguments @('--host', 'https://example.invalid/')
        }
        Should -Invoke Start-CapsulenvBrowser -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            $Browser -eq 'LibreWolf' -and $UseHostExecutable -and @($Arguments).Count -eq 1 -and $Arguments[0] -eq 'https://example.invalid/'
        }

        & $script:Module {
            { Invoke-CapsulenvBrowserCommand -Browser Firefox -Arguments @('https://example.invalid/', '--host') } |
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
            Mock Get-CapsulenvBrowserExecutable { $executable } -ModuleName Capsulenv
            Mock Get-CapsulenvBrowserProfilePath { $profile } -ModuleName Capsulenv
            Mock Get-CapsulenvBrowserDefinition { @{ ProfileArgument = '-profile' } } -ModuleName Capsulenv
            Mock Get-CapsulenvDefaultBrowserState { $null } -ModuleName Capsulenv
            Mock Test-CapsulenvCurrentUserRegistryKey { $false } -ModuleName Capsulenv
            Mock Get-CapsulenvCurrentUserRegistryRawValue { [pscustomobject]@{ Exists = $false; Value = $null } } -ModuleName Capsulenv
            Mock Write-CapsulenvDefaultBrowserState {} -ModuleName Capsulenv
            Mock Set-CapsulenvCurrentUserRegistryStringValue {} -ModuleName Capsulenv
            Mock Send-CapsulenvAssociationChanged {} -ModuleName Capsulenv

            $registration = & $script:Module { Install-CapsulenvDefaultBrowserRegistration -Browser LibreWolf }

            $registration.RegisteredName | Should -Match '^Capsulenv LibreWolf'
            Should -Invoke Set-CapsulenvCurrentUserRegistryStringValue -ModuleName Capsulenv -Times 1 -ParameterFilter {
                $SubKey -like '*\URLAssociations' -and $Name -eq 'https' -and $Value -eq $registration.UrlProgId
            }
            Should -Invoke Set-CapsulenvCurrentUserRegistryStringValue -ModuleName Capsulenv -Times 1 -ParameterFilter {
                $SubKey -eq ($registration.UrlClassPath + '\shell\open\command') -and
                $Name -eq '' -and
                $Value -like ('*' + $executable + '*') -and
                $Value -like ('*' + $profile + '*') -and
                $Value -like '*-osint*' -and
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

    It 'opens the targeted Windows Default Apps page only when the configured browser is not already selected' {
        Mock Get-CapsulenvConfiguredDefaultBrowser { 'LibreWolf' } -ModuleName Capsulenv
        Mock Get-CapsulenvInstallMode { 'User' } -ModuleName Capsulenv
        Mock Install-CapsulenvDefaultBrowserRegistration {
            [pscustomobject]@{ RegisteredName = 'Capsulenv LibreWolf (111111111111)'; DisplayName = 'LibreWolf (Capsulenv)' }
        } -ModuleName Capsulenv
        Mock Test-CapsulenvDefaultBrowserSelected { $false } -ModuleName Capsulenv
        Mock Open-CapsulenvDefaultAppsSettings {} -ModuleName Capsulenv
        Mock Write-CapsulenvMessage {} -ModuleName Capsulenv

        & $script:Module { Sync-CapsulenvConfiguredDefaultBrowser }
        Should -Invoke Open-CapsulenvDefaultAppsSettings -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            $RegisteredName -eq 'Capsulenv LibreWolf (111111111111)'
        }

        Mock Test-CapsulenvDefaultBrowserSelected { $true } -ModuleName Capsulenv
        & $script:Module { Sync-CapsulenvConfiguredDefaultBrowser }
        Should -Invoke Open-CapsulenvDefaultAppsSettings -ModuleName Capsulenv -Times 1 -Exactly
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
            [pscustomobject]@{ Browser = 'LibreWolf'; RegisteredName = 'Capsulenv LibreWolf (111111111111)' }
        } -ModuleName Capsulenv
        Mock Test-CapsulenvDefaultBrowserSelected { $true } -ModuleName Capsulenv
        Mock Open-CapsulenvDefaultAppsSettings {} -ModuleName Capsulenv

        & $script:Module {
            { Assert-CapsulenvDefaultBrowserRestorable } | Should -Throw '*still the Windows default browser*UserChoice hashes*'
        }
        Should -Invoke Open-CapsulenvDefaultAppsSettings -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            [string]::IsNullOrWhiteSpace([string]$RegisteredName)
        }
    }
}
