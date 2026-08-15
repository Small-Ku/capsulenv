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
    $shimsRoot = Join-Path $scoopRoot 'shims'
    $scoopAppRoot = Join-Path (Join-Path (Join-Path $scoopRoot 'apps') 'scoop') 'current'
    # Internal Capsulenv calls must bypass the public policy gateway to avoid
    # recursion. Prefer Scoop's canonical executable; keep the shim fallback
    # only for incomplete/legacy layouts.
    foreach ($candidate in @(
        (Join-Path (Join-Path $scoopAppRoot 'bin') 'scoop.ps1'),
        (Join-Path $shimsRoot 'scoop.ps1')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
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
    & $scoop @Arguments
    $succeeded = $?
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
        [ValidateSet('ShellOnly', 'User')]
        [string]$IntegrationMode = (Get-CapsulenvInstallMode)
    )

    if ($IntegrationMode -eq 'ShellOnly') {
        if (-not $Quiet) {
            Write-CapsulenvMessage -Level Info -Message 'Rebuilding capsule-owned Scoop current links, shims, and persist links without touching Start Menu or user environment...'
        }
        Invoke-CapsulenvPortableScoopReset -Apps $Apps
        return $true
    }

    if (-not $Quiet) {
        Write-CapsulenvMessage -Level Info -Message 'Rebuilding Scoop current links, shims, shortcuts, environment entries, and persist links for the installed user...'
    }
    Invoke-CapsulenvUserScoopReset -Apps $Apps
    return $true
}

function Get-CapsulenvScoopReplayScriptPath {
    [CmdletBinding()]
    param()

    $context = Get-CapsulenvContext
    return Join-Path (Join-Path $context.Root 'scripts') 'scoop-capsulenv-replay.ps1'
}

function Get-CapsulenvScoopPortableResetScriptPath {
    [CmdletBinding()]
    param()

    $context = Get-CapsulenvContext
    return Join-Path (Join-Path $context.Root 'scripts') 'scoop-capsulenv-portable-reset.ps1'
}

function Get-CapsulenvScoopUserResetScriptPath {
    [CmdletBinding()]
    param()

    $context = Get-CapsulenvContext
    return Join-Path (Join-Path $context.Root 'scripts') 'scoop-capsulenv-user-reset.ps1'
}

function Install-CapsulenvTemporaryScoopCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Prefix
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Missing Scoop helper command: $Source"
    }
    if (-not (Get-CapsulenvScoopExecutable)) {
        throw 'Scoop is not installed in the configured portable root.'
    }

    $shims = Join-Path (Get-CapsulenvScoopRoot) 'shims'
    [void](New-Item -ItemType Directory -Path $shims -Force)
    $suffix = ('{0}-{1}' -f $PID, ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
    $commandName = "capsulenv-$Prefix-$suffix"
    $target = Join-Path $shims ("scoop-{0}.ps1" -f $commandName)
    Copy-Item -LiteralPath $Source -Destination $target -ErrorAction Stop
    return [pscustomobject]@{
        Command = $commandName
        Path = $target
    }
}

function Install-CapsulenvScoopReplayCommand {
    [CmdletBinding()]
    param()

    return Install-CapsulenvTemporaryScoopCommand `
        -Source (Get-CapsulenvScoopReplayScriptPath) `
        -Prefix 'replay'
}

function Invoke-CapsulenvPortableScoopReset {
    [CmdletBinding()]
    param([string[]]$Apps = @('*'))

    [void](Set-CapsulenvSessionEnvironment)
    $temporaryCommand = Install-CapsulenvTemporaryScoopCommand `
        -Source (Get-CapsulenvScoopPortableResetScriptPath) `
        -Prefix 'portable-reset'
    try {
        $arguments = @($temporaryCommand.Command) + @($Apps)
        [void](Invoke-CapsulenvScoopCommand -Arguments $arguments)
    } finally {
        if (Test-Path -LiteralPath $temporaryCommand.Path -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryCommand.Path -Force
        }
    }
}

function Invoke-CapsulenvUserScoopReset {
    [CmdletBinding()]
    param([string[]]$Apps = @('*'))

    [void](Set-CapsulenvSessionEnvironment)
    $temporaryCommand = Install-CapsulenvTemporaryScoopCommand `
        -Source (Get-CapsulenvScoopUserResetScriptPath) `
        -Prefix 'user-reset'
    try {
        $arguments = @($temporaryCommand.Command) + @($Apps)
        [void](Invoke-CapsulenvScoopCommand -Arguments $arguments)
    } finally {
        if (Test-Path -LiteralPath $temporaryCommand.Path -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryCommand.Path -Force
        }
    }
}

function Invoke-CapsulenvScoopHookReplay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('pre_install', 'post_install')]
        [string]$Hook,
        [Parameter(Mandatory = $true)][string[]]$Apps
    )

    if ($Apps.Count -eq 0) {
        return
    }
    if ((Get-CapsulenvInstallMode) -ne 'User') {
        throw 'Scoop lifecycle hook replay is disabled in ShellOnly mode because manifest hooks may write host user profile or registry state. Switch to User mode to replay hooks.'
    }

    [void](Set-CapsulenvSessionEnvironment)
    $temporaryCommand = Install-CapsulenvScoopReplayCommand
    try {
        $arguments = @($temporaryCommand.Command, $Hook) + @($Apps)
        [void](Invoke-CapsulenvScoopCommand -Arguments $arguments)
    } finally {
        if (Test-Path -LiteralPath $temporaryCommand.Path -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryCommand.Path -Force
        }
    }
}

function Invoke-CapsulenvConfiguredHookReplay {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    $groups = @{
        pre_install = New-Object System.Collections.Generic.List[string]
        post_install = New-Object System.Collections.Generic.List[string]
    }

    foreach ($app in ($configuration.Scoop.ReplayHooks.Keys | Sort-Object)) {
        foreach ($hook in @($configuration.Scoop.ReplayHooks[$app])) {
            $hookName = [string]$hook
            $groups[$hookName].Add([string]$app)
        }
    }

    foreach ($hook in @('pre_install', 'post_install')) {
        if ($groups[$hook].Count -gt 0) {
            Invoke-CapsulenvScoopHookReplay -Hook $hook -Apps @($groups[$hook])
        }
    }
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
        $PersistRepairResult
    )

    $statePath = Get-CapsulenvRehydrationStatePath
    $stateDirectory = Split-Path -Parent $statePath
    [void](New-Item -ItemType Directory -Path $stateDirectory -Force)
    $state = Get-CapsulenvRelocationFingerprint
    $state.Insert(0, 'SchemaVersion', 2)
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

function Assert-CapsulenvGlobalScoopResetAccess {
    [CmdletBinding()]
    param()

    $appsRoot = Join-Path (Get-CapsulenvScoopGlobalRoot) 'apps'
    if (-not (Test-Path -LiteralPath $appsRoot -PathType Container)) {
        return
    }
    $globalApps = @(
        Get-ChildItem -LiteralPath $appsRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'scoop' } |
            Select-Object -ExpandProperty Name
    )
    if ($globalApps.Count -eq 0 -or (Test-CapsulenvAdministrator)) {
        return
    }

    $summary = @($globalApps | Sort-Object | Select-Object -First 8) -join ', '
    if ($globalApps.Count -gt 8) {
        $summary += (', ... ({0} total)' -f $globalApps.Count)
    }
    throw "Portable Scoop global apps require an elevated terminal for relocation rehydration: $summary"
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
    Assert-CapsulenvGlobalScoopResetAccess
    [void](Reset-CapsulenvScoop -IntegrationMode $IntegrationMode)
    if (-not $SkipHooks -and $IntegrationMode -eq 'User') {
        Invoke-CapsulenvConfiguredHookReplay
    } elseif (-not $SkipHooks -and $IntegrationMode -eq 'ShellOnly') {
        Write-CapsulenvMessage -Level Detail -Message 'ShellOnly mode skips manifest lifecycle replay because hooks may modify host user profile/registry state.'
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
    Save-CapsulenvRehydrationState -RelocationContext $relocationContext -PersistRepairResult $repairResult
    Write-CapsulenvMessage -Level Success -Message "Portable Scoop rehydration completed in $IntegrationMode mode."
}

function Find-CapsulenvExecutable {
    [CmdletBinding()]
    param(
        [string[]]$Candidates,
        [string[]]$CommandNames
    )

    foreach ($candidate in $Candidates) {
        $resolved = Resolve-CapsulenvPath -Path $candidate -AllowMissing
        if (Test-Path -LiteralPath $resolved -PathType Leaf) {
            return $resolved
        }
    }
    $portableRoots = @(
        [System.IO.Path]::GetFullPath((Get-CapsulenvScoopRoot)).TrimEnd('\', '/'),
        [System.IO.Path]::GetFullPath((Get-CapsulenvScoopGlobalRoot)).TrimEnd('\', '/')
    )
    foreach ($name in $CommandNames) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue
        if (-not $command) {
            continue
        }
        $source = [System.IO.Path]::GetFullPath([string]$command.Source)
        $separator = [System.IO.Path]::DirectorySeparatorChar
        foreach ($portableRoot in $portableRoots) {
            $rootPrefix = $portableRoot + $separator
            if ($source.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $source
            }
        }
    }
    return $null
}

##MOD_EXEC## Export-ModuleMember -Function Reset-CapsulenvScoop, Invoke-CapsulenvScoopRehydrate, Invoke-CapsulenvScoopHookReplay, Test-CapsulenvScoopRehydrationRequired
