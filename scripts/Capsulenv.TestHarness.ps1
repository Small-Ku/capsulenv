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
                'ProjectCacheLifecycle.Tests.ps1',
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

function New-CapsulenvTestExecutionPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Cases)

    $nodes = New-Object System.Collections.Generic.List[object]
    $sharedModuleBuildId = 'build:shared-module'
    $nodes.Add([pscustomobject][ordered]@{
        Id = $sharedModuleBuildId
        Index = 0
        Kind = 'SharedModuleBuild'
        DependsOn = [string[]]@()
        Case = $null
    })
    foreach ($case in @($Cases)) {
        $id = ('suite:{0:D3}:r{1:D2}:{2}' -f [int]$case.Index, [int]$case.RepeatIndex, [string]$case.SuiteName)
        $nodes.Add([pscustomobject][ordered]@{
            Id = $id
            Index = [int]$case.Index + 1
            Kind = 'Suite'
            DependsOn = [string[]]@($sharedModuleBuildId)
            Case = $case
        })
    }
    $suiteIds = [string[]]@($nodes | Where-Object Kind -eq 'Suite' | ForEach-Object { [string]$_.Id })
    $terminalId = 'gate:complete'
    $nodes.Add([pscustomobject][ordered]@{
        Id = $terminalId
        Index = $Cases.Count + 1
        Kind = 'Barrier'
        DependsOn = $suiteIds
        Case = $null
    })
    return [pscustomobject][ordered]@{
        Nodes = $nodes.ToArray()
        SharedModuleBuildId = $sharedModuleBuildId
        TerminalId = $terminalId
    }
}

function New-CapsulenvTestDagState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Nodes)

    $byId = @{}
    $indexById = @{}
    for ($index = 0; $index -lt $Nodes.Count; $index++) {
        $id = [string]$Nodes[$index].Id
        if ([string]::IsNullOrWhiteSpace($id)) { throw 'Test DAG node id cannot be empty.' }
        if ($byId.ContainsKey($id)) { throw "Duplicate test DAG node id: $id" }
        $byId[$id] = $Nodes[$index]
        $indexById[$id] = $index
    }

    $unmet = [int[]]::new($Nodes.Count)
    $dependents = @{}
    foreach ($id in @($byId.Keys)) { $dependents[[string]$id] = [System.Collections.Generic.List[int]]::new() }
    for ($index = 0; $index -lt $Nodes.Count; $index++) {
        foreach ($dependency in @($Nodes[$index].DependsOn)) {
            $dependencyId = [string]$dependency
            if (-not $byId.ContainsKey($dependencyId)) {
                throw ("Test DAG node '{0}' depends on missing node '{1}'." -f $Nodes[$index].Id, $dependencyId)
            }
            $unmet[$index]++
            $dependents[$dependencyId].Add($index)
        }
    }

    $ready = [System.Collections.Generic.SortedSet[int]]::new()
    for ($index = 0; $index -lt $Nodes.Count; $index++) {
        if ($unmet[$index] -eq 0) { [void]$ready.Add($index) }
    }
    return [pscustomobject][ordered]@{
        Nodes = $Nodes
        IndexById = $indexById
        UnmetDependencies = $unmet
        Dependents = $dependents
        ReadyIndexes = $ready
        Completed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
}

function Complete-CapsulenvTestDagNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$NodeId
    )

    if (-not $State.IndexById.ContainsKey($NodeId)) { throw "Unknown test DAG node id: $NodeId" }
    if (-not $State.Completed.Add($NodeId)) { throw "Test DAG node completed more than once: $NodeId" }
    $nodeIndex = [int]$State.IndexById[$NodeId]
    [void]$State.ReadyIndexes.Remove($nodeIndex)
    foreach ($dependentIndex in @($State.Dependents[$NodeId])) {
        $State.UnmetDependencies[$dependentIndex]--
        if ($State.UnmetDependencies[$dependentIndex] -lt 0) {
            throw ("Test DAG dependency count underflow for node '{0}'." -f $State.Nodes[$dependentIndex].Id)
        }
        if ($State.UnmetDependencies[$dependentIndex] -eq 0) {
            [void]$State.ReadyIndexes.Add([int]$dependentIndex)
        }
    }
}
