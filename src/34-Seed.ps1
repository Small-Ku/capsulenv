function Test-CapsulenvFileHasContent {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    return ((Get-Item -LiteralPath $Path).Length -gt 0)
}

function Copy-CapsulenvSeedFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$Force
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        return [pscustomobject]@{
            Source = $Source
            Destination = $Destination
            Status = 'MissingSource'
        }
    }
    if ((Test-CapsulenvFileHasContent -Path $Destination) -and -not $Force) {
        throw "Portable seed destination already contains data: $Destination. Pass --force to replace it."
    }

    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force)
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    return [pscustomobject]@{
        Source = $Source
        Destination = $Destination
        Status = 'Seeded'
    }
}

function Seed-CapsulenvPowerShellProfiles {
    [CmdletBinding()]
    param(
        [switch]$Force,
        [string]$CurrentUserAllHosts,
        [string]$CurrentUserCurrentHost
    )

    if ([string]::IsNullOrWhiteSpace($CurrentUserAllHosts)) {
        $CurrentUserAllHosts = [string]$PROFILE.CurrentUserAllHosts
    }
    if ([string]::IsNullOrWhiteSpace($CurrentUserCurrentHost)) {
        $CurrentUserCurrentHost = [string]$PROFILE.CurrentUserCurrentHost
    }

    $persist = Get-CapsulenvPowerShellPersistRoot
    [void](New-Item -ItemType Directory -Path $persist.PersistRoot -Force)
    $results = @(
        Copy-CapsulenvSeedFile `
            -Source $CurrentUserAllHosts `
            -Destination (Join-Path $persist.PersistRoot 'profile.ps1') `
            -Force:$Force
        Copy-CapsulenvSeedFile `
            -Source $CurrentUserCurrentHost `
            -Destination (Join-Path $persist.PersistRoot 'Microsoft.PowerShell_profile.ps1') `
            -Force:$Force
    )

    Write-CapsulenvMessage -Level Detail -Message 'PowerShell seed copies profile source verbatim. Review host-specific absolute paths and machine-only module imports after seeding.'
    return $results
}

function Get-CapsulenvSeedGitFilteredReason {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [switch]$IncludeSensitive
    )

    $normalized = $Key.ToLowerInvariant()
    if ($normalized -eq 'core.sshcommand' -or $normalized -eq 'gpg.ssh.program') {
        return 'Capsulenv-owned SSH integration'
    }
    if ($normalized.StartsWith('include.') -or $normalized.StartsWith('includeif.')) {
        return 'include directive flattened by Git query'
    }
    if (-not $IncludeSensitive) {
        if ($normalized.StartsWith('credential.')) {
            return 'credential setting'
        }
        if ($normalized -match '^http\..*\.extraheader$') {
            return 'HTTP extra header'
        }
    }
    return $null
}

function Invoke-CapsulenvGitGlobalConfigCapture {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Git)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Git
    $startInfo.Arguments = 'config --global --includes --null --list'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    foreach ($name in @($startInfo.EnvironmentVariables.Keys)) {
        $environmentName = [string]$name
        if (
            $environmentName -eq 'GIT_CONFIG_GLOBAL' -or
            $environmentName -eq 'GIT_CONFIG_COUNT' -or
            $environmentName -eq 'CAPSULENV_GIT_CONFIG_BASE_COUNT' -or
            $environmentName -eq 'CAPSULENV_GIT_CONFIG_BASE_PRESENT' -or
            $environmentName -like 'GIT_CONFIG_KEY_*' -or
            $environmentName -like 'GIT_CONFIG_VALUE_*'
        ) {
            $startInfo.EnvironmentVariables.Remove($environmentName)
        }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Failed to start Git while reading the host global configuration.'
    }
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "git config --global failed with exit code $($process.ExitCode): $stderr"
    }

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($record in @($stdout -split "`0")) {
        if ([string]::IsNullOrEmpty($record)) {
            continue
        }
        $separator = $record.IndexOf("`n")
        if ($separator -lt 0) {
            continue
        }
        $key = $record.Substring(0, $separator).TrimEnd("`r")
        $value = $record.Substring($separator + 1)
        if ([string]::IsNullOrWhiteSpace($key)) {
            continue
        }
        $entries.Add([pscustomobject]@{ Key = $key; Value = $value })
    }
    return $entries.ToArray()
}

function Seed-CapsulenvGitConfig {
    [CmdletBinding()]
    param(
        [switch]$Force,
        [switch]$IncludeSensitive
    )

    [void](Set-CapsulenvSessionEnvironment)
    $git = Get-CapsulenvGitCommand
    $destination = [string](Get-CapsulenvEnvironmentPlan).Variables.GIT_CONFIG_GLOBAL
    if ((Test-CapsulenvFileHasContent -Path $destination) -and -not $Force) {
        throw "Portable Git config already contains data: $destination. Pass --force to replace it."
    }

    $captured = @(Invoke-CapsulenvGitGlobalConfigCapture -Git $git)
    $filtered = New-Object System.Collections.Generic.List[object]
    $accepted = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $captured) {
        $reason = Get-CapsulenvSeedGitFilteredReason -Key ([string]$entry.Key) -IncludeSensitive:$IncludeSensitive
        if ($null -ne $reason) {
            $filtered.Add([pscustomobject]@{ Key = [string]$entry.Key; Reason = $reason })
        } else {
            $accepted.Add($entry)
        }
    }

    $parent = Split-Path -Parent $destination
    [void](New-Item -ItemType Directory -Path $parent -Force)
    $temporary = Join-Path $parent ('.git-config-seed-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($temporary, '')
        foreach ($entry in $accepted) {
            Clear-CapsulenvLastExitCode
            & $git config --file $temporary --add ([string]$entry.Key) ([string]$entry.Value)
            $exitCode = Get-CapsulenvLastExitCode -Succeeded $?
            if ($exitCode -ne 0) {
                throw "Failed to write portable Git setting: $($entry.Key)"
            }
        }
        Copy-Item -LiteralPath $temporary -Destination $destination -Force
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }

    return [pscustomobject]@{
        Destination = $destination
        Imported = $accepted.Count
        Filtered = $filtered.Count
        FilteredEntries = $filtered.ToArray()
    }
}

function Find-CapsulenvHostScoop {
    [CmdletBinding()]
    param()

    $capsuleRoots = @(
        [System.IO.Path]::GetFullPath((Get-CapsulenvScoopRoot)).TrimEnd('\', '/'),
        [System.IO.Path]::GetFullPath((Get-CapsulenvScoopGlobalRoot)).TrimEnd('\', '/')
    )
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($target in @('Process', 'User', 'Machine')) {
        try {
            $value = [Environment]::GetEnvironmentVariable('SCOOP', $target)
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $candidates.Add([string]$value)
            }
        } catch {
            # User/Machine environment targets are not available on every host.
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $candidates.Add((Join-Path $env:USERPROFILE 'scoop'))
    }

    $seen = @{}
    foreach ($candidate in $candidates) {
        try {
            $root = [System.IO.Path]::GetFullPath($candidate).TrimEnd('\', '/')
        } catch {
            continue
        }
        $key = $root.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true
        if ($capsuleRoots | Where-Object { [System.StringComparer]::OrdinalIgnoreCase.Equals($_, $root) }) {
            continue
        }
        foreach ($scoop in @(
            (Join-Path (Join-Path $root 'shims') 'scoop.ps1'),
            (Join-Path (Join-Path (Join-Path (Join-Path $root 'apps') 'scoop') 'current') 'bin\scoop.ps1')
        )) {
            if (Test-Path -LiteralPath $scoop -PathType Leaf) {
                return [pscustomobject]@{ Root = $root; Command = $scoop }
            }
        }
    }
    return $null
}

function Invoke-CapsulenvHostScoopExport {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$HostScoop)

    $names = @('SCOOP', 'SCOOP_GLOBAL', 'SCOOP_CACHE')
    $backup = @{}
    foreach ($name in $names) {
        $backup[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    try {
        [Environment]::SetEnvironmentVariable('SCOOP', [string]$HostScoop.Root, 'Process')
        foreach ($name in @('SCOOP_GLOBAL', 'SCOOP_CACHE')) {
            $userValue = $null
            try { $userValue = [Environment]::GetEnvironmentVariable($name, 'User') } catch {}
            [Environment]::SetEnvironmentVariable($name, $userValue, 'Process')
        }
        Clear-CapsulenvLastExitCode
        $output = & $HostScoop.Command export
        $exitCode = Get-CapsulenvLastExitCode -Succeeded $?
        if ($exitCode -ne 0) {
            throw "Host scoop export failed with exit code $exitCode"
        }
        $json = $output -join [Environment]::NewLine
        if ([string]::IsNullOrWhiteSpace($json)) {
            throw 'Host scoop export returned no JSON.'
        }
        return ($json | ConvertFrom-Json)
    } finally {
        foreach ($name in $names) {
            [Environment]::SetEnvironmentVariable($name, $backup[$name], 'Process')
        }
    }
}

function Save-CapsulenvScoopSeedInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Export,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$Force
    )

    if ((Test-CapsulenvFileHasContent -Path $Destination) -and -not $Force) {
        throw "Portable Scoop seed inventory already contains data: $Destination. Pass --force to replace it."
    }
    $sanitized = [ordered]@{}
    foreach ($name in @('apps', 'buckets')) {
        $property = $Export.PSObject.Properties[$name]
        if ($null -ne $property) {
            $sanitized[$name] = @($property.Value)
        }
    }
    if ($sanitized.Count -eq 0) {
        throw 'Host scoop export did not contain apps or buckets.'
    }

    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force)
    $json = $sanitized | ConvertTo-Json -Depth 10
    [void]($json | ConvertFrom-Json)
    [System.IO.File]::WriteAllText($Destination, $json, (New-Object System.Text.UTF8Encoding($true)))
    return $Destination
}

function Seed-CapsulenvScoopInventory {
    [CmdletBinding()]
    param(
        [switch]$Force,
        [switch]$Apply
    )

    $destination = Resolve-CapsulenvPath -Path 'tool-data\scoop\Scoopfile.json' -AllowMissing
    $hostScoop = Find-CapsulenvHostScoop
    $captured = $false
    if ($null -ne $hostScoop) {
        $export = Invoke-CapsulenvHostScoopExport -HostScoop $hostScoop
        [void](Save-CapsulenvScoopSeedInventory -Export $export -Destination $destination -Force:$Force)
        $captured = $true
    } elseif (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        throw 'No foreign host Scoop installation was found and no saved Scoop seed inventory exists.'
    }

    $applied = $false
    if ($Apply) {
        if ((Get-CapsulenvInstallMode) -ne 'User') {
            throw 'Applying a Scoop seed is User-mode only because native scoop import may create shortcuts, environment entries, and other package lifecycle integration.'
        }
        [void](Set-CapsulenvSessionEnvironment)
        [void](Initialize-CapsulenvScoopBootstrap)
        [void](Invoke-CapsulenvScoopCommand -Arguments @('import', $destination))
        $applied = $true
    }

    return [pscustomobject]@{
        Destination = $destination
        HostScoop = if ($null -ne $hostScoop) { [string]$hostScoop.Root } else { $null }
        Captured = $captured
        Applied = $applied
    }
}

##MOD_EXEC## Export-ModuleMember -Function Seed-CapsulenvPowerShellProfiles, Seed-CapsulenvGitConfig, Seed-CapsulenvScoopInventory
