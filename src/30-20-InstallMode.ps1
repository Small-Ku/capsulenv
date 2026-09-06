function Get-CapsulenvUserEnvironmentBackupPath {
    Move-CapsulenvLegacyUserIntegrationState
    return Join-Path (Get-CapsulenvUserIntegrationStateRoot) 'environment-backup.json'
}

function Get-CapsulenvInstallModeStatePath {
    Move-CapsulenvLegacyUserIntegrationState
    return Join-Path (Get-CapsulenvUserIntegrationStateRoot) 'install-mode.json'
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
        $schema = if ($null -ne $state.PSObject.Properties['SchemaVersion']) { [int]$state.SchemaVersion } else { 2 }
        if ($schema -notin @(2, 3) -or [string]$state.Mode -notin @('ShellOnly', 'User')) {
            return $null
        }
        if ($schema -ge 3) {
            $capsuleProperty = $state.PSObject.Properties['CapsuleId']
            if (
                $null -eq $capsuleProperty -or
                -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$capsuleProperty.Value, [string](Get-CapsulenvIdentity))
            ) {
                Write-CapsulenvMessage -Level Warning -Message 'Ignoring install-mode state that belongs to a different capsule identity.'
                return $null
            }
        }
        $hostProperty = $state.PSObject.Properties['HostIntegrationKey']
        if (
            $schema -ge 3 -and
            ($null -eq $hostProperty -or [string]$hostProperty.Value -ne [string](Get-CapsulenvHostIntegrationKey))
        ) {
            return $null
        }
        return $state
    } catch {
        return $null
    }
}

function Get-CapsulenvUserIntegrationMode {
    [CmdletBinding()]
    param()

    if (Test-CapsulenvWindows) {
        if (Test-CapsulenvCurrentUserIntegrationOwnership) {
            return 'User'
        }
        return 'ShellOnly'
    }

    $state = Get-CapsulenvInstallModeState
    if ($null -ne $state -and [string]$state.Mode -eq 'User') {
        return 'User'
    }
    return 'ShellOnly'
}

function Get-CapsulenvInstallMode {
    [CmdletBinding()]
    param()

    # Session mode is invocation-scoped. A new capsulenv.cmd process defaults to
    # ShellOnly even when this capsule owns persistent User integration on the
    # host. Commands launched from an explicit User shell inherit User through
    # this process-only variable.
    if ([string]$env:CAPSULENV_MODE -eq 'User') {
        return 'User'
    }
    return 'ShellOnly'
}

function Get-CapsulenvUserStartMenuShortcutRoot {
    [CmdletBinding()]
    param([switch]$Global)

    if (-not (Test-CapsulenvWindows)) {
        return $null
    }
    $identity = (Get-CapsulenvIdentity) -replace '[^0-9A-Fa-f]', ''
    if ($identity.Length -lt 12) {
        throw 'Capsule identity is invalid. User Start Menu ownership cannot be resolved.'
    }
    $folderName = if ($Global) { 'CommonStartMenu' } else { 'StartMenu' }
    $startMenu = [Environment]::GetFolderPath($folderName)
    if ([string]::IsNullOrWhiteSpace($startMenu)) {
        throw "Windows $folderName folder could not be resolved."
    }
    return [System.IO.Path]::Combine(
        $startMenu,
        'Programs',
        'Capsulenv Apps',
        $identity.Substring(0, 12).ToLowerInvariant()
    )
}

function Remove-CapsulenvUserStartMenuShortcuts {
    [CmdletBinding()]
    param()

    if (-not (Test-CapsulenvWindows)) {
        return
    }
    $userRoot = Get-CapsulenvUserStartMenuShortcutRoot
    $globalRoot = Get-CapsulenvUserStartMenuShortcutRoot -Global
    if ((Test-Path -LiteralPath $globalRoot -PathType Container) -and -not (Test-CapsulenvAdministrator)) {
        throw 'Capsulenv owns global Start Menu shortcuts on this host. Run restore-user from an elevated terminal so they can be removed safely.'
    }
    foreach ($root in @($userRoot, $globalRoot)) {
        if ([string]::IsNullOrWhiteSpace([string]$root) -or -not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }
        Remove-Item -LiteralPath $root -Recurse -Force
        $parent = Split-Path -Parent $root
        if (
            (Test-Path -LiteralPath $parent -PathType Container) -and
            $null -eq (Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
        ) {
            Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
        }
    }
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
            SchemaVersion = 3
            CapsuleId = (Get-CapsulenvIdentity)
            HostIntegrationKey = (Get-CapsulenvHostIntegrationKey)
            Mode = $Mode
            ManagedPathEntries = @($ManagedPathEntries | ForEach-Object { ConvertTo-CapsulenvStatePathReference -Path ([string]$_) })
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

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvInstallMode, Set-CapsulenvInstallMode
