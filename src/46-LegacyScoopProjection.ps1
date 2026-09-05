function Get-CapsulenvLegacyScoopLocation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Selector)

    $parsed = Split-CapsulenvScoopAppSelector -Selector $Selector
    if ([string]$parsed.Scope -eq 'Capsule') {
        throw (New-CapsulenvDiagnosticErrorRecord `
            -Id 'Capsulenv.LegacyScoopProjection.SelectorNotOwned' `
            -Message "Legacy Scoop projection does not own Capsulenv package selector '$Selector'." `
            -TargetObject $Selector `
            -Remediation @('Use capsule/<app> for a Capsulenv-owned package, or an explicit scoop/user or scoop/global selector for upstream Scoop state.'))
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
        throw (New-CapsulenvDiagnosticErrorRecord `
            -Id 'Capsulenv.LegacyScoopProjection.NotInstalled' `
            -Message "Legacy Scoop app is not installed in the capsule: $Selector" `
            -Category ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
            -TargetObject $Selector)
    }
    if ($matches.Count -gt 1) {
        throw (New-CapsulenvDiagnosticErrorRecord `
            -Id 'Capsulenv.LegacyScoopProjection.AmbiguousScope' `
            -Message "Legacy Scoop app '$($parsed.Name)' exists in both user and global roots." `
            -TargetObject $Selector `
            -Context ([ordered]@{ App = [string]$parsed.Name }) `
            -Remediation @("Use scoop:user/$($parsed.Name) or scoop:global/$($parsed.Name) explicitly."))
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
        throw (New-CapsulenvDiagnosticErrorRecord `
            -Id 'Capsulenv.LegacyScoopProjection.NoVersionEvidence' `
            -Message "No installed version metadata is available for legacy Scoop app '$($Location.Selector)'." `
            -TargetObject $Location.Selector `
            -Context ([ordered]@{ Selector = [string]$Location.Selector; AppRoot = [string]$Location.AppRoot }) `
            -Remediation @("Run upstream 'scoop reset $($Location.Name)' explicitly, or reinstall/migrate the package."))
    }
    throw (New-CapsulenvDiagnosticErrorRecord `
        -Id 'Capsulenv.LegacyScoopProjection.AmbiguousVersion' `
        -Message "Cannot prove the active version for legacy Scoop app '$($Location.Selector)' because current is stale and multiple versions exist." `
        -TargetObject $Location.Selector `
        -Context ([ordered]@{ Selector = [string]$Location.Selector; CandidateCount = [int]$candidates.Count }) `
        -Remediation @("Run upstream 'scoop reset $($Location.Name)' explicitly, or reinstall/migrate the package."))
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
            throw (New-CapsulenvDiagnosticErrorRecord `
                -Id 'Capsulenv.LegacyScoopProjection.PersistConflict' `
                -Message "Refusing to replace a normal directory while repairing legacy Scoop persist projection: $source" `
                -TargetObject $source `
                -Context ([ordered]@{ Source = $source; Target = $target }) `
                -Remediation @('Resolve the upstream Scoop persist projection explicitly before retrying Capsulenv relocation repair.'))
        }

        try {
            Repair-CapsulenvPackageFileProjection `
                -Path $source `
                -Target $target `
                -OwnershipLabel 'legacy Scoop persist projection'
        } catch {
            throw (ConvertTo-CapsulenvDiagnosticErrorRecord `
                -ErrorRecord $_ `
                -Id 'Capsulenv.LegacyScoopProjection.PersistConflict' `
                -Message "Capsulenv cannot safely repair the legacy Scoop persist file projection: $source" `
                -TargetObject $source `
                -Context ([ordered]@{ Source = $source; Target = $target }) `
                -Remediation @('Resolve the upstream Scoop persist projection explicitly before retrying Capsulenv relocation repair.'))
        }
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
        throw (New-CapsulenvDiagnosticErrorRecord `
            -Id 'Capsulenv.LegacyScoopProjection.AppRunning' `
            -Message "Legacy Scoop app is running; close it before repairing its projection: $($location.Selector)" `
            -TargetObject $location.Selector `
            -Remediation @('Close the app and retry; automatic User-mode rehydration will retry deferred running apps on the next session.'))
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

function New-CapsulenvLegacyProjectionIssue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Selector,
        [Parameter(Mandatory = $true)][string]$ErrorId,
        [Parameter(Mandatory = $true)][string]$Summary,
        [AllowEmptyCollection()][string[]]$Remediation = @(),
        [bool]$Retryable = $false
    )

    return [pscustomobject][ordered]@{
        Selector = $Selector
        ErrorId = $ErrorId
        Summary = $Summary
        Remediation = [string[]]@($Remediation)
        Retryable = $Retryable
    }
}

function Get-CapsulenvPackageProjectionRepairDescriptors {
    [CmdletBinding()]
    param([string[]]$Apps = @('*'))

    $requested = @($Apps)
    if ($requested.Count -eq 0) { $requested = @('*') }
    $repairAll = $requested -contains '*'
    $descriptors = New-Object System.Collections.Generic.List[object]

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
        $descriptors.Add([pscustomobject][ordered]@{
            Kind = 'Owned'
            Selector = ('capsule/{0}' -f $name)
            Name = $name
            Scope = 'Capsule'
            Shims = [string[]]@($state.Shims)
        })
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
        $parsed = Split-CapsulenvScoopAppSelector -Selector ([string]$selector)
        $scope = if ($null -ne $parsed.Scope) { [string]$parsed.Scope } else { 'Legacy' }
        $descriptors.Add([pscustomobject][ordered]@{
            Kind = 'Legacy'
            Selector = [string]$selector
            Name = [string]$parsed.Name
            Scope = $scope
            Shims = [string[]]@()
        })
    }
    return $descriptors.ToArray()
}

function Invoke-CapsulenvPackageProjectionDescriptor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Descriptor,
        [switch]$DeferRunningApps,
        [switch]$DeferUnsafeLegacyProjectionFailures
    )

    if ([string]$Descriptor.Kind -eq 'Owned') {
        $state = Get-CapsulenvInstalledPackageState -Name ([string]$Descriptor.Name)
        Repair-CapsulenvPackageProjection -State $state
        [void](Sync-CapsulenvPackageShims -Name ([string]$Descriptor.Name))
        return [pscustomobject][ordered]@{
            Kind='Owned'; Selector=[string]$Descriptor.Selector; Repaired=$true; Issue=$null
        }
    }

    $selector = [string]$Descriptor.Selector
    try {
        $completed = Repair-CapsulenvLegacyScoopAppProjection -Selector $selector -DeferRunningApps:$DeferRunningApps
        if ($completed) {
            return [pscustomobject][ordered]@{ Kind='Legacy'; Selector=$selector; Repaired=$true; Issue=$null }
        }
        $issue = New-CapsulenvLegacyProjectionIssue `
            -Selector $selector `
            -ErrorId 'Capsulenv.LegacyScoopProjection.AppRunning' `
            -Summary "Legacy Scoop app is running; projection repair was deferred: $selector" `
            -Remediation @('Close the app; automatic User-mode rehydration will retry the projection on the next session.') `
            -Retryable $true
        return [pscustomobject][ordered]@{ Kind='Legacy'; Selector=$selector; Repaired=$false; Issue=$issue }
    } catch {
        $isLegacySafetyBoundary = (
            (Test-CapsulenvDiagnosticErrorRecord -ErrorRecord $_) -and
            ([string]$_.FullyQualifiedErrorId -like 'Capsulenv.LegacyScoopProjection.*')
        )
        if (-not $DeferUnsafeLegacyProjectionFailures -or -not $isLegacySafetyBoundary) {
            throw
        }
        $summary = if ($null -ne $_.ErrorDetails -and -not [string]::IsNullOrWhiteSpace([string]$_.ErrorDetails.Message)) {
            [string]$_.ErrorDetails.Message
        } else {
            [string]$_.Exception.Message
        }
        $remediation = @(Get-CapsulenvDiagnosticRemediation -ErrorRecord $_)
        $issue = New-CapsulenvLegacyProjectionIssue `
            -Selector $selector `
            -ErrorId ([string]$_.FullyQualifiedErrorId) `
            -Summary $summary `
            -Remediation $remediation
        Write-CapsulenvMessage -Level Warning -Message ("Legacy Scoop projection was left unchanged for '{0}': {1}" -f $selector, $summary)
        if ($remediation.Count -gt 0) {
            Write-CapsulenvMessage -Level Detail -Message ([string]$remediation[0])
        }
        return [pscustomobject][ordered]@{ Kind='Legacy'; Selector=$selector; Repaired=$false; Issue=$issue }
    }
}

function Merge-CapsulenvPackageProjectionResults {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Results = @())

    $issues = @($Results | ForEach-Object { if ($null -ne $_ -and $null -ne $_.Issue) { $_.Issue } })
    return [pscustomobject][ordered]@{
        Complete = ($issues.Count -eq 0)
        RetryRequired = (@($issues | Where-Object { [bool]$_.Retryable }).Count -gt 0)
        OwnedPackagesRepaired = @($Results | Where-Object { $_.Kind -eq 'Owned' -and [bool]$_.Repaired }).Count
        LegacyAppsRepaired = @($Results | Where-Object { $_.Kind -eq 'Legacy' -and [bool]$_.Repaired }).Count
        Issues = $issues
    }
}

function Invoke-CapsulenvInstalledAppProjectionRepair {
    [CmdletBinding()]
    param(
        [string[]]$Apps = @('*'),
        [switch]$DeferRunningApps,
        [switch]$DeferUnsafeLegacyProjectionFailures,
        [ValidateSet('ShellOnly', 'User')]
        [string]$IntegrationMode = (Get-CapsulenvInstallMode)
    )

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($descriptor in @(Get-CapsulenvPackageProjectionRepairDescriptors -Apps $Apps)) {
        $results.Add((Invoke-CapsulenvPackageProjectionDescriptor `
            -Descriptor $descriptor `
            -DeferRunningApps:$DeferRunningApps `
            -DeferUnsafeLegacyProjectionFailures:$DeferUnsafeLegacyProjectionFailures))
    }
    return Merge-CapsulenvPackageProjectionResults -Results $results.ToArray()
}

function Repair-CapsulenvInstalledAppProjections {
    [CmdletBinding()]
    param(
        [string[]]$Apps = @('*'),
        [switch]$DeferRunningApps,
        [ValidateSet('ShellOnly', 'User')]
        [string]$IntegrationMode = (Get-CapsulenvInstallMode)
    )

    $report = Invoke-CapsulenvInstalledAppProjectionRepair `
        -Apps $Apps `
        -DeferRunningApps:$DeferRunningApps `
        -IntegrationMode $IntegrationMode
    if ($IntegrationMode -eq 'User') {
        Sync-CapsulenvPackageStartMenuShortcuts -IntegrationMode $IntegrationMode
    }
    return [bool]$report.Complete
}

##MOD_EXEC## Export-ModuleMember -Function Repair-CapsulenvInstalledAppProjections
