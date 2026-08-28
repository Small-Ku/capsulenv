function New-CapsulenvDesiredStateNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string[]]$DependsOn = @(),
        [Parameter(Mandatory = $true)][scriptblock]$Plan,
        [Parameter(Mandatory = $true)][scriptblock]$Apply,
        [Parameter(Mandatory = $true)][scriptblock]$Verify
    )
    return [pscustomobject][ordered]@{ Id=$Id; DependsOn=[string[]]@($DependsOn); Plan=$Plan; Apply=$Apply; Verify=$Verify }
}

function Resolve-CapsulenvDesiredStateOrder {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Nodes)
    $byId = @{}
    foreach ($node in $Nodes) {
        $id = [string]$node.Id
        if ([string]::IsNullOrWhiteSpace($id)) { throw 'Desired-state node id cannot be empty.' }
        if ($byId.ContainsKey($id)) { throw "Duplicate desired-state node id: $id" }
        $byId[$id] = $node
    }
    foreach ($node in $Nodes) {
        foreach ($dependency in @($node.DependsOn)) {
            if (-not $byId.ContainsKey([string]$dependency)) { throw "Desired-state node '$($node.Id)' depends on missing node '$dependency'." }
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
        if ($selectedIndex -lt 0) { throw "Desired-state graph contains a dependency cycle: $(@($remaining.Id) -join ', ')" }
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
            $decision = [pscustomobject][ordered]@{ Id=$node.Id; Node=$node; Operation='Blocked'; CanApply=$false; Reason=("Blocked by dependency: {0}" -f ($blockedBy -join ', ')); Current=$null; Desired=$null }
        } else {
            $raw = & $node.Plan $Context
            if ($null -eq $raw) { throw "Desired-state node '$($node.Id)' returned no plan decision." }
            $operation = [string]$raw.Operation
            if ($operation -notin @('NoOp','Apply','Blocked')) { throw "Desired-state node '$($node.Id)' returned unsupported operation '$operation'." }
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
    return [pscustomobject][ordered]@{ Nodes=$items; CanApply=(@($items | Where-Object { -not $_.CanApply }).Count -eq 0) }
}

function Invoke-CapsulenvDesiredStatePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan, [AllowNull()][hashtable]$Context = $null)
    if ($null -eq $Context) { $Context = @{} }
    if (-not $Context.ContainsKey('Outputs')) { $Context['Outputs'] = @{} }
    $blocked = @($Plan.Nodes | Where-Object { -not $_.CanApply })
    if ($blocked.Count -gt 0) {
        throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.DesiredState.Blocked' -Message "Desired-state plan is blocked by $($blocked.Count) node(s)." -Context ([ordered]@{ NodeIds=@($blocked.Id) }))
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
            if (-not $verified) { throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.DesiredState.VerifyFailed' -Message "Desired-state verification failed: $($decision.Id)" -TargetObject $decision.Id) }
            $results.Add([pscustomobject][ordered]@{ Id=$decision.Id; Operation='Apply'; Applied=$true; Verified=$true; Output=$output })
        } catch {
            throw (ConvertTo-CapsulenvDiagnosticErrorRecord -ErrorRecord $_ -Id 'Capsulenv.DesiredState.ApplyFailed' -Message "Desired-state apply failed: $($decision.Id)" -TargetObject $decision.Id -Context ([ordered]@{ NodeId=$decision.Id }))
        }
    }
    return $results.ToArray()
}
