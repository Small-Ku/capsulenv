function Get-CapsulenvEnvironmentPlan {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    $context = Get-CapsulenvContext
    $variables = [ordered]@{
        CAPSULENV_ROOT = $context.Root
        SCOOP = Resolve-CapsulenvPath -Path $configuration.Scoop.Root -AllowMissing
        XDG_CONFIG_HOME = Resolve-CapsulenvPath -Path $configuration.Scoop.ConfigHome -AllowMissing
    }

    if ($configuration.Bitwarden.Enabled) {
        $variables['BITWARDEN_APPDATA_DIR'] = Resolve-CapsulenvPath -Path $configuration.Bitwarden.AppDataDir -AllowMissing
        if ($configuration.Bitwarden.SetSshAuthSock) {
            $variables['SSH_AUTH_SOCK'] = '\\.\pipe\openssh-ssh-agent'
        }
    }

    foreach ($name in $configuration.Environment.PathVariables.Keys) {
        $variables[$name] = Resolve-CapsulenvPath `
            -Path ([string]$configuration.Environment.PathVariables[$name]) `
            -AllowMissing
    }
    foreach ($name in $configuration.Environment.Variables.Keys) {
        $value = [Environment]::ExpandEnvironmentVariables([string]$configuration.Environment.Variables[$name])
        $variables[$name] = $value
    }

    $pathEntries = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $configuration.Environment.Path) {
        $pathEntries.Add((Resolve-CapsulenvPath -Path ([string]$entry) -AllowMissing))
    }
    $scoopShims = Join-Path $variables.SCOOP 'shims'
    if (-not ($pathEntries -contains $scoopShims)) {
        $pathEntries.Insert(0, $scoopShims)
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
    [void](New-Item -ItemType Directory -Path $context.StateRoot -Force)
    $backupPath = Get-CapsulenvUserEnvironmentBackupPath
    $backupExists = Test-Path -LiteralPath $backupPath -PathType Leaf
    if ($backupExists -and -not $Force) {
        throw "A user-environment backup already exists: $backupPath. Restore it first or pass -Force to reapply without replacing the original backup."
    }

    $plan = Get-CapsulenvEnvironmentPlan
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
    [void](Set-CapsulenvSessionEnvironment)

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
