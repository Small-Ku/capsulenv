function Get-CapsulenvPortableSeedManifestPath {
    [CmdletBinding()]
    param()

    $context = Get-CapsulenvContext
    return Join-Path $context.Root 'state/portable/seed/manifest.json'
}

function New-CapsulenvPortableSeedEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedHash,
        [string]$ExecutableRelativePath,
        [string[]]$Capabilities = @(),
        [string]$Provenance
    )

    $sourceFull = [System.IO.Path]::GetFullPath($SourcePath)
    $sourceReference = ConvertTo-CapsulenvStatePathReference -Path $sourceFull
    if (-not $sourceReference.StartsWith('capsule://', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Portable seed sources must be inside the current capsule root.'
    }
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        Immutable = $true
        Name = $Name
        Version = $Version
        SourceReference = $sourceReference
        ExpectedHash = $ExpectedHash.ToLowerInvariant()
        ExecutableRelativePath = $ExecutableRelativePath
        Capabilities = @($Capabilities | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        Provenance = if ([string]::IsNullOrWhiteSpace($Provenance)) { 'portable-seed' } else { $Provenance }
    }
}

function Resolve-CapsulenvPortableSeedSourcePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    $reference = [string]$Entry.SourceReference
    if ([string]::IsNullOrWhiteSpace($reference) -or
        -not $reference.StartsWith('capsule://', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Portable seed entries must use a capsule-relative SourceReference.'
    }
    return Resolve-CapsulenvStatePathReference -Reference $reference -CapsuleRoot (Get-CapsulenvContext).Root
}

function Resolve-CapsulenvPortableSeedExecutablePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SeedRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [System.IO.Path]::IsPathRooted($RelativePath)) {
        throw 'Portable seed ExecutableRelativePath must be a non-rooted relative path.'
    }
    $normalized = $RelativePath.Replace('\', [System.IO.Path]::DirectorySeparatorChar)
    $root = [System.IO.Path]::GetFullPath($SeedRoot).TrimEnd([char[]]'\/')
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $root $normalized))
    $comparison = if (Test-CapsulenvWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, $comparison)) {
        throw 'Portable seed ExecutableRelativePath must remain inside the verified seed root.'
    }
    return $candidate
}

function Set-CapsulenvPortableSeedManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entries)

    $path = Get-CapsulenvPortableSeedManifestPath
    $parent = Split-Path -Parent $path
    [void](New-Item -ItemType Directory -Path $parent -Force)
    $value = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Entries = @($Entries)
        UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $temporary = Join-Path $parent ('.seed-manifest.{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        $encoding = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($temporary, ($value | ConvertTo-Json -Depth 8), $encoding)
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            [System.IO.File]::Replace($temporary, $path, $null, $true)
        } else {
            Move-Item -LiteralPath $temporary -Destination $path
        }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
    return $value
}

function Get-CapsulenvPortableSeedEntries {
    [CmdletBinding()]
    param()

    $path = Get-CapsulenvPortableSeedManifestPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @()
    }
    try {
        $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ([int]$manifest.SchemaVersion -ne 1) {
            return @()
        }
        return @($manifest.Entries)
    } catch {
        return @()
    }
}

function Get-CapsulenvPortableSeedEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Version
    )

    $matches = @(
        Get-CapsulenvPortableSeedEntries |
            Where-Object {
                [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$_.Name, $Name) -and
                ([string]::IsNullOrWhiteSpace($Version) -or [string]$_.Version -eq $Version)
            }
    )
    return $matches | Select-Object -First 1
}

function Get-CapsulenvSeedSourceHash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SourcePath)

    $source = [System.IO.Path]::GetFullPath($SourcePath)
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        return (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "Seed source does not exist: $SourcePath"
    }
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($file in @(Get-ChildItem -LiteralPath $source -File -Recurse | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($source.TrimEnd([char[]]'\/').Length).TrimStart([char[]]'\/').Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $entries.Add(('{0}|{1}' -f $relative, $hash))
    }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($entries -join [Environment]::NewLine))) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha256.Dispose()
    }
}

function Test-CapsulenvPortableSeedEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Entry)

    if ([bool]$Entry.Immutable -ne $true -or
        [string]$Entry.ExpectedHash -notmatch '^[A-Fa-f0-9]{64}$') {
        return $false
    }
    try {
        $source = Resolve-CapsulenvPortableSeedSourcePath -Entry $Entry
    } catch {
        return $false
    }
    if (-not (Test-Path -LiteralPath $source)) {
        return $false
    }
    if ((Test-Path -LiteralPath $source -PathType Container) -and
        (-not [string]::IsNullOrWhiteSpace([string]$Entry.ExecutableRelativePath))) {
        try {
            $executable = Resolve-CapsulenvPortableSeedExecutablePath -SeedRoot $source -RelativePath ([string]$Entry.ExecutableRelativePath)
            if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
                return $false
            }
        } catch {
            return $false
        }
    }
    try {
        $actual = Get-CapsulenvSeedSourceHash -SourcePath $source
        return [System.StringComparer]::OrdinalIgnoreCase.Equals($actual, [string]$Entry.ExpectedHash)
    } catch {
        return $false
    }
}

function Test-CapsulenvSeedAcquisitionCandidateAgainstRequirement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Requirement,
        [Parameter(Mandatory = $true)]$Candidate
    )

    try {
        $source = Resolve-CapsulenvStatePathReference -Reference ([string]$Candidate.SourceReference) -CapsuleRoot (Get-CapsulenvContext).Root
        if (Test-Path -LiteralPath $source -PathType Container) {
            if ([string]::IsNullOrWhiteSpace([string]$Candidate.ExecutableRelativePath)) {
                throw 'Seed acquisition candidates must identify an executable inside their source root.'
            }
            $executable = Resolve-CapsulenvPortableSeedExecutablePath -SeedRoot $source -RelativePath ([string]$Candidate.ExecutableRelativePath)
        } elseif (Test-Path -LiteralPath $source -PathType Leaf) {
            $executable = $source
        } else {
            throw 'Seed acquisition source does not exist.'
        }

        $expectedHash = [string]$Candidate.ExpectedHash
        if ($expectedHash -notmatch '^[A-Fa-f0-9]{64}$') {
            throw 'Seed acquisition candidates must carry a valid ExpectedHash.'
        }
        $actualHash = Get-CapsulenvSeedSourceHash -SourcePath $source
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($actualHash, $expectedHash)) {
            throw 'Seed acquisition source hash does not match its ExpectedHash.'
        }

        $programCandidate = New-CapsulenvProgramCandidate -Name ([string]$Candidate.Name) -Executable $executable -Root $source -Provider 'seed' -Scope 'portable' -Version ([string]$Candidate.Version) -Capabilities @($Candidate.Capabilities) -Trusted:$true -Provenance ([string]$Candidate.Provenance)
        return Test-CapsulenvProgramCandidate -Requirement $Requirement -Candidate $programCandidate
    } catch {
        return [pscustomobject][ordered]@{
            Compatible = $false
            Reasons = @('seed-source-invalid')
            Candidate = $Candidate
        }
    }
}

function Get-CapsulenvSeedAcquisitionCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Requirement)

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @(Get-CapsulenvPortableSeedEntries | Where-Object { [string]$_.Name -eq [string]$Requirement.Name })) {
        if (-not (Test-CapsulenvPortableSeedEntry -Entry $entry)) {
            continue
        }
        try {
            $source = Resolve-CapsulenvPortableSeedSourcePath -Entry $entry
            if ((Test-Path -LiteralPath $source -PathType Container) -and
                (-not [string]::IsNullOrWhiteSpace([string]$entry.ExecutableRelativePath))) {
                [void](Resolve-CapsulenvPortableSeedExecutablePath -SeedRoot $source -RelativePath ([string]$entry.ExecutableRelativePath))
            }
        } catch {
            continue
        }
        $candidate = [pscustomobject][ordered]@{
            Kind = 'seed-acquisition'
            Name = [string]$entry.Name
            Version = [string]$entry.Version
            Provider = 'seed'
            Scope = 'portable'
            Provenance = [string]$entry.Provenance
            SourceReference = [string]$entry.SourceReference
            ExpectedHash = [string]$entry.ExpectedHash
            ExecutableRelativePath = [string]$entry.ExecutableRelativePath
            Capabilities = @($entry.Capabilities)
        }
        if ((Test-CapsulenvSeedAcquisitionCandidateAgainstRequirement -Requirement $Requirement -Candidate $candidate).Compatible) {
            $candidates.Add($candidate)
        }
    }
    return @($candidates.ToArray())
}

function Get-CapsulenvSeedProgramCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Requirement)

    return Get-CapsulenvSeedAcquisitionCandidates -Requirement $Requirement
}


if (-not (Get-Variable -Name CapsulenvBootstrapNetworkInvoker -Scope Script -ErrorAction SilentlyContinue)) {
    $script:CapsulenvBootstrapNetworkInvoker = $null
}

function Set-CapsulenvBootstrapNetworkInvoker {
    [CmdletBinding()]
    param([AllowNull()][scriptblock]$Invoker)

    $script:CapsulenvBootstrapNetworkInvoker = $Invoker
}

function Get-CapsulenvProgramProviderExecutableRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Requirement,
        [Parameter(Mandatory = $true)]$Plan
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$Requirement.RelativePath)) {
        if (-not (Test-CapsulenvPackageRelativePath -Path ([string]$Requirement.RelativePath))) {
            throw "Program provider relative executable escapes the package root: $($Requirement.RelativePath)"
        }
        return [string]$Requirement.RelativePath
    }

    $requested = if (-not [string]::IsNullOrWhiteSpace([string]$Requirement.BinName)) {
        [string]$Requirement.BinName
    } else {
        [string]$Requirement.Name
    }
    $matches = New-Object System.Collections.Generic.List[string]
    $items = @(if ($Plan.Bin -is [string]) { [string]$Plan.Bin } else { @($Plan.Bin) })
    foreach ($item in $items) {
        $parts = @(if ($item -is [string]) { [string]$item } else { @($item) })
        if ($parts.Count -lt 1 -or [string]::IsNullOrWhiteSpace([string]$parts[0])) { continue }
        $relative = [string]$parts[0]
        if (-not (Test-CapsulenvPackageRelativePath -Path $relative)) { continue }
        $leaf = [System.IO.Path]::GetFileName($relative)
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
        $alias = if ($parts.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace([string]$parts[1])) {
            [string]$parts[1]
        } else {
            $stem
        }
        if (
            [System.StringComparer]::OrdinalIgnoreCase.Equals($requested, $alias) -or
            [System.StringComparer]::OrdinalIgnoreCase.Equals($requested, $leaf) -or
            [System.StringComparer]::OrdinalIgnoreCase.Equals($requested, $stem)
        ) {
            $matches.Add($relative)
        }
    }
    if ($matches.Count -eq 1) {
        return [string]$matches[0]
    }
    if ($matches.Count -gt 1) {
        throw "Program provider manifest has multiple executable aliases matching '$requested'."
    }
    throw "Program provider manifest does not expose an executable matching '$requested'."
}

function Copy-CapsulenvProgramProviderDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Download,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    [void](New-Item -ItemType Directory -Path $Destination -Force)
    $artifact = Join-Path $Destination ('{0:D3}-{1}' -f [int]$Download.Index, [string]$Download.FileName)
    $uri = [Uri]([string]$Download.Url)
    if ($uri.Scheme -eq 'file') {
        Copy-Item -LiteralPath $uri.LocalPath -Destination $artifact -Force
    } else {
        $parameters = @{
            Uri = [string]$Download.Url
            OutFile = $artifact
            ErrorAction = 'Stop'
        }
        if ($PSVersionTable.PSVersion.Major -le 5) {
            $parameters['UseBasicParsing'] = $true
        }
        Invoke-WebRequest @parameters
    }
    $actual = Get-CapsulenvFileSha256 -Path $artifact
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($actual, [string]$Download.Hash)) {
        throw "Program provider hash mismatch for $($Download.OriginalUrl): expected $($Download.Hash), got $actual"
    }
    return $artifact
}

function Expand-CapsulenvProgramProviderPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$StagingRoot
    )

    $payloadRoot = Join-Path $StagingRoot 'payload'
    $downloadRoot = Join-Path $StagingRoot 'downloads'
    [void](New-Item -ItemType Directory -Path $payloadRoot -Force)
    foreach ($download in @($Plan.Downloads)) {
        $artifact = Copy-CapsulenvProgramProviderDownload -Download $download -Destination $downloadRoot
        $extractTo = Get-CapsulenvPackageIndexedValue -Values @($Plan.ExtractTo) -Index ([int]$download.Index)
        $targetRoot = if ([string]::IsNullOrWhiteSpace($extractTo)) {
            $payloadRoot
        } else {
            Resolve-CapsulenvScoopAppRelativePath -Root $payloadRoot -RelativePath $extractTo
        }
        [void](New-Item -ItemType Directory -Path $targetRoot -Force)

        if ([string]$download.ArchiveKind -eq 'Zip') {
            $archiveRoot = Join-Path $StagingRoot ('archive-{0:D3}' -f [int]$download.Index)
            Expand-CapsulenvSafeZip -Archive $artifact -Destination $archiveRoot
            $extractDir = Get-CapsulenvPackageIndexedValue -Values @($Plan.ExtractDir) -Index ([int]$download.Index)
            $sourceRoot = if ([string]::IsNullOrWhiteSpace($extractDir)) {
                $archiveRoot
            } else {
                Resolve-CapsulenvScoopAppRelativePath -Root $archiveRoot -RelativePath $extractDir
            }
            if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
                throw "Program provider extract_dir was not found: $extractDir"
            }
            Copy-CapsulenvPackageTree -Source $sourceRoot -Destination $targetRoot
        } elseif ([string]$download.ArchiveKind -eq 'File') {
            $target = Join-Path $targetRoot ([string]$download.FileName)
            if (Test-Path -LiteralPath $target) {
                throw "Program provider artifacts collide at: $target"
            }
            Copy-Item -LiteralPath $artifact -Destination $target
        } else {
            throw "Program provider cannot safely materialize archive type '$($download.ArchiveKind)'."
        }
    }
    return $payloadRoot
}



function Get-CapsulenvProgramProviderCapabilities {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    switch ($Name.ToLowerInvariant()) {
        'pwsh' { return @('interactive') }
        'sing-box' { return @('proxy') }
        default { return @() }
    }
}

function Test-CapsulenvProgramProviderPayloadPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Requirement,
        [Parameter(Mandatory = $true)]$Plan
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    if (@($Plan.Downloads).Count -eq 0) {
        $reasons.Add('provider-manifest-has-no-downloads')
    }
    foreach ($download in @($Plan.Downloads)) {
        if ([string]$download.ArchiveKind -notin @('Zip', 'File')) {
            $reasons.Add(('unsupported-provider-payload:{0}' -f [string]$download.ArchiveKind))
        }
        if ([string]::IsNullOrWhiteSpace([string]$download.Hash)) {
            $reasons.Add('provider-payload-hash-missing')
        }
    }
    if ($null -eq $Plan.Bin -or @($Plan.Bin).Count -eq 0) {
        $reasons.Add('provider-manifest-has-no-program-bin')
    }
    if (@($Plan.Dependencies).Count -gt 0) {
        $reasons.Add('provider-payload-dependencies-require-explicit-acquisition')
    }
    try {
        if ($reasons.Count -eq 0) {
            [void](Get-CapsulenvProgramProviderExecutableRelativePath -Requirement $Requirement -Plan $Plan)
        }
    } catch {
        $reasons.Add($_.Exception.Message)
    }

    return [pscustomobject][ordered]@{
        Compatible = ($reasons.Count -eq 0)
        Reasons = @($reasons.ToArray())
        # Scoop lifecycle classification is deliberately diagnostic only here.
        # Program acquisition consumes immutable payload metadata and never runs
        # pre/post-install, persist, shortcut, registry, or uninstaller scripts.
        SourceClassification = [string]$Plan.Classification
    }
}

function Get-CapsulenvProgramProviderCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Requirement)

    if (@($Requirement.AllowedProviders | ForEach-Object { ([string]$_).ToLowerInvariant() }) -notcontains 'provider') {
        return @()
    }

    [void](Initialize-CapsulenvScoopBootstrap)
    $plan = Get-CapsulenvPackageManifestPlan -Reference ([string]$Requirement.Name)
    $payloadCompatibility = Test-CapsulenvProgramProviderPayloadPlan -Requirement $Requirement -Plan $plan
    if (-not $payloadCompatibility.Compatible) {
        throw "Program provider '$($plan.Reference)' has no safe payload-only acquisition path: $($payloadCompatibility.Reasons -join ', ')"
    }
    $relativeExecutable = Get-CapsulenvProgramProviderExecutableRelativePath -Requirement $Requirement -Plan $plan

    $placement = Initialize-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity)
    $providerRoot = Join-Path $placement.ScratchRoot 'provider-acquisition'
    [void](New-Item -ItemType Directory -Path $providerRoot -Force)
    $stagingRoot = Join-Path $providerRoot ([Guid]::NewGuid().ToString('N'))
    try {
        $payloadRoot = Expand-CapsulenvProgramProviderPlan -Plan $plan -StagingRoot $stagingRoot
        $executable = Resolve-CapsulenvScoopAppRelativePath -Root $payloadRoot -RelativePath $relativeExecutable
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            throw "Program provider executable was not materialized: $relativeExecutable"
        }
        $candidateParameters = @{
            Name = [string]$Requirement.Name
            Executable = $executable
            Root = $payloadRoot
            Provider = 'provider'
            AcquisitionProvider = 'provider'
            Scope = 'acquisition'
            Version = [string]$plan.Version
            Capabilities = @(Get-CapsulenvProgramProviderCapabilities -Name ([string]$Requirement.Name))
            Trusted = $true
            OwnsLifecycle = $false
            Provenance = ('provider/scoop-manifest/{0}@{1}' -f [string]$plan.Reference, [string]$plan.Version)
        }
        $candidate = New-CapsulenvProgramCandidate @candidateParameters
        $candidate | Add-Member -NotePropertyName AcquisitionCleanupRoot -NotePropertyValue $stagingRoot -Force
        $candidate | Add-Member -NotePropertyName ProviderReference -NotePropertyValue ([string]$plan.Reference) -Force
        $check = Test-CapsulenvProgramCandidate -Requirement $Requirement -Candidate $candidate
        if (-not $check.Compatible) {
            throw "Program provider candidate is incompatible: $($check.Reasons -join ', ')"
        }
        return @($candidate)
    } catch {
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Get-CapsulenvProgramProviderCandidatesWithBootstrap {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Requirement)

    try {
        return @(Get-CapsulenvProgramProviderCandidates -Requirement $Requirement)
    } catch {
        $firstFailure = $_
        if ($null -eq $script:CapsulenvBootstrapNetworkInvoker) {
            throw
        }
        $operation = { @(Get-CapsulenvProgramProviderCandidates -Requirement $Requirement) }.GetNewClosure()
        try {
            return @(& $script:CapsulenvBootstrapNetworkInvoker $Requirement $operation)
        } catch {
            throw "Program provider acquisition failed before and after bootstrap networking. Initial failure: $($firstFailure.Exception.Message). Bootstrap/retry failure: $($_.Exception.Message)"
        }
    }
}

function Resolve-CapsulenvProgramWithAcquisition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Requirement,
        [object[]]$HostCandidates,
        [object[]]$SeedCandidates,
        [object[]]$ProviderCandidates = @()
    )

    $hostCandidates = if ($PSBoundParameters.ContainsKey('HostCandidates')) {
        @($HostCandidates)
    } else {
        @(Get-CapsulenvProgramCandidates -Requirement $Requirement)
    }
    $current = Resolve-CapsulenvProgram -Requirement $Requirement -Candidates $hostCandidates
    if ($current.Succeeded) {
        return [pscustomobject][ordered]@{
            Succeeded = $true
            Stage = 'existing-host-program'
            Selected = $current.Selected
            Diagnostics = @('trusted current host authority selected before acquisition')
        }
    }

    $seedCandidates = if ($PSBoundParameters.ContainsKey('SeedCandidates')) {
        @($SeedCandidates)
    } else {
        @(Get-CapsulenvSeedAcquisitionCandidates -Requirement $Requirement)
    }
    $seed = @(
        $seedCandidates |
            Where-Object {
                [string]$_.Kind -eq 'seed-acquisition' -and
                [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$_.Name, [string]$Requirement.Name)
            } |
            Where-Object { (Test-CapsulenvSeedAcquisitionCandidateAgainstRequirement -Requirement $Requirement -Candidate $_).Compatible } |
            Select-Object -First 1
    )
    if ($seed.Count -eq 1) {
        $entry = $seed[0]
        $source = Resolve-CapsulenvPortableSeedSourcePath -Entry $entry
        $manifest = Acquire-CapsulenvProgramRealization `
            -Name ([string]$entry.Name) `
            -Version ([string]$entry.Version) `
            -SourcePath $source `
            -ExecutableRelativePath ([string]$entry.ExecutableRelativePath) `
            -ExpectedHash ([string]$entry.ExpectedHash) `
            -Provider capsulenv-local `
            -AcquisitionProvider seed `
            -Provenance ([string]$entry.Provenance)
        $authority = Get-CapsulenvRealizationAuthority -Manifest $manifest
        $payload = Join-Path ([string]$manifest.RealizationRoot) 'payload'
        $executable = Resolve-CapsulenvRealizationPayloadPath -PayloadRoot $payload -ExecutableRelativePath ([string]$manifest.ExecutableRelativePath)
        $selected = New-CapsulenvProgramCandidate `
            -Name ([string]$manifest.Name) `
            -Executable $executable `
            -Root ([string]$manifest.RealizationRoot) `
            -Provider $authority.Provider `
            -AcquisitionProvider $authority.AcquisitionProvider `
            -Scope $authority.Scope `
            -Version ([string]$manifest.Version) `
            -Capabilities @($entry.Capabilities) `
            -Trusted:$true `
            -OwnsLifecycle:$authority.OwnsLifecycle `
            -Provenance $authority.Provenance
        $check = Test-CapsulenvProgramCandidate -Requirement $Requirement -Candidate $selected
        if (-not $check.Compatible) {
            throw "Materialized seed program '$($entry.Name)' failed current authority validation: $($check.Reasons -join ', ')"
        }
        return [pscustomobject][ordered]@{
            Succeeded = $true
            Stage = 'materialized-portable-seed'
            Selected = $selected
            Diagnostics = @('verified seed was materialized into a host-local owned realization')
        }
    }

    $providerCandidates = if ($PSBoundParameters.ContainsKey('ProviderCandidates')) {
        @($ProviderCandidates)
    } else {
        @(Get-CapsulenvProgramProviderCandidatesWithBootstrap -Requirement $Requirement)
    }
    $provider = Resolve-CapsulenvProgram -Requirement $Requirement -Candidates $providerCandidates
    if ($provider.Succeeded) {
        $sourceCandidate = $provider.Selected
        $cleanupRoot = if ($null -ne $sourceCandidate.PSObject.Properties['AcquisitionCleanupRoot']) {
            [string]$sourceCandidate.AcquisitionCleanupRoot
        } else {
            $null
        }
        try {
            $sourcePath = [string]$sourceCandidate.Executable
            $relativePath = $null
            if (-not [string]::IsNullOrWhiteSpace([string]$sourceCandidate.Root) -and
                (Test-Path -LiteralPath ([string]$sourceCandidate.Root) -PathType Container) -and
                (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                $root = [System.IO.Path]::GetFullPath([string]$sourceCandidate.Root).TrimEnd([char[]]'\/')
                $fullExecutable = [System.IO.Path]::GetFullPath($sourcePath)
                $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
                $comparison = if (Test-CapsulenvWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
                if ($fullExecutable.StartsWith($prefix, $comparison)) {
                    $relativePath = $fullExecutable.Substring($prefix.Length).Replace('\', '/')
                    $sourcePath = $root
                }
            }
            if ([string]::IsNullOrWhiteSpace($relativePath) -and (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                $relativePath = [System.IO.Path]::GetFileName($sourcePath)
            }
            if ([string]::IsNullOrWhiteSpace($relativePath)) {
                throw "Provider candidate '$($sourceCandidate.Name)' has no safe materialization source."
            }
            $manifestParameters = @{
                Name = [string]$sourceCandidate.Name
                Version = [string]$sourceCandidate.Version
                SourcePath = $sourcePath
                ExecutableRelativePath = $relativePath
                Provider = 'capsulenv-local'
                AcquisitionProvider = 'provider'
                Provenance = [string]$sourceCandidate.Provenance
            }
            $manifest = Acquire-CapsulenvProgramRealization @manifestParameters
            $authority = Get-CapsulenvRealizationAuthority -Manifest $manifest
            $payload = Join-Path ([string]$manifest.RealizationRoot) 'payload'
            $executable = Resolve-CapsulenvRealizationPayloadPath -PayloadRoot $payload -ExecutableRelativePath ([string]$manifest.ExecutableRelativePath)
            $selectedParameters = @{
                Name = [string]$manifest.Name
                Executable = $executable
                Root = [string]$manifest.RealizationRoot
                Provider = $authority.Provider
                AcquisitionProvider = $authority.AcquisitionProvider
                Scope = $authority.Scope
                Version = [string]$manifest.Version
                Capabilities = @($sourceCandidate.Capabilities)
                Trusted = $true
                OwnsLifecycle = $authority.OwnsLifecycle
                Provenance = $authority.Provenance
            }
            $selected = New-CapsulenvProgramCandidate @selectedParameters
            return [pscustomobject][ordered]@{
                Succeeded = $true
                Stage = 'materialized-normal-provider'
                Selected = $selected
                Diagnostics = @('provider candidate was materialized into a host-local owned realization')
            }
        } finally {
            if (-not [string]::IsNullOrWhiteSpace($cleanupRoot) -and (Test-Path -LiteralPath $cleanupRoot)) {
                Remove-Item -LiteralPath $cleanupRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    return [pscustomobject][ordered]@{
        Succeeded = $false
        Stage = 'normal-provider'
        Selected = $null
        Diagnostics = @('no compatible host, seed, or provider candidate is available')
    }
}

function Ensure-CapsulenvProgramGeneration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Requirement,
        [object[]]$HostCandidates,
        [object[]]$SeedCandidates,
        [object[]]$ProviderCandidates = @()
    )

    $active = Get-CapsulenvActiveGeneration
    if ($null -ne $active) {
        try {
            $selected = Get-CapsulenvActiveGenerationProgram -Requirement $Requirement -ActivationSnapshot (New-CapsulenvActivationSnapshot -ActiveGeneration $active)
            return [pscustomobject][ordered]@{
                Succeeded = $true
                Stage = 'existing-active-generation'
                Selected = $selected
                Generation = $active.Generation
            }
        } catch {}
    }

    $parameters = @{ Requirement = $Requirement }
    if ($PSBoundParameters.ContainsKey('HostCandidates')) { $parameters.HostCandidates = $HostCandidates }
    if ($PSBoundParameters.ContainsKey('SeedCandidates')) { $parameters.SeedCandidates = $SeedCandidates }
    if ($PSBoundParameters.ContainsKey('ProviderCandidates')) { $parameters.ProviderCandidates = $ProviderCandidates }
    $resolved = Resolve-CapsulenvProgramWithAcquisition @parameters
    if (-not $resolved.Succeeded -or $null -eq $resolved.Selected) {
        throw "Program '$($Requirement.Name)' could not be acquired for a new active generation."
    }

    $realizations = New-Object System.Collections.Generic.List[object]
    if ($null -ne $active) {
        foreach ($selection in @($active.Generation.Selections)) {
            if ([string]$selection.Kind -eq 'host-program') {
                $realizations.Add([pscustomobject]@{ Kind = 'host-program'; Program = $selection })
            } elseif ([string]$selection.Kind -eq 'realization' -or [string]::IsNullOrWhiteSpace([string]$selection.Kind)) {
                $realizations.Add([pscustomobject]@{ Kind = 'realization'; RealizationRoot = [string]$selection.RealizationRoot })
            }
        }
    }
    if ([string]$resolved.Selected.Provider -eq 'capsulenv-local' -and
        -not [string]::IsNullOrWhiteSpace([string]$resolved.Selected.Root)) {
        $realizations.Add([pscustomobject]@{ Kind = 'realization'; RealizationRoot = [string]$resolved.Selected.Root })
    } elseif ([string]$resolved.Selected.Provider -eq 'host-scoop') {
        $realizations.Add([pscustomobject]@{ Kind = 'host-program'; Program = $resolved.Selected })
    } else {
        throw "Acquisition for '$($Requirement.Name)' did not produce a publishable host authority."
    }
    $generation = Publish-CapsulenvGeneration -Realizations $realizations.ToArray()
    [void](Set-CapsulenvActiveGenerationAuthority -GenerationId ([string]$generation.GenerationId))
    return [pscustomobject][ordered]@{
        Succeeded = $true
        Stage = $resolved.Stage
        Selected = $resolved.Selected
        Generation = $generation
    }
}

function Invoke-CapsulenvBootstrapAcquisition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Requirement,
        [object[]]$HostCandidates = @(),
        [object[]]$SeedCandidates = @(),
        [object[]]$ProviderCandidates = @(),
        [switch]$RequireBootstrapNetwork,
        [switch]$BootstrapNetworkReady
    )

    $acquisitionParameters = @{ Requirement = $Requirement }
    if ($PSBoundParameters.ContainsKey('HostCandidates')) { $acquisitionParameters['HostCandidates'] = $HostCandidates }
    if ($PSBoundParameters.ContainsKey('SeedCandidates')) { $acquisitionParameters['SeedCandidates'] = $SeedCandidates }
    if ($PSBoundParameters.ContainsKey('ProviderCandidates')) {
        $acquisitionParameters['ProviderCandidates'] = $ProviderCandidates
    } elseif ($RequireBootstrapNetwork -and -not $BootstrapNetworkReady) {
        # Fail closed on host/local + seed only. Do not enter a network-backed
        # provider while this helper is being used to break that dependency.
        $acquisitionParameters['ProviderCandidates'] = @()
    }
    $resolved = Resolve-CapsulenvProgramWithAcquisition @acquisitionParameters
    if ($resolved.Succeeded) { return $resolved }
    if ($RequireBootstrapNetwork -and -not $BootstrapNetworkReady) {
        throw 'Bootstrap network is required before normal provider acquisition, but no host or seed bootstrap program is available.'
    }
    return $resolved
}

##MOD_EXEC## Export-ModuleMember -Function New-CapsulenvPortableSeedEntry, Set-CapsulenvPortableSeedManifest, Get-CapsulenvPortableSeedEntries, Get-CapsulenvPortableSeedEntry, Test-CapsulenvPortableSeedEntry, Test-CapsulenvSeedAcquisitionCandidateAgainstRequirement, Get-CapsulenvSeedAcquisitionCandidates, Get-CapsulenvSeedProgramCandidates, Resolve-CapsulenvProgramWithAcquisition, Ensure-CapsulenvProgramGeneration, Invoke-CapsulenvBootstrapAcquisition


