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
        throw 'Scoop is not installed in the configured portable root.'
    }

    Clear-CapsulenvLastExitCode
    $commandOutput = @(& $scoop @Arguments)
    $succeeded = $?
    if ($commandOutput.Count -gt 0) {
        $commandOutput | Out-Host
    }
    $exitCode = Get-CapsulenvLastExitCode -Succeeded $succeeded
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "scoop $($Arguments -join ' ') failed with exit code $exitCode"
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

function Invoke-CapsulenvScoopRehydrate {
    [CmdletBinding()]
    param(
        [switch]$SkipHooks,
        [switch]$SkipPersistRepairs,
        [switch]$SkipToolRepairs,
        [switch]$StrictToolRepairs,
        [ValidateSet('ShellOnly', 'User')]
        [string]$IntegrationMode = (Get-CapsulenvInstallMode)
    )

    $relocationContext = Get-CapsulenvRelocationContext
    [void](Set-CapsulenvSessionEnvironment)
    if ($IntegrationMode -eq 'User') {
        $environmentPlan = Get-CapsulenvEnvironmentPlan
        $scoopPathEnvironmentVariable = Get-CapsulenvScoopPathEnvironmentVariable
        Ensure-CapsulenvUserEnvironmentBackupEntries `
            -Names (@($environmentPlan.Variables.Keys) + @('PATH', $scoopPathEnvironmentVariable))
    }
    $projectionRepairComplete = [bool](Repair-CapsulenvInstalledAppProjections `
        -IntegrationMode $IntegrationMode `
        -DeferRunningApps:($IntegrationMode -eq 'User'))
    if (-not $SkipHooks) {
        Write-CapsulenvMessage -Level Detail -Message 'Automatic Scoop lifecycle replay has been removed; arbitrary manifest code is available only through explicit upstream Scoop execution.'
    }

    $repairResult = $null
    if (-not $SkipPersistRepairs -and $relocationContext.HasPathChanges) {
        $repairResult = Invoke-CapsulenvPersistRelocationRepair -RelocationContext $relocationContext
    }

    $toolRelocation = (Get-CapsulenvToolRelocationConfiguration)
    if (-not $SkipToolRepairs -and $relocationContext.HasPathChanges) {
        [void](Repair-CapsulenvProjectCacheLinks -Strict:$StrictToolRepairs -Quiet)
    }
    if (
        -not $SkipToolRepairs -and
        $relocationContext.HasPathChanges -and
        $toolRelocation.Enabled -and
        $toolRelocation.AutoRepair
    ) {
        [void](Invoke-CapsulenvToolRelocationRepair `
            -RelocationContext $relocationContext `
            -Strict:$StrictToolRepairs)
    }

    if ($IntegrationMode -eq 'User') {
        [void](Sync-CapsulenvUserEnvironment -RelocationContext $relocationContext)
    }
    Save-CapsulenvRehydrationState `
        -RelocationContext $relocationContext `
        -PersistRepairResult $repairResult `
        -PendingProjectionRepair:(-not $projectionRepairComplete)
    if ($projectionRepairComplete) {
        Write-CapsulenvMessage -Level Success -Message "Capsulenv package projection rehydration completed in $IntegrationMode mode."
    } else {
        Write-CapsulenvMessage -Level Warning -Message "Capsulenv package projection rehydration completed in $IntegrationMode mode with a deferred legacy app projection; it will be retried automatically."
    }
}

##MOD_EXEC## Export-ModuleMember -Function Reset-CapsulenvScoop, Invoke-CapsulenvScoopRehydrate, Test-CapsulenvScoopRehydrationRequired
