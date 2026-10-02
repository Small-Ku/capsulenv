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

    It 'keeps production documentation and default configuration on explicit state authority' {
        $architecture = Get-Content -LiteralPath (Join-Path $script:Root 'docs/ARCHITECTURE.md') -Raw
        $usage = Get-Content -LiteralPath (Join-Path $script:Root 'docs/USAGE.md') -Raw
        $readme = Get-Content -LiteralPath (Join-Path $script:Root 'README.md') -Raw
        $configuration = Get-Content -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Raw

        ($architecture + $usage + $readme) | Should -Not -Match '(?i)automatic rehydration'
        $configuration | Should -Match 'RehydrateOnRelocation\s*=\s*\$false'
        $configuration | Should -Match 'Explicit tool State scopes'
        $usage | Should -Match 'OnRehydrate.*explicitly requested'
    }

    It 'enforces the normative selector and state architecture over derived projections' {
        $architecture = Get-Content -LiteralPath (Join-Path $script:Root 'docs/ARCHITECTURE.md') -Raw
        $usage = Get-Content -LiteralPath (Join-Path $script:Root 'docs/USAGE.md') -Raw
        $configuration = Get-Content -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Raw

        $contractMatch = [regex]::Match($architecture, '(?ms)<!--\s*CAPSULENV-AUTHORITY-CONTRACT(?<body>.*?)-->')
        $contractMatch.Success | Should -BeTrue
        $contract = $contractMatch.Groups['body'].Value
        $contract | Should -Match '(?i)primary:.*provider-neutral-selector.*installed-state.*generation.*session.*host-integration'
        $contract | Should -Match '(?i)derived:.*package-projection.*shortcut-projection.*legacy-relocation-repair'

        $headings = @([regex]::Matches($architecture, '(?m)^##\s+(.+?)\s*$') | ForEach-Object { $_.Groups[1].Value })
        $headings[0] | Should -Be 'Normative runtime authority'
        $authorityIndex = [Array]::IndexOf($headings, 'Normative runtime authority')
        $legacyIndex = [Array]::IndexOf($headings, 'Bounded legacy projection adapter')
        $legacyIndex | Should -BeGreaterThan $authorityIndex
        $architecture | Should -Match '(?i)generation\s*->\s*session\s*->\s*process plan'
        $architecture | Should -Match '(?i)removable launcher is never persisted as the.*TargetPath'
        $usage | Should -Match '(?i)installed selector.*runtime identity'
        $usage | Should -Not -Match '(?i)Add `--host` only'
        $configuration | Should -Match '(?i)adapter.*tool State.*cache scopes'
    }

    It 'covers every detectable legacy kind with a handler or explicit remediation' {
        $coverage = & $script:Module {
            $inventory = [pscustomobject]@{
                LegacyBrowserProfilePresent = $true
                LegacyPowerShellProfilePresent = $true
                LegacyPowerShellHistoryPresent = $true
                LegacyScoopProjection = $true
                LegacyScoopPersist = $true
                LegacyToolStorage = $true
            }
            Get-CapsulenvMigrationCoverage -Inventory $inventory
        }

        @($coverage).Count | Should -BeGreaterThan 4
        @($coverage | Where-Object { $_.Detected -and [string]::IsNullOrWhiteSpace([string]$_.Handler) }).Count | Should -Be 0
        @($coverage | Where-Object { $_.Detected -and -not $_.Supported -and @($_.Remediation).Count -eq 0 }).Count | Should -Be 0
        @($coverage | Where-Object { $_.LegacyKind -eq 'LegacyScoopProjection' }).Handler | Should -Be 'Invoke-CapsulenvUnsupportedLegacyMigration'
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
            $second = & $script:Module {
                param($LegacyProfile)
                Invoke-CapsulenvLegacyMigration -LegacyPowerShellProfilePath $LegacyProfile -MigratePowerShellProfile
            } $legacyProfile
            @($second.Results.Status) | Should -Contain 'Skipped'
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

    It 'recovers the previous directory authority after an injected swap fault' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-directory-transaction-' + [Guid]::NewGuid().ToString('N'))
        $destination = Join-Path $temporaryRoot 'state'
        $staged = Join-Path $temporaryRoot 'staged'
        [void](New-Item -ItemType Directory -Path $destination -Force)
        [void](New-Item -ItemType Directory -Path $staged -Force)
        'old-valid-state' | Set-Content -LiteralPath (Join-Path $destination 'marker.txt') -Encoding UTF8
        'new-state' | Set-Content -LiteralPath (Join-Path $staged 'marker.txt') -Encoding UTF8

        $result = & $script:Module {
            param($Destination, $Staged)
            $threw = $false
            try {
                Publish-CapsulenvDirectoryAuthorityTransactionally `
                    -Path $Destination `
                    -StagedPath $Staged `
                    -FaultInjector { param($Phase) if ($Phase -eq 'AfterBackup') { throw 'injected directory publication fault' } }
            } catch {
                $threw = $true
            }
            [pscustomobject]@{
                Threw = $threw
                Marker = (Get-Content -LiteralPath (Join-Path $Destination 'marker.txt') -Raw).Trim()
                JournalExists = Test-Path -LiteralPath (Get-CapsulenvDirectoryAuthorityJournalPath -Path $Destination) -PathType Leaf
            }
        } $destination $staged

        $result.Threw | Should -BeTrue
        $result.Marker | Should -Be 'old-valid-state'
        $result.JournalExists | Should -BeFalse
    }

    It 'cleans a prepared transaction when no previous directory existed' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-directory-transaction-empty-' + [Guid]::NewGuid().ToString('N'))
        $destination = Join-Path $temporaryRoot 'state'
        $staged = Join-Path $temporaryRoot 'staged'
        [void](New-Item -ItemType Directory -Path $staged -Force)
        'new-state' | Set-Content -LiteralPath (Join-Path $staged 'marker.txt') -Encoding UTF8

        $result = & $script:Module {
            param($Destination, $Staged)
            $threw = $false
            try {
                Publish-CapsulenvDirectoryAuthorityTransactionally `
                    -Path $Destination `
                    -StagedPath $Staged `
                    -FaultInjector { param($Phase) if ($Phase -eq 'AfterBackup') { throw 'injected prepared fault' } }
            } catch {
                $threw = $true
            }
            $journalPath = Get-CapsulenvDirectoryAuthorityJournalPath -Path $Destination
            [pscustomobject]@{
                Threw = $threw
                DestinationExists = Test-Path -LiteralPath $Destination
                JournalExists = Test-Path -LiteralPath $journalPath -PathType Leaf
            }
        } $destination $staged

        $result.Threw | Should -BeTrue
        $result.DestinationExists | Should -BeFalse
        $result.JournalExists | Should -BeTrue

        $recovered = & $script:Module {
            param($Destination)
            Recover-CapsulenvDirectoryAuthorityTransaction -Path $Destination
        } $destination
        $recovered | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $temporaryRoot '.state.transaction.json') -PathType Leaf) | Should -BeFalse
    }


}
