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
    param([Parameter(Mandatory = $true)][string]$Selector)

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
            Root = $rootRecord.Root
            Current = $current
            Persist = Join-Path $rootRecord.PersistRoot $parsed.Name
            ManifestPath = $manifestPath
            InstallPath = $installPath
            Manifest = $manifest
            Install = $install
        })
    }

    if ($matches.Count -eq 0) {
        throw "Scoop app is not installed in the capsule: $Selector"
    }
    if ($matches.Count -gt 1) {
        throw "Scoop app '$($parsed.Name)' is installed in both user and global roots. Use user/$($parsed.Name) or global/$($parsed.Name)."
    }
    return $matches[0]
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

    $manifest = $App.Manifest
    $shortcutProperty = Get-CapsulenvJsonPropertyRecord -Object $manifest -Name 'shortcuts'
    $shortcuts = $null
    if ($null -ne $shortcutProperty) {
        $shortcuts = $shortcutProperty.Value
    }
    $architecture = Get-CapsulenvInstalledScoopArchitecture -App $App
    $architectureMapProperty = Get-CapsulenvJsonPropertyRecord -Object $manifest -Name 'architecture'
    $architectureManifestProperty = if ($null -ne $architectureMapProperty) {
        Get-CapsulenvJsonPropertyRecord -Object $architectureMapProperty.Value -Name $architecture
    } else {
        $null
    }
    $architectureShortcutProperty = if ($null -ne $architectureManifestProperty) {
        Get-CapsulenvJsonPropertyRecord -Object $architectureManifestProperty.Value -Name 'shortcuts'
    } else {
        $null
    }
    if ($null -ne $architectureShortcutProperty -and @($architectureShortcutProperty.Value).Count -gt 0) {
        $shortcuts = $architectureShortcutProperty.Value
    }

    if ($null -eq $shortcuts) {
        $shortcuts = @()
    }
    return [pscustomobject]@{ Entries = $shortcuts }
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

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvScoopAppShortcuts, Get-CapsulenvScoopShortcutCatalog, Start-CapsulenvScoopShortcut
