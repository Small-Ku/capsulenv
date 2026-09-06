function Get-CapsulenvScoopRoot {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    return Resolve-CapsulenvPath -Path $configuration.Scoop.Root -AllowMissing
}


function Get-CapsulenvScoopGlobalRoot {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    return Resolve-CapsulenvPath -Path $configuration.Scoop.GlobalRoot -AllowMissing
}

function Get-CapsulenvScoopExecutable {
    [CmdletBinding()]
    param()

    $scoopRoot = Get-CapsulenvScoopRoot
    $scoopAppRoot = Join-Path (Join-Path (Join-Path $scoopRoot 'apps') 'scoop') 'current'
    # Explicit TrustedExecution uses only Scoop's canonical dispatcher. A shim
    # is never an internal fallback because it may be stale or foreign-owned.
    $upstream = Join-Path (Join-Path $scoopAppRoot 'bin') 'scoop.ps1'
    if (Test-Path -LiteralPath $upstream -PathType Leaf) {
        return $upstream
    }
    return $null
}

function Invoke-CapsulenvScoopCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $scoop = Get-CapsulenvScoopExecutable
    if (-not $scoop) {
        throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Scoop.NotInstalled' -Message '[[CapsulenvText:Scoop.NotInstalled.Message]]' -TargetObject (Get-CapsulenvScoopRoot) -Remediation @('[[CapsulenvText:Scoop.NotInstalled.Remediation]]'))
    }

    Clear-CapsulenvLastExitCode
    $commandOutput = @(& $scoop @Arguments)
    $succeeded = $?
    if ($commandOutput.Count -gt 0) {
        $commandOutput | Out-Host
    }
    $exitCode = Get-CapsulenvLastExitCode -Succeeded $succeeded
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Scoop.CommandFailed' -Message ('[[CapsulenvText:Scoop.CommandFailed.Message]]' -f $exitCode) -TargetObject $scoop -Context ([ordered]@{ ExitCode=$exitCode }))
    }
    return $exitCode
}

function Reset-CapsulenvScoop {
    [CmdletBinding()]
    param(
        [string[]]$Apps = @('*'),
        [switch]$Quiet,
        [switch]$DeferRunningApps,
        [ValidateSet('ShellOnly', 'User')]
        [string]$IntegrationMode = (Get-CapsulenvInstallMode)
    )

    if (-not $Quiet) {
        Write-CapsulenvMessage -Level Info -Message 'Reconciling Capsulenv-owned package projections and bounded legacy Scoop current/persist links...'
    }
    return [bool](Repair-CapsulenvInstalledAppProjections `
        -Apps $Apps `
        -DeferRunningApps:($DeferRunningApps -and $IntegrationMode -eq 'User') `
        -IntegrationMode $IntegrationMode)
}

function Get-CapsulenvRehydrationStatePath {
    [CmdletBinding()]
    param()

    $context = Get-CapsulenvContext
    return Join-Path $context.StateRoot 'scoop-rehydration.json'
}

function Get-CapsulenvRelocationFingerprint {
    [CmdletBinding()]
    param()

    $context = Get-CapsulenvContext
    [ordered]@{
        CapsuleId = (Get-CapsulenvIdentity)
        Root = $context.Root
        ScoopRoot = (Get-CapsulenvScoopRoot)
        ScoopGlobalRoot = (Get-CapsulenvScoopGlobalRoot)
        ComputerName = [Environment]::MachineName
        User = ('{0}\{1}' -f [Environment]::UserDomainName, [Environment]::UserName)
    }
}

function Get-CapsulenvScoopRehydrationMarkerPaths {
    [CmdletBinding()]
    param(
        $Fingerprint = (Get-CapsulenvRelocationFingerprint),
        [string]$StatePath = (Get-CapsulenvRehydrationStatePath)
    )

    $payload = New-Object System.Collections.Generic.List[string]
    $payload.Add('scoop-rehydration-generation-schema=1')
    foreach ($name in @('CapsuleId', 'Root', 'ScoopRoot', 'ScoopGlobalRoot', 'ComputerName', 'User')) {
        $value = if ($Fingerprint -is [System.Collections.IDictionary]) {
            if ($Fingerprint.Contains($name)) { [string]$Fingerprint[$name] } else { '' }
        } else {
            $property = $Fingerprint.PSObject.Properties[$name]
            if ($null -ne $property) { [string]$property.Value } else { '' }
        }
        $payload.Add(('{0}={1}' -f $name, $value.ToLowerInvariant()))
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($payload -join "`n"))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
    $prefix = Join-Path (Split-Path -Parent $StatePath) ("scoop-rehydration-{0}" -f $hash.Substring(0, 16))
    return [pscustomobject][ordered]@{
        Ready = $prefix + '.ready'
        Pending = $prefix + '.pending'
    }
}

function Remove-CapsulenvScoopRehydrationMarker {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$MarkerPath)

    if (Test-Path -LiteralPath $MarkerPath -PathType Leaf) {
        Remove-Item -LiteralPath $MarkerPath -Force
    }
}

function Publish-CapsulenvScoopRehydrationMarker {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$MarkerPath)

    $markerRoot = Split-Path -Parent $MarkerPath
    if (-not (Test-Path -LiteralPath $markerRoot -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $markerRoot -Force)
    }
    # Marker content is not authority.  Existence after the already-atomic
    # detail-state commit is the generation signal, so an idempotent direct
    # write is safer under concurrent activations than a temp-file rename.
    [System.IO.File]::WriteAllText($MarkerPath, 'ready', [System.Text.UTF8Encoding]::new($false))
    return $MarkerPath
}

function Test-CapsulenvScoopRehydrationRequired {
    [CmdletBinding()]
    param()

    $markers = Get-CapsulenvScoopRehydrationMarkerPaths
    if (Test-Path -LiteralPath $markers.Pending -PathType Leaf) {
        return $true
    }
    return -not (Test-Path -LiteralPath $markers.Ready -PathType Leaf)
}

function ConvertTo-CapsulenvFingerprintSnapshot {
    [CmdletBinding()]
    param($Fingerprint)

    if ($null -eq $Fingerprint) {
        return $null
    }
    $snapshot = [ordered]@{}
    foreach ($name in @('CapsuleId', 'Root', 'ScoopRoot', 'ScoopGlobalRoot', 'ComputerName', 'User')) {
        if ($Fingerprint -is [System.Collections.IDictionary]) {
            if ($Fingerprint.Contains($name)) {
                $snapshot[$name] = [string]$Fingerprint[$name]
            }
            continue
        }
        $property = $Fingerprint.PSObject.Properties[$name]
        if ($null -ne $property) {
            $snapshot[$name] = [string]$property.Value
        }
    }
    return $snapshot
}

function Save-CapsulenvRehydrationState {
    [CmdletBinding()]
    param(
        $RelocationContext,
        $PersistRepairResult,
        [bool]$PendingProjectionRepair = $false,
        [AllowEmptyCollection()][object[]]$ProjectionRepairIssues = @()
    )

    $statePath = Get-CapsulenvRehydrationStatePath
    $stateDirectory = Split-Path -Parent $statePath
    [void](New-Item -ItemType Directory -Path $stateDirectory -Force)
    $state = Get-CapsulenvRelocationFingerprint
    $rehydrationMarkers = Get-CapsulenvScoopRehydrationMarkerPaths -Fingerprint $state -StatePath $statePath
    Remove-CapsulenvScoopRehydrationMarker -MarkerPath $rehydrationMarkers.Ready
    $state.Insert(0, 'SchemaVersion', 5)
    $state['PendingProjectionRepair'] = $PendingProjectionRepair
    $state['ProjectionRepairIssues'] = @(
        foreach ($issue in @($ProjectionRepairIssues)) {
            if ($null -eq $issue) { continue }
            [ordered]@{
                Selector = [string]$issue.Selector
                ErrorId = [string]$issue.ErrorId
                Summary = [string]$issue.Summary
                Remediation = [string[]]@($issue.Remediation)
                Retryable = [bool]$issue.Retryable
            }
        }
    )
    $state['CompletedAtUtc'] = [DateTime]::UtcNow.ToString('o')
    if ($null -ne $RelocationContext -and $RelocationContext.HasPathChanges) {
        $state['LastRelocation'] = [ordered]@{
            Previous = ConvertTo-CapsulenvFingerprintSnapshot -Fingerprint $RelocationContext.Previous
            Current = ConvertTo-CapsulenvFingerprintSnapshot -Fingerprint $RelocationContext.Current
            PersistFilesChanged = if ($null -ne $PersistRepairResult) { [int]$PersistRepairResult.FilesChanged } else { 0 }
            PersistReplacements = if ($null -ne $PersistRepairResult) { [int]$PersistRepairResult.Replacements } else { 0 }
        }
    } elseif ($null -ne $RelocationContext -and $null -ne $RelocationContext.Previous) {
        $lastRelocation = $null
        if ($RelocationContext.Previous -is [System.Collections.IDictionary]) {
            if ($RelocationContext.Previous.Contains('LastRelocation')) {
                $lastRelocation = $RelocationContext.Previous['LastRelocation']
            }
        } else {
            $lastProperty = $RelocationContext.Previous.PSObject.Properties['LastRelocation']
            if ($null -ne $lastProperty) {
                $lastRelocation = $lastProperty.Value
            }
        }
        if ($null -ne $lastRelocation) {
            $state['LastRelocation'] = $lastRelocation
        }
    }

    $json = $state | ConvertTo-Json -Depth 8
    [void]($json | ConvertFrom-Json)
    $token = [Guid]::NewGuid().ToString('N')
    $tempPath = Join-Path $stateDirectory ('.capsulenv-rehydration-{0}.tmp' -f $token)
    $rollbackPath = Join-Path $stateDirectory ('.capsulenv-rehydration-{0}.rollback' -f $token)
    [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($true))
    try {
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            [System.IO.File]::Replace($tempPath, $statePath, $rollbackPath, $true)
            if (Test-Path -LiteralPath $rollbackPath -PathType Leaf) {
                Remove-Item -LiteralPath $rollbackPath -Force
            }
        } else {
            [System.IO.File]::Move($tempPath, $statePath)
        }
    } finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $rollbackPath -PathType Leaf) {
            Remove-Item -LiteralPath $rollbackPath -Force -ErrorAction SilentlyContinue
        }
    }
    if ($PendingProjectionRepair) {
        [void](Publish-CapsulenvScoopRehydrationMarker -MarkerPath $rehydrationMarkers.Pending)
    } else {
        Remove-CapsulenvScoopRehydrationMarker -MarkerPath $rehydrationMarkers.Pending
        [void](Publish-CapsulenvScoopRehydrationMarker -MarkerPath $rehydrationMarkers.Ready)
    }
}

function Get-CapsulenvIntegrationDesiredStatePlan {
    [CmdletBinding()]
    param(
        [switch]$SkipPersistRepairs,
        [switch]$SkipToolRepairs,
        [switch]$StrictToolRepairs,
        [ValidateSet('ShellOnly', 'User')][string]$IntegrationMode = (Get-CapsulenvInstallMode),
        [bool]$RehydrationRequired = $false,
        [switch]$IncludeDiagnostics
    )

    # Process-wide worker prerequisites are initialized once in the parent
    # runspace before worker-dependent descriptors or nodes are constructed.
    Initialize-CapsulenvFileIdentityRuntime
    $relocationContext = Get-CapsulenvRelocationContext
    $toolRelocation = Get-CapsulenvToolRelocationConfiguration
    $context = @{
        RelocationContext=$relocationContext
        IntegrationMode=$IntegrationMode
        StrictToolRepairs=[bool]$StrictToolRepairs
        RehydrationRequired=[bool]$RehydrationRequired
    }
    $packageProjectionDescriptors = if ($RehydrationRequired) { @(Get-CapsulenvPackageProjectionRepairDescriptors -Apps @('*')) } else { @() }
    $packageProjectionDescriptorMap = @{}
    $packageProjectionNodeIds = New-Object System.Collections.Generic.List[string]
    $packageProjectionNodes = New-Object System.Collections.Generic.List[object]
    foreach ($descriptor in $packageProjectionDescriptors) {
        $scopeToken = [Uri]::EscapeDataString(([string]$descriptor.Scope).ToLowerInvariant())
        $nameToken = [Uri]::EscapeDataString([string]$descriptor.Name)
        $nodeId = ('package-projection:{0}:{1}' -f $scopeToken, $nameToken)
        $readResources = New-Object System.Collections.Generic.List[string]
        $writeResources = New-Object System.Collections.Generic.List[string]
        $writeResources.Add(('capsule:///scoop/apps/{0}/{1}' -f $scopeToken, $nameToken))
        $writeResources.Add(('capsule:///scoop/persist/{0}/{1}' -f $scopeToken, $nameToken))
        if ([string]$descriptor.Kind -eq 'Owned') {
            $readResources.Add(('capsule:///packages/installed-state/{0}' -f $nameToken))
            $readResources.Add(('capsule:///packages/persist/{0}' -f $nameToken))
            $writeResources.Add(('capsule:///packages/content/{0}' -f $nameToken))
            foreach ($alias in @($descriptor.Shims)) {
                $writeResources.Add(('capsule:///packages/shims/{0}' -f [Uri]::EscapeDataString([string]$alias)))
            }
        }
        $packageProjectionDescriptorMap[$nodeId] = $descriptor
        $packageProjectionNodeIds.Add($nodeId)
        $packageProjectionNodes.Add((New-CapsulenvDesiredStateNode -Id $nodeId -ExecutionAffinity AnyRunspace -ConcurrencyPolicy ResourceBound `
            -DependsOn @('session-environment','user-environment-backup') `
            -ReadResources $readResources.ToArray() `
            -WriteResources $writeResources.ToArray() `
            -Plan { param($c) [pscustomobject]@{ Operation='Apply'; CanApply=$true } } `
            -Apply { param($c,$d) Invoke-CapsulenvPackageProjectionDescriptor -Descriptor $c.PackageProjectionDescriptors[[string]$d.Id] -DeferRunningApps -DeferUnsafeLegacyProjectionFailures } `
            -Verify { param($c,$d,$o) $null -ne $o -and $null -ne $o.PSObject.Properties['Repaired'] }))
    }
    $context.PackageProjectionDescriptors = $packageProjectionDescriptorMap
    $context.PackageProjectionNodeIds = [string[]]$packageProjectionNodeIds.ToArray()
    $packageProjectionBarrierDependencies = if ($packageProjectionNodeIds.Count -gt 0) {
        [string[]]$packageProjectionNodeIds.ToArray()
    } else {
        [string[]]@('session-environment','user-environment-backup')
    }

    $projectCacheDescriptorSet = if ($RehydrationRequired) {
        Get-CapsulenvProjectCacheRepairDescriptorSet -Strict:$StrictToolRepairs -Quiet
    } else {
        [pscustomobject]@{ Records=@(); RegistryError=$null }
    }
    $projectCacheRecordMap = @{}
    $projectCacheNodeIds = New-Object System.Collections.Generic.List[string]
    $projectCacheNodes = New-Object System.Collections.Generic.List[object]
    foreach ($record in @($projectCacheDescriptorSet.Records)) {
        $recordKey = Get-CapsulenvProjectCacheRecordKey `
            -Profile ([string]$record.Profile) `
            -ProjectScope ([string]$record.ProjectScope) `
            -ProjectReference ([string]$record.ProjectReference)
        $recordToken = [Uri]::EscapeDataString($recordKey)
        $profileToken = [Uri]::EscapeDataString(([string]$record.Profile).ToLowerInvariant())
        $nodeId = ('project-cache-link:{0}' -f $recordToken)
        $projectCacheRecordMap[$nodeId] = $record
        $projectCacheNodeIds.Add($nodeId)
        $projectCacheNodes.Add((New-CapsulenvDesiredStateNode -Id $nodeId -ExecutionAffinity AnyRunspace -ConcurrencyPolicy ResourceBound `
            -DependsOn 'package-projections' `
            -ReadResources @(('capsule:///project-cache/store/{0}/{1}' -f $profileToken, $recordToken)) `
            -WriteResources @(('host:///project-cache-links/{0}' -f $recordToken)) `
            -Plan { param($c) [pscustomobject]@{ Operation='Apply'; CanApply=$true } } `
            -Apply { param($c,$d) Invoke-CapsulenvProjectCacheLinkRepairRecord -Record $c.ProjectCacheRecords[[string]$d.Id] -Strict:$c.StrictToolRepairs -Quiet } `
            -Verify { param($c,$d,$o) $null -ne $o -and $null -ne $o.PSObject.Properties['Result'] }))
    }
    $context.ProjectCacheRecords = $projectCacheRecordMap
    $context.ProjectCacheNodeIds = [string[]]$projectCacheNodeIds.ToArray()
    $context.ProjectCacheRegistryError = $projectCacheDescriptorSet.RegistryError
    $projectCacheBarrierDependencies = if ($projectCacheNodeIds.Count -gt 0) {
        [string[]]$projectCacheNodeIds.ToArray()
    } else {
        [string[]]@('package-projections')
    }

    # Keep each constructor behind an explicit expression boundary. Windows PowerShell 5.1
    # can otherwise mis-bind adjacent array-subexpression statements into the trailing
    # [scriptblock] Verify parameter and surface it as System.Object[].
    $nodes = @(
        (New-CapsulenvDesiredStateNode -Id 'session-environment' -ExecutionAffinity MainRunspace -ConcurrencyPolicy ResourceBound `
            -ReadResources @() `
            -WriteResources @('process:///environment','capsule:///tool-storage','capsule:///runtime-directories') `
            -Plan { param($c) [pscustomobject]@{ Operation='Apply'; CanApply=$true } } `
            -Apply { param($c,$d) Set-CapsulenvSessionEnvironment -IntegrationMode $c.IntegrationMode } `
            -Verify { param($c,$d,$o) $true })
        (New-CapsulenvDesiredStateNode -Id 'user-environment-backup' -ExecutionAffinity MainRunspace -ConcurrencyPolicy ResourceBound `
            -DependsOn 'session-environment' `
            -ReadResources @('host:///environment/user') `
            -WriteResources @('capsule:///state/user-environment-backup') `
            -Plan { param($c) [pscustomobject]@{ Operation=if($c.RehydrationRequired -and $c.IntegrationMode -eq 'User'){'Apply'}else{'NoOp'}; CanApply=$true } } `
            -Apply { param($c,$d) $plan=Get-CapsulenvEnvironmentPlan; $name=Get-CapsulenvScoopPathEnvironmentVariable; Ensure-CapsulenvUserEnvironmentBackupEntries -Names (@($plan.Variables.Keys)+@('PATH',$name)) } `
            -Verify { param($c,$d,$o) $true })
        $packageProjectionNodes.ToArray()
        (New-CapsulenvDesiredStateNode -Id 'package-projections' -ExecutionAffinity MainRunspace -ConcurrencyPolicy Exclusive `
            -DependsOn $packageProjectionBarrierDependencies `
            -ReadResources @() `
            -WriteResources @() `
            -Plan { param($c) [pscustomobject]@{ Operation=if($c.RehydrationRequired){'Apply'}else{'NoOp'}; CanApply=$true } } `
            -Apply { param($c,$d) $results=New-Object System.Collections.Generic.List[object]; foreach($nodeId in @($c.PackageProjectionNodeIds)){ $results.Add($c.Outputs[[string]$nodeId]) }; Merge-CapsulenvPackageProjectionResults -Results $results.ToArray() } `
            -Verify { param($c,$d,$o) $null -ne $o -and $null -ne $o.PSObject.Properties['Complete'] })
        (New-CapsulenvDesiredStateNode -Id 'package-host-integration' -ExecutionAffinity MainRunspace -ConcurrencyPolicy ResourceBound `
            -DependsOn 'package-projections' `
            -ReadResources @('capsule:///packages/installed-state') `
            -WriteResources @('host:///start-menu/capsulenv') `
            -Plan { param($c) [pscustomobject]@{ Operation=if($c.RehydrationRequired -and $c.IntegrationMode -eq 'User'){'Apply'}else{'NoOp'}; CanApply=$true } } `
            -Apply { param($c,$d) Sync-CapsulenvPackageStartMenuShortcuts -IntegrationMode $c.IntegrationMode } `
            -Verify { param($c,$d,$o) $true })
        (New-CapsulenvDesiredStateNode -Id 'persist-relocation' -ExecutionAffinity AnyRunspace -ConcurrencyPolicy ResourceBound `
            -DependsOn 'package-projections' `
            -ReadResources @('capsule:///state/rehydration') `
            -WriteResources @('capsule:///scoop/persist') `
            -Plan { param($c) [pscustomobject]@{ Operation=if($c.RehydrationRequired -and (-not $SkipPersistRepairs) -and $c.RelocationContext.HasPathChanges){'Apply'}else{'NoOp'}; CanApply=$true } } `
            -Apply { param($c,$d) Invoke-CapsulenvPersistRelocationRepair -RelocationContext $c.RelocationContext } `
            -Verify { param($c,$d,$o) $true })
        $projectCacheNodes.ToArray()
        (New-CapsulenvDesiredStateNode -Id 'project-cache-links' -ExecutionAffinity MainRunspace -ConcurrencyPolicy ResourceBound `
            -DependsOn $projectCacheBarrierDependencies `
            -ReadResources @('capsule:///project-cache/registry') `
            -WriteResources @('capsule:///project-cache/registry') `
            -Plan { param($c) [pscustomobject]@{ Operation=if($c.RehydrationRequired){'Apply'}else{'NoOp'}; CanApply=$true } } `
            -Apply { param($c,$d) if($null -ne $c.ProjectCacheRegistryError){ return @([pscustomobject]@{ Profile=$null; ProjectPath=$null; LinkPath=$null; StorePath=$null; LinkType=$null; Changed=$false; Status='RegistryError'; Detail=[string]$c.ProjectCacheRegistryError }) }; $repairs=New-Object System.Collections.Generic.List[object]; foreach($nodeId in @($c.ProjectCacheNodeIds)){ $repairs.Add($c.Outputs[[string]$nodeId]) }; @(Complete-CapsulenvProjectCacheRepairBatch -Repairs $repairs.ToArray()) } `
            -Verify { param($c,$d,$o) $null -ne $o })
        (New-CapsulenvDesiredStateNode -Id 'tool-relocation' -ExecutionAffinity AnyRunspace -ConcurrencyPolicy ResourceBound `
            -DependsOn 'project-cache-links' `
            -ReadResources @('capsule:///tool-storage/configuration','capsule:///state/tool-workspaces') `
            -WriteResources @('capsule:///tool-data','capsule:///tool-storage','capsule:///state/tool-workspaces','host:///workspaces/registered') `
            -Plan { param($c) [pscustomobject]@{ Operation=if($c.RehydrationRequired -and (-not $SkipToolRepairs) -and $c.RelocationContext.HasPathChanges -and $toolRelocation.Enabled -and $toolRelocation.AutoRepair){'Apply'}else{'NoOp'}; CanApply=$true } } `
            -Apply { param($c,$d) Invoke-CapsulenvToolRelocationRepairCore -RelocationContext $c.RelocationContext -Strict:$c.StrictToolRepairs } `
            -Verify { param($c,$d,$o) $true })
        (New-CapsulenvDesiredStateNode -Id 'user-integration' -ExecutionAffinity MainRunspace -ConcurrencyPolicy ResourceBound `
            -DependsOn @('persist-relocation','tool-relocation','package-host-integration') `
            -ReadResources @('capsule:///packages/installed-state','capsule:///state/user-environment-backup','capsule:///state/install-mode') `
            -WriteResources @('host:///environment/user','capsule:///state/user-environment-backup','capsule:///state/install-mode') `
            -Plan { param($c) [pscustomobject]@{ Operation=if($c.RehydrationRequired -and $c.IntegrationMode -eq 'User'){'Apply'}else{'NoOp'}; CanApply=$true } } `
            -Apply { param($c,$d) Sync-CapsulenvUserEnvironment -RelocationContext $c.RelocationContext } `
            -Verify { param($c,$d,$o) $true })
        (New-CapsulenvDesiredStateNode -Id 'rehydration-state' -ExecutionAffinity MainRunspace -ConcurrencyPolicy ResourceBound `
            -DependsOn @('persist-relocation','tool-relocation','user-integration') `
            -ReadResources @('capsule:///state/rehydration') `
            -WriteResources @('capsule:///state/rehydration') `
            -Plan { param($c) [pscustomobject]@{ Operation=if($c.RehydrationRequired){'Apply'}else{'NoOp'}; CanApply=$true } } `
            -Apply { param($c,$d) $repair=$c.Outputs['persist-relocation']; $projection=$c.Outputs['package-projections']; $complete=[bool]$projection.Complete; $retryRequired=[bool]$projection.RetryRequired; $issues=@($projection.Issues); Save-CapsulenvRehydrationState -RelocationContext $c.RelocationContext -PersistRepairResult $repair -PendingProjectionRepair:$retryRequired -ProjectionRepairIssues $issues; [pscustomobject]@{ ProjectionRepairComplete=$complete; ProjectionRepairRetryRequired=$retryRequired; ProjectionRepairIssues=$issues } } `
            -Verify { param($c,$d,$o) $true })
    )
    return [pscustomobject][ordered]@{
        Context=$context
        Plan=(Get-CapsulenvDesiredStatePlan -Nodes $nodes -Context $context -IncludeDiagnostics:$IncludeDiagnostics)
        RelocationContext=$relocationContext
        RehydrationRequired=[bool]$RehydrationRequired
    }
}

function Get-CapsulenvScoopRehydratePlan {
    [CmdletBinding()]
    param(
        [switch]$SkipPersistRepairs,
        [switch]$SkipToolRepairs,
        [switch]$StrictToolRepairs,
        [ValidateSet('ShellOnly', 'User')][string]$IntegrationMode = (Get-CapsulenvInstallMode),
        [bool]$IncludeDiagnostics = $true
    )

    return Get-CapsulenvIntegrationDesiredStatePlan `
        -SkipPersistRepairs:$SkipPersistRepairs `
        -SkipToolRepairs:$SkipToolRepairs `
        -StrictToolRepairs:$StrictToolRepairs `
        -IntegrationMode $IntegrationMode `
        -RehydrationRequired $true `
        -IncludeDiagnostics:$IncludeDiagnostics
}

function Write-CapsulenvRehydrationResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Results,
        [Parameter(Mandatory = $true)][ValidateSet('ShellOnly', 'User')][string]$IntegrationMode
    )

    $state = @($Results | Where-Object Id -eq 'rehydration-state' | Select-Object -Last 1).Output
    if ($null -ne $state -and [bool]$state.ProjectionRepairComplete) {
        Write-CapsulenvMessage -Level Success -Message "Capsulenv package projection rehydration completed in $IntegrationMode mode."
        return
    }
    $issueCount = if ($null -ne $state) { @($state.ProjectionRepairIssues).Count } else { 0 }
    $retryRequired = ($null -ne $state -and [bool]$state.ProjectionRepairRetryRequired)
    if ($retryRequired) {
        Write-CapsulenvMessage -Level Warning -Message ("Capsulenv package projection rehydration completed in {0} mode with {1} deferred legacy Scoop projection issue(s); retryable state will be checked again on the next activation." -f $IntegrationMode, $issueCount)
    } else {
        Write-CapsulenvMessage -Level Warning -Message ("Capsulenv package projection rehydration completed in {0} mode with {1} unresolved legacy Scoop projection issue(s); ambiguous or foreign-owned state was left unchanged. Run 'capsulenv.cmd doctor' for remediation." -f $IntegrationMode, $issueCount)
    }
}

function Invoke-CapsulenvIntegrationDesiredState {
    [CmdletBinding()]
    param(
        [switch]$SkipPersistRepairs,
        [switch]$SkipToolRepairs,
        [switch]$StrictToolRepairs,
        [ValidateSet('ShellOnly', 'User')][string]$IntegrationMode = (Get-CapsulenvInstallMode)
    )

    $rehydrationRequired = [bool](Test-CapsulenvScoopRehydrationRequired)
    if ($rehydrationRequired) {
        Write-CapsulenvMessage -Level Info -Message 'Capsule root or host changed; rehydrating installed package projections...'
    }
    $integration = Get-CapsulenvIntegrationDesiredStatePlan `
        -SkipPersistRepairs:$SkipPersistRepairs `
        -SkipToolRepairs:$SkipToolRepairs `
        -StrictToolRepairs:$StrictToolRepairs `
        -IntegrationMode $IntegrationMode `
        -RehydrationRequired $rehydrationRequired
    $results = @(Invoke-CapsulenvDesiredStatePlan -Plan $integration.Plan -Context $integration.Context)
    if ($rehydrationRequired) {
        Write-CapsulenvRehydrationResult -Results $results -IntegrationMode $IntegrationMode
        [void](Invoke-CapsulenvRoutines -Trigger OnRehydrate)
    }
    return $results
}

function Invoke-CapsulenvScoopRehydrate {
    [CmdletBinding()]
    param(
        [switch]$SkipHooks,
        [switch]$SkipPersistRepairs,
        [switch]$SkipToolRepairs,
        [switch]$StrictToolRepairs,
        [ValidateSet('ShellOnly', 'User')][string]$IntegrationMode = (Get-CapsulenvInstallMode)
    )
    $rehydrate = Get-CapsulenvScoopRehydratePlan -SkipPersistRepairs:$SkipPersistRepairs -SkipToolRepairs:$SkipToolRepairs -StrictToolRepairs:$StrictToolRepairs -IntegrationMode $IntegrationMode -IncludeDiagnostics:$false
    if (-not $SkipHooks) { Write-CapsulenvMessage -Level Detail -Message 'Automatic Scoop lifecycle replay has been removed; arbitrary manifest code is available only through explicit upstream Scoop execution.' }
    $results = @(Invoke-CapsulenvDesiredStatePlan -Plan $rehydrate.Plan -Context $rehydrate.Context)
    Write-CapsulenvRehydrationResult -Results $results -IntegrationMode $IntegrationMode
    [void](Invoke-CapsulenvRoutines -Trigger OnRehydrate)
    return $results
}

Register-CapsulenvDoctorCheck -Id 'Capsulenv.Doctor.Scoop.Root' -Area 'Scoop' -Name 'Portable Scoop root' -Handler {
    $root = Get-CapsulenvScoopRoot
    $exists = Test-Path -LiteralPath $root -PathType Container
    New-CapsulenvDoctorResult -Id 'Capsulenv.Doctor.Scoop.Root' -Name 'Portable Scoop root' -Area 'Scoop' -Status $(if($exists){'Healthy'}else{'Failed'}) -Summary $root -Detail $root -Data ([ordered]@{ Path=$root; Exists=$exists }) -Remediation $(if($exists){@()}else{@('Bootstrap the capsule to create the configured portable Scoop root.')})
}
Register-CapsulenvDoctorCheck -Id 'Capsulenv.Doctor.Scoop.GlobalRoot' -Area 'Scoop' -Name 'Scoop -g compatibility root' -Importance Optional -Handler {
    $root = Get-CapsulenvScoopGlobalRoot
    $valid = -not [string]::IsNullOrWhiteSpace([string]$root)
    $exists = $valid -and (Test-Path -LiteralPath $root -PathType Container)
    $summary = if (-not $valid) {
        'No compatibility root is configured.'
    } elseif ($exists) {
        "Available for unmodified upstream Scoop -g compatibility: $root"
    } else {
        "Not materialized; upstream Scoop -g will use this capsule-local compatibility path if needed: $root"
    }
    New-CapsulenvDoctorResult `
        -Id 'Capsulenv.Doctor.Scoop.GlobalRoot' `
        -Name 'Scoop -g compatibility root' `
        -Area 'Scoop' `
        -Status $(if($valid){'Healthy'}else{'Failed'}) `
        -Importance Optional `
        -Summary $summary `
        -Detail $summary `
        -Data ([ordered]@{ Path=$root; Exists=$exists; Provider='Scoop'; ProviderScope='Global' }) `
        -Remediation $(if($valid){@()}else{@('Configure Scoop.GlobalRoot only when upstream Scoop compatibility is required.')})
}
Register-CapsulenvDoctorCheck -Id 'Capsulenv.Doctor.Scoop.Command' -Area 'Scoop' -Name 'Scoop command' -Handler {
    $executable = Get-CapsulenvScoopExecutable
    $available = $null -ne $executable
    New-CapsulenvDoctorResult -Id 'Capsulenv.Doctor.Scoop.Command' -Name 'Scoop command' -Area 'Scoop' -Status $(if($available){'Healthy'}else{'Unavailable'}) -Summary $(if($available){[string]$executable}else{'Not found; bootstrap will install it on first session'}) -Detail $(if($available){[string]$executable}else{'Not found; bootstrap will install it on first session'}) -Data ([ordered]@{ Executable=$executable }) -Remediation $(if($available){@()}else{@('Bootstrap the capsule before running explicit TrustedExecution Scoop commands.')})
}
Register-CapsulenvDoctorCheck -Id 'Capsulenv.Doctor.Scoop.ProjectionRepairState' -Area 'Scoop' -Name 'Package projection repair state' -Importance Optional -Handler {
    $statePath = Get-CapsulenvRehydrationStatePath
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return New-CapsulenvDoctorResult `
            -Id 'Capsulenv.Doctor.Scoop.ProjectionRepairState' `
            -Name 'Package projection repair state' `
            -Area 'Scoop' `
            -Status Healthy `
            -Importance Optional `
            -Summary 'No persisted relocation repair issues.' `
            -Data ([ordered]@{ StatePath=$statePath; Pending=$false; Issues=@() })
    }
    try {
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    } catch {
        return New-CapsulenvDoctorResult `
            -Id 'Capsulenv.Doctor.Scoop.ProjectionRepairState' `
            -Name 'Package projection repair state' `
            -Area 'Scoop' `
            -Status Advisory `
            -Importance Optional `
            -Summary "The rehydration detail state is unreadable: $statePath" `
            -Data ([ordered]@{ StatePath=$statePath; Pending=$true; Issues=@() }) `
            -Remediation @('Run capsulenv rehydrate after resolving any filesystem or media errors affecting the capsule state directory; ordinary activation intentionally does not parse this detail state.')
    }
    $pendingProperty = $saved.PSObject.Properties['PendingProjectionRepair']
    $pending = ($null -ne $pendingProperty -and [bool]$pendingProperty.Value)
    $issuesProperty = $saved.PSObject.Properties['ProjectionRepairIssues']
    $issues = if ($null -ne $issuesProperty) { @($issuesProperty.Value) } else { @() }
    $status = if ($pending -or $issues.Count -gt 0) { 'Advisory' } else { 'Healthy' }
    $summary = if ($issues.Count -gt 0) {
        "Legacy Scoop projection repair has $($issues.Count) unresolved issue(s); foreign or ambiguous state was left unchanged."
    } elseif ($pending) {
        'Package projection repair is pending and will be retried on the next rehydrate.'
    } else {
        'No persisted relocation repair issues.'
    }
    $remediation = New-Object System.Collections.Generic.List[string]
    foreach ($issue in $issues) {
        if ($null -eq $issue) { continue }
        $selectorProperty = $issue.PSObject.Properties['Selector']
        $errorIdProperty = $issue.PSObject.Properties['ErrorId']
        $remediationProperty = $issue.PSObject.Properties['Remediation']
        $selector = if ($null -ne $selectorProperty) { [string]$selectorProperty.Value } else { '' }
        $errorId = if ($null -ne $errorIdProperty) { [string]$errorIdProperty.Value } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($selector)) {
            $remediation.Add(("Inspect legacy Scoop projection '{0}' ({1})." -f $selector, $errorId))
        }
        $issueRemediation = if ($null -ne $remediationProperty) { @($remediationProperty.Value) } else { @() }
        foreach ($line in $issueRemediation) {
            if (-not [string]::IsNullOrWhiteSpace([string]$line) -and -not $remediation.Contains([string]$line)) {
                $remediation.Add([string]$line)
            }
        }
    }
    New-CapsulenvDoctorResult `
        -Id 'Capsulenv.Doctor.Scoop.ProjectionRepairState' `
        -Name 'Package projection repair state' `
        -Area 'Scoop' `
        -Status $status `
        -Importance Optional `
        -Summary $summary `
        -Data ([ordered]@{ StatePath=$statePath; Pending=$pending; Issues=$issues }) `
        -Remediation $remediation.ToArray()
}

Register-CapsulenvDoctorCheck -Id 'Capsulenv.Doctor.Scoop.Config' -Area 'Scoop' -Name 'Portable Scoop config' -Importance Optional -Handler {
    $path = Join-Path (Get-CapsulenvScoopRoot) 'config.json'
    $exists = Test-Path -LiteralPath $path -PathType Leaf
    New-CapsulenvDoctorResult -Id 'Capsulenv.Doctor.Scoop.Config' -Name 'Portable Scoop config' -Area 'Scoop' -Status $(if($exists){'Healthy'}else{'Advisory'}) -Importance Optional -Summary $path -Detail $path -Data ([ordered]@{ Path=$path; Exists=$exists })
}
Register-CapsulenvDoctorCheck -Id 'Capsulenv.Doctor.Scoop.PersistStore' -Area 'Scoop' -Name 'Scoop persist store' -Importance Optional -Handler {
    $path = Join-Path (Get-CapsulenvScoopRoot) 'persist'
    $exists = Test-Path -LiteralPath $path -PathType Container
    New-CapsulenvDoctorResult -Id 'Capsulenv.Doctor.Scoop.PersistStore' -Name 'Scoop persist store' -Area 'Scoop' -Status $(if($exists){'Healthy'}else{'Advisory'}) -Importance Optional -Summary $path -Detail $path -Data ([ordered]@{ Path=$path; Exists=$exists })
}

Register-CapsulenvDoctorCheck -Id 'Capsulenv.Doctor.DesiredState.RehydrateOwnership' -Area 'DesiredState' -Name 'Rehydrate resource ownership' -Importance Optional -Handler {
    $rehydrate = Get-CapsulenvScoopRehydratePlan -IncludeDiagnostics:$true
    $plan = $rehydrate.Plan
    $unorderedWriters = @($plan.OwnershipDiagnostics.UnorderedWriteWrite)
    $workerNodeIds = @($plan.ExecutionWaves | ForEach-Object { @($_.WorkerNodeIds) } | Select-Object -Unique)
    $status = if ($unorderedWriters.Count -eq 0) { 'Healthy' } else { 'Advisory' }
    New-CapsulenvDoctorResult `
        -Id 'Capsulenv.Doctor.DesiredState.RehydrateOwnership' `
        -Name 'Rehydrate resource ownership' `
        -Area 'DesiredState' `
        -Status $status `
        -Importance Optional `
        -Summary ("{0} claim(s), {1} diagnostic concurrency wave(s), {2} worker-capable resource-bound node(s), {3} unordered competing writer pair(s)" -f @($plan.ResourceClaims).Count, @($plan.ExecutionWaves).Count, $workerNodeIds.Count, $unorderedWriters.Count) `
        -Data ([ordered]@{ Claims=@($plan.ResourceClaims); Conflicts=@($plan.ResourceConflicts); WorkerNodeIds=$workerNodeIds; ParallelNodeIds=$workerNodeIds; UnorderedWriteWrite=$unorderedWriters }) `
        -Remediation $(if($unorderedWriters.Count -eq 0){@()}else{@('Add an explicit dependency between competing writers, or narrow their write-resource claims before enabling parallel execution.')})
}

##MOD_EXEC## Export-ModuleMember -Function Reset-CapsulenvScoop, Get-CapsulenvScoopRehydratePlan, Invoke-CapsulenvScoopRehydrate, Test-CapsulenvScoopRehydrationRequired
