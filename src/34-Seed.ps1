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

function Get-CapsulenvHostScoopGlobalRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$HostRoot)

    $hostConfig = Join-Path $HostRoot 'config.json'
    if (Test-Path -LiteralPath $hostConfig -PathType Leaf) {
        try {
            $config = Get-Content -LiteralPath $hostConfig -Raw | ConvertFrom-Json
            foreach ($name in @('global_path', 'globalPath')) {
                $property = $config.PSObject.Properties[$name]
                if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                    return [System.IO.Path]::GetFullPath([string]$property.Value)
                }
            }
        } catch {
            # Fall back to environment/default discovery.
        }
    }

    $capsuleGlobal = [System.IO.Path]::GetFullPath((Get-CapsulenvScoopGlobalRoot)).TrimEnd('\', '/')
    foreach ($target in @('User', 'Machine', 'Process')) {
        try {
            $value = [Environment]::GetEnvironmentVariable('SCOOP_GLOBAL', $target)
            if ([string]::IsNullOrWhiteSpace($value)) {
                continue
            }
            $candidate = [System.IO.Path]::GetFullPath($value).TrimEnd('\', '/')
            if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($candidate, $capsuleGlobal)) {
                return $candidate
            }
        } catch {
            # Continue to the default path when this environment target is unavailable.
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        return [System.IO.Path]::GetFullPath((Join-Path $env:ProgramData 'scoop'))
    }
    return $null
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
                return [pscustomobject]@{
                    Root = $root
                    GlobalRoot = Get-CapsulenvHostScoopGlobalRoot -HostRoot $root
                    Command = $scoop
                }
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

function Get-CapsulenvSeedObjectValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Test-CapsulenvSeedAppIsGlobal {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$App)

    $globalValue = Get-CapsulenvSeedObjectValue -Object $App -Name 'Global'
    if ($null -ne $globalValue) {
        if ($globalValue -is [bool]) {
            return [bool]$globalValue
        }
        $globalText = [string]$globalValue
        if ($globalText -match '^(?i:true|false)$') {
            return [System.Convert]::ToBoolean($globalText)
        }
    }
    $info = [string](Get-CapsulenvSeedObjectValue -Object $App -Name 'Info')
    return ($info -match '(?i)global install')
}

function New-CapsulenvShellOnlyScoopSeedPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Inventory,
        [Parameter(Mandatory = $true)]$HostScoop
    )

    $apps = New-Object System.Collections.Generic.List[object]
    foreach ($app in @(Get-CapsulenvSeedObjectValue -Object $Inventory -Name 'apps')) {
        $name = [string](Get-CapsulenvSeedObjectValue -Object $app -Name 'Name')
        if ([string]::IsNullOrWhiteSpace($name) -or $name -eq 'scoop') {
            continue
        }
        $version = [string](Get-CapsulenvSeedObjectValue -Object $app -Name 'Version')
        $global = Test-CapsulenvSeedAppIsGlobal -App $app
        $sourceScopeRoot = if ($global) {
            [string](Get-CapsulenvSeedObjectValue -Object $HostScoop -Name 'GlobalRoot')
        } else {
            [string](Get-CapsulenvSeedObjectValue -Object $HostScoop -Name 'Root')
        }
        $destinationScopeRoot = if ($global) { Get-CapsulenvScoopGlobalRoot } else { Get-CapsulenvScoopRoot }
        $destinationAppRoot = Join-Path (Join-Path $destinationScopeRoot 'apps') $name
        $destinationReady = Test-Path -LiteralPath (Join-Path (Join-Path $destinationAppRoot 'current') 'manifest.json') -PathType Leaf
        if (-not $destinationReady -and (Test-Path -LiteralPath $destinationAppRoot -PathType Container)) {
            $destinationReady = $null -ne (
                Get-ChildItem -LiteralPath $destinationAppRoot -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ne 'current' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') -PathType Leaf) } |
                    Select-Object -First 1
            )
        }

        $sourceVersionPath = $null
        if (-not [string]::IsNullOrWhiteSpace($sourceScopeRoot)) {
            if (-not [string]::IsNullOrWhiteSpace($version)) {
                $candidate = Join-Path (Join-Path (Join-Path $sourceScopeRoot 'apps') $name) $version
                if (Test-Path -LiteralPath $candidate -PathType Container) {
                    $sourceVersionPath = $candidate
                }
            }
            if ($null -eq $sourceVersionPath) {
                $current = Join-Path (Join-Path (Join-Path $sourceScopeRoot 'apps') $name) 'current'
                if (Test-Path -LiteralPath $current -PathType Container) {
                    $manifestPath = Join-Path $current 'manifest.json'
                    if ([string]::IsNullOrWhiteSpace($version) -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                        try {
                            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
                            $version = [string]$manifest.version
                        } catch {}
                    }
                    if (-not [string]::IsNullOrWhiteSpace($version)) {
                        $candidate = Join-Path (Join-Path (Join-Path $sourceScopeRoot 'apps') $name) $version
                        if (Test-Path -LiteralPath $candidate -PathType Container) {
                            $sourceVersionPath = $candidate
                        }
                    }
                }
            }
        }

        $status = if ($destinationReady) {
            'AlreadyInstalled'
        } elseif ($null -eq $sourceVersionPath) {
            'MissingSource'
        } else {
            'Ready'
        }
        $apps.Add([pscustomobject]@{
            Name = $name
            Version = $version
            Global = $global
            Status = $status
            SourceScopeRoot = $sourceScopeRoot
            SourceVersionPath = $sourceVersionPath
            DestinationScopeRoot = $destinationScopeRoot
            DestinationAppRoot = $destinationAppRoot
        })
    }

    $buckets = New-Object System.Collections.Generic.List[object]
    foreach ($bucket in @(Get-CapsulenvSeedObjectValue -Object $Inventory -Name 'buckets')) {
        $name = [string](Get-CapsulenvSeedObjectValue -Object $bucket -Name 'Name')
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }
        $sourcePath = Join-Path (Join-Path ([string]$HostScoop.Root) 'buckets') $name
        $destinationPath = Join-Path (Join-Path (Get-CapsulenvScoopRoot) 'buckets') $name
        $status = if (Test-Path -LiteralPath $destinationPath -PathType Container) {
            'AlreadyPresent'
        } elseif (Test-Path -LiteralPath $sourcePath -PathType Container) {
            'Ready'
        } else {
            'MissingSource'
        }
        $buckets.Add([pscustomobject]@{
            Name = $name
            SourcePath = $sourcePath
            DestinationPath = $destinationPath
            Status = $status
        })
    }

    return [pscustomobject]@{
        Apps = $apps.ToArray()
        Buckets = $buckets.ToArray()
    }
}

function Copy-CapsulenvShellOnlyScoopSeedSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Inventory,
        [Parameter(Mandatory = $true)]$HostScoop
    )

    $plan = New-CapsulenvShellOnlyScoopSeedPlan -Inventory $Inventory -HostScoop $HostScoop
    $missingApps = @($plan.Apps | Where-Object { $_.Status -eq 'MissingSource' })
    if ($missingApps.Count -gt 0) {
        $summary = @($missingApps | ForEach-Object {
            $scope = if ($_.Global) { 'global' } else { 'user' }
            '{0}/{1}@{2}' -f $scope, $_.Name, $_.Version
        }) -join ', '
        throw "ShellOnly Scoop seed apply needs the original host Scoop app files so it can snapshot them without running package installers or hooks. Missing source app state: $summary"
    }

    [void](Set-CapsulenvSessionEnvironment)
    [void](Initialize-CapsulenvScoopBootstrap)

    $copiedBuckets = 0
    foreach ($bucket in @($plan.Buckets | Where-Object { $_.Status -eq 'Ready' })) {
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $bucket.DestinationPath) -Force)
        Copy-Item -LiteralPath $bucket.SourcePath -Destination $bucket.DestinationPath -Recurse -Force
        $copiedBuckets++
    }
    foreach ($bucket in @($plan.Buckets | Where-Object { $_.Status -eq 'MissingSource' })) {
        Write-CapsulenvMessage -Level Warning -Message "Scoop bucket '$($bucket.Name)' is not present in the source host and was not copied. Installed app snapshots remain usable, but future updates may require re-adding the bucket."
    }

    $copiedApps = New-Object System.Collections.Generic.List[string]
    foreach ($app in @($plan.Apps | Where-Object { $_.Status -eq 'Ready' })) {
        [void](New-Item -ItemType Directory -Path $app.DestinationAppRoot -Force)
        $destinationVersion = Join-Path $app.DestinationAppRoot ([string]$app.Version)
        if (Test-Path -LiteralPath $destinationVersion) {
            Remove-Item -LiteralPath $destinationVersion -Recurse -Force
        }
        Copy-Item -LiteralPath $app.SourceVersionPath -Destination $destinationVersion -Recurse -Force

        $sourcePersist = Join-Path (Join-Path ([string]$app.SourceScopeRoot) 'persist') ([string]$app.Name)
        $destinationPersist = Join-Path (Join-Path ([string]$app.DestinationScopeRoot) 'persist') ([string]$app.Name)
        if (
            (Test-Path -LiteralPath $sourcePersist -PathType Container) -and
            -not (Test-Path -LiteralPath $destinationPersist)
        ) {
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $destinationPersist) -Force)
            Copy-Item -LiteralPath $sourcePersist -Destination $destinationPersist -Recurse -Force
        }
        $scope = if ($app.Global) { 'global' } else { 'user' }
        $copiedApps.Add(('{0}/{1}' -f $scope, $app.Name))
    }

    if ($copiedApps.Count -gt 0) {
        # Rebuild every installed portable app in one pass so the helper can retain
        # its exact local/global scope tuples and replace copied host current/persist
        # links without executing package lifecycle hooks or user integration.
        [void](Reset-CapsulenvScoop -Apps @('*') -IntegrationMode ShellOnly -Quiet)
    }

    return [pscustomobject]@{
        Strategy = 'ShellOnlySnapshot'
        CopiedApps = $copiedApps.Count
        ExistingApps = @($plan.Apps | Where-Object { $_.Status -eq 'AlreadyInstalled' }).Count
        CopiedBuckets = $copiedBuckets
        MissingBuckets = @($plan.Buckets | Where-Object { $_.Status -eq 'MissingSource' }).Count
        Apps = $copiedApps.ToArray()
    }
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
    $applyStrategy = $null
    $applyResult = $null
    if ($Apply) {
        $mode = Get-CapsulenvInstallMode
        if ($mode -eq 'User') {
            [void](Set-CapsulenvSessionEnvironment)
            [void](Initialize-CapsulenvScoopBootstrap)
            [void](Invoke-CapsulenvScoopCommand -Arguments @('import', $destination))
            $applyStrategy = 'NativeImport'
        } else {
            if ($null -eq $hostScoop) {
                throw 'ShellOnly Scoop seed apply requires the original host Scoop installation to remain available. Re-run --apply on the source host so Capsulenv can snapshot installed app state without executing installers/hooks, or use User mode for native Scoop import.'
            }
            $inventory = Get-Content -LiteralPath $destination -Raw | ConvertFrom-Json
            $applyResult = Copy-CapsulenvShellOnlyScoopSeedSnapshot -Inventory $inventory -HostScoop $hostScoop
            $applyStrategy = [string]$applyResult.Strategy
        }
        $applied = $true
    }

    return [pscustomobject]@{
        Destination = $destination
        HostScoop = if ($null -ne $hostScoop) { [string]$hostScoop.Root } else { $null }
        Captured = $captured
        Applied = $applied
        ApplyStrategy = $applyStrategy
        ApplyResult = $applyResult
    }
}

##MOD_EXEC## Export-ModuleMember -Function Seed-CapsulenvPowerShellProfiles, Seed-CapsulenvGitConfig, Seed-CapsulenvScoopInventory
