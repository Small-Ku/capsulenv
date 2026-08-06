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
    foreach ($name in @('Root', 'ConfigHome')) {
        if (
            -not $Configuration.Scoop.ContainsKey($name) -or
            [string]::IsNullOrWhiteSpace([string]$Configuration.Scoop[$name])
        ) {
            throw "Scoop configuration value is missing: $name"
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

    $reserved = @(
        'CAPSULENV_ROOT',
        'SCOOP',
        'XDG_CONFIG_HOME',
        'BITWARDEN_APPDATA_DIR',
        'SSH_AUTH_SOCK'
    )
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
    }

    if (-not $configuration.ContainsKey('SchemaVersion')) {
        throw 'Configuration is missing SchemaVersion.'
    }
    if ([int]$configuration.SchemaVersion -ne 1) {
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
