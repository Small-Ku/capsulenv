function Normalize-CapsulenvDesiredStateResourceUri {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ResourceUri)

    $value = $ResourceUri.Trim()
    if ([string]::IsNullOrWhiteSpace($value) -or $value -notmatch '^[A-Za-z][A-Za-z0-9+.-]*:///.+') {
        throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.DesiredState.ResourceUriInvalid' -Message ("Desired-state resource claim is not a valid absolute resource URI: {0}" -f $ResourceUri) -TargetObject $ResourceUri -Remediation @('Use a stable resource URI such as capsule:///tool-data, host:///environment/user, or process:///environment.'))
    }
    $separator = $value.IndexOf(':///')
    $scheme = $value.Substring(0, $separator).ToLowerInvariant()
    $tail = $value.Substring($separator + 4).Replace('\', '/').Trim('/')
    return ('{0}:///{1}' -f $scheme, $tail)
}

function Get-CapsulenvDesiredStateResourcePathParts {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ResourceUri)

    $normalized = Normalize-CapsulenvDesiredStateResourceUri -ResourceUri $ResourceUri
    $separator = $normalized.IndexOf(':///')
    $scheme = $normalized.Substring(0, $separator)
    $tail = $normalized.Substring($separator + 4)
    $segments = if ([string]::IsNullOrWhiteSpace($tail)) { @() } else { @($tail -split '/') }
    return [pscustomobject][ordered]@{ Uri=$normalized; Scheme=$scheme; Segments=[string[]]$segments }
}

function Test-CapsulenvDesiredStateResourceOverlap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LeftResourceUri,
        [Parameter(Mandatory = $true)][string]$RightResourceUri
    )

    $left = Get-CapsulenvDesiredStateResourcePathParts -ResourceUri $LeftResourceUri
    $right = Get-CapsulenvDesiredStateResourcePathParts -ResourceUri $RightResourceUri
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$left.Scheme, [string]$right.Scheme)) { return $false }
    $count = [Math]::Min($left.Segments.Count, $right.Segments.Count)
    for ($index = 0; $index -lt $count; $index++) {
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$left.Segments[$index], [string]$right.Segments[$index])) { return $false }
    }
    return $true
}

function Get-CapsulenvDesiredStateResourceClaims {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Node)

    $write = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($resource in @($Node.WriteResources)) { [void]$write.Add((Normalize-CapsulenvDesiredStateResourceUri -ResourceUri ([string]$resource))) }
    $claims = New-Object System.Collections.Generic.List[object]
    foreach ($resource in @($Node.ReadResources)) {
        $normalized = Normalize-CapsulenvDesiredStateResourceUri -ResourceUri ([string]$resource)
        if (-not $write.Contains($normalized)) { $claims.Add([pscustomobject][ordered]@{ NodeId=[string]$Node.Id; ResourceUri=$normalized; Access='Read' }) }
    }
    foreach ($resource in $write) { $claims.Add([pscustomobject][ordered]@{ NodeId=[string]$Node.Id; ResourceUri=$resource; Access='Write' }) }
    return $claims.ToArray()
}

function Test-CapsulenvDesiredStateResourceConflict {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Left, [Parameter(Mandatory = $true)]$Right)

    $leftClaims = @(Get-CapsulenvDesiredStateResourceClaims -Node $Left)
    $rightClaims = @(Get-CapsulenvDesiredStateResourceClaims -Node $Right)
    foreach ($leftClaim in $leftClaims) {
        foreach ($rightClaim in $rightClaims) {
            if (-not (Test-CapsulenvDesiredStateResourceOverlap -LeftResourceUri ([string]$leftClaim.ResourceUri) -RightResourceUri ([string]$rightClaim.ResourceUri))) { continue }
            if ($leftClaim.Access -eq 'Write' -or $rightClaim.Access -eq 'Write') { return $true }
        }
    }
    return $false
}

function Test-CapsulenvDesiredStateDependencyPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Node,
        [Parameter(Mandatory = $true)][string]$DependencyId,
        [Parameter(Mandatory = $true)][hashtable]$NodesById
    )

    $pending = New-Object System.Collections.Generic.Stack[string]
    foreach ($dependency in @($Node.DependsOn)) { $pending.Push([string]$dependency) }
    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        if (-not $visited.Add($current)) { continue }
        if ([System.StringComparer]::OrdinalIgnoreCase.Equals($current, $DependencyId)) { return $true }
        if ($NodesById.ContainsKey($current)) {
            foreach ($dependency in @($NodesById[$current].DependsOn)) { $pending.Push([string]$dependency) }
        }
    }
    return $false
}

function Get-CapsulenvDesiredStateResourceConflicts {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Decisions)

    $nodesById = @{}
    foreach ($decision in $Decisions) { $nodesById[[string]$decision.Id] = $decision.Node }
    $conflicts = New-Object System.Collections.Generic.List[object]
    for ($leftIndex = 0; $leftIndex -lt $Decisions.Count; $leftIndex++) {
        $leftDecision = $Decisions[$leftIndex]
        if (-not $leftDecision.CanApply -or $leftDecision.Operation -ne 'Apply') { continue }
        $leftClaims = @(Get-CapsulenvDesiredStateResourceClaims -Node $leftDecision.Node)
        for ($rightIndex = $leftIndex + 1; $rightIndex -lt $Decisions.Count; $rightIndex++) {
            $rightDecision = $Decisions[$rightIndex]
            if (-not $rightDecision.CanApply -or $rightDecision.Operation -ne 'Apply') { continue }
            $rightClaims = @(Get-CapsulenvDesiredStateResourceClaims -Node $rightDecision.Node)
            foreach ($leftClaim in $leftClaims) {
                foreach ($rightClaim in $rightClaims) {
                    if ($leftClaim.Access -ne 'Write' -and $rightClaim.Access -ne 'Write') { continue }
                    if (-not (Test-CapsulenvDesiredStateResourceOverlap -LeftResourceUri ([string]$leftClaim.ResourceUri) -RightResourceUri ([string]$rightClaim.ResourceUri))) { continue }
                    $leftAfterRight = Test-CapsulenvDesiredStateDependencyPath -Node $leftDecision.Node -DependencyId ([string]$rightDecision.Id) -NodesById $nodesById
                    $rightAfterLeft = Test-CapsulenvDesiredStateDependencyPath -Node $rightDecision.Node -DependencyId ([string]$leftDecision.Id) -NodesById $nodesById
                    $conflicts.Add([pscustomobject][ordered]@{
                        LeftNodeId=[string]$leftDecision.Id
                        RightNodeId=[string]$rightDecision.Id
                        LeftResourceUri=[string]$leftClaim.ResourceUri
                        RightResourceUri=[string]$rightClaim.ResourceUri
                        LeftAccess=[string]$leftClaim.Access
                        RightAccess=[string]$rightClaim.Access
                        Kind=if($leftClaim.Access -eq 'Write' -and $rightClaim.Access -eq 'Write'){'WriteWrite'}else{'ReadWrite'}
                        OrderedByDependency=($leftAfterRight -or $rightAfterLeft)
                    })
                }
            }
        }
    }
    return $conflicts.ToArray()
}

function Assert-CapsulenvDesiredStateParallelSafety {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Decisions)

    foreach ($decision in $Decisions) {
        if (-not [bool]$decision.Node.ParallelSafe -or $decision.Operation -ne 'Apply' -or -not $decision.CanApply) { continue }
        $claims = @(Get-CapsulenvDesiredStateResourceClaims -Node $decision.Node)
        if ($claims.Count -eq 0) {
            throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.DesiredState.ParallelClaimsRequired' -Message ("Parallel-safe desired-state node '{0}' must declare at least one resource claim." -f $decision.Id) -TargetObject $decision.Id -Remediation @('Declare every resource read/write used by the node, or leave the node sequential.'))
        }
        $processClaims = @($claims | Where-Object { ([string]$_.ResourceUri).StartsWith('process:///', [System.StringComparison]::OrdinalIgnoreCase) })
        if ($processClaims.Count -gt 0) {
            throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.DesiredState.ParallelProcessResource' -Message ("Parallel-safe desired-state node '{0}' claims process-scoped state and cannot safely run in a worker runspace." -f $decision.Id) -TargetObject $decision.Id -Context ([ordered]@{ Resources=@($processClaims.ResourceUri) }) -Remediation @('Keep process-scoped mutations sequential.'))
        }
    }
}

function Get-CapsulenvDesiredStateExecutionWaves {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Decisions)

    $pending = New-Object System.Collections.Generic.List[object]
    $pendingNoOp = New-Object System.Collections.Generic.List[object]
    foreach ($decision in $Decisions) {
        if (-not $decision.CanApply) { continue }
        if ($decision.Operation -eq 'Apply') { $pending.Add($decision) }
        elseif ($decision.Operation -eq 'NoOp') { $pendingNoOp.Add($decision) }
    }
    $completed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $waves = New-Object System.Collections.Generic.List[object]
    $waveIndex = 0
    while ($pending.Count -gt 0 -or $pendingNoOp.Count -gt 0) {
        $advancedNoOp = $true
        while ($advancedNoOp) {
            $advancedNoOp = $false
            foreach ($decision in @($pendingNoOp.ToArray())) {
                $ready = $true
                foreach ($dependency in @($decision.Node.DependsOn)) {
                    if (-not $completed.Contains([string]$dependency)) { $ready = $false; break }
                }
                if ($ready) {
                    [void]$completed.Add([string]$decision.Id)
                    [void]$pendingNoOp.Remove($decision)
                    $advancedNoOp = $true
                }
            }
        }
        if ($pending.Count -eq 0) { break }

        $selected = New-Object System.Collections.Generic.List[object]
        foreach ($decision in @($pending.ToArray())) {
            $ready = $true
            foreach ($dependency in @($decision.Node.DependsOn)) {
                if (-not $completed.Contains([string]$dependency)) { $ready = $false; break }
            }
            if (-not $ready) { continue }
            $conflict = $false
            foreach ($existing in $selected.ToArray()) {
                if (Test-CapsulenvDesiredStateResourceConflict -Left $decision.Node -Right $existing.Node) { $conflict = $true; break }
            }
            if (-not $conflict) { $selected.Add($decision) }
        }
        if ($selected.Count -eq 0) {
            throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.DesiredState.WaveResolutionFailed' -Message 'Desired-state execution waves could not be resolved from the planned dependency graph.' -Context ([ordered]@{ PendingNodeIds=@($pending.Id); PendingNoOpNodeIds=@($pendingNoOp.Id) }))
        }
        $claims = New-Object System.Collections.Generic.List[object]
        foreach ($decision in $selected.ToArray()) { foreach ($claim in @(Get-CapsulenvDesiredStateResourceClaims -Node $decision.Node)) { $claims.Add($claim) } }
        $waves.Add([pscustomobject][ordered]@{ Index=$waveIndex; NodeIds=[string[]]@($selected.Id); ParallelNodeIds=[string[]]@($selected | Where-Object { [bool]$_.Node.ParallelSafe } | ForEach-Object { [string]$_.Id }); SequentialNodeIds=[string[]]@($selected | Where-Object { -not [bool]$_.Node.ParallelSafe } | ForEach-Object { [string]$_.Id }); ResourceClaims=$claims.ToArray() })
        foreach ($decision in $selected.ToArray()) { [void]$completed.Add([string]$decision.Id); [void]$pending.Remove($decision) }
        $waveIndex++
    }
    if ($pendingNoOp.Count -gt 0) {
        throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.DesiredState.WaveResolutionFailed' -Message 'Desired-state no-op dependencies could not be resolved from the planned dependency graph.' -Context ([ordered]@{ PendingNoOpNodeIds=@($pendingNoOp.Id) }))
    }
    return $waves.ToArray()
}

function New-CapsulenvDesiredStateNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string[]]$DependsOn = @(),
        [AllowEmptyCollection()][string[]]$ReadResources = @(),
        [AllowEmptyCollection()][string[]]$WriteResources = @(),
        [switch]$ParallelSafe,
        [Parameter(Mandatory = $true)][scriptblock]$Plan,
        [Parameter(Mandatory = $true)][scriptblock]$Apply,
        [Parameter(Mandatory = $true)][scriptblock]$Verify
    )
    foreach ($resource in @($ReadResources) + @($WriteResources)) { [void](Normalize-CapsulenvDesiredStateResourceUri -ResourceUri ([string]$resource)) }
    return [pscustomobject][ordered]@{
        Id=$Id; DependsOn=[string[]]@($DependsOn)
        ReadResources=[string[]]@($ReadResources); WriteResources=[string[]]@($WriteResources); ParallelSafe=[bool]$ParallelSafe
        Plan=$Plan; Apply=$Apply; Verify=$Verify
    }
}

function Resolve-CapsulenvDesiredStateOrder {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Nodes)
    $byId = @{}
    foreach ($node in $Nodes) {
        $id = [string]$node.Id
        if ([string]::IsNullOrWhiteSpace($id)) { throw '[[CapsulenvText:DesiredState.NodeIdEmpty]]' }
        if ($byId.ContainsKey($id)) { throw ('[[CapsulenvText:DesiredState.DuplicateNode]]' -f $id) }
        $byId[$id] = $node
    }
    foreach ($node in $Nodes) {
        foreach ($dependency in @($node.DependsOn)) {
            if (-not $byId.ContainsKey([string]$dependency)) { throw ('[[CapsulenvText:DesiredState.MissingDependency]]' -f $node.Id, $dependency) }
        }
    }
    $remaining = New-Object System.Collections.Generic.List[object]
    foreach ($node in $Nodes) { $remaining.Add($node) }
    $ordered = New-Object System.Collections.Generic.List[object]
    $resolved = @{}
    while ($remaining.Count -gt 0) {
        $selectedIndex = -1
        for ($index = 0; $index -lt $remaining.Count; $index++) {
            $ready = $true
            foreach ($dependency in @($remaining[$index].DependsOn)) { if (-not $resolved.ContainsKey([string]$dependency)) { $ready = $false; break } }
            if ($ready) { $selectedIndex = $index; break }
        }
        if ($selectedIndex -lt 0) { throw ('[[CapsulenvText:DesiredState.DependencyCycle]]' -f (@($remaining.Id) -join ', ')) }
        $selected = $remaining[$selectedIndex]
        $ordered.Add($selected); $resolved[[string]$selected.Id] = $true; $remaining.RemoveAt($selectedIndex)
    }
    return $ordered.ToArray()
}

function Get-CapsulenvDesiredStatePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Nodes, [AllowNull()][hashtable]$Context = $null)
    if ($null -eq $Context) { $Context = @{} }
    $ordered = @(Resolve-CapsulenvDesiredStateOrder -Nodes $Nodes)
    $decisions = [ordered]@{}
    foreach ($node in $ordered) {
        $blockedBy = @($node.DependsOn | Where-Object { $decisions.Contains([string]$_) -and -not [bool]$decisions[[string]$_].CanApply })
        if ($blockedBy.Count -gt 0) {
            $decision = [pscustomobject][ordered]@{ Id=$node.Id; Node=$node; Operation='Blocked'; CanApply=$false; Reason=('[[CapsulenvText:DesiredState.BlockedByDependency]]' -f ($blockedBy -join ', ')); Current=$null; Desired=$null }
        } else {
            $raw = & $node.Plan $Context
            if ($null -eq $raw) { throw ('[[CapsulenvText:DesiredState.NoPlanDecision]]' -f $node.Id) }
            $operation = [string]$raw.Operation
            if ($operation -notin @('NoOp','Apply','Blocked')) { throw ('[[CapsulenvText:DesiredState.UnsupportedOperation]]' -f $node.Id, $operation) }
            $canApply = if ($null -ne $raw.PSObject.Properties['CanApply']) { [bool]$raw.CanApply } else { $operation -ne 'Blocked' }
            $decision = [pscustomobject][ordered]@{
                Id=$node.Id; Node=$node; Operation=$operation; CanApply=$canApply
                Reason=if($null -ne $raw.PSObject.Properties['Reason']){[string]$raw.Reason}else{''}
                Current=if($null -ne $raw.PSObject.Properties['Current']){$raw.Current}else{$null}
                Desired=if($null -ne $raw.PSObject.Properties['Desired']){$raw.Desired}else{$null}
            }
        }
        $decisions[[string]$node.Id] = $decision
    }
    $items = @($decisions.Values)
    Assert-CapsulenvDesiredStateParallelSafety -Decisions $items
    $resourceConflicts = @(Get-CapsulenvDesiredStateResourceConflicts -Decisions $items)
    $claims = New-Object System.Collections.Generic.List[object]
    foreach ($item in $items) { foreach ($claim in @(Get-CapsulenvDesiredStateResourceClaims -Node $item.Node)) { $claims.Add($claim) } }
    $waves = if (@($items | Where-Object { -not $_.CanApply }).Count -eq 0) { @(Get-CapsulenvDesiredStateExecutionWaves -Decisions $items) } else { @() }
    return [pscustomobject][ordered]@{
        Nodes=$items
        CanApply=(@($items | Where-Object { -not $_.CanApply }).Count -eq 0)
        ResourceClaims=$claims.ToArray()
        ResourceConflicts=$resourceConflicts
        OwnershipDiagnostics=[pscustomobject][ordered]@{
            UnorderedWriteWrite=@($resourceConflicts | Where-Object { $_.Kind -eq 'WriteWrite' -and -not $_.OrderedByDependency })
            SerializedConflicts=@($resourceConflicts | Where-Object { $_.OrderedByDependency })
        }
        ExecutionWaves=$waves
    }
}

function Copy-CapsulenvDesiredStateWorkerContext {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $copy = @{}
    foreach ($key in @($Context.Keys)) {
        if ([System.StringComparer]::OrdinalIgnoreCase.Equals([string]$key, 'Outputs')) {
            $outputs = @{}
            foreach ($outputKey in @($Context.Outputs.Keys)) { $outputs[[string]$outputKey] = $Context.Outputs[$outputKey] }
            $copy['Outputs'] = $outputs
        } else {
            $copy[$key] = $Context[$key]
        }
    }
    if (-not $copy.ContainsKey('Outputs')) { $copy['Outputs'] = @{} }
    return $copy
}

function Invoke-CapsulenvDesiredStateDecisionSequential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Decision,
        [Parameter(Mandatory = $true)][hashtable]$Context
    )

    try {
        $output = & $Decision.Node.Apply $Context $Decision
        $verified = [bool](& $Decision.Node.Verify $Context $Decision $output)
        if (-not $verified) {
            throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.DesiredState.VerifyFailed' -Message ('[[CapsulenvText:DesiredState.VerifyFailed]]' -f $Decision.Id) -TargetObject $Decision.Id)
        }
        return [pscustomobject][ordered]@{ Id=$Decision.Id; Operation='Apply'; Applied=$true; Verified=$true; Output=$output }
    } catch {
        throw (ConvertTo-CapsulenvDiagnosticErrorRecord `
            -ErrorRecord $_ `
            -Id 'Capsulenv.DesiredState.ApplyFailed' `
            -Message ('[[CapsulenvText:DesiredState.ApplyFailed]]' -f $Decision.Id) `
            -TargetObject $Decision.Id `
            -Context ([ordered]@{ NodeId=$Decision.Id }) `
            -Remediation @(
                "Run 'capsulenv.cmd doctor' to inspect the affected ownership boundary.",
                "Set CAPSULENV_DEBUG=1 and rerun the command to expose the underlying PowerShell error record."
            ))
    }
}

function Invoke-CapsulenvDesiredStateParallelBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Decisions,
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [ValidateRange(1, 32)][int]$ThrottleLimit = 4
    )

    if ($Decisions.Count -eq 0) { return @() }
    if ($Decisions.Count -eq 1) { return @(Invoke-CapsulenvDesiredStateDecisionSequential -Decision $Decisions[0] -Context $Context) }

    $loadedModules = @(Get-Module Capsulenv)
    $module = if ($loadedModules.Count -gt 0) { $loadedModules[0] } else { $null }
    if ($null -eq $module -or [string]::IsNullOrWhiteSpace([string]$module.Path)) {
        throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.DesiredState.ParallelModuleUnavailable' -Message 'Parallel desired-state execution requires the loaded Capsulenv module to have a module path.' -Remediation @('Run desired-state execution through the built/imported Capsulenv module, or use sequential execution.'))
    }

    $initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $initialSessionState.ImportPSModule(@([string]$module.Path))
    $maximum = [Math]::Min($ThrottleLimit, $Decisions.Count)
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $maximum, $initialSessionState, $Host)
    $jobs = New-Object System.Collections.Generic.List[object]
    $workerScript = @'
param($Node, $Context, $Decision)
try {
    $output = & $Node.Apply $Context $Decision
    $verified = [bool](& $Node.Verify $Context $Decision $output)
    [pscustomobject][ordered]@{
        Success = $verified
        Output = $output
        FailureId = if ($verified) { '' } else { 'Capsulenv.DesiredState.VerifyFailed' }
        FailureMessage = if ($verified) { '' } else { "Verification returned false for desired-state node '$($Decision.Id)'." }
    }
} catch {
    [pscustomobject][ordered]@{
        Success = $false
        Output = $null
        FailureId = [string]$_.FullyQualifiedErrorId
        FailureMessage = [string]$_.Exception.Message
    }
}
'@
    try {
        $pool.Open()
        foreach ($decision in $Decisions) {
            $powershell = [PowerShell]::Create()
            $powershell.RunspacePool = $pool
            $workerContext = Copy-CapsulenvDesiredStateWorkerContext -Context $Context
            [void]$powershell.AddScript($workerScript).AddArgument($decision.Node).AddArgument($workerContext).AddArgument($decision)
            $async = $powershell.BeginInvoke()
            $jobs.Add([pscustomobject]@{ Decision=$decision; PowerShell=$powershell; Async=$async })
        }

        $results = New-Object System.Collections.Generic.List[object]
        foreach ($job in $jobs.ToArray()) {
            $workerOutput = @($job.PowerShell.EndInvoke($job.Async))
            $worker = if ($workerOutput.Count -gt 0) { $workerOutput[$workerOutput.Count - 1] } else { $null }
            if ($null -eq $worker) {
                throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.DesiredState.ParallelWorkerNoResult' -Message ("Parallel worker returned no result for desired-state node '{0}'." -f $job.Decision.Id) -TargetObject $job.Decision.Id)
            }
            if (-not [bool]$worker.Success) {
                throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.DesiredState.ApplyFailed' -Message ('[[CapsulenvText:DesiredState.ApplyFailed]]' -f $job.Decision.Id) -TargetObject $job.Decision.Id -Context ([ordered]@{ NodeId=[string]$job.Decision.Id; WorkerFailureId=[string]$worker.FailureId; WorkerFailureMessage=[string]$worker.FailureMessage }))
            }
            $results.Add([pscustomobject][ordered]@{ Id=$job.Decision.Id; Operation='Apply'; Applied=$true; Verified=$true; Output=$worker.Output })
        }
        return $results.ToArray()
    } finally {
        foreach ($job in $jobs.ToArray()) {
            if ($null -ne $job.PowerShell) { $job.PowerShell.Dispose() }
        }
        if ($null -ne $pool) { $pool.Dispose() }
    }
}

function Invoke-CapsulenvDesiredStatePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [AllowNull()][hashtable]$Context = $null,
        [ValidateSet('Auto','Sequential','Parallel')][string]$ExecutionMode = 'Auto',
        [ValidateRange(1, 32)][int]$ThrottleLimit = 4
    )
    if ($null -eq $Context) { $Context = @{} }
    if (-not $Context.ContainsKey('Outputs')) { $Context['Outputs'] = @{} }
    $blocked = @($Plan.Nodes | Where-Object { -not $_.CanApply })
    if ($blocked.Count -gt 0) {
        throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.DesiredState.Blocked' -Message ('[[CapsulenvText:DesiredState.PlanBlocked]]' -f $blocked.Count) -Context ([ordered]@{ NodeIds=@($blocked.Id) }))
    }

    $resultsById = @{}
    foreach ($decision in @($Plan.Nodes | Where-Object { $_.Operation -eq 'NoOp' })) {
        $resultsById[[string]$decision.Id] = [pscustomobject][ordered]@{ Id=$decision.Id; Operation='NoOp'; Applied=$false; Verified=$true; Output=$null }
    }

    if ($ExecutionMode -eq 'Sequential') {
        foreach ($decision in @($Plan.Nodes | Where-Object { $_.Operation -eq 'Apply' })) {
            $result = Invoke-CapsulenvDesiredStateDecisionSequential -Decision $decision -Context $Context
            $Context.Outputs[[string]$decision.Id] = $result.Output
            $resultsById[[string]$decision.Id] = $result
        }
    } else {
        $decisionsById = @{}
        foreach ($decision in @($Plan.Nodes)) { $decisionsById[[string]$decision.Id] = $decision }
        foreach ($wave in @($Plan.ExecutionWaves)) {
            $parallel = New-Object System.Collections.Generic.List[object]
            $sequential = New-Object System.Collections.Generic.List[object]
            foreach ($nodeId in @($wave.NodeIds)) {
                $decision = $decisionsById[[string]$nodeId]
                if ([bool]$decision.Node.ParallelSafe) { $parallel.Add($decision) } else { $sequential.Add($decision) }
            }

            foreach ($decision in $sequential.ToArray()) {
                $result = Invoke-CapsulenvDesiredStateDecisionSequential -Decision $decision -Context $Context
                $Context.Outputs[[string]$decision.Id] = $result.Output
                $resultsById[[string]$decision.Id] = $result
            }

            if ($parallel.Count -gt 0) {
                $batchResults = if ($ExecutionMode -eq 'Parallel' -or $parallel.Count -gt 1) {
                    @(Invoke-CapsulenvDesiredStateParallelBatch -Decisions $parallel.ToArray() -Context $Context -ThrottleLimit $ThrottleLimit)
                } else {
                    @(Invoke-CapsulenvDesiredStateDecisionSequential -Decision $parallel[0] -Context $Context)
                }
                foreach ($result in $batchResults) {
                    $Context.Outputs[[string]$result.Id] = $result.Output
                    $resultsById[[string]$result.Id] = $result
                }
            }
        }
    }

    $orderedResults = New-Object System.Collections.Generic.List[object]
    foreach ($decision in @($Plan.Nodes)) {
        if ($resultsById.ContainsKey([string]$decision.Id)) { $orderedResults.Add($resultsById[[string]$decision.Id]) }
    }
    return $orderedResults.ToArray()
}
