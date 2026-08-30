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

$testPaths = @(
    Get-ChildItem -LiteralPath $testsRoot -Filter '*.Tests.ps1' -File |
        Sort-Object Name |
        ForEach-Object { $_.FullName }
)
$passedCount = 0
$failedCount = 0
$notRunCount = 0
$totalCount = 0

# Run each suite through a fresh Pester invocation. Several tests rebuild and
# reload the module; keeping all files in one Pester run causes accumulated
# module/runspace state to make later suites progressively slower and can leave
# the delivery gate waiting long after the individual tests have completed.
foreach ($testPath in $testPaths) {
    $config = New-PesterConfiguration
    $config.Run.Path = $testPath
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Minimal'
    $result = Invoke-Pester -Configuration $config

    $passedCount += [int]$result.PassedCount
    $failedCount += [int]$result.FailedCount
    $notRunCount += [int]$result.NotRunCount
    $totalCount += [int]$result.TotalCount
}

Write-Host ("Capsulenv Pester gate: {0}/{1} passed, {2} failed, {3} not run." -f $passedCount, $totalCount, $failedCount, $notRunCount)
if ($failedCount -gt 0 -or $notRunCount -gt 0) {
    exit 1
}
exit 0
