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

function Get-CapsulenvScoopAppRootRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('User', 'Global')]
        [string]$Scope
    )

    $root = if ($Scope -eq 'Global') {
        Get-CapsulenvScoopGlobalRoot
    } else {
        Get-CapsulenvScoopRoot
    }
    return [pscustomobject]@{
        Scope = $Scope
        Root = $root
        AppsRoot = Join-Path $root 'apps'
        PersistRoot = Join-Path $root 'persist'
    }
}

function Split-CapsulenvScoopAppSelector {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Selector)

    if ([string]::IsNullOrWhiteSpace($Selector)) {
        throw 'Scoop app selector must not be empty.'
    }

    $scope = $null
    $name = $Selector
    $separator = $Selector.IndexOf('/')
    if ($separator -ge 0) {
        if ($separator -eq 0 -or $separator -eq ($Selector.Length - 1) -or $Selector.IndexOf('/', $separator + 1) -ge 0) {
            throw "Invalid Scoop app selector '$Selector'. Use <app>, user/<app>, or global/<app>."
        }
        $scopeToken = $Selector.Substring(0, $separator).ToLowerInvariant()
        switch ($scopeToken) {
            'user' { $scope = 'User' }
            'global' { $scope = 'Global' }
            default { throw "Invalid Scoop app scope '$scopeToken'. Use user/<app> or global/<app>." }
        }
        $name = $Selector.Substring($separator + 1)
    }

    if ($name -match '[\\/:*?"<>|]') {
        throw "Invalid Scoop app name '$name'."
    }

    return [pscustomobject]@{
        Scope = $scope
        Name = $name
    }
}

function Get-CapsulenvInstalledScoopApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Selector,
        [switch]$AllowMissing
    )

    $parsed = Split-CapsulenvScoopAppSelector -Selector $Selector
    $scopes = if ($null -ne $parsed.Scope) { @([string]$parsed.Scope) } else { @('User', 'Global') }
    $matches = New-Object System.Collections.Generic.List[object]

    foreach ($scope in $scopes) {
        $rootRecord = Get-CapsulenvScoopAppRootRecord -Scope $scope
        $current = Join-Path (Join-Path $rootRecord.AppsRoot $parsed.Name) 'current'
        if (-not (Test-Path -LiteralPath $current -PathType Container)) {
            continue
        }
        $manifestPath = Join-Path $current 'manifest.json'
        $installPath = Join-Path $current 'install.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "Installed manifest is missing for $($scope.ToLowerInvariant())/$($parsed.Name): $manifestPath"
        }
        if (-not (Test-Path -LiteralPath $installPath -PathType Leaf)) {
            throw "Installed metadata is missing for $($scope.ToLowerInvariant())/$($parsed.Name): $installPath"
        }

        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $install = Get-Content -LiteralPath $installPath -Raw | ConvertFrom-Json
        } catch {
            throw "Failed to read installed Scoop metadata for $($scope.ToLowerInvariant())/$($parsed.Name): $($_.Exception.Message)"
        }

        $matches.Add([pscustomobject]@{
            Scope = $scope
            Name = [string]$parsed.Name
            Selector = ('{0}/{1}' -f $scope.ToLowerInvariant(), $parsed.Name)
            Root = $rootRecord.Root
            AppRoot = Join-Path $rootRecord.AppsRoot $parsed.Name
            Current = $current
            Persist = Join-Path $rootRecord.PersistRoot $parsed.Name
            ManifestPath = $manifestPath
            InstallPath = $installPath
            Manifest = $manifest
            Install = $install
        })
    }

    if ($matches.Count -eq 0) {
        if ($AllowMissing) {
            return $null
        }
        throw "Scoop app is not installed in the capsule: $Selector"
    }
    if ($matches.Count -gt 1) {
        throw "Scoop app '$($parsed.Name)' is installed in both user and global roots. Use user/$($parsed.Name) or global/$($parsed.Name)."
    }
    return $matches[0]
}

function Get-CapsulenvInstalledManifestPropertyValue {
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
    return $value
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

    $shortcuts = Get-CapsulenvInstalledManifestPropertyValue -App $App -Name 'shortcuts'

    if ($null -eq $shortcuts) {
        $shortcuts = @()
    }
    return [pscustomobject]@{ Entries = $shortcuts }
}

function Get-CapsulenvInstalledBinEntries {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$App)

    $bin = Get-CapsulenvInstalledManifestPropertyValue -App $App -Name 'bin'
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
        [System.IO.Path]::GetFullPath($targetSpec)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $App.Current $targetSpec))
    }
    $arguments = if ($parts.Count -ge 3 -and $null -ne $parts[2]) {
        Expand-CapsulenvScoopShortcutValue -Value ([string]$parts[2]) -App $App
    } else {
        ''
    }
    $icon = if ($parts.Count -ge 4 -and $null -ne $parts[3]) {
        Expand-CapsulenvScoopShortcutValue -Value ([string]$parts[3]) -App $App
    } else {
        ''
    }

    return [pscustomobject]@{
        Scope = [string]$App.Scope
        App = [string]$App.Name
        Selector = ('{0}/{1}' -f $App.Scope.ToLowerInvariant(), $App.Name)
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

    $parts = if ($Entry -is [string]) { @([string]$Entry) } else { @($Entry) }
    if ($parts.Count -lt 1 -or [string]::IsNullOrWhiteSpace([string]$parts[0])) {
        throw "Invalid bin entry in installed manifest for $($App.Scope.ToLowerInvariant())/$($App.Name)."
    }

    $targetSpec = Expand-CapsulenvScoopShortcutValue -Value ([string]$parts[0]) -App $App
    $target = if ([System.IO.Path]::IsPathRooted($targetSpec)) {
        [System.IO.Path]::GetFullPath($targetSpec)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $App.Current $targetSpec))
    }
    $alias = if ($parts.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace([string]$parts[1])) {
        [string]$parts[1]
    } else {
        [System.IO.Path]::GetFileNameWithoutExtension($target)
    }

    return [pscustomobject]@{
        Scope = [string]$App.Scope
        App = [string]$App.Name
        Selector = [string]$App.Selector
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

    $installed = Get-CapsulenvInstalledScoopApp -Selector $App
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
        throw "Scoop app integration paths must remain relative to their owning app: $RelativePath"
    }
    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]'\\/')
    $resolved = [System.IO.Path]::GetFullPath((Join-Path $rootPath $RelativePath))
    if (
        -not [System.StringComparer]::OrdinalIgnoreCase.Equals($resolved.TrimEnd([char[]]'\\/'), $rootPath) -and
        -not $resolved.StartsWith(
            $rootPath + [System.IO.Path]::DirectorySeparatorChar,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "Scoop app integration path escapes its owning app: $RelativePath"
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

    $installed = Get-CapsulenvInstalledScoopApp -Selector $App
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
            throw "Installed Scoop app '$($installed.Selector)' does not expose exactly one bin named '$BinName'."
        }
        if (-not (Test-Path -LiteralPath $matches[0].Target -PathType Leaf)) {
            throw "Configured Scoop bin target is missing: $($matches[0].Target)"
        }
        return [string]$matches[0].Target
    }

    if (-not [string]::IsNullOrWhiteSpace($ShortcutName)) {
        $matches = @(Get-CapsulenvScoopAppShortcuts -App $installed.Selector | Where-Object { [string]$_.Name -eq $ShortcutName })
        if ($matches.Count -ne 1) {
            throw "Installed Scoop app '$($installed.Selector)' does not expose exactly one shortcut named '$ShortcutName'."
        }
        if (-not (Test-Path -LiteralPath $matches[0].Target -PathType Leaf)) {
            throw "Configured Scoop shortcut target is missing: $($matches[0].Target)"
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
        throw "Installed Scoop app '$($installed.Selector)' has no resolvable bin or shortcut executable. Configure RelativePath, BinName, or ShortcutName."
    }
    throw "Installed Scoop app '$($installed.Selector)' exposes multiple executable targets. Configure RelativePath, BinName, or ShortcutName."
}

function Resolve-CapsulenvScoopAppPersistPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [AllowEmptyString()][string]$RelativePath = '',
        [switch]$AllowMissing
    )

    $installed = Get-CapsulenvInstalledScoopApp -Selector $App
    $target = Resolve-CapsulenvScoopAppRelativePath -Root $installed.Persist -RelativePath $RelativePath
    if (-not $AllowMissing -and -not (Test-Path -LiteralPath $target)) {
        throw "Configured persisted path is missing for '$($installed.Selector)': $target"
    }
    return $target
}

function Test-CapsulenvScoopAppOwnsPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $installed = Get-CapsulenvInstalledScoopApp -Selector $App
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

    $installed = Get-CapsulenvInstalledScoopApp -Selector $App
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
    foreach ($scope in @('User', 'Global')) {
        $rootRecord = Get-CapsulenvScoopAppRootRecord -Scope $scope
        if (-not (Test-Path -LiteralPath $rootRecord.AppsRoot -PathType Container)) {
            continue
        }
        foreach ($directory in @(Get-ChildItem -LiteralPath $rootRecord.AppsRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $current = Join-Path $directory.FullName 'current'
            if (-not (Test-Path -LiteralPath $current -PathType Container)) {
                continue
            }
            try {
                foreach ($shortcut in @(Get-CapsulenvScoopAppShortcuts -App (('{0}/{1}' -f $scope.ToLowerInvariant(), $directory.Name)))) {
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
    $shortcuts = @(Get-CapsulenvScoopAppShortcuts -App $App)
    if ($shortcuts.Count -eq 0) {
        throw "Installed Scoop app '$App' does not define a shortcut. Use its Scoop shim/bin command when available."
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
        throw "Installed Scoop app '$App' defines multiple shortcuts. Specify one of: $available"
    }

    if (-not (Test-Path -LiteralPath $selected.Target -PathType Leaf)) {
        throw "Shortcut target does not exist: $($selected.Target)"
    }

    $launchArguments = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace([string]$selected.Arguments)) {
        # Scoop stores shortcut arguments as one command-line string. Preserve
        # it verbatim rather than trying to parse and reserialize it.
        $launchArguments.Add([string]$selected.Arguments)
    }
    foreach ($argument in @($Arguments)) {
        $launchArguments.Add((ConvertTo-CapsulenvProcessArgument -Argument ([string]$argument)))
    }

    $startParameters = @{
        FilePath = [string]$selected.Target
        WorkingDirectory = [string]$selected.WorkingDirectory
    }
    if ($launchArguments.Count -gt 0) {
        $startParameters['ArgumentList'] = @($launchArguments.ToArray())
    }
    if ($PassThru) {
        $startParameters['PassThru'] = $true
    }
    return Start-Process @startParameters
}

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvScoopAppShortcuts, Get-CapsulenvScoopAppBins, Get-CapsulenvScoopShortcutCatalog, Start-CapsulenvScoopShortcut, Resolve-CapsulenvScoopAppExecutable, Resolve-CapsulenvScoopAppPersistPath
