[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$settingsPath = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
$minimumAnalyzerVersion = [version]'1.25.0'
$staticAnalysisLibrary = Join-Path $PSScriptRoot 'Capsulenv.StaticAnalysis.ps1'
$dagStaticAnalysisLibrary = Join-Path $PSScriptRoot 'Capsulenv.DagStaticAnalysis.ps1'
. $staticAnalysisLibrary

$analyzer = Get-Module PSScriptAnalyzer -ListAvailable |
    Where-Object { $_.Version -ge $minimumAnalyzerVersion } |
    Sort-Object Version -Descending |
    Select-Object -First 1
if ($null -eq $analyzer) {
    throw "PSScriptAnalyzer $minimumAnalyzerVersion or newer is required."
}
Import-Module $analyzer.Path -Force

try {
# Analyze code that can execute in the Windows PowerShell 5.1 control plane or
# be merged into the runtime module.  Development-only test/analyzer drivers use
# newer tooling APIs intentionally and are checked by the parser/Pester suite.
$runtimePaths = @(
    (Join-Path $root 'Merge-ModuleScripts.ps1')
    (Join-Path (Join-Path $root 'packaging') 'capsulenv-runtime.ps1')
    (Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1' -File | Select-Object -ExpandProperty FullName)
    (Get-ChildItem -LiteralPath (Join-Path $root 'module-runtime') -Filter '*.ps1' -File -Recurse | Select-Object -ExpandProperty FullName)
    (Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' -File |
        Where-Object { $_.Name -notin @('Analyze-Capsulenv.ps1', 'Test-Capsulenv.ps1', 'Capsulenv.StaticAnalysis.ps1') } |
        Select-Object -ExpandProperty FullName)
)

$analysisPaths = @($runtimePaths) + @($staticAnalysisLibrary, $dagStaticAnalysisLibrary)
$diagnostics = @(
    foreach ($path in $analysisPaths) {
        Invoke-ScriptAnalyzer -Path $path -Settings $settingsPath
    }
)

$controlBootstrapPath = Join-Path (Join-Path $root 'module-runtime') 'Initialize-CapsulenvControlHost.ps1'
$controlBootstrapCommands = @(Get-CapsulenvCommandAsts -Path $controlBootstrapPath)
if ($controlBootstrapCommands.Count -gt 0) {
    $detail = $controlBootstrapCommands | ForEach-Object {
        '{0}:{1}: {2}' -f $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Extent.Text
    }
    throw "Control-host bootstrap must remain PowerShell language/.NET-only; command dependencies are forbidden:`n$($detail -join [Environment]::NewLine)"
}

$forbiddenRuntimeCommands = @('Import-PowerShellDataFile')
$forbiddenRuntimeUses = @(
    foreach ($path in $runtimePaths) {
        foreach ($commandAst in @(Get-CapsulenvCommandAsts -Path $path)) {
            $commandName = $commandAst.GetCommandName()
            if ($commandName -and $commandName -in $forbiddenRuntimeCommands) {
                [pscustomobject]@{
                    Path = $path
                    Line = $commandAst.Extent.StartLineNumber
                    Column = $commandAst.Extent.StartColumnNumber
                    Command = $commandName
                }
            }
        }
    }
)
if ($forbiddenRuntimeUses.Count -gt 0) {
    $detail = $forbiddenRuntimeUses | ForEach-Object {
        '{0}:{1}:{2}: forbidden runtime dependency {3}' -f $_.Path, $_.Line, $_.Column, $_.Command
    }
    throw "Capsulenv runtime command-boundary analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$hostIntegrationViolations = @(
    Get-CapsulenvHostIntegrationOwnershipViolations -Paths $runtimePaths
)
if ($hostIntegrationViolations.Count -gt 0) {
    $detail = $hostIntegrationViolations | ForEach-Object {
        '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail
    }
    throw "Capsulenv host-integration ownership analysis failed:`n$($detail -join [Environment]::NewLine)"
}


$workloadSpecializationViolations = @(
    Get-CapsulenvWorkloadSpecializationViolations -Paths @(
        Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1' -File | Select-Object -ExpandProperty FullName
    )
)
if ($workloadSpecializationViolations.Count -gt 0) {
    $detail = $workloadSpecializationViolations | ForEach-Object {
        '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail
    }
    throw "Capsulenv workload-ownership analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$scoopRuntimeAdapterViolations = @(
    Get-CapsulenvScoopRuntimeAdapterViolations -RuntimeRoot (Join-Path $root 'module-runtime')
)
if ($scoopRuntimeAdapterViolations.Count -gt 0) {
    $detail = $scoopRuntimeAdapterViolations | ForEach-Object {
        '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail
    }
    throw "Capsulenv Scoop runtime-adapter analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$installModePath = Join-Path (Join-Path $root 'src') '30-20-InstallMode.ps1'
$sessionModeViolations = @(
    Get-CapsulenvSessionModeBoundaryViolations -Path $installModePath
)
if ($sessionModeViolations.Count -gt 0) {
    $detail = $sessionModeViolations | ForEach-Object {
        '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail
    }
    throw "Capsulenv session-mode ownership analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$scoopBootstrapPath = Join-Path (Join-Path $root 'src') '41-ScoopBootstrap.ps1'
$stockScoopBoundaryViolations = @(
    Get-CapsulenvStockScoopBoundaryViolations -Path $scoopBootstrapPath
)
if ($stockScoopBoundaryViolations.Count -gt 0) {
    $detail = $stockScoopBoundaryViolations | ForEach-Object {
        '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail
    }
    throw "Capsulenv stock Scoop boundary analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$toolRelocationPath = Join-Path (Join-Path $root 'src') '37-ToolRelocation.ps1'
$externalJsonViolations = @(
    Get-CapsulenvExternalJsonMemberViolations `
        -Path $toolRelocationPath `
        -FunctionName 'Get-CapsulenvUvManagedPythonInstallations' `
        -RecordVariables @('item')
)
if ($externalJsonViolations.Count -gt 0) {
    $detail = $externalJsonViolations | ForEach-Object {
        '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail
    }
    throw "Capsulenv external-data access analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$mandatoryBindingViolations = @(Get-CapsulenvMandatoryParameterBindingViolations -Paths $runtimePaths)
if ($mandatoryBindingViolations.Count -gt 0) {
    $detail = $mandatoryBindingViolations | ForEach-Object {
        '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail
    }
    throw "Capsulenv mandatory-parameter binding analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$desiredStateNodeBindingViolations = @(Get-CapsulenvDesiredStateNodeBindingBoundaryViolations -Paths $runtimePaths)
if ($desiredStateNodeBindingViolations.Count -gt 0) {
    $detail = $desiredStateNodeBindingViolations | ForEach-Object {
        '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail
    }
    throw "Capsulenv desired-state scriptblock binding analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$desiredStateNodeContractViolations = @(Get-CapsulenvDesiredStateNodeContractViolations -Paths $runtimePaths)
if ($desiredStateNodeContractViolations.Count -gt 0) {
    $detail = $desiredStateNodeContractViolations | ForEach-Object {
        '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail
    }
    throw "Capsulenv desired-state node contract analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$desiredStateWorkerReachabilityViolations = @(Get-CapsulenvDesiredStateWorkerReachabilityViolations -Paths $runtimePaths)
if ($desiredStateWorkerReachabilityViolations.Count -gt 0) {
    $detail = $desiredStateWorkerReachabilityViolations | ForEach-Object {
        '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail
    }
    throw "Capsulenv desired-state worker call-graph analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$desiredStateWorkerPreflightViolations = @(
    Get-CapsulenvDesiredStateWorkerPreflightViolations `
        -IntegrationPath (Join-Path (Join-Path $root 'src') '40-Scoop.ps1') `
        -PackageGraphPath (Join-Path (Join-Path $root 'src') '45-PackageExecutionGraph.ps1')
)
if ($desiredStateWorkerPreflightViolations.Count -gt 0) {
    $detail = $desiredStateWorkerPreflightViolations | ForEach-Object {
        '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail
    }
    throw "Capsulenv desired-state worker preflight analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$desiredStateSchedulerViolations = @(
    Get-CapsulenvDesiredStateSchedulerBoundaryViolations -Path (Join-Path (Join-Path $root 'src') '01-DesiredStateCore.ps1')
)
if ($desiredStateSchedulerViolations.Count -gt 0) {
    $detail = $desiredStateSchedulerViolations | ForEach-Object {
        '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail
    }
    throw "Capsulenv desired-state scheduler boundary analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$portablePackageExecutionViolations = @(
    Get-CapsulenvPortablePackageExecutionBoundaryViolations -Paths @(
        Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1' -File | Select-Object -ExpandProperty FullName
    )
)
if ($portablePackageExecutionViolations.Count -gt 0) {
    $detail = $portablePackageExecutionViolations | ForEach-Object {
        '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail
    }
    throw "Capsulenv PortableSafe package execution boundary analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$testHarnessIsolationViolations = @(
    Get-CapsulenvTestHarnessIsolationViolations -Path (Join-Path (Join-Path $root 'scripts') 'Test-Capsulenv.ps1')
)

$runtimeLauncherViolations = @(Get-CapsulenvRuntimeLauncherBoundaryViolations -Path (Join-Path (Join-Path $root 'module-runtime') 'Invoke-Capsulenv.ps1'))
if ($runtimeLauncherViolations.Count -gt 0) {
    $detail = $runtimeLauncherViolations | ForEach-Object { '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail }
    throw "Capsulenv runtime-launcher boundary analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$installerLifecycleViolations = @(Get-CapsulenvInstallerLifecycleBoundaryViolations -Path (Join-Path (Join-Path $root 'scripts') 'Install-Capsulenv.ps1'))
if ($installerLifecycleViolations.Count -gt 0) {
    $detail = $installerLifecycleViolations | ForEach-Object { '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail }
    throw "Capsulenv installer lifecycle-boundary analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$persistRelocationScanViolations = @(Get-CapsulenvPersistRelocationScanViolations -Paths @((Join-Path (Join-Path $root 'src') '45-Relocation.ps1'), (Join-Path (Join-Path $root 'src') '46-PersistRelocation.ps1')))
if ($persistRelocationScanViolations.Count -gt 0) {
    $detail = $persistRelocationScanViolations | ForEach-Object { '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail }
    throw "Capsulenv persist-relocation scan analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$projectCacheOrderingViolations = @(Get-CapsulenvProjectCacheOrderingViolations -Path (Join-Path (Join-Path $root 'src') '35-ToolStorage.ps1'))
if ($projectCacheOrderingViolations.Count -gt 0) {
    $detail = $projectCacheOrderingViolations | ForEach-Object { '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail }
    throw "Capsulenv project-cache ordering analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$modeIsolationBoundaryViolations = @(
    Get-CapsulenvModeIsolationBoundaryViolations `
        -UserModePath (Join-Path (Join-Path $root 'src') '30-40-UserShell.ps1') `
        -SessionShellPath (Join-Path (Join-Path $root 'src') '30-50-SessionShell.ps1') `
        -PackageHostIntegrationPath (Join-Path (Join-Path $root 'src') '45-PackageHostIntegration.ps1') `
        -BitwardenPath (Join-Path (Join-Path $root 'src') '50-Bitwarden.ps1') `
        -LegacyProjectionPath (Join-Path (Join-Path $root 'src') '46-LegacyScoopProjection.ps1')
)
if ($modeIsolationBoundaryViolations.Count -gt 0) {
    $detail = $modeIsolationBoundaryViolations | ForEach-Object { '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail }
    throw "Capsulenv install-mode isolation analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$processIsolationBoundaryViolations = @(
    Get-CapsulenvProcessIsolationBoundaryViolations `
        -ProcessPlanPath (Join-Path (Join-Path $root 'src') '03-ProcessPlan.ps1') `
        -AppLauncherPath (Join-Path (Join-Path $root 'src') '42-40-AppShortcut.ps1') `
        -PackageProcessPath (Join-Path (Join-Path $root 'src') '44-40-PackageProcess.ps1') `
        -ToolRelocationPath (Join-Path (Join-Path $root 'src') '37-ToolRelocation.ps1')
)
if ($processIsolationBoundaryViolations.Count -gt 0) {
    $detail = $processIsolationBoundaryViolations | ForEach-Object { '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail }
    throw "Capsulenv process-isolation boundary analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$bitwardenStateBoundaryViolations = @(Get-CapsulenvBitwardenStateBoundaryViolations -Path (Join-Path (Join-Path $root 'src') '55-BitwardenSshAgent.ps1'))
if ($bitwardenStateBoundaryViolations.Count -gt 0) {
    $detail = $bitwardenStateBoundaryViolations | ForEach-Object { '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail }
    throw "Capsulenv Bitwarden state-boundary analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$environmentHotPathViolations = @(
    Get-CapsulenvEnvironmentHotPathViolations `
        -SessionEnvironmentPath (Join-Path (Join-Path $root 'src') '30-10-EnvironmentSession.ps1') `
        -UserEnvironmentPath (Join-Path (Join-Path $root 'src') '30-30-UserEnvironment.ps1')
)
$environmentPlanReuseViolations = @(
    Get-CapsulenvEnvironmentPlanReuseViolations `
        -SessionEnvironmentPath (Join-Path (Join-Path $root 'src') '30-10-EnvironmentSession.ps1') `
        -ToolStoragePath (Join-Path (Join-Path $root 'src') '35-ToolStorage.ps1')
)
if ($environmentPlanReuseViolations.Count -gt 0) {
    $detail = $environmentPlanReuseViolations | ForEach-Object { '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail }
    throw "Capsulenv environment plan-reuse analysis failed:`n$($detail -join [Environment]::NewLine)"
}
if ($environmentHotPathViolations.Count -gt 0) {
    $detail = $environmentHotPathViolations | ForEach-Object { '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail }
    throw "Capsulenv session environment hot-path analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$scoopBootstrapHotPathViolations = @(
    Get-CapsulenvScoopBootstrapHotPathViolations `
        -BootstrapPath (Join-Path (Join-Path $root 'src') '41-ScoopBootstrap.ps1') `
        -IntegrationsPath (Join-Path (Join-Path $root 'src') '70-Doctor.ps1') `
        -CommandsPath (Join-Path (Join-Path $root 'src') '90-90-Dispatch.ps1')
)
$toolStorageHotPathViolations = @(
    Get-CapsulenvToolStorageHotPathViolations `
        -ReadinessPath (Join-Path (Join-Path $root 'src') '34-ToolStorageReadiness.ps1') `
        -ToolStoragePath (Join-Path (Join-Path $root 'src') '35-ToolStorage.ps1') `
        -SessionEnvironmentPath (Join-Path (Join-Path $root 'src') '30-10-EnvironmentSession.ps1') `
        -CacheCommandPath (Join-Path (Join-Path $root 'src') '90-20-CacheTools.ps1') `
        -DoctorPath (Join-Path (Join-Path $root 'src') '70-Doctor.ps1')
)
if ($toolStorageHotPathViolations.Count -gt 0) {
    $detail = $toolStorageHotPathViolations | ForEach-Object { '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail }
    throw "Capsulenv ToolStorage hot-path analysis failed:`n$($detail -join [Environment]::NewLine)"
}
if ($scoopBootstrapHotPathViolations.Count -gt 0) {
    $detail = $scoopBootstrapHotPathViolations | ForEach-Object { '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail }
    throw "Capsulenv Scoop bootstrap hot-path analysis failed:`n$($detail -join [Environment]::NewLine)"
}
if ($testHarnessIsolationViolations.Count -gt 0) {
    $detail = $testHarnessIsolationViolations | ForEach-Object {
        '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail
    }
    throw "Capsulenv test-harness isolation analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$loopArrayAppendViolations = @(Get-CapsulenvLoopArrayAppendViolations -Paths $runtimePaths)
if ($loopArrayAppendViolations.Count -gt 0) {
    $detail = $loopArrayAppendViolations | ForEach-Object {
        '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail
    }
    throw "Capsulenv loop-array performance analysis failed:`n$($detail -join [Environment]::NewLine)"
}

if ($diagnostics.Count -gt 0) {
    $detail = $diagnostics | ForEach-Object {
        '{0}:{1}:{2} [{3}] {4}' -f $_.ScriptPath, $_.Line, $_.Column, $_.RuleName, $_.Message
    }
    throw "PowerShell 5.1 compatibility analysis failed:`n$($detail -join [Environment]::NewLine)"
}

[pscustomobject]@{
    AnalyzerVersion = [string]$analyzer.Version
    FilesAnalyzed = $analysisPaths.Count
    Diagnostics = 0
    ControlBootstrapCommands = $controlBootstrapCommands.Count
    ForbiddenRuntimeCommands = $forbiddenRuntimeUses.Count
    HostIntegrationOwnershipViolations = $hostIntegrationViolations.Count
    WorkloadSpecializationViolations = $workloadSpecializationViolations.Count
    ScoopRuntimeAdapterViolations = $scoopRuntimeAdapterViolations.Count
    SessionModeBoundaryViolations = $sessionModeViolations.Count
    StockScoopBoundaryViolations = $stockScoopBoundaryViolations.Count
    ExternalJsonUnsafeMemberAccess = $externalJsonViolations.Count
    MandatoryParameterBindingViolations = $mandatoryBindingViolations.Count
    DesiredStateNodeBindingViolations = $desiredStateNodeBindingViolations.Count
    DesiredStateNodeContractViolations = $desiredStateNodeContractViolations.Count
    DesiredStateWorkerReachabilityViolations = $desiredStateWorkerReachabilityViolations.Count
    DesiredStateWorkerPreflightViolations = $desiredStateWorkerPreflightViolations.Count
    DesiredStateSchedulerViolations = $desiredStateSchedulerViolations.Count
    PortablePackageExecutionViolations = $portablePackageExecutionViolations.Count
    TestHarnessIsolationViolations = $testHarnessIsolationViolations.Count
    RuntimeLauncherBoundaryViolations = $runtimeLauncherViolations.Count
    InstallerLifecycleBoundaryViolations = $installerLifecycleViolations.Count
    PersistRelocationScanViolations = $persistRelocationScanViolations.Count
    ProjectCacheOrderingViolations = $projectCacheOrderingViolations.Count
    ModeIsolationBoundaryViolations = $modeIsolationBoundaryViolations.Count
    ProcessIsolationBoundaryViolations = $processIsolationBoundaryViolations.Count
    BitwardenStateBoundaryViolations = $bitwardenStateBoundaryViolations.Count
    EnvironmentHotPathViolations = $environmentHotPathViolations.Count
    EnvironmentPlanReuseViolations = $environmentPlanReuseViolations.Count
    ScoopBootstrapHotPathViolations = $scoopBootstrapHotPathViolations.Count
    ToolStorageHotPathViolations = $toolStorageHotPathViolations.Count
    LoopArrayAppendViolations = $loopArrayAppendViolations.Count
}
} finally {
    # PSScriptAnalyzer 1.25 can keep background analysis resources alive long
    # enough to stall non-interactive pwsh process shutdown unless the module is
    # explicitly unloaded.  Keep the analyzer lifecycle inside this script so
    # the canonical test runner can supervise it deterministically.
    Remove-Module PSScriptAnalyzer -Force -ErrorAction SilentlyContinue
}
