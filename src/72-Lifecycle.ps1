function Get-CapsulenvOwnedProcesses {
    [CmdletBinding()]
    param()

    $context = Get-CapsulenvContext
    $root = [System.IO.Path]::GetFullPath($context.Root).TrimEnd([char[]]'\/')
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        if ($process.Id -eq $PID) {
            continue
        }
        $path = $null
        try {
            $path = [string]$process.Path
        } catch {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }
        try {
            $fullPath = [System.IO.Path]::GetFullPath($path)
        } catch {
            continue
        }
        if (
            [System.StringComparer]::OrdinalIgnoreCase.Equals($fullPath.TrimEnd([char[]]'\/'), $root) -or
            $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            $results.Add([pscustomobject]@{
                Id = $process.Id
                Name = $process.ProcessName
                Path = $fullPath
                Process = $process
            })
        }
    }
    return $results.ToArray()
}

function Stop-CapsulenvOwnedProcesses {
    [CmdletBinding()]
    param([switch]$Force)

    $records = @(Get-CapsulenvOwnedProcesses)
    foreach ($record in $records) {
        try {
            [void]$record.Process.CloseMainWindow()
        } catch {
            # Console/background processes may not expose a main window.
        }
    }

    if ($records.Count -gt 0) {
        Start-Sleep -Milliseconds 500
    }
    $remaining = New-Object System.Collections.Generic.List[object]
    foreach ($record in $records) {
        if ($null -ne (Get-Process -Id $record.Id -ErrorAction SilentlyContinue)) {
            $remaining.Add($record)
        }
    }

    if ($remaining.Count -gt 0 -and $Force) {
        foreach ($record in $remaining) {
            Stop-Process -Id $record.Id -Force -ErrorAction SilentlyContinue
        }
        return @($records | Select-Object Id, Name, Path)
    }
    if ($remaining.Count -gt 0) {
        $summary = @($remaining | ForEach-Object { '{0}({1})' -f $_.Name, $_.Id }) -join ', '
        Write-CapsulenvMessage -Level Warning -Message "Capsule-owned processes are still running: $summary. Re-run eject --force to terminate them."
    }
    return @($records | Where-Object {
        $null -eq (Get-Process -Id $_.Id -ErrorAction SilentlyContinue)
    } | Select-Object Id, Name, Path)
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
    $dirtyRepositories = @(Get-CapsulenvDirtyRepositories)
    foreach ($repository in $dirtyRepositories) {
        Write-CapsulenvMessage -Level Warning -Message ("Dirty workspace repository: {0} ({1} change line(s))" -f $repository.Path, $repository.Changes)
    }

    $stopped = @(Stop-CapsulenvOwnedProcesses -Force:$Force)
    $statePath = Write-CapsulenvEjectState -DirtyRepositories $dirtyRepositories -StoppedProcesses $stopped

    $scratch = Get-CapsulenvScratchPath
    if (Test-Path -LiteralPath $scratch -PathType Container) {
        try {
            Remove-Item -LiteralPath $scratch -Recurse -Force
        } catch {
            Write-CapsulenvMessage -Level Warning -Message "Unable to remove host-local scratch directory: $scratch. $($_.Exception.Message)"
        }
    }

    # Deliberately do not call Restore-CapsulenvUserEnvironment here. User mode
    # represents integration ownership for the current user session, not a
    # teardown obligation. restore-user remains an explicit reversible action.
    Write-CapsulenvMessage -Level Success -Message "Capsulenv session ejected without changing install mode. State: $statePath"
    return [pscustomobject]@{
        Mode = Get-CapsulenvInstallMode
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
                Name = $directory.Name
                Scope = $scope.Name
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
                Path = $path
            }
        } catch {
            continue
        }
    }
    return $null
}

function Get-CapsulenvVersionDrift {
    [CmdletBinding()]
    param()

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($app in @(Get-CapsulenvInstalledScoopApps)) {
        $available = Get-CapsulenvBucketManifestForApp -Name $app.Name -PreferredBucket $app.Bucket
        $status = 'Unknown'
        $availableVersion = $null
        $bucket = $app.Bucket
        if ($null -ne $available) {
            $availableVersion = $available.Version
            $bucket = $available.Bucket
            if (-not [string]::IsNullOrWhiteSpace($app.Version) -and $app.Version -eq $available.Version) {
                $status = 'Current'
            } elseif (-not [string]::IsNullOrWhiteSpace($app.Version)) {
                $status = 'Drift'
            }
        }
        $results.Add([pscustomobject]@{
            Name = $app.Name
            Scope = $app.Scope
            Installed = $app.Version
            Available = $availableVersion
            Bucket = $bucket
            Status = $status
        })
    }
    return $results.ToArray()
}

function Get-CapsulenvOfflineReadiness {
    [CmdletBinding()]
    param()

    $scoopRoot = Get-CapsulenvScoopRoot
    $configuration = Get-CapsulenvConfiguration
    $cacheRoot = Resolve-CapsulenvPath -Path ([string]$configuration.Scoop.Cache) -AllowMissing
    $apps = @(Get-CapsulenvInstalledScoopApps)
    $missingManifests = @($apps | Where-Object { -not $_.Ready })
    $cacheFiles = @()
    if (Test-Path -LiteralPath $cacheRoot -PathType Container) {
        $cacheFiles = @(Get-ChildItem -LiteralPath $cacheRoot -File -Recurse -ErrorAction SilentlyContinue)
    }
    $cacheBytes = [int64]0
    if ($cacheFiles.Count -gt 0) {
        $cacheBytes = [int64](($cacheFiles | Measure-Object -Property Length -Sum).Sum)
    }
    return [pscustomobject]@{
        RunReady = (
            (Test-Path -LiteralPath (Join-Path $scoopRoot 'apps/scoop/current/bin/scoop.ps1') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $scoopRoot 'buckets/main') -PathType Container) -and
            $missingManifests.Count -eq 0
        )
        ScoopCore = Test-Path -LiteralPath (Join-Path $scoopRoot 'apps/scoop/current/bin/scoop.ps1') -PathType Leaf
        MainBucket = Test-Path -LiteralPath (Join-Path $scoopRoot 'buckets/main') -PathType Container
        InstalledApps = $apps.Count
        MissingInstalledManifests = $missingManifests.Count
        CacheRoot = $cacheRoot
        CacheFiles = $cacheFiles.Count
        CacheBytes = $cacheBytes
    }
}

function Invoke-CapsulenvOfflinePrefetch {
    [CmdletBinding()]
    param([string[]]$Apps = @())

    [void](Set-CapsulenvSessionEnvironment)
    [void](Initialize-CapsulenvScoopBootstrap)
    $installed = @(Get-CapsulenvInstalledScoopApps)
    if ($Apps.Count -gt 0) {
        $requested = @($Apps | Sort-Object -Unique)
        $installed = @($installed | Where-Object { $requested -contains $_.Name })
        $missing = @($requested | Where-Object { $_ -notin @($installed | Select-Object -ExpandProperty Name) })
        if ($missing.Count -gt 0) {
            throw "Prefetch currently accepts installed Scoop apps only. Not installed: $($missing -join ', ')"
        }
    }

    foreach ($app in $installed) {
        # `scoop download` is cache-scoped rather than install-scope-scoped; it
        # has no -g switch. Keep the local bucket snapshot stable while warming
        # the cache, and qualify the bucket when install metadata records one.
        $appReference = if ([string]::IsNullOrWhiteSpace([string]$app.Bucket)) {
            [string]$app.Name
        } else {
            '{0}/{1}' -f $app.Bucket, $app.Name
        }
        [void](Invoke-CapsulenvScoopCommand -Arguments @('download', '--no-update-scoop', $appReference))
    }
    return Get-CapsulenvOfflineReadiness
}

##MOD_EXEC## Export-ModuleMember -Function Invoke-CapsulenvEject, Get-CapsulenvOfflineReadiness, Invoke-CapsulenvOfflinePrefetch, Get-CapsulenvVersionDrift
