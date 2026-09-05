Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CapsulenvTestProfileSuiteNames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Full','Fast','Concurrency')]
        [string]$Profile
    )

    switch ($Profile) {
        'Fast' {
            return [string[]]@(
                'ArchitectureAnalysis.Tests.ps1',
                'DesiredState.Tests.ps1',
                'Diagnostics.Tests.ps1',
                'PackageExecutor.Tests.ps1',
                'ScoopReset.Tests.ps1',
                'Static.Tests.ps1',
                'TestHarness.Tests.ps1'
            )
        }
        'Concurrency' {
            return [string[]]@(
                'DesiredState.Tests.ps1',
                'PackageExecutor.Tests.ps1',
                'ScoopReset.Tests.ps1',
                'ToolRelocation.Tests.ps1',
                'TestHarness.Tests.ps1'
            )
        }
        default {
            return [string[]]@()
        }
    }
}

function Select-CapsulenvTestPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$AllTestPaths,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Full','Fast','Concurrency')]
        [string]$Profile
    )

    $ordered = @($AllTestPaths | Sort-Object { Split-Path -Leaf $_ })
    if ($Profile -eq 'Full') {
        return [string[]]$ordered
    }

    $suiteNames = @(Get-CapsulenvTestProfileSuiteNames -Profile $Profile)
    $available = @{}
    foreach ($path in $ordered) {
        $available[[string](Split-Path -Leaf $path)] = [string]$path
    }

    $missing = New-Object System.Collections.Generic.List[string]
    $selected = New-Object System.Collections.Generic.List[string]
    foreach ($suiteName in $suiteNames) {
        if (-not $available.ContainsKey([string]$suiteName)) {
            $missing.Add([string]$suiteName)
            continue
        }
        $selected.Add([string]$available[[string]$suiteName])
    }
    if ($missing.Count -gt 0) {
        throw ("Test profile '{0}' references missing suite(s): {1}" -f $Profile, ($missing -join ', '))
    }
    return [string[]]$selected.ToArray()
}

function New-CapsulenvTestCasePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$TestPaths,
        [ValidateRange(1, 20)][int]$Repeat = 1
    )

    $cases = New-Object System.Collections.Generic.List[object]
    $caseIndex = 0
    for ($repeatIndex = 1; $repeatIndex -le $Repeat; $repeatIndex++) {
        foreach ($path in $TestPaths) {
            $cases.Add([pscustomobject][ordered]@{
                Index = $caseIndex
                RepeatIndex = $repeatIndex
                Path = [string]$path
                SuiteName = [string](Split-Path -Leaf $path)
            })
            $caseIndex++
        }
    }
    return $cases.ToArray()
}
