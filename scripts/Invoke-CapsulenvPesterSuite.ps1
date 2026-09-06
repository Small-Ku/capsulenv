[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testPath = [string]$env:CAPSULENV_TEST_SUITE_PATH
$resultPath = [string]$env:CAPSULENV_TEST_SUITE_RESULT_PATH
if ([string]::IsNullOrWhiteSpace($resultPath)) {
    throw 'CAPSULENV_TEST_SUITE_RESULT_PATH is required.'
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$summary = [ordered]@{
    Suite = if ([string]::IsNullOrWhiteSpace($testPath)) { '' } else { Split-Path -Leaf $testPath }
    Passed = 0
    Failed = 0
    NotRun = 0
    Total = 0
    InfrastructureFailed = 0
    InfrastructureError = ''
    DurationSeconds = 0.0
}
try {
    if ([string]::IsNullOrWhiteSpace($testPath) -or -not (Test-Path -LiteralPath $testPath -PathType Leaf)) {
        throw "CAPSULENV_TEST_SUITE_PATH does not identify a Pester suite: $testPath"
    }

    $pester = Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
    if ($null -eq $pester -or $pester.Version -lt [version]'6.1.0') {
        throw 'Pester 6.1.0 or newer is required in the isolated suite process.'
    }
    Import-Module $pester.Path -Force

    $testSupport = Join-Path (Split-Path -Parent $testPath) 'Capsulenv.TestSupport.ps1'
    if (Test-Path -LiteralPath $testSupport -PathType Leaf) {
        . $testSupport
    }

    $result = Invoke-Pester -Path $testPath -PassThru
    $summary.Passed = [int]$result.PassedCount
    $summary.Failed = [int]$result.FailedCount
    $summary.NotRun = [int]$result.NotRunCount
    $summary.Total = [int]$result.TotalCount
} catch {
    $summary.InfrastructureFailed = 1
    $summary.InfrastructureError = [string]$_.Exception.Message
} finally {
    $stopwatch.Stop()
    $summary.DurationSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
    $parent = Split-Path -Parent $resultPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    $summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $resultPath -Encoding UTF8
}

if ($summary.InfrastructureFailed -gt 0 -or $summary.Failed -gt 0 -or $summary.NotRun -gt 0) {
    exit 1
}
exit 0
