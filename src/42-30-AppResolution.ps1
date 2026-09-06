function Get-CapsulenvScoopAppBins {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$App)

    $installed = Get-CapsulenvInstalledApp -Selector $App
    $results = New-Object System.Collections.Generic.List[object]
    $entrySet = Get-CapsulenvInstalledBinEntries -App $installed
    foreach ($entry in @($entrySet.Entries)) {
        $results.Add((ConvertTo-CapsulenvInstalledBin -App $installed -Entry $entry))
    }
    return $results.ToArray()
}

function Resolve-CapsulenvScoopAppRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [AllowEmptyString()][string]$RelativePath = ''
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        return [System.IO.Path]::GetFullPath($Root)
    }
    if (
        [System.IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath -match '(^|[\\/])\.\.([\\/]|$)'
    ) {
        throw "App integration paths must remain relative to their owning app: $RelativePath"
    }
    # Scoop manifests/configuration use Windows separators. Normalize both
    # forms so the same resolver can also be tested on non-Windows hosts.
    $separator = [string][System.IO.Path]::DirectorySeparatorChar
    $hostRelativePath = $RelativePath.Replace('\', $separator).Replace('/', $separator)
    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]'\\/')
    $resolved = [System.IO.Path]::GetFullPath((Join-Path $rootPath $hostRelativePath))
    if (
        -not [System.StringComparer]::OrdinalIgnoreCase.Equals($resolved.TrimEnd([char[]]'\\/'), $rootPath) -and
        -not $resolved.StartsWith(
            $rootPath + [System.IO.Path]::DirectorySeparatorChar,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "App integration path escapes its owning app: $RelativePath"
    }
    return $resolved
}

function Resolve-CapsulenvScoopAppExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [string]$RelativePath,
        [string]$BinName,
        [string]$ShortcutName
    )

    $installed = Get-CapsulenvInstalledApp -Selector $App
    if (-not [string]::IsNullOrWhiteSpace($RelativePath)) {
        $target = Resolve-CapsulenvScoopAppRelativePath -Root $installed.Current -RelativePath $RelativePath
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            throw "Configured executable is missing for '$($installed.Selector)': $target"
        }
        return $target
    }

    if (-not [string]::IsNullOrWhiteSpace($BinName)) {
        $matches = @(
            Get-CapsulenvScoopAppBins -App $installed.Selector |
                Where-Object {
                    [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$_.Name, $BinName) -or
                    [System.StringComparer]::OrdinalIgnoreCase.Equals([System.IO.Path]::GetFileName([string]$_.Target), $BinName)
                }
        )
        if ($matches.Count -ne 1) {
            throw "Installed app '$($installed.Selector)' does not expose exactly one bin named '$BinName'."
        }
        if (-not (Test-Path -LiteralPath $matches[0].Target -PathType Leaf)) {
            throw "Configured bin target is missing: $($matches[0].Target)"
        }
        return [string]$matches[0].Target
    }

    if (-not [string]::IsNullOrWhiteSpace($ShortcutName)) {
        $matches = @(Get-CapsulenvScoopAppShortcuts -App $installed.Selector | Where-Object { [string]$_.Name -eq $ShortcutName })
        if ($matches.Count -ne 1) {
            throw "Installed app '$($installed.Selector)' does not expose exactly one shortcut named '$ShortcutName'."
        }
        if (-not (Test-Path -LiteralPath $matches[0].Target -PathType Leaf)) {
            throw "Configured shortcut target is missing: $($matches[0].Target)"
        }
        return [string]$matches[0].Target
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @(Get-CapsulenvScoopAppBins -App $installed.Selector)) {
        if (Test-Path -LiteralPath $entry.Target -PathType Leaf) {
            $candidates.Add([string]$entry.Target)
        }
    }
    foreach ($entry in @(Get-CapsulenvScoopAppShortcuts -App $installed.Selector)) {
        if (Test-Path -LiteralPath $entry.Target -PathType Leaf) {
            $candidates.Add([string]$entry.Target)
        }
    }
    $unique = @($candidates.ToArray() | Sort-Object -Unique)
    if ($unique.Count -eq 1) {
        return [string]$unique[0]
    }
    if ($unique.Count -eq 0) {
        throw "Installed app '$($installed.Selector)' has no resolvable bin or shortcut executable. Configure RelativePath, BinName, or ShortcutName."
    }
    throw "Installed app '$($installed.Selector)' exposes multiple executable targets. Configure RelativePath, BinName, or ShortcutName."
}

function Resolve-CapsulenvScoopAppPersistPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [AllowEmptyString()][string]$RelativePath = '',
        [switch]$AllowMissing
    )

    $installed = Get-CapsulenvInstalledApp -Selector $App
    $target = Resolve-CapsulenvScoopAppRelativePath -Root $installed.Persist -RelativePath $RelativePath
    if (-not $AllowMissing -and -not (Test-Path -LiteralPath $target)) {
        throw "Configured persisted path is missing for '$($installed.Selector)': $target"
    }
    return $target
}

function Resolve-CapsulenvScoopAppRuntimePersistPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [AllowEmptyString()][string]$RelativePath = '',
        [switch]$AllowMissing
    )

    $installed = Get-CapsulenvInstalledApp -Selector $App
    $persistedTarget = Resolve-CapsulenvScoopAppRelativePath -Root $installed.Persist -RelativePath $RelativePath
    if (-not $AllowMissing -and -not (Test-Path -LiteralPath $persistedTarget)) {
        throw "Configured persisted path is missing for '$($installed.Selector)': $persistedTarget"
    }

    # Runtime consumers should address a persisted item through the source path
    # inside app/current when the installed manifest owns such a persist link.
    # The provider creates that source as the projection that points at its
    # persist store. Using the app-visible path keeps command lines identical to
    # those emitted by the app's own launcher while the underlying data remains
    # owned by the selected package provider.
    $persistRecord = Get-CapsulenvInstalledManifestPropertyRecord -App $installed -Name 'persist'
    $persistValue = $persistRecord.Value
    if ($null -eq $persistValue) {
        return $persistedTarget
    }

    $requested = ([string]$RelativePath).Replace('/', '\').Trim([char[]]'\')
    $mappings = New-Object System.Collections.Generic.List[object]
    $definitions = New-Object System.Collections.Generic.List[object]
    if ($persistValue -is [string]) {
        $definitions.Add([string]$persistValue)
    } else {
        foreach ($persistDefinition in $persistValue) {
            $definitions.Add([object]$persistDefinition)
        }
    }
    foreach ($definition in $definitions.ToArray()) {
        if ($definition -is [string]) {
            $source = [string]$definition
            $target = [string]$definition
        } else {
            $parts = @($definition)
            if ($parts.Count -lt 1 -or [string]::IsNullOrWhiteSpace([string]$parts[0])) {
                continue
            }
            $source = [string]$parts[0]
            $target = if ($parts.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace([string]$parts[1])) {
                [string]$parts[1]
            } else {
                [string]$parts[0]
            }
        }
        $sourceNormalized = $source.Replace('/', '\').Trim([char[]]'\')
        $targetNormalized = $target.Replace('/', '\').Trim([char[]]'\')
        if ([string]::IsNullOrWhiteSpace($sourceNormalized) -or [string]::IsNullOrWhiteSpace($targetNormalized)) {
            continue
        }
        $mappings.Add([pscustomobject]@{
            Source = $sourceNormalized
            Target = $targetNormalized
        })
    }

    foreach ($mapping in @($mappings.ToArray() | Sort-Object { ([string]$_.Target).Length } -Descending)) {
        $targetPrefix = [string]$mapping.Target
        $matchesTarget = (
            [System.StringComparer]::OrdinalIgnoreCase.Equals($requested, $targetPrefix) -or
            $requested.StartsWith($targetPrefix + '\', [System.StringComparison]::OrdinalIgnoreCase)
        )
        if (-not $matchesTarget) {
            continue
        }
        $remainder = if ($requested.Length -gt $targetPrefix.Length) {
            $requested.Substring($targetPrefix.Length).TrimStart([char[]]'\')
        } else {
            ''
        }
        $runtimeRelative = if ([string]::IsNullOrWhiteSpace($remainder)) {
            [string]$mapping.Source
        } else {
            ([string]$mapping.Source).TrimEnd([char[]]'\') + '\' + $remainder
        }
        $runtime = Resolve-CapsulenvScoopAppRelativePath -Root $installed.Current -RelativePath $runtimeRelative
        if ($AllowMissing -or (Test-Path -LiteralPath $runtime)) {
            return $runtime
        }
        throw "Configured persisted runtime path is missing for '$($installed.Selector)': $runtime"
    }

    return $persistedTarget
}

function Test-CapsulenvScoopAppOwnsPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $installed = Get-CapsulenvInstalledApp -Selector $App
    try {
        $root = [System.IO.Path]::GetFullPath([string]$installed.AppRoot).TrimEnd([char[]]'\\/')
        $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\\/')
    } catch {
        return $false
    }
    return (
        [System.StringComparer]::OrdinalIgnoreCase.Equals($fullPath, $root) -or
        $fullPath.StartsWith(
            $root + [System.IO.Path]::DirectorySeparatorChar,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    )
}

