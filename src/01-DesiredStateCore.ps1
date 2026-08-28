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
            if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$leftClaim.ResourceUri, [string]$rightClaim.ResourceUri)) { continue }
            if ($leftClaim.Access -eq 'Write' -or $rightClaim.Access -eq 'Write') { return $true }
        }
    }
    return $false
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
        $waves.Add([pscustomobject][ordered]@{ Index=$waveIndex; NodeIds=[string[]]@($selected.Id); ResourceClaims=$claims.ToArray() })
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
        [Parameter(Mandatory = $true)][scriptblock]$Plan,
        [Parameter(Mandatory = $true)][scriptblock]$Apply,
        [Parameter(Mandatory = $true)][scriptblock]$Verify
    )
    foreach ($resource in @($ReadResources) + @($WriteResources)) { [void](Normalize-CapsulenvDesiredStateResourceUri -ResourceUri ([string]$resource)) }
    return [pscustomobject][ordered]@{
        Id=$Id; DependsOn=[string[]]@($DependsOn)
        ReadResources=[string[]]@($ReadResources); WriteResources=[string[]]@($WriteResources)
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
    $claims = New-Object System.Collections.Generic.List[object]
    foreach ($item in $items) { foreach ($claim in @(Get-CapsulenvDesiredStateResourceClaims -Node $item.Node)) { $claims.Add($claim) } }
    $waves = if (@($items | Where-Object { -not $_.CanApply }).Count -eq 0) { @(Get-CapsulenvDesiredStateExecutionWaves -Decisions $items) } else { @() }
    return [pscustomobject][ordered]@{
        Nodes=$items
        CanApply=(@($items | Where-Object { -not $_.CanApply }).Count -eq 0)
        ResourceClaims=$claims.ToArray()
        ExecutionWaves=$waves
    }
}

function Invoke-CapsulenvDesiredStatePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan, [AllowNull()][hashtable]$Context = $null)
    if ($null -eq $Context) { $Context = @{} }
    if (-not $Context.ContainsKey('Outputs')) { $Context['Outputs'] = @{} }
    $blocked = @($Plan.Nodes | Where-Object { -not $_.CanApply })
    if ($blocked.Count -gt 0) {
        throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.DesiredState.Blocked' -Message ('[[CapsulenvText:DesiredState.PlanBlocked]]' -f $blocked.Count) -Context ([ordered]@{ NodeIds=@($blocked.Id) }))
    }
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($decision in @($Plan.Nodes)) {
        if ($decision.Operation -eq 'NoOp') {
            $results.Add([pscustomobject][ordered]@{ Id=$decision.Id; Operation='NoOp'; Applied=$false; Verified=$true; Output=$null })
            continue
        }
        try {
            $output = & $decision.Node.Apply $Context $decision
            $Context.Outputs[[string]$decision.Id] = $output
            $verified = [bool](& $decision.Node.Verify $Context $decision $output)
            if (-not $verified) { throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.DesiredState.VerifyFailed' -Message ('[[CapsulenvText:DesiredState.VerifyFailed]]' -f $decision.Id) -TargetObject $decision.Id) }
            $results.Add([pscustomobject][ordered]@{ Id=$decision.Id; Operation='Apply'; Applied=$true; Verified=$true; Output=$output })
        } catch {
            throw (ConvertTo-CapsulenvDiagnosticErrorRecord -ErrorRecord $_ -Id 'Capsulenv.DesiredState.ApplyFailed' -Message ('[[CapsulenvText:DesiredState.ApplyFailed]]' -f $decision.Id) -TargetObject $decision.Id -Context ([ordered]@{ NodeId=$decision.Id }))
        }
    }
    return $results.ToArray()
}
