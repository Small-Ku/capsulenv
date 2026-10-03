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
    # Capsulenv will not reuse, stop, or patch it when the process is foreign.
    Write-CapsulenvMessage -Level Detail -Message "A foreign Bitwarden process is running; attach-only integration may reuse its SSH agent, but Capsulenv will not stop or patch it: $details"
    return $foreign
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

    $foreign = @(Assert-CapsulenvNoForeignBitwardenProcess)
    if ($foreign.Count -gt 0) {
        throw 'A non-capsule Bitwarden process is running; close it before starting the capsule copy.'
    }
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
    return Join-Path (Get-CapsulenvUserIntegrationStateRoot) 'bitwarden\ssh-agent-service.json'
}

function Get-CapsulenvBitwardenOwnershipSurface {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('Git', 'Service')][string]$Kind)
    if ($Kind -eq 'Git') { return 'git-global' }
    return 'windows-ssh-agent-service'
}

function New-CapsulenvBitwardenHostBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Values,
        [AllowNull()]$Applied = $null
    )
    $evidence = Get-CapsulenvHostIdentityEvidence
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        OwnershipId = [Guid]::NewGuid().ToString('N')
        CapsuleId = Get-CapsulenvIdentity
        HostIntegrationKey = Get-CapsulenvHostIntegrationKey
        MachineUser = [string]$evidence.MachineUser.Value
        WindowsGdid = [string]$evidence.WindowsGdid.Value
        Values = $Values
        Applied = $Applied
    }
}

function Write-CapsulenvBitwardenHostBackupDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Git', 'Service')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Reason
    )
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Write-CapsulenvMessage -Level Warning -Message "Unattributed Bitwarden $Kind backup preserved; it grants no current-host ownership and cannot be restored automatically: $Path. $Reason"
    }
}

function Read-CapsulenvBitwardenHostBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Git', 'Service')][string]$Kind
    )
    $record = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    Assert-CapsulenvUserIntegrationIdentity -Record $record
    if ([string]::IsNullOrWhiteSpace([string]$record.OwnershipId)) { throw "Bitwarden $Kind backup is missing its ownership id: $Path" }
    $values = $record.Values
    if ($Kind -eq 'Git') {
        $keys = @('core.sshCommand', 'gpg.ssh.program')
        if (@($values.PSObject.Properties).Count -ne $keys.Count) { throw "Invalid Git SSH backup values: $Path" }
        foreach ($key in $keys) {
            $entry = $values.PSObject.Properties[$key]
            if ($null -eq $entry -or $entry.Value.Exists -isnot [bool] -or $entry.Value.Value -isnot [string]) {
                throw "Invalid Git SSH backup value for $($key): $Path"
            }
        }
    } elseif ([string]$values.StartMode -notin @('Auto', 'Manual', 'Disabled') -or [string]$values.Status -notin @('Running', 'Stopped')) {
        throw "Invalid Windows ssh-agent service backup values: $Path"
    }
    return $record
}

function Get-CapsulenvBitwardenOwnedHostBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Git', 'Service')][string]$Kind
    )
    $surface = Get-CapsulenvBitwardenOwnershipSurface -Kind $Kind
    $marker = Read-CapsulenvPersistentUserIntegrationMarker -Surface $surface
    if ($null -eq $marker) { throw "No current-host ownership marker exists for the Bitwarden $Kind backup." }
    $record = Read-CapsulenvBitwardenHostBackup -Path $Path -Kind $Kind
    if ([string]$marker.Token -ne [string]$record.OwnershipId) { throw "Bitwarden $Kind backup does not match the current-host ownership marker." }
    return [pscustomobject]@{ Record = $record; Marker = $marker }
}

function Get-CapsulenvWindowsSshAgentLiveState {
    [CmdletBinding()]
    param()

    $service = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
    if ($null -eq $service) { return $null }
    $serviceInfo = Get-CimInstance Win32_Service -Filter "Name='ssh-agent'"
    return [pscustomobject]@{
        Status = [string]$service.Status
        StartMode = [string]$serviceInfo.StartMode
    }
}

function Get-CapsulenvWindowsSshAgentBackupClassification {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $record = Read-CapsulenvBitwardenHostBackup -Path $Path -Kind Service
    } catch {
        return [pscustomobject]@{ State = 'ForeignOrInvalid'; Record = $null; Current = $null; Diagnostic = $_.Exception.Message }
    }
    $current = Get-CapsulenvWindowsSshAgentLiveState
    if ($null -eq $current) {
        return [pscustomobject]@{ State = 'AlreadyRestored'; Record = $record; Current = $null; Diagnostic = 'ssh-agent service is absent on this host incarnation.' }
    }

    $before = $record.Values
    $applied = if ($null -ne $record.PSObject.Properties['Applied'] -and $null -ne $record.Applied) {
        $record.Applied
    } else {
        [pscustomobject]@{ Status = 'Stopped'; StartMode = 'Disabled' }
    }
    $statusBefore = [string]$current.Status -eq [string]$before.Status
    $modeBefore = [string]$current.StartMode -eq [string]$before.StartMode
    if ($statusBefore -and $modeBefore) {
        return [pscustomobject]@{ State = 'AlreadyRestored'; Record = $record; Current = $current; Diagnostic = '' }
    }

    $statusOwned = [string]$current.Status -in @([string]$before.Status, [string]$applied.Status)
    $modeOwned = [string]$current.StartMode -in @([string]$before.StartMode, [string]$applied.StartMode)
    if ($statusOwned -and $modeOwned) {
        return [pscustomobject]@{ State = 'OwnedOrPartial'; Record = $record; Current = $current; Diagnostic = '' }
    }
    return [pscustomobject]@{ State = 'Ambiguous'; Record = $record; Current = $current; Diagnostic = 'ssh-agent service contains values outside both the saved before-state and Capsulenv applied-state.' }
}

function Test-CapsulenvBitwardenHostBackupOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Git', 'Service')][string]$Kind
    )
    $surface = Get-CapsulenvBitwardenOwnershipSurface -Kind $Kind
    $markerPath = Get-CapsulenvPersistentUserIntegrationMarkerPath -Surface $surface
    $markerExists = Test-Path -LiteralPath $markerPath -PathType Leaf
    if (-not $markerExists) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
        if ($Kind -eq 'Service') {
            $classification = Get-CapsulenvWindowsSshAgentBackupClassification -Path $Path
            if ($classification.State -in @('AlreadyRestored', 'ForeignOrInvalid')) {
                Write-CapsulenvBitwardenHostBackupDiagnostic -Path $Path -Kind $Kind -Reason $(if ($classification.Diagnostic) { $classification.Diagnostic } else { 'The service is already back at its saved before-state.' })
                return $false
            }
            Write-CapsulenvMessage -Level Warning -Message "Windows ssh-agent portable recovery evidence remains unresolved after its host-local marker disappeared; ownership remains fail-closed. $($classification.Diagnostic)"
            return $true
        }
        Write-CapsulenvBitwardenHostBackupDiagnostic -Path $Path -Kind $Kind -Reason 'The host-local mutation marker is absent.'
        return $false
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-CapsulenvMessage -Level Warning -Message "Persistent Bitwarden $Kind ownership marker exists but its portable backup is missing; ownership remains fail-closed: $markerPath"
        return $true
    }
    try {
        [void](Get-CapsulenvBitwardenOwnedHostBackup -Path $Path -Kind $Kind)
        return $true
    } catch {
        Write-CapsulenvMessage -Level Warning -Message "Persistent Bitwarden $Kind ownership is incomplete or invalid and remains fail-closed: $($_.Exception.Message)"
        return $true
    }
}

function Move-CapsulenvBitwardenHostBackupToRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Git', 'Service')][string]$Kind
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $recoveryRoot = Join-Path (Split-Path -Parent $Path) 'recovery'
    [void](New-Item -ItemType Directory -Path $recoveryRoot -Force)
    $leaf = [IO.Path]::GetFileNameWithoutExtension($Path)
    $destination = Join-Path $recoveryRoot ('{0}.stale.{1}.{2}.json' -f $leaf, [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [Guid]::NewGuid().ToString('N'))
    Move-Item -LiteralPath $Path -Destination $destination
    Write-CapsulenvMessage -Level Warning -Message "Stale Bitwarden $Kind recovery evidence was preserved without treating it as current-host ownership: $destination"
    return $destination
}

function Write-CapsulenvLegacyBitwardenBackupDiagnostic {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('git-ssh-config.json', 'ssh-agent-service.json')][string]$Name)
    $path = Join-Path (Get-CapsulenvContext).StateRoot (Join-Path 'bitwarden' $Name)
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Write-CapsulenvMessage -Level Warning -Message "Legacy unscoped Bitwarden backup preserved as ambiguous residue: $path. No host/user ownership can be proven; automatic restore or migration is refused. Inspect it and repair the original host explicitly."
    }
}

function Disable-CapsulenvWindowsSshAgent {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    if (-not (Test-CapsulenvWindows)) { throw 'The Windows OpenSSH Authentication Agent service exists only on Windows.' }
    if ((Get-CapsulenvInstallMode) -ne 'User') { throw 'ShellOnly mode cannot change the Windows ssh-agent service. Switch to User mode before changing machine/user integration.' }
    Assert-CapsulenvUserIntegrationAuthority -PersistentOnly
    $service = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-CapsulenvMessage -Level Warning -Message 'Windows OpenSSH Authentication Agent service is not installed.'
        return
    }
    if (-not $PSCmdlet.ShouldProcess('ssh-agent', 'Stop and disable Windows OpenSSH Authentication Agent')) { return }

    $statePath = Get-CapsulenvSshAgentServiceStatePath
    $surface = Get-CapsulenvBitwardenOwnershipSurface -Kind Service
    $markerPath = Get-CapsulenvPersistentUserIntegrationMarkerPath -Surface $surface
    $markerExists = Test-Path -LiteralPath $markerPath -PathType Leaf
    $backupExists = Test-Path -LiteralPath $statePath -PathType Leaf
    if ($markerExists -and -not $backupExists) { throw "Windows ssh-agent ownership marker exists but its backup is missing: $markerPath" }
    if ($backupExists -and -not $markerExists) {
        $classification = Get-CapsulenvWindowsSshAgentBackupClassification -Path $statePath
        if ($classification.State -in @('OwnedOrPartial', 'Ambiguous')) {
            throw 'Windows ssh-agent recovery evidence is still active or ambiguous while its host-local ownership marker is missing; refusing to replace the original rollback state.'
        }
        [void](Move-CapsulenvBitwardenHostBackupToRecovery -Path $statePath -Kind Service)
        $backupExists = $false
    }

    if ($backupExists) {
        $owned = Get-CapsulenvBitwardenOwnedHostBackup -Path $statePath -Kind Service
        $record = $owned.Record
    } else {
        Write-CapsulenvLegacyBitwardenBackupDiagnostic -Name 'ssh-agent-service.json'
        $serviceInfo = Get-CimInstance Win32_Service -Filter "Name='ssh-agent'"
        $record = New-CapsulenvBitwardenHostBackup -Values ([ordered]@{ Status = [string]$service.Status; StartMode = [string]$serviceInfo.StartMode }) -Applied ([ordered]@{ Status = 'Stopped'; StartMode = 'Disabled' })
        Write-CapsulenvHostJsonAtomically -Path $statePath -Value $record
    }

    [void](Write-CapsulenvPersistentUserIntegrationMarker -Surface $surface -Token ([string]$record.OwnershipId) -Applied ([ordered]@{ Status = 'Stopped'; StartMode = 'Disabled' }))
    if ($service.Status -ne 'Stopped') { Stop-Service -Name 'ssh-agent' -Force }
    Set-Service -Name 'ssh-agent' -StartupType Disabled
    Write-CapsulenvMessage -Level Success -Message 'Windows OpenSSH Authentication Agent disabled for Bitwarden SSH Agent.'
}

function Restore-CapsulenvWindowsSshAgent {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    $statePath = Get-CapsulenvSshAgentServiceStatePath
    $surface = Get-CapsulenvBitwardenOwnershipSurface -Kind Service
    $markerPath = Get-CapsulenvPersistentUserIntegrationMarkerPath -Surface $surface
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        Write-CapsulenvLegacyBitwardenBackupDiagnostic -Name 'ssh-agent-service.json'
        Write-CapsulenvBitwardenHostBackupDiagnostic -Path $statePath -Kind Service -Reason 'The host-local mutation marker is absent, so this backup cannot authorize restore on the current host incarnation.'
        throw 'No validated current-host Windows ssh-agent service ownership exists; stale or unscoped evidence cannot authorize restore.'
    }
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw "Windows ssh-agent ownership marker exists but its portable backup is missing: $markerPath" }

    $owned = Get-CapsulenvBitwardenOwnedHostBackup -Path $statePath -Kind Service
    $record = $owned.Record
    $marker = $owned.Marker
    $state = $record.Values
    $service = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
    if ($null -eq $service) { throw 'Windows ssh-agent service disappeared while Capsulenv still owns its recovery record; refusing destructive restore.' }
    $serviceInfo = Get-CimInstance Win32_Service -Filter "Name='ssh-agent'"
    $currentStatus = [string]$service.Status
    $currentStartMode = [string]$serviceInfo.StartMode
    $beforeStatus = [string]$state.Status
    $beforeStartMode = [string]$state.StartMode
    $appliedStatus = [string]$marker.Applied.Status
    $appliedStartMode = [string]$marker.Applied.StartMode
    if ($currentStatus -notin @($beforeStatus, $appliedStatus) -or $currentStartMode -notin @($beforeStartMode, $appliedStartMode)) {
        throw 'Windows ssh-agent service changed after Capsulenv applied its persistent mutation; refusing to overwrite concurrent service changes.'
    }
    $startupType = switch ($beforeStartMode) { 'Auto' { 'Automatic' }; 'Manual' { 'Manual' }; 'Disabled' { 'Disabled' } }
    if ($PSCmdlet.ShouldProcess('ssh-agent', "Restore startup type $startupType")) {
        if ($currentStartMode -ne $beforeStartMode) { Set-Service -Name 'ssh-agent' -StartupType $startupType }
        if ($beforeStatus -eq 'Running' -and $currentStatus -ne 'Running') { Start-Service -Name 'ssh-agent' }
        elseif ($beforeStatus -eq 'Stopped' -and $currentStatus -ne 'Stopped') { Stop-Service -Name 'ssh-agent' -Force }
        Remove-CapsulenvPersistentUserIntegrationMarker -Surface $surface
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

function Get-CapsulenvPortableGitConfigTarget {
    [CmdletBinding()]
    param()

    $target = [string](Get-CapsulenvEnvironmentPlan).Variables.GIT_CONFIG_GLOBAL
    if ([string]::IsNullOrWhiteSpace($target)) {
        throw 'Capsulenv portable Git global config target is not configured.'
    }
    return [System.IO.Path]::GetFullPath($target)
}

function Invoke-CapsulenvPortableGitConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Git,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments
    )

    $environment = [ordered]@{
        GIT_CONFIG_GLOBAL = [System.IO.Path]::GetFullPath($Target)
        GIT_CONFIG_COUNT = $null
        CAPSULENV_GIT_CONFIG_BASE_COUNT = $null
        CAPSULENV_GIT_CONFIG_BASE_PRESENT = $null
    }
    foreach ($nameObject in [Environment]::GetEnvironmentVariables('Process').Keys) {
        $name = [string]$nameObject
        if ($name -like 'GIT_CONFIG_KEY_*' -or $name -like 'GIT_CONFIG_VALUE_*') {
            $environment[$name] = $null
        }
    }

    $startInfo = New-CapsulenvProcessStartInfo -Executable $Git -Arguments (@('config', '--global') + @($Arguments)) -Environment $environment -Capture
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Failed to start Git while updating the portable global configuration.'
    }
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = $stdout
        Error = $stderr
    }
}

function Get-CapsulenvGitOpenSshGlobalValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Git,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $captured = [ordered]@{}
    foreach ($key in @('core.sshCommand', 'gpg.ssh.program')) {
        $result = Invoke-CapsulenvPortableGitConfig -Git $Git -Target $Target -Arguments @('--null', '--get-all', $key)
        if ($result.ExitCode -eq 0) {
            $values = @(([string]$result.Output).Split([char]0) | Where-Object { $_ -ne '' })
            $captured[$key] = [pscustomobject][ordered]@{ Exists = $true; Values = [string[]]$values }
        } elseif ($result.ExitCode -eq 1) {
            $captured[$key] = [pscustomobject][ordered]@{ Exists = $false; Values = [string[]]@() }
        } else {
            throw "Failed to read portable Git setting $key (exit $($result.ExitCode)): $($result.Error)"
        }
    }
    return [pscustomobject]$captured
}

function Test-CapsulenvGitValueSetEqual {
    [CmdletBinding()]
    param([AllowNull()]$Left, [AllowNull()]$Right)

    $leftValues = @($Left)
    $rightValues = @($Right)
    if ($leftValues.Count -ne $rightValues.Count) { return $false }
    for ($index = 0; $index -lt $leftValues.Count; $index++) {
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$leftValues[$index], [string]$rightValues[$index])) {
            return $false
        }
    }
    return $true
}

function New-CapsulenvGitPortableBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Values,
        [Parameter(Mandatory = $true)]$Applied,
        [Parameter(Mandatory = $true)][string]$Target
    )

    return [pscustomobject][ordered]@{
        SchemaVersion = 2
        CapsuleId = Get-CapsulenvIdentity
        TargetReference = ConvertTo-CapsulenvStatePathReference -Path $Target
        Values = $Values
        Applied = $Applied
    }
}

function Read-CapsulenvGitPortableBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $record = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $target = Get-CapsulenvPortableGitConfigTarget
    if ($record.PSObject.Properties['SchemaVersion']) {
        if ([int]$record.SchemaVersion -ne 2 -or [string]$record.CapsuleId -ne [string](Get-CapsulenvIdentity)) {
            throw "Invalid portable Git SSH backup identity: $Path"
        }
        $recordTarget = Resolve-CapsulenvStatePathReference -Reference ([string]$record.TargetReference) -CapsuleRoot (Get-CapsulenvContext).Root
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([System.IO.Path]::GetFullPath($recordTarget), [System.IO.Path]::GetFullPath($target))) {
            throw "Portable Git SSH backup target no longer matches the configured capsule Git target: $Path"
        }
        return $record
    }

    $values = [ordered]@{}
    foreach ($key in @('core.sshCommand', 'gpg.ssh.program')) {
        $entry = $record.PSObject.Properties[$key]
        if ($null -eq $entry) { throw "Invalid legacy Git SSH backup: $Path" }
        $legacy = $entry.Value
        $legacyValues = if ([bool]$legacy.Exists) { [string[]]@([string]$legacy.Value) } else { [string[]]@() }
        $values[$key] = [pscustomobject][ordered]@{ Exists = [bool]$legacy.Exists; Values = $legacyValues }
    }
    $paths = Get-CapsulenvGitOpenSshPaths
    return New-CapsulenvGitPortableBackup -Values ([pscustomobject]$values) -Applied ([pscustomobject][ordered]@{
        'core.sshCommand' = [string[]]@([string]$paths.Ssh)
        'gpg.ssh.program' = [string[]]@([string]$paths.SshKeygen)
    }) -Target $target
}

function Assert-CapsulenvGitOpenSshOwnershipApplied {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Git,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)]$Record
    )

    $current = Get-CapsulenvGitOpenSshGlobalValues -Git $Git -Target $Target
    foreach ($key in @('core.sshCommand', 'gpg.ssh.program')) {
        $actual = $current.PSObject.Properties[$key].Value
        $before = $Record.Values.PSObject.Properties[$key].Value
        $appliedValues = @($Record.Applied.PSObject.Properties[$key].Value)
        $actualValues = @($actual.Values)
        $beforeValues = @($before.Values)
        $matchesApplied = Test-CapsulenvGitValueSetEqual -Left $actualValues -Right $appliedValues
        $matchesBefore = Test-CapsulenvGitValueSetEqual -Left $actualValues -Right $beforeValues
        if (-not $matchesApplied -and -not $matchesBefore) {
            throw "Portable Git SSH setting $key changed after Capsulenv applied persistent integration; refusing to overwrite concurrent configuration."
        }
    }
}

function Set-CapsulenvGitConfigValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Git,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowEmptyCollection()][string[]]$Values = @()
    )

    $unset = Invoke-CapsulenvPortableGitConfig -Git $Git -Target $Target -Arguments @('--unset-all', $Key)
    if ($unset.ExitCode -ne 0 -and $unset.ExitCode -ne 5) {
        throw "Failed to clear portable Git setting $Key (exit $($unset.ExitCode)): $($unset.Error)"
    }
    foreach ($value in @($Values)) {
        $add = Invoke-CapsulenvPortableGitConfig -Git $Git -Target $Target -Arguments @('--add', $Key, [string]$value)
        if ($add.ExitCode -ne 0) {
            throw "Failed to add portable Git setting $Key (exit $($add.ExitCode)): $($add.Error)"
        }
    }
}

function Restore-CapsulenvGitValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Git,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)]$Backup
    )

    foreach ($property in $Backup.PSObject.Properties) {
        Set-CapsulenvGitConfigValues -Git $Git -Target $Target -Key $property.Name -Values @($property.Value.Values)
    }
}

function Set-CapsulenvGitOpenSsh {
    [CmdletBinding()]
    param([switch]$Force)

    $mode = Get-CapsulenvInstallMode
    if ($mode -eq 'ShellOnly') {
        [void](Get-CapsulenvGitOpenSshPaths)
        Enable-CapsulenvGitOpenSshSession
        Write-CapsulenvMessage -Level Success -Message 'Git uses Microsoft OpenSSH through a Capsulenv process-only config overlay; portable global Git config is unchanged.'
        return
    }

    Assert-CapsulenvUserIntegrationAuthority -PersistentOnly
    Clear-CapsulenvGitOpenSshSession
    $git = Get-CapsulenvGitCommand
    $target = Get-CapsulenvPortableGitConfigTarget
    $paths = Get-CapsulenvGitOpenSshPaths
    $applied = [pscustomobject][ordered]@{
        'core.sshCommand' = [string[]]@([string]$paths.Ssh)
        'gpg.ssh.program' = [string[]]@([string]$paths.SshKeygen)
    }
    $intentExisted = Test-CapsulenvGitOpenSshSessionConfigured
    $backupPath = Get-CapsulenvGitConfigBackupPath
    $backupExists = Test-Path -LiteralPath $backupPath -PathType Leaf
    if ($backupExists -and -not $Force) {
        throw 'A portable Git SSH configuration backup already exists. Restore it first or pass -Force to reapply without replacing the original backup.'
    }

    if ($backupExists) {
        $record = Read-CapsulenvGitPortableBackup -Path $backupPath
    } else {
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force)
        $captured = Get-CapsulenvGitOpenSshGlobalValues -Git $git -Target $target
        $record = New-CapsulenvGitPortableBackup -Values $captured -Applied $applied -Target $target
        Write-CapsulenvHostJsonAtomically -Path $backupPath -Value $record
    }

    try {
        Set-CapsulenvGitConfigValues -Git $git -Target $target -Key 'core.sshCommand' -Values @($applied.'core.sshCommand')
        Set-CapsulenvGitConfigValues -Git $git -Target $target -Key 'gpg.ssh.program' -Values @($applied.'gpg.ssh.program')
        Set-CapsulenvGitOpenSshIntent
    } catch {
        $configurationError = $_
        try {
            Restore-CapsulenvGitValues -Git $git -Target $target -Backup $record.Values
            if (-not $backupExists -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
                Remove-Item -LiteralPath $backupPath -Force
            }
            if (-not $intentExisted) {
                $intentPath = Get-CapsulenvGitSessionConfigPath
                if (Test-Path -LiteralPath $intentPath -PathType Leaf) {
                    Remove-Item -LiteralPath $intentPath -Force
                }
            }
        } catch {
            Write-Warning "Portable Git configuration rollback failed; the original backup was retained at $backupPath. $($_.Exception.Message)"
        }
        throw $configurationError
    }

    Write-CapsulenvMessage -Level Success -Message 'Capsulenv portable Git global configuration now uses Microsoft OpenSSH for User-mode Bitwarden SSH Agent compatibility.'
}

function Restore-CapsulenvGitOpenSshGlobal {
    [CmdletBinding()]
    param([switch]$IfPresent)

    $backupPath = Get-CapsulenvGitConfigBackupPath
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        if ($IfPresent) { return $false }
        throw 'No portable Git global SSH configuration backup exists.'
    }

    $record = Read-CapsulenvGitPortableBackup -Path $backupPath
    $git = Get-CapsulenvGitCommand
    $target = Get-CapsulenvPortableGitConfigTarget
    Assert-CapsulenvGitOpenSshOwnershipApplied -Git $git -Target $target -Record $record
    Restore-CapsulenvGitValues -Git $git -Target $target -Backup $record.Values
    Remove-Item -LiteralPath $backupPath -Force
    Write-CapsulenvMessage -Level Success -Message 'Portable Git global SSH configuration restored.'
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
