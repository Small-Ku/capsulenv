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

function Assert-CapsulenvConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Configuration)

    foreach ($sectionName in @('Scoop', 'Environment', 'Bitwarden', 'Browsers')) {
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
        -not $Configuration.Scoop.ContainsKey('RehydrateOnRelocation') -or
        $Configuration.Scoop.RehydrateOnRelocation -isnot [bool]
    ) {
        throw 'Scoop.RehydrateOnRelocation must be a Boolean.'
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

    $reserved = @('CAPSULENV_ROOT', 'SCOOP', 'SCOOP_GLOBAL', 'SSH_AUTH_SOCK')
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
    }

    if (-not $configuration.ContainsKey('SchemaVersion')) {
        throw 'Configuration is missing SchemaVersion.'
    }
    if ([int]$configuration.SchemaVersion -ne 3) {
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
