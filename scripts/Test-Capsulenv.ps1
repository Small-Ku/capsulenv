[CmdletBinding()]
param(
    [ValidateSet('Full', 'Fast')]
    [string]$Profile = 'Full',
    [ValidateRange(10, 900)]
    [int]$SuiteTimeoutSeconds = 120,
    [switch]$SkipWindowsPowerShell51Contract,
    [switch]$KeepArtifacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testsRoot = Join-Path $root 'tests'
$analysisScript = Join-Path $PSScriptRoot 'Analyze-Capsulenv.ps1'
$windowsPowerShellContract = Join-Path $testsRoot 'WindowsPowerShell51.Contract.ps1'
$suiteRunner = Join-Path $PSScriptRoot 'Invoke-CapsulenvPesterSuite.ps1'

Write-Host '[1/3] Static analysis'
& $analysisScript | Out-Host

Write-Host '[2/3] Windows PowerShell 5.1 runtime contract'
if ($SkipWindowsPowerShell51Contract) {
    Write-Host 'Skipped by request.'
} elseif ($PSVersionTable.PSEdition -eq 'Desktop' -or $env:OS -eq 'Windows_NT') {
    $windowsPowerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($null -eq $windowsPowerShell) {
        throw 'Windows PowerShell 5.1 contract cannot run because powershell.exe is unavailable.'
    }
    & $windowsPowerShell.Source `
        -NoProfile `
        -NonInteractive `
        -ExecutionPolicy Bypass `
        -File $windowsPowerShellContract `
        -RequireWindowsPowerShell51 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Windows PowerShell 5.1 runtime contract failed with exit code $LASTEXITCODE."
    }
} else {
    Write-Host 'Skipped: Windows PowerShell 5.1 is not available on this host.'
}

$pester = Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $pester) {
    throw 'Pester is required to run the capsulenv test suite. Install/import Pester 6.1.0 or newer.'
}
if ($pester.Version -lt [version]'6.1.0') {
    throw "Pester 6.1.0 or newer is required; found $($pester.Version)."
}

$allTestPaths = @(
    Get-ChildItem -LiteralPath $testsRoot -Filter '*.Tests.ps1' -File |
        Sort-Object Name |
        ForEach-Object { $_.FullName }
)
$fastSuites = @(
    'ArchitectureAnalysis.Tests.ps1',
    'DesiredState.Tests.ps1',
    'Diagnostics.Tests.ps1',
    'PackageExecutor.Tests.ps1',
    'ScoopReset.Tests.ps1',
    'Static.Tests.ps1',
    'TestHarness.Tests.ps1'
)
$testPaths = if ($Profile -eq 'Fast') {
    @($allTestPaths | Where-Object { $fastSuites -contains (Split-Path -Leaf $_) })
} else {
    $allTestPaths
}
if ($testPaths.Count -eq 0) {
    throw "No Pester suites were selected for profile '$Profile'."
}

$hostExecutable = [string](Get-Process -Id $PID).Path
if ([string]::IsNullOrWhiteSpace($hostExecutable) -or -not (Test-Path -LiteralPath $hostExecutable -PathType Leaf)) {
    throw 'Cannot resolve the current PowerShell executable for isolated Pester suite execution.'
}

Write-Host ("[3/3] Pester ({0}: {1} isolated suite process(es), timeout {2}s each)" -f $Profile, $testPaths.Count, $SuiteTimeoutSeconds)
$passedCount = 0
$failedCount = 0
$notRunCount = 0
$infrastructureFailedCount = 0
$totalCount = 0
$suiteResults = New-Object System.Collections.Generic.List[object]
$gateStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$resultRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-test-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $resultRoot -Force)
$completedGate = $false
try {
    for ($index = 0; $index -lt $testPaths.Count; $index++) {
        $testPath = $testPaths[$index]
        $suiteName = Split-Path -Leaf $testPath
        $suiteToken = ('{0:D3}-{1}' -f $index, ([System.IO.Path]::GetFileNameWithoutExtension($suiteName)))
        $suiteRoot = Join-Path $resultRoot $suiteToken
        $suiteTempRoot = Join-Path $suiteRoot 'tmp'
        $suiteBuildRoot = Join-Path $suiteRoot 'build'
        $resultPath = Join-Path $suiteRoot 'result.json'
        [void](New-Item -ItemType Directory -Path $suiteTempRoot -Force)
        [void](New-Item -ItemType Directory -Path $suiteBuildRoot -Force)
        Write-Host ("  [{0}/{1}] {2}" -f ($index + 1), $testPaths.Count, $suiteName)

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $hostExecutable
        $startInfo.Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $suiteRunner.Replace('"', '\"'))
        $startInfo.UseShellExecute = $false
        $startInfo.EnvironmentVariables['CAPSULENV_TEST_SUITE_PATH'] = $testPath
        $startInfo.EnvironmentVariables['CAPSULENV_TEST_SUITE_RESULT_PATH'] = $resultPath
        $startInfo.EnvironmentVariables['CAPSULENV_TEST_ARTIFACT_ROOT'] = $suiteRoot
        $startInfo.EnvironmentVariables['CAPSULENV_BUILD_ROOT'] = $suiteBuildRoot
        foreach ($tempVariable in @('TMP', 'TEMP', 'TMPDIR')) {
            $startInfo.EnvironmentVariables[$tempVariable] = $suiteTempRoot
        }

        $process = [System.Diagnostics.Process]::Start($startInfo)
        if ($null -eq $process) {
            throw "Failed to start isolated Pester process for $suiteName."
        }
        $completed = $process.WaitForExit($SuiteTimeoutSeconds * 1000)
        if (-not $completed) {
            try { $process.Kill() } catch {}
            $process.Dispose()
            throw "Pester suite timed out after $SuiteTimeoutSeconds seconds: $suiteName. Artifacts: $suiteRoot"
        }
        $exitCode = $process.ExitCode
        $process.Dispose()

        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            throw "Pester suite process exited with code $exitCode without writing a result: $suiteName. Artifacts: $suiteRoot"
        }
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        $passedCount += [int]$result.Passed
        $failedCount += [int]$result.Failed
        $notRunCount += [int]$result.NotRun
        $totalCount += [int]$result.Total
        $infrastructureFailed = if ($null -ne $result.PSObject.Properties['InfrastructureFailed']) {
            [int]$result.InfrastructureFailed
        } else {
            0
        }
        $infrastructureFailedCount += $infrastructureFailed
        $suiteResults.Add([pscustomobject][ordered]@{
            Suite = $suiteName
            Passed = [int]$result.Passed
            Failed = [int]$result.Failed
            NotRun = [int]$result.NotRun
            InfrastructureFailed = $infrastructureFailed
            DurationSeconds = [double]$result.DurationSeconds
            ExitCode = $exitCode
        })
        Write-Host ("        {0}/{1} passed; {2} failed; infra {3}; {4:N2}s" -f $result.Passed, $result.Total, $result.Failed, $infrastructureFailed, [double]$result.DurationSeconds)
        if ($infrastructureFailed -gt 0 -and $null -ne $result.PSObject.Properties['InfrastructureError']) {
            Write-Warning ("{0}: {1}" -f $suiteName, [string]$result.InfrastructureError)
        }
    }
    $completedGate = $true
} finally {
    $gateStopwatch.Stop()
    if ($KeepArtifacts) {
        Write-Host ("Test artifacts retained at: {0}" -f $resultRoot)
    } elseif ($completedGate) {
        Remove-Item -LiteralPath $resultRoot -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Warning ("Test gate aborted; artifacts retained at: {0}" -f $resultRoot)
    }
}

Write-Host ''
$suiteResults.ToArray() | Format-Table -AutoSize | Out-Host
Write-Host ("Capsulenv Pester gate ({0}): {1}/{2} passed, {3} failed, {4} not run, {5} infrastructure failure(s) in {6:N2}s." -f $Profile, $passedCount, $totalCount, $failedCount, $notRunCount, $infrastructureFailedCount, $gateStopwatch.Elapsed.TotalSeconds)
if ($failedCount -gt 0 -or $notRunCount -gt 0 -or $infrastructureFailedCount -gt 0) {
    exit 1
}
exit 0
