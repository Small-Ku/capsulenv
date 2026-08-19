function Get-CapsulenvPackageStatePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

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
    if ([int]$state.SchemaVersion -ne 1 -or [string]$state.Name -ne $Name) {
        throw "Capsulenv package state has an unsupported schema or identity: $path"
    }
    $capsuleId = $state.PSObject.Properties['CapsuleId']
    if (
        $null -eq $capsuleId -or
        -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$capsuleId.Value, [string](Get-CapsulenvIdentity))
    ) {
        throw "Capsulenv package state belongs to another capsule identity: $path"
    }

    $installRoot = Resolve-CapsulenvStatePathReference -Reference ([string]$state.InstallRoot)
    $currentRoot = Resolve-CapsulenvStatePathReference -Reference ([string]$state.CurrentRoot)
    $persistRoot = Resolve-CapsulenvStatePathReference -Reference ([string]$state.PersistRoot)
    return [pscustomobject]@{
        Path = $path
        State = $state
        Name = [string]$state.Name
        Version = [string]$state.Version
        Architecture = [string]$state.Architecture
        Bucket = [string]$state.Bucket
        Reference = [string]$state.Reference
        InstallRoot = $installRoot
        CurrentRoot = $currentRoot
        PersistRoot = $persistRoot
        ManifestPath = Join-Path $installRoot 'manifest.json'
        InstallPath = Join-Path $installRoot 'install.json'
        PersistMappings = @($state.PersistMappings)
        Shims = @($state.Shims)
        Capabilities = @($state.Capabilities)
    }
}

function Get-CapsulenvInstalledPackageStates {
    [CmdletBinding()]
    param()

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
    try {
        [void](Resolve-CapsulenvPackageManifest -Reference $candidate)
        return $candidate
    } catch {
        return $Dependency
    }
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

function Expand-CapsulenvSafeZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    [void](New-Item -ItemType Directory -Path $Destination -Force)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
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
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
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

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        if ((Test-CapsulenvWindows) -and (Test-CapsulenvHardLinkMatch -Left $Path -Right $Target)) {
            return
        }
        Remove-Item -LiteralPath $Path -Force
    } elseif (Test-Path -LiteralPath $Path) {
        throw "Refusing to replace a non-file path while projecting package persistence: $Path"
    }
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force)
    $linkType = if (Test-CapsulenvWindows) { 'HardLink' } else { 'SymbolicLink' }
    [void](New-Item -ItemType $linkType -Path $Path -Target $Target -Force)
}

function Get-CapsulenvPackagePersistDefinitions {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan)

    if ($null -eq $Plan.Persist) { return @() }
    $items = if ($Plan.Persist -is [string]) { @([string]$Plan.Persist) } else { @($Plan.Persist) }
    return @(
        foreach ($item in $items) {
            $parts = if ($item -is [string]) { @([string]$item) } else { @($item) }
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
        [ordered]@{
            SchemaVersion = 1
            CapsuleId = (Get-CapsulenvIdentity)
            Provider = 'Capsulenv'
            Name = [string]$Plan.Name
            Version = [string]$Plan.Version
            Architecture = [string]$Plan.Architecture
            Bucket = [string]$Plan.Bucket
            Reference = [string]$Plan.Reference
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

    if ($Alias -match '[\\/]' -or $Alias -in @('capsulenv', 'scoop')) {
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

function Install-CapsulenvPortablePackageNode {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan)

    if ([string]$Plan.Classification -ne 'PortableSafe') {
        throw "Package '$($Plan.Reference)' is not PortableSafe: $($Plan.Classification)"
    }
    $existing = Get-CapsulenvInstalledPackageState -Name ([string]$Plan.Name) -AllowMissing
    if (
        $null -ne $existing -and
        [string]$existing.Version -eq [string]$Plan.Version -and
        [string]$existing.Architecture -eq [string]$Plan.Architecture -and
        (Test-Path -LiteralPath $existing.InstallRoot -PathType Container)
    ) {
        Repair-CapsulenvPackageProjection -State $existing
        $shims = @(Sync-CapsulenvPackageShims -Name ([string]$Plan.Name))
        Save-CapsulenvPackageInstalledState `
            -Plan $Plan `
            -VersionRoot $existing.InstallRoot `
            -PersistMappings @($existing.PersistMappings) `
            -Shims $shims
        return Get-CapsulenvInstalledPackageState -Name ([string]$Plan.Name)
    }

    $appRoot = Join-Path (Get-CapsulenvPackageRoot) ([string]$Plan.Name)
    $versionRoot = Join-Path $appRoot ([string]$Plan.Version)
    if (Test-Path -LiteralPath $versionRoot) {
        throw "Capsulenv package version path already exists but is not the active installed state: $versionRoot"
    }
    [void](New-Item -ItemType Directory -Path $appRoot -Force)
    $temporaryRoot = Join-Path $appRoot ('.install-{0}' -f [Guid]::NewGuid().ToString('N'))
    try {
        [void](New-Item -ItemType Directory -Path $temporaryRoot -Force)
        Expand-CapsulenvPackageDownloads -Plan $Plan -Destination $temporaryRoot
        $persistMappings = @(Initialize-CapsulenvPackagePersistence -Plan $Plan -VersionRoot $temporaryRoot)
        $Plan.SourceManifest | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath (Join-Path $temporaryRoot 'manifest.json') -Encoding UTF8
        [ordered]@{
            architecture = [string]$Plan.Architecture
            bucket = [string]$Plan.Bucket
            provider = 'capsulenv'
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $temporaryRoot 'install.json') -Encoding UTF8
        Move-Item -LiteralPath $temporaryRoot -Destination $versionRoot
        Set-CapsulenvPackageDirectoryLink -Path (Join-Path $appRoot 'current') -Target $versionRoot
        Save-CapsulenvPackageInstalledState -Plan $Plan -VersionRoot $versionRoot -PersistMappings $persistMappings
        $shims = @(Sync-CapsulenvPackageShims -Name ([string]$Plan.Name))
        Save-CapsulenvPackageInstalledState -Plan $Plan -VersionRoot $versionRoot -PersistMappings $persistMappings -Shims $shims
        return Get-CapsulenvInstalledPackageState -Name ([string]$Plan.Name)
    } catch {
        if (Test-Path -LiteralPath $temporaryRoot) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Install-CapsulenvPortablePackage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Reference)

    $installPlan = Get-CapsulenvPackageInstallPlan -Reference $Reference
    if ([string]$installPlan.Classification -ne 'PortableSafe') {
        $blocked = @($installPlan.BlockedPackages | ForEach-Object {
            '{0} [{1}] {2}' -f $_.Reference, $_.Classification, (@($_.Reasons) -join '; ')
        }) -join [Environment]::NewLine
        throw "PortableSafe installation is unavailable because trusted/unsupported package semantics are required:`n$blocked"
    }
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($plan in @($installPlan.Packages)) {
        $results.Add((Install-CapsulenvPortablePackageNode -Plan $plan))
    }
    return $results.ToArray()
}

function Repair-CapsulenvPackageProjection {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State)

    if (-not (Test-Path -LiteralPath $State.InstallRoot -PathType Container)) {
        throw "Installed Capsulenv package files are missing: $($State.Name) $($State.InstallRoot)"
    }
    Set-CapsulenvPackageDirectoryLink -Path $State.CurrentRoot -Target $State.InstallRoot
    foreach ($mapping in @($State.PersistMappings)) {
        $source = Resolve-CapsulenvScoopAppRelativePath -Root $State.InstallRoot -RelativePath ([string]$mapping.Source)
        $target = Resolve-CapsulenvScoopAppRelativePath -Root $State.PersistRoot -RelativePath ([string]$mapping.Target)
        if (-not (Test-Path -LiteralPath $target)) {
            throw "Persist target is missing for $($State.Name): $target"
        }
        if ([string]$mapping.Kind -eq 'Directory') {
            $existingTarget = Get-CapsulenvReparseTarget -Path $source
            if ($null -ne $existingTarget -and -not (Test-CapsulenvSamePath -Left $existingTarget -Right $target)) {
                Remove-Item -LiteralPath $source -Force
            }
            if ($null -eq (Get-CapsulenvReparseTarget -Path $source)) {
                if (Test-Path -LiteralPath $source) {
                    throw "Persist projection was replaced by a normal path: $source"
                }
                Set-CapsulenvPackageDirectoryLink -Path $source -Target $target
            }
        } else {
            if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or ((Test-CapsulenvWindows) -and -not (Test-CapsulenvHardLinkMatch -Left $source -Right $target))) {
                if (Test-Path -LiteralPath $source) {
                    Remove-Item -LiteralPath $source -Force
                }
                Set-CapsulenvPackageFileLink -Path $source -Target $target
            }
        }
    }
}

function Repair-CapsulenvPackageProjections {
    [CmdletBinding()]
    param()

    foreach ($state in @(Get-CapsulenvInstalledPackageStates)) {
        Repair-CapsulenvPackageProjection -State $state
    }
}

function Get-CapsulenvPackageEnvironmentPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Installed)

    if ([string]$Installed.Scope -ne 'Capsule') {
        throw "Package process environment is reserved for Capsulenv-owned PortableSafe packages: $($Installed.Selector)"
    }
    $pathProperty = Get-CapsulenvInstalledManifestPropertyRecord -App $Installed -Name 'env_add_path'
    $setProperty = Get-CapsulenvInstalledManifestPropertyRecord -App $Installed -Name 'env_set'
    $pathEntries = New-Object System.Collections.Generic.List[string]
    if ($null -ne $pathProperty.Value) {
        $values = if ($pathProperty.Value -is [string]) { @([string]$pathProperty.Value) } else { @($pathProperty.Value) }
        foreach ($value in $values) {
            $raw = [string]$value
            if ($raw.Contains('$dir') -or $raw.Contains('$original_dir') -or $raw.Contains('$persist_dir')) {
                $expanded = Expand-CapsulenvScoopShortcutValue -Value $raw -App $Installed
                $candidate = [System.IO.Path]::GetFullPath($expanded)
                $currentRoot = [System.IO.Path]::GetFullPath([string]$Installed.Current).TrimEnd([char[]]'\/')
                if (
                    -not [System.StringComparer]::OrdinalIgnoreCase.Equals($candidate.TrimEnd([char[]]'\/'), $currentRoot) -and
                    -not $candidate.StartsWith($currentRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
                ) {
                    throw "env_add_path escapes the installed package root: $raw"
                }
                $pathEntries.Add($candidate)
            } else {
                $pathEntries.Add((Resolve-CapsulenvScoopAppRelativePath -Root $Installed.Current -RelativePath $raw))
            }
        }
    }
    $variables = [ordered]@{}
    if ($null -ne $setProperty.Value) {
        foreach ($property in @($setProperty.Value.PSObject.Properties)) {
            $variables[[string]$property.Name] = Expand-CapsulenvScoopShortcutValue -Value ([string]$property.Value) -App $Installed
        }
    }
    return [pscustomobject]@{
        PathEntries = $pathEntries.ToArray()
        Variables = $variables
    }
}

function Set-CapsulenvPackageProcessEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Installed)

    $environment = Get-CapsulenvPackageEnvironmentPlan -Installed $Installed
    foreach ($name in $environment.Variables.Keys) {
        [Environment]::SetEnvironmentVariable([string]$name, [string]$environment.Variables[$name], 'Process')
    }
    if ($environment.PathEntries.Count -gt 0) {
        $env:PATH = Merge-CapsulenvPath -ExistingPath $env:PATH -Prepend @($environment.PathEntries)
    }
    return $environment
}

function Get-CapsulenvPackageProcessPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [Parameter(Mandatory = $true)][string]$BinName
    )

    $installed = Get-CapsulenvInstalledScoopApp -Selector $App
    if ([string]$installed.Scope -ne 'Capsule') {
        throw "app exec is reserved for Capsulenv-owned PortableSafe packages: $App"
    }
    $matches = @(Get-CapsulenvScoopAppBins -App $installed.Selector | Where-Object {
        [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$_.Name, $BinName)
    })
    if ($matches.Count -ne 1) {
        throw "Capsulenv package '$($installed.Name)' does not expose exactly one bin named '$BinName'."
    }
    $environment = Get-CapsulenvPackageEnvironmentPlan -Installed $installed
    return [pscustomobject]@{
        App = [string]$installed.Selector
        BinName = $BinName
        FilePath = [string]$matches[0].Target
        PathEntries = @($environment.PathEntries)
        Variables = $environment.Variables
    }
}

function Invoke-CapsulenvPackageExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [Parameter(Mandatory = $true)][string]$BinName,
        [string[]]$Arguments = @()
    )

    [void](Set-CapsulenvSessionEnvironment)
    $plan = Get-CapsulenvPackageProcessPlan -App $App -BinName $BinName
    foreach ($name in $plan.Variables.Keys) {
        [Environment]::SetEnvironmentVariable([string]$name, [string]$plan.Variables[$name], 'Process')
    }
    if ($plan.PathEntries.Count -gt 0) {
        $env:PATH = Merge-CapsulenvPath -ExistingPath $env:PATH -Prepend @($plan.PathEntries)
    }
    if (-not (Test-Path -LiteralPath $plan.FilePath -PathType Leaf)) {
        throw "Capsulenv package executable is missing: $($plan.FilePath)"
    }
    Clear-CapsulenvLastExitCode
    & $plan.FilePath @Arguments
    $succeeded = $?
    return Get-CapsulenvLastExitCode -Succeeded $succeeded
}

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvPackageInstallPlan, Install-CapsulenvPortablePackage, Repair-CapsulenvPackageProjections
