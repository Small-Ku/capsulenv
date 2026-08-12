function Get-CapsulenvSavedRehydrationState {
    [CmdletBinding()]
    param()

    $statePath = Get-CapsulenvRehydrationStatePath
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    } catch {
        Write-CapsulenvMessage -Level Warning -Message "Ignoring invalid relocation state: $statePath"
        return $null
    }
}

function Get-CapsulenvScoopRootFromShimMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ScoopRoot)

    $shimsRoot = Join-Path $ScoopRoot 'shims'
    if (-not (Test-Path -LiteralPath $shimsRoot -PathType Container)) {
        return $null
    }

    $counts = @{}
    $files = @(
        Get-ChildItem -LiteralPath $shimsRoot -Filter '*.shim' -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer -and $_.Length -le 65536 } |
            Sort-Object -Property FullName |
            Select-Object -First 256
    )
    foreach ($file in $files) {
        try {
            $text = [System.IO.File]::ReadAllText($file.FullName)
        } catch {
            continue
        }
        $match = [System.Text.RegularExpressions.Regex]::Match(
            $text,
            '(?im)^\s*path\s*=\s*"?(?<path>[^"\r\n]+)"?\s*$'
        )
        if (-not $match.Success) {
            continue
        }
        $target = $match.Groups['path'].Value.Trim()
        $appsMatch = [System.Text.RegularExpressions.Regex]::Match(
            $target,
            '(?i)[\\/]+apps[\\/]+'
        )
        if (-not $appsMatch.Success -or $appsMatch.Index -le 0) {
            continue
        }
        $candidate = $target.Substring(0, $appsMatch.Index).TrimEnd('\', '/')
        if (
            [string]::IsNullOrWhiteSpace($candidate) -or
            -not [System.IO.Path]::IsPathRooted($candidate)
        ) {
            continue
        }
        if (-not $counts.ContainsKey($candidate)) {
            $counts[$candidate] = 0
        }
        $counts[$candidate] = [int]$counts[$candidate] + 1
    }

    if ($counts.Count -eq 0) {
        return $null
    }
    return [string](
        $counts.GetEnumerator() |
            Sort-Object -Property `
                @{ Expression = { $_.Value }; Descending = $true }, `
                @{ Expression = { $_.Key.Length }; Descending = $true }, `
                @{ Expression = { $_.Key }; Descending = $false } |
            Select-Object -First 1 -ExpandProperty Key
    )
}

function Get-CapsulenvRootFromRelocatedScoopRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OldScoopRoot,
        [Parameter(Mandatory = $true)][string]$CurrentScoopRoot
    )

    $context = Get-CapsulenvContext
    $currentRoot = [System.IO.Path]::GetFullPath($context.Root).TrimEnd('\', '/')
    $currentScoop = [System.IO.Path]::GetFullPath($CurrentScoopRoot).TrimEnd('\', '/')
    $prefix = $currentRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $currentScoop.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    $relative = $currentScoop.Substring($prefix.Length).Replace('/', '\').Trim('\')
    $oldNormalized = $OldScoopRoot.Replace('/', '\').TrimEnd('\')
    $suffix = '\' + $relative
    if (-not $oldNormalized.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    return $oldNormalized.Substring(0, $oldNormalized.Length - $suffix.Length)
}

function Get-CapsulenvPreviousRelocationFingerprint {
    [CmdletBinding()]
    param()

    $saved = Get-CapsulenvSavedRehydrationState
    $previous = [ordered]@{}
    $sourceParts = New-Object System.Collections.Generic.List[string]
    if ($null -ne $saved) {
        $savedCapsuleProperty = $saved.PSObject.Properties['CapsuleId']
        if (
            $null -ne $savedCapsuleProperty -and
            -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$savedCapsuleProperty.Value, [string](Get-CapsulenvIdentity))
        ) {
            Write-CapsulenvMessage -Level Warning -Message 'Ignoring relocation state from a different capsule identity; stale Scoop shim metadata may still be used.'
            $saved = $null
        }
    }
    if ($null -ne $saved) {
        foreach ($name in @('CapsuleId', 'Root', 'ScoopRoot', 'ScoopGlobalRoot', 'ComputerName', 'User')) {
            $property = $saved.PSObject.Properties[$name]
            if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                $previous[$name] = [string]$property.Value
            }
        }
        $lastRelocationProperty = $saved.PSObject.Properties['LastRelocation']
        if ($null -ne $lastRelocationProperty) {
            $previous['LastRelocation'] = $lastRelocationProperty.Value
        }
        $sourceParts.Add('state')
    }

    $current = Get-CapsulenvRelocationFingerprint
    $inferredScoop = Get-CapsulenvScoopRootFromShimMetadata -ScoopRoot ([string]$current.ScoopRoot)
    if (-not $previous.Contains('ScoopRoot') -and -not [string]::IsNullOrWhiteSpace($inferredScoop)) {
        $previous['ScoopRoot'] = $inferredScoop
        $sourceParts.Add('local-shims')
    }
    $inferredGlobal = Get-CapsulenvScoopRootFromShimMetadata -ScoopRoot ([string]$current.ScoopGlobalRoot)
    if (-not $previous.Contains('ScoopGlobalRoot') -and -not [string]::IsNullOrWhiteSpace($inferredGlobal)) {
        $previous['ScoopGlobalRoot'] = $inferredGlobal
        $sourceParts.Add('global-shims')
    }
    if (-not $previous.Contains('Root') -and $previous.Contains('ScoopRoot')) {
        $inferredRoot = Get-CapsulenvRootFromRelocatedScoopRoot `
            -OldScoopRoot ([string]$previous.ScoopRoot) `
            -CurrentScoopRoot ([string]$current.ScoopRoot)
        if (-not [string]::IsNullOrWhiteSpace($inferredRoot)) {
            $previous['Root'] = $inferredRoot
        }
    }

    if ($previous.Count -eq 0) {
        return $null
    }
    $previous['Source'] = if ($sourceParts.Count -gt 0) { @($sourceParts | Sort-Object -Unique) -join '+' } else { 'unknown' }
    return $previous
}

function New-CapsulenvRelocationContext {
    [CmdletBinding()]
    param(
        $Previous,
        [Parameter(Mandatory = $true)]$Current
    )

    $mappings = New-Object System.Collections.Generic.List[object]
    foreach ($name in @('Root', 'ScoopRoot', 'ScoopGlobalRoot')) {
        $oldValue = $null
        if ($null -ne $Previous) {
            if ($Previous -is [System.Collections.IDictionary]) {
                if ($Previous.Contains($name)) {
                    $oldValue = [string]$Previous[$name]
                }
            } else {
                $property = $Previous.PSObject.Properties[$name]
                if ($null -ne $property) {
                    $oldValue = [string]$property.Value
                }
            }
        }

        $newValue = $null
        if ($Current -is [System.Collections.IDictionary]) {
            if ($Current.Contains($name)) {
                $newValue = [string]$Current[$name]
            }
        } else {
            $property = $Current.PSObject.Properties[$name]
            if ($null -ne $property) {
                $newValue = [string]$property.Value
            }
        }

        if (
            -not [string]::IsNullOrWhiteSpace($oldValue) -and
            -not [string]::IsNullOrWhiteSpace($newValue) -and
            -not $oldValue.Equals($newValue, [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            $mappings.Add([pscustomobject]@{
                Name = $name
                OldPath = [System.IO.Path]::GetFullPath($oldValue).TrimEnd('\', '/')
                NewPath = [System.IO.Path]::GetFullPath($newValue).TrimEnd('\', '/')
            })
        }
    }

    return [pscustomobject]@{
        Previous = $Previous
        Current = $Current
        HasPreviousState = ($null -ne $Previous)
        PreviousSource = $(
            if ($null -eq $Previous) {
                'none'
            } elseif ($Previous -is [System.Collections.IDictionary] -and $Previous.Contains('Source')) {
                [string]$Previous['Source']
            } else {
                'recorded'
            }
        )
        HasPathChanges = ($mappings.Count -gt 0)
        PathMappings = @($mappings | Sort-Object { $_.OldPath.Length } -Descending)
    }
}

function Get-CapsulenvRelocationContext {
    [CmdletBinding()]
    param()

    return New-CapsulenvRelocationContext `
        -Previous (Get-CapsulenvPreviousRelocationFingerprint) `
        -Current (Get-CapsulenvRelocationFingerprint)
}

function Get-CapsulenvLastRelocationContext {
    [CmdletBinding()]
    param()

    $saved = Get-CapsulenvSavedRehydrationState
    if ($null -eq $saved) {
        throw 'No completed capsulenv relocation is recorded.'
    }
    $lastProperty = $saved.PSObject.Properties['LastRelocation']
    if ($null -eq $lastProperty -or $null -eq $lastProperty.Value) {
        throw 'No completed capsulenv relocation is recorded.'
    }
    $previousProperty = $lastProperty.Value.PSObject.Properties['Previous']
    $currentProperty = $lastProperty.Value.PSObject.Properties['Current']
    if ($null -eq $previousProperty -or $null -eq $currentProperty) {
        throw 'The recorded relocation context is incomplete.'
    }
    return New-CapsulenvRelocationContext `
        -Previous $previousProperty.Value `
        -Current $currentProperty.Value
}

function Get-CapsulenvRelocationReplacementPairs {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$RelocationContext)

    $pairs = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($mapping in @($RelocationContext.PathMappings)) {
        $oldNative = [string]$mapping.OldPath
        $newNative = [string]$mapping.NewPath
        $variants = @(
            [pscustomobject]@{ Old = $oldNative; New = $newNative; Kind = 'native' },
            [pscustomobject]@{ Old = $oldNative.Replace('\', '/'); New = $newNative.Replace('\', '/'); Kind = 'slash' },
            [pscustomobject]@{ Old = $oldNative.Replace('\', '\\'); New = $newNative.Replace('\', '\\'); Kind = 'json-escaped' }
        )

        foreach ($variant in $variants) {
            if ([string]::IsNullOrWhiteSpace([string]$variant.Old)) {
                continue
            }
            $key = ([string]$variant.Old).ToLowerInvariant()
            if ($seen.ContainsKey($key)) {
                continue
            }
            $seen[$key] = $true
            $pairs.Add($variant)
        }
    }

    return @($pairs | Sort-Object { $_.Old.Length } -Descending)
}

function Convert-CapsulenvRelocatedText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)]$RelocationContext
    )

    $result = $Text
    $replacementCount = 0
    foreach ($pair in @(Get-CapsulenvRelocationReplacementPairs -RelocationContext $RelocationContext)) {
        $oldValue = [string]$pair.Old
        $newValue = [string]$pair.New
        $boundary = '(?=$|[\\/"''\s,;:)\]\}\?&#])'
        $pattern = [System.Text.RegularExpressions.Regex]::Escape($oldValue) + $boundary
        $regex = [System.Text.RegularExpressions.Regex]::new(
            $pattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $matches = $regex.Matches($result)
        if ($matches.Count -eq 0) {
            continue
        }
        $replacement = [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $newValue }
        $result = $regex.Replace($result, $replacement)
        $replacementCount += $matches.Count
    }

    return [pscustomobject]@{
        Text = $result
        ReplacementCount = $replacementCount
        Changed = ($replacementCount -gt 0)
    }
}

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvRelocationContext
