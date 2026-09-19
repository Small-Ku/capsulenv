function Test-CapsulenvSafeRealizationComponent {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value)

    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

function Get-CapsulenvRealizationSourceHash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SourcePath)

    $fullSource = [System.IO.Path]::GetFullPath($SourcePath)
    if (Test-Path -LiteralPath $fullSource -PathType Leaf) {
        return (Get-FileHash -LiteralPath $fullSource -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if (-not (Test-Path -LiteralPath $fullSource -PathType Container)) {
        throw "Realization source does not exist: $SourcePath"
    }

    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($file in @(Get-ChildItem -LiteralPath $fullSource -File -Recurse | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($fullSource.TrimEnd([char[]]'\/').Length).TrimStart([char[]]'\/').Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $entries.Add(('{0}|{1}' -f $relative, $hash))
    }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($entries -join [Environment]::NewLine))
        return (($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha256.Dispose()
    }
}

function Get-CapsulenvRealizationManifestPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RealizationRoot)

    return Join-Path $RealizationRoot 'realization.json'
}

function Resolve-CapsulenvRealizationPayloadPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PayloadRoot,
        [Parameter(Mandatory = $true)][string]$ExecutableRelativePath
    )

    if ([string]::IsNullOrWhiteSpace($ExecutableRelativePath)) {
        throw 'ExecutableRelativePath must be a non-rooted relative path.'
    }
    $normalized = $ExecutableRelativePath.Replace('\', [System.IO.Path]::DirectorySeparatorChar)
    if ([System.IO.Path]::IsPathRooted($normalized) -or $normalized -match '^[A-Za-z]:[\\/]') {
        throw 'ExecutableRelativePath must be a non-rooted relative path.'
    }
    $root = [System.IO.Path]::GetFullPath($PayloadRoot).TrimEnd([char[]]'\\/')
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $root $normalized))
    $comparison = if (Test-CapsulenvWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    $sameRoot = [System.StringComparer]::Ordinal.Equals($candidate, $root)
    if (-not $sameRoot -and -not $candidate.StartsWith($prefix, $comparison)) {
        throw 'ExecutableRelativePath must remain inside the realization payload.'
    }
    return $candidate
}

function Get-CapsulenvRealizationPayloadHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RealizationRoot,
        [Parameter(Mandatory = $true)]$Manifest
    )

    $payloadRoot = Join-Path $RealizationRoot 'payload'
    if ([string]$Manifest.SourceKind -eq 'file') {
        $publishedFile = Resolve-CapsulenvRealizationPayloadPath -PayloadRoot $payloadRoot -ExecutableRelativePath ([string]$Manifest.ExecutableRelativePath)
        if (-not (Test-Path -LiteralPath $publishedFile -PathType Leaf)) {
            throw "Published realization payload is missing: $publishedFile"
        }
        return (Get-FileHash -LiteralPath $publishedFile -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return Get-CapsulenvRealizationSourceHash -SourcePath $payloadRoot
}

function Test-CapsulenvHostProgramSelection {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Selection)

    if ([string]$Selection.Kind -ne 'host-program') {
        return $false
    }
    if ([bool]$Selection.Trusted -ne $true -or [string]$Selection.Provider -ne 'host-scoop') {
        return $false
    }
    if ([bool]$Selection.OwnsLifecycle -eq $true) {
        return $false
    }
    return -not [string]::IsNullOrWhiteSpace([string]$Selection.Executable) -and
        (Test-Path -LiteralPath ([string]$Selection.Executable) -PathType Leaf)
}

function Read-CapsulenvRealizationManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RealizationRoot)

    $manifestPath = Get-CapsulenvRealizationManifestPath -RealizationRoot $RealizationRoot
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Test-CapsulenvProgramRealization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RealizationRoot,
        [string]$ExpectedName,
        [string]$ExpectedHash,
        [string]$ExpectedVersion,
        [string]$ExpectedProvider,
        [string]$ExpectedAcquisitionProvider,
        [string]$ExpectedProvenance,
        [string]$ExpectedExecutableRelativePath
    )

    $manifest = Read-CapsulenvRealizationManifest -RealizationRoot $RealizationRoot
    if ($null -eq $manifest -or [bool]$manifest.Complete -ne $true -or [bool]$manifest.Immutable -ne $true) {
        return $false
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedName) -and
        [string]$manifest.Name -ne $ExpectedName) {
        return $false
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedHash) -and
        -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$manifest.SourceHash, $ExpectedHash)) {
        return $false
    }
    $authority = Get-CapsulenvRealizationAuthority -Manifest $manifest
    foreach ($pair in @(
        [pscustomobject]@{ Expected = $ExpectedVersion; Actual = [string]$manifest.Version },
        [pscustomobject]@{ Expected = $ExpectedProvider; Actual = [string]$authority.Provider },
        [pscustomobject]@{ Expected = $ExpectedAcquisitionProvider; Actual = [string]$authority.AcquisitionProvider },
        [pscustomobject]@{ Expected = $ExpectedProvenance; Actual = [string]$manifest.Provenance },
        [pscustomobject]@{ Expected = $ExpectedExecutableRelativePath; Actual = [string]$manifest.ExecutableRelativePath }
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$pair.Expected) -and
            -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$pair.Expected, [string]$pair.Actual)) {
            return $false
        }
    }
    $payloadRoot = Join-Path $RealizationRoot 'payload'
    if (-not (Test-Path -LiteralPath $payloadRoot -PathType Container)) {
        return $false
    }
    try {
        $executable = Resolve-CapsulenvRealizationPayloadPath -PayloadRoot $payloadRoot -ExecutableRelativePath ([string]$manifest.ExecutableRelativePath)
    } catch {
        return $false
    }
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        return $false
    }
    try {
        $payloadHash = Get-CapsulenvRealizationPayloadHash -RealizationRoot $RealizationRoot -Manifest $manifest
        return [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$manifest.PayloadHash, $payloadHash) -and
            [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$manifest.SourceHash, $payloadHash)
    } catch {
        return $false
    }
}

function Acquire-CapsulenvProgramRealization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [string]$ExecutableRelativePath,
        [string]$ExpectedHash,
        [ValidateSet('seed', 'provider', 'host-scoop', 'capsulenv-local')]
        [string]$Provider = 'provider',
        [string]$AcquisitionProvider,
        [string]$Provenance
    )

    if ([string]::IsNullOrWhiteSpace($AcquisitionProvider)) {
        $AcquisitionProvider = $Provider
    }

    if (-not (Test-CapsulenvSafeRealizationComponent -Value $Name) -or
        -not (Test-CapsulenvSafeRealizationComponent -Value $Version)) {
        throw 'Realization name and version must be safe path components.'
    }
    $sourceFull = [System.IO.Path]::GetFullPath($SourcePath)
    $sourceIsFile = Test-Path -LiteralPath $sourceFull -PathType Leaf
    $sourceIsDirectory = Test-Path -LiteralPath $sourceFull -PathType Container
    if (-not $sourceIsFile -and -not $sourceIsDirectory) {
        throw "Realization source does not exist: $SourcePath"
    }
    if ($sourceIsDirectory -and [string]::IsNullOrWhiteSpace($ExecutableRelativePath)) {
        throw 'ExecutableRelativePath is required when realizing a source directory.'
    }
    if ($sourceIsFile -and [string]::IsNullOrWhiteSpace($ExecutableRelativePath)) {
        $ExecutableRelativePath = [System.IO.Path]::GetFileName($sourceFull)
    }
    $ExecutableRelativePath = $ExecutableRelativePath.Replace('\', '/').Trim('/')
    if ([string]::IsNullOrWhiteSpace($ExecutableRelativePath) -or
        [System.IO.Path]::IsPathRooted($ExecutableRelativePath) -or
        $ExecutableRelativePath -match '^[A-Za-z]:[\\/]') {
        throw 'ExecutableRelativePath must be a non-rooted relative path.'
    }

    $sourceHash = Get-CapsulenvRealizationSourceHash -SourcePath $sourceFull
    if (-not [string]::IsNullOrWhiteSpace($ExpectedHash) -and
        -not [System.StringComparer]::OrdinalIgnoreCase.Equals($sourceHash, $ExpectedHash)) {
        throw "Realization source hash mismatch for '$Name': expected $ExpectedHash, got $sourceHash."
    }

    $placement = Initialize-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity)
    $stagingRoot = Join-Path (Join-Path $placement.ScratchRoot 'realization-staging') ([Guid]::NewGuid().ToString('N'))
    $payloadRoot = Join-Path $stagingRoot 'payload'
    try {
        [void](New-Item -ItemType Directory -Path $payloadRoot -Force)
        $publishedExecutable = Resolve-CapsulenvRealizationPayloadPath -PayloadRoot $payloadRoot -ExecutableRelativePath $ExecutableRelativePath
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $publishedExecutable) -Force)
        if ($sourceIsDirectory) {
            Copy-Item -Path (Join-Path $sourceFull '*') -Destination $payloadRoot -Recurse -Force
        } else {
            Copy-Item -LiteralPath $sourceFull -Destination $publishedExecutable -Force
        }
        if (-not (Test-Path -LiteralPath $publishedExecutable -PathType Leaf)) {
            throw "Realization executable is missing from staging: $ExecutableRelativePath"
        }
        $stagedSourceHash = if ($sourceIsFile) {
            (Get-FileHash -LiteralPath $publishedExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
        } else {
            Get-CapsulenvRealizationSourceHash -SourcePath $payloadRoot
        }
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($sourceHash, $stagedSourceHash)) {
            throw "Realization source changed while staging '$Name'; the staged content hash does not match the acquired source."
        }
        $finalRoot = Join-Path (Join-Path (Join-Path $placement.PackagesRoot $Name) $Version) $stagedSourceHash
        if (Test-Path -LiteralPath $finalRoot) {
            if (Test-CapsulenvProgramRealization -RealizationRoot $finalRoot -ExpectedName $Name -ExpectedHash $stagedSourceHash -ExpectedVersion $Version -ExpectedProvider $Provider -ExpectedAcquisitionProvider $AcquisitionProvider -ExpectedProvenance $Provenance -ExpectedExecutableRelativePath $ExecutableRelativePath) {
                return (Read-CapsulenvRealizationManifest -RealizationRoot $finalRoot) | Add-Member -NotePropertyName RealizationRoot -NotePropertyValue $finalRoot -PassThru
            }
            throw "An immutable realization with the same bytes has incompatible semantic identity: $finalRoot"
        }
        $manifest = [pscustomobject][ordered]@{
            SchemaVersion = 2
            Complete = $true
            Immutable = $true
            Name = $Name
            Version = $Version
            Provider = $Provider
            AcquisitionProvider = $AcquisitionProvider
            Provenance = $Provenance
            SourceKind = if ($sourceIsFile) { 'file' } else { 'directory' }
            SourceHash = $stagedSourceHash
            PayloadHash = $stagedSourceHash
            ExecutableRelativePath = $ExecutableRelativePath
            PublishedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        Write-CapsulenvHostJsonAtomically -Path (Get-CapsulenvRealizationManifestPath -RealizationRoot $stagingRoot) -Value $manifest
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $finalRoot) -Force)
        if (Test-Path -LiteralPath $finalRoot) {
            throw "Realization publication raced with another writer: $finalRoot"
        }
        Move-Item -LiteralPath $stagingRoot -Destination $finalRoot
        return $manifest | Add-Member -NotePropertyName RealizationRoot -NotePropertyValue $finalRoot -PassThru
    } finally {
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-CapsulenvGenerationManifestPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$GenerationId)

    if (-not (Test-CapsulenvSafeRealizationComponent -Value $GenerationId)) {
        throw 'Generation ID must be a safe path component.'
    }
    $placement = Get-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity)
    return Join-Path $placement.GenerationsRoot ($GenerationId + '.json')
}

function Get-CapsulenvActiveGenerationPath {
    [CmdletBinding()]
    param()

    $placement = Get-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity)
    return Join-Path $placement.StateRoot 'active-generation.json'
}

function Get-CapsulenvGeneration {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$GenerationId)

    $path = Get-CapsulenvGenerationManifestPath -GenerationId $GenerationId
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        $generation = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
    if ([bool]$generation.Complete -ne $true -or [string]$generation.GenerationId -ne $GenerationId) {
        return $null
    }
    foreach ($selection in @($generation.Selections)) {
        if ([string]$selection.Kind -eq 'host-program') {
            if (-not (Test-CapsulenvHostProgramSelection -Selection $selection)) {
                return $null
            }
        } elseif ([string]$selection.Kind -eq 'realization' -or [string]::IsNullOrWhiteSpace([string]$selection.Kind)) {
            if (-not (Test-CapsulenvProgramRealization -RealizationRoot ([string]$selection.RealizationRoot) -ExpectedName ([string]$selection.Name) -ExpectedHash ([string]$selection.SourceHash) -ExpectedVersion ([string]$selection.Version) -ExpectedProvider ([string]$selection.Provider) -ExpectedAcquisitionProvider ([string]$selection.AcquisitionProvider) -ExpectedProvenance ([string]$selection.Provenance) -ExpectedExecutableRelativePath ([string]$selection.ExecutableRelativePath))) {
                return $null
            }
        } else {
            return $null
        }
    }
    return $generation
}

function Publish-CapsulenvGeneration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Realizations,
        [string[]]$PinnedGenerationIds = @()
    )

    $selections = New-Object System.Collections.Generic.List[object]
    $selectionNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($realization in @($Realizations)) {
        $kind = if ($null -ne $realization.PSObject.Properties['Kind']) {
            [string]$realization.Kind
        } else {
            ''
        }
        if ([string]::IsNullOrWhiteSpace($kind) -and
            -not [string]::IsNullOrWhiteSpace([string]$realization.RealizationRoot)) {
            $kind = 'realization'
        }
        if ($kind -eq 'seed-acquisition') {
            $seedRequirement = New-CapsulenvProgramRequirement -Name ([string]$realization.Name) -ExactVersion ([string]$realization.Version) -AllowedProviders @('seed')
            if (-not (Test-CapsulenvSeedAcquisitionCandidateAgainstRequirement -Requirement $seedRequirement -Candidate $realization).Compatible) {
                throw "Cannot materialize an invalid portable seed acquisition: $($realization.Name)"
            }
            $source = Resolve-CapsulenvPortableSeedSourcePath -Entry $realization
            $realization = Acquire-CapsulenvProgramRealization -Name ([string]$realization.Name) -Version ([string]$realization.Version) -SourcePath $source -ExecutableRelativePath ([string]$realization.ExecutableRelativePath) -ExpectedHash ([string]$realization.ExpectedHash) -Provider capsulenv-local -AcquisitionProvider seed -Provenance ([string]$realization.Provenance)
            $kind = 'realization'
        }
        if ($kind -eq 'realization') {
            $root = [string]$realization.RealizationRoot
            if (-not (Test-CapsulenvProgramRealization -RealizationRoot $root)) {
                throw "Cannot publish a generation with an incomplete realization: $root"
            }
            $manifest = Read-CapsulenvRealizationManifest -RealizationRoot $root
            $authority = Get-CapsulenvRealizationAuthority -Manifest $manifest
            $selectionName = [string]$manifest.Name
            if (
                [string]::IsNullOrWhiteSpace($selectionName) -or
                -not $selectionNames.Add($selectionName)
            ) {
                throw "Cannot publish a generation with duplicate or empty Program selection name: $selectionName"
            }
            $selections.Add([pscustomobject][ordered]@{
                Kind = 'realization'
                Name = [string]$manifest.Name
                Version = [string]$manifest.Version
                Provider = [string]$authority.Provider
                AcquisitionProvider = [string]$authority.AcquisitionProvider
                Provenance = [string]$manifest.Provenance
                SourceHash = [string]$manifest.SourceHash
                ExecutableRelativePath = [string]$manifest.ExecutableRelativePath
                RealizationRoot = $root
            })
        } elseif ($kind -eq 'host-program') {
            $program = if ($null -ne $realization.PSObject.Properties['Program']) {
                $realization.Program
            } else {
                $realization
            }
            $selectionName = [string]$program.Name
            if (
                [string]::IsNullOrWhiteSpace($selectionName) -or
                -not $selectionNames.Add($selectionName)
            ) {
                throw "Cannot publish a generation with duplicate or empty Program selection name: $selectionName"
            }
            $selection = [pscustomobject][ordered]@{
                Kind = 'host-program'
                Name = $selectionName
                Version = [string]$program.Version
                Provider = [string]$program.Provider
                Scope = [string]$program.Scope
                Provenance = [string]$program.Provenance
                Executable = [string]$program.Executable
                Root = [string]$program.Root
                Trusted = [bool]$program.Trusted
                OwnsLifecycle = [bool]$program.OwnsLifecycle
                AcquisitionProvider = [string]$program.AcquisitionProvider
            }
            if (-not (Test-CapsulenvHostProgramSelection -Selection $selection)) {
                throw "Cannot publish an invalid host-program generation selection: $($selection.Name)"
            }
            $selections.Add($selection)
        } else {
            throw 'Generation selections must declare kind realization or host-program.'
        }
    }
    $generationId = [Guid]::NewGuid().ToString('N')
    $generation = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Complete = $true
        GenerationId = $generationId
        CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
        PinnedGenerationIds = @($PinnedGenerationIds)
        Selections = @($selections.ToArray())
    }
    $placement = Initialize-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity)
    [void](New-Item -ItemType Directory -Path $placement.GenerationsRoot -Force)
    Write-CapsulenvHostJsonAtomically -Path (Get-CapsulenvGenerationManifestPath -GenerationId $generationId) -Value $generation
    return $generation
}

function Set-CapsulenvActiveGenerationAuthority {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$GenerationId)

    $generation = Get-CapsulenvGeneration -GenerationId $GenerationId
    if ($null -eq $generation) {
        throw "Cannot activate an incomplete or invalid generation: $GenerationId"
    }
    $authorityPath = Get-CapsulenvActiveGenerationPath
    $authority = [pscustomobject][ordered]@{
        SchemaVersion = 1
        GenerationId = $GenerationId
        ActivatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $parent = Split-Path -Parent $authorityPath
    [void](New-Item -ItemType Directory -Path $parent -Force)
    $temporary = Join-Path $parent ('.active-generation.{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        $encoding = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($temporary, ($authority | ConvertTo-Json -Depth 5), $encoding)
        if (Test-Path -LiteralPath $authorityPath -PathType Leaf) {
            [System.IO.File]::Replace($temporary, $authorityPath, $null, $true)
        } else {
            Move-Item -LiteralPath $temporary -Destination $authorityPath
        }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
    return $generation
}

function Get-CapsulenvActiveGeneration {
    [CmdletBinding()]
    param()

    $path = Get-CapsulenvActiveGenerationPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        $authority = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace([string]$authority.GenerationId)) {
        return $null
    }
    $generation = Get-CapsulenvGeneration -GenerationId ([string]$authority.GenerationId)
    if ($null -eq $generation) {
        return $null
    }
    return [pscustomobject][ordered]@{
        Authority = $authority
        Generation = $generation
    }
}

function Get-CapsulenvReachableRealizationRoots {
    [CmdletBinding()]
    param([string[]]$PinnedGenerationIds = @())

    $active = Get-CapsulenvActiveGeneration
    $generationIds = New-Object System.Collections.Generic.List[string]
    if ($null -ne $active) {
        $generationIds.Add([string]$active.Generation.GenerationId)
    }
    foreach ($generationId in @($PinnedGenerationIds)) {
        if (-not [string]::IsNullOrWhiteSpace($generationId)) {
            $generationIds.Add([string]$generationId)
        }
    }
    $visited = New-Object System.Collections.Generic.HashSet[string]
    $roots = New-Object System.Collections.Generic.List[string]
    $pending = New-Object System.Collections.Generic.Queue[string]
    foreach ($generationId in $generationIds.ToArray()) {
        $pending.Enqueue($generationId)
    }
    while ($pending.Count -gt 0) {
        $generationId = $pending.Dequeue()
        if (-not $visited.Add($generationId)) { continue }
        $generation = Get-CapsulenvGeneration -GenerationId $generationId
        if ($null -eq $generation) { continue }
        foreach ($pinnedId in @($generation.PinnedGenerationIds)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$pinnedId)) {
                $pending.Enqueue([string]$pinnedId)
            }
        }
        foreach ($selection in @($generation.Selections)) {
            if ([string]$selection.Kind -ne 'host-program') {
                $roots.Add([System.IO.Path]::GetFullPath([string]$selection.RealizationRoot))
            }
        }
    }
    return @($roots.ToArray() | Sort-Object -Unique)
}

function Invoke-CapsulenvRealizationGarbageCollection {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string[]]$PinnedGenerationIds = @())

    $placement = Get-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity)
    $reachable = @(Get-CapsulenvReachableRealizationRoots -PinnedGenerationIds $PinnedGenerationIds)
    $removed = New-Object System.Collections.Generic.List[string]
    $kept = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $placement.PackagesRoot -PathType Container)) {
        return [pscustomobject][ordered]@{ Removed = @(); Kept = @(); Reachable = $reachable }
    }
    foreach ($manifestPath in @(Get-ChildItem -LiteralPath $placement.PackagesRoot -Filter 'realization.json' -File -Recurse)) {
        $root = [System.IO.Path]::GetFullPath($manifestPath.DirectoryName)
        if ($reachable -contains $root) {
            $kept.Add($root)
        } elseif ($PSCmdlet.ShouldProcess($root, 'Remove unreachable realization')) {
            Remove-Item -LiteralPath $root -Recurse -Force
            $removed.Add($root)
        }
    }
    return [pscustomobject][ordered]@{
        Removed = @($removed.ToArray())
        Kept = @($kept.ToArray())
        Reachable = $reachable
    }
}

##MOD_EXEC## Export-ModuleMember -Function Acquire-CapsulenvProgramRealization, Test-CapsulenvProgramRealization, Get-CapsulenvGeneration, Publish-CapsulenvGeneration, Set-CapsulenvActiveGenerationAuthority, Get-CapsulenvActiveGeneration, Invoke-CapsulenvRealizationGarbageCollection
