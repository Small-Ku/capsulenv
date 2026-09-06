function Get-CapsulenvPackageExecutionNodeId {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Reference)

    return ('package-install:{0}' -f $Reference.ToLowerInvariant())
}

function Get-CapsulenvPortablePackageExecutionClaims {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan)

    $reads = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $writes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    [void]$reads.Add(('capsule:///packages/source-manifests/{0}/{1}' -f ([string]$Plan.Bucket).ToLowerInvariant(), ([string]$Plan.Name).ToLowerInvariant()))
    [void]$reads.Add('capsule:///state/identity')

    $name = [Uri]::EscapeDataString(([string]$Plan.Name).ToLowerInvariant())
    [void]$writes.Add(('capsule:///packages/content/{0}' -f $name))
    [void]$writes.Add(('capsule:///packages/persist/{0}' -f $name))
    [void]$writes.Add(('capsule:///packages/installed-state/{0}' -f $name))

    foreach ($download in @($Plan.Downloads)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$download.Hash)) {
            [void]$writes.Add(('capsule:///packages/cache/{0}' -f ([string]$download.Hash).ToLowerInvariant()))
        }
    }

    $aliases = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($alias in @(Get-CapsulenvPackagePlanExecutableAliases -Package $Plan)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$alias)) { [void]$aliases.Add([string]$alias) }
    }
    $existing = Get-CapsulenvInstalledPackageState -Name ([string]$Plan.Name) -AllowMissing
    if ($null -ne $existing) {
        foreach ($alias in @($existing.Shims)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$alias)) { [void]$aliases.Add([string]$alias) }
        }
    }
    foreach ($alias in $aliases) {
        # Shim aliases are validated as package executable names before a plan
        # reaches PortableSafe execution, so each alias forms a stable leaf
        # ownership boundary in the shared shim namespace.
        [void]$writes.Add(('capsule:///packages/shims/{0}' -f [Uri]::EscapeDataString(([string]$alias).ToLowerInvariant())))
    }

    return [pscustomobject][ordered]@{
        ReadResources = [string[]]@($reads | Sort-Object)
        WriteResources = [string[]]@($writes | Sort-Object)
    }
}

function Get-CapsulenvPortablePackageExecutionDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][hashtable]$NodeIdByReference
    )

    $dependencies = New-Object System.Collections.Generic.List[string]
    foreach ($dependency in @($Plan.Dependencies)) {
        $resolved = Resolve-CapsulenvPackageDependencyReference -Dependency ([string]$dependency) -ParentPlan $Plan
        $canonical = [string](Get-CapsulenvPackageManifestPlan -Reference $resolved).Reference
        $key = $canonical.ToLowerInvariant()
        if (-not $NodeIdByReference.ContainsKey($key)) {
            throw "Package execution graph is missing planned dependency '$canonical' required by '$($Plan.Reference)'."
        }
        $dependencies.Add([string]$NodeIdByReference[$key])
    }
    return [string[]]$dependencies.ToArray()
}

function Get-CapsulenvPortablePackageDesiredStatePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$InstallPlan,
        [switch]$AllowSourceManifestReplacement,
        [switch]$IncludeDiagnostics
    )

    if ([string]$InstallPlan.Classification -ne 'PortableSafe') {
        throw "Portable package execution graph requires a PortableSafe install plan: $($InstallPlan.Reference)"
    }

    # Initialize all process-wide worker prerequisites in the parent before
    # package nodes are constructed or dispatched.
    Initialize-CapsulenvPortablePackageWorkerRuntime

    $nodeIdByReference = @{}
    $packagePlans = @{}
    foreach ($package in @($InstallPlan.Packages)) {
        if ([string]$package.Classification -ne 'PortableSafe') {
            throw "Package '$($package.Reference)' is not PortableSafe: $($package.Classification)"
        }
        $referenceKey = ([string]$package.Reference).ToLowerInvariant()
        $nodeId = Get-CapsulenvPackageExecutionNodeId -Reference ([string]$package.Reference)
        $nodeIdByReference[$referenceKey] = $nodeId
        $packagePlans[$nodeId] = $package
    }

    $nodes = New-Object System.Collections.Generic.List[object]
    foreach ($package in @($InstallPlan.Packages)) {
        $nodeId = [string]$nodeIdByReference[([string]$package.Reference).ToLowerInvariant()]
        $dependsOn = @(Get-CapsulenvPortablePackageExecutionDependencies -Plan $package -NodeIdByReference $nodeIdByReference)
        $claims = Get-CapsulenvPortablePackageExecutionClaims -Plan $package
        $nodes.Add((New-CapsulenvDesiredStateNode `
            -Id $nodeId `
            -DependsOn $dependsOn `
            -ReadResources @($claims.ReadResources) `
            -WriteResources @($claims.WriteResources) `
            -ExecutionAffinity AnyRunspace `
            -ConcurrencyPolicy ResourceBound `
            -Plan {
                param($c)
                return [pscustomobject][ordered]@{ Operation='Apply'; CanApply=$true; Reason='PortableSafe package execution'; Current=$null; Desired=$null }
            } `
            -Apply {
                param($c, $d)
                $packagePlan = $c.PackagePlans[[string]$d.Id]
                return Install-CapsulenvPortablePackageNode -Plan $packagePlan -AllowSourceManifestReplacement:([bool]$c.AllowSourceManifestReplacement)
            } `
            -Verify {
                param($c, $d, $output)
                if ($null -eq $output) { return $false }
                $expected = $c.PackagePlans[[string]$d.Id]
                return (
                    [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$output.Reference, [string]$expected.Reference) -and
                    [string]$output.Version -eq [string]$expected.Version
                )
            }
        ))
    }

    $context = @{
        PackagePlans = $packagePlans
        AllowSourceManifestReplacement = [bool]$AllowSourceManifestReplacement
        Outputs = @{}
    }
    $plan = Get-CapsulenvDesiredStatePlan -Nodes $nodes.ToArray() -Context $context -IncludeDiagnostics:$IncludeDiagnostics
    return [pscustomobject][ordered]@{
        Plan = $plan
        Context = $context
        NodeIds = [string[]]@($InstallPlan.Packages | ForEach-Object { [string]$nodeIdByReference[([string]$_.Reference).ToLowerInvariant()] })
    }
}

function Invoke-CapsulenvPortablePackageInstallPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$InstallPlan,
        [switch]$AllowSourceManifestReplacement,
        [ValidateRange(1, 32)][int]$ThrottleLimit = 4
    )

    $execution = Get-CapsulenvPortablePackageDesiredStatePlan `
        -InstallPlan $InstallPlan `
        -AllowSourceManifestReplacement:$AllowSourceManifestReplacement
    try {
        $results = @(Invoke-CapsulenvDesiredStatePlan `
            -Plan $execution.Plan `
            -Context $execution.Context `
            -ExecutionMode Auto `
            -ThrottleLimit $ThrottleLimit)
    } catch {
        # The desired-state coordinator deliberately sanitizes arbitrary worker
        # exceptions. PortableSafe package APIs historically surfaced the
        # package executor's own message directly, and those messages carry the
        # actionable ownership/hash/manifest failure. Restore that public
        # contract without retaining the worker exception object graph.
        $diagnostic = Get-CapsulenvDiagnosticContext -ErrorRecord $_
        if (
            $null -ne $diagnostic -and
            [string]$diagnostic.NodeId -like 'package-install:*' -and
            -not [string]::IsNullOrWhiteSpace([string]$diagnostic.WorkerFailureMessage)
        ) {
            throw [string]$diagnostic.WorkerFailureMessage
        }
        throw
    }

    $byId = @{}
    foreach ($result in $results) { $byId[[string]$result.Id] = $result }
    $outputs = New-Object System.Collections.Generic.List[object]
    foreach ($nodeId in @($execution.NodeIds)) {
        if (-not $byId.ContainsKey([string]$nodeId)) {
            throw "Package desired-state execution did not return node result: $nodeId"
        }
        $outputs.Add($byId[[string]$nodeId].Output)
    }
    return $outputs.ToArray()
}
