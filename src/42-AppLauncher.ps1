function Get-CapsulenvJsonPropertyRecord {
    [CmdletBinding()]
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) {
            return $null
        }
        return [pscustomobject]@{ Value = $Object[$Name] }
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return [pscustomobject]@{ Value = $property.Value }
}

function Get-CapsulenvInstalledAppRootRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Capsule', 'User', 'Global')]
        [string]$Scope
    )

    if ($Scope -eq 'Capsule') {
        $root = Get-CapsulenvPackageRoot
        return [pscustomobject]@{
            Scope = $Scope
            Provider = 'Capsulenv'
            ProviderScope = $null
            Root = $root
            AppsRoot = $root
            PersistRoot = Get-CapsulenvPackagePersistRoot
        }
    }

    $root = if ($Scope -eq 'Global') { Get-CapsulenvScoopGlobalRoot } else { Get-CapsulenvScoopRoot }
    return [pscustomobject]@{
        Scope = $Scope
        Provider = 'Scoop'
        ProviderScope = $Scope
        Root = $root
        AppsRoot = Join-Path $root 'apps'
        PersistRoot = Join-Path $root 'persist'
    }
}

function Get-CapsulenvScoopAppRootRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Capsule', 'User', 'Global')]
        [string]$Scope
    )

    # Compatibility name for legacy relocation code. The primary abstraction
    # is provider-neutral because Capsule is not a Scoop scope.
    return Get-CapsulenvInstalledAppRootRecord -Scope $Scope
}

function Split-CapsulenvInstalledAppSelector {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Selector)

    if ([string]::IsNullOrWhiteSpace($Selector)) {
        throw 'Installed app selector must not be empty.'
    }

    $provider = $null
    $providerScope = $null
    $legacyAlias = $false
    $name = $Selector
    $separator = $Selector.IndexOf('/')
    if ($separator -ge 0) {
        if ($separator -eq 0 -or $separator -eq ($Selector.Length - 1) -or $Selector.IndexOf('/', $separator + 1) -ge 0) {
            throw "Invalid installed app selector '$Selector'. Use <app>, capsule/<app>, scoop/<app>, scoop:user/<app>, or scoop:global/<app>."
        }
        $selectorToken = $Selector.Substring(0, $separator).ToLowerInvariant()
        switch ($selectorToken) {
            'capsule' {
                $provider = 'Capsulenv'
            }
            'scoop' {
                $provider = 'Scoop'
            }
            'scoop:user' {
                $provider = 'Scoop'
                $providerScope = 'User'
            }
            'scoop:global' {
                $provider = 'Scoop'
                $providerScope = 'Global'
            }
            'user' {
                $provider = 'Scoop'
                $providerScope = 'User'
                $legacyAlias = $true
            }
            'global' {
                $provider = 'Scoop'
                $providerScope = 'Global'
                $legacyAlias = $true
            }
            default {
                throw "Invalid installed app selector namespace '$selectorToken'. Use capsule/<app> or scoop/<app>; use scoop:user/<app> or scoop:global/<app> only to disambiguate an upstream Scoop root. Legacy user/<app> and global/<app> aliases remain accepted."
            }
        }
        $name = $Selector.Substring($separator + 1)
    }

    if (-not (Test-CapsulenvPortableFileNameComponent -Value $name)) {
        throw "Invalid installed app name '$name'."
    }

    return [pscustomobject]@{
        Provider = $provider
        ProviderScope = $providerScope
        Name = $name
        LegacyAlias = $legacyAlias
    }
}

function Test-CapsulenvInstalledAppSelectorEquivalent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    try {
        $leftSelector = Split-CapsulenvInstalledAppSelector -Selector $Left
        $rightSelector = Split-CapsulenvInstalledAppSelector -Selector $Right
    } catch {
        return $false
    }
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$leftSelector.Name, [string]$rightSelector.Name)) {
        return $false
    }
    if ($null -eq $leftSelector.Provider -or $null -eq $rightSelector.Provider) {
        return ($null -eq $leftSelector.Provider -and $null -eq $rightSelector.Provider)
    }
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$leftSelector.Provider, [string]$rightSelector.Provider)) {
        return $false
    }
    if ([string]$leftSelector.Provider -ne 'Scoop') {
        return $true
    }
    if ($null -eq $leftSelector.ProviderScope -or $null -eq $rightSelector.ProviderScope) {
        return $true
    }
    return [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$leftSelector.ProviderScope, [string]$rightSelector.ProviderScope)
}

function Split-CapsulenvScoopAppSelector {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Selector)

    # Compatibility surface for older internal callers. Scope used to mix the
    # package provider (Capsulenv) with Scoop's user/global roots. New code
    # should consume Provider + ProviderScope from Split-CapsulenvInstalledAppSelector.
    $parsed = Split-CapsulenvInstalledAppSelector -Selector $Selector
    $legacyScope = if ([string]$parsed.Provider -eq 'Capsulenv') {
        'Capsule'
    } elseif ([string]$parsed.Provider -eq 'Scoop' -and $null -ne $parsed.ProviderScope) {
        [string]$parsed.ProviderScope
    } else {
        $null
    }
    return [pscustomobject]@{
        Scope = $legacyScope
        Provider = $parsed.Provider
        ProviderScope = $parsed.ProviderScope
        Name = [string]$parsed.Name
        LegacyAlias = [bool]$parsed.LegacyAlias
    }
}

function Get-CapsulenvInstalledApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Selector,
        [switch]$AllowMissing
    )

    $parsed = Split-CapsulenvInstalledAppSelector -Selector $Selector
    $scopes = if ([string]$parsed.Provider -eq 'Capsulenv') {
        @('Capsule')
    } elseif ([string]$parsed.Provider -eq 'Scoop') {
        if ($null -ne $parsed.ProviderScope) { @([string]$parsed.ProviderScope) } else { @('User', 'Global') }
    } else {
        @('Capsule', 'User', 'Global')
    }
    $matches = New-Object System.Collections.Generic.List[object]

    foreach ($scope in $scopes) {
        $rootRecord = Get-CapsulenvInstalledAppRootRecord -Scope $scope
        $packageState = $null
        if ($scope -eq 'Capsule') {
            $packageState = Get-CapsulenvInstalledPackageState -Name $parsed.Name -AllowMissing
            if ($null -eq $packageState) {
                continue
            }
            $current = [string]$packageState.CurrentRoot
            $currentTarget = Get-CapsulenvReparseTarget -Path $current
            if ($null -eq $currentTarget -or -not (Test-CapsulenvSamePath -Left $currentTarget -Right ([string]$packageState.InstallRoot))) {
                throw "Capsulenv package current projection is missing or no longer owned: $current. Run capsulenv rehydrate."
            }
        } else {
            $current = Join-Path (Join-Path $rootRecord.AppsRoot $parsed.Name) 'current'
            if (-not (Test-Path -LiteralPath $current -PathType Container)) {
                continue
            }
        }

        $provider = [string]$rootRecord.Provider
        $providerScope = $rootRecord.ProviderScope
        $canonicalSelector = if ($provider -eq 'Capsulenv') {
            'capsule/{0}' -f $parsed.Name
        } else {
            'scoop:{0}/{1}' -f $scope.ToLowerInvariant(), $parsed.Name
        }
        $displaySelector = if ($provider -eq 'Capsulenv') { $canonicalSelector } else { 'scoop/{0}' -f $parsed.Name }
        $legacySelector = if ($provider -eq 'Capsulenv') { $canonicalSelector } else { '{0}/{1}' -f $scope.ToLowerInvariant(), $parsed.Name }

        $manifestPath = Join-Path $current 'manifest.json'
        $installPath = Join-Path $current 'install.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "Installed manifest is missing for ${canonicalSelector}: $manifestPath"
        }
        if (-not (Test-Path -LiteralPath $installPath -PathType Leaf)) {
            throw "Installed metadata is missing for ${canonicalSelector}: $installPath"
        }

        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $install = Get-Content -LiteralPath $installPath -Raw | ConvertFrom-Json
        } catch {
            throw "Failed to read installed app metadata for ${canonicalSelector}: $($_.Exception.Message)"
        }

        $matches.Add([pscustomobject]@{
            Provider = $provider
            ProviderScope = $providerScope
            Ownership = if ($provider -eq 'Capsulenv') { 'PortableSafe' } else { 'Upstream' }
            Scope = $scope
            Name = [string]$parsed.Name
            Selector = $canonicalSelector
            DisplaySelector = $displaySelector
            LegacySelector = $legacySelector
            Root = $rootRecord.Root
            AppRoot = Join-Path $rootRecord.AppsRoot $parsed.Name
            Current = $current
            Persist = Join-Path $rootRecord.PersistRoot $parsed.Name
            ManifestPath = $manifestPath
            InstallPath = $installPath
            Manifest = $manifest
            Install = $install
        })
        if ($null -eq $parsed.Provider -and $scope -eq 'Capsule') {
            return $matches[0]
        }
    }

    if ($matches.Count -eq 0) {
        if ($AllowMissing) {
            return $null
        }
        throw "App is not installed in the capsule: $Selector"
    }
    if ($matches.Count -gt 1) {
        throw "App '$($parsed.Name)' exists in both user and global upstream Scoop roots. Use scoop:user/$($parsed.Name) or scoop:global/$($parsed.Name)."
    }
    return $matches[0]
}

function Get-CapsulenvInstalledScoopApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Selector,
        [switch]$AllowMissing
    )

    # Historical name kept for module-internal and third-party compatibility.
    # The resolver has always included Capsulenv-owned packages, so route it to
    # the provider-neutral implementation instead of perpetuating that model.
    return Get-CapsulenvInstalledApp -Selector $Selector -AllowMissing:$AllowMissing
}

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

function Get-CapsulenvScoopAppShortcuts {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$App)

    $installed = Get-CapsulenvInstalledApp -Selector $App
    $results = New-Object System.Collections.Generic.List[object]
    $entrySet = Get-CapsulenvInstalledShortcutEntries -App $installed
    foreach ($entry in @($entrySet.Entries)) {
        $results.Add((ConvertTo-CapsulenvInstalledShortcut -App $installed -Entry $entry))
    }
    return $results.ToArray()
}

function Get-CapsulenvScoopShortcutCatalog {
    [CmdletBinding()]
    param()

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($scope in @('Capsule', 'User', 'Global')) {
        $rootRecord = Get-CapsulenvInstalledAppRootRecord -Scope $scope
        if (-not (Test-Path -LiteralPath $rootRecord.AppsRoot -PathType Container)) {
            continue
        }
        foreach ($directory in @(Get-ChildItem -LiteralPath $rootRecord.AppsRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $current = Join-Path $directory.FullName 'current'
            if (-not (Test-Path -LiteralPath $current -PathType Container)) {
                continue
            }
            try {
                $selector = if ($scope -eq 'Capsule') {
                    'capsule/{0}' -f $directory.Name
                } else {
                    'scoop:{0}/{1}' -f $scope.ToLowerInvariant(), $directory.Name
                }
                foreach ($shortcut in @(Get-CapsulenvScoopAppShortcuts -App $selector)) {
                    $results.Add($shortcut)
                }
            } catch {
                Write-Verbose $_.Exception.Message
            }
        }
    }
    return $results.ToArray()
}

function Start-CapsulenvScoopShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [string]$ShortcutName,
        [string[]]$Arguments = @(),
        [switch]$PassThru
    )

    [void](Set-CapsulenvSessionEnvironment)
    $installed = Get-CapsulenvInstalledApp -Selector $App
    $shortcuts = @(Get-CapsulenvScoopAppShortcuts -App $installed.Selector)
    if ($shortcuts.Count -eq 0) {
        throw "Installed app '$App' does not define a shortcut. Use its shim/bin command when available."
    }

    $selected = $null
    if (-not [string]::IsNullOrWhiteSpace($ShortcutName)) {
        $matches = @($shortcuts | Where-Object { [string]$_.Name -eq $ShortcutName })
        if ($matches.Count -eq 0) {
            $available = @($shortcuts | ForEach-Object { [string]$_.Name }) -join ', '
            throw "Shortcut '$ShortcutName' was not found for '$App'. Available shortcuts: $available"
        }
        if ($matches.Count -gt 1) {
            throw "Shortcut name '$ShortcutName' is ambiguous for '$App'."
        }
        $selected = $matches[0]
    } elseif ($shortcuts.Count -eq 1) {
        $selected = $shortcuts[0]
    } else {
        $available = @($shortcuts | ForEach-Object { [string]$_.Name }) -join ', '
        throw "Installed app '$App' defines multiple shortcuts. Specify one of: $available"
    }

    if (-not (Test-Path -LiteralPath $selected.Target -PathType Leaf)) {
        throw "Shortcut target does not exist: $($selected.Target)"
    }

    # Scoop shortcut arguments are already one Windows command-line fragment.
    # Preserve that fragment, then append correctly escaped runtime arguments.
    $argumentFragments = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace([string]$selected.Arguments)) {
        $argumentFragments.Add([string]$selected.Arguments)
    }
    foreach ($argument in @($Arguments)) {
        $argumentFragments.Add((ConvertTo-CapsulenvProcessArgument -Argument ([string]$argument)))
    }
    $rawArguments = if ($argumentFragments.Count -gt 0) { $argumentFragments.ToArray() -join ' ' } else { '' }

    $environment = [pscustomobject]@{ PathEntries = @(); Variables = [ordered]@{} }
    if ([string]$installed.Scope -eq 'Capsule') {
        $environment = Get-CapsulenvPackageEnvironmentPlan -Installed $installed
    }
    $plan = New-CapsulenvProcessPlan `
        -Executable ([string]$selected.Target) `
        -RawArgumentString $rawArguments `
        -WorkingDirectory ([string]$selected.WorkingDirectory) `
        -Environment $environment.Variables `
        -PathEntries @($environment.PathEntries) `
        -ExecutionMode Detached `
        -Metadata ([ordered]@{
            App = [string]$installed.Selector
            Shortcut = [string]$selected.Name
            Ownership = [string]$installed.Ownership
        })
    $process = Invoke-CapsulenvProcessPlan -Plan $plan
    if ($PassThru) {
        return $process
    }
    if ($process -is [System.IDisposable]) {
        $process.Dispose()
    }
    return $null
}

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvScoopAppShortcuts, Get-CapsulenvScoopAppBins, Get-CapsulenvScoopShortcutCatalog, Start-CapsulenvScoopShortcut, Resolve-CapsulenvScoopAppExecutable, Resolve-CapsulenvScoopAppPersistPath
