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

    $pathEntries = New-Object System.Collections.Generic.List[string]
    $scoopShims = Join-Path $variables.SCOOP 'shims'
    $pathEntries.Add($scoopShims)
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

function Set-CapsulenvSessionEnvironment {
    [CmdletBinding()]
    param()

    $plan = Get-CapsulenvEnvironmentPlan
    $configuration = Get-CapsulenvConfiguration
    if ($configuration.ToolStorage.Enabled -and $configuration.ToolStorage.CreateDirectories) {
        [void](Initialize-CapsulenvToolStorage)
    }
    foreach ($name in $plan.Variables.Keys) {
        [Environment]::SetEnvironmentVariable($name, [string]$plan.Variables[$name], 'Process')
    }
    $env:PATH = Merge-CapsulenvPath -ExistingPath $env:PATH -Prepend $plan.PathEntries
    return $plan
}

function Get-CapsulenvUserEnvironmentBackupPath {
    $context = Get-CapsulenvContext
    return Join-Path $context.StateRoot 'user-environment-backup.json'
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

function Enable-CapsulenvUserEnvironment {
    [CmdletBinding()]
    param([switch]$Force)

    $context = Get-CapsulenvContext
    $backupPath = Get-CapsulenvUserEnvironmentBackupPath
    $backupExists = Test-Path -LiteralPath $backupPath -PathType Leaf
    if ($backupExists -and -not $Force) {
        throw "A user-environment backup already exists: $backupPath. Restore it first or pass -Force to reapply without replacing the original backup."
    }

    $plan = Set-CapsulenvSessionEnvironment
    $configuration = Get-CapsulenvConfiguration
    if (
        $configuration.Scoop.RehydrateOnRelocation -and
        (Test-CapsulenvScoopRehydrationRequired)
    ) {
        Invoke-CapsulenvScoopRehydrate
    }

    [void](New-Item -ItemType Directory -Path $context.StateRoot -Force)
    $names = @($plan.Variables.Keys) + 'PATH' | Sort-Object -Unique
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

    foreach ($name in $plan.Variables.Keys) {
        [Environment]::SetEnvironmentVariable($name, [string]$plan.Variables[$name], 'User')
    }
    $oldUserPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $newUserPath = Merge-CapsulenvPath -ExistingPath $oldUserPath -Prepend $plan.PathEntries
    [Environment]::SetEnvironmentVariable('PATH', $newUserPath, 'User')

    Write-CapsulenvMessage -Level Success -Message "User environment enabled. Backup: $backupPath"
}

function Restore-CapsulenvUserEnvironment {
    [CmdletBinding()]
    param()

    $backupPath = Get-CapsulenvUserEnvironmentBackupPath
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        throw "No user-environment backup exists: $backupPath"
    }

    $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
    foreach ($property in $backup.PSObject.Properties) {
        $entry = $property.Value
        $value = if ($entry.Exists) { [string]$entry.Value } else { $null }
        [Environment]::SetEnvironmentVariable($property.Name, $value, 'User')
    }
    Remove-Item -LiteralPath $backupPath -Force
    Write-CapsulenvMessage -Level Success -Message 'User environment restored from the original backup.'
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

##MOD_EXEC## Export-ModuleMember -Function Set-CapsulenvSessionEnvironment, Enable-CapsulenvUserEnvironment, Restore-CapsulenvUserEnvironment
