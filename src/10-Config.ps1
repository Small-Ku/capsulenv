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

        # ReplayHooks is an allow-list and must be replaceable as one unit.
        # An empty local hashtable therefore disables all automatic hook replay.
        if (
            $local.ContainsKey('Scoop') -and
            $local.Scoop -is [hashtable] -and
            $local.Scoop.ContainsKey('ReplayHooks')
        ) {
            $configuration.Scoop.ReplayHooks = $local.Scoop.ReplayHooks
        }
    }

    if (-not $configuration.ContainsKey('SchemaVersion')) {
        throw 'Configuration is missing SchemaVersion.'
    }
    if ([int]$configuration.SchemaVersion -ne 2) {
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
