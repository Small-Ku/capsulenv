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

}
