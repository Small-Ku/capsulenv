Describe 'Capsulenv test harness isolation' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:Pwsh = [string](Get-Process -Id $PID).Path
        . (Join-Path (Join-Path $script:Root 'scripts') 'Capsulenv.TestHarness.ps1')
    }

    It 'routes implicit module builds through the per-suite build root' {
        $buildRoot = Join-Path $TestDrive 'isolated-build'
        $oldBuildRoot = $env:CAPSULENV_BUILD_ROOT
        try {
            $env:CAPSULENV_BUILD_ROOT = $buildRoot
            $build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
            [System.IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $build.ModulePath))) |
                Should -Be ([System.IO.Path]::GetFullPath($buildRoot))
            Test-Path -LiteralPath (Join-Path $buildRoot 'Capsulenv/Capsulenv.psm1') -PathType Leaf |
                Should -BeTrue
        } finally {
            $env:CAPSULENV_BUILD_ROOT = $oldBuildRoot
        }
    }

    It 'always writes a structured result for suite infrastructure failures' {
        $runner = Join-Path (Join-Path $script:Root 'scripts') 'Invoke-CapsulenvPesterSuite.ps1'
        $resultPath = Join-Path $TestDrive 'infrastructure-result.json'
        $oldSuite = $env:CAPSULENV_TEST_SUITE_PATH
        $oldResult = $env:CAPSULENV_TEST_SUITE_RESULT_PATH
        try {
            $env:CAPSULENV_TEST_SUITE_PATH = Join-Path $TestDrive 'missing.Tests.ps1'
            $env:CAPSULENV_TEST_SUITE_RESULT_PATH = $resultPath
            & $script:Pwsh -NoProfile -NonInteractive -File $runner
            $LASTEXITCODE | Should -Be 1
            Test-Path -LiteralPath $resultPath -PathType Leaf | Should -BeTrue
            $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            $result.InfrastructureFailed | Should -Be 1
            [string]$result.InfrastructureError | Should -Match 'does not identify a Pester suite'
        } finally {
            $env:CAPSULENV_TEST_SUITE_PATH = $oldSuite
            $env:CAPSULENV_TEST_SUITE_RESULT_PATH = $oldResult
        }
    }

    It 'selects explicit fast and concurrency suite contracts' {
        $paths = @(
            'Z:\tests\ArchitectureAnalysis.Tests.ps1',
            'Z:\tests\DesiredState.Tests.ps1',
            'Z:\tests\Diagnostics.Tests.ps1',
            'Z:\tests\PackageExecutor.Tests.ps1',
            'Z:\tests\ProjectCacheLifecycle.Tests.ps1',
            'Z:\tests\ScoopReset.Tests.ps1',
            'Z:\tests\Static.Tests.ps1',
            'Z:\tests\TestHarness.Tests.ps1',
            'Z:\tests\ToolRelocation.Tests.ps1',
            'Z:\tests\Other.Tests.ps1'
        )

        $fast = @(Select-CapsulenvTestPaths -AllTestPaths $paths -Profile Fast)
        @($fast | ForEach-Object { Split-Path -Leaf $_ }) | Should -Be @(
            'ArchitectureAnalysis.Tests.ps1',
            'DesiredState.Tests.ps1',
            'Diagnostics.Tests.ps1',
            'PackageExecutor.Tests.ps1',
            'ProjectCacheLifecycle.Tests.ps1',
            'ScoopReset.Tests.ps1',
            'Static.Tests.ps1',
            'TestHarness.Tests.ps1'
        )

        $concurrency = @(Select-CapsulenvTestPaths -AllTestPaths $paths -Profile Concurrency)
        @($concurrency | ForEach-Object { Split-Path -Leaf $_ }) | Should -Be @(
            'DesiredState.Tests.ps1',
            'PackageExecutor.Tests.ps1',
            'ScoopReset.Tests.ps1',
            'ToolRelocation.Tests.ps1',
            'TestHarness.Tests.ps1'
        )
    }

    It 'builds deterministic repeated concurrency case plans' {
        $paths = @(
            'Z:\tests\DesiredState.Tests.ps1',
            'Z:\tests\PackageExecutor.Tests.ps1'
        )
        $cases = @(New-CapsulenvTestCasePlan -TestPaths $paths -Repeat 3)
        $cases.Count | Should -Be 6
        @($cases.RepeatIndex) | Should -Be @(1, 1, 2, 2, 3, 3)
        @($cases.SuiteName) | Should -Be @(
            'DesiredState.Tests.ps1',
            'PackageExecutor.Tests.ps1',
            'DesiredState.Tests.ps1',
            'PackageExecutor.Tests.ps1',
            'DesiredState.Tests.ps1',
            'PackageExecutor.Tests.ps1'
        )
        @($cases.Index) | Should -Be @(0, 1, 2, 3, 4, 5)
    }

    It 'fails closed when a named profile suite disappears' {
        {
            Select-CapsulenvTestPaths -AllTestPaths @('Z:\tests\DesiredState.Tests.ps1') -Profile Concurrency
        } | Should -Throw "*references missing suite(s)*"
    }

    It 'models isolated suites as a fan-out DAG with a terminal barrier' {
        $cases = @(New-CapsulenvTestCasePlan -TestPaths @(
            'Z:\tests\Alpha.Tests.ps1',
            'Z:\tests\Beta.Tests.ps1'
        ) -Repeat 1)
        $plan = New-CapsulenvTestExecutionPlan -Cases $cases

        @($plan.Nodes) | Should -HaveCount 3
        @($plan.Nodes | Where-Object Kind -eq 'Suite') | Should -HaveCount 2
        $barrier = @($plan.Nodes | Where-Object Id -eq $plan.TerminalId)[0]
        $barrier.Kind | Should -Be 'Barrier'
        @($barrier.DependsOn) | Should -Be @($plan.Nodes | Where-Object Kind -eq 'Suite' | ForEach-Object { [string]$_.Id })
    }

    It 'publishes the terminal test barrier only after every suite node completes' {
        $cases = @(New-CapsulenvTestCasePlan -TestPaths @(
            'Z:\tests\Alpha.Tests.ps1',
            'Z:\tests\Beta.Tests.ps1'
        ) -Repeat 1)
        $plan = New-CapsulenvTestExecutionPlan -Cases $cases
        $state = New-CapsulenvTestDagState -Nodes $plan.Nodes
        @($state.ReadyIndexes) | Should -HaveCount 2

        $suiteNodes = @($plan.Nodes | Where-Object Kind -eq 'Suite')
        Complete-CapsulenvTestDagNode -State $state -NodeId ([string]$suiteNodes[0].Id)
        @($state.ReadyIndexes | ForEach-Object { [string]$plan.Nodes[[int]$_].Id }) | Should -Not -Contain $plan.TerminalId

        Complete-CapsulenvTestDagNode -State $state -NodeId ([string]$suiteNodes[1].Id)
        @($state.ReadyIndexes | ForEach-Object { [string]$plan.Nodes[[int]$_].Id }) | Should -Contain $plan.TerminalId
    }

    It 'fails closed for missing test DAG dependencies and duplicate completion' {
        {
            New-CapsulenvTestDagState -Nodes @(
                [pscustomobject]@{ Id='a'; DependsOn=@('missing') }
            )
        } | Should -Throw '*depends on missing node*'

        $state = New-CapsulenvTestDagState -Nodes @(
            [pscustomobject]@{ Id='a'; DependsOn=@() }
        )
        Complete-CapsulenvTestDagNode -State $state -NodeId 'a'
        { Complete-CapsulenvTestDagNode -State $state -NodeId 'a' } | Should -Throw '*completed more than once*'
    }

}
