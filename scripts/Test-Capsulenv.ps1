[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testsRoot = Join-Path (Join-Path $PSScriptRoot '..') 'tests'
$analysisScript = Join-Path $PSScriptRoot 'Analyze-Capsulenv.ps1'
& $analysisScript | Out-Host

$pester = Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $pester) {
    throw 'Pester is required to run the capsulenv test suite. Install/import Pester 6.1.0 or newer.'
}
if ($pester.Version -lt [version]'6.1.0') {
    throw "Pester 6.1.0 or newer is required; found $($pester.Version)."
}
Import-Module $pester.Path -Force

$config = New-PesterConfiguration
$config.Run.Path = $testsRoot
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
$result = Invoke-Pester -Configuration $config
if ([int]$result.FailedCount -gt 0 -or [int]$result.NotRunCount -gt 0) {
    exit 1
}
exit 0
