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

    foreach ($sectionName in @('Scoop', 'Environment', 'ToolStorage', 'Bitwarden', 'Browsers')) {
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
    foreach ($app in $Configuration.Scoop.ReplayHooks.Keys) {
        if ([string]::IsNullOrWhiteSpace([string]$app)) {
            throw 'Scoop.ReplayHooks contains an empty application name.'
        }
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
        if ($appName -in @('.', '..') -or $appName.IndexOfAny([char[]]'\/') -ge 0) {
            throw "Scoop.RelocationRepairs app names must not contain path traversal: $appName"
        }
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

    $reserved = @('CAPSULENV_ROOT', 'CAPSULENV_ID', 'CAPSULENV_SCRATCH', 'SCOOP', 'SCOOP_GLOBAL', 'SCOOP_CACHE', 'SSH_AUTH_SOCK', 'PATH')
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
            foreach ($allowListName in @('ReplayHooks', 'RelocationRepairs')) {
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
    if ([int]$configuration.SchemaVersion -ne 9) {
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
