[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$settingsPath = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
$minimumAnalyzerVersion = [version]'1.25.0'

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
$paths = @(
    (Join-Path $root 'Merge-ModuleScripts.ps1')
    (Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1' -File | Select-Object -ExpandProperty FullName)
    (Get-ChildItem -LiteralPath (Join-Path $root 'module-runtime') -Filter '*.ps1' -File -Recurse | Select-Object -ExpandProperty FullName)
    (Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' -File |
        Where-Object { $_.Name -notin @('Analyze-Capsulenv.ps1', 'Test-Capsulenv.ps1') } |
        Select-Object -ExpandProperty FullName)
)

$diagnostics = @(
    foreach ($path in $paths) {
        Invoke-ScriptAnalyzer -Path $path -Settings $settingsPath
    }
)

function Get-CapsulenvCommandAsts {
    param([Parameter(Mandatory = $true)][string]$Path)

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        throw "Static command-boundary parse failed: $Path"
    }
    return @(
        $ast.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.CommandAst] },
            $true
        )
    )
}

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
    foreach ($path in $paths) {
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

if ($diagnostics.Count -gt 0) {
    $detail = $diagnostics | ForEach-Object {
        '{0}:{1}:{2} [{3}] {4}' -f $_.ScriptPath, $_.Line, $_.Column, $_.RuleName, $_.Message
    }
    throw "PowerShell 5.1 compatibility analysis failed:`n$($detail -join [Environment]::NewLine)"
}

[pscustomobject]@{
    AnalyzerVersion = [string]$analyzer.Version
    FilesAnalyzed = $paths.Count
    Diagnostics = 0
    ControlBootstrapCommands = $controlBootstrapCommands.Count
    ForbiddenRuntimeCommands = $forbiddenRuntimeUses.Count
}
