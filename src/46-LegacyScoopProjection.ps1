function Get-CapsulenvLegacyScoopLocation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Selector)

    $parsed = Split-CapsulenvScoopAppSelector -Selector $Selector
    if ([string]$parsed.Scope -eq 'Capsule') {
        throw "Legacy Scoop projection does not own Capsulenv package selector '$Selector'."
    }

    $candidateScopes = if ($null -ne $parsed.Scope) { @([string]$parsed.Scope) } else { @('User', 'Global') }
    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($scope in $candidateScopes) {
        $record = Get-CapsulenvScoopAppRootRecord -Scope $scope
        $appRoot = Join-Path $record.AppsRoot ([string]$parsed.Name)
        if (-not (Test-Path -LiteralPath $appRoot -PathType Container)) {
            continue
        }
        $matches.Add([pscustomobject]@{
            Scope = $scope
            Name = [string]$parsed.Name
            Selector = ('{0}/{1}' -f $scope.ToLowerInvariant(), $parsed.Name)
            Root = [string]$record.Root
            AppRoot = $appRoot
            CurrentRoot = Join-Path $appRoot 'current'
            PersistRoot = Join-Path $record.PersistRoot ([string]$parsed.Name)
        })
    }

    if ($matches.Count -eq 0) {
        throw "Legacy Scoop app is not installed in the capsule: $Selector"
    }
    if ($matches.Count -gt 1) {
        throw "Legacy Scoop app '$($parsed.Name)' exists in both user and global roots. Use scoop:user/$($parsed.Name) or scoop:global/$($parsed.Name)."
    }
    return $matches[0]
}

function Get-CapsulenvLegacyScoopSelectors {
    [CmdletBinding()]
    param()

    $results = New-Object System.Collections.Generic.List[string]
    foreach ($scope in @('User', 'Global')) {
        $record = Get-CapsulenvScoopAppRootRecord -Scope $scope
        if (-not (Test-Path -LiteralPath $record.AppsRoot -PathType Container)) {
            continue
        }
        foreach ($directory in @(Get-ChildItem -LiteralPath $record.AppsRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            if ($directory.Name -eq 'scoop') { continue }
            $results.Add(('{0}/{1}' -f $scope.ToLowerInvariant(), $directory.Name))
        }
    }
    return $results.ToArray()
}

function Test-CapsulenvLegacyScoopVersionRootCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Location,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $candidate = [System.IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $candidate
    if (-not (Test-CapsulenvSamePath -Left $parent -Right ([string]$Location.AppRoot))) {
        return $false
    }
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals((Split-Path -Leaf $candidate), 'current')) {
        return $false
    }
    # Scoop version roots are physical directories. Following another reparse
    # point here would let a stale/foreign projection redirect Capsulenv's
    # bounded repair outside the app root.
    if ($null -ne (Get-CapsulenvReparseTarget -Path $candidate)) {
        return $false
    }
    return (
        (Test-Path -LiteralPath (Join-Path $candidate 'manifest.json') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $candidate 'install.json') -PathType Leaf)
    )
}

function Resolve-CapsulenvLegacyScoopVersionRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Location)

    $currentManifest = Join-Path $Location.CurrentRoot 'manifest.json'
    $currentInstall = Join-Path $Location.CurrentRoot 'install.json'
    if (
        (Test-Path -LiteralPath $currentManifest -PathType Leaf) -and
        (Test-Path -LiteralPath $currentInstall -PathType Leaf)
    ) {
        $resolvedCurrent = Get-CapsulenvReparseTarget -Path $Location.CurrentRoot
        if (
            $null -ne $resolvedCurrent -and
            (Test-CapsulenvLegacyScoopVersionRootCandidate -Location $Location -Path $resolvedCurrent)
        ) {
            return $resolvedCurrent
        }
        # A normal current directory is unusual but already usable. Do not
        # replace it without ownership evidence.
        if ($null -eq $resolvedCurrent) {
            return $Location.CurrentRoot
        }
    }

    $staleTarget = Get-CapsulenvReparseTarget -Path $Location.CurrentRoot
    if ($null -ne $staleTarget) {
        $staleVersion = Split-Path -Leaf $staleTarget
        if (-not [string]::IsNullOrWhiteSpace($staleVersion)) {
            $candidate = Join-Path $Location.AppRoot $staleVersion
            if (Test-CapsulenvLegacyScoopVersionRootCandidate -Location $Location -Path $candidate) {
                return $candidate
            }
        }
    }

    $candidates = @(
        Get-ChildItem -LiteralPath $Location.AppRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                Test-CapsulenvLegacyScoopVersionRootCandidate -Location $Location -Path $_.FullName
            }
    )
    if ($candidates.Count -eq 1) {
        return [string]$candidates[0].FullName
    }
    if ($candidates.Count -eq 0) {
        throw "No installed version metadata is available for legacy Scoop app '$($Location.Selector)'."
    }
    throw "Cannot prove the active version for legacy Scoop app '$($Location.Selector)' because current is stale and multiple versions exist. Run upstream 'scoop reset $($Location.Name)' explicitly, or reinstall/migrate the package."
}

function Test-CapsulenvLegacyScoopAppHasBlockingProcesses {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Location)

    $appRoot = [System.IO.Path]::GetFullPath([string]$Location.AppRoot).TrimEnd([char[]]'\/')
    $prefix = $appRoot + [System.IO.Path]::DirectorySeparatorChar
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        if ($process.Id -eq $PID) { continue }
        try {
            $path = [string]$process.Path
            if ([string]::IsNullOrWhiteSpace($path)) { continue }
            $fullPath = [System.IO.Path]::GetFullPath($path)
            if (
                [System.StringComparer]::OrdinalIgnoreCase.Equals($fullPath, $appRoot) -or
                $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
            ) {
                return $true
            }
        } catch {
            continue
        }
    }
    return $false
}

function Get-CapsulenvLegacyPersistDefinitions {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Installed)

    $persistProperty = Get-CapsulenvInstalledManifestPropertyRecord -App $Installed -Name 'persist'
    if ($null -eq $persistProperty.Value) { return @() }
    return @(Get-CapsulenvPackagePersistDefinitions -Plan ([pscustomobject]@{ Persist = $persistProperty.Value }))
}

function Repair-CapsulenvLegacyPersistProjection {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Installed)

    foreach ($definition in @(Get-CapsulenvLegacyPersistDefinitions -Installed $Installed)) {
        $source = Resolve-CapsulenvScoopAppRelativePath -Root $Installed.Current -RelativePath ([string]$definition.Source)
        $target = Resolve-CapsulenvScoopAppRelativePath -Root $Installed.Persist -RelativePath ([string]$definition.Target)
        if (-not (Test-Path -LiteralPath $target)) {
            Write-CapsulenvMessage -Level Detail -Message "Legacy Scoop persist target is absent; leaving upstream-owned state unchanged: $target"
            continue
        }

        $targetItem = Get-Item -LiteralPath $target -Force
        if ($targetItem.PSIsContainer) {
            $existingTarget = Get-CapsulenvReparseTarget -Path $source
            if ($null -ne $existingTarget) {
                if (-not (Test-CapsulenvSamePath -Left $existingTarget -Right $target)) {
                    Set-CapsulenvPackageDirectoryLink -Path $source -Target $target
                }
                continue
            }
            if (-not (Test-Path -LiteralPath $source)) {
                Set-CapsulenvPackageDirectoryLink -Path $source -Target $target
                continue
            }
            throw "Refusing to replace a normal directory while repairing legacy Scoop persist projection: $source"
        }

        Repair-CapsulenvPackageFileProjection `
            -Path $source `
            -Target $target `
            -OwnershipLabel 'legacy Scoop persist projection'
    }
}

function Repair-CapsulenvLegacyScoopAppProjection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Selector,
        [switch]$DeferRunningApps
    )

    $location = Get-CapsulenvLegacyScoopLocation -Selector $Selector
    if (Test-CapsulenvLegacyScoopAppHasBlockingProcesses -Location $location) {
        if ($DeferRunningApps) {
            Write-CapsulenvMessage -Level Warning -Message "Deferring legacy Scoop projection repair for '$($location.Selector)' until its running processes exit."
            return $false
        }
        throw "Legacy Scoop app is running; close it before repairing its projection: $($location.Selector)"
    }

    $versionRoot = Resolve-CapsulenvLegacyScoopVersionRoot -Location $location
    if (Test-CapsulenvSamePath -Left $versionRoot -Right $location.CurrentRoot) {
        # A normal current directory may be usable, but Capsulenv cannot prove it
        # is an upstream-owned projection. Do not create persist links inside it.
        Write-CapsulenvMessage -Level Detail -Message "Legacy Scoop current is a normal directory; leaving its upstream-owned contents unchanged: $($location.CurrentRoot)"
        return $true
    }
    Set-CapsulenvPackageDirectoryLink -Path $location.CurrentRoot -Target $versionRoot
    $installed = Get-CapsulenvInstalledApp -Selector $location.Selector
    Repair-CapsulenvLegacyPersistProjection -Installed $installed
    return $true
}

function Repair-CapsulenvInstalledAppProjections {
    [CmdletBinding()]
    param(
        [string[]]$Apps = @('*'),
        [switch]$DeferRunningApps,
        [ValidateSet('ShellOnly', 'User')]
        [string]$IntegrationMode = (Get-CapsulenvInstallMode)
    )

    $requested = @($Apps)
    if ($requested.Count -eq 0) { $requested = @('*') }
    $repairAll = $requested -contains '*'
    $deferred = $false

    $safeStates = @(Get-CapsulenvInstalledPackageStates -Strict)
    $safeNames = @($safeStates | ForEach-Object { [string]$_.Name })
    $safeRequested = if ($repairAll) {
        $safeNames
    } else {
        @($requested | ForEach-Object {
            $parsed = Split-CapsulenvScoopAppSelector -Selector ([string]$_)
            if ([string]$parsed.Scope -eq 'Capsule' -or ($null -eq $parsed.Scope -and $safeNames -contains [string]$parsed.Name)) {
                [string]$parsed.Name
            }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
    }
    foreach ($name in @($safeRequested)) {
        $state = Get-CapsulenvInstalledPackageState -Name $name
        Repair-CapsulenvPackageProjection -State $state
        [void](Sync-CapsulenvPackageShims -Name $name)
    }

    $legacyRequested = if ($repairAll) {
        @(Get-CapsulenvLegacyScoopSelectors)
    } else {
        @(
            foreach ($selector in $requested) {
                $parsed = Split-CapsulenvScoopAppSelector -Selector ([string]$selector)
                if ([string]$parsed.Scope -eq 'Capsule') { continue }
                if ($null -eq $parsed.Scope -and $safeNames -contains [string]$parsed.Name) { continue }
                [string]$selector
            }
        )
    }
    foreach ($selector in @($legacyRequested)) {
        $completed = Repair-CapsulenvLegacyScoopAppProjection -Selector $selector -DeferRunningApps:$DeferRunningApps
        if (-not $completed) { $deferred = $true }
    }

    if ($IntegrationMode -eq 'User') {
        Sync-CapsulenvPackageStartMenuShortcuts
    }
    return (-not $deferred)
}

##MOD_EXEC## Export-ModuleMember -Function Repair-CapsulenvInstalledAppProjections
