[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$settingsPath = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
$minimumAnalyzerVersion = [version]'1.25.0'
$staticAnalysisLibrary = Join-Path $PSScriptRoot 'Capsulenv.StaticAnalysis.ps1'
. $staticAnalysisLibrary

$analyzer = Get-Module PSScriptAnalyzer -ListAvailable |
    Where-Object { $_.Version -ge $minimumAnalyzerVersion } |
    Sort-Object Version -Descending |
    Select-Object -First 1
if ($null -eq $analyzer) {
    throw "PSScriptAnalyzer $minimumAnalyzerVersion or newer is required."
}
Import-Module $analyzer.Path -Force

# Analyze code that can execute in the Windows PowerShell 5.1 control plane or
# be merged into the runtime module.  Development-only test/analyzer drivers use
# newer tooling APIs intentionally and are checked by the parser/Pester suite.
$runtimePaths = @(
    (Join-Path $root 'Merge-ModuleScripts.ps1')
    (Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1' -File | Select-Object -ExpandProperty FullName)
    (Get-ChildItem -LiteralPath (Join-Path $root 'module-runtime') -Filter '*.ps1' -File -Recurse | Select-Object -ExpandProperty FullName)
    (Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' -File |
        Where-Object { $_.Name -notin @('Analyze-Capsulenv.ps1', 'Test-Capsulenv.ps1', 'Capsulenv.StaticAnalysis.ps1') } |
        Select-Object -ExpandProperty FullName)
)

$analysisPaths = @($runtimePaths) + @($staticAnalysisLibrary)
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

$allowedShortcutOverridePath = Join-Path (Join-Path $root 'module-runtime') 'scoop-capsulenv-user-policy.ps1'
$hostIntegrationViolations = @(
    Get-CapsulenvHostIntegrationOwnershipViolations `
        -Paths $runtimePaths `
        -AllowedShortcutOverridePath $allowedShortcutOverridePath
)
if ($hostIntegrationViolations.Count -gt 0) {
    $detail = $hostIntegrationViolations | ForEach-Object {
        '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail
    }
    throw "Capsulenv host-integration ownership analysis failed:`n$($detail -join [Environment]::NewLine)"
}

$environmentPath = Join-Path (Join-Path $root 'src') '30-Environment.ps1'
$sessionModeViolations = @(
    Get-CapsulenvSessionModeBoundaryViolations -Path $environmentPath
)
if ($sessionModeViolations.Count -gt 0) {
    $detail = $sessionModeViolations | ForEach-Object {
        '{0}:{1}:{2} [{3}] {4}' -f $_.Path, $_.Line, $_.Column, $_.Rule, $_.Detail
    }
    throw "Capsulenv session-mode ownership analysis failed:`n$($detail -join [Environment]::NewLine)"
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
    SessionModeBoundaryViolations = $sessionModeViolations.Count
    ExternalJsonUnsafeMemberAccess = $externalJsonViolations.Count
}
