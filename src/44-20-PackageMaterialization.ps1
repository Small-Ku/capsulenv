function Get-CapsulenvFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Get-CapsulenvPackageCachedArtifact {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Download)

    $cacheRoot = Get-CapsulenvPackageCacheRoot
    $cacheDirectory = Join-Path $cacheRoot ([string]$Download.Hash)
    $path = Join-Path $cacheDirectory ([string]$Download.FileName)
    [void](New-Item -ItemType Directory -Path $cacheDirectory -Force)

    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $actual = Get-CapsulenvFileSha256 -Path $path
        if ([System.StringComparer]::OrdinalIgnoreCase.Equals($actual, [string]$Download.Hash)) {
            return $path
        }
        Remove-Item -LiteralPath $path -Force
    }

    $temporary = Join-Path $cacheDirectory ('.download-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        $uri = [Uri]([string]$Download.Url)
        if ($uri.Scheme -eq 'file') {
            Copy-Item -LiteralPath $uri.LocalPath -Destination $temporary -Force
        } else {
            $parameters = @{
                Uri = [string]$Download.Url
                OutFile = $temporary
                ErrorAction = 'Stop'
            }
            if ($PSVersionTable.PSVersion.Major -le 5) {
                $parameters['UseBasicParsing'] = $true
            }
            Invoke-WebRequest @parameters
        }
        $actual = Get-CapsulenvFileSha256 -Path $temporary
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($actual, [string]$Download.Hash)) {
            throw "Package hash mismatch for $($Download.OriginalUrl): expected $($Download.Hash), got $actual"
        }
        Move-Item -LiteralPath $temporary -Destination $path
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
    return $path
}

function Initialize-CapsulenvPortablePackageWorkerRuntime {
    [CmdletBinding()]
    param()

    # Identity state and runtime types are process-wide prerequisites. They are
    # initialized by the parent before any package worker is dispatched.
    [void](Get-CapsulenvIdentity)
    Initialize-CapsulenvFileIdentityRuntime
    if (-not ('System.IO.Compression.ZipArchive' -as [type])) {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    }
}

function Assert-CapsulenvPortablePackageWorkerRuntime {
    [CmdletBinding()]
    param()

    if (-not ('System.IO.Compression.ZipArchive' -as [type])) {
        throw 'Capsulenv package archive runtime was not initialized in the parent runspace before worker execution.'
    }
    Assert-CapsulenvFileIdentityRuntime
}

function Expand-CapsulenvSafeZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    [void](New-Item -ItemType Directory -Path $Destination -Force)
    Assert-CapsulenvPortablePackageWorkerRuntime
    $destinationRoot = [System.IO.Path]::GetFullPath($Destination).TrimEnd([char[]]'\/')
    $prefix = $destinationRoot + [System.IO.Path]::DirectorySeparatorChar
    $stream = [System.IO.File]::OpenRead($Archive)
    $zip = New-Object System.IO.Compression.ZipArchive(
        $stream,
        [System.IO.Compression.ZipArchiveMode]::Read,
        $false
    )
    try {
        foreach ($entry in $zip.Entries) {
            $relative = ([string]$entry.FullName).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            if ([string]::IsNullOrWhiteSpace($relative)) {
                continue
            }
            $target = [System.IO.Path]::GetFullPath((Join-Path $destinationRoot $relative))
            if (
                -not [System.StringComparer]::OrdinalIgnoreCase.Equals($target.TrimEnd([char[]]'\/'), $destinationRoot) -and
                -not $target.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
            ) {
                throw "ZIP entry escapes the extraction root: $($entry.FullName)"
            }
            if ([string]::IsNullOrWhiteSpace([string]$entry.Name)) {
                [void](New-Item -ItemType Directory -Path $target -Force)
                continue
            }
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force)
            if (Test-Path -LiteralPath $target) {
                throw "ZIP contains a duplicate extraction target: $($entry.FullName)"
            }
            $inputStream = $entry.Open()
            $outputStream = [System.IO.File]::Create($target)
            try {
                $inputStream.CopyTo($outputStream)
            } finally {
                $outputStream.Dispose()
                $inputStream.Dispose()
            }
        }
    } finally {
        $zip.Dispose()
        $stream.Dispose()
    }
}

function Get-CapsulenvPackageIndexedValue {
    [CmdletBinding()]
    param(
        [object[]]$Values,
        [int]$Index
    )

    if ($null -eq $Values -or $Values.Count -eq 0) { return '' }
    if ($Values.Count -eq 1) { return [string]$Values[0] }
    return [string]$Values[$Index]
}

function Copy-CapsulenvPackageTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    [void](New-Item -ItemType Directory -Path $Destination -Force)
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) {
            Copy-CapsulenvPackageTree -Source $item.FullName -Destination $target
        } else {
            if (Test-Path -LiteralPath $target) {
                throw "Package artifacts collide at: $target"
            }
            Copy-Item -LiteralPath $item.FullName -Destination $target
        }
    }
}

function Expand-CapsulenvPackageDownloads {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    [void](New-Item -ItemType Directory -Path $Destination -Force)
    foreach ($download in @($Plan.Downloads)) {
        $artifact = Get-CapsulenvPackageCachedArtifact -Download $download
        $extractTo = Get-CapsulenvPackageIndexedValue -Values @($Plan.ExtractTo) -Index ([int]$download.Index)
        $targetRoot = if ([string]::IsNullOrWhiteSpace($extractTo)) {
            $Destination
        } else {
            Resolve-CapsulenvScoopAppRelativePath -Root $Destination -RelativePath $extractTo
        }
        [void](New-Item -ItemType Directory -Path $targetRoot -Force)

        if ([string]$download.ArchiveKind -eq 'Zip') {
            $staging = Join-Path (Split-Path -Parent $Destination) ('.extract-{0}' -f [Guid]::NewGuid().ToString('N'))
            try {
                Expand-CapsulenvSafeZip -Archive $artifact -Destination $staging
                $extractDir = Get-CapsulenvPackageIndexedValue -Values @($Plan.ExtractDir) -Index ([int]$download.Index)
                $sourceRoot = if ([string]::IsNullOrWhiteSpace($extractDir)) {
                    $staging
                } else {
                    Resolve-CapsulenvScoopAppRelativePath -Root $staging -RelativePath $extractDir
                }
                if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
                    throw "extract_dir was not found in package archive: $extractDir"
                }
                Copy-CapsulenvPackageTree -Source $sourceRoot -Destination $targetRoot
            } finally {
                if (Test-Path -LiteralPath $staging) {
                    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        } elseif ([string]$download.ArchiveKind -eq 'File') {
            $target = Join-Path $targetRoot ([string]$download.FileName)
            if (Test-Path -LiteralPath $target) {
                throw "Package artifacts collide at: $target"
            }
            Copy-Item -LiteralPath $artifact -Destination $target
        } else {
            throw "PortableSafe executor cannot extract $($download.FileName)."
        }
    }
}

function Set-CapsulenvPackageDirectoryLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $existingTarget = Get-CapsulenvReparseTarget -Path $Path
    if ($null -ne $existingTarget) {
        if (Test-CapsulenvSamePath -Left $existingTarget -Right $Target) {
            return
        }
        Remove-CapsulenvPackageReparsePoint -Path $Path
    } elseif (Test-Path -LiteralPath $Path) {
        throw "Refusing to replace a non-link path while projecting a package: $Path"
    }
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force)
    $linkType = if (Test-CapsulenvWindows) { 'Junction' } else { 'SymbolicLink' }
    [void](New-Item -ItemType $linkType -Path $Path -Target $Target -Force)
}

function Set-CapsulenvPackageFileLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $existingTarget = Get-CapsulenvReparseTarget -Path $Path
    if ($null -ne $existingTarget) {
        if (Test-CapsulenvSamePath -Left $existingTarget -Right $Target) {
            return
        }
        Remove-CapsulenvPackageReparsePoint -Path $Path
    } elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
        if ((Test-CapsulenvWindows) -and (Test-CapsulenvHardLinkMatch -Left $Path -Right $Target)) {
            return
        }
        throw "Refusing to replace a normal file while projecting package persistence: $Path"
    } elseif (Test-Path -LiteralPath $Path) {
        throw "Refusing to replace a non-file path while projecting package persistence: $Path"
    }
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force)
    $linkType = if (Test-CapsulenvWindows) { 'HardLink' } else { 'SymbolicLink' }
    [void](New-Item -ItemType $linkType -Path $Path -Target $Target -Force)
}

function Repair-CapsulenvPackageFileProjection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$OwnershipLabel
    )

    if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) {
        throw "Persist target is not a file while repairing $OwnershipLabel`: $Target"
    }

    $existingTarget = Get-CapsulenvReparseTarget -Path $Path
    if ($null -ne $existingTarget) {
        if (Test-CapsulenvSamePath -Left $existingTarget -Right $Target) {
            return
        }
        Remove-CapsulenvPackageReparsePoint -Path $Path
        Set-CapsulenvPackageFileLink -Path $Path -Target $Target
        return
    }

    if (Test-Path -LiteralPath $Path -PathType Container) {
        throw "Persist source kind no longer matches its file target while repairing $OwnershipLabel`: $Path"
    }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        if ((Test-CapsulenvWindows) -and (Test-CapsulenvHardLinkMatch -Left $Path -Right $Target)) {
            return
        }
        $sourceHash = Get-CapsulenvFileSha256 -Path $Path
        $targetHash = Get-CapsulenvFileSha256 -Path $Target
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($sourceHash, $targetHash)) {
            throw "Refusing to replace a diverged normal file while repairing $OwnershipLabel`: $Path"
        }
        Remove-Item -LiteralPath $Path -Force
    } elseif (Test-Path -LiteralPath $Path) {
        throw "Refusing to replace an unknown path while repairing $OwnershipLabel`: $Path"
    }
    Set-CapsulenvPackageFileLink -Path $Path -Target $Target
}

function Remove-CapsulenvPackageReparsePoint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    # Scoop and older Capsulenv versions can leave a stale junction with the
    # ReadOnly attribute set. Windows PowerShell 5.1's Remove-Item -Force still
    # refuses that broken directory junction. We have already inspected the
    # reparse target before reaching this helper, so remove only the link itself
    # with the .NET directory/file API; never recurse through its target.
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
        throw "Refusing to remove a non-reparse path while replacing a package projection: $Path"
    }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
        $item.Attributes = $item.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
    }
    if ($item.PSIsContainer) {
        [System.IO.Directory]::Delete($Path, $false)
    } else {
        [System.IO.File]::Delete($Path)
    }
}

function Get-CapsulenvPackagePersistDefinitions {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan)

    if ($null -eq $Plan.Persist) { return @() }
    $items = @(if ($Plan.Persist -is [string]) { [string]$Plan.Persist } else { @($Plan.Persist) })
    return @(
        foreach ($item in $items) {
            $parts = @(if ($item -is [string]) { [string]$item } else { @($item) })
            $source = [string]$parts[0]
            $target = if ($parts.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace([string]$parts[1])) {
                [string]$parts[1]
            } else {
                $source
            }
            [pscustomobject]@{ Source = $source; Target = $target }
        }
    )
}

function Initialize-CapsulenvPackagePersistence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$VersionRoot
    )

    $persistRoot = Join-Path (Get-CapsulenvPackagePersistRoot) ([string]$Plan.Name)
    $mappings = New-Object System.Collections.Generic.List[object]
    foreach ($definition in @(Get-CapsulenvPackagePersistDefinitions -Plan $Plan)) {
        $source = Resolve-CapsulenvScoopAppRelativePath -Root $VersionRoot -RelativePath ([string]$definition.Source)
        $target = Resolve-CapsulenvScoopAppRelativePath -Root $persistRoot -RelativePath ([string]$definition.Target)
        $sourceExists = Test-Path -LiteralPath $source
        $targetExists = Test-Path -LiteralPath $target
        if (-not $sourceExists -and -not $targetExists) {
            throw "Persist source does not exist after extraction: $($definition.Source)"
        }

        $kind = $null
        if ($targetExists) {
            $kind = if ((Get-Item -LiteralPath $target -Force).PSIsContainer) { 'Directory' } else { 'File' }
            if ($sourceExists) {
                $sourceKind = if ((Get-Item -LiteralPath $source -Force).PSIsContainer) { 'Directory' } else { 'File' }
                if ($sourceKind -ne $kind) {
                    throw "Persist source kind changed for $($Plan.Name): $($definition.Source)"
                }
                Remove-Item -LiteralPath $source -Recurse -Force
            }
        } else {
            $kind = if ((Get-Item -LiteralPath $source -Force).PSIsContainer) { 'Directory' } else { 'File' }
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force)
            Move-Item -LiteralPath $source -Destination $target
        }

        if ($kind -eq 'Directory') {
            Set-CapsulenvPackageDirectoryLink -Path $source -Target $target
        } else {
            Set-CapsulenvPackageFileLink -Path $source -Target $target
        }
        $mappings.Add([pscustomobject]@{
            Source = [string]$definition.Source
            Target = [string]$definition.Target
            Kind = $kind
        })
    }
    return $mappings.ToArray()
}

function Save-CapsulenvPackageInstalledState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$VersionRoot,
        [object[]]$PersistMappings = @(),
        [string[]]$Shims = @()
    )

    $packageRoot = Join-Path (Get-CapsulenvPackageRoot) ([string]$Plan.Name)
    $currentRoot = Join-Path $packageRoot 'current'
    $persistRoot = Join-Path (Get-CapsulenvPackagePersistRoot) ([string]$Plan.Name)
    $statePath = Get-CapsulenvPackageStatePath -Name ([string]$Plan.Name)
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force)
    $temporary = Join-Path (Split-Path -Parent $statePath) ('.package-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        $manifestPath = Join-Path $VersionRoot 'manifest.json'
        $installPath = Join-Path $VersionRoot 'install.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or -not (Test-Path -LiteralPath $installPath -PathType Leaf)) {
            throw "Capsulenv package metadata is incomplete and cannot be recorded: $VersionRoot"
        }
        [ordered]@{
            SchemaVersion = 1
            CapsuleId = (Get-CapsulenvIdentity)
            Provider = 'Capsulenv'
            Name = [string]$Plan.Name
            Version = [string]$Plan.Version
            Architecture = [string]$Plan.Architecture
            Bucket = [string]$Plan.Bucket
            Reference = [string]$Plan.Reference
            SourceManifestSha256 = (Get-CapsulenvFileSha256 -Path ([string]$Plan.ManifestPath))
            InstalledManifestSha256 = (Get-CapsulenvFileSha256 -Path $manifestPath)
            InstallMetadataSha256 = (Get-CapsulenvFileSha256 -Path $installPath)
            InstallRoot = ConvertTo-CapsulenvStatePathReference -Path $VersionRoot
            CurrentRoot = ConvertTo-CapsulenvStatePathReference -Path $currentRoot
            PersistRoot = ConvertTo-CapsulenvStatePathReference -Path $persistRoot
            PersistMappings = @($PersistMappings)
            Shims = @($Shims)
            Capabilities = @($Plan.Capabilities)
            InstalledAtUtc = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            try {
                [System.IO.File]::Replace($temporary, $statePath, $null, $true)
            } catch {
                Remove-Item -LiteralPath $statePath -Force
                Move-Item -LiteralPath $temporary -Destination $statePath
            }
        } else {
            Move-Item -LiteralPath $temporary -Destination $statePath
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-CapsulenvPackageShim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Package,
        [Parameter(Mandatory = $true)][string]$Alias
    )

    if (-not (Test-CapsulenvPortableFileNameComponent -Value $Alias) -or $Alias -in @('capsulenv', 'scoop')) {
        throw "Invalid or reserved Capsulenv package shim alias: $Alias"
    }
    $shimRoot = Get-CapsulenvPackageShimRoot
    [void](New-Item -ItemType Directory -Path $shimRoot -Force)
    $path = Join-Path $shimRoot ($Alias + '.cmd')
    $marker = "@rem capsulenv-package: $Package"
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $firstLine = Get-Content -LiteralPath $path -TotalCount 1
        if ([string]$firstLine -ne $marker) {
            throw "Capsulenv package shim alias is already owned by another entry: $Alias"
        }
    }
    $text = $marker + [Environment]::NewLine + @'
@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "CAPSULENV_SHIM_ROOT=%~dp0.."
call "%CAPSULENV_SHIM_ROOT%\capsulenv.cmd" app exec __PACKAGE__ "__ALIAS__" -- %*
exit /b %ERRORLEVEL%
'@
    $text = $text.Replace('__PACKAGE__', ('capsule/' + $Package)).Replace('__ALIAS__', $Alias)
    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Sync-CapsulenvPackageShims {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    $installed = Get-CapsulenvInstalledPackageState -Name $Name
    $desired = New-Object System.Collections.Generic.List[string]
    foreach ($bin in @(Get-CapsulenvScoopAppBins -App ('capsule/' + $Name))) {
        $alias = [string]$bin.Name
        [void](Write-CapsulenvPackageShim -Package $Name -Alias $alias)
        $desired.Add($alias)
    }

    $shimRoot = Get-CapsulenvPackageShimRoot
    foreach ($oldAlias in @($installed.Shims)) {
        if ($desired -contains [string]$oldAlias) { continue }
        $path = Join-Path $shimRoot (([string]$oldAlias) + '.cmd')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $firstLine = Get-Content -LiteralPath $path -TotalCount 1
        if ([string]$firstLine -eq "@rem capsulenv-package: $Name") {
            Remove-Item -LiteralPath $path -Force
        }
    }
    return $desired.ToArray()
}
