[CmdletBinding()]
param(
    [ValidateSet('Full', 'Fast', 'Concurrency')]
    [string]$Profile = 'Full',
    [ValidateRange(1, 20)]
    [int]$Repeat = 1,
    [ValidateRange(10, 900)]
    [int]$SuiteTimeoutSeconds = 120,
    [switch]$SkipWindowsPowerShell51Contract,
    [switch]$KeepArtifacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Profile -eq 'Concurrency' -and -not $PSBoundParameters.ContainsKey('Repeat')) {
    $Repeat = 3
}

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testsRoot = Join-Path $root 'tests'
$analysisScript = Join-Path $PSScriptRoot 'Analyze-Capsulenv.ps1'
$windowsPowerShellContract = Join-Path $testsRoot 'WindowsPowerShell51.Contract.ps1'
$suiteRunner = Join-Path $PSScriptRoot 'Invoke-CapsulenvPesterSuite.ps1'
$testHarnessLibrary = Join-Path $PSScriptRoot 'Capsulenv.TestHarness.ps1'
. $testHarnessLibrary

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
$testPaths = @(Select-CapsulenvTestPaths -AllTestPaths $allTestPaths -Profile $Profile)
if ($testPaths.Count -eq 0) {
    throw "No Pester suites were selected for profile '$Profile'."
}
$testCases = @(New-CapsulenvTestCasePlan -TestPaths $testPaths -Repeat $Repeat)

$hostExecutable = [string](Get-Process -Id $PID).Path
if ([string]::IsNullOrWhiteSpace($hostExecutable) -or -not (Test-Path -LiteralPath $hostExecutable -PathType Leaf)) {
    throw 'Cannot resolve the current PowerShell executable for isolated Pester suite execution.'
}

Write-Host ("[3/3] Pester ({0}: {1} suite(s), {2} repeat(s), {3} isolated process(es), timeout {4}s each)" -f $Profile, $testPaths.Count, $Repeat, $testCases.Count, $SuiteTimeoutSeconds)
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
$gateSucceeded = $false
try {
    foreach ($testCase in $testCases) {
        $testPath = [string]$testCase.Path
        $suiteName = [string]$testCase.SuiteName
        $repeatIndex = [int]$testCase.RepeatIndex
        $caseIndex = [int]$testCase.Index
        $suiteToken = ('{0:D3}-r{1:D2}-{2}' -f $caseIndex, $repeatIndex, ([System.IO.Path]::GetFileNameWithoutExtension($suiteName)))
        $suiteRoot = Join-Path $resultRoot $suiteToken
        $suiteTempRoot = Join-Path $suiteRoot 'tmp'
        $suiteBuildRoot = Join-Path $suiteRoot 'build'
        $resultPath = Join-Path $suiteRoot 'result.json'
        [void](New-Item -ItemType Directory -Path $suiteTempRoot -Force)
        [void](New-Item -ItemType Directory -Path $suiteBuildRoot -Force)
        Write-Host ("  [{0}/{1}] {2} (run {3}/{4})" -f ($caseIndex + 1), $testCases.Count, $suiteName, $repeatIndex, $Repeat)

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $hostExecutable
        $startInfo.Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $suiteRunner.Replace('"', '\"'))
        $startInfo.UseShellExecute = $false
        $startInfo.EnvironmentVariables['CAPSULENV_TEST_SUITE_PATH'] = $testPath
        $startInfo.EnvironmentVariables['CAPSULENV_TEST_SUITE_RESULT_PATH'] = $resultPath
        $startInfo.EnvironmentVariables['CAPSULENV_TEST_ARTIFACT_ROOT'] = $suiteRoot
        $startInfo.EnvironmentVariables['CAPSULENV_BUILD_ROOT'] = $suiteBuildRoot
        $startInfo.EnvironmentVariables['TMP'] = $suiteTempRoot
        $startInfo.EnvironmentVariables['TEMP'] = $suiteTempRoot
        $startInfo.EnvironmentVariables['TMPDIR'] = $suiteTempRoot

        $process = [System.Diagnostics.Process]::Start($startInfo)
        if ($null -eq $process) {
            throw "Failed to start isolated Pester process for $suiteName."
        }
        $completed = $process.WaitForExit($SuiteTimeoutSeconds * 1000)
        if (-not $completed) {
            try { $process.Kill() } catch {}
            $process.Dispose()
            throw "Pester suite timed out after $SuiteTimeoutSeconds seconds: $suiteName (run $repeatIndex/$Repeat). Artifacts: $suiteRoot"
        }
        $exitCode = $process.ExitCode
        $process.Dispose()

        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            throw "Pester suite process exited with code $exitCode without writing a result: $suiteName (run $repeatIndex/$Repeat). Artifacts: $suiteRoot"
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
        $resultSignalsFailure = (
            [int]$result.Failed -gt 0 -or
            [int]$result.NotRun -gt 0 -or
            $infrastructureFailed -gt 0
        )
        $processExitMismatch = (
            ($resultSignalsFailure -and $exitCode -eq 0) -or
            ((-not $resultSignalsFailure) -and $exitCode -ne 0)
        )
        if ($processExitMismatch) {
            $infrastructureFailed++
            Write-Warning ("{0} (run {1}/{2}) result/exit mismatch: exit {3}." -f $suiteName, $repeatIndex, $Repeat, $exitCode)
        }
        $infrastructureFailedCount += $infrastructureFailed

        $suiteResults.Add([pscustomobject][ordered]@{
            Suite = $suiteName
            Run = $repeatIndex
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
    $gateSucceeded = ($failedCount -eq 0 -and $notRunCount -eq 0 -and $infrastructureFailedCount -eq 0)
} finally {
    $gateStopwatch.Stop()
    if ($KeepArtifacts -or -not $completedGate -or -not $gateSucceeded) {
        if ($gateSucceeded) {
            Write-Host ("Test artifacts retained at: {0}" -f $resultRoot)
        } else {
            Write-Warning ("Test gate did not pass cleanly; artifacts retained at: {0}" -f $resultRoot)
        }
    } else {
        Remove-Item -LiteralPath $resultRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
$suiteResults.ToArray() | Format-Table -AutoSize | Out-Host
Write-Host ("Capsulenv Pester gate ({0}, repeat {1}): {2}/{3} passed, {4} failed, {5} not run, {6} infrastructure failure(s) in {7:N2}s." -f $Profile, $Repeat, $passedCount, $totalCount, $failedCount, $notRunCount, $infrastructureFailedCount, $gateStopwatch.Elapsed.TotalSeconds)
if (-not $gateSucceeded) {
    exit 1
}
exit 0
