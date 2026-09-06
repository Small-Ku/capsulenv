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

