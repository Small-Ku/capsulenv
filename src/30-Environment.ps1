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

    $pathEntries = New-Object System.Collections.Generic.List[string]
    $scoopShims = Join-Path $variables.SCOOP 'shims'
    $pathEntries.Add($scoopShims)
    foreach ($entry in $configuration.Environment.Path) {
        $resolved = Resolve-CapsulenvPath -Path ([string]$entry) -AllowMissing
        if (-not ($pathEntries -contains $resolved)) {
            $pathEntries.Add($resolved)
        }
    }

    return [pscustomobject]@{
        Variables = $variables
        PathEntries = @($pathEntries)
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
        $normalized = $trimmed.TrimEnd('\')
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
    if (-not $backupExists) {
        $names = @($plan.Variables.Keys) + 'PATH' | Sort-Object -Unique
        $backup = [ordered]@{}
        foreach ($name in $names) {
            $value = [Environment]::GetEnvironmentVariable($name, 'User')
            $backup[$name] = [ordered]@{
                Exists = $null -ne $value
                Value = $value
            }
        }
        $backup | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $backupPath -Encoding UTF8
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
        & $shellPath -NoLogo -NoExit
        return
    }

    & $shellPath -NoLogo -Command $Command
    if ($null -ne $LASTEXITCODE) {
        $global:LASTEXITCODE = $LASTEXITCODE
    }
}

function Invoke-CapsulenvExternalCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @()
    )

    [void](Set-CapsulenvSessionEnvironment)
    Initialize-CapsulenvIntegrations
    & $Command @Arguments
    if ($null -ne $LASTEXITCODE) {
        $global:LASTEXITCODE = $LASTEXITCODE
    }
}

##MOD_EXEC## Export-ModuleMember -Function Set-CapsulenvSessionEnvironment, Enable-CapsulenvUserEnvironment, Restore-CapsulenvUserEnvironment
