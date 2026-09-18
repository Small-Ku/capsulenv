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
        $candidates.Add([pscustomobject][ordered]@{
            Kind = 'seed-acquisition'
            Name = [string]$entry.Name
            Version = [string]$entry.Version
            Provider = 'seed'
            Scope = 'portable'
            Provenance = [string]$entry.Provenance
            SourceReference = [string]$entry.SourceReference
            ExpectedHash = [string]$entry.ExpectedHash
            ExecutableRelativePath = [string]$entry.ExecutableRelativePath
        })
    }
    return @($candidates.ToArray())
}

function Get-CapsulenvSeedProgramCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Requirement)

    return Get-CapsulenvSeedAcquisitionCandidates -Requirement $Requirement
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

    $host = Resolve-CapsulenvProgram -Requirement $Requirement -Candidates $HostCandidates
    if ($host.Succeeded) {
        return [pscustomobject][ordered]@{
            Succeeded = $true
            Stage = 'existing-host-program'
            Selected = $host.Selected
            Diagnostics = @('trusted host realization selected before bootstrap')
        }
    }
    $seed = @($SeedCandidates | Where-Object {
        [string]$_.Kind -eq 'seed-acquisition' -and
        [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$_.Name, [string]$Requirement.Name)
    } | Select-Object -First 1)
    if ($seed.Count -eq 1) {
        return [pscustomobject][ordered]@{
            Succeeded = $true
            Stage = 'portable-seed'
            Selected = $seed[0]
            Diagnostics = @('verified immutable seed acquisition selected before provider acquisition')
        }
    }
    if ($RequireBootstrapNetwork -and -not $BootstrapNetworkReady) {
        throw 'Bootstrap network is required before normal provider acquisition, but no host or seed bootstrap program is available.'
    }
    $provider = Resolve-CapsulenvProgram -Requirement $Requirement -Candidates $ProviderCandidates
    return [pscustomobject][ordered]@{
        Succeeded = [bool]$provider.Succeeded
        Stage = 'normal-provider'
        Selected = $provider.Selected
        Diagnostics = if ($provider.Succeeded) { @('normal provider acquisition is permitted') } else { @('no compatible provider candidate is available') }
    }
}

##MOD_EXEC## Export-ModuleMember -Function New-CapsulenvPortableSeedEntry, Set-CapsulenvPortableSeedManifest, Get-CapsulenvPortableSeedEntries, Get-CapsulenvPortableSeedEntry, Test-CapsulenvPortableSeedEntry, Get-CapsulenvSeedAcquisitionCandidates, Get-CapsulenvSeedProgramCandidates, Invoke-CapsulenvBootstrapAcquisition
