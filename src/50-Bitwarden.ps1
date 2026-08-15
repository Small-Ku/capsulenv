function Get-CapsulenvBitwardenDefinition {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    return $configuration.Bitwarden
}

function Get-CapsulenvBitwardenExecutable {
    [CmdletBinding()]
    param()

    $definition = Get-CapsulenvBitwardenDefinition
    $parameters = @{
        App = [string]$definition.App
    }
    foreach ($name in @('ExecutablePath', 'BinName', 'ShortcutName')) {
        if ($definition.ContainsKey($name) -and -not [string]::IsNullOrWhiteSpace([string]$definition[$name])) {
            $parameters[$name] = [string]$definition[$name]
        }
    }
    return Resolve-CapsulenvScoopAppExecutable @parameters
}

function Get-CapsulenvBitwardenProcesses {
    [CmdletBinding()]
    param([switch]$IncludeForeign)

    $definition = Get-CapsulenvBitwardenDefinition
    $processName = 'Bitwarden'
    try {
        $executable = Get-CapsulenvBitwardenExecutable
        if (-not [string]::IsNullOrWhiteSpace($executable)) {
            $processName = [System.IO.Path]::GetFileNameWithoutExtension($executable)
        }
    } catch {
        # The configured app may not be installed yet. We still inspect the
        # conventional process name so a host Bitwarden is never mistaken for
        # a capsule-owned process during activation.
    }

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($process in @(Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
        $path = $null
        try {
            $path = [string]$process.Path
        } catch {
            # If a process path cannot be inspected, it cannot be proven to
            # belong to this capsule and is therefore treated as foreign.
        }

        $owned = $false
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            try {
                $owned = Test-CapsulenvScoopAppOwnsPath -App ([string]$definition.App) -Path $path
            } catch {
                $owned = $false
            }
        }
        if ($owned -or $IncludeForeign) {
            $result.Add([pscustomobject]@{
                Process = $process
                Path = $path
                CapsuleOwned = $owned
            })
        }
    }
    return $result.ToArray()
}

function Assert-CapsulenvNoForeignBitwardenProcess {
    [CmdletBinding()]
    param()

    $foreign = @(
        Get-CapsulenvBitwardenProcesses -IncludeForeign |
            Where-Object { -not $_.CapsuleOwned }
    )
    if ($foreign.Count -eq 0) {
        return
    }
    $details = @(
        $foreign | ForEach-Object {
            if ([string]::IsNullOrWhiteSpace([string]$_.Path)) {
                "PID $($_.Process.Id) (path unavailable)"
            } else {
                "PID $($_.Process.Id): $($_.Path)"
            }
        }
    ) -join '; '
    throw "A non-capsule Bitwarden process is running. Capsulenv will not reuse, stop, or patch it: $details"
}

function Initialize-CapsulenvBitwarden {
    [CmdletBinding()]
    param([switch]$Start)

    $configuration = Get-CapsulenvConfiguration
    if (-not $configuration.Bitwarden.Enabled) {
        return
    }

    if ($configuration.Bitwarden.SetSshAuthSock) {
        [Environment]::SetEnvironmentVariable('SSH_AUTH_SOCK', '\\.\pipe\openssh-ssh-agent', 'Process')
    }
    Initialize-CapsulenvGitOpenSshSession

    if ($Start) {
        Start-CapsulenvBitwarden
        return
    }

    if ($configuration.Bitwarden.StartOnEnter) {
        $foreign = @(
            Get-CapsulenvBitwardenProcesses -IncludeForeign |
                Where-Object { -not $_.CapsuleOwned }
        )
        if ($foreign.Count -gt 0) {
            Write-CapsulenvMessage -Level Warning -Message 'Automatic capsule Bitwarden start skipped because a non-capsule Bitwarden process is already running. Close the host Bitwarden and run `capsulenv.cmd bitwarden start` if you want the capsule copy.'
            return
        }
        Start-CapsulenvBitwarden
    }
}

function Start-CapsulenvBitwarden {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    if (-not $configuration.Bitwarden.Enabled) {
        return
    }

    Assert-CapsulenvNoForeignBitwardenProcess
    $existing = @(Get-CapsulenvBitwardenProcesses)
    if ($existing.Count -gt 0) {
        Write-CapsulenvMessage -Level Detail -Message 'Capsule-owned Bitwarden desktop is already running.'
        return
    }

    try {
        $executable = Get-CapsulenvBitwardenExecutable
    } catch {
        Write-CapsulenvMessage -Level Warning -Message "Configured Bitwarden Scoop app '$($configuration.Bitwarden.App)' is unavailable: $($_.Exception.Message)"
        return
    }

    [void](Start-Process -FilePath $executable -WorkingDirectory (Split-Path -Parent $executable))
    Write-CapsulenvMessage -Level Success -Message 'Bitwarden desktop started from portable Scoop.'
}


function Stop-CapsulenvBitwarden {
    [CmdletBinding()]
    param([switch]$Force)

    Assert-CapsulenvNoForeignBitwardenProcess
    $processRecords = @(Get-CapsulenvBitwardenProcesses)
    if ($processRecords.Count -eq 0) {
        return
    }
    $processes = @($processRecords | ForEach-Object { $_.Process })

    foreach ($process in $processes) {
        try {
            [void]$process.CloseMainWindow()
        } catch {
            Write-CapsulenvMessage -Level Detail -Message "Unable to request a graceful Bitwarden shutdown: $($_.Exception.Message)"
        }
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    do {
        Start-Sleep -Milliseconds 200
        $remaining = @(
            Get-CapsulenvBitwardenProcesses | ForEach-Object { $_.Process }
        )
    } while ($remaining.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)

    if ($remaining.Count -gt 0) {
        if (-not $Force) {
            throw 'Bitwarden desktop is still running. Quit it from the system tray or rerun with a command that permits forced shutdown.'
        }
        $remaining | Stop-Process -Force
        Write-CapsulenvMessage -Level Warning -Message 'Bitwarden desktop was force-stopped so its persisted settings could be updated safely.'
    }
}

function Get-CapsulenvSshAgentServiceStatePath {
    $context = Get-CapsulenvContext
    return Join-Path $context.StateRoot 'bitwarden\ssh-agent-service.json'
}

function Disable-CapsulenvWindowsSshAgent {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if (-not (Test-CapsulenvWindows)) {
        throw 'The Windows OpenSSH Authentication Agent service exists only on Windows.'
    }
    if ((Get-CapsulenvInstallMode) -ne 'User') {
        throw 'ShellOnly mode cannot change the Windows ssh-agent service. Switch to User mode before changing machine/user integration.'
    }

    $service = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-CapsulenvMessage -Level Warning -Message 'Windows OpenSSH Authentication Agent service is not installed.'
        return
    }

    if (-not $PSCmdlet.ShouldProcess('ssh-agent', 'Stop and disable Windows OpenSSH Authentication Agent')) {
        return
    }

    $statePath = Get-CapsulenvSshAgentServiceStatePath
    if (-not (Test-Path -LiteralPath $statePath)) {
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force)
        $serviceInfo = Get-CimInstance Win32_Service -Filter "Name='ssh-agent'"
        [ordered]@{
            Status = [string]$service.Status
            StartMode = [string]$serviceInfo.StartMode
        } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    }

    if ($service.Status -ne 'Stopped') {
        Stop-Service -Name 'ssh-agent' -Force
    }
    Set-Service -Name 'ssh-agent' -StartupType Disabled
    Write-CapsulenvMessage -Level Success -Message 'Windows OpenSSH Authentication Agent disabled for Bitwarden SSH Agent.'
}

function Restore-CapsulenvWindowsSshAgent {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $statePath = Get-CapsulenvSshAgentServiceStatePath
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw 'No saved Windows ssh-agent service state exists.'
    }

    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $startupType = switch ([string]$state.StartMode) {
        'Auto' { 'Automatic' }
        'Manual' { 'Manual' }
        'Disabled' { 'Disabled' }
        default { 'Manual' }
    }

    if ($PSCmdlet.ShouldProcess('ssh-agent', "Restore startup type $startupType")) {
        Set-Service -Name 'ssh-agent' -StartupType $startupType
        if ($state.Status -eq 'Running') {
            Start-Service -Name 'ssh-agent'
        }
        Remove-Item -LiteralPath $statePath -Force
        Write-CapsulenvMessage -Level Success -Message 'Windows OpenSSH Authentication Agent service restored.'
    }
}

function Test-CapsulenvBitwardenSshAgent {
    [CmdletBinding()]
    param()

    [void](Set-CapsulenvSessionEnvironment)
    $sshAdd = Get-Command ssh-add.exe -CommandType Application -ErrorAction SilentlyContinue
    if (-not $sshAdd) {
        $sshAdd = Get-Command ssh-add -CommandType Application -ErrorAction SilentlyContinue
    }
    if (-not $sshAdd) {
        throw 'ssh-add was not found. Install the Windows OpenSSH client.'
    }

    Clear-CapsulenvLastExitCode
    $output = & $sshAdd.Source -L 2>&1
    $succeeded = $?
    $exitCode = Get-CapsulenvLastExitCode -Succeeded $succeeded
    [pscustomobject]@{
        Reachable = ($exitCode -eq 0 -or ($output -match 'no identities'))
        ExitCode = $exitCode
        Output = ($output -join [Environment]::NewLine)
    }
}

function Get-CapsulenvGitConfigBackupPath {
    $context = Get-CapsulenvContext
    return Join-Path $context.StateRoot 'bitwarden\git-ssh-config.json'
}

function Get-CapsulenvGitSessionConfigPath {
    $context = Get-CapsulenvContext
    return Join-Path $context.StateRoot 'bitwarden\git-ssh-session.json'
}

function Get-CapsulenvGitOpenSshPaths {
    [CmdletBinding()]
    param()

    $windowsDirectory = [Environment]::GetEnvironmentVariable('WINDIR')
    if ([string]::IsNullOrWhiteSpace($windowsDirectory)) {
        throw 'WINDIR is not set; Microsoft OpenSSH paths cannot be resolved.'
    }
    $openSshRoot = Join-Path $windowsDirectory 'System32\OpenSSH'
    $sshPath = Join-Path $openSshRoot 'ssh.exe'
    $sshKeygenPath = Join-Path $openSshRoot 'ssh-keygen.exe'
    if (-not (Test-Path -LiteralPath $sshPath -PathType Leaf)) {
        throw "Microsoft OpenSSH client was not found: $sshPath"
    }
    if (-not (Test-Path -LiteralPath $sshKeygenPath -PathType Leaf)) {
        throw "Microsoft OpenSSH ssh-keygen was not found: $sshKeygenPath"
    }
    return [pscustomobject]@{
        Ssh = ([System.IO.Path]::GetFullPath($sshPath) -replace '\\', '/')
        SshKeygen = ([System.IO.Path]::GetFullPath($sshKeygenPath) -replace '\\', '/')
    }
}

function Get-CapsulenvGitConfigEnvironmentCount {
    [CmdletBinding()]
    param()

    $raw = [Environment]::GetEnvironmentVariable('GIT_CONFIG_COUNT', 'Process')
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return 0
    }
    $count = 0
    if (-not [int]::TryParse($raw, [ref]$count) -or $count -lt 0) {
        throw "Invalid inherited GIT_CONFIG_COUNT: $raw"
    }
    return $count
}

function Clear-CapsulenvGitOpenSshSession {
    [CmdletBinding()]
    param()

    $baseRaw = [Environment]::GetEnvironmentVariable('CAPSULENV_GIT_CONFIG_BASE_COUNT', 'Process')
    if ([string]::IsNullOrWhiteSpace($baseRaw)) {
        return
    }
    $baseCount = 0
    if (-not [int]::TryParse($baseRaw, [ref]$baseCount) -or $baseCount -lt 0) {
        throw "Invalid CAPSULENV_GIT_CONFIG_BASE_COUNT: $baseRaw"
    }
    $currentCount = Get-CapsulenvGitConfigEnvironmentCount
    for ($index = $baseCount; $index -lt $currentCount; $index++) {
        [Environment]::SetEnvironmentVariable("GIT_CONFIG_KEY_$index", $null, 'Process')
        [Environment]::SetEnvironmentVariable("GIT_CONFIG_VALUE_$index", $null, 'Process')
    }

    $baseWasPresent = [Environment]::GetEnvironmentVariable('CAPSULENV_GIT_CONFIG_BASE_PRESENT', 'Process') -eq '1'
    if ($baseWasPresent) {
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', [string]$baseCount, 'Process')
    } else {
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', $null, 'Process')
    }
    [Environment]::SetEnvironmentVariable('CAPSULENV_GIT_CONFIG_BASE_COUNT', $null, 'Process')
    [Environment]::SetEnvironmentVariable('CAPSULENV_GIT_CONFIG_BASE_PRESENT', $null, 'Process')
}

function Set-CapsulenvGitOpenSshSession {
    [CmdletBinding()]
    param()

    Clear-CapsulenvGitOpenSshSession
    $paths = Get-CapsulenvGitOpenSshPaths
    $baseRaw = [Environment]::GetEnvironmentVariable('GIT_CONFIG_COUNT', 'Process')
    $basePresent = -not [string]::IsNullOrWhiteSpace($baseRaw)
    $baseCount = Get-CapsulenvGitConfigEnvironmentCount

    [Environment]::SetEnvironmentVariable('CAPSULENV_GIT_CONFIG_BASE_COUNT', [string]$baseCount, 'Process')
    [Environment]::SetEnvironmentVariable('CAPSULENV_GIT_CONFIG_BASE_PRESENT', $(if ($basePresent) { '1' } else { '0' }), 'Process')

    $entries = @(
        [pscustomobject]@{ Key = 'core.sshCommand'; Value = $paths.Ssh },
        [pscustomobject]@{ Key = 'gpg.ssh.program'; Value = $paths.SshKeygen }
    )
    $index = $baseCount
    foreach ($entry in $entries) {
        [Environment]::SetEnvironmentVariable("GIT_CONFIG_KEY_$index", [string]$entry.Key, 'Process')
        [Environment]::SetEnvironmentVariable("GIT_CONFIG_VALUE_$index", [string]$entry.Value, 'Process')
        $index++
    }
    [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', [string]$index, 'Process')
}

function Test-CapsulenvGitOpenSshSessionConfigured {
    [CmdletBinding()]
    param()

    return Test-Path -LiteralPath (Get-CapsulenvGitSessionConfigPath) -PathType Leaf
}

function Initialize-CapsulenvGitOpenSshSession {
    [CmdletBinding()]
    param()

    if ((Get-CapsulenvInstallMode) -ne 'ShellOnly') {
        Clear-CapsulenvGitOpenSshSession
        return
    }
    if (Test-CapsulenvGitOpenSshSessionConfigured) {
        Set-CapsulenvGitOpenSshSession
    } else {
        Clear-CapsulenvGitOpenSshSession
    }
}

function Set-CapsulenvGitOpenSshIntent {
    [CmdletBinding()]
    param()

    $path = Get-CapsulenvGitSessionConfigPath
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
    [ordered]@{
        SchemaVersion = 1
        EnabledAtUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
}

function Enable-CapsulenvGitOpenSshSession {
    [CmdletBinding()]
    param()

    Set-CapsulenvGitOpenSshSession
    try {
        Set-CapsulenvGitOpenSshIntent
    } catch {
        Clear-CapsulenvGitOpenSshSession
        throw
    }
}

function Disable-CapsulenvGitOpenSshSession {
    [CmdletBinding()]
    param()

    $path = Get-CapsulenvGitSessionConfigPath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force
    }
    Clear-CapsulenvGitOpenSshSession
}

function Get-CapsulenvGitCommand {
    [CmdletBinding()]
    param()

    $git = @(Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($git.Count -eq 0) {
        $git = @(Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    }
    if ($git.Count -eq 0) {
        throw 'Git was not found.'
    }
    return [string]$git[0].Source
}

function Restore-CapsulenvGitValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Git,
        [Parameter(Mandatory = $true)]$Backup
    )

    foreach ($property in $Backup.PSObject.Properties) {
        $entry = $property.Value
        if ($entry.Exists) {
            Clear-CapsulenvLastExitCode
            & $Git config --global --replace-all $property.Name ([string]$entry.Value)
            $exitCode = Get-CapsulenvLastExitCode -Succeeded $?
            if ($exitCode -ne 0) {
                throw "Failed to restore Git setting: $($property.Name)"
            }
        } else {
            Clear-CapsulenvLastExitCode
            & $Git config --global --unset-all $property.Name 2>$null
            $exitCode = Get-CapsulenvLastExitCode -Succeeded $?
            if ($exitCode -ne 0 -and $exitCode -ne 5) {
                throw "Failed to remove Git setting: $($property.Name)"
            }
        }
    }
}

function Set-CapsulenvGitOpenSsh {
    [CmdletBinding()]
    param([switch]$Force)

    $mode = Get-CapsulenvInstallMode
    if ($mode -eq 'ShellOnly') {
        [void](Get-CapsulenvGitOpenSshPaths)
        Enable-CapsulenvGitOpenSshSession
        Write-CapsulenvMessage -Level Success -Message 'Git uses Microsoft OpenSSH through a Capsulenv process-only config overlay; host global Git config is unchanged.'
        return
    }

    # User mode changes the storage scope (global Git config) and clears the
    # process overlay so Git sees a single effective value. Existing intent is
    # preserved; a new intent marker is committed only after Git config succeeds.
    Clear-CapsulenvGitOpenSshSession
    $git = Get-CapsulenvGitCommand
    $paths = Get-CapsulenvGitOpenSshPaths

    $intentExisted = Test-CapsulenvGitOpenSshSessionConfigured
    $backupPath = Get-CapsulenvGitConfigBackupPath
    $backupExists = Test-Path -LiteralPath $backupPath -PathType Leaf
    if ($backupExists -and -not $Force) {
        throw 'A Git SSH configuration backup already exists. Restore it first or pass -Force to reapply without replacing the original backup.'
    }

    if ($backupExists) {
        $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
    } else {
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force)
        $keys = @('core.sshCommand', 'gpg.ssh.program')
        $captured = [ordered]@{}
        foreach ($key in $keys) {
            Clear-CapsulenvLastExitCode
            $value = & $git config --global --get $key 2>$null
            $exitCode = Get-CapsulenvLastExitCode -Succeeded $?
            $captured[$key] = [ordered]@{
                Exists = ($exitCode -eq 0)
                Value = ($value -join [Environment]::NewLine)
            }
        }
        $captured | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $backupPath -Encoding UTF8
        $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
    }

    try {
        Clear-CapsulenvLastExitCode
        & $git config --global --replace-all core.sshCommand $paths.Ssh
        $exitCode = Get-CapsulenvLastExitCode -Succeeded $?
        if ($exitCode -ne 0) { throw 'Failed to set Git core.sshCommand.' }
        Clear-CapsulenvLastExitCode
        & $git config --global --replace-all gpg.ssh.program $paths.SshKeygen
        $exitCode = Get-CapsulenvLastExitCode -Succeeded $?
        if ($exitCode -ne 0) { throw 'Failed to set Git gpg.ssh.program.' }
        Set-CapsulenvGitOpenSshIntent
    } catch {
        $configurationError = $_
        try {
            Restore-CapsulenvGitValues -Git $git -Backup $backup
            if (-not $backupExists) {
                Remove-Item -LiteralPath $backupPath -Force
            }
            if (-not $intentExisted) {
                $intentPath = Get-CapsulenvGitSessionConfigPath
                if (Test-Path -LiteralPath $intentPath -PathType Leaf) {
                    Remove-Item -LiteralPath $intentPath -Force
                }
            }
        } catch {
            Write-Warning "Git configuration rollback failed; the original backup was retained at $backupPath. $($_.Exception.Message)"
        }
        throw $configurationError
    }

    Write-CapsulenvMessage -Level Success -Message 'Git global configuration now uses Microsoft OpenSSH for User-mode Bitwarden SSH Agent compatibility.'
}

function Restore-CapsulenvGitOpenSshGlobal {
    [CmdletBinding()]
    param([switch]$IfPresent)

    $backupPath = Get-CapsulenvGitConfigBackupPath
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        if ($IfPresent) {
            return $false
        }
        throw 'No Git global SSH configuration backup exists.'
    }
    $git = Get-CapsulenvGitCommand
    $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
    Restore-CapsulenvGitValues -Git $git -Backup $backup
    Remove-Item -LiteralPath $backupPath -Force
    Write-CapsulenvMessage -Level Success -Message 'Git global SSH configuration restored.'
    return $true
}

function Restore-CapsulenvGitOpenSsh {
    [CmdletBinding()]
    param()

    $restored = $false
    if (Test-CapsulenvGitOpenSshSessionConfigured) {
        Disable-CapsulenvGitOpenSshSession
        $restored = $true
        Write-CapsulenvMessage -Level Success -Message 'Capsulenv process-only Git SSH overlay and persisted OpenSSH intent disabled.'
    }
    if (Restore-CapsulenvGitOpenSshGlobal -IfPresent) {
        $restored = $true
    }
    if (-not $restored) {
        throw 'No Capsulenv Git SSH configuration exists.'
    }
}

##MOD_EXEC## Export-ModuleMember -Function Start-CapsulenvBitwarden, Stop-CapsulenvBitwarden, Disable-CapsulenvWindowsSshAgent, Restore-CapsulenvWindowsSshAgent, Test-CapsulenvBitwardenSshAgent, Set-CapsulenvGitOpenSsh, Restore-CapsulenvGitOpenSsh
