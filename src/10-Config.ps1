function Merge-CapsulenvHashtable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Base,
        [Parameter(Mandatory = $true)][hashtable]$Override
    )

    $result = @{}
    foreach ($key in $Base.Keys) {
        $result[$key] = $Base[$key]
    }

    foreach ($key in $Override.Keys) {
        if (
            $result.ContainsKey($key) -and
            $result[$key] -is [hashtable] -and
            $Override[$key] -is [hashtable]
        ) {
            $result[$key] = Merge-CapsulenvHashtable -Base $result[$key] -Override $Override[$key]
        } else {
            $result[$key] = $Override[$key]
        }
    }

    return $result
}

function Assert-CapsulenvScoopIntegrationRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Name must not be empty."
    }
    if (
        [System.IO.Path]::IsPathRooted($Path) -or
        $Path -match '(^|[\\/])\.\.([\\/]|$)'
    ) {
        throw "$Name must remain relative to its owning Scoop app: $Path"
    }
}

function Get-CapsulenvBrowserDefinitionFromConfiguration {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Configuration,
        [Parameter(Mandatory = $true)][string]$App
    )

    $parsed = Split-CapsulenvScoopAppSelector -Selector $App
    $exact = New-Object System.Collections.Generic.List[object]
    $byName = New-Object System.Collections.Generic.List[object]
    foreach ($name in @($Configuration.Browsers.Keys)) {
        $definition = $Configuration.Browsers[$name]
        if ($definition -isnot [hashtable]) {
            continue
        }
        $selector = if ($definition.ContainsKey('App')) { [string]$definition.App } else { [string]$name }
        if ([string]::IsNullOrWhiteSpace($selector)) {
            continue
        }
        if ([System.StringComparer]::OrdinalIgnoreCase.Equals($selector, $App)) {
            $exact.Add($definition)
            continue
        }
        try {
            $configured = Split-CapsulenvScoopAppSelector -Selector $selector
            if (
                $null -eq $configured.Scope -and
                [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$configured.Name, [string]$parsed.Name)
            ) {
                $byName.Add($definition)
            }
        } catch {}
    }
    $matches = if ($exact.Count -gt 0) { @($exact.ToArray()) } else { @($byName.ToArray()) }
    if ($matches.Count -eq 0) {
        throw "No Browsers entry selects Scoop app '$App'."
    }
    if ($matches.Count -gt 1) {
        throw "Multiple Browsers entries select Scoop app '$App'."
    }
    return $matches[0]
}


function Assert-CapsulenvPortableStoragePath {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "ToolStorage path is empty: $Name"
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if (
        [System.IO.Path]::IsPathRooted($expanded) -or
        $expanded -match '(^|[\\/])\.\.([\\/]|$)'
    ) {
        throw "ToolStorage paths must remain inside CAPSULENV_ROOT: $Name=$Path"
    }
}

function Assert-CapsulenvConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Configuration)

    foreach ($sectionName in @('Scoop', 'Environment', 'ToolStorage', 'Bitwarden', 'SingBox', 'Browsers', 'UserIntegration')) {
        if (-not $Configuration.ContainsKey($sectionName) -or $Configuration[$sectionName] -isnot [hashtable]) {
            throw "Configuration section is missing or invalid: $sectionName"
        }
    }
    if (
        -not $Configuration.Scoop.ContainsKey('Root') -or
        [string]::IsNullOrWhiteSpace([string]$Configuration.Scoop.Root)
    ) {
        throw 'Scoop configuration value is missing: Root'
    }
    if (
        -not $Configuration.Scoop.ContainsKey('GlobalRoot') -or
        [string]::IsNullOrWhiteSpace([string]$Configuration.Scoop.GlobalRoot)
    ) {
        throw 'Scoop configuration value is missing: GlobalRoot'
    }
    if (
        -not $Configuration.Scoop.ContainsKey('Cache') -or
        [string]::IsNullOrWhiteSpace([string]$Configuration.Scoop.Cache)
    ) {
        throw 'Scoop configuration value is missing: Cache'
    }
    Assert-CapsulenvPortableStoragePath -Name 'Scoop.Cache' -Path ([string]$Configuration.Scoop.Cache)
    if (
        -not $Configuration.Scoop.ContainsKey('RehydrateOnRelocation') -or
        $Configuration.Scoop.RehydrateOnRelocation -isnot [bool]
    ) {
        throw 'Scoop.RehydrateOnRelocation must be a Boolean.'
    }
    if (
        -not $Configuration.Scoop.ContainsKey('Bootstrap') -or
        $Configuration.Scoop.Bootstrap -isnot [hashtable]
    ) {
        throw 'Scoop.Bootstrap must be a hashtable.'
    }
    $bootstrap = $Configuration.Scoop.Bootstrap
    if (-not $bootstrap.ContainsKey('Enabled') -or $bootstrap.Enabled -isnot [bool]) {
        throw 'Scoop.Bootstrap.Enabled must be a Boolean.'
    }
    if (-not $bootstrap.ContainsKey('GitDepth') -or [int]$bootstrap.GitDepth -le 0) {
        throw 'Scoop.Bootstrap.GitDepth must be a positive integer.'
    }
    foreach ($sourceName in @('Scoop', 'Main')) {
        if (-not $bootstrap.ContainsKey($sourceName) -or $bootstrap[$sourceName] -isnot [hashtable]) {
            throw "Scoop.Bootstrap.$sourceName must be a hashtable."
        }
        foreach ($fieldName in @('Repository', 'Branch', 'Archive')) {
            if (
                -not $bootstrap[$sourceName].ContainsKey($fieldName) -or
                [string]::IsNullOrWhiteSpace([string]$bootstrap[$sourceName][$fieldName])
            ) {
                throw "Scoop.Bootstrap.$sourceName.$fieldName must be a non-empty string."
            }
        }
    }

    if (
        -not $Configuration.Scoop.ContainsKey('ReplayHooks') -or
        $Configuration.Scoop.ReplayHooks -isnot [hashtable]
    ) {
        throw 'Scoop.ReplayHooks must be a hashtable.'
    }
    if (
        -not $Configuration.Scoop.ContainsKey('RelocationRepairs') -or
        $Configuration.Scoop.RelocationRepairs -isnot [hashtable]
    ) {
        throw 'Scoop.RelocationRepairs must be a hashtable.'
    }
    if (
        -not $Configuration.Scoop.ContainsKey('ShellOnlyLifecyclePolicy') -or
        $Configuration.Scoop.ShellOnlyLifecyclePolicy -isnot [hashtable]
    ) {
        throw 'Scoop.ShellOnlyLifecyclePolicy must be a hashtable.'
    }
    foreach ($fingerprint in $Configuration.Scoop.ShellOnlyLifecyclePolicy.Keys) {
        $fingerprintText = [string]$fingerprint
        if ($fingerprintText -notmatch '^[0-9a-fA-F]{64}$') {
            throw "Scoop.ShellOnlyLifecyclePolicy contains an invalid SHA-256 fingerprint: $fingerprintText"
        }
        $action = [string]$Configuration.Scoop.ShellOnlyLifecyclePolicy[$fingerprint]
        if ($action -notin @('Allow', 'Skip')) {
            throw "Scoop.ShellOnlyLifecyclePolicy action must be Allow or Skip for fingerprint $fingerprintText."
        }
    }
    foreach ($app in $Configuration.Scoop.ReplayHooks.Keys) {
        if ([string]::IsNullOrWhiteSpace([string]$app)) {
            throw 'Scoop.ReplayHooks contains an empty application name.'
        }
        [void](Split-CapsulenvScoopAppSelector -Selector ([string]$app))
        foreach ($hook in @($Configuration.Scoop.ReplayHooks[$app])) {
            if (([string]$hook) -notin @('pre_install', 'post_install')) {
                throw "Unsupported Scoop lifecycle hook '$hook' for '$app'."
            }
        }
    }

    foreach ($app in $Configuration.Scoop.RelocationRepairs.Keys) {
        $appName = [string]$app
        if ([string]::IsNullOrWhiteSpace($appName)) {
            throw 'Scoop.RelocationRepairs contains an empty application name.'
        }
        [void](Split-CapsulenvScoopAppSelector -Selector $appName)
        foreach ($rule in @($Configuration.Scoop.RelocationRepairs[$app])) {
            if ($rule -isnot [hashtable]) {
                throw "Scoop.RelocationRepairs rules for '$app' must be hashtables."
            }
            if (-not $rule.ContainsKey('Path') -or [string]::IsNullOrWhiteSpace([string]$rule.Path)) {
                throw "Scoop.RelocationRepairs rule for '$app' is missing Path."
            }
            if ([System.IO.Path]::IsPathRooted([string]$rule.Path)) {
                throw "Scoop.RelocationRepairs path for '$app' must be relative: $($rule.Path)"
            }
            $format = if ($rule.ContainsKey('Format')) { [string]$rule.Format } else { 'text' }
            if ($format -notin @('text', 'json')) {
                throw "Unsupported Scoop.RelocationRepairs format '$format' for '$app'."
            }
            if ($rule.ContainsKey('Required') -and $rule.Required -isnot [bool]) {
                throw "Scoop.RelocationRepairs.Required must be Boolean for '$app'."
            }
            if ($rule.ContainsKey('MaxBytes') -and [int64]$rule.MaxBytes -le 0) {
                throw "Scoop.RelocationRepairs.MaxBytes must be positive for '$app'."
            }
            if ($rule.ContainsKey('Processes')) {
                foreach ($processName in @($rule.Processes)) {
                    if ([string]::IsNullOrWhiteSpace([string]$processName)) {
                        throw "Scoop.RelocationRepairs.Processes contains an empty name for '$app'."
                    }
                }
            }
            if ([string]$rule.Path -match '[*?\[\]]') {
                throw "Scoop.RelocationRepairs paths do not support wildcards for '$app': $($rule.Path)"
            }
        }
    }

    if (-not $Configuration.UserIntegration.ContainsKey('DefaultBrowser')) {
        throw 'UserIntegration.DefaultBrowser is missing.'
    }
    $defaultBrowser = [string]$Configuration.UserIntegration.DefaultBrowser
    if (-not [string]::IsNullOrWhiteSpace($defaultBrowser)) {
        [void](Split-CapsulenvScoopAppSelector -Selector $defaultBrowser)
        [void](Get-CapsulenvBrowserDefinitionFromConfiguration -Configuration $Configuration -App $defaultBrowser)
    }

    foreach ($browserName in @($Configuration.Browsers.Keys)) {
        $browser = $Configuration.Browsers[$browserName]
        if ($browser -isnot [hashtable]) {
            throw "Browsers.$browserName must be a hashtable."
        }
        $browserApp = if ($browser.ContainsKey('App')) { [string]$browser.App } else { [string]$browserName }
        [void](Split-CapsulenvScoopAppSelector -Selector $browserApp)
        if (-not $browser.ContainsKey('ProfilePath') -or [string]::IsNullOrWhiteSpace([string]$browser.ProfilePath)) {
            throw "Browsers.$browserName.ProfilePath must be a non-empty path relative to the selected Scoop app persist root."
        }
        Assert-CapsulenvScoopIntegrationRelativePath -Name "Browsers.$browserName.ProfilePath" -Path ([string]$browser.ProfilePath)
        if (-not $browser.ContainsKey('ProfileArgument') -or [string]::IsNullOrWhiteSpace([string]$browser.ProfileArgument)) {
            throw "Browsers.$browserName.ProfileArgument must be a non-empty Gecko profile command-line argument."
        }
        if ($browser.ContainsKey('ExecutablePath') -and -not [string]::IsNullOrWhiteSpace([string]$browser.ExecutablePath)) {
            Assert-CapsulenvScoopIntegrationRelativePath -Name "Browsers.$browserName.ExecutablePath" -Path ([string]$browser.ExecutablePath)
        }
        if ($browser.ContainsKey('Enabled') -and $browser.Enabled -isnot [bool]) {
            throw "Browsers.$browserName.Enabled must be Boolean."
        }
    }

    if (
        -not $Configuration.Bitwarden.ContainsKey('Authorization') -or
        ([string]$Configuration.Bitwarden.Authorization) -notin @(
            'always',
            'never',
            'remember-until-lock'
        )
    ) {
        throw 'Bitwarden.Authorization must be always, never, or remember-until-lock.'
    }
    if (-not $Configuration.Bitwarden.ContainsKey('App') -or [string]::IsNullOrWhiteSpace([string]$Configuration.Bitwarden.App)) {
        throw 'Bitwarden.App must select an installed Scoop manifest.'
    }
    [void](Split-CapsulenvScoopAppSelector -Selector ([string]$Configuration.Bitwarden.App))
    if ($Configuration.Bitwarden.ContainsKey('StatePath') -and -not [string]::IsNullOrWhiteSpace([string]$Configuration.Bitwarden.StatePath)) {
        Assert-CapsulenvScoopIntegrationRelativePath -Name 'Bitwarden.StatePath' -Path ([string]$Configuration.Bitwarden.StatePath)
    }
    if ($Configuration.Bitwarden.ContainsKey('ExecutablePath') -and -not [string]::IsNullOrWhiteSpace([string]$Configuration.Bitwarden.ExecutablePath)) {
        Assert-CapsulenvScoopIntegrationRelativePath -Name 'Bitwarden.ExecutablePath' -Path ([string]$Configuration.Bitwarden.ExecutablePath)
    }

    foreach ($booleanName in @('Enabled', 'AutoConnect')) {
        if (-not $Configuration.SingBox.ContainsKey($booleanName) -or $Configuration.SingBox[$booleanName] -isnot [bool]) {
            throw "SingBox.$booleanName must be Boolean."
        }
    }
    if (-not $Configuration.SingBox.ContainsKey('App') -or [string]::IsNullOrWhiteSpace([string]$Configuration.SingBox.App)) {
        throw 'SingBox.App must select an installed Scoop manifest.'
    }
    [void](Split-CapsulenvScoopAppSelector -Selector ([string]$Configuration.SingBox.App))
    if ($Configuration.SingBox.ContainsKey('ExecutablePath') -and -not [string]::IsNullOrWhiteSpace([string]$Configuration.SingBox.ExecutablePath)) {
        Assert-CapsulenvScoopIntegrationRelativePath -Name 'SingBox.ExecutablePath' -Path ([string]$Configuration.SingBox.ExecutablePath)
    }
    $singBoxConfigPath = if ($Configuration.SingBox.ContainsKey('ConfigPath')) { [string]$Configuration.SingBox.ConfigPath } else { '' }
    $singBoxConfigDirectory = if ($Configuration.SingBox.ContainsKey('ConfigDirectory')) { [string]$Configuration.SingBox.ConfigDirectory } else { '' }
    if ([string]::IsNullOrWhiteSpace($singBoxConfigPath) -and [string]::IsNullOrWhiteSpace($singBoxConfigDirectory)) {
        throw 'SingBox must configure ConfigPath or ConfigDirectory.'
    }
    if (-not [string]::IsNullOrWhiteSpace($singBoxConfigPath)) {
        Assert-CapsulenvScoopIntegrationRelativePath -Name 'SingBox.ConfigPath' -Path $singBoxConfigPath
    }
    if (-not [string]::IsNullOrWhiteSpace($singBoxConfigDirectory)) {
        Assert-CapsulenvScoopIntegrationRelativePath -Name 'SingBox.ConfigDirectory' -Path $singBoxConfigDirectory
    }

    foreach ($name in @('PathVariables', 'Variables')) {
        if (
            -not $Configuration.Environment.ContainsKey($name) -or
            $Configuration.Environment[$name] -isnot [hashtable]
        ) {
            throw "Environment configuration value must be a hashtable: $name"
        }
    }
    foreach ($name in @('PathVariables', 'FileVariables', 'Variables')) {
        if (
            -not $Configuration.ToolStorage.ContainsKey($name) -or
            $Configuration.ToolStorage[$name] -isnot [hashtable]
        ) {
            throw "ToolStorage configuration value must be a hashtable: $name"
        }
    }
    if (-not $Configuration.Environment.ContainsKey('Path')) {
        throw 'Environment configuration value is missing: Path'
    }
    if (-not $Configuration.Environment.ContainsKey('ModulePath')) {
        throw 'Environment configuration value is missing: ModulePath'
    }
    foreach ($modulePathEntry in @($Configuration.Environment.ModulePath)) {
        if ([string]::IsNullOrWhiteSpace([string]$modulePathEntry)) {
            throw 'Environment.ModulePath contains an empty path.'
        }
        $expandedModulePath = [Environment]::ExpandEnvironmentVariables([string]$modulePathEntry)
        if ($expandedModulePath -match '(^|[\\/])\.\.([\\/]|$)') {
            throw "Environment.ModulePath must not traverse parents: $modulePathEntry"
        }
    }
    if (-not $Configuration.ToolStorage.ContainsKey('Enabled') -or $Configuration.ToolStorage.Enabled -isnot [bool]) {
        throw 'ToolStorage.Enabled must be Boolean.'
    }
    if (-not $Configuration.ToolStorage.ContainsKey('CreateDirectories') -or $Configuration.ToolStorage.CreateDirectories -isnot [bool]) {
        throw 'ToolStorage.CreateDirectories must be Boolean.'
    }
    foreach ($listName in @('Path', 'ProjectLinks')) {
        if (-not $Configuration.ToolStorage.ContainsKey($listName)) {
            throw "ToolStorage configuration value is missing: $listName"
        }
    }
    if ($Configuration.ToolStorage.ProjectLinks -isnot [hashtable]) {
        throw 'ToolStorage.ProjectLinks must be a hashtable.'
    }
    if (
        -not $Configuration.ToolStorage.ContainsKey('Relocation') -or
        $Configuration.ToolStorage.Relocation -isnot [hashtable]
    ) {
        throw 'ToolStorage.Relocation must be a hashtable.'
    }
    foreach ($booleanName in @('Enabled', 'AutoRepair')) {
        if (
            -not $Configuration.ToolStorage.Relocation.ContainsKey($booleanName) -or
            $Configuration.ToolStorage.Relocation[$booleanName] -isnot [bool]
        ) {
            throw "ToolStorage.Relocation.$booleanName must be Boolean."
        }
    }
    if (
        -not $Configuration.ToolStorage.Relocation.ContainsKey('Uv') -or
        $Configuration.ToolStorage.Relocation.Uv -isnot [hashtable]
    ) {
        throw 'ToolStorage.Relocation.Uv must be a hashtable.'
    }
    foreach ($booleanName in @('Enabled', 'RepairManagedPython', 'RepairGlobalTools')) {
        if (
            -not $Configuration.ToolStorage.Relocation.Uv.ContainsKey($booleanName) -or
            $Configuration.ToolStorage.Relocation.Uv[$booleanName] -isnot [bool]
        ) {
            throw "ToolStorage.Relocation.Uv.$booleanName must be Boolean."
        }
    }
    if (
        -not $Configuration.ToolStorage.Relocation.Uv.ContainsKey('App') -or
        [string]::IsNullOrWhiteSpace([string]$Configuration.ToolStorage.Relocation.Uv.App)
    ) {
        throw 'ToolStorage.Relocation.Uv.App must select a Scoop app manifest.'
    }
    [void](Split-CapsulenvScoopAppSelector -Selector ([string]$Configuration.ToolStorage.Relocation.Uv.App))
    if (
        $Configuration.ToolStorage.Relocation.Uv.ContainsKey('ExecutablePath') -and
        -not [string]::IsNullOrWhiteSpace([string]$Configuration.ToolStorage.Relocation.Uv.ExecutablePath)
    ) {
        Assert-CapsulenvScoopIntegrationRelativePath `
            -Name 'ToolStorage.Relocation.Uv.ExecutablePath' `
            -Path ([string]$Configuration.ToolStorage.Relocation.Uv.ExecutablePath)
    }
    foreach ($sectionName in @('Pixi', 'Workspaces')) {
        if (
            -not $Configuration.ToolStorage.Relocation.ContainsKey($sectionName) -or
            $Configuration.ToolStorage.Relocation[$sectionName] -isnot [hashtable]
        ) {
            throw "ToolStorage.Relocation.$sectionName must be a hashtable."
        }
    }
    foreach ($booleanName in @('Enabled', 'RepairGlobal')) {
        if (
            -not $Configuration.ToolStorage.Relocation.Pixi.ContainsKey($booleanName) -or
            $Configuration.ToolStorage.Relocation.Pixi[$booleanName] -isnot [bool]
        ) {
            throw "ToolStorage.Relocation.Pixi.$booleanName must be Boolean."
        }
    }
    if (
        -not $Configuration.ToolStorage.Relocation.Pixi.ContainsKey('App') -or
        [string]::IsNullOrWhiteSpace([string]$Configuration.ToolStorage.Relocation.Pixi.App)
    ) {
        throw 'ToolStorage.Relocation.Pixi.App must select a Scoop app manifest.'
    }
    [void](Split-CapsulenvScoopAppSelector -Selector ([string]$Configuration.ToolStorage.Relocation.Pixi.App))
    if (
        $Configuration.ToolStorage.Relocation.Pixi.ContainsKey('ExecutablePath') -and
        -not [string]::IsNullOrWhiteSpace([string]$Configuration.ToolStorage.Relocation.Pixi.ExecutablePath)
    ) {
        Assert-CapsulenvScoopIntegrationRelativePath `
            -Name 'ToolStorage.Relocation.Pixi.ExecutablePath' `
            -Path ([string]$Configuration.ToolStorage.Relocation.Pixi.ExecutablePath)
    }
    foreach ($booleanName in @('Enabled', 'RepairRegistered')) {
        if (
            -not $Configuration.ToolStorage.Relocation.Workspaces.ContainsKey($booleanName) -or
            $Configuration.ToolStorage.Relocation.Workspaces[$booleanName] -isnot [bool]
        ) {
            throw "ToolStorage.Relocation.Workspaces.$booleanName must be Boolean."
        }
    }
    foreach ($name in $Configuration.ToolStorage.PathVariables.Keys) {
        if ([string]::IsNullOrWhiteSpace([string]$name) -or ([string]$name).Contains('=')) {
            throw "ToolStorage contains an invalid environment variable name: $name"
        }
        Assert-CapsulenvPortableStoragePath `
            -Name ("PathVariables.{0}" -f $name) `
            -Path ([string]$Configuration.ToolStorage.PathVariables[$name])
    }
    foreach ($name in $Configuration.ToolStorage.FileVariables.Keys) {
        if ([string]::IsNullOrWhiteSpace([string]$name) -or ([string]$name).Contains('=')) {
            throw "ToolStorage contains an invalid environment variable name: $name"
        }
        Assert-CapsulenvPortableStoragePath `
            -Name ("FileVariables.{0}" -f $name) `
            -Path ([string]$Configuration.ToolStorage.FileVariables[$name])
    }
    foreach ($name in $Configuration.ToolStorage.Variables.Keys) {
        if ([string]::IsNullOrWhiteSpace([string]$name) -or ([string]$name).Contains('=')) {
            throw "ToolStorage contains an invalid environment variable name: $name"
        }
    }
    $toolPathIndex = 0
    foreach ($pathEntry in @($Configuration.ToolStorage.Path)) {
        Assert-CapsulenvPortableStoragePath `
            -Name ("Path[{0}]" -f $toolPathIndex) `
            -Path ([string]$pathEntry)
        $toolPathIndex++
    }
    foreach ($profileName in $Configuration.ToolStorage.ProjectLinks.Keys) {
        $profile = $Configuration.ToolStorage.ProjectLinks[$profileName]
        if ([string]::IsNullOrWhiteSpace([string]$profileName) -or $profile -isnot [hashtable]) {
            throw 'ToolStorage.ProjectLinks contains an invalid profile.'
        }
        foreach ($requiredName in @('Kind', 'ProjectPath', 'StorePath', 'LinkType')) {
            if (-not $profile.ContainsKey($requiredName) -or [string]::IsNullOrWhiteSpace([string]$profile[$requiredName])) {
                throw "ToolStorage.ProjectLinks.$profileName is missing $requiredName."
            }
        }
        if (([string]$profile.Kind) -notin @('Directory', 'File')) {
            throw "ToolStorage.ProjectLinks.$profileName.Kind must be Directory or File."
        }
        if (([string]$profile.LinkType) -notin @('Junction', 'SymbolicLink', 'HardLink')) {
            throw "ToolStorage.ProjectLinks.$profileName.LinkType is unsupported."
        }
        if (([string]$profile.Kind) -eq 'Directory' -and ([string]$profile.LinkType) -eq 'HardLink') {
            throw "ToolStorage.ProjectLinks.$profileName cannot use a directory hard link."
        }
        if (([string]$profile.Kind) -eq 'File' -and ([string]$profile.LinkType) -eq 'Junction') {
            throw "ToolStorage.ProjectLinks.$profileName cannot use a junction for a file."
        }
        foreach ($pathName in @('ProjectPath', 'StorePath')) {
            $pathValue = [string]$profile[$pathName]
            if ([System.IO.Path]::IsPathRooted($pathValue) -or $pathValue -match '(^|[\\/])\.\.([\\/]|$)') {
                throw "ToolStorage.ProjectLinks.$profileName.$pathName must remain relative and cannot traverse parents."
            }
        }
        $storePath = [string]$profile.StorePath
        foreach ($placeholder in [regex]::Matches($storePath, '\{[^}]+\}')) {
            if ($placeholder.Value -notin @('{ProjectId}', '{ProjectName}')) {
                throw "ToolStorage.ProjectLinks.$profileName.StorePath contains an unsupported placeholder: $($placeholder.Value)"
            }
        }
    }

    $reserved = @('CAPSULENV_ROOT', 'CAPSULENV_ID', 'CAPSULENV_SCRATCH', 'CAPSULENV_MODE', 'CAPSULENV_SCOOP_LIFECYCLE_POLICY', 'SCOOP', 'SCOOP_GLOBAL', 'SCOOP_CACHE', 'SSH_AUTH_SOCK', 'PATH')
    foreach ($name in @($Configuration.Environment.PathVariables.Keys) + @($Configuration.Environment.Variables.Keys)) {
        if ($reserved -contains [string]$name) {
            throw "Environment variable is managed by a dedicated capsulenv setting and cannot be overridden here: $name"
        }
    }
    foreach ($name in $Configuration.Environment.PathVariables.Keys) {
        if ($Configuration.Environment.Variables.ContainsKey($name)) {
            throw "Environment variable is declared as both a path and a literal value: $name"
        }
    }
    $toolStorageVariableNames = @(
        @($Configuration.ToolStorage.PathVariables.Keys) +
        @($Configuration.ToolStorage.FileVariables.Keys) +
        @($Configuration.ToolStorage.Variables.Keys)
    )
    foreach ($name in $toolStorageVariableNames) {
        if ($reserved -contains [string]$name) {
            throw "ToolStorage cannot override a dedicated capsulenv variable: $name"
        }
        if (
            $Configuration.Environment.PathVariables.ContainsKey($name) -or
            $Configuration.Environment.Variables.ContainsKey($name)
        ) {
            throw "Environment variable is declared by both ToolStorage and Environment: $name"
        }
    }
    $duplicates = @($toolStorageVariableNames | Group-Object | Where-Object { $_.Count -gt 1 })
    if ($duplicates.Count -gt 0) {
        throw "ToolStorage variable is declared in more than one storage class: $($duplicates[0].Name)"
    }
}

function Import-CapsulenvConfiguration {
    [CmdletBinding()]
    param([switch]$Refresh)

    if (-not $Refresh -and $null -ne $script:CapsulenvConfiguration) {
        return $script:CapsulenvConfiguration
    }

    $context = Get-CapsulenvContext
    if (-not (Test-Path -LiteralPath $context.ConfigPath -PathType Leaf)) {
        throw "Missing capsulenv configuration: $($context.ConfigPath)"
    }

    $configuration = Import-PowerShellDataFile -Path $context.ConfigPath
    if (Test-Path -LiteralPath $context.LocalConfigPath -PathType Leaf) {
        $local = Import-PowerShellDataFile -Path $context.LocalConfigPath
        $configuration = Merge-CapsulenvHashtable -Base $configuration -Override $local

        # Scoop repair maps are allow-lists and must be replaceable as one unit.
        # Empty local hashtables therefore disable their automatic behavior.
        if ($local.ContainsKey('Scoop') -and $local.Scoop -is [hashtable]) {
            foreach ($allowListName in @('ReplayHooks', 'RelocationRepairs', 'ShellOnlyLifecyclePolicy')) {
                if ($local.Scoop.ContainsKey($allowListName)) {
                    $configuration.Scoop[$allowListName] = $local.Scoop[$allowListName]
                }
            }
        }
        if (
            $local.ContainsKey('ToolStorage') -and
            $local.ToolStorage -is [hashtable] -and
            $local.ToolStorage.ContainsKey('ProjectLinks')
        ) {
            $configuration.ToolStorage.ProjectLinks = $local.ToolStorage.ProjectLinks
        }
    }

    if (-not $configuration.ContainsKey('SchemaVersion')) {
        throw 'Configuration is missing SchemaVersion.'
    }
    if ([int]$configuration.SchemaVersion -ne 11) {
        throw "Unsupported configuration schema: $($configuration.SchemaVersion)"
    }
    Assert-CapsulenvConfiguration -Configuration $configuration

    $script:CapsulenvConfiguration = $configuration
    return $script:CapsulenvConfiguration
}

function Get-CapsulenvConfiguration {
    [CmdletBinding()]
    param([switch]$Refresh)

    return Import-CapsulenvConfiguration -Refresh:$Refresh
}

function Get-CapsulenvConfigValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Path,
        $Default = $null
    )

    $value = Get-CapsulenvConfiguration
    foreach ($segment in $Path) {
        if ($value -isnot [hashtable] -or -not $value.ContainsKey($segment)) {
            return $Default
        }
        $value = $value[$segment]
    }
    return $value
}

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvConfiguration
