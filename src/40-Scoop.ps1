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

function Test-CapsulenvScoopRehydrationRequired {
    [CmdletBinding()]
    param()

    $statePath = Get-CapsulenvRehydrationStatePath
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $true
    }

    try {
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    } catch {
        return $true
    }
    $pendingRepairProperty = $saved.PSObject.Properties['PendingProjectionRepair']
    if ($null -eq $pendingRepairProperty) {
        # Schema <=3 used this name for the same retry signal.
        $pendingRepairProperty = $saved.PSObject.Properties['PendingScoopReset']
    }
    if ($null -ne $pendingRepairProperty -and [bool]$pendingRepairProperty.Value) {
        return $true
    }
    $current = Get-CapsulenvRelocationFingerprint
    foreach ($name in @('CapsuleId', 'Root', 'ScoopRoot', 'ScoopGlobalRoot', 'ComputerName', 'User')) {
        $property = $saved.PSObject.Properties[$name]
        if ($null -eq $property -or [string]$property.Value -ne [string]$current[$name]) {
            return $true
        }
    }
    return $false
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
        [bool]$PendingProjectionRepair = $false
    )

    $statePath = Get-CapsulenvRehydrationStatePath
    $stateDirectory = Split-Path -Parent $statePath
    [void](New-Item -ItemType Directory -Path $stateDirectory -Force)
    $state = Get-CapsulenvRelocationFingerprint
    $state.Insert(0, 'SchemaVersion', 4)
    $state['PendingProjectionRepair'] = $PendingProjectionRepair
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
}

function Get-CapsulenvScoopRehydratePlan {
    [CmdletBinding()]
    param(
        [switch]$SkipPersistRepairs,
        [switch]$SkipToolRepairs,
        [switch]$StrictToolRepairs,
        [ValidateSet('ShellOnly', 'User')][string]$IntegrationMode = (Get-CapsulenvInstallMode)
    )

    $relocationContext = Get-CapsulenvRelocationContext
    $toolRelocation = Get-CapsulenvToolRelocationConfiguration
    $context = @{ RelocationContext=$relocationContext; IntegrationMode=$IntegrationMode; StrictToolRepairs=[bool]$StrictToolRepairs }
    $nodes = @(
        New-CapsulenvDesiredStateNode -Id 'session-environment' `
            -WriteResources @('process:///environment') `
            -Plan { param($c) [pscustomobject]@{ Operation='Apply'; CanApply=$true } } `
            -Apply { param($c,$d) Set-CapsulenvSessionEnvironment } `
            -Verify { param($c,$d,$o) $true },
        New-CapsulenvDesiredStateNode -Id 'user-environment-backup' `
            -DependsOn 'session-environment' `
            -ReadResources @('host:///environment/user') `
            -WriteResources @('capsule:///state/user-environment-backup') `
            -Plan { param($c) [pscustomobject]@{ Operation=if($c.IntegrationMode -eq 'User'){'Apply'}else{'NoOp'}; CanApply=$true } } `
            -Apply { param($c,$d) $plan=Get-CapsulenvEnvironmentPlan; $name=Get-CapsulenvScoopPathEnvironmentVariable; Ensure-CapsulenvUserEnvironmentBackupEntries -Names (@($plan.Variables.Keys)+@('PATH',$name)) } `
            -Verify { param($c,$d,$o) $true },
        New-CapsulenvDesiredStateNode -Id 'package-projections' `
            -DependsOn @('session-environment','user-environment-backup') `
            -ReadResources @('capsule:///packages/installed-state') `
            -WriteResources @('capsule:///packages/projections','capsule:///scoop/apps','capsule:///scoop/persist','capsule:///packages/shims','host:///start-menu/capsulenv') `
            -Plan { param($c) [pscustomobject]@{ Operation='Apply'; CanApply=$true } } `
            -Apply { param($c,$d) [bool](Repair-CapsulenvInstalledAppProjections -IntegrationMode $c.IntegrationMode -DeferRunningApps:($c.IntegrationMode -eq 'User')) } `
            -Verify { param($c,$d,$o) $null -ne $o },
        New-CapsulenvDesiredStateNode -Id 'persist-relocation' -ParallelSafe `
            -DependsOn 'package-projections' `
            -ReadResources @('capsule:///state/rehydration') `
            -WriteResources @('capsule:///scoop/persist') `
            -Plan { param($c) [pscustomobject]@{ Operation=if((-not $SkipPersistRepairs)-and $c.RelocationContext.HasPathChanges){'Apply'}else{'NoOp'}; CanApply=$true } } `
            -Apply { param($c,$d) Invoke-CapsulenvPersistRelocationRepair -RelocationContext $c.RelocationContext } `
            -Verify { param($c,$d,$o) $true },
        New-CapsulenvDesiredStateNode -Id 'project-cache-links' -ParallelSafe `
            -DependsOn 'package-projections' `
            -ReadResources @('capsule:///project-cache/registry') `
            -WriteResources @('capsule:///project-cache','host:///project-cache-links') `
            -Plan { param($c) [pscustomobject]@{ Operation=if((-not $SkipToolRepairs)-and $c.RelocationContext.HasPathChanges){'Apply'}else{'NoOp'}; CanApply=$true } } `
            -Apply { param($c,$d) Repair-CapsulenvProjectCacheLinks -Strict:$c.StrictToolRepairs -Quiet } `
            -Verify { param($c,$d,$o) $true },
        New-CapsulenvDesiredStateNode -Id 'tool-relocation' `
            -DependsOn 'project-cache-links' `
            -ReadResources @('capsule:///tool-storage/configuration') `
            -WriteResources @('capsule:///tool-data','capsule:///tool-storage') `
            -Plan { param($c) [pscustomobject]@{ Operation=if((-not $SkipToolRepairs)-and $c.RelocationContext.HasPathChanges -and $toolRelocation.Enabled -and $toolRelocation.AutoRepair){'Apply'}else{'NoOp'}; CanApply=$true } } `
            -Apply { param($c,$d) Invoke-CapsulenvToolRelocationRepair -RelocationContext $c.RelocationContext -Strict:$c.StrictToolRepairs } `
            -Verify { param($c,$d,$o) $true },
        New-CapsulenvDesiredStateNode -Id 'user-integration' `
            -DependsOn @('persist-relocation','tool-relocation') `
            -ReadResources @('capsule:///packages/installed-state') `
            -WriteResources @('host:///environment/user','host:///start-menu/capsulenv') `
            -Plan { param($c) [pscustomobject]@{ Operation=if($c.IntegrationMode -eq 'User'){'Apply'}else{'NoOp'}; CanApply=$true } } `
            -Apply { param($c,$d) Sync-CapsulenvUserEnvironment -RelocationContext $c.RelocationContext } `
            -Verify { param($c,$d,$o) $true },
        New-CapsulenvDesiredStateNode -Id 'rehydration-state' `
            -DependsOn @('persist-relocation','tool-relocation','user-integration') `
            -ReadResources @('capsule:///state/rehydration') `
            -WriteResources @('capsule:///state/rehydration') `
            -Plan { param($c) [pscustomobject]@{ Operation='Apply'; CanApply=$true } } `
            -Apply { param($c,$d) $repair=$c.Outputs['persist-relocation']; $projection=[bool]$c.Outputs['package-projections']; Save-CapsulenvRehydrationState -RelocationContext $c.RelocationContext -PersistRepairResult $repair -PendingProjectionRepair:(-not $projection); [pscustomobject]@{ ProjectionRepairComplete=$projection } } `
            -Verify { param($c,$d,$o) $true }
    )
    return [pscustomobject][ordered]@{ Context=$context; Plan=(Get-CapsulenvDesiredStatePlan -Nodes $nodes -Context $context); RelocationContext=$relocationContext }
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
    $rehydrate = Get-CapsulenvScoopRehydratePlan -SkipPersistRepairs:$SkipPersistRepairs -SkipToolRepairs:$SkipToolRepairs -StrictToolRepairs:$StrictToolRepairs -IntegrationMode $IntegrationMode
    if (-not $SkipHooks) { Write-CapsulenvMessage -Level Detail -Message 'Automatic Scoop lifecycle replay has been removed; arbitrary manifest code is available only through explicit upstream Scoop execution.' }
    $results = @(Invoke-CapsulenvDesiredStatePlan -Plan $rehydrate.Plan -Context $rehydrate.Context)
    $state = @($results | Where-Object Id -eq 'rehydration-state' | Select-Object -Last 1).Output
    if ($null -ne $state -and [bool]$state.ProjectionRepairComplete) { Write-CapsulenvMessage -Level Success -Message "Capsulenv package projection rehydration completed in $IntegrationMode mode." }
    else { Write-CapsulenvMessage -Level Warning -Message "Capsulenv package projection rehydration completed in $IntegrationMode mode with a deferred legacy app projection; it will be retried automatically." }
    return $results
}

Register-CapsulenvDoctorCheck -Id 'Capsulenv.Doctor.Scoop.Root' -Area 'Scoop' -Name 'Portable Scoop root' -Handler {
    $root = Get-CapsulenvScoopRoot
    $exists = Test-Path -LiteralPath $root -PathType Container
    New-CapsulenvDoctorResult -Id 'Capsulenv.Doctor.Scoop.Root' -Name 'Portable Scoop root' -Area 'Scoop' -Status $(if($exists){'Healthy'}else{'Failed'}) -Summary $root -Detail $root -Data ([ordered]@{ Path=$root; Exists=$exists }) -Remediation $(if($exists){@()}else{@('Bootstrap the capsule to create the configured portable Scoop root.')})
}
Register-CapsulenvDoctorCheck -Id 'Capsulenv.Doctor.Scoop.GlobalRoot' -Area 'Scoop' -Name 'Portable Scoop global root' -Handler {
    $root = Get-CapsulenvScoopGlobalRoot
    $valid = -not [string]::IsNullOrWhiteSpace([string]$root)
    New-CapsulenvDoctorResult -Id 'Capsulenv.Doctor.Scoop.GlobalRoot' -Name 'Portable Scoop global root' -Area 'Scoop' -Status $(if($valid){'Healthy'}else{'Failed'}) -Summary $root -Detail $root -Data ([ordered]@{ Path=$root })
}
Register-CapsulenvDoctorCheck -Id 'Capsulenv.Doctor.Scoop.Command' -Area 'Scoop' -Name 'Scoop command' -Handler {
    $executable = Get-CapsulenvScoopExecutable
    $available = $null -ne $executable
    New-CapsulenvDoctorResult -Id 'Capsulenv.Doctor.Scoop.Command' -Name 'Scoop command' -Area 'Scoop' -Status $(if($available){'Healthy'}else{'Unavailable'}) -Summary $(if($available){[string]$executable}else{'Not found; bootstrap will install it on first session'}) -Detail $(if($available){[string]$executable}else{'Not found; bootstrap will install it on first session'}) -Data ([ordered]@{ Executable=$executable }) -Remediation $(if($available){@()}else{@('Bootstrap the capsule before running explicit TrustedExecution Scoop commands.')})
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
    $rehydrate = Get-CapsulenvScoopRehydratePlan
    $plan = $rehydrate.Plan
    $unorderedWriters = @($plan.OwnershipDiagnostics.UnorderedWriteWrite)
    $parallelNodeIds = @($plan.ExecutionWaves | ForEach-Object { @($_.ParallelNodeIds) } | Select-Object -Unique)
    $status = if ($unorderedWriters.Count -eq 0) { 'Healthy' } else { 'Advisory' }
    New-CapsulenvDoctorResult `
        -Id 'Capsulenv.Doctor.DesiredState.RehydrateOwnership' `
        -Name 'Rehydrate resource ownership' `
        -Area 'DesiredState' `
        -Status $status `
        -Importance Optional `
        -Summary ("{0} claim(s), {1} execution wave(s), {2} parallel-safe node(s), {3} unordered competing writer pair(s)" -f @($plan.ResourceClaims).Count, @($plan.ExecutionWaves).Count, $parallelNodeIds.Count, $unorderedWriters.Count) `
        -Data ([ordered]@{ Claims=@($plan.ResourceClaims); Conflicts=@($plan.ResourceConflicts); ParallelNodeIds=$parallelNodeIds; UnorderedWriteWrite=$unorderedWriters }) `
        -Remediation $(if($unorderedWriters.Count -eq 0){@()}else{@('Add an explicit dependency between competing writers, or narrow their write-resource claims before enabling parallel execution.')})
}

##MOD_EXEC## Export-ModuleMember -Function Reset-CapsulenvScoop, Get-CapsulenvScoopRehydratePlan, Invoke-CapsulenvScoopRehydrate, Test-CapsulenvScoopRehydrationRequired
