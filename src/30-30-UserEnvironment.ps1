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


function Get-CapsulenvManagedPathEntriesFromState {
    [CmdletBinding()]
    param(
        $State,
        $RelocationContext
    )

    if ($null -eq $State) {
        return @()
    }
    $managedProperty = $State.PSObject.Properties['ManagedPathEntries']
    if ($null -eq $managedProperty) {
        return @()
    }

    $referenceRoot = $null
    if ($null -ne $RelocationContext -and $RelocationContext.HasPathChanges) {
        foreach ($mapping in @($RelocationContext.PathMappings)) {
            if ([string]$mapping.Name -eq 'Root') {
                $referenceRoot = [string]$mapping.OldPath
                break
            }
        }
    }

    $result = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($managedProperty.Value)) {
        if ([string]::IsNullOrWhiteSpace([string]$entry)) {
            continue
        }
        $result.Add((Resolve-CapsulenvStatePathReference -Reference ([string]$entry) -CapsuleRoot $referenceRoot))
    }
    return $result.ToArray()
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
    $previousEntries = @(Get-CapsulenvManagedPathEntriesFromState -State $state -RelocationContext $RelocationContext)
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
    $foreignScoopShimPaths = @(Get-CapsulenvPersistentForeignScoopShimPaths -ExistingPath $userPath)
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
    param(
        [switch]$Force,
        [switch]$RefreshBackup
    )

    $context = Get-CapsulenvContext
    $backupPath = Get-CapsulenvUserEnvironmentBackupPath
    $backupExists = Test-Path -LiteralPath $backupPath -PathType Leaf
    $ledgerState = Get-CapsulenvInstallModeState
    $ledgerWasUser = ($backupExists -and $null -ne $ledgerState -and [string]$ledgerState.Mode -eq 'User')
    $currentMode = Get-CapsulenvUserIntegrationMode
    if ($currentMode -eq 'User' -and -not $backupExists) {
        throw "The current Windows user already points at this capsule, but its reversible environment backup is missing: $backupPath"
    }
    $alreadyUser = ($backupExists -and $currentMode -eq 'User')
    if ($backupExists -and -not $alreadyUser -and $ledgerWasUser -and -not $Force) {
        # A reset-on-shutdown host erased User environment integration while the
        # USB retained its host-scoped ledger. Treat a deliberate install-user
        # on that same host as a fresh takeover and snapshot the now-clean User
        # environment instead of demanding restore-user first.
        $RefreshBackup = $true
    }
    if ($backupExists -and -not $Force -and -not $RefreshBackup -and -not $alreadyUser) {
        throw "A user-environment backup already exists but this capsule is not recorded as the active User integration: $backupPath. Restore it first or pass -Force to reapply without replacing the original backup."
    }

    $plan = Set-CapsulenvSessionEnvironment -IntegrationMode User
    [void](Initialize-CapsulenvScoopBootstrap)
    $configuration = Get-CapsulenvConfiguration
    $rehydrationRequired = (
        $configuration.Scoop.RehydrateOnRelocation -and
        (Test-CapsulenvScoopRehydrationRequired)
    )

    [void](New-Item -ItemType Directory -Path $context.StateRoot -Force)
    $scoopPathEnvironmentVariable = Get-CapsulenvScoopPathEnvironmentVariable
    $names = @($plan.Variables.Keys) + @('PATH', $scoopPathEnvironmentVariable) | Sort-Object -Unique
    if (-not $backupExists -or ($RefreshBackup -and -not $alreadyUser)) {
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
    if (-not $rehydrationRequired) {
        Sync-CapsulenvPackageStartMenuShortcuts
    }
    Initialize-CapsulenvGitOpenSshSession
    if ($hadSessionGitIntent -and -not (Test-Path -LiteralPath (Get-CapsulenvGitConfigBackupPath) -PathType Leaf)) {
        Write-CapsulenvMessage -Level Warning -Message 'Bitwarden Git/OpenSSH was configured only for ShellOnly sessions. User mode does not silently promote optional Git integration; run `capsulenv.cmd bitwarden configure-git` if you want persistent User Git configuration.'
    }

    if ($rehydrationRequired) {
        Invoke-CapsulenvScoopRehydrate -IntegrationMode User
    }
    Sync-CapsulenvConfiguredDefaultBrowser
    Write-CapsulenvMessage -Level Success -Message $(if ($alreadyUser) { "User environment synchronized. Backup: $backupPath" } else { "User environment enabled. Backup: $backupPath" })
}

##MOD_EXEC## Export-ModuleMember -Function Install-CapsulenvUserEnvironment
