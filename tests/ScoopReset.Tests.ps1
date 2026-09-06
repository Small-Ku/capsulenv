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
        Mock Get-CapsulenvPackageProjectionRepairDescriptors { @() } -ModuleName Capsulenv
        Mock Get-CapsulenvProjectCacheRepairDescriptorSet { [pscustomobject]@{ Records=@(); RegistryError=$null } } -ModuleName Capsulenv

        $rehydrate = Get-CapsulenvScoopRehydratePlan -IntegrationMode ShellOnly

        @($rehydrate.Plan.Nodes).Count | Should -BeGreaterOrEqual 9
        @($rehydrate.Plan.Nodes | ForEach-Object { $_.Node.Verify }).Count | Should -Be @($rehydrate.Plan.Nodes).Count
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
        @($toolNode.WriteResources) | Should -Not -Contain 'process:///environment'
        @($toolNode.WriteResources) | Should -Contain 'host:///workspaces/registered'
        $toolNode.ExecutionAffinity | Should -Be 'AnyRunspace'
        $toolNode.ConcurrencyPolicy | Should -Be 'ResourceBound'
        $hostNode.ExecutionAffinity | Should -Be 'MainRunspace'
        $hostNode.ConcurrencyPolicy | Should -Be 'ResourceBound'
        @($userNode.WriteResources) | Should -Contain 'capsule:///state/user-environment-backup'
        @($userNode.WriteResources) | Should -Contain 'capsule:///state/install-mode'
    }

    It 'expands package projections into claim-safe parallel nodes with an aggregate barrier' {
        Mock Get-CapsulenvRelocationContext { [pscustomobject]@{ HasPathChanges = $false } } -ModuleName Capsulenv
        Mock Get-CapsulenvToolRelocationConfiguration { [pscustomobject]@{ Enabled = $false; AutoRepair = $false } } -ModuleName Capsulenv
        Mock Get-CapsulenvPackageProjectionRepairDescriptors {
            @(
                [pscustomobject]@{ Kind='Owned'; Selector='capsule/alpha'; Name='alpha'; Scope='Capsule'; Shims=@('alpha') },
                [pscustomobject]@{ Kind='Owned'; Selector='capsule/beta'; Name='beta'; Scope='Capsule'; Shims=@('beta') },
                [pscustomobject]@{ Kind='Legacy'; Selector='user/tool'; Name='tool'; Scope='User'; Shims=@() }
            )
        } -ModuleName Capsulenv
        Mock Get-CapsulenvProjectCacheRepairDescriptorSet { [pscustomobject]@{ Records=@(); RegistryError=$null } } -ModuleName Capsulenv

        $integration = & $script:Module {
            Get-CapsulenvIntegrationDesiredStatePlan -IntegrationMode ShellOnly -RehydrationRequired $true -IncludeDiagnostics
        }
        $projectionNodes = @($integration.Plan.Nodes | Where-Object { $_.Id -like 'package-projection:*' })
        $projectionNodes | Should -HaveCount 3
        @($projectionNodes | Where-Object { $_.Node.ExecutionAffinity -ne 'AnyRunspace' -or $_.Node.ConcurrencyPolicy -ne 'ResourceBound' }) | Should -HaveCount 0
        @($projectionNodes | ForEach-Object { @($_.Node.WriteResources) } | Where-Object { $_ -eq 'capsule:///packages/shims' }) | Should -HaveCount 0
        @($projectionNodes | ForEach-Object { @($_.Node.WriteResources) }) | Should -Contain 'capsule:///packages/shims/alpha'
        @($projectionNodes | ForEach-Object { @($_.Node.WriteResources) }) | Should -Contain 'capsule:///packages/shims/beta'
        $aggregate = @($integration.Plan.Nodes | Where-Object Id -eq 'package-projections')[0]
        @($aggregate.Node.DependsOn) | Should -HaveCount 3
        foreach ($node in $projectionNodes) { @($aggregate.Node.DependsOn) | Should -Contain ([string]$node.Id) }
        $projectionWave = @($integration.Plan.ExecutionWaves | Where-Object { @($_.NodeIds | Where-Object { $_ -like 'package-projection:*' }).Count -gt 0 })[0]
        @($projectionWave.ParallelNodeIds | Where-Object { $_ -like 'package-projection:*' }) | Should -HaveCount 3
    }

    It 'expands project-cache repairs into parallel link nodes with one registry commit barrier' {
        Mock Get-CapsulenvRelocationContext { [pscustomobject]@{ HasPathChanges = $false } } -ModuleName Capsulenv
        Mock Get-CapsulenvToolRelocationConfiguration { [pscustomobject]@{ Enabled = $false; AutoRepair = $false } } -ModuleName Capsulenv
        Mock Get-CapsulenvPackageProjectionRepairDescriptors { @() } -ModuleName Capsulenv
        Mock Get-CapsulenvProjectCacheRepairDescriptorSet {
            [pscustomobject]@{
                Records=@(
                    [pscustomobject]@{ Profile='uv'; ProjectScope='Absolute'; ProjectReference='X:\dev\a'; LinkType='Junction'; LastLinkPath='X:\dev\a\.venv'; LastStorePath='X:\cap\cache\a' },
                    [pscustomobject]@{ Profile='npm'; ProjectScope='Absolute'; ProjectReference='X:\dev\b'; LinkType='Junction'; LastLinkPath='X:\dev\b\node_modules'; LastStorePath='X:\cap\cache\b' }
                ); RegistryError=$null
            }
        } -ModuleName Capsulenv

        $integration = & $script:Module { Get-CapsulenvIntegrationDesiredStatePlan -IntegrationMode ShellOnly -RehydrationRequired $true }
        $linkNodes = @($integration.Plan.Nodes | Where-Object { $_.Id -like 'project-cache-link:*' })
        $linkNodes | Should -HaveCount 2
        @($linkNodes | Where-Object { $_.Node.ExecutionAffinity -ne 'AnyRunspace' -or $_.Node.ConcurrencyPolicy -ne 'ResourceBound' }) | Should -HaveCount 0
        @($linkNodes | ForEach-Object { @($_.Node.WriteResources) } | Select-Object -Unique) | Should -HaveCount 2
        $barrier = @($integration.Plan.Nodes | Where-Object Id -eq 'project-cache-links')[0]
        [bool]$barrier.Node.ParallelSafe | Should -BeFalse
        @($barrier.Node.WriteResources) | Should -Be @('capsule:///project-cache/registry')
        @($barrier.Node.DependsOn) | Should -HaveCount 2
        foreach ($node in $linkNodes) { @($barrier.Node.DependsOn) | Should -Contain ([string]$node.Id) }
    }

    It 'commits the project-cache registry only once after parallel repair results are gathered' {
        Mock Write-CapsulenvProjectCacheRegistry {} -ModuleName Capsulenv
        $repairs = @(
            [pscustomobject]@{ UpdatedRecord=[pscustomobject]@{ Profile='uv' }; RegistryChanged=$true; Result=[pscustomobject]@{ Status='Ready' } },
            [pscustomobject]@{ UpdatedRecord=[pscustomobject]@{ Profile='npm' }; RegistryChanged=$false; Result=[pscustomobject]@{ Status='Ready' } }
        )

        $results = & $script:Module { param($Repairs) @(Complete-CapsulenvProjectCacheRepairBatch -Repairs $Repairs) } $repairs
        $results | Should -HaveCount 2
        Should -Invoke Write-CapsulenvProjectCacheRegistry -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            @($Records).Count -eq 2
        }
    }

    It 'uses the same desired-state graph for steady activation without relocation-only mutations' {
        Mock Get-CapsulenvRelocationContext { [pscustomobject]@{ HasPathChanges = $false } } -ModuleName Capsulenv
        Mock Get-CapsulenvToolRelocationConfiguration { [pscustomobject]@{ Enabled = $false; AutoRepair = $false } } -ModuleName Capsulenv
        Mock Get-CapsulenvPackageProjectionRepairDescriptors { @() } -ModuleName Capsulenv
        Mock Get-CapsulenvProjectCacheRepairDescriptorSet { [pscustomobject]@{ Records=@(); RegistryError=$null } } -ModuleName Capsulenv

        $integration = & $script:Module {
            Get-CapsulenvIntegrationDesiredStatePlan -IntegrationMode ShellOnly -RehydrationRequired $false
        }
        $operations = @{}
        foreach ($decision in @($integration.Plan.Nodes)) { $operations[[string]$decision.Id] = [string]$decision.Operation }

        $operations['session-environment'] | Should -Be 'Apply'
        $operations['package-projections'] | Should -Be 'NoOp'
        $operations['project-cache-links'] | Should -Be 'NoOp'
        $operations['user-environment-backup'] | Should -Be 'NoOp'
        $operations['package-host-integration'] | Should -Be 'NoOp'
        $operations['persist-relocation'] | Should -Be 'NoOp'
        $operations['tool-relocation'] | Should -Be 'NoOp'
        $operations['user-integration'] | Should -Be 'NoOp'
        $operations['rehydration-state'] | Should -Be 'NoOp'
        Should -Invoke Get-CapsulenvPackageProjectionRepairDescriptors -ModuleName Capsulenv -Times 0 -Exactly
        Should -Invoke Get-CapsulenvProjectCacheRepairDescriptorSet -ModuleName Capsulenv -Times 0 -Exactly
    }

    It 'keeps User host projection repair off the steady activation path' {
        Mock Get-CapsulenvRelocationContext { [pscustomobject]@{ HasPathChanges = $false } } -ModuleName Capsulenv
        Mock Get-CapsulenvToolRelocationConfiguration { [pscustomobject]@{ Enabled = $false; AutoRepair = $false } } -ModuleName Capsulenv
        Mock Get-CapsulenvPackageProjectionRepairDescriptors { throw 'steady activation must not enumerate package projections' } -ModuleName Capsulenv
        Mock Get-CapsulenvProjectCacheRepairDescriptorSet { throw 'steady activation must not enumerate project-cache repairs' } -ModuleName Capsulenv

        $integration = & $script:Module {
            Get-CapsulenvIntegrationDesiredStatePlan -IntegrationMode User -RehydrationRequired $false
        }
        $operations = @{}
        foreach ($decision in @($integration.Plan.Nodes)) { $operations[[string]$decision.Id] = [string]$decision.Operation }
        $operations['package-host-integration'] | Should -Be 'NoOp'
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
