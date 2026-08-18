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
    (Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' -File |
        Where-Object { $_.Name -notin @('Analyze-Capsulenv.ps1', 'Test-Capsulenv.ps1') } |
        Select-Object -ExpandProperty FullName)
)

$diagnostics = @(
    foreach ($path in $paths) {
        Invoke-ScriptAnalyzer -Path $path -Settings $settingsPath
    }
)

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
}
