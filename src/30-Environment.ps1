function Get-CapsulenvEnvironmentPlan {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    $context = Get-CapsulenvContext
    $scoopRoot = Resolve-CapsulenvPath -Path $configuration.Scoop.Root -AllowMissing
    $scoopGlobalRoot = Resolve-CapsulenvPath -Path $configuration.Scoop.GlobalRoot -AllowMissing
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($scoopRoot, $scoopGlobalRoot)) {
        throw 'Scoop.Root and Scoop.GlobalRoot must resolve to different directories.'
    }

    $variables = [ordered]@{
        CAPSULENV_ROOT = $context.Root
        SCOOP = $scoopRoot
        SCOOP_GLOBAL = $scoopGlobalRoot
        SCOOP_CACHE = (Join-Path $scoopRoot 'cache')
    }

    if ($configuration.Bitwarden.Enabled -and $configuration.Bitwarden.SetSshAuthSock) {
        $variables['SSH_AUTH_SOCK'] = '\\.\pipe\openssh-ssh-agent'
    }

    foreach ($name in $configuration.Environment.PathVariables.Keys) {
        $variables[$name] = Resolve-CapsulenvPath `
            -Path ([string]$configuration.Environment.PathVariables[$name]) `
            -AllowMissing
    }
    foreach ($name in $configuration.Environment.Variables.Keys) {
        $variables[$name] = [Environment]::ExpandEnvironmentVariables(
            [string]$configuration.Environment.Variables[$name]
        )
    }

    $toolStorage = Get-CapsulenvToolStoragePlan
    foreach ($name in $toolStorage.Variables.Keys) {
        $variables[$name] = [string]$toolStorage.Variables[$name]
    }

    $modulePathEntries = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($configuration.Environment.ModulePath)) {
        $resolved = Resolve-CapsulenvPath -Path ([string]$entry) -AllowMissing
        if (-not ($modulePathEntries -contains $resolved)) {
            $modulePathEntries.Add($resolved)
        }
    }
    if ($modulePathEntries.Count -gt 0) {
        $variables['CAPSULENV_MODULE_ROOT'] = $modulePathEntries[0]
    }

    $pathEntries = New-Object System.Collections.Generic.List[string]
    foreach ($scoopShims in @(
        (Join-Path $variables.SCOOP 'shims'),
        (Join-Path $variables.SCOOP_GLOBAL 'shims')
    )) {
        if (-not ($pathEntries -contains $scoopShims)) {
            $pathEntries.Add($scoopShims)
        }
    }
    foreach ($entry in $configuration.Environment.Path) {
        $resolved = Resolve-CapsulenvPath -Path ([string]$entry) -AllowMissing
        if (-not ($pathEntries -contains $resolved)) {
            $pathEntries.Add($resolved)
        }
    }
    foreach ($entry in $toolStorage.PathEntries) {
        if (-not ($pathEntries -contains $entry)) {
            $pathEntries.Add($entry)
        }
    }

    return [pscustomobject]@{
        Variables = $variables
        PathEntries = $pathEntries.ToArray()
        ModulePathEntries = $modulePathEntries.ToArray()
        Directories = @($toolStorage.Directories)
    }
}

function Merge-CapsulenvPath {
    [CmdletBinding()]
    param(
        [string]$ExistingPath,
        [Parameter(Mandatory = $true)][string[]]$Prepend
    )

    $result = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($item in @($Prepend) + @($ExistingPath -split ';')) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            continue
        }
        $trimmed = $item.Trim()
        $normalized = $trimmed.TrimEnd([char[]]'\/')
        if (-not $seen.ContainsKey($normalized)) {
            $seen[$normalized] = $true
            $result.Add($trimmed)
        }
    }
    return ($result -join ';')
}

function Merge-CapsulenvModulePath {
    [CmdletBinding()]
    param(
        [string]$ExistingPath,
        [Parameter(Mandatory = $true)][string[]]$Prepend
    )

    $separator = [System.IO.Path]::PathSeparator
    $result = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($item in @($Prepend) + @($ExistingPath -split [regex]::Escape([string]$separator))) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            continue
        }
        $trimmed = $item.Trim()
        $normalized = $trimmed.TrimEnd([char[]]'\/')
        if (-not $seen.ContainsKey($normalized)) {
            $seen[$normalized] = $true
            $result.Add($trimmed)
        }
    }
    return ($result -join [string]$separator)
}

function Get-CapsulenvForeignScoopShimPaths {
    [CmdletBinding()]
    param()

    $capsuleRoots = @(
        ([System.IO.Path]::GetFullPath((Get-CapsulenvScoopRoot))).TrimEnd('\', '/'),
        ([System.IO.Path]::GetFullPath((Get-CapsulenvScoopGlobalRoot))).TrimEnd('\', '/')
    )
    $candidateRoots = New-Object System.Collections.Generic.List[string]
    $addCandidate = {
        param([AllowNull()][string]$Value)
        if ([string]::IsNullOrWhiteSpace($Value)) {
            return
        }
        try {
            $full = [System.IO.Path]::GetFullPath($Value).TrimEnd('\', '/')
        } catch {
            return
        }
        foreach ($capsuleRoot in $capsuleRoots) {
            if ([System.StringComparer]::OrdinalIgnoreCase.Equals($full, $capsuleRoot)) {
                return
            }
        }
        if (-not ($candidateRoots | Where-Object { [System.StringComparer]::OrdinalIgnoreCase.Equals($_, $full) })) {
            $candidateRoots.Add($full)
        }
    }

    foreach ($name in @('SCOOP', 'SCOOP_GLOBAL')) {
        foreach ($target in @('Process', 'User', 'Machine')) {
            try {
                & $addCandidate ([Environment]::GetEnvironmentVariable($name, $target))
            } catch {
                # User/Machine targets are not available on every test host.
            }
        }
    }

    $backupPath = Get-CapsulenvUserEnvironmentBackupPath
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        try {
            $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
            foreach ($name in @('SCOOP', 'SCOOP_GLOBAL')) {
                $property = $backup.PSObject.Properties[$name]
                if ($null -ne $property -and [bool]$property.Value.Exists) {
                    & $addCandidate ([string]$property.Value.Value)
                }
            }
        } catch {
            Write-CapsulenvMessage -Level Warning -Message "Ignoring unreadable User environment backup while isolating host Scoop shims: $($_.Exception.Message)"
        }
    }

    if (Test-CapsulenvWindows) {
        $userProfile = [Environment]::GetFolderPath('UserProfile')
        if (-not [string]::IsNullOrWhiteSpace($userProfile)) {
            & $addCandidate (Join-Path $userProfile 'scoop')
        }
        $programData = [Environment]::GetEnvironmentVariable('ProgramData', 'Process')
        if (-not [string]::IsNullOrWhiteSpace($programData)) {
            & $addCandidate (Join-Path $programData 'scoop')
        }
    }

    return @($candidateRoots | ForEach-Object { Join-Path $_ 'shims' })
}

function Set-CapsulenvSessionEnvironment {
    [CmdletBinding()]
    param()

    $plan = Get-CapsulenvEnvironmentPlan
    $configuration = Get-CapsulenvConfiguration
    if ($configuration.ToolStorage.Enabled -and $configuration.ToolStorage.CreateDirectories) {
        [void](Initialize-CapsulenvToolStorage)
    }
    foreach ($modulePathEntry in @($plan.ModulePathEntries)) {
        if (-not (Test-Path -LiteralPath $modulePathEntry -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $modulePathEntry -Force)
        }
    }
    $foreignScoopShimPaths = @(Get-CapsulenvForeignScoopShimPaths)
    foreach ($name in $plan.Variables.Keys) {
        [Environment]::SetEnvironmentVariable($name, [string]$plan.Variables[$name], 'Process')
    }
    $sessionPath = Remove-CapsulenvPathEntries `
        -ExistingPath $env:PATH `
        -Remove $foreignScoopShimPaths
    $env:PATH = Merge-CapsulenvPath -ExistingPath $sessionPath -Prepend $plan.PathEntries
    $env:PSModulePath = Merge-CapsulenvModulePath -ExistingPath $env:PSModulePath -Prepend $plan.ModulePathEntries
    return $plan
}

function Get-CapsulenvUserEnvironmentBackupPath {
    $context = Get-CapsulenvContext
    return Join-Path $context.StateRoot 'user-environment-backup.json'
}

function Get-CapsulenvInstallModeStatePath {
    $context = Get-CapsulenvContext
    return Join-Path $context.StateRoot 'install-mode.json'
}

function Get-CapsulenvInstallModeState {
    [CmdletBinding()]
    param()

    $statePath = Get-CapsulenvInstallModeStatePath
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $null
    }
    try {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ([string]$state.Mode -notin @('ShellOnly', 'User')) {
            return $null
        }
        return $state
    } catch {
        return $null
    }
}

function Get-CapsulenvInstallMode {
    [CmdletBinding()]
    param()

    $state = Get-CapsulenvInstallModeState
    if ($null -ne $state) {
        return [string]$state.Mode
    }
    if (Test-Path -LiteralPath (Get-CapsulenvUserEnvironmentBackupPath) -PathType Leaf) {
        return 'User'
    }
    return 'ShellOnly'
}

function Set-CapsulenvInstallMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('ShellOnly', 'User')]
        [string]$Mode,
        [string[]]$ManagedPathEntries = @()
    )

    $statePath = Get-CapsulenvInstallModeStatePath
    $parent = Split-Path -Parent $statePath
    [void](New-Item -ItemType Directory -Path $parent -Force)
    $temporary = Join-Path $parent ('.install-mode-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        [ordered]@{
            SchemaVersion = 2
            Mode = $Mode
            ManagedPathEntries = @($ManagedPathEntries)
            UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporary -Encoding UTF8
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            try {
                [System.IO.File]::Replace($temporary, $statePath, $null, $true)
            } catch {
                Remove-Item -LiteralPath $statePath -Force
                Move-Item -LiteralPath $temporary -Destination $statePath
            }
        } else {
            Move-Item -LiteralPath $temporary -Destination $statePath
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-CapsulenvPathEntries {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$ExistingPath,
        [string[]]$Remove = @()
    )

    $removeSet = @{}
    foreach ($entry in @($Remove)) {
        if ([string]::IsNullOrWhiteSpace([string]$entry)) {
            continue
        }
        $removeSet[[System.IO.Path]::GetFullPath([string]$entry).TrimEnd('\', '/').ToLowerInvariant()] = $true
    }
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @(([string]$ExistingPath) -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }
        $normalized = $null
        try {
            $normalized = [System.IO.Path]::GetFullPath($entry).TrimEnd('\', '/').ToLowerInvariant()
        } catch {
            $normalized = $entry.Trim().TrimEnd('\', '/').ToLowerInvariant()
        }
        if (-not $removeSet.ContainsKey($normalized)) {
            $kept.Add($entry)
        }
    }
    return ($kept -join ';')
}

function Get-CapsulenvScoopPathEnvironmentVariable {
    [CmdletBinding()]
    param()

    $configPath = Join-Path (Get-CapsulenvScoopRoot) 'config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return 'PATH'
    }
    try {
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $property = $config.PSObject.Properties['use_isolated_path']
        if ($null -eq $property) {
            return 'PATH'
        }
        $value = $property.Value
        if ($value -is [bool]) {
            if ($value) { return 'SCOOP_PATH' }
            return 'PATH'
        }
        if ($value -is [string] -and -not [string]::IsNullOrWhiteSpace($value)) {
            return ([string]$value).ToUpperInvariant()
        }
    } catch {
        Write-CapsulenvMessage -Level Warning -Message "Ignoring invalid Scoop use_isolated_path while synchronizing User environment: $($_.Exception.Message)"
    }
    return 'PATH'
}

function Get-CapsulenvRelocatedScoopPathEntries {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$ExistingPath,
        $RelocationContext
    )

    if ($null -eq $RelocationContext -or -not $RelocationContext.HasPathChanges) {
        return @()
    }
    $oldRoots = New-Object System.Collections.Generic.List[string]
    foreach ($mapping in @($RelocationContext.PathMappings)) {
        if ([string]$mapping.Name -notin @('ScoopRoot', 'ScoopGlobalRoot')) {
            continue
        }
        $oldRoots.Add(([System.IO.Path]::GetFullPath([string]$mapping.OldPath)).TrimEnd('\', '/'))
    }
    if ($oldRoots.Count -eq 0) {
        return @()
    }

    $matches = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @(([string]$ExistingPath) -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }
        $full = $null
        try {
            $full = [System.IO.Path]::GetFullPath($entry).TrimEnd('\', '/')
        } catch {
            continue
        }
        foreach ($root in $oldRoots) {
            if (
                [System.StringComparer]::OrdinalIgnoreCase.Equals($full, $root) -or
                $full.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
            ) {
                $matches.Add($entry)
                break
            }
        }
    }
    return $matches.ToArray()
}

function Ensure-CapsulenvUserEnvironmentBackupEntries {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Names)

    $backupPath = Get-CapsulenvUserEnvironmentBackupPath
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        throw "User mode cannot be synchronized without the original environment backup: $backupPath"
    }
    $existing = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
    $backup = [ordered]@{}
    foreach ($property in $existing.PSObject.Properties) {
        $backup[$property.Name] = [ordered]@{
            Exists = [bool]$property.Value.Exists
            Value = $property.Value.Value
        }
    }
    $changed = $false
    foreach ($name in @($Names | Sort-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace([string]$name) -or $backup.Contains($name)) {
            continue
        }
        $value = [Environment]::GetEnvironmentVariable($name, 'User')
        $backup[$name] = [ordered]@{
            Exists = $null -ne $value
            Value = $value
        }
        $changed = $true
    }
    if ($changed) {
        Write-CapsulenvUserEnvironmentBackup -Path $backupPath -Backup $backup
    }
}

function Sync-CapsulenvUserEnvironment {
    [CmdletBinding()]
    param($RelocationContext)

    $backupPath = Get-CapsulenvUserEnvironmentBackupPath
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        throw "User mode cannot be synchronized without the original environment backup: $backupPath"
    }
    $plan = Get-CapsulenvEnvironmentPlan
    $scoopPathEnvironmentVariable = Get-CapsulenvScoopPathEnvironmentVariable
    Ensure-CapsulenvUserEnvironmentBackupEntries `
        -Names (@($plan.Variables.Keys) + @('PATH', $scoopPathEnvironmentVariable))
    $state = Get-CapsulenvInstallModeState
    $previousEntries = @()
    if ($null -ne $state) {
        $managedProperty = $state.PSObject.Properties['ManagedPathEntries']
        if ($null -ne $managedProperty) {
            $previousEntries = @($managedProperty.Value | ForEach-Object { [string]$_ })
        }
    }
    if ($previousEntries.Count -eq 0 -and $null -ne $RelocationContext -and $RelocationContext.HasPathChanges) {
        $derived = New-Object System.Collections.Generic.List[string]
        foreach ($entry in @($plan.PathEntries)) {
            foreach ($mapping in @($RelocationContext.PathMappings)) {
                $newRoot = ([string]$mapping.NewPath).TrimEnd('\', '/')
                $oldRoot = ([string]$mapping.OldPath).TrimEnd('\', '/')
                if (
                    [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$entry, $newRoot) -or
                    ([string]$entry).StartsWith($newRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
                ) {
                    $suffix = ([string]$entry).Substring($newRoot.Length)
                    $derived.Add($oldRoot + $suffix)
                    break
                }
            }
        }
        $previousEntries = $derived.ToArray()
    }

    foreach ($name in $plan.Variables.Keys) {
        [Environment]::SetEnvironmentVariable($name, [string]$plan.Variables[$name], 'User')
    }
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $staleScoopPathEntries = @(Get-CapsulenvRelocatedScoopPathEntries `
        -ExistingPath $userPath `
        -RelocationContext $RelocationContext)
    $foreignScoopShimPaths = @(Get-CapsulenvForeignScoopShimPaths)
    $userPath = Remove-CapsulenvPathEntries `
        -ExistingPath $userPath `
        -Remove (@($previousEntries) + @($staleScoopPathEntries) + @($foreignScoopShimPaths))
    $userPath = Merge-CapsulenvPath -ExistingPath $userPath -Prepend $plan.PathEntries
    [Environment]::SetEnvironmentVariable('PATH', $userPath, 'User')

    if ($scoopPathEnvironmentVariable -ne 'PATH') {
        $isolatedPath = [Environment]::GetEnvironmentVariable($scoopPathEnvironmentVariable, 'User')
        $staleIsolatedEntries = @(Get-CapsulenvRelocatedScoopPathEntries `
            -ExistingPath $isolatedPath `
            -RelocationContext $RelocationContext)
        if ($staleIsolatedEntries.Count -gt 0) {
            $isolatedPath = Remove-CapsulenvPathEntries -ExistingPath $isolatedPath -Remove $staleIsolatedEntries
            [Environment]::SetEnvironmentVariable($scoopPathEnvironmentVariable, $isolatedPath, 'User')
        }
    }
    Set-CapsulenvInstallMode -Mode User -ManagedPathEntries $plan.PathEntries
    return $plan
}

function Write-CapsulenvUserEnvironmentBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Backup
    )

    $parent = Split-Path -Parent $Path
    [void](New-Item -ItemType Directory -Path $parent -Force)
    $temporary = Join-Path $parent ('.user-environment-backup-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        $Backup | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporary -Encoding UTF8
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                [System.IO.File]::Replace($temporary, $Path, $null, $true)
            } catch {
                $fallback = Join-Path $parent ('.user-environment-backup-{0}.rollback' -f [Guid]::NewGuid().ToString('N'))
                Move-Item -LiteralPath $Path -Destination $fallback
                try {
                    Move-Item -LiteralPath $temporary -Destination $Path
                    Remove-Item -LiteralPath $fallback -Force
                } catch {
                    if (Test-Path -LiteralPath $Path) {
                        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
                    }
                    Move-Item -LiteralPath $fallback -Destination $Path -ErrorAction SilentlyContinue
                    throw
                }
            }
        } else {
            Move-Item -LiteralPath $temporary -Destination $Path
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-CapsulenvUserEnvironment {
    [CmdletBinding()]
    param([switch]$Force)

    $context = Get-CapsulenvContext
    $backupPath = Get-CapsulenvUserEnvironmentBackupPath
    $backupExists = Test-Path -LiteralPath $backupPath -PathType Leaf
    if ($backupExists -and -not $Force) {
        throw "A user-environment backup already exists: $backupPath. Restore it first or pass -Force to reapply without replacing the original backup."
    }

    $plan = Set-CapsulenvSessionEnvironment
    [void](Initialize-CapsulenvScoopBootstrap)
    $configuration = Get-CapsulenvConfiguration
    $rehydrationRequired = (
        $configuration.Scoop.RehydrateOnRelocation -and
        (Test-CapsulenvScoopRehydrationRequired)
    )

    [void](New-Item -ItemType Directory -Path $context.StateRoot -Force)
    $scoopPathEnvironmentVariable = Get-CapsulenvScoopPathEnvironmentVariable
    $names = @($plan.Variables.Keys) + @('PATH', $scoopPathEnvironmentVariable) | Sort-Object -Unique
    if (-not $backupExists) {
        $backup = [ordered]@{}
        foreach ($name in $names) {
            $value = [Environment]::GetEnvironmentVariable($name, 'User')
            $backup[$name] = [ordered]@{
                Exists = $null -ne $value
                Value = $value
            }
        }
        Write-CapsulenvUserEnvironmentBackup -Path $backupPath -Backup $backup
    } elseif ($Force) {
        # Preserve the original snapshot while extending an older backup with
        # variables introduced by a newer capsulenv/configuration version.
        $existing = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
        $backup = [ordered]@{}
        foreach ($property in $existing.PSObject.Properties) {
            $backup[$property.Name] = [ordered]@{
                Exists = [bool]$property.Value.Exists
                Value = $property.Value.Value
            }
        }
        $backupChanged = $false
        foreach ($name in $names) {
            if ($backup.Contains($name)) {
                continue
            }
            $value = [Environment]::GetEnvironmentVariable($name, 'User')
            $backup[$name] = [ordered]@{
                Exists = $null -ne $value
                Value = $value
            }
            $backupChanged = $true
        }
        if ($backupChanged) {
            Write-CapsulenvUserEnvironmentBackup -Path $backupPath -Backup $backup
        }
    }

    $relocationContext = if ($rehydrationRequired) { Get-CapsulenvRelocationContext } else { $null }
    $hadSessionGitIntent = Test-CapsulenvGitOpenSshSessionConfigured
    [void](Sync-CapsulenvUserEnvironment -RelocationContext $relocationContext)
    Initialize-CapsulenvGitOpenSshSession
    if ($hadSessionGitIntent -and -not (Test-Path -LiteralPath (Get-CapsulenvGitConfigBackupPath) -PathType Leaf)) {
        Write-CapsulenvMessage -Level Warning -Message 'Bitwarden Git/OpenSSH was configured only for ShellOnly sessions. User mode does not silently promote optional Git integration; run `capsulenv.cmd bitwarden configure-git` if you want persistent User Git configuration.'
    }

    if ($rehydrationRequired) {
        Invoke-CapsulenvScoopRehydrate -IntegrationMode User
    }
    Write-CapsulenvMessage -Level Success -Message "User environment enabled. Backup: $backupPath"
}

function Enable-CapsulenvUserEnvironment {
    [CmdletBinding()]
    param([switch]$Force)

    Install-CapsulenvUserEnvironment -Force:$Force
}

function Restore-CapsulenvUserEnvironment {
    [CmdletBinding()]
    param()

    $backupPath = Get-CapsulenvUserEnvironmentBackupPath
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        throw "No user-environment backup exists: $backupPath"
    }

    $sshAgentStatePath = Get-CapsulenvSshAgentServiceStatePath
    if ((Test-Path -LiteralPath $sshAgentStatePath -PathType Leaf) -and -not (Test-CapsulenvAdministrator)) {
        throw 'User-mode Bitwarden setup changed the Windows ssh-agent service. Run restore-user from an elevated terminal so Capsulenv can restore that machine-level state before returning to ShellOnly.'
    }
    if (Test-Path -LiteralPath $sshAgentStatePath -PathType Leaf) {
        Restore-CapsulenvWindowsSshAgent -Confirm:$false
    }
    [void](Restore-CapsulenvGitOpenSshGlobal -IfPresent)

    $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
    foreach ($property in $backup.PSObject.Properties) {
        $entry = $property.Value
        $value = if ($entry.Exists) { [string]$entry.Value } else { $null }
        [Environment]::SetEnvironmentVariable($property.Name, $value, 'User')
    }
    Remove-Item -LiteralPath $backupPath -Force
    Set-CapsulenvInstallMode -Mode ShellOnly
    try {
        Initialize-CapsulenvGitOpenSshSession
    } catch {
        Write-CapsulenvMessage -Level Warning -Message "ShellOnly mode was restored, but the recorded Bitwarden Git/OpenSSH session intent could not be activated: $($_.Exception.Message)"
    }
    Write-CapsulenvMessage -Level Success -Message 'Capsulenv-owned User environment and reversible Bitwarden integrations restored; capsulenv is shell-only again.'
}

function Invoke-CapsulenvChildShell {
    [CmdletBinding()]
    param([string]$Command)

    [void](Set-CapsulenvSessionEnvironment)
    Initialize-CapsulenvIntegrations

    $shellPath = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrWhiteSpace($Command)) {
        Write-CapsulenvMessage -Level Success -Message "capsulenv active at $env:CAPSULENV_ROOT"
        & $shellPath -NoLogo -NoExit -ExecutionPolicy Bypass
        return
    }

    Clear-CapsulenvLastExitCode
    & $shellPath -NoLogo -ExecutionPolicy Bypass -Command $Command
    $succeeded = $?
    $global:LASTEXITCODE = Get-CapsulenvLastExitCode -Succeeded $succeeded
}

function Invoke-CapsulenvExternalCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @()
    )

    [void](Set-CapsulenvSessionEnvironment)
    Initialize-CapsulenvIntegrations
    Clear-CapsulenvLastExitCode
    & $Command @Arguments
    $succeeded = $?
    $global:LASTEXITCODE = Get-CapsulenvLastExitCode -Succeeded $succeeded
}

##MOD_EXEC## Export-ModuleMember -Function Set-CapsulenvSessionEnvironment, Get-CapsulenvInstallMode, Set-CapsulenvInstallMode, Install-CapsulenvUserEnvironment, Enable-CapsulenvUserEnvironment, Restore-CapsulenvUserEnvironment
