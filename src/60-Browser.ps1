function Get-CapsulenvBrowserDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Firefox', 'Zen', 'LibreWolf')]
        [string]$Browser
    )

    $configuration = Get-CapsulenvConfiguration
    $definition = $configuration.Browsers[$Browser]
    if ($null -eq $definition) {
        throw "Browser is not configured: $Browser"
    }
    return $definition
}

function Test-CapsulenvPathUnderPortableScoop {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\\/')
    } catch {
        return $false
    }
    foreach ($root in @((Get-CapsulenvScoopRoot), (Get-CapsulenvScoopGlobalRoot))) {
        $fullRoot = [System.IO.Path]::GetFullPath([string]$root).TrimEnd([char[]]'\\/')
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
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Firefox', 'Zen', 'LibreWolf')]
        [string]$Browser
    )

    $definition = Get-CapsulenvBrowserDefinition -Browser $Browser
    return Find-CapsulenvExecutable `
        -Candidates @($definition.ExecutableCandidates) `
        -CommandNames @($definition.CommandNames)
}

function Get-CapsulenvHostBrowserExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Firefox', 'Zen', 'LibreWolf')]
        [string]$Browser
    )

    if (-not (Test-CapsulenvWindows)) {
        return $null
    }
    $definition = Get-CapsulenvBrowserDefinition -Browser $Browser
    foreach ($candidate in @($definition.HostExecutableCandidates)) {
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

    foreach ($name in @($definition.HostAppPathNames)) {
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

    foreach ($name in @($definition.HostCommandNames)) {
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
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Firefox', 'Zen', 'LibreWolf')]
        [string]$Browser
    )

    $definition = Get-CapsulenvBrowserDefinition -Browser $Browser
    foreach ($candidate in @($definition.ProfileCandidates)) {
        $resolved = Resolve-CapsulenvPath -Path ([string]$candidate) -AllowMissing
        if (Test-Path -LiteralPath $resolved -PathType Container) {
            return $resolved
        }
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
        [Parameter(Mandatory = $true)]
        [ValidateSet('Firefox', 'Zen', 'LibreWolf')]
        [string]$Browser,
        [string[]]$Arguments = @(),
        [switch]$UseHostExecutable
    )

    [void](Set-CapsulenvSessionEnvironment)
    $definition = Get-CapsulenvBrowserDefinition -Browser $Browser
    if (-not $definition.Enabled) {
        throw "$Browser integration is disabled."
    }

    $executable = if ($UseHostExecutable) {
        Get-CapsulenvHostBrowserExecutable -Browser $Browser
    } else {
        Get-CapsulenvBrowserExecutable -Browser $Browser
    }
    if (-not $executable) {
        if ($UseHostExecutable) {
            throw "$Browser host executable was not found. --host never falls back to a different Gecko product or the capsule Scoop executable."
        }
        throw "$Browser executable was not found. Install it with Scoop or configure ExecutableCandidates."
    }

    $effectiveArguments = @($Arguments)
    $modeArguments = if ($UseHostExecutable -or (Get-CapsulenvInstallMode) -eq 'ShellOnly') {
        @($definition.ShellOnlyArguments)
    } else {
        @()
    }
    if (-not (Test-CapsulenvBrowserProfileArgument -Arguments $effectiveArguments)) {
        $profilePath = Get-CapsulenvBrowserProfilePath -Browser $Browser
        if (-not $profilePath) {
            throw "$Browser Scoop-persisted profile was not found. Capsulenv browser commands never fall back to an unrelated host profile."
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
        Write-CapsulenvMessage -Level Detail -Message "$Browser host executable will open the capsule-owned profile explicitly; Gecko profile compatibility remains the browser's responsibility."
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
        [Parameter(Mandatory = $true)]
        [ValidateSet('Firefox', 'Zen', 'LibreWolf')]
        [string]$Browser,
        [string[]]$Arguments = @()
    )

    $remaining = @($Arguments)
    $useHost = $false
    if ($remaining.Count -gt 0 -and [string]$remaining[0] -eq '--host') {
        $useHost = $true
        $remaining = if ($remaining.Count -gt 1) { @($remaining[1..($remaining.Count - 1)]) } else { @() }
    }
    if (@($remaining | Where-Object { [string]$_ -eq '--host' }).Count -gt 0) {
        throw "Usage: $($Browser.ToLowerInvariant()) [--host] [browser arguments...] (--host must be the first browser argument)"
    }
    Start-CapsulenvBrowser -Browser $Browser -Arguments $remaining -UseHostExecutable:$useHost
}

##MOD_EXEC## Export-ModuleMember -Function Start-CapsulenvBrowser, Get-CapsulenvBrowserExecutable, Get-CapsulenvHostBrowserExecutable, Get-CapsulenvBrowserProfilePath
