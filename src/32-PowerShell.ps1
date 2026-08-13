function Test-CapsulenvPortablePowerShellExecutable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
    } catch {
        return $false
    }
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals((Split-Path -Leaf $fullPath), 'pwsh.exe')) {
        return $false
    }

    foreach ($root in @((Get-CapsulenvScoopRoot), (Get-CapsulenvScoopGlobalRoot))) {
        $appRoot = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $root 'apps') 'pwsh')).TrimEnd('\', '/')
        $prefix = $appRoot + [System.IO.Path]::DirectorySeparatorChar
        if ($fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-CapsulenvPortablePowerShellProfilePaths {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ShellPath)

    if (-not (Test-CapsulenvPortablePowerShellExecutable -Path $ShellPath)) {
        return @()
    }

    $psHome = Split-Path -Parent ([System.IO.Path]::GetFullPath($ShellPath))
    $profiles = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('profile.ps1', 'Microsoft.PowerShell_profile.ps1')) {
        $candidate = Join-Path $psHome $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $profiles.Add($candidate)
        }
    }
    return $profiles.ToArray()
}

function ConvertTo-CapsulenvPowerShellSingleQuotedLiteral {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value)

    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-CapsulenvPowerShellHistoryStartupStatement {
    [CmdletBinding()]
    param()

    # PSReadLine has no environment variable for its history path. Keep its
    # mutable history on the capsule explicitly, without changing TEMP/TMP.
    return @'
if (-not [string]::IsNullOrWhiteSpace($env:CAPSULENV_PSREADLINE_HISTORY)) {
    $setHistory = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue
    if ($null -ne $setHistory) {
        Set-PSReadLineOption -HistorySavePath $env:CAPSULENV_PSREADLINE_HISTORY
    }
}
'@.Trim()
}

function Get-CapsulenvShellOnlyPowerShellStartupCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ShellPath)

    $statements = New-Object System.Collections.Generic.List[string]
    foreach ($profilePath in @(Get-CapsulenvPortablePowerShellProfilePaths -ShellPath $ShellPath)) {
        $literal = ConvertTo-CapsulenvPowerShellSingleQuotedLiteral -Value $profilePath
        $statements.Add(". $literal")
    }
    $statements.Add((Get-CapsulenvPowerShellHistoryStartupStatement))
    return '& { ' + ($statements -join '; ') + ' }'
}

function Get-CapsulenvPowerShellChildLaunchPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ShellPath,
        [ValidateSet('ShellOnly', 'User')][string]$IntegrationMode = (Get-CapsulenvInstallMode),
        [string]$Command
    )

    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add('-NoLogo')

    if ($IntegrationMode -eq 'ShellOnly') {
        $arguments.Add('-NoProfile')
    }
    if ([string]::IsNullOrWhiteSpace($Command)) {
        $arguments.Add('-NoExit')
    }
    $arguments.Add('-ExecutionPolicy')
    $arguments.Add('Bypass')

    if ($IntegrationMode -eq 'ShellOnly') {
        $startup = Get-CapsulenvShellOnlyPowerShellStartupCommand -ShellPath $ShellPath
        if (-not [string]::IsNullOrWhiteSpace($Command)) {
            $startup = $startup + '; ' + $Command
        }
        $arguments.Add('-Command')
        $arguments.Add($startup)
    } else {
        $startup = '& { ' + (Get-CapsulenvPowerShellHistoryStartupStatement) + ' }'
        if (-not [string]::IsNullOrWhiteSpace($Command)) {
            $startup = $startup + '; ' + $Command
        }
        $arguments.Add('-Command')
        $arguments.Add($startup)
    }

    return [pscustomobject]@{
        ShellPath = [System.IO.Path]::GetFullPath($ShellPath)
        IntegrationMode = $IntegrationMode
        Arguments = $arguments.ToArray()
        PortableProfiles = if ($IntegrationMode -eq 'ShellOnly') {
            @(Get-CapsulenvPortablePowerShellProfilePaths -ShellPath $ShellPath)
        } else {
            @()
        }
    }
}

function Get-CapsulenvPowerShellPersistRoot {
    [CmdletBinding()]
    param()

    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($scope in @(
        [pscustomobject]@{ Name = 'User'; Root = (Get-CapsulenvScoopRoot) },
        [pscustomobject]@{ Name = 'Global'; Root = (Get-CapsulenvScoopGlobalRoot) }
    )) {
        $current = Join-Path (Join-Path (Join-Path $scope.Root 'apps') 'pwsh') 'current'
        if (Test-Path -LiteralPath $current -PathType Container) {
            $matches.Add([pscustomobject]@{
                Scope = $scope.Name
                AppRoot = $current
                PersistRoot = Join-Path (Join-Path $scope.Root 'persist') 'pwsh'
            })
        }
    }

    if ($matches.Count -eq 0) {
        throw 'The capsule does not have Scoop pwsh installed. Install pwsh before seeding portable PowerShell profiles.'
    }
    if ($matches.Count -gt 1) {
        throw 'pwsh is installed in both local and portable-global Scoop roots. Remove one installation before seeding profiles so ownership is unambiguous.'
    }
    return $matches[0]
}

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvPowerShellChildLaunchPlan, Get-CapsulenvPortablePowerShellProfilePaths
