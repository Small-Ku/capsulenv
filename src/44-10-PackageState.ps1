function Get-CapsulenvPackageStatePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Test-CapsulenvPortableFileNameComponent -Value $Name)) {
        throw "Invalid Capsulenv package state name: $Name"
    }
    return Join-Path (Get-CapsulenvPackageStateRoot) ($Name + '.json')
}

function Get-CapsulenvInstalledPackageState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$AllowMissing
    )

    $path = Get-CapsulenvPackageStatePath -Name $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        if ($AllowMissing) { return $null }
        throw "Capsulenv package is not installed: $Name"
    }
    try {
        $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    } catch {
        throw "Capsulenv package state is invalid for '$Name': $($_.Exception.Message)"
    }
    if (
        [int]$state.SchemaVersion -ne 1 -or
        [string]$state.Provider -ne 'Capsulenv' -or
        [string]$state.Name -ne $Name
    ) {
        throw "Capsulenv package state has an unsupported schema, provider, or identity: $path"
    }
    $capsuleId = $state.PSObject.Properties['CapsuleId']
    if (
        $null -eq $capsuleId -or
        -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$capsuleId.Value, [string](Get-CapsulenvIdentity))
    ) {
        throw "Capsulenv package state belongs to another capsule identity: $path"
    }

    try {
        $reference = Split-CapsulenvPackageReference -Reference ([string]$state.Reference)
    } catch {
        throw "Capsulenv package state has an invalid source reference: $path"
    }
    if (
        [string]$reference.Name -ne $Name -or
        [string]::IsNullOrWhiteSpace([string]$reference.Bucket) -or
        [string]$reference.Bucket -ne [string]$state.Bucket -or
        -not (Test-CapsulenvPortableFileNameComponent -Value ([string]$state.Version)) -or
        [string]$state.Architecture -notin @('64bit', '32bit', 'arm64')
    ) {
        throw "Capsulenv package state has inconsistent package identity metadata: $path"
    }

    $installRoot = Resolve-CapsulenvStatePathReference -Reference ([string]$state.InstallRoot)
    $currentRoot = Resolve-CapsulenvStatePathReference -Reference ([string]$state.CurrentRoot)
    $persistRoot = Resolve-CapsulenvStatePathReference -Reference ([string]$state.PersistRoot)
    $packageRoot = Join-Path (Get-CapsulenvPackageRoot) $Name
    $expectedInstallRoot = Join-Path $packageRoot ([string]$state.Version)
    $expectedCurrentRoot = Join-Path $packageRoot 'current'
    $expectedPersistRoot = Join-Path (Get-CapsulenvPackagePersistRoot) $Name
    foreach ($rootCheck in @(
        [pscustomobject]@{ Actual = $installRoot; Expected = $expectedInstallRoot; Label = 'install' },
        [pscustomobject]@{ Actual = $currentRoot; Expected = $expectedCurrentRoot; Label = 'current' },
        [pscustomobject]@{ Actual = $persistRoot; Expected = $expectedPersistRoot; Label = 'persist' }
    )) {
        if (-not (Test-CapsulenvSamePath -Left ([string]$rootCheck.Actual) -Right ([string]$rootCheck.Expected))) {
            throw "Capsulenv package state $($rootCheck.Label) path escapes its owned projection: $path"
        }
    }

    $manifestPath = Join-Path $installRoot 'manifest.json'
    $installPath = Join-Path $installRoot 'install.json'
    foreach ($fingerprint in @(
        [pscustomobject]@{ Path = $manifestPath; Property = 'InstalledManifestSha256'; Label = 'installed manifest' },
        [pscustomobject]@{ Path = $installPath; Property = 'InstallMetadataSha256'; Label = 'install metadata' }
    )) {
        $record = $state.PSObject.Properties[[string]$fingerprint.Property]
        if (
            $null -eq $record -or
            [string]$record.Value -notmatch '^[0-9a-fA-F]{64}$' -or
            -not (Test-Path -LiteralPath ([string]$fingerprint.Path) -PathType Leaf)
        ) {
            throw "Capsulenv package state is missing trusted $($fingerprint.Label) metadata: $path"
        }
        $actualHash = Get-CapsulenvFileSha256 -Path ([string]$fingerprint.Path)
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($actualHash, [string]$record.Value)) {
            throw "Capsulenv package $($fingerprint.Label) changed outside the package executor: $($fingerprint.Path)"
        }
    }
    $sourceFingerprint = $state.PSObject.Properties['SourceManifestSha256']
    if ($null -eq $sourceFingerprint -or [string]$sourceFingerprint.Value -notmatch '^[0-9a-fA-F]{64}$') {
        throw "Capsulenv package state is missing its source manifest fingerprint: $path"
    }

    return [pscustomobject]@{
        Provider = 'Capsulenv'
        ProviderScope = $null
        Ownership = 'PortableSafe'
        Scope = 'Capsule'
        Selector = ('capsule/{0}' -f [string]$state.Name)
        DisplaySelector = ('capsule/{0}' -f [string]$state.Name)
        Path = $path
        State = $state
        Name = [string]$state.Name
        Version = [string]$state.Version
        Architecture = [string]$state.Architecture
        Bucket = [string]$state.Bucket
        Reference = [string]$state.Reference
        SourceManifestSha256 = ([string]$sourceFingerprint.Value).ToLowerInvariant()
        InstalledManifestSha256 = ([string]$state.InstalledManifestSha256).ToLowerInvariant()
        InstallMetadataSha256 = ([string]$state.InstallMetadataSha256).ToLowerInvariant()
        InstallRoot = $installRoot
        CurrentRoot = $currentRoot
        PersistRoot = $persistRoot
        ManifestPath = $manifestPath
        InstallPath = $installPath
        PersistMappings = @($state.PersistMappings)
        Shims = @($state.Shims)
        Capabilities = @($state.Capabilities)
    }
}

function Get-CapsulenvInstalledPackageStates {
    [CmdletBinding()]
    param([switch]$Strict)

    $stateRoot = Get-CapsulenvPackageStateRoot
    if (-not (Test-Path -LiteralPath $stateRoot -PathType Container)) {
        return @()
    }
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $stateRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        try {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            $results.Add((Get-CapsulenvInstalledPackageState -Name $name))
        } catch {
            if ($Strict) { throw }
            Write-CapsulenvMessage -Level Warning -Message $_.Exception.Message
        }
    }
    return $results.ToArray()
}

function Resolve-CapsulenvPackageDependencyReference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Dependency,
        [Parameter(Mandatory = $true)]$ParentPlan
    )

    $parsed = Split-CapsulenvPackageReference -Reference $Dependency
    if ($parsed.Bucket -or [string]$ParentPlan.Bucket -eq 'main') {
        return $Dependency
    }
    $candidate = ('{0}/{1}' -f $ParentPlan.Bucket, $parsed.Name)
    $bucketRoot = Join-Path (Get-CapsulenvScoopRoot) ('buckets\' + [string]$ParentPlan.Bucket)
    $candidatePath = Join-Path $bucketRoot ('bucket\' + [string]$parsed.Name + '.json')
    if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
        # Prefer same-bucket dependencies when the manifest exists. Do not catch
        # parse/classification failures here: malformed metadata must fail closed
        # instead of silently falling back to a different bucket.
        return $candidate
    }
    return $Dependency
}

function Add-CapsulenvPackagePlanNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Reference,
        [Parameter(Mandatory = $true)][hashtable]$Visited,
        [Parameter(Mandatory = $true)][hashtable]$Visiting,
        [Parameter(Mandatory = $true)]$Ordered
    )

    $plan = Get-CapsulenvPackageManifestPlan -Reference $Reference
    $key = ([string]$plan.Reference).ToLowerInvariant()
    if ($Visited.ContainsKey($key)) {
        return
    }
    if ($Visiting.ContainsKey($key)) {
        throw "Package dependency cycle detected at $($plan.Reference)."
    }
    $Visiting[$key] = $true
    try {
        foreach ($dependency in @($plan.Dependencies)) {
            $dependencyReference = Resolve-CapsulenvPackageDependencyReference -Dependency ([string]$dependency) -ParentPlan $plan
            Add-CapsulenvPackagePlanNode `
                -Reference $dependencyReference `
                -Visited $Visited `
                -Visiting $Visiting `
                -Ordered $Ordered
        }
    } finally {
        [void]$Visiting.Remove($key)
    }
    $Visited[$key] = $true
    $Ordered.Add($plan)
}

function Get-CapsulenvPackageInstallPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Reference)

    $ordered = New-Object System.Collections.Generic.List[object]
    Add-CapsulenvPackagePlanNode `
        -Reference $Reference `
        -Visited @{} `
        -Visiting @{} `
        -Ordered $ordered

    $packages = $ordered.ToArray()
    $blocked = @($packages | Where-Object { [string]$_.Classification -ne 'PortableSafe' })
    return [pscustomobject]@{
        SchemaVersion = 1
        Reference = [string](Split-CapsulenvPackageReference -Reference $Reference).Reference
        Classification = if ($blocked.Count -eq 0) { 'PortableSafe' } else { 'TrustedExecutionRequired' }
        Packages = $packages
        BlockedPackages = $blocked
    }
}

function Get-CapsulenvPackagePlanExecutableAliases {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Package)

    $aliases = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Package.Bin) { return @() }
    $items = @(if ($Package.Bin -is [string]) { [string]$Package.Bin } else { @($Package.Bin) })
    foreach ($item in $items) {
        $parts = @(if ($item -is [string]) { [string]$item } else { @($item) })
        if ($parts.Count -lt 1) { continue }
        $alias = if ($parts.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace([string]$parts[1])) {
            [string]$parts[1]
        } else {
            [System.IO.Path]::GetFileNameWithoutExtension((Get-CapsulenvPackagePathLeaf -Path ([string]$parts[0])))
        }
        if (-not [string]::IsNullOrWhiteSpace($alias) -and -not $aliases.Contains($alias)) { $aliases.Add($alias) }
    }
    return [string[]]$aliases.ToArray()
}

function ConvertTo-CapsulenvPackageInstallPlanContract {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan)

    $packageContracts = @(
        foreach ($package in @($Plan.Packages)) {
            [pscustomobject][ordered]@{
                Reference = [string]$package.Reference
                Version = [string]$package.Version
                Architecture = [string]$package.Architecture
                Classification = [string]$package.Classification
                Capabilities = @($package.Capabilities | ForEach-Object { [string]$_ })
                Executables = @(Get-CapsulenvPackagePlanExecutableAliases -Package $package)
                Reasons = @($package.Reasons | ForEach-Object { [string]$_ })
                Dependencies = @($package.Dependencies | ForEach-Object { [string]$_ })
            }
        }
    )
    $blockedReferences = @(
        foreach ($package in @($Plan.BlockedPackages)) {
            [string]$package.Reference
        }
    )

    return [pscustomobject][ordered]@{
        SchemaVersion = 2
        Reference = [string]$Plan.Reference
        Classification = [string]$Plan.Classification
        PortableSafe = ([string]$Plan.Classification -eq 'PortableSafe')
        Executables = @($packageContracts | ForEach-Object { @($_.Executables) } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        Packages = $packageContracts
        BlockedPackages = $blockedReferences
    }
}

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvPackageInstallPlan
