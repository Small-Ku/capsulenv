function Get-CapsulenvOwnedProcesses {
    [CmdletBinding()]
    param()

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($record in @(Get-CapsulenvOwnedProcessRecords)) {
        $process = Get-Process -Id ([int]$record.PID) -ErrorAction SilentlyContinue
        if ($null -eq $process) { continue }
        $path = $null
        try { $path = [string]$process.Path } catch {}
        $results.Add([pscustomobject]@{
            Id = $process.Id
            Name = $process.ProcessName
            Path = $path
            Process = $process
            ProcessRecord = $record
        })
    }
    return $results.ToArray()
}

function Stop-CapsulenvOwnedProcesses {
    [CmdletBinding()]
    param([switch]$Force)

    $records = @(Get-CapsulenvOwnedProcessRecords)
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($record in $records) {
        $result = Stop-CapsulenvOwnedProcessRecord -ProcessRecord $record
        $results.Add([pscustomobject]@{
            Id = $record.PID
            Name = $record.Role
            Path = $record.Provenance
            Stopped = $result.Stopped
            Reason = $result.Reason
        })
    }
    if ($Force) {
        return $results.ToArray()
    }
    return $results.ToArray()
}

function Get-CapsulenvWorkspaceRepositoryPaths {
    [CmdletBinding()]
    param()

    $workspace = Resolve-CapsulenvPath -Path 'workspace' -AllowMissing
    if (-not (Test-Path -LiteralPath $workspace -PathType Container)) {
        return @()
    }
    $candidates = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath (Join-Path $workspace '.git')) {
        $candidates.Add($workspace)
    }
    foreach ($directory in @(Get-ChildItem -LiteralPath $workspace -Directory -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath (Join-Path $directory.FullName '.git')) {
            $candidates.Add($directory.FullName)
        }
    }
    return $candidates.ToArray()
}

function Get-CapsulenvDirtyRepositories {
    [CmdletBinding()]
    param()

    $repositories = @(Get-CapsulenvWorkspaceRepositoryPaths)
    if ($repositories.Count -eq 0) {
        return @()
    }
    $git = $null
    try {
        $git = Get-CapsulenvGitCommand
    } catch {
        Write-CapsulenvMessage -Level Warning -Message 'Git is unavailable; eject cannot inspect workspace repository dirtiness.'
        return @()
    }

    $dirty = New-Object System.Collections.Generic.List[object]
    foreach ($repository in $repositories) {
        Clear-CapsulenvLastExitCode
        $status = & $git -C $repository status --porcelain 2>$null
        $exitCode = Get-CapsulenvLastExitCode -Succeeded $?
        if ($exitCode -ne 0) {
            continue
        }
        if (@($status).Count -gt 0) {
            $dirty.Add([pscustomobject]@{
                Path = $repository
                Reference = ConvertTo-CapsulenvStatePathReference -Path $repository
                Changes = @($status).Count
            })
        }
    }
    return $dirty.ToArray()
}

function Write-CapsulenvEjectState {
    [CmdletBinding()]
    param(
        [object[]]$DirtyRepositories = @(),
        [object[]]$StoppedProcesses = @()
    )

    $context = Get-CapsulenvContext
    $path = Join-Path $context.StateRoot 'eject-state.json'
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
    [ordered]@{
        SchemaVersion = 1
        CapsuleId = Get-CapsulenvIdentity
        Root = ConvertTo-CapsulenvStatePathReference -Path $context.Root
        Mode = Get-CapsulenvInstallMode
        EjectedAtUtc = [DateTime]::UtcNow.ToString('o')
        DirtyRepositories = @($DirtyRepositories | ForEach-Object {
            [ordered]@{ Reference = $_.Reference; Changes = $_.Changes }
        })
        StoppedProcesses = @($StoppedProcesses | ForEach-Object {
            [ordered]@{ Name = $_.Name; Path = ConvertTo-CapsulenvStatePathReference -Path $_.Path }
        })
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Invoke-CapsulenvEject {
    [CmdletBinding()]
    param([switch]$Force)

    [void](Set-CapsulenvSessionEnvironment)
    [void](Invoke-CapsulenvRoutines -Trigger OnEject)
    $serviceStops = @(Stop-CapsulenvActiveSessionServices)
    $dirtyRepositories = @(Get-CapsulenvDirtyRepositories)
    foreach ($repository in $dirtyRepositories) {
        Write-CapsulenvMessage -Level Warning -Message ("Dirty workspace repository: {0} ({1} change line(s))" -f $repository.Path, $repository.Changes)
    }

    $stopped = @(Stop-CapsulenvOwnedProcesses -Force:$Force)
    $remainingProcesses = @(Get-CapsulenvOwnedProcesses)
    if ($remainingProcesses.Count -gt 0) {
        $summary = @($remainingProcesses | ForEach-Object { '{0}({1})' -f $_.Name, $_.Id }) -join ', '
        if ($Force) {
            throw "Forced eject could not stop all capsule-owned processes: $summary"
        }
        throw "Eject blocked because capsule-owned processes are still running: $summary. Close them or re-run eject --force."
    }
    $activeLeases = @(Get-CapsulenvActiveExclusiveStateLeases)
    if ($activeLeases.Count -gt 0) {
        $summary = @($activeLeases | ForEach-Object { '{0}:{1}' -f $_.SessionId, $_.StatePath }) -join ', '
        throw "Eject blocked because active exclusive state leases remain: $summary. Close the owning binding before removing the capsule."
    }

    $statePath = Write-CapsulenvEjectState -DirtyRepositories $dirtyRepositories -StoppedProcesses $stopped

    $scratch = Get-CapsulenvScratchPath
    if (Test-Path -LiteralPath $scratch -PathType Container) {
        try {
            Remove-Item -LiteralPath $scratch -Recurse -Force
        } catch {
            Write-CapsulenvMessage -Level Warning -Message "Unable to remove host-local scratch directory: $scratch. $($_.Exception.Message)"
        }
    }

    # Deliberately do not call Restore-CapsulenvUserEnvironment here. Persistent
    # User integration is host ownership state, not the lifetime of this process
    # tree. restore-user remains an explicit reversible action.
    $mode = Get-CapsulenvInstallMode
    $persistentMode = Get-CapsulenvUserIntegrationMode
    if ($persistentMode -eq 'User') {
        Write-CapsulenvMessage -Level Warning -Message 'Persistent User integration remains active. Run restore-user before removing the capsule from a host that will continue to be used.'
    }
    Write-CapsulenvMessage -Level Success -Message "Capsulenv session ejected. Session mode was $mode; persistent integration is $persistentMode. State: $statePath"
    return [pscustomobject]@{
        Mode = $mode
        DirtyRepositories = $dirtyRepositories.Count
        StoppedProcesses = $stopped.Count
        ScratchRemoved = -not (Test-Path -LiteralPath $scratch)
        StatePath = $statePath
    }
}

function Get-CapsulenvInstalledScoopApps {
    [CmdletBinding()]
    param()

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($scope in @(
        [pscustomobject]@{ Name = 'User'; Root = Get-CapsulenvScoopRoot },
        [pscustomobject]@{ Name = 'Global'; Root = Get-CapsulenvScoopGlobalRoot }
    )) {
        $appsRoot = Join-Path $scope.Root 'apps'
        if (-not (Test-Path -LiteralPath $appsRoot -PathType Container)) {
            continue
        }
        foreach ($directory in @(Get-ChildItem -LiteralPath $appsRoot -Directory -ErrorAction SilentlyContinue)) {
            if ($directory.Name -eq 'scoop') {
                continue
            }
            $current = Join-Path $directory.FullName 'current'
            $manifestPath = Join-Path $current 'manifest.json'
            $installPath = Join-Path $current 'install.json'
            $version = $null
            $bucket = $null
            if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
                try {
                    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
                    $version = [string]$manifest.version
                } catch {
                    $version = $null
                }
            }
            if (Test-Path -LiteralPath $installPath -PathType Leaf) {
                try {
                    $install = Get-Content -LiteralPath $installPath -Raw | ConvertFrom-Json
                    $bucketProperty = $install.PSObject.Properties['bucket']
                    if ($null -ne $bucketProperty) {
                        $bucket = [string]$bucketProperty.Value
                    }
                } catch {
                    $bucket = $null
                }
            }
            $results.Add([pscustomobject]@{
                Provider = 'Scoop'
                ProviderScope = $scope.Name
                Ownership = 'Upstream'
                Scope = $scope.Name
                Name = $directory.Name
                Selector = ('scoop:{0}/{1}' -f ([string]$scope.Name).ToLowerInvariant(), $directory.Name)
                DisplaySelector = ('scoop/{0}' -f $directory.Name)
                Root = $scope.Root
                Version = $version
                Bucket = $bucket
                ManifestPath = $manifestPath
                Ready = (Test-Path -LiteralPath $manifestPath -PathType Leaf)
            })
        }
    }
    return $results.ToArray()
}

function Get-CapsulenvInstalledAppInventory {
    [CmdletBinding()]
    param()

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($state in @(Get-CapsulenvInstalledPackageStates)) {
        $results.Add([pscustomobject]@{
            Provider = 'Capsulenv'
            ScoopScope = ''
            App = [string]$state.Name
            Selector = [string]$state.Selector
            Version = [string]$state.Version
            Bucket = [string]$state.Bucket
            Ready = $true
        })
    }
    foreach ($app in @(Get-CapsulenvInstalledScoopApps)) {
        $results.Add([pscustomobject]@{
            Provider = 'Scoop'
            ScoopScope = [string]$app.ProviderScope
            App = [string]$app.Name
            Selector = [string]$app.Selector
            Version = [string]$app.Version
            Bucket = [string]$app.Bucket
            Ready = [bool]$app.Ready
        })
    }
    return @($results.ToArray() | Sort-Object App, Provider, ScoopScope)
}

function Get-CapsulenvBucketManifestForApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$PreferredBucket
    )

    $bucketsRoot = Join-Path (Get-CapsulenvScoopRoot) 'buckets'
    if (-not (Test-Path -LiteralPath $bucketsRoot -PathType Container)) {
        return $null
    }
    $bucketNames = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($PreferredBucket)) {
        $bucketNames.Add($PreferredBucket)
    }
    foreach ($directory in @(Get-ChildItem -LiteralPath $bucketsRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if (-not ($bucketNames -contains $directory.Name)) {
            $bucketNames.Add($directory.Name)
        }
    }
    foreach ($bucketName in $bucketNames) {
        $path = Join-Path (Join-Path (Join-Path $bucketsRoot $bucketName) 'bucket') ($Name + '.json')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        try {
            $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            return [pscustomobject]@{
                Bucket = $bucketName
                Version = [string]$manifest.version
