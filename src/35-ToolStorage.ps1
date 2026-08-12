function Test-CapsulenvSamePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $leftPath = [System.IO.Path]::GetFullPath($Left).TrimEnd([char[]]'\/')
    $rightPath = [System.IO.Path]::GetFullPath($Right).TrimEnd([char[]]'\/')
    return [System.StringComparer]::OrdinalIgnoreCase.Equals($leftPath, $rightPath)
}

function Test-CapsulenvPathNested {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Child
    )

    $parentPath = [System.IO.Path]::GetFullPath($Parent).TrimEnd([char[]]'\/')
    $childPath = [System.IO.Path]::GetFullPath($Child).TrimEnd([char[]]'\/')
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($parentPath, $childPath)) {
        return $false
    }
    $prefix = $parentPath + [System.IO.Path]::DirectorySeparatorChar
    return $childPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-CapsulenvToolStoragePlan {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    $variables = [ordered]@{}
    $locations = [ordered]@{}
    $locationKinds = [ordered]@{}
    $locationClasses = [ordered]@{}
    $pathEntries = New-Object System.Collections.Generic.List[string]
    $directories = New-Object System.Collections.Generic.List[string]
    $files = New-Object System.Collections.Generic.List[string]

    if (-not $configuration.ToolStorage.Enabled) {
        return [pscustomobject]@{
            Enabled = $false
            Variables = $variables
            Locations = $locations
            LocationKinds = $locationKinds
            LocationClasses = $locationClasses
            PathEntries = @()
            Directories = @()
            Files = @()
        }
    }

    foreach ($name in @($configuration.ToolStorage.PathVariables.Keys | Sort-Object)) {
        $relative = [string]$configuration.ToolStorage.PathVariables[$name]
        $resolved = Resolve-CapsulenvPath -Path $relative -AllowMissing
        $variables[$name] = $resolved
        $locations[$name] = $resolved
        $locationKinds[$name] = 'Directory'
        $locationClasses[$name] = if ($relative -match '^(?i:cache)[\\/]') { 'Cache' } else { 'Data' }
        if (-not ($directories -contains $resolved)) {
            $directories.Add($resolved)
        }
    }

    foreach ($name in @($configuration.ToolStorage.FileVariables.Keys | Sort-Object)) {
        $resolved = Resolve-CapsulenvPath `
            -Path ([string]$configuration.ToolStorage.FileVariables[$name]) `
            -AllowMissing
        $variables[$name] = $resolved
        $locations[$name] = $resolved
        $locationKinds[$name] = 'File'
        $locationClasses[$name] = 'Config'
        $parent = Split-Path -Parent $resolved
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not ($directories -contains $parent)) {
            $directories.Add($parent)
        }
        if (-not ($files -contains $resolved)) {
            $files.Add($resolved)
        }
    }

    foreach ($name in @($configuration.ToolStorage.Variables.Keys | Sort-Object)) {
        $variables[$name] = [Environment]::ExpandEnvironmentVariables(
            [string]$configuration.ToolStorage.Variables[$name]
        )
    }

    $pathIndex = 0
    foreach ($entry in $configuration.ToolStorage.Path) {
        $resolved = Resolve-CapsulenvPath -Path ([string]$entry) -AllowMissing
        if (-not ($pathEntries -contains $resolved)) {
            $pathEntries.Add($resolved)
        }
        if (-not ($directories -contains $resolved)) {
            $directories.Add($resolved)
        }
        $locationName = 'PATH_{0}' -f $pathIndex
        $locations[$locationName] = $resolved
        $locationKinds[$locationName] = 'Directory'
        $locationClasses[$locationName] = 'Bin'
        $pathIndex++
    }

    # Scoop owns this cache and chooses its layout. Listing the location here
    # makes the complete capsule storage plan visible, but capsulenv never
    # creates or clears it behind Scoop's back.
    $scoopRoot = Resolve-CapsulenvPath -Path ([string]$configuration.Scoop.Root) -AllowMissing
    $scoopCache = Join-Path $scoopRoot 'cache'
    $locations['SCOOP_CACHE'] = $scoopCache
    $locationKinds['SCOOP_CACHE'] = 'Directory'
    $locationClasses['SCOOP_CACHE'] = 'Cache'

    return [pscustomobject]@{
        Enabled = $true
        Variables = $variables
        Locations = $locations
        LocationKinds = $locationKinds
        LocationClasses = $locationClasses
        PathEntries = $pathEntries.ToArray()
        Directories = $directories.ToArray()
        Files = $files.ToArray()
    }
}

function Initialize-CapsulenvToolStorage {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    $plan = Get-CapsulenvToolStoragePlan
    if (-not $plan.Enabled) {
        return $plan
    }

    if (-not $configuration.ToolStorage.CreateDirectories) {
        return $plan
    }

    foreach ($directory in $plan.Directories) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $directory -Force)
        }
    }
    foreach ($file in $plan.Files) {
        if (Test-Path -LiteralPath $file -PathType Container) {
            throw "ToolStorage file path is occupied by a directory: $file"
        }
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            [System.IO.File]::WriteAllText($file, '')
        }
    }
    return $plan
}

function Get-CapsulenvProjectIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    $context = Get-CapsulenvContext
    $fullPath = [System.IO.Path]::GetFullPath($ProjectPath).TrimEnd([char[]]'\/')
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw "Project directory does not exist: $fullPath"
    }

    $root = $context.Root.TrimEnd([char[]]'\/')
    $rootPrefix = $root + [System.IO.Path]::DirectorySeparatorChar
    $identitySource = if ([System.StringComparer]::OrdinalIgnoreCase.Equals($fullPath, $root)) {
        'capsule:.'
    } elseif ($fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        'capsule:' + $fullPath.Substring($rootPrefix.Length).Replace('\', '/').ToLowerInvariant()
    } else {
        'absolute:' + $fullPath.Replace('\', '/').ToLowerInvariant()
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($identitySource)
        $hash = $sha256.ComputeHash($bytes)
    } finally {
        $sha256.Dispose()
    }
    $hashText = ([System.BitConverter]::ToString($hash)).Replace('-', '').Substring(0, 16).ToLowerInvariant()
    $leaf = Split-Path -Leaf $fullPath
    if ([string]::IsNullOrWhiteSpace($leaf)) {
        $leaf = 'project'
    }
    $safeLeaf = [regex]::Replace($leaf.ToLowerInvariant(), '[^a-z0-9._-]+', '-')
    $safeLeaf = $safeLeaf.Trim('-', '.')
    if ([string]::IsNullOrWhiteSpace($safeLeaf)) {
        $safeLeaf = 'project'
    }

    return [pscustomobject]@{
        FullPath = $fullPath
        Name = $leaf
        SafeName = $safeLeaf
        Id = "$safeLeaf-$hashText"
        Source = $identitySource
    }
}

function Get-CapsulenvProjectLinkDefinition {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Profile)

    $definitions = (Get-CapsulenvConfiguration).ToolStorage.ProjectLinks
    if (-not $definitions.ContainsKey($Profile)) {
        throw "Unknown project cache profile: $Profile"
    }
    return $definitions[$Profile]
}

function Resolve-CapsulenvProjectLinkPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Profile,
        [string]$ProjectPath = '.',
        [string]$LinkType
    )

    $configuration = Get-CapsulenvConfiguration
    if (-not $configuration.ToolStorage.Enabled) {
        throw 'Portable tool storage is disabled.'
    }
    $definition = Get-CapsulenvProjectLinkDefinition -Profile $Profile
    $identity = Get-CapsulenvProjectIdentity -ProjectPath $ProjectPath
    $projectRelative = [string]$definition.ProjectPath
    if ([System.IO.Path]::IsPathRooted($projectRelative)) {
        throw "ToolStorage.ProjectLinks.$Profile.ProjectPath must be relative."
    }
    $storeTemplate = [string]$definition.StorePath
    $storeRelative = $storeTemplate.Replace('{ProjectId}', $identity.Id).Replace('{ProjectName}', $identity.SafeName)
    if ([System.IO.Path]::IsPathRooted($storeRelative)) {
        throw "ToolStorage.ProjectLinks.$Profile.StorePath must be relative."
    }

    $kind = [string]$definition.Kind
    $selectedLinkType = if ([string]::IsNullOrWhiteSpace($LinkType)) { [string]$definition.LinkType } else { $LinkType }
    if ($selectedLinkType -notin @('Junction', 'SymbolicLink', 'HardLink')) {
        throw "Unsupported project cache link type: $selectedLinkType"
    }
    if ($kind -eq 'Directory' -and $selectedLinkType -eq 'HardLink') {
        throw 'Windows does not support directory hard links. Use Junction or SymbolicLink.'
    }
    if ($kind -eq 'File' -and $selectedLinkType -eq 'Junction') {
        throw 'Junctions can target directories only. Use SymbolicLink or HardLink for a file profile.'
    }

    $linkPath = [System.IO.Path]::GetFullPath((Join-Path $identity.FullPath $projectRelative))
    $storePath = Resolve-CapsulenvPath -Path $storeRelative -AllowMissing
    if (
        (Test-CapsulenvSamePath -Left $linkPath -Right $storePath) -or
        (Test-CapsulenvPathNested -Parent $linkPath -Child $storePath) -or
        (Test-CapsulenvPathNested -Parent $storePath -Child $linkPath)
    ) {
        throw "Project cache link and capsule store must not overlap: $linkPath <-> $storePath"
    }

    return [pscustomobject]@{
        Profile = $Profile
        Kind = $kind
        LinkType = $selectedLinkType
        ProjectRoot = $identity.FullPath
        ProjectId = $identity.Id
        LinkPath = $linkPath
        StorePath = $storePath
    }
}

function Get-CapsulenvReparseTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    # Get-Item can inspect a broken junction/symlink even when Test-Path is
    # false because its target disappeared after the capsule was moved.
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $null
    }
    if (-not (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        return $null
    }
    $targetValue = $item.PSObject.Properties['Target']
    if ($null -eq $targetValue) {
        return $null
    }
    $target = @($targetValue.Value) | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace([string]$target)) {
        return $null
    }
    if (-not [System.IO.Path]::IsPathRooted([string]$target)) {
        $target = Join-Path (Split-Path -Parent $Path) ([string]$target)
    }
    return [System.IO.Path]::GetFullPath([string]$target)
}

function Initialize-CapsulenvFileIdentityType {
    [CmdletBinding()]
    param()

    if ('Capsulenv.NativeFileIdentity' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Capsulenv {
    [StructLayout(LayoutKind.Sequential)]
    internal struct ByHandleFileInformation {
        internal uint FileAttributes;
        internal System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        internal System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        internal System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        internal uint VolumeSerialNumber;
        internal uint FileSizeHigh;
        internal uint FileSizeLow;
        internal uint NumberOfLinks;
        internal uint FileIndexHigh;
        internal uint FileIndexLow;
    }

    public static class NativeFileIdentity {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            FileShare shareMode,
            IntPtr securityAttributes,
            FileMode creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out ByHandleFileInformation information);

        public static string Get(string path) {
            using (SafeFileHandle handle = CreateFile(
                path,
                0,
                FileShare.ReadWrite | FileShare.Delete,
                IntPtr.Zero,
                FileMode.Open,
                0,
                IntPtr.Zero)) {
                if (handle.IsInvalid) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), path);
                }
                ByHandleFileInformation information;
                if (!GetFileInformationByHandle(handle, out information)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), path);
                }
                return string.Format(
                    "{0:x8}:{1:x8}{2:x8}",
                    information.VolumeSerialNumber,
                    information.FileIndexHigh,
                    information.FileIndexLow);
            }
        }
    }
}
'@
}

function Get-CapsulenvFileIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'File hard-link identity checks are supported on Windows only.'
    }
    Initialize-CapsulenvFileIdentityType
    return [Capsulenv.NativeFileIdentity]::Get([System.IO.Path]::GetFullPath($Path))
}

function Test-CapsulenvHardLinkMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $leftIdentity = Get-CapsulenvFileIdentity -Path $Left
    $rightIdentity = Get-CapsulenvFileIdentity -Path $Right
    return $null -ne $leftIdentity -and $leftIdentity -eq $rightIdentity
}

function Test-CapsulenvPathEmpty {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $true
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) {
        return $item.Length -eq 0
    }
    return $null -eq (Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 1)
}

function Assert-CapsulenvProjectCachePathKind {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Directory', 'File')][string]$Kind
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $item = Get-Item -LiteralPath $Path -Force
    $actualKind = if ($item.PSIsContainer) { 'Directory' } else { 'File' }
    if ($actualKind -ne $Kind) {
        throw "Project cache path has the wrong kind: $Path (expected $Kind; found $actualKind)"
    }
}

function Get-CapsulenvProjectLinkInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan)

    # Detect reparse points before file identity. Opening a file symlink follows
    # its target, which would otherwise make a symbolic link look like a hard
    # link because both paths expose the same underlying file identity.
    $target = Get-CapsulenvReparseTarget -Path $Plan.LinkPath
    if ($null -ne $target -and (Test-CapsulenvSamePath -Left $target -Right $Plan.StorePath)) {
        $item = Get-Item -LiteralPath $Plan.LinkPath -Force
        $linkTypeProperty = $item.PSObject.Properties['LinkType']
        $actualLinkType = if ($null -ne $linkTypeProperty -and -not [string]::IsNullOrWhiteSpace([string]$linkTypeProperty.Value)) {
            [string]$linkTypeProperty.Value
        } else {
            $Plan.LinkType
        }
        return [pscustomobject]@{
            Linked = $true
            LinkType = $actualLinkType
            Target = $target
        }
    }

    if (
        $Plan.Kind -eq 'File' -and
        (Test-CapsulenvWindows) -and
        (Test-Path -LiteralPath $Plan.LinkPath -PathType Leaf) -and
        (Test-Path -LiteralPath $Plan.StorePath -PathType Leaf)
    ) {
        if (Test-CapsulenvHardLinkMatch -Left $Plan.LinkPath -Right $Plan.StorePath) {
            return [pscustomobject]@{
                Linked = $true
                LinkType = 'HardLink'
                Target = $Plan.StorePath
            }
        }
    }

    return [pscustomobject]@{
        Linked = $false
        LinkType = $null
        Target = $target
    }
}

function New-CapsulenvProjectCacheLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Profile,
        [string]$ProjectPath = '.',
        [switch]$MoveExisting,
        [ValidateSet('Junction', 'SymbolicLink', 'HardLink')][string]$LinkType
    )

    $plan = Resolve-CapsulenvProjectLinkPlan -Profile $Profile -ProjectPath $ProjectPath -LinkType $LinkType
    $currentLink = Get-CapsulenvProjectLinkInfo -Plan $plan
    if ($currentLink.Linked) {
        Register-CapsulenvProjectCacheLink -Plan $plan -ActualLinkType $currentLink.LinkType
        return $plan | Select-Object *, @{ Name = 'ActualLinkType'; Expression = { $currentLink.LinkType } }, @{ Name = 'Changed'; Expression = { $false } }
    }

    $existingTarget = Get-CapsulenvReparseTarget -Path $plan.LinkPath
    if ($existingTarget) {
        throw "Project path is already a link to another target: $($plan.LinkPath) -> $existingTarget"
    }

    $linkExists = Test-Path -LiteralPath $plan.LinkPath
    $storeExists = Test-Path -LiteralPath $plan.StorePath
    if ($linkExists) {
        Assert-CapsulenvProjectCachePathKind -Path $plan.LinkPath -Kind $plan.Kind
    }
    if ($storeExists) {
        Assert-CapsulenvProjectCachePathKind -Path $plan.StorePath -Kind $plan.Kind
    }
    $linkWasEmpty = $linkExists -and (Test-CapsulenvPathEmpty -Path $plan.LinkPath)
    $storeWasEmpty = $storeExists -and (Test-CapsulenvPathEmpty -Path $plan.StorePath)
    if ($linkExists -and -not $linkWasEmpty -and -not $MoveExisting) {
        throw "Project cache path is not empty. Re-run with --move: $($plan.LinkPath)"
    }
    if ($linkExists -and -not $linkWasEmpty -and $storeExists -and -not $storeWasEmpty) {
        throw 'Both project and capsule cache paths contain data; refusing to merge them automatically.'
    }

    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $plan.StorePath) -Force)
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $plan.LinkPath) -Force)
    $moved = $false
    $storeCreated = -not $storeExists
    try {
        if ($linkExists -and -not $linkWasEmpty) {
            if ($storeExists) {
                Remove-Item -LiteralPath $plan.StorePath -Force -Recurse
            }
            Move-Item -LiteralPath $plan.LinkPath -Destination $plan.StorePath
            $moved = $true
        } else {
            if ($linkExists) {
                Remove-Item -LiteralPath $plan.LinkPath -Force -Recurse
            }
            if (-not $storeExists) {
                if ($plan.Kind -eq 'Directory') {
                    [void](New-Item -ItemType Directory -Path $plan.StorePath -Force)
                } else {
                    [void](New-Item -ItemType File -Path $plan.StorePath -Force)
                }
            }
        }

        [void](New-Item -ItemType $plan.LinkType -Path $plan.LinkPath -Target $plan.StorePath -Force)
        $createdLink = Get-CapsulenvProjectLinkInfo -Plan $plan
        if (-not $createdLink.Linked) {
            throw 'The created project cache link could not be verified.'
        }
        Register-CapsulenvProjectCacheLink -Plan $plan -ActualLinkType $createdLink.LinkType
    } catch {
        if (Test-Path -LiteralPath $plan.LinkPath) {
            Remove-Item -LiteralPath $plan.LinkPath -Force -Recurse -ErrorAction SilentlyContinue
        }
        if ($moved -and (Test-Path -LiteralPath $plan.StorePath) -and -not (Test-Path -LiteralPath $plan.LinkPath)) {
            Move-Item -LiteralPath $plan.StorePath -Destination $plan.LinkPath -ErrorAction SilentlyContinue
            if ($storeExists -and $storeWasEmpty -and -not (Test-Path -LiteralPath $plan.StorePath)) {
                [void](New-Item -ItemType $plan.Kind -Path $plan.StorePath -Force -ErrorAction SilentlyContinue)
            }
        } elseif ($linkExists -and $linkWasEmpty -and -not (Test-Path -LiteralPath $plan.LinkPath)) {
            [void](New-Item -ItemType $plan.Kind -Path $plan.LinkPath -Force -ErrorAction SilentlyContinue)
        }
        if (
            $storeCreated -and
            (Test-Path -LiteralPath $plan.StorePath) -and
            (Test-CapsulenvPathEmpty -Path $plan.StorePath)
        ) {
            Remove-Item -LiteralPath $plan.StorePath -Force -Recurse -ErrorAction SilentlyContinue
        }
        throw
    }

    return $plan | Select-Object *, @{ Name = 'ActualLinkType'; Expression = { $createdLink.LinkType } }, @{ Name = 'Changed'; Expression = { $true } }
}

function Remove-CapsulenvProjectCacheLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Profile,
        [string]$ProjectPath = '.',
        [switch]$Restore
    )

    $plan = Resolve-CapsulenvProjectLinkPlan -Profile $Profile -ProjectPath $ProjectPath
    $currentLink = Get-CapsulenvProjectLinkInfo -Plan $plan
    if (-not $currentLink.Linked) {
        throw "Project path is not the configured managed link: $($plan.LinkPath)"
    }

    # Remove the registry entry before mutating the link. If registry writing
    # fails, the managed link remains untouched and cannot be recreated later
    # against the user's intent by an automatic repair pass.
    Unregister-CapsulenvProjectCacheLink -Plan $plan
    try {
        Remove-Item -LiteralPath $plan.LinkPath -Force
        if ($Restore -and (Test-Path -LiteralPath $plan.StorePath)) {
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $plan.LinkPath) -Force)
            Move-Item -LiteralPath $plan.StorePath -Destination $plan.LinkPath
        }
    } catch {
        $unlinkError = $_
        try {
            $remainingTarget = Get-CapsulenvReparseTarget -Path $plan.LinkPath
            if ($null -eq $remainingTarget -and (Test-Path -LiteralPath $plan.LinkPath)) {
                if ($Restore -and -not (Test-Path -LiteralPath $plan.StorePath)) {
                    Move-Item -LiteralPath $plan.LinkPath -Destination $plan.StorePath
                } else {
                    throw "Rollback found a normal path at the managed link location: $($plan.LinkPath)"
                }
            }
            if (
                -not (Test-Path -LiteralPath $plan.LinkPath) -and
                (Test-Path -LiteralPath $plan.StorePath)
            ) {
                [void](New-Item `
                    -ItemType $currentLink.LinkType `
                    -Path $plan.LinkPath `
                    -Target $plan.StorePath `
                    -Force)
            }
            $restoredLink = Get-CapsulenvProjectLinkInfo -Plan $plan
            if (-not $restoredLink.Linked) {
                throw "Rollback could not verify the restored managed link: $($plan.LinkPath)"
            }
            Register-CapsulenvProjectCacheLink -Plan $plan -ActualLinkType $restoredLink.LinkType
        } catch {
            throw "Project-cache unlink failed: $($unlinkError.Exception.Message) Restoring its managed registry/link state also failed: $($_.Exception.Message)"
        }
        throw $unlinkError
    }
    return $plan | Select-Object *, @{ Name = 'Restored'; Expression = { [bool]$Restore } }
}

function Get-CapsulenvProjectCacheStatus {
    [CmdletBinding()]
    param([string]$ProjectPath = '.')

    $configuration = Get-CapsulenvConfiguration
    foreach ($profile in @($configuration.ToolStorage.ProjectLinks.Keys | Sort-Object)) {
        $plan = Resolve-CapsulenvProjectLinkPlan -Profile ([string]$profile) -ProjectPath $ProjectPath
        $linkInfo = Get-CapsulenvProjectLinkInfo -Plan $plan
        [pscustomobject]@{
            Profile = $plan.Profile
            Kind = $plan.Kind
            ConfiguredLinkType = $plan.LinkType
            ActualLinkType = $linkInfo.LinkType
            ProjectId = $plan.ProjectId
            LinkPath = $plan.LinkPath
            StorePath = $plan.StorePath
            Linked = $linkInfo.Linked
            ActualTarget = $linkInfo.Target
            StoreExists = Test-Path -LiteralPath $plan.StorePath
        }
    }
}

function Get-CapsulenvToolStorageStatus {
    [CmdletBinding()]
    param()

    $plan = Get-CapsulenvToolStoragePlan
    foreach ($name in $plan.Locations.Keys) {
        $value = [string]$plan.Locations[$name]
        $kind = [string]$plan.LocationKinds[$name]
        [pscustomobject]@{
            Name = $name
            Kind = $kind
            Class = [string]$plan.LocationClasses[$name]
            Value = $value
            Exists = if ($kind -eq 'File') {
                Test-Path -LiteralPath $value -PathType Leaf
            } else {
                Test-Path -LiteralPath $value -PathType Container
            }
        }
    }
    foreach ($name in $plan.Variables.Keys) {
        if ($plan.Locations.Contains($name)) {
            continue
        }
        [pscustomobject]@{
            Name = $name
            Kind = 'Value'
            Class = 'Setting'
            Value = [string]$plan.Variables[$name]
            Exists = $null
        }
    }
}

##MOD_EXEC## Export-ModuleMember -Function Initialize-CapsulenvToolStorage, New-CapsulenvProjectCacheLink, Remove-CapsulenvProjectCacheLink, Get-CapsulenvToolStorageStatus, Get-CapsulenvProjectCacheStatus
