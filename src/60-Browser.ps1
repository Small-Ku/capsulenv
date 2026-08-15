function Get-CapsulenvBrowserDefinition {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$App)

    $configuration = Get-CapsulenvConfiguration
    try {
        return Get-CapsulenvBrowserDefinitionFromConfiguration -Configuration $configuration -App $App
    } catch {
        throw "No unambiguous Gecko browser integration is configured for Scoop app '$App'. Add one Browsers entry whose App value selects that installed manifest. $($_.Exception.Message)"
    }
}

function Get-CapsulenvBrowserDisplayName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [hashtable]$Definition
    )

    if ($null -eq $Definition) {
        $Definition = Get-CapsulenvBrowserDefinition -App $App
    }
    if (
        $Definition.ContainsKey('DisplayName') -and
        -not [string]::IsNullOrWhiteSpace([string]$Definition.DisplayName)
    ) {
        return [string]$Definition.DisplayName
    }
    $parsed = Split-CapsulenvScoopAppSelector -Selector $App
    return [string]$parsed.Name
}

function Test-CapsulenvPathUnderPortableScoop {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\/')
    } catch {
        return $false
    }
    foreach ($root in @((Get-CapsulenvScoopRoot), (Get-CapsulenvScoopGlobalRoot))) {
        $fullRoot = [System.IO.Path]::GetFullPath([string]$root).TrimEnd([char[]]'\/')
        if ([System.StringComparer]::OrdinalIgnoreCase.Equals($fullPath, $fullRoot)) {
            return $true
        }
        if (
            $fullPath.StartsWith(
                $fullRoot + [System.IO.Path]::DirectorySeparatorChar,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            return $true
        }
    }
    return $false
}

function Get-CapsulenvBrowserExecutable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$App)

    $definition = Get-CapsulenvBrowserDefinition -App $App
    $parameters = @{ App = $App }
    foreach ($pair in @(
        [pscustomobject]@{ Config = 'ExecutablePath'; Parameter = 'RelativePath' },
        [pscustomobject]@{ Config = 'BinName'; Parameter = 'BinName' },
        [pscustomobject]@{ Config = 'ShortcutName'; Parameter = 'ShortcutName' }
    )) {
        if (
            $definition.ContainsKey($pair.Config) -and
            -not [string]::IsNullOrWhiteSpace([string]$definition[$pair.Config])
        ) {
            $parameters[$pair.Parameter] = [string]$definition[$pair.Config]
        }
    }
    return Resolve-CapsulenvScoopAppExecutable @parameters
}

function Get-CapsulenvBrowserDefaultExecutable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$App)

    $definition = Get-CapsulenvBrowserDefinition -App $App
    if (
        $definition.ContainsKey('DefaultExecutablePath') -and
        -not [string]::IsNullOrWhiteSpace([string]$definition.DefaultExecutablePath)
    ) {
        return Resolve-CapsulenvScoopAppExecutable `
            -App $App `
            -RelativePath ([string]$definition.DefaultExecutablePath)
    }
    return Get-CapsulenvBrowserExecutable -App $App
}

function Get-CapsulenvHostBrowserExecutable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$App)

    if (-not (Test-CapsulenvWindows)) {
        return $null
    }
    $definition = Get-CapsulenvBrowserDefinition -App $App
    $hostCandidates = if ($definition.ContainsKey('HostExecutableCandidates')) { @($definition.HostExecutableCandidates) } else { @() }
    foreach ($candidate in $hostCandidates) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
            continue
        }
        $expanded = [Environment]::ExpandEnvironmentVariables([string]$candidate)
        if ($expanded -match '%[^%]+%') {
            continue
        }
        try { $resolved = [System.IO.Path]::GetFullPath($expanded) } catch { continue }
        if (
            (Test-Path -LiteralPath $resolved -PathType Leaf) -and
            -not (Test-CapsulenvPathUnderPortableScoop -Path $resolved)
        ) {
            return $resolved
        }
    }

    $hostAppPathNames = if ($definition.ContainsKey('HostAppPathNames')) { @($definition.HostAppPathNames) } else { @() }
    foreach ($name in $hostAppPathNames) {
        $subKey = 'Software\Microsoft\Windows\CurrentVersion\App Paths\{0}' -f [string]$name
        foreach ($hive in @('CurrentUser', 'LocalMachine')) {
            $appPath = Get-CapsulenvRegistryStringValue -Hive $hive -SubKey $subKey -Name ''
            if ([string]::IsNullOrWhiteSpace([string]$appPath)) {
                continue
            }
            try { $resolved = [System.IO.Path]::GetFullPath([string]$appPath) } catch { continue }
            if (
                (Test-Path -LiteralPath $resolved -PathType Leaf) -and
                -not (Test-CapsulenvPathUnderPortableScoop -Path $resolved)
            ) {
                return $resolved
            }
        }
    }

    $hostCommandNames = if ($definition.ContainsKey('HostCommandNames')) { @($definition.HostCommandNames) } else { @() }
    foreach ($name in $hostCommandNames) {
        foreach ($command in @(Get-Command $name -CommandType Application -All -ErrorAction SilentlyContinue)) {
            try { $source = [System.IO.Path]::GetFullPath([string]$command.Source) } catch { continue }
            if (
                (Test-Path -LiteralPath $source -PathType Leaf) -and
                -not (Test-CapsulenvPathUnderPortableScoop -Path $source)
            ) {
                return $source
            }
        }
    }
    return $null
}

function Get-CapsulenvBrowserProfilePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$App)

    $definition = Get-CapsulenvBrowserDefinition -App $App
    if (
        -not $definition.ContainsKey('ProfilePath') -or
        [string]::IsNullOrWhiteSpace([string]$definition.ProfilePath)
    ) {
        throw "Gecko browser integration for '$App' must declare ProfilePath relative to the Scoop app persist root."
    }
    $profile = Resolve-CapsulenvScoopAppRuntimePersistPath `
        -App $App `
        -RelativePath ([string]$definition.ProfilePath) `
        -AllowMissing
    if (Test-Path -LiteralPath $profile -PathType Container) {
        return $profile
    }
    return $null
}

function Test-CapsulenvBrowserProfileArgument {
    [CmdletBinding()]
    param([string[]]$Arguments = @())

    foreach ($argument in @($Arguments)) {
        if ([string]$argument -match '^(?i:-p|-profile|--profile)$') {
            return $true
        }
    }
    return $false
}

function ConvertTo-CapsulenvProcessArgument {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Argument)

    if (-not $Argument) {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashCount = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ([int]$character -eq 92) {
            $backslashCount++
            continue
        }
        if ($character -eq '"') {
            if ($backslashCount -gt 0) {
                [void]$builder.Append([string]::new([char]92, (($backslashCount * 2) + 1)))
            } else {
                [void]$builder.Append([char]92)
            }
            [void]$builder.Append('"')
            $backslashCount = 0
            continue
        }
        if ($backslashCount -gt 0) {
            [void]$builder.Append([string]::new([char]92, $backslashCount))
            $backslashCount = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashCount -gt 0) {
        [void]$builder.Append([string]::new([char]92, ($backslashCount * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Start-CapsulenvBrowser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [string[]]$Arguments = @(),
        [switch]$UseHostExecutable
    )

    [void](Set-CapsulenvSessionEnvironment)
    $definition = Get-CapsulenvBrowserDefinition -App $App
    $displayName = Get-CapsulenvBrowserDisplayName -App $App -Definition $definition
    if ($definition.ContainsKey('Enabled') -and -not [bool]$definition.Enabled) {
        throw "$displayName integration is disabled."
    }

    $executable = if ($UseHostExecutable) {
        Get-CapsulenvHostBrowserExecutable -App $App
    } else {
        Get-CapsulenvBrowserExecutable -App $App
    }
    if (-not $executable) {
        if ($UseHostExecutable) {
            throw "$displayName host executable was not found. --host never falls back to a different Gecko product or the capsule Scoop executable."
        }
        throw "$displayName executable was not found in the installed Scoop app '$App'."
    }

    $effectiveArguments = @($Arguments)
    $modeArguments = if (
        ($UseHostExecutable -or (Get-CapsulenvInstallMode) -eq 'ShellOnly') -and
        $definition.ContainsKey('ShellOnlyArguments')
    ) {
        @($definition.ShellOnlyArguments)
    } else {
        @()
    }
    if (-not (Test-CapsulenvBrowserProfileArgument -Arguments $effectiveArguments)) {
        $profilePath = Get-CapsulenvBrowserProfilePath -App $App
        if (-not $profilePath) {
            throw "$displayName Scoop-persisted profile was not found. Capsulenv browser commands never fall back to an unrelated host profile."
        }
        $profileArgument = if (
            $definition.ContainsKey('ProfileArgument') -and
            -not [string]::IsNullOrWhiteSpace([string]$definition.ProfileArgument)
        ) {
            [string]$definition.ProfileArgument
        } else {
            '-profile'
        }
        $effectiveArguments = @($profileArgument, $profilePath) + $effectiveArguments
    }
    foreach ($modeArgument in @($modeArguments)) {
        if ($effectiveArguments -notcontains [string]$modeArgument) {
            $effectiveArguments = @([string]$modeArgument) + $effectiveArguments
        }
    }

    if ($UseHostExecutable) {
        Write-CapsulenvMessage -Level Detail -Message "$displayName host executable will open the capsule-owned profile explicitly; Gecko profile compatibility remains the browser's responsibility."
    }
    $launchArguments = @($effectiveArguments | ForEach-Object { ConvertTo-CapsulenvProcessArgument -Argument $_ })
    $startParameters = @{
        FilePath = $executable
        WorkingDirectory = (Split-Path -Parent $executable)
    }
    if ($launchArguments.Count -gt 0) {
        $startParameters['ArgumentList'] = $launchArguments
    }
    [void](Start-Process @startParameters)
}

function Invoke-CapsulenvBrowserCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [string[]]$Arguments = @()
    )

    $remaining = @($Arguments)
    $useHost = $false
    if ($remaining.Count -gt 0 -and [string]$remaining[0] -eq '--host') {
        $useHost = $true
        $remaining = @($remaining | Select-Object -Skip 1)
    }
    if (@($remaining | Where-Object { [string]$_ -eq '--host' }).Count -gt 0) {
        throw 'Usage: browser <scoop-app> [--host] [browser arguments...] (--host must be the first browser argument)'
    }
    Start-CapsulenvBrowser -App $App -Arguments $remaining -UseHostExecutable:$useHost
}

##MOD_EXEC## Export-ModuleMember -Function Start-CapsulenvBrowser, Get-CapsulenvBrowserExecutable, Get-CapsulenvBrowserDefaultExecutable, Get-CapsulenvHostBrowserExecutable, Get-CapsulenvBrowserProfilePath
