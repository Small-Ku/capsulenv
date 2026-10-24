function Test-CapsulenvSafeRealizationComponent {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value)

    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

# A candidate's final hash directory is 64 hexadecimal characters. Reject an
# unlaunchable Windows path before materializing the owned host placement.
function Assert-CapsulenvRealizationExecutablePathBudget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$ExecutableRelativePath
    )

    if (-not (Test-CapsulenvWindows)) { return }
    $placement = Get-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity)
    $finalRoot = Join-Path (Join-Path (Join-Path $placement.PackagesRoot $Name) $Version) ('0' * 64)
    $executable = Resolve-CapsulenvRealizationPayloadPath -PayloadRoot (Join-Path $finalRoot 'payload') -ExecutableRelativePath $ExecutableRelativePath
    if ($executable.Length -ge 260) {
        throw ('Capsulenv host-local executable path is {0} characters long and may not launch on Windows. Configure a shorter CAPSULENV_HOST_STATE_ROOT or enrolled host placement root before acquisition. No realization was published.' -f $executable.Length)
    }
}
function Get-CapsulenvRealizationSourceHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [ValidateSet('ordinal-v1', 'legacy-runtime', 'legacy-windows-nls')]
        [string]$Algorithm = 'ordinal-v1'
    )

    $fullSource = [System.IO.Path]::GetFullPath($SourcePath)
    if (Test-Path -LiteralPath $fullSource -PathType Leaf) {
        return (Get-FileHash -LiteralPath $fullSource -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if (-not (Test-Path -LiteralPath $fullSource -PathType Container)) {
        throw "Realization source does not exist: $SourcePath"
    }

    $files = @(Get-ChildItem -LiteralPath $fullSource -File -Recurse)
    if ($Algorithm -eq 'legacy-runtime') {
        $paths = [string[]]@($files | Sort-Object FullName | ForEach-Object { $_.FullName })
    } else {
        $paths = [string[]]@($files | ForEach-Object { $_.FullName })
        if ($Algorithm -eq 'legacy-windows-nls') {
            if (-not (Test-CapsulenvWindows)) { throw 'NLS legacy hashing is Windows-only.' }
            if (-not ('CapsulenvLegacyNlsFilePathComparer' -as [type])) {
                Add-Type -TypeDefinition @"
using System;
using System.Collections;
using System.ComponentModel;
using System.Runtime.InteropServices;
public sealed class CapsulenvLegacyNlsFilePathComparer : IComparer {
    private readonly string locale;
    public CapsulenvLegacyNlsFilePathComparer(string localeName) { locale = localeName; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int CompareStringEx(
        string localeName, uint flags, string left, int leftLength,
        string right, int rightLength, IntPtr version, IntPtr reserved, IntPtr parameter);
    public int Compare(object left, object right) {
        const uint NORM_IGNORECASE = 1;
        int result = CompareStringEx(locale, NORM_IGNORECASE,
            (string)left, -1, (string)right, -1,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (result == 0) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
        return result - 2;
    }
}
"@ -ErrorAction Stop
            }
            $comparer = New-Object CapsulenvLegacyNlsFilePathComparer ([System.Globalization.CultureInfo]::CurrentCulture.Name)
            [System.Array]::Sort($paths, [System.Collections.IComparer]$comparer)
        } else {
            $prefixLength = $fullSource.TrimEnd([char[]]'\/').Length
            $relativePaths = [string[]]@($paths | ForEach-Object {
                $_.Substring($prefixLength).TrimStart([char[]]'\/').Replace('\', '/')
            })
            [System.Array]::Sort($relativePaths, [System.StringComparer]::Ordinal)
            $paths = [string[]]@($relativePaths | ForEach-Object {
                Join-Path $fullSource ($_.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
            })
        }
    }

    $entries = New-Object System.Collections.Generic.List[string]
    $prefixLength = $fullSource.TrimEnd([char[]]'\/').Length
    foreach ($path in $paths) {
        $relative = $path.Substring($prefixLength).TrimStart([char[]]'\/').Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $entries.Add(('{0}|{1}' -f $relative, $hash))
    }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $separator = if ($Algorithm -eq 'ordinal-v1') { [string][char]10 } else { [Environment]::NewLine }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($entries -join $separator))
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
        [Parameter(Mandatory = $true)]$Manifest,
        [ValidateSet('ordinal-v1','legacy-runtime','legacy-windows-nls')][string]$DirectoryHashAlgorithm = 'ordinal-v1'
    )

    $payloadRoot = Join-Path $RealizationRoot 'payload'
    if ([string]$Manifest.SourceKind -eq 'file') {
        $publishedFile = Resolve-CapsulenvRealizationPayloadPath -PayloadRoot $payloadRoot -ExecutableRelativePath ([string]$Manifest.ExecutableRelativePath)
        if (-not (Test-Path -LiteralPath $publishedFile -PathType Leaf)) {
            throw "Published realization payload is missing: $publishedFile"
        }
        return (Get-FileHash -LiteralPath $publishedFile -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return Get-CapsulenvRealizationSourceHash -SourcePath $payloadRoot -Algorithm $DirectoryHashAlgorithm
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
        [string]$ExpectedExecutableRelativePath,
        [string[]]$ExpectedCapabilities
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
    if ($PSBoundParameters.ContainsKey('ExpectedCapabilities')) {
        $expectedCapabilities = @($ExpectedCapabilities | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        $actualCapabilities = @($manifest.Capabilities | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        if ($expectedCapabilities.Count -ne $actualCapabilities.Count -or
            @($expectedCapabilities | Where-Object { $actualCapabilities -notcontains $_ }).Count -ne 0) {
            return $false
        }
    }
    $schema = 0
    if (-not [int]::TryParse([string]$manifest.SchemaVersion, [ref]$schema)) { return $false }
    if ($schema -eq 3) {
        if ([string]$manifest.DirectoryHashAlgorithm -ne 'ordinal-v1') { return $false }
    } elseif ($schema -ne 2 -or $null -ne $manifest.PSObject.Properties['DirectoryHashAlgorithm']) {
        return $false
    }
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals(
        [string]$manifest.SourceHash, [string]$manifest.PayloadHash)) { return $false }
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
        $algorithm = if ($schema -eq 2) { 'legacy-runtime' } else { 'ordinal-v1' }
        $payloadHash = Get-CapsulenvRealizationPayloadHash -RealizationRoot $RealizationRoot -Manifest $manifest -DirectoryHashAlgorithm $algorithm
        if ([System.StringComparer]::OrdinalIgnoreCase.Equals([string]$manifest.PayloadHash, $payloadHash)) { return $true }
        if ($schema -eq 2 -and [string]$manifest.SourceKind -eq 'directory' -and (Test-CapsulenvWindows)) {
            # Schema-v2 WinPS5 generations were hashed with Windows NLS; pwsh
            # uses ICU. Only a full directory digest match confers authority.
            $legacyHash = Get-CapsulenvRealizationPayloadHash -RealizationRoot $RealizationRoot -Manifest $manifest -DirectoryHashAlgorithm 'legacy-windows-nls'
            return [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$manifest.PayloadHash, $legacyHash)
        }
        return $false
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
        [string]$Provenance,
        [string[]]$Capabilities = @()
    )

    if ([string]::IsNullOrWhiteSpace($AcquisitionProvider)) {
        $AcquisitionProvider = $Provider
        if ($Provider -in @('seed', 'provider', 'host-scoop')) {
            # The pre-schema-2 API used Provider for acquisition origin. A
            # materialized realization is always a host-local authority.
            $Provider = 'capsulenv-local'
        }
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
    $normalizedCapabilities = @($Capabilities | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if (-not [string]::IsNullOrWhiteSpace($ExpectedHash) -and
        -not [System.StringComparer]::OrdinalIgnoreCase.Equals($sourceHash, $ExpectedHash)) {
        # Portable seed schema-v1 records a legacy tree digest. Verify those
        # original bytes under the seed contract, then publish a distinct
        # ordinal-v1 realization digest. Do not reinterpret other providers.
        $legacySeedHash = if ($sourceIsDirectory -and $AcquisitionProvider -eq 'seed') {
            Get-CapsulenvSeedSourceHash -SourcePath $sourceFull
        } else { $null }
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$legacySeedHash, $ExpectedHash)) {
            throw "Realization source hash mismatch for '$Name': expected $ExpectedHash, got $sourceHash."
        }
    }

    $placement = Initialize-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity)
    # Staging has no durable authority; keep its path shallow for WinPS 5.1 deep trees.
    $stagingBase = Join-Path (Get-CapsulenvHostLocalStateRoot) 'realization-staging'
    $stagingRoot = Join-Path $stagingBase ([Guid]::NewGuid().ToString('N'))
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
            if (Test-CapsulenvProgramRealization -RealizationRoot $finalRoot -ExpectedName $Name -ExpectedHash $stagedSourceHash -ExpectedVersion $Version -ExpectedProvider $Provider -ExpectedAcquisitionProvider $AcquisitionProvider -ExpectedProvenance $Provenance -ExpectedExecutableRelativePath $ExecutableRelativePath -ExpectedCapabilities $normalizedCapabilities) {
                return (Read-CapsulenvRealizationManifest -RealizationRoot $finalRoot) | Add-Member -NotePropertyName RealizationRoot -NotePropertyValue $finalRoot -PassThru
            }
            throw "An immutable realization with the same bytes has incompatible semantic identity: $finalRoot"
        }
        $manifest = [pscustomobject][ordered]@{
            SchemaVersion = 3
            DirectoryHashAlgorithm = 'ordinal-v1'
            Complete = $true
            Immutable = $true
            Name = $Name
            Version = $Version
            Provider = $Provider
            AcquisitionProvider = $AcquisitionProvider
            Provenance = $Provenance
            Capabilities = @($normalizedCapabilities)
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
            if (-not (Test-CapsulenvProgramRealization -RealizationRoot ([string]$selection.RealizationRoot) -ExpectedName ([string]$selection.Name) -ExpectedHash ([string]$selection.SourceHash) -ExpectedVersion ([string]$selection.Version) -ExpectedProvider ([string]$selection.Provider) -ExpectedAcquisitionProvider ([string]$selection.AcquisitionProvider) -ExpectedProvenance ([string]$selection.Provenance) -ExpectedExecutableRelativePath ([string]$selection.ExecutableRelativePath) -ExpectedCapabilities @($selection.Capabilities))) {
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
            $realization = Acquire-CapsulenvProgramRealization -Name ([string]$realization.Name) -Version ([string]$realization.Version) -SourcePath $source -ExecutableRelativePath ([string]$realization.ExecutableRelativePath) -ExpectedHash ([string]$realization.ExpectedHash) -Provider capsulenv-local -AcquisitionProvider seed -Provenance ([string]$realization.Provenance) -Capabilities @($realization.Capabilities)
            $kind = 'realization'
        }
        if ($kind -eq 'realization') {
            $root = [string]$realization.RealizationRoot
            if (-not (Test-CapsulenvProgramRealization -RealizationRoot $root)) {
                # Publish only complete, hash-verified trees. Explain verification
                # failures without modifying a previously published realization.
                $detail = 'manifest or executable validation failed'
                $invalidManifest = Read-CapsulenvRealizationManifest -RealizationRoot $root
                if ($null -eq $invalidManifest) {
                    $detail = 'realization manifest is missing or unreadable'
                } else {
                    $payloadRoot = Join-Path $root 'payload'
                    if (-not (Test-Path -LiteralPath $payloadRoot -PathType Container)) {
                        $detail = 'realization payload directory is missing'
                    } else {
                        try {
                            $actualHash = Get-CapsulenvRealizationPayloadHash -RealizationRoot $root -Manifest $invalidManifest
                            if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals(
                                [string]$invalidManifest.PayloadHash, $actualHash)) {
                                $detail = "payload hash mismatch: expected $($invalidManifest.PayloadHash), actual $actualHash"
                            }
                        } catch {
                            $detail = "payload verification failed: $($_.Exception.Message)"
                        }
                    }
                }
                throw "Cannot publish a generation with an incomplete realization: $root. $detail"
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
                Capabilities = if ($null -ne $manifest.PSObject.Properties['Capabilities']) { @($manifest.Capabilities) } else { @() }
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
                AcquisitionProvider = if ($null -ne $program.PSObject.Properties['AcquisitionProvider']) { [string]$program.AcquisitionProvider } else { [string]$program.Provider }
                Capabilities = if ($null -ne $program.PSObject.Properties['Capabilities']) { @($program.Capabilities) } else { @() }
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
