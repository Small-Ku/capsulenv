[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testPath = [string]$env:CAPSULENV_TEST_SUITE_PATH
$resultPath = [string]$env:CAPSULENV_TEST_SUITE_RESULT_PATH
if ([string]::IsNullOrWhiteSpace($testPath) -or -not (Test-Path -LiteralPath $testPath -PathType Leaf)) {
    throw "CAPSULENV_TEST_SUITE_PATH does not identify a Pester suite: $testPath"
}
if ([string]::IsNullOrWhiteSpace($resultPath)) {
    throw 'CAPSULENV_TEST_SUITE_RESULT_PATH is required.'
}

$pester = Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $pester -or $pester.Version -lt [version]'6.1.0') {
    throw 'Pester 6.1.0 or newer is required in the isolated suite process.'
}
Import-Module $pester.Path -Force

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$result = Invoke-Pester -Path $testPath -PassThru
$stopwatch.Stop()

$summary = [ordered]@{
    Suite = Split-Path -Leaf $testPath
    Passed = [int]$result.PassedCount
    Failed = [int]$result.FailedCount
    NotRun = [int]$result.NotRunCount
    Total = [int]$result.TotalCount
    DurationSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
}
$parent = Split-Path -Parent $resultPath
if (-not [string]::IsNullOrWhiteSpace($parent)) {
    [void](New-Item -ItemType Directory -Path $parent -Force)
}
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $resultPath -Encoding UTF8
if ($summary.Failed -gt 0 -or $summary.NotRun -gt 0) {
    exit 1
}
exit 0
