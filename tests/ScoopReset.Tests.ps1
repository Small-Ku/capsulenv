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

    It 'builds the rehydrate desired-state DAG without binding adjacent nodes into Verify' {
        Mock Get-CapsulenvRelocationContext { [pscustomobject]@{ HasPathChanges = $false } } -ModuleName Capsulenv
        Mock Get-CapsulenvToolRelocationConfiguration { [pscustomobject]@{ Enabled = $false; AutoRepair = $false } } -ModuleName Capsulenv

        $rehydrate = Get-CapsulenvScoopRehydratePlan -IntegrationMode ShellOnly

        @($rehydrate.Plan.Nodes).Count | Should -Be 9
        @($rehydrate.Plan.Nodes | ForEach-Object { $_.Node.Verify }).Count | Should -Be 9
        @($rehydrate.Plan.Nodes | Where-Object { $_.Node.Verify -isnot [scriptblock] }).Count | Should -Be 0
        @($rehydrate.Plan.Nodes.Id) | Should -Contain 'package-host-integration'
        $projectionNode = @($rehydrate.Plan.Nodes | Where-Object Id -eq 'package-projections')[0].Node
        $hostNode = @($rehydrate.Plan.Nodes | Where-Object Id -eq 'package-host-integration')[0].Node
        @($projectionNode.WriteResources) | Should -Not -Contain 'host:///start-menu/capsulenv'
        @($hostNode.WriteResources) | Should -Contain 'host:///start-menu/capsulenv'
        $sessionNode = @($rehydrate.Plan.Nodes | Where-Object Id -eq 'session-environment')[0].Node
        $toolNode = @($rehydrate.Plan.Nodes | Where-Object Id -eq 'tool-relocation')[0].Node
        $userNode = @($rehydrate.Plan.Nodes | Where-Object Id -eq 'user-integration')[0].Node
        @($sessionNode.WriteResources) | Should -Contain 'capsule:///tool-storage'
        @($sessionNode.WriteResources) | Should -Contain 'capsule:///runtime-directories'
        @($toolNode.WriteResources) | Should -Contain 'process:///environment'
        @($toolNode.WriteResources) | Should -Contain 'host:///workspaces/registered'
        @($userNode.WriteResources) | Should -Contain 'capsule:///state/user-environment-backup'
        @($userNode.WriteResources) | Should -Contain 'capsule:///state/install-mode'
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

        $record = & $script:Module {
            param($Location)
            try { Resolve-CapsulenvLegacyScoopVersionRoot -Location $Location } catch { $_ }
        } $location
        $record.FullyQualifiedErrorId | Should -Be 'Capsulenv.LegacyScoopProjection.AmbiguousVersion'
        $record.ErrorDetails.Message | Should -Match 'Cannot prove the active version'
        @(& $script:Module { param($Record) Get-CapsulenvDiagnosticRemediation -ErrorRecord $Record } $record) -join ' ' | Should -Match 'upstream.*scoop reset'
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

    It 'defers a known legacy ownership ambiguity during automatic rehydrate repair' {
        $script:LegacyAmbiguityRecord = & $script:Module {
            New-CapsulenvDiagnosticErrorRecord `
                -Id 'Capsulenv.LegacyScoopProjection.AmbiguousVersion' `
                -Message 'Cannot prove active version for test fixture.' `
                -TargetObject 'user/tool' `
                -Remediation @("Run upstream 'scoop reset tool'.")
        }
        Mock Get-CapsulenvInstalledPackageStates { @() } -ModuleName Capsulenv
        Mock Get-CapsulenvLegacyScoopSelectors { @('user/tool') } -ModuleName Capsulenv
        Mock Repair-CapsulenvLegacyScoopAppProjection { throw $script:LegacyAmbiguityRecord } -ModuleName Capsulenv

        $report = & $script:Module {
            Invoke-CapsulenvInstalledAppProjectionRepair `
                -IntegrationMode ShellOnly `
                -DeferRunningApps `
                -DeferUnsafeLegacyProjectionFailures
        }

        $report.Complete | Should -BeFalse
        $report.RetryRequired | Should -BeFalse
        $report.Issues | Should -HaveCount 1
        $report.Issues[0].Selector | Should -Be 'user/tool'
        $report.Issues[0].ErrorId | Should -Be 'Capsulenv.LegacyScoopProjection.AmbiguousVersion'
        $report.Issues[0].Summary | Should -Match 'Cannot prove active version'
        Should -Invoke Repair-CapsulenvLegacyScoopAppProjection -ModuleName Capsulenv -Times 1 -Exactly
    }

    It 'keeps explicit reset fail-closed for the same legacy ownership ambiguity' {
        $script:LegacyAmbiguityRecord = & $script:Module {
            New-CapsulenvDiagnosticErrorRecord `
                -Id 'Capsulenv.LegacyScoopProjection.AmbiguousVersion' `
                -Message 'Cannot prove active version for test fixture.' `
                -TargetObject 'user/tool'
        }
        Mock Get-CapsulenvInstalledPackageStates { @() } -ModuleName Capsulenv
        Mock Get-CapsulenvLegacyScoopSelectors { @('user/tool') } -ModuleName Capsulenv
        Mock Repair-CapsulenvLegacyScoopAppProjection { throw $script:LegacyAmbiguityRecord } -ModuleName Capsulenv

        { Repair-CapsulenvInstalledAppProjections -IntegrationMode ShellOnly } |
            Should -Throw -ErrorId 'Capsulenv.LegacyScoopProjection.AmbiguousVersion'
    }

    It 'persists sanitized projection issues in rehydration state schema 5' {
        $statePath = Join-Path $TestDrive 'state/scoop-rehydration.json'
        Mock Get-CapsulenvRehydrationStatePath { $statePath } -ModuleName Capsulenv
        Mock Get-CapsulenvRelocationFingerprint {
            [ordered]@{
                CapsuleId='test'; Root='X:\\cap'; ScoopRoot='X:\\cap\\scoop'; ScoopGlobalRoot='X:\\cap\\scoop-global'
                ComputerName='host'; User='domain\\user'
            }
        } -ModuleName Capsulenv
        $issue = [pscustomobject]@{
            Selector='user/tool'; ErrorId='Capsulenv.LegacyScoopProjection.AmbiguousVersion'
            Summary='ambiguous'; Remediation=@('use upstream reset'); Retryable=$false
        }

        & $script:Module {
            param($Issue)
            Save-CapsulenvRehydrationState `
                -RelocationContext $null `
                -PersistRepairResult $null `
                -PendingProjectionRepair $true `
                -ProjectionRepairIssues @($Issue)
        } $issue

        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $saved.SchemaVersion | Should -Be 5
        $saved.PendingProjectionRepair | Should -BeTrue
        @($saved.ProjectionRepairIssues) | Should -HaveCount 1
        $saved.ProjectionRepairIssues[0].Selector | Should -Be 'user/tool'
        $saved.ProjectionRepairIssues[0].ErrorId | Should -Be 'Capsulenv.LegacyScoopProjection.AmbiguousVersion'
    }

    It 'does not force every activation to retry a non-retryable legacy ownership issue' {
        $statePath = Join-Path $TestDrive 'state/nonretryable-rehydration.json'
        Mock Get-CapsulenvRehydrationStatePath { $statePath } -ModuleName Capsulenv
        Mock Get-CapsulenvRelocationFingerprint {
            [ordered]@{
                CapsuleId='test'; Root='X:\cap'; ScoopRoot='X:\cap\scoop'; ScoopGlobalRoot='X:\cap\scoop-global'
                ComputerName='host'; User='domain\user'
            }
        } -ModuleName Capsulenv
        $issue = [pscustomobject]@{
            Selector='user/tool'; ErrorId='Capsulenv.LegacyScoopProjection.AmbiguousVersion'
            Summary='ambiguous'; Remediation=@('use upstream reset'); Retryable=$false
        }

        $required = & $script:Module {
            param($Issue)
            Save-CapsulenvRehydrationState `
                -RelocationContext $null `
                -PersistRepairResult $null `
                -PendingProjectionRepair $false `
                -ProjectionRepairIssues @($Issue)
            Test-CapsulenvScoopRehydrationRequired
        } $issue

        $required | Should -BeFalse
    }


}
