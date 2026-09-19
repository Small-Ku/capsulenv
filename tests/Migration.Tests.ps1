Describe 'Capsulenv explicit migration and legacy isolation' {
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

    It 'reports that startup and ownership no longer depend on legacy repair/path scans' {
        $audit = & $script:Module { Test-CapsulenvLegacyIsolation }
        $audit.Passed | Should -BeTrue
        $audit.StartupBroadRehydrate | Should -BeFalse
        $audit.ExecutablePathOwnership | Should -BeFalse
        $audit.OnRehydrateSteadyState | Should -BeFalse
        $audit.BrowserScoopPersistAuthority | Should -BeFalse
        $audit.InteractivePowerShellControlFallback | Should -BeFalse
        $audit.ForeignBitwardenRejection | Should -BeFalse
        $audit.RemovableUserIntegration | Should -BeFalse
    }

    It 'migrates an explicitly selected PowerShell profile into portable State' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-migration-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $legacyProfile = Join-Path $temporaryRoot 'legacy/profile.ps1'
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $legacyProfile) -Force)
            'Write-Output migrated' | Set-Content -LiteralPath $legacyProfile -Encoding UTF8
            $result = & $script:Module {
                param($CapsuleRoot, $LegacyProfile)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                Invoke-CapsulenvLegacyMigration -LegacyPowerShellProfilePath $LegacyProfile -MigratePowerShellProfile -Force
            } (Join-Path $temporaryRoot 'capsule') $legacyProfile

            $result.Results[0].Status | Should -Be 'Migrated'
            $portable = & $script:Module { (Get-CapsulenvPowerShellStatePaths).ProfilePath }
            (Get-Content -LiteralPath $portable -Raw) | Should -Match 'migrated'
        } finally {
            if ($null -eq $oldStateRoot) {
                Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_STATE_ROOT = $oldStateRoot
            }
        }
    }

    It 'establishes migrated Gecko compatibility evidence from the legacy profile' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-migration-gecko-' + [Guid]::NewGuid().ToString('N'))
        $legacy = Join-Path $temporaryRoot 'legacy-profile'
        $portable = Join-Path $temporaryRoot 'portable-profile'
        [void](New-Item -ItemType Directory -Path $legacy -Force)
        [void](New-Item -ItemType Directory -Path $portable -Force)
        "[Compatibility]`nLastVersion=123.0.1`n" | Set-Content -LiteralPath (Join-Path $legacy 'compatibility.ini') -Encoding UTF8
        $result = & $script:Module {
            param($CapsuleRoot, $Legacy, $Portable)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $evidence = Set-CapsulenvMigratedBrowserCompatibilityEvidence -LegacyProfile $Legacy -PortableProfile $Portable -BrowserApp firefox
            [pscustomobject]@{
                GeckoMajor = $evidence.GeckoMajor
                Evidence = Get-Content -LiteralPath (Join-Path $Portable '.capsulenv-gecko-compatibility.json') -Raw | ConvertFrom-Json
            }
        } (Join-Path $temporaryRoot 'capsule') $legacy $portable

        $result.GeckoMajor | Should -Be 123
        $result.Evidence.GeckoMajor | Should -Be 123
        $result.Evidence.ProductId | Should -Be 'firefox'
    }
    It 'requires an explicit supported migration scope' {
        & $script:Module {
            { Invoke-CapsulenvLegacyMigration } | Should -Throw '*explicit supported scope*'
        }
    }

    It 'preserves an existing state directory when staged file publication fails' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-migration-transaction-' + [Guid]::NewGuid().ToString('N'))
        $source = Join-Path $temporaryRoot 'legacy/profile.ps1'
        $destination = Join-Path $temporaryRoot 'state/profile.ps1'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force)
        [void](New-Item -ItemType Directory -Path $destination -Force)
        'old-valid-state' | Set-Content -LiteralPath (Join-Path $destination 'marker.txt') -Encoding UTF8
        'new-state' | Set-Content -LiteralPath $source -Encoding UTF8
        $result = & $script:Module {
            param($Source, $Destination)
            $threw = $false
            try { Copy-CapsulenvLegacyStateItem -Source $Source -Destination $Destination -Force | Out-Null } catch { $threw = $true }
            [pscustomobject]@{
                Threw = $threw
                Marker = (Get-Content -LiteralPath (Join-Path $Destination 'marker.txt') -Raw).Trim()
            }
        } $source $destination
        $result.Threw | Should -BeTrue
        $result.Marker | Should -Be 'old-valid-state'
    }


}
