function Get-CapsulenvInstalledManifestPropertyRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$App,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $value = $null
    $property = Get-CapsulenvJsonPropertyRecord -Object $App.Manifest -Name $Name
    if ($null -ne $property) {
        $value = $property.Value
    }

    $architecture = Get-CapsulenvInstalledScoopArchitecture -App $App
    $architectureMapProperty = Get-CapsulenvJsonPropertyRecord -Object $App.Manifest -Name 'architecture'
    $architectureManifestProperty = if ($null -ne $architectureMapProperty) {
        Get-CapsulenvJsonPropertyRecord -Object $architectureMapProperty.Value -Name $architecture
    } else {
        $null
    }
    $architectureProperty = if ($null -ne $architectureManifestProperty) {
        Get-CapsulenvJsonPropertyRecord -Object $architectureManifestProperty.Value -Name $Name
    } else {
        $null
    }
    if ($null -ne $architectureProperty) {
        $architectureValue = $architectureProperty.Value
        $hasArchitectureValue = (
            $null -ne $architectureValue -and
            @($architectureValue).Count -gt 0 -and
            -not ($architectureValue -is [string] -and [string]::IsNullOrWhiteSpace([string]$architectureValue))
        )
        if ($hasArchitectureValue) {
            $value = $architectureValue
        }
    }
    # Never return a manifest array as the function output itself. Windows
    # PowerShell can enumerate nested arrays while they cross command/function
    # boundaries. Keeping the value inside a scalar record preserves the JSON
    # array shape until the schema-specific consumer normalizes it.
    return [pscustomobject]@{ Value = $value }
}

function Get-CapsulenvInstalledScoopArchitecture {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$App)

    $architectureProperty = Get-CapsulenvJsonPropertyRecord -Object $App.Install -Name 'architecture'
    $architecture = if ($null -ne $architectureProperty) { [string]$architectureProperty.Value } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($architecture)) {
        return $architecture
    }

    $processorArchitecture = [string]$env:PROCESSOR_ARCHITECTURE
    switch -Regex ($processorArchitecture) {
        '^(?i:ARM64)$' { return 'arm64' }
        '^(?i:x86)$' { return '32bit' }
        default { return '64bit' }
    }
}

function Get-CapsulenvInstalledShortcutEntries {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$App)

    $shortcutProperty = Get-CapsulenvInstalledManifestPropertyRecord -App $App -Name 'shortcuts'
    $shortcuts = $shortcutProperty.Value
    if ($null -eq $shortcuts) {
        return [pscustomobject]@{ Entries = @() }
    }

    $items = @($shortcuts)
    if ($items.Count -eq 0) {
        return [pscustomobject]@{ Entries = @() }
    }

    # Scoop shortcuts are always an outer list of shortcut tuples. Windows
    # PowerShell 5.1 can lose that one-element outer list while values travel
    # through function output, leaving a valid single tuple such as
    # @('code.exe', 'Visual Studio Code') looking like two shortcut entries.
    # Detect that shape by its required first string field and restore only the
    # schema-mandated outer list. Multi-shortcut manifests already begin with
    # an array/collection and are left untouched.
    if ($items[0] -is [string]) {
        $entries = New-Object System.Collections.Generic.List[object]
        $entries.Add([object[]]$items)
        return [pscustomobject]@{ Entries = $entries.ToArray() }
    }

    return [pscustomobject]@{ Entries = $items }
}

function Get-CapsulenvInstalledBinEntries {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$App)

    $binProperty = Get-CapsulenvInstalledManifestPropertyRecord -App $App -Name 'bin'
    $bin = $binProperty.Value
    if ($null -eq $bin) {
        return [pscustomobject]@{ Entries = @() }
    }

    if ($bin -is [string]) {
        return [pscustomobject]@{ Entries = @([string]$bin) }
    }
    return [pscustomobject]@{ Entries = @($bin) }
}

function Expand-CapsulenvScoopShortcutValue {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)]$App
    )

    if ($null -eq $Value) {
        return $null
    }

    # For launch purposes current/ and the physical version directory address
    # the same installed files. Using current keeps all generated arguments
    # relocation-safe even when a copied capsule receives a different drive.
    $dir = [string]$App.Current
    $originalDir = $dir
    $persistDir = [string]$App.Persist
    return $Value.Replace('$original_dir', $originalDir).Replace('$persist_dir', $persistDir).Replace('$dir', $dir)
}

function ConvertTo-CapsulenvInstalledShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$App,
        [Parameter(Mandatory = $true)]$Entry
    )

    $parts = @($Entry)
    if ($parts.Count -lt 2) {
        throw "Invalid shortcut entry in installed manifest for $($App.Scope.ToLowerInvariant())/$($App.Name)."
    }

    $targetSpec = Expand-CapsulenvScoopShortcutValue -Value ([string]$parts[0]) -App $App
    $shortcutName = [string]$parts[1]
    if ([string]::IsNullOrWhiteSpace($targetSpec) -or [string]::IsNullOrWhiteSpace($shortcutName)) {
        throw "Invalid shortcut entry in installed manifest for $($App.Scope.ToLowerInvariant())/$($App.Name)."
    }

    $target = if ([System.IO.Path]::IsPathRooted($targetSpec)) {
        $resolvedTarget = [System.IO.Path]::GetFullPath($targetSpec)
        if (
            [string]$App.Scope -eq 'Capsule' -and
            -not (Test-CapsulenvSamePath -Left $resolvedTarget -Right ([string]$App.Current)) -and
            -not (Test-CapsulenvPathNested -Parent ([string]$App.Current) -Child $resolvedTarget)
        ) {
            throw "Capsulenv package shortcut target escapes its current projection: $targetSpec"
        }
        $resolvedTarget
    } else {
        Resolve-CapsulenvScoopAppRelativePath -Root $App.Current -RelativePath $targetSpec
    }
    $arguments = if ($parts.Count -ge 3 -and $null -ne $parts[2]) {
        Expand-CapsulenvScoopShortcutValue -Value ([string]$parts[2]) -App $App
    } else {
        ''
    }
    $iconSpec = if ($parts.Count -ge 4 -and $null -ne $parts[3]) {
        Expand-CapsulenvScoopShortcutValue -Value ([string]$parts[3]) -App $App
    } else {
        ''
    }
    $icon = if ([string]::IsNullOrWhiteSpace($iconSpec)) {
        ''
    } elseif ([System.IO.Path]::IsPathRooted($iconSpec)) {
        $resolvedIcon = [System.IO.Path]::GetFullPath($iconSpec)
        if (
            [string]$App.Scope -eq 'Capsule' -and
            -not (Test-CapsulenvSamePath -Left $resolvedIcon -Right ([string]$App.Current)) -and
            -not (Test-CapsulenvPathNested -Parent ([string]$App.Current) -Child $resolvedIcon)
        ) {
            throw "Capsulenv package shortcut icon escapes its current projection: $iconSpec"
        }
        $resolvedIcon
    } else {
        Resolve-CapsulenvScoopAppRelativePath -Root $App.Current -RelativePath $iconSpec
    }

    return [pscustomobject]@{
        Provider = [string]$App.Provider
        ProviderScope = $App.ProviderScope
        Scope = [string]$App.Scope
        App = [string]$App.Name
        Selector = [string]$App.Selector
        DisplaySelector = [string]$App.DisplaySelector
        Name = $shortcutName
        Target = $target
        Arguments = $arguments
        Icon = $icon
        WorkingDirectory = Split-Path -Parent $target
        Architecture = Get-CapsulenvInstalledScoopArchitecture -App $App
        ManifestPath = [string]$App.ManifestPath
        InstallPath = [string]$App.InstallPath
    }
}

function ConvertTo-CapsulenvInstalledBin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$App,
        [Parameter(Mandatory = $true)]$Entry
    )

    $parts = @($Entry)
    if ($parts.Count -lt 1 -or [string]::IsNullOrWhiteSpace([string]$parts[0])) {
        throw "Invalid bin entry in installed manifest for $($App.Scope.ToLowerInvariant())/$($App.Name)."
    }

    $targetSpec = Expand-CapsulenvScoopShortcutValue -Value ([string]$parts[0]) -App $App
    $target = if ([System.IO.Path]::IsPathRooted($targetSpec)) {
        $resolvedTarget = [System.IO.Path]::GetFullPath($targetSpec)
        if (
            [string]$App.Scope -eq 'Capsule' -and
            -not (Test-CapsulenvSamePath -Left $resolvedTarget -Right ([string]$App.Current)) -and
            -not (Test-CapsulenvPathNested -Parent ([string]$App.Current) -Child $resolvedTarget)
        ) {
            throw "Capsulenv package bin target escapes its current projection: $targetSpec"
        }
        $resolvedTarget
    } else {
        Resolve-CapsulenvScoopAppRelativePath -Root $App.Current -RelativePath $targetSpec
    }
    $alias = if ($parts.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace([string]$parts[1])) {
        [string]$parts[1]
    } else {
        [System.IO.Path]::GetFileNameWithoutExtension($target)
    }

    return [pscustomobject]@{
        Provider = [string]$App.Provider
        ProviderScope = $App.ProviderScope
        Scope = [string]$App.Scope
        App = [string]$App.Name
        Selector = [string]$App.Selector
        DisplaySelector = [string]$App.DisplaySelector
        Name = $alias
        Target = $target
        Architecture = Get-CapsulenvInstalledScoopArchitecture -App $App
        ManifestPath = [string]$App.ManifestPath
        InstallPath = [string]$App.InstallPath
    }
}

