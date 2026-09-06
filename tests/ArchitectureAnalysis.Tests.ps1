Describe 'Capsulenv architecture static analysis' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        . (Join-Path (Join-Path $script:Root 'scripts') 'Capsulenv.StaticAnalysis.ps1')

        function New-CapsulenvStaticFixture {
            param(
                [Parameter(Mandatory = $true)][string]$Name,
                [Parameter(Mandatory = $true)][string]$Source
            )

            $path = Join-Path $TestDrive $Name
            [System.IO.File]::WriteAllText($path, $Source)
            return $path
        }
    }

    It 'rejects foreign Scoop Start Menu namespace literals in runtime code' {
        $fixture = New-CapsulenvStaticFixture -Name 'foreign-startmenu.ps1' -Source @'
function Invoke-BadShortcutTarget {
    return [System.IO.Path]::Combine('C:\Users\test', 'Programs', 'Scoop Apps')
}
'@
        $violations = @(Get-CapsulenvHostIntegrationOwnershipViolations -Paths @($fixture))
        $violations.Count | Should -Be 1
        $violations[0].Rule | Should -Be 'HostStartMenuNamespace'
    }

    It 'rejects every Scoop shortcut_folder override' {
        $fixture = New-CapsulenvStaticFixture -Name 'shortcut-override.ps1' -Source @'
function shortcut_folder($global) {
    return [System.IO.Path]::Combine('Programs', 'Capsulenv Apps')
}
'@
        $violations = @(Get-CapsulenvHostIntegrationOwnershipViolations -Paths @($fixture))
        $violations.Count | Should -Be 1
        $violations[0].Rule | Should -Be 'ScoopShortcutOverrideForbidden'
    }


    It 'rejects sing-box or rclone runtime specializations' {
        $fixture = New-CapsulenvStaticFixture -Name 'workload-specialization.ps1' -Source @'
function Connect-CapsulenvSingBox {
    $config = Get-CapsulenvConfiguration
    return $config.SingBox
}
'@
        $violations = @(Get-CapsulenvWorkloadSpecializationViolations -Paths @($fixture))
        @($violations.Rule) | Should -Contain 'NoWorkloadSpecializedRuntime'
        @($violations.Rule) | Should -Contain 'NoWorkloadSpecializedConfiguration'
    }

    It 'accepts generic lifecycle routine runtime code' {
        $fixture = New-CapsulenvStaticFixture -Name 'generic-routine.ps1' -Source @'
function Invoke-CapsulenvRoutine {
    $config = Get-CapsulenvConfiguration
    return $config.Routines
}
'@
        @(Get-CapsulenvWorkloadSpecializationViolations -Paths @($fixture)).Count | Should -Be 0
    }

    It 'rejects Scoop runtime source adapters by filename' {
        $runtimeRoot = Join-Path $TestDrive 'runtime-adapters'
        [void](New-Item -ItemType Directory -Path $runtimeRoot -Force)
        Set-Content -LiteralPath (Join-Path $runtimeRoot 'scoop-capsulenv-transform.ps1') -Value '# forbidden'
        $violations = @(Get-CapsulenvScoopRuntimeAdapterViolations -RuntimeRoot $runtimeRoot)
        $violations.Count | Should -Be 1
        $violations[0].Rule | Should -Be 'NoScoopRuntimeAdapters'
    }

    It 'accepts a runtime directory with no Scoop source adapters' {
        $runtimeRoot = Join-Path $TestDrive 'runtime-clean'
        [void](New-Item -ItemType Directory -Path $runtimeRoot -Force)
        Set-Content -LiteralPath (Join-Path $runtimeRoot 'Invoke-Capsulenv.ps1') -Value 'param()'
        @(Get-CapsulenvScoopRuntimeAdapterViolations -RuntimeRoot $runtimeRoot).Count | Should -Be 0
    }

    It 'rejects persistent ownership reads from the session mode resolver' {
        $fixture = New-CapsulenvStaticFixture -Name 'mode-persistent.ps1' -Source @'
function Get-CapsulenvInstallMode {
    if ([string]$env:CAPSULENV_MODE -eq 'User') {
        return 'User'
    }
    if (Test-CapsulenvCurrentUserIntegrationOwnership) {
        return 'User'
    }
    return 'ShellOnly'
}
'@
        $violations = @(Get-CapsulenvSessionModeBoundaryViolations -Path $fixture)
        $violations.Count | Should -Be 1
        $violations[0].Rule | Should -Be 'SessionModeCommandDependency'
    }

    It 'accepts invocation-scoped CAPSULENV_MODE as the session selector' {
        $fixture = New-CapsulenvStaticFixture -Name 'mode-process.ps1' -Source @'
function Get-CapsulenvInstallMode {
    if ([string]$env:CAPSULENV_MODE -eq 'User') {
        return 'User'
    }
    return 'ShellOnly'
}
'@
        @(Get-CapsulenvSessionModeBoundaryViolations -Path $fixture).Count | Should -Be 0
    }

    It 'rejects direct member access on declared external JSON record variables' {
        $fixture = New-CapsulenvStaticFixture -Name 'external-json-unsafe.ps1' -Source @'
function Get-CapsulenvUvManagedPythonInstallations {
    foreach ($item in @()) {
        $key = $item.key
    }
}
'@
        $violations = @(
            Get-CapsulenvExternalJsonMemberViolations `
                -Path $fixture `
                -FunctionName 'Get-CapsulenvUvManagedPythonInstallations' `
                -RecordVariables @('item')
        )
        $violations.Count | Should -Be 1
        $violations[0].Rule | Should -Be 'ExternalJsonSafePropertyAccess'
    }

    It 'accepts the safe property accessor for external JSON records' {
        $fixture = New-CapsulenvStaticFixture -Name 'external-json-safe.ps1' -Source @'
function Get-CapsulenvUvManagedPythonInstallations {
    foreach ($item in @()) {
        $key = Get-CapsulenvObjectPropertyValue -InputObject $item -Name 'key'
    }
}
'@
        @(
            Get-CapsulenvExternalJsonMemberViolations `
                -Path $fixture `
                -FunctionName 'Get-CapsulenvUvManagedPythonInstallations' `
                -RecordVariables @('item')
        ).Count | Should -Be 0
    }

    It 'rejects a Scoop shim that routes direct commands through a Capsulenv gateway' {
        $fixture = New-CapsulenvStaticFixture -Name 'gateway-shim.ps1' -Source @'
function Install-CapsulenvScoopShim {
    $path = Get-CapsulenvModuleRuntimePath -Name 'scoop-capsulenv-gateway.ps1'
    $ps1Text = '$PSScriptRoot'
    $cmdText = '%~dp0'
}
'@
        $violations = @(Get-CapsulenvStockScoopBoundaryViolations -Path $fixture)
        @($violations.Rule) | Should -Contain 'StockScoopNoGateway'
        @($violations.Rule) | Should -Contain 'StockScoopNoRuntimeTransform'
    }

    It 'accepts a cmd-only trampoline while PowerShell resolves upstream Scoop directly from PATH' {
        $fixture = New-CapsulenvStaticFixture -Name 'stock-shim.ps1' -Source @'
function Install-CapsulenvScoopShim {
    $cmdText = @"
set "UPSTREAM=%~dp0..\apps\scoop\current\bin\scoop.ps1"
"@
}
'@
        @(Get-CapsulenvStockScoopBoundaryViolations -Path $fixture).Count | Should -Be 0
    }

    It 'rejects explicit null passed to a mandatory local function parameter without AllowNull' {
        $fixture = New-CapsulenvStaticFixture -Name 'mandatory-null.ps1' -Source @'
function Invoke-Target {
    param([Parameter(Mandatory = $true)][string]$Name)
}
Invoke-Target -Name $null
'@
        $violations = @(Get-CapsulenvMandatoryParameterBindingViolations -Paths @($fixture))
        $violations.Count | Should -Be 1
        $violations[0].Rule | Should -Be 'MandatoryParameterExplicitEmptyValue'
    }

    It 'accepts explicit null when the mandatory local function parameter allows null' {
        $fixture = New-CapsulenvStaticFixture -Name 'mandatory-null-allowed.ps1' -Source @'
function Invoke-Target {
    param([AllowNull()][Parameter(Mandatory = $true)][string]$Name)
}
Invoke-Target -Name $null
'@
        @(Get-CapsulenvMandatoryParameterBindingViolations -Paths @($fixture)).Count | Should -Be 0
    }

    It 'rejects unparenthesized desired-state node constructors inside array subexpressions' {
        $fixture = New-CapsulenvStaticFixture -Name 'desired-state-binding-unsafe.ps1' -Source @'
$nodes = @(
    New-CapsulenvDesiredStateNode -Id a -Plan { 1 } -Apply { 2 } -Verify { 3 }
    New-CapsulenvDesiredStateNode -Id b -Plan { 1 } -Apply { 2 } -Verify { 3 }
)
'@
        $violations = @(Get-CapsulenvDesiredStateNodeBindingBoundaryViolations -Paths @($fixture))
        $violations.Count | Should -Be 2
        @($violations.Rule | Select-Object -Unique) | Should -Be @('DesiredStateNodeScriptBlockBoundary')
    }

    It 'accepts explicit desired-state node expression boundaries inside array subexpressions' {
        $fixture = New-CapsulenvStaticFixture -Name 'desired-state-binding-safe.ps1' -Source @'
$nodes = @(
    (New-CapsulenvDesiredStateNode -Id a -Plan { 1 } -Apply { 2 } -Verify { 3 })
    (New-CapsulenvDesiredStateNode -Id b -Plan { 1 } -Apply { 2 } -Verify { 3 })
)
'@
        @(Get-CapsulenvDesiredStateNodeBindingBoundaryViolations -Paths @($fixture)).Count | Should -Be 0
    }

    It 'rejects PowerShell array += inside a loop when the variable is known to be an array' {
        $fixture = New-CapsulenvStaticFixture -Name 'loop-array-append.ps1' -Source @'
$items = @()
foreach ($item in 1..3) {
    $items += $item
}
'@
        $violations = @(Get-CapsulenvLoopArrayAppendViolations -Paths @($fixture))
        $violations.Count | Should -Be 1
        $violations[0].Rule | Should -Be 'LoopArrayAppend'
    }

    It 'accepts List[T].Add inside a loop' {
        $fixture = New-CapsulenvStaticFixture -Name 'loop-list-add.ps1' -Source @'
$items = New-Object System.Collections.Generic.List[object]
foreach ($item in 1..3) {
    $items.Add($item)
}
'@
        @(Get-CapsulenvLoopArrayAppendViolations -Paths @($fixture)).Count | Should -Be 0
    }


    It 'rejects desired-state nodes with implicit execution or resource contracts' {
        $fixture = New-CapsulenvStaticFixture -Name 'desired-state-contract-implicit.ps1' -Source @'
(New-CapsulenvDesiredStateNode -Id demo -Plan { 1 } -Apply { 2 } -Verify { 3 })
'@
        $violations = @(Get-CapsulenvDesiredStateNodeContractViolations -Paths @($fixture))
        @($violations.Rule) | Should -Contain 'DesiredStateExecutionAffinityRequired'
        @($violations.Rule) | Should -Contain 'DesiredStateConcurrencyPolicyRequired'
        @($violations.Rule) | Should -Contain 'DesiredStateReadResourcesRequired'
        @($violations.Rule) | Should -Contain 'DesiredStateWriteResourcesRequired'
    }

    It 'rejects the legacy ParallelSafe shorthand in desired-state declarations' {
        $fixture = New-CapsulenvStaticFixture -Name 'desired-state-contract-legacy.ps1' -Source @'
(New-CapsulenvDesiredStateNode -Id demo -ParallelSafe -ReadResources @() -WriteResources @() -Plan { 1 } -Apply { 2 } -Verify { 3 })
'@
        $violations = @(Get-CapsulenvDesiredStateNodeContractViolations -Paths @($fixture))
        @($violations.Rule) | Should -Contain 'DesiredStateLegacyParallelSafeUsage'
    }

    It 'rejects Auto or claim-free ResourceBound runtime node contracts' {
        $fixture = New-CapsulenvStaticFixture -Name 'desired-state-contract-auto-empty.ps1' -Source @'
(New-CapsulenvDesiredStateNode -Id auto -ExecutionAffinity MainRunspace -ConcurrencyPolicy Auto -ReadResources @() -WriteResources @() -Plan { 1 } -Apply { 2 } -Verify { 3 })
(New-CapsulenvDesiredStateNode -Id empty -ExecutionAffinity MainRunspace -ConcurrencyPolicy ResourceBound -ReadResources @() -WriteResources @() -Plan { 1 } -Apply { 2 } -Verify { 3 })
'@
        $violations = @(Get-CapsulenvDesiredStateNodeContractViolations -Paths @($fixture))
        @($violations.Rule) | Should -Contain 'DesiredStateAutoConcurrencyForbidden'
        @($violations.Rule) | Should -Contain 'DesiredStateResourceBoundClaimsRequired'
    }

    It 'rejects AnyRunspace nodes with exclusive or process-scoped contracts' {
        $fixture = New-CapsulenvStaticFixture -Name 'desired-state-worker-contract-bad.ps1' -Source @'
(New-CapsulenvDesiredStateNode -Id exclusive -ExecutionAffinity AnyRunspace -ConcurrencyPolicy Exclusive -ReadResources @() -WriteResources @() -Plan { 1 } -Apply { 2 } -Verify { 3 })
(New-CapsulenvDesiredStateNode -Id process -ExecutionAffinity AnyRunspace -ConcurrencyPolicy ResourceBound -ReadResources @() -WriteResources @('process:///environment') -Plan { 1 } -Apply { 2 } -Verify { 3 })
'@
        $violations = @(Get-CapsulenvDesiredStateNodeContractViolations -Paths @($fixture))
        @($violations.Rule) | Should -Contain 'DesiredStateAnyRunspaceMustBeResourceBound'
        @($violations.Rule) | Should -Contain 'DesiredStateWorkerProcessResourceClaim'
    }

    It 'requires literal desired-state callbacks' {
        $fixture = New-CapsulenvStaticFixture -Name 'desired-state-callback-variable.ps1' -Source @'
$apply = { 2 }
(New-CapsulenvDesiredStateNode -Id demo -ExecutionAffinity MainRunspace -ConcurrencyPolicy ResourceBound -ReadResources @() -WriteResources @() -Plan { 1 } -Apply $apply -Verify { 3 })
'@
        $violations = @(Get-CapsulenvDesiredStateNodeContractViolations -Paths @($fixture))
        @($violations.Rule) | Should -Contain 'DesiredStateCallbackLiteralRequired'
    }

    It 'rejects process-global mutations inside AnyRunspace callbacks' {
        $fixture = New-CapsulenvStaticFixture -Name 'desired-state-worker-global.ps1' -Source @'
(New-CapsulenvDesiredStateNode -Id demo -ExecutionAffinity AnyRunspace -ConcurrencyPolicy ResourceBound -ReadResources @() -WriteResources @('capsule:///demo') -Plan { 1 } -Apply {
    $env:DEMO = 'bad'
    Set-Location C:\
    [Environment]::SetEnvironmentVariable('DEMO', 'bad', 'Process')
} -Verify { $true })
'@
        $violations = @(Get-CapsulenvDesiredStateNodeContractViolations -Paths @($fixture))
        @($violations.Rule | Where-Object { $_ -eq 'DesiredStateWorkerProcessGlobalMutation' }).Count |
            Should -BeGreaterOrEqual 3
    }

    It 'accepts a fully explicit resource-bound worker node with child-local effects' {
        $fixture = New-CapsulenvStaticFixture -Name 'desired-state-worker-safe.ps1' -Source @'
(New-CapsulenvDesiredStateNode -Id demo -ExecutionAffinity AnyRunspace -ConcurrencyPolicy ResourceBound -ReadResources @('capsule:///input') -WriteResources @('capsule:///output') -Plan { 1 } -Apply {
    Invoke-CapsulenvNativeTool -Executable demo.exe -Arguments @('--check')
} -Verify { $true })
'@
        @(Get-CapsulenvDesiredStateNodeContractViolations -Paths @($fixture)).Count | Should -Be 0
    }

    It 'rejects wave-barrier scheduler regressions and legacy batch executors' {
        $fixture = New-CapsulenvStaticFixture -Name 'scheduler-wave-regression.ps1' -Source @'
function Invoke-CapsulenvDesiredStateParallelBatch { }
function Invoke-CapsulenvDesiredStatePlan {
    param($Plan)
    foreach ($wave in $Plan.ExecutionWaves) {
        $wave
    }
}
'@
        $violations = @(Get-CapsulenvDesiredStateSchedulerBoundaryViolations -Path $fixture)
        @($violations.Rule) | Should -Contain 'DesiredStateDynamicReadyQueueRequired'
        @($violations.Rule) | Should -Contain 'DesiredStateRuntimeWaveBarrierForbidden'
        @($violations.Rule) | Should -Contain 'DesiredStateLegacyWaveBatchHelperForbidden'
    }

    It 'accepts the authoritative dynamic ready-queue scheduler boundary' {
        $core = Join-Path (Join-Path $script:Root 'src') '01-DesiredStateCore.ps1'
        @(Get-CapsulenvDesiredStateSchedulerBoundaryViolations -Path $core).Count | Should -Be 0
    }

    It 'rejects PortableSafe package-node execution outside the DAG Apply boundary' {
        $outside = New-CapsulenvStaticFixture -Name 'package-direct.ps1' -Source @'
function Invoke-BadInstall {
    Install-CapsulenvPortablePackageNode -Plan $plan
}
'@
        $violations = @(Get-CapsulenvPortablePackageExecutionBoundaryViolations -Paths @($outside))
        @($violations.Rule) | Should -Contain 'PortablePackageDirectExecutorForbidden'

        $insideFile = New-CapsulenvStaticFixture -Name '45-PackageExecutionGraph.ps1' -Source @'
function Invoke-StillBad {
    Install-CapsulenvPortablePackageNode -Plan $plan
}
'@
        $insideViolations = @(Get-CapsulenvPortablePackageExecutionBoundaryViolations -Paths @($insideFile))
        @($insideViolations.Rule) | Should -Contain 'PortablePackageExecutorMustBeDagApply'
    }

    It 'accepts PortableSafe package-node execution from a desired-state Apply callback' {
        $fixture = New-CapsulenvStaticFixture -Name '45-PackageExecutionGraph.ps1' -Source @'
(New-CapsulenvDesiredStateNode -Id package -ExecutionAffinity AnyRunspace -ConcurrencyPolicy ResourceBound -ReadResources @('capsule:///source') -WriteResources @('capsule:///package') -Plan { 1 } -Apply {
    Install-CapsulenvPortablePackageNode -Plan $plan
} -Verify { $true })
'@
        @(Get-CapsulenvPortablePackageExecutionBoundaryViolations -Paths @($fixture)).Count | Should -Be 0
    }

    It 'keeps the canonical test runner child-environment isolated' {
        $runner = Join-Path (Join-Path $script:Root 'scripts') 'Test-Capsulenv.ps1'
        @(Get-CapsulenvTestHarnessIsolationViolations -Path $runner).Count | Should -Be 0
    }

    It 'requires a dedicated child artifact root in the canonical test runner' {
        $runner = Join-Path (Join-Path $script:Root 'scripts') 'Test-Capsulenv.ps1'
        $source = [System.IO.File]::ReadAllText($runner)
        $fixture = New-CapsulenvStaticFixture -Name 'Test-Capsulenv.ps1' -Source (
            $source -replace '(?m)^.*CAPSULENV_TEST_ARTIFACT_ROOT.*\r?\n?', ''
        )
        $violations = @(Get-CapsulenvTestHarnessIsolationViolations -Path $fixture)
        @($violations.Rule) | Should -Contain 'TestHarnessChildIsolationVariableRequired'
        ($violations.Detail -join "`n") | Should -Match 'CAPSULENV_TEST_ARTIFACT_ROOT'
    }

    It 'requires the canonical runner to execute its bound analyzer' {
        $fixture = New-CapsulenvStaticFixture -Name 'test-runner-analyzer-not-executed.ps1' -Source @'
$analysisScript = Join-Path $PSScriptRoot 'Analyze-Capsulenv.ps1'
$pester = Get-Module Pester -ListAvailable
Select-CapsulenvTestPaths -AllTestPaths @() -Profile Full
'@
        $violations = @(Get-CapsulenvTestHarnessIsolationViolations -Path $fixture)
        @($violations.Rule) | Should -Contain 'TestHarnessStaticAnalysisExecutionRequired'
    }

    It 'requires canonical static analysis before Pester planning' {
        $fixture = New-CapsulenvStaticFixture -Name 'test-runner-analyzer-too-late.ps1' -Source @'
$analysisScript = Join-Path $PSScriptRoot 'Analyze-Capsulenv.ps1'
$pester = Get-Module Pester -ListAvailable
Select-CapsulenvTestPaths -AllTestPaths @() -Profile Full
& $analysisScript
'@
        $violations = @(Get-CapsulenvTestHarnessIsolationViolations -Path $fixture)
        @($violations.Rule) | Should -Contain 'TestHarnessStaticAnalysisOrder'
    }

    It 'requires canonical static analysis to execute unconditionally at script scope' {
        $fixture = New-CapsulenvStaticFixture -Name 'test-runner-analyzer-conditional.ps1' -Source @'
$analysisScript = Join-Path $PSScriptRoot 'Analyze-Capsulenv.ps1'
if ($true) {
    & $analysisScript
}
$pester = Get-Module Pester -ListAvailable
'@
        $violations = @(Get-CapsulenvTestHarnessIsolationViolations -Path $fixture)
        @($violations.Rule) | Should -Contain 'TestHarnessStaticAnalysisMustBeUnconditional'
    }

    It 'rejects process-global mutations reached through nested AnyRunspace helpers' {
        $fixture = New-CapsulenvStaticFixture -Name 'desired-state-worker-reachable-global.ps1' -Source @'
function Invoke-CapsulenvWorkerLeaf {
    $env:DEMO = 'bad'
}
function Invoke-CapsulenvWorkerMiddle {
    Invoke-CapsulenvWorkerLeaf
}
(New-CapsulenvDesiredStateNode -Id demo -ExecutionAffinity AnyRunspace -ConcurrencyPolicy ResourceBound -ReadResources @('capsule:///input') -WriteResources @('capsule:///output') -Plan { 1 } -Apply {
    Invoke-CapsulenvWorkerMiddle
} -Verify { $true })
'@
        $violations = @(Get-CapsulenvDesiredStateWorkerReachabilityViolations -Paths @($fixture))
        @($violations.Rule) | Should -Contain 'DesiredStateWorkerReachableProcessMutation'
        @($violations.Detail -join "`n") | Should -Match 'Invoke-CapsulenvWorkerMiddle.*Invoke-CapsulenvWorkerLeaf'
    }

    It 'rejects Add-Type reached through an AnyRunspace helper' {
        $fixture = New-CapsulenvStaticFixture -Name 'desired-state-worker-reachable-add-type.ps1' -Source @'
function Initialize-CapsulenvWorkerType {
    Add-Type -TypeDefinition 'public static class DemoType {}'
}
(New-CapsulenvDesiredStateNode -Id demo -ExecutionAffinity AnyRunspace -ConcurrencyPolicy ResourceBound -ReadResources @('capsule:///input') -WriteResources @('capsule:///output') -Plan { 1 } -Apply {
    Initialize-CapsulenvWorkerType
} -Verify { $true })
'@
        $violations = @(Get-CapsulenvDesiredStateWorkerReachabilityViolations -Paths @($fixture))
        @($violations.Rule) | Should -Contain 'DesiredStateWorkerReachableProcessMutation'
    }

    It 'fails closed on unresolved Capsulenv helpers in AnyRunspace call graphs' {
        $fixture = New-CapsulenvStaticFixture -Name 'desired-state-worker-unresolved.ps1' -Source @'
(New-CapsulenvDesiredStateNode -Id demo -ExecutionAffinity AnyRunspace -ConcurrencyPolicy ResourceBound -ReadResources @('capsule:///input') -WriteResources @('capsule:///output') -Plan { 1 } -Apply {
    Invoke-CapsulenvMissingWorkerHelper
} -Verify { $true })
'@
        $violations = @(Get-CapsulenvDesiredStateWorkerReachabilityViolations -Paths @($fixture))
        @($violations.Rule) | Should -Contain 'DesiredStateWorkerUnresolvedCapsulenvCall'
    }

    It 'accepts a statically resolvable worker-safe helper chain' {
        $fixture = New-CapsulenvStaticFixture -Name 'desired-state-worker-reachable-safe.ps1' -Source @'
function Get-CapsulenvWorkerLeaf {
    Get-Item -LiteralPath .
}
function Invoke-CapsulenvWorkerMiddle {
    Get-CapsulenvWorkerLeaf
}
(New-CapsulenvDesiredStateNode -Id demo -ExecutionAffinity AnyRunspace -ConcurrencyPolicy ResourceBound -ReadResources @('capsule:///input') -WriteResources @('capsule:///output') -Plan { 1 } -Apply {
    Invoke-CapsulenvWorkerMiddle
} -Verify { $true })
'@
        @(Get-CapsulenvDesiredStateWorkerReachabilityViolations -Paths @($fixture)).Count | Should -Be 0
    }

    It 'requires worker runtime preflight before worker-dependent graph construction' {
        $integration = New-CapsulenvStaticFixture -Name 'integration-preflight-missing.ps1' -Source @'
function Get-CapsulenvIntegrationDesiredStatePlan {
    $descriptors = Get-CapsulenvPackageProjectionRepairDescriptors
    Initialize-CapsulenvFileIdentityRuntime
    New-CapsulenvDesiredStateNode
}
'@
        $packageGraph = New-CapsulenvStaticFixture -Name 'package-preflight-missing.ps1' -Source @'
function Get-CapsulenvPortablePackageDesiredStatePlan {
    New-CapsulenvDesiredStateNode
}
'@
        $violations = @(Get-CapsulenvDesiredStateWorkerPreflightViolations -IntegrationPath $integration -PackageGraphPath $packageGraph)
        @($violations.Rule) | Should -Contain 'DesiredStateWorkerParentPreflightOrder'
        @($violations.Rule) | Should -Contain 'DesiredStateWorkerParentPreflightRequired'
    }

    It 'accepts worker runtime preflight before graph construction' {
        $integration = New-CapsulenvStaticFixture -Name 'integration-preflight-good.ps1' -Source @'
function Get-CapsulenvIntegrationDesiredStatePlan {
    Initialize-CapsulenvFileIdentityRuntime
    $descriptors = Get-CapsulenvPackageProjectionRepairDescriptors
    New-CapsulenvDesiredStateNode
}
'@
        $packageGraph = New-CapsulenvStaticFixture -Name 'package-preflight-good.ps1' -Source @'
function Get-CapsulenvPortablePackageDesiredStatePlan {
    Initialize-CapsulenvPortablePackageWorkerRuntime
    New-CapsulenvDesiredStateNode
}
'@
        @(Get-CapsulenvDesiredStateWorkerPreflightViolations -IntegrationPath $integration -PackageGraphPath $packageGraph).Count | Should -Be 0
    }

    It 'accepts the repository AnyRunspace call graph and parent preflights' {
        $runtimePaths = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'src') -Filter '*.ps1' -File | Select-Object -ExpandProperty FullName)
        @(Get-CapsulenvDesiredStateWorkerReachabilityViolations -Paths $runtimePaths).Count | Should -Be 0
        @(Get-CapsulenvDesiredStateWorkerPreflightViolations `
            -IntegrationPath (Join-Path (Join-Path $script:Root 'src') '40-Scoop.ps1') `
            -PackageGraphPath (Join-Path (Join-Path $script:Root 'src') '45-PackageExecutionGraph.ps1')).Count | Should -Be 0
    }

    It 'rejects dynamic and dot-sourced execution reachable from AnyRunspace workers' {
        $fixture = New-CapsulenvStaticFixture -Name 'desired-state-worker-opaque-invoke.ps1' -Source @'
function Invoke-CapsulenvOpaqueWorker {
    $handler = 'tool.exe'
    & $handler
    . ./worker-extra.ps1
}
(New-CapsulenvDesiredStateNode -Id demo -ExecutionAffinity AnyRunspace -ConcurrencyPolicy ResourceBound -ReadResources @('capsule:///input') -WriteResources @('capsule:///output') -Plan { 1 } -Apply {
    Invoke-CapsulenvOpaqueWorker
} -Verify { $true })
'@
        $violations = @(Get-CapsulenvDesiredStateWorkerReachabilityViolations -Paths @($fixture))
        @($violations.Rule) | Should -Contain 'DesiredStateWorkerOpaqueDynamicInvocation'
    }

    It 'rejects opaque commands and detached async work reachable from AnyRunspace workers' {
        $fixture = New-CapsulenvStaticFixture -Name 'desired-state-worker-detached.ps1' -Source @'
function Invoke-CapsulenvDetachedWorker {
    Invoke-Expression '$x = 1'
    Start-Job { Get-Date } | Out-Null
    1..3 | ForEach-Object -Parallel { $_ }
    [System.Threading.ThreadPool]::QueueUserWorkItem({ param($state) $null }) | Out-Null
}
(New-CapsulenvDesiredStateNode -Id demo -ExecutionAffinity AnyRunspace -ConcurrencyPolicy ResourceBound -ReadResources @('capsule:///input') -WriteResources @('capsule:///output') -Plan { 1 } -Apply {
    Invoke-CapsulenvDetachedWorker
} -Verify { $true })
'@
        $violations = @(Get-CapsulenvDesiredStateWorkerReachabilityViolations -Paths @($fixture))
        @($violations.Rule) | Should -Contain 'DesiredStateWorkerOpaqueExecutionCommand'
        @($violations.Rule) | Should -Contain 'DesiredStateWorkerDetachedAsyncExecution'
    }


    It 'rejects runtime launchers that buffer dispatcher output or lose native exit status' {
        $fixture = New-CapsulenvStaticFixture -Name 'runtime-launcher-unsafe.ps1' -Source @'
Import-Module $modulePath -Force
$result = Invoke-Capsulenv @args
'@
        $violations = @(Get-CapsulenvRuntimeLauncherBoundaryViolations -Path $fixture)
        @($violations.Rule) | Should -Contain 'RuntimeLauncherDisableNameChecking'
        @($violations.Rule) | Should -Contain 'RuntimeLauncherNoDispatcherCapture'
        @($violations.Rule) | Should -Contain 'RuntimeLauncherExitCodePreservation'
    }

    It 'rejects lifecycle ownership in the deployment-only installer' {
        $fixture = New-CapsulenvStaticFixture -Name 'installer-lifecycle-unsafe.ps1' -Source @'
param(
    [ValidateSet('ShellOnly', 'User')][string]$Mode,
    [switch]$SkipScoopBootstrap
)
Import-Module ./Capsulenv.psd1
Initialize-CapsulenvScoopBootstrap
Set-CapsulenvInstallMode -Mode User
'@
        $violations = @(Get-CapsulenvInstallerLifecycleBoundaryViolations -Path $fixture)
        @($violations.Rule) | Should -Contain 'InstallerDeploymentOnlyCommand'
        @($violations.Rule) | Should -Contain 'InstallerDeploymentOnlyParameter'
        @($violations.Rule) | Should -Contain 'InstallerDeploymentOnlyModeSelector'
    }

    It 'rejects recursive persist relocation scans' {
        $fixture = New-CapsulenvStaticFixture -Name 'persist-recursive-scan.ps1' -Source @'
function Invoke-CapsulenvPersistRelocationRepair {
    Get-ChildItem -LiteralPath $PersistRoot -Recurse
}
'@
        $violations = @(Get-CapsulenvPersistRelocationScanViolations -Paths @($fixture))
        $violations.Count | Should -Be 1
        $violations[0].Rule | Should -Be 'PersistRelocationNoRecursiveScan'
    }

    It 'requires reparse-point inspection before hard-link identity checks' {
        $fixture = New-CapsulenvStaticFixture -Name 'project-cache-ordering.ps1' -Source @'
function Get-CapsulenvProjectLinkInfo {
    param($Plan)
    if (Test-CapsulenvHardLinkMatch -Left $Plan.LinkPath -Right $Plan.StorePath) { return $true }
    $target = Get-CapsulenvReparseTarget -Path $Plan.LinkPath
    return $false
}
'@
        $violations = @(Get-CapsulenvProjectCacheOrderingViolations -Path $fixture)
        $violations.Count | Should -Be 1
        $violations[0].Rule | Should -Be 'ProjectCacheReparseBeforeHardLink'
    }

    It 'requires precise Bitwarden state boundaries and rejects wholesale settings reserialization' {
        $fixture = New-CapsulenvStaticFixture -Name 'bitwarden-state-unsafe.ps1' -Source @'
function Set-CapsulenvBitwardenDesktopSshAgent {
    ConvertTo-Json -InputObject $state -Depth 100
}
function Restore-CapsulenvBitwardenDesktopSettings {
    return $json
}
'@
        $violations = @(Get-CapsulenvBitwardenStateBoundaryViolations -Path $fixture)
        @($violations.Rule) | Should -Contain 'BitwardenPreciseStateBoundary'
        @($violations.Rule) | Should -Contain 'BitwardenNoWholesaleJsonReserialization'
    }

    It 'accepts repository control-plane, relocation, project-cache, and Bitwarden AST boundaries' {
        @(Get-CapsulenvRuntimeLauncherBoundaryViolations -Path (Join-Path (Join-Path $script:Root 'module-runtime') 'Invoke-Capsulenv.ps1')).Count | Should -Be 0
        @(Get-CapsulenvInstallerLifecycleBoundaryViolations -Path (Join-Path (Join-Path $script:Root 'scripts') 'Install-Capsulenv.ps1')).Count | Should -Be 0
        @(Get-CapsulenvPersistRelocationScanViolations -Paths @(
            (Join-Path (Join-Path $script:Root 'src') '45-Relocation.ps1'),
            (Join-Path (Join-Path $script:Root 'src') '46-PersistRelocation.ps1')
        )).Count | Should -Be 0
        @(Get-CapsulenvProjectCacheOrderingViolations -Path (Join-Path (Join-Path $script:Root 'src') '35-ToolStorage.ps1')).Count | Should -Be 0
        @(Get-CapsulenvBitwardenStateBoundaryViolations -Path (Join-Path (Join-Path $script:Root 'src') '55-BitwardenSshAgent.ps1')).Count | Should -Be 0
    }


    It 'rejects ShellOnly/User ownership leaks across host-integration boundaries' {
        $environmentFixture = New-CapsulenvStaticFixture -Name 'mode-environment-unsafe.ps1' -Source @'
function Restore-CapsulenvUserEnvironment {
    Set-CapsulenvInstallMode -Mode ShellOnly
}
function Invoke-CapsulenvChildShell {
    Sync-CapsulenvConfiguredDefaultBrowser
}
'@
        $hostFixture = New-CapsulenvStaticFixture -Name 'mode-host-unsafe.ps1' -Source @'
function Sync-CapsulenvPackageStartMenuShortcuts {
    param([string]$IntegrationMode)
    New-Item -ItemType Directory -Path C:\HostUi
}
'@
        $bitwardenFixture = New-CapsulenvStaticFixture -Name 'mode-bitwarden-unsafe.ps1' -Source @'
function Disable-CapsulenvWindowsSshAgent {
    Set-Service -Name ssh-agent -StartupType Disabled
}
function Set-CapsulenvGitOpenSsh {
    & $git config --global --replace-all core.sshCommand ssh.exe
    if ($mode -eq 'ShellOnly') {
        Enable-CapsulenvGitOpenSshSession
        return
    }
}
'@
        $legacyFixture = New-CapsulenvStaticFixture -Name 'mode-legacy-unsafe.ps1' -Source @'
function Repair-CapsulenvInstalledAppProjections {
    param([string]$IntegrationMode)
    Sync-CapsulenvPackageStartMenuShortcuts -IntegrationMode $IntegrationMode
    New-Object -ComObject WScript.Shell
}
'@
        $violations = @(
            Get-CapsulenvModeIsolationBoundaryViolations `
                -EnvironmentPath $environmentFixture `
                -PackageHostIntegrationPath $hostFixture `
                -BitwardenPath $bitwardenFixture `
                -LegacyProjectionPath $legacyFixture
        )
        @($violations.Rule) | Should -Contain 'ModeIsolationStartMenuUserGuard'
        @($violations.Rule) | Should -Contain 'ModeIsolationSshAgentUserGuard'
        @($violations.Rule) | Should -Contain 'ModeIsolationGitShellOnlyEarlyReturn'
        @($violations.Rule) | Should -Contain 'ModeIsolationRestoreUserOwnership'
        @($violations.Rule) | Should -Contain 'ModeIsolationBrowserUserGuard'
        @($violations.Rule) | Should -Contain 'ModeIsolationLegacyProjectionUserHostGuard'
        @($violations.Rule) | Should -Contain 'ModeIsolationLegacyProjectionNoHostUi'
    }

    It 'accepts repository ShellOnly/User ownership boundaries' {
        @(Get-CapsulenvModeIsolationBoundaryViolations `
            -EnvironmentPath (Join-Path (Join-Path $script:Root 'src') '30-Environment.ps1') `
            -PackageHostIntegrationPath (Join-Path (Join-Path $script:Root 'src') '45-PackageHostIntegration.ps1') `
            -BitwardenPath (Join-Path (Join-Path $script:Root 'src') '50-Bitwarden.ps1') `
            -LegacyProjectionPath (Join-Path (Join-Path $script:Root 'src') '46-LegacyScoopProjection.ps1')
        ).Count | Should -Be 0
    }

    It 'rejects detached shortcuts that bypass child-local process plans' {
        $processFixture = New-CapsulenvStaticFixture -Name 'process-plan-unsafe.ps1' -Source @'
function Invoke-CapsulenvProcessPlan {
    Push-Location C:\temp
    Invoke-CapsulenvDetachedProcessPlan
}
function Invoke-CapsulenvDetachedProcessPlan {
    Start-Process demo.exe
    [Environment]::SetEnvironmentVariable('DEMO', 'x', 'Process')
}
'@
        $launcherFixture = New-CapsulenvStaticFixture -Name 'shortcut-process-unsafe.ps1' -Source @'
function Start-CapsulenvScoopShortcut {
    Set-CapsulenvPackageProcessEnvironment -Installed $installed
    Start-Process demo.exe
}
'@
        $packageFixture = New-CapsulenvStaticFixture -Name 'package-process-unsafe.ps1' -Source @'
function Set-CapsulenvPackageProcessEnvironment { $env:PATH = 'x' }
'@
        $toolFixture = New-CapsulenvStaticFixture -Name 'tool-process-unsafe.ps1' -Source @'
function New-CapsulenvNativeProcessStartInfo { New-Object Diagnostics.ProcessStartInfo }
'@
        $violations = @(Get-CapsulenvProcessIsolationBoundaryViolations `
            -ProcessPlanPath $processFixture `
            -AppLauncherPath $launcherFixture `
            -PackageProcessPath $packageFixture `
            -ToolRelocationPath $toolFixture)
        @($violations.Rule) | Should -Contain 'DetachedShortcutCanonicalProcessPlan'
        @($violations.Rule) | Should -Contain 'DetachedShortcutNoParentProcessMutation'
        @($violations.Rule) | Should -Contain 'PackageProcessNoParentEnvironmentMutator'
        @($violations.Rule) | Should -Contain 'ProcessStartInfoSingleAuthority'
        @($violations.Rule) | Should -Contain 'DetachedProcessNoHostOverlay'
        @($violations.Rule) | Should -Contain 'DetachedProcessNoHostEnvironmentMutation'
    }

    It 'accepts repository child-local detached process boundaries' {
        @(Get-CapsulenvProcessIsolationBoundaryViolations `
            -ProcessPlanPath (Join-Path (Join-Path $script:Root 'src') '03-ProcessPlan.ps1') `
            -AppLauncherPath (Join-Path (Join-Path $script:Root 'src') '42-40-AppShortcut.ps1') `
            -PackageProcessPath (Join-Path (Join-Path $script:Root 'src') '44-40-PackageProcess.ps1') `
            -ToolRelocationPath (Join-Path (Join-Path $script:Root 'src') '37-ToolRelocation.ps1')
        ).Count | Should -Be 0
    }

}
