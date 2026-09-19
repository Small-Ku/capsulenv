function Get-CapsulenvBitwardenProgramRequirement {
    [CmdletBinding()]
    param(
        [string]$App,
        [ValidateSet('required', 'optional')]
        [string]$Criticality = 'optional'
    )

    if ([string]::IsNullOrWhiteSpace($App)) {
        $definition = Get-CapsulenvBitwardenDefinition
        $App = [string]$definition.App
    }
    $parsed = Split-CapsulenvInstalledAppSelector -Selector $App
    return [pscustomobject][ordered]@{
        Requirement = New-CapsulenvProgramRequirement -Name ([string]$parsed.Name)
        Criticality = $Criticality
        App = $App
    }
}

function Get-CapsulenvBitwardenAttachedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Program,
        [int]$ProcessId
    )

    $expected = [System.IO.Path]::GetFullPath([string]$Program.Executable)
    $processes = if ($ProcessId -gt 0) {
        @(Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
    } else {
        @(Get-Process -ErrorAction SilentlyContinue)
    }
    foreach ($process in $processes) {
        $path = $null
        try { $path = [System.IO.Path]::GetFullPath([string]$process.Path) } catch {}
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $comparison = if (Test-CapsulenvWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        if ($path.Equals($expected, $comparison)) {
            return [pscustomobject][ordered]@{
                Process = $process
                PID = [int]$process.Id
                ProcessStartIdentity = Get-CapsulenvProcessStartIdentity -ProcessId ([int]$process.Id)
                Ownership = 'attached'
            }
        }
    }
    return $null
}

function Test-CapsulenvBitwardenSshAgentEndpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Endpoint)

    if ([string]::IsNullOrWhiteSpace($Endpoint) -or $Endpoint -match '^agent://') {
        return [pscustomobject][ordered]@{ Reachable = $false; Endpoint = $Endpoint; Diagnostics = 'SSH-agent endpoint is not a real socket or named pipe.' }
    }
    $sshAdd = Get-Command ssh-add.exe -CommandType Application -ErrorAction SilentlyContinue
    if (-not $sshAdd) { $sshAdd = Get-Command ssh-add -CommandType Application -ErrorAction SilentlyContinue }
    if (-not $sshAdd) {
        return [pscustomobject][ordered]@{ Reachable = $false; Endpoint = $Endpoint; Diagnostics = 'ssh-add is unavailable for the SSH-agent reachability probe.' }
    }
    $old = [Environment]::GetEnvironmentVariable('SSH_AUTH_SOCK', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('SSH_AUTH_SOCK', $Endpoint, 'Process')
        Clear-CapsulenvLastExitCode
        $output = & $sshAdd.Source -L 2>&1
        $exitCode = Get-CapsulenvLastExitCode -Succeeded $?
        $reachable = $exitCode -eq 0 -or ($output -match 'no identities|No identities')
        return [pscustomobject][ordered]@{
            Reachable = $reachable
            Endpoint = $Endpoint
            ExitCode = $exitCode
            Diagnostics = if ($reachable) { 'SSH-agent endpoint responded to ssh-add -L' } else { "SSH-agent endpoint did not respond: $($output -join ' ')" }
        }
    } finally {
        [Environment]::SetEnvironmentVariable('SSH_AUTH_SOCK', $old, 'Process')
    }
}

function Get-CapsulenvBitwardenSessionEnvironmentSnapshot {
    [CmdletBinding()]
    param()

    $values = [ordered]@{}
    foreach ($name in @('SSH_AUTH_SOCK', 'GIT_CONFIG_COUNT', 'CAPSULENV_GIT_CONFIG_BASE_COUNT', 'CAPSULENV_GIT_CONFIG_BASE_PRESENT')) {
        $values[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    $count = 0
    [void][int]::TryParse([string]$values.GIT_CONFIG_COUNT, [ref]$count)
    for ($index = 0; $index -lt $count; $index++) {
        foreach ($prefix in @('GIT_CONFIG_KEY_', 'GIT_CONFIG_VALUE_')) {
            $name = "$prefix$index"
            $values[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
    }
    return [pscustomobject]$values
}

function Restore-CapsulenvBitwardenSessionEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Snapshot)

    if ([bool]$Snapshot.GitConfigured) {
        Clear-CapsulenvGitOpenSshSession
    }
    foreach ($property in @($Snapshot.PSObject.Properties | Where-Object { $_.Name -ne 'GitConfigured' })) {
        [Environment]::SetEnvironmentVariable($property.Name, $property.Value, 'Process')
    }
    return $Snapshot
}

function Resolve-CapsulenvBitwardenBinding {
    [CmdletBinding()]
    param(
        [string]$App,
        $Requirement,
        [object[]]$Candidates,
        [ValidateSet('required', 'optional')]
        [string]$Criticality = 'optional',
        [string]$SessionId,
        [object]$AgentBinding
    )

    $requirementRecord = if ($null -eq $Requirement) {
        Get-CapsulenvBitwardenProgramRequirement -App $App -Criticality $Criticality
    } else {
        [pscustomobject]@{ Requirement = $Requirement; Criticality = $Criticality; App = $App }
    }
    $parameters = @{
        Requirement = $requirementRecord.Requirement
        Criticality = $requirementRecord.Criticality
    }
    if ($PSBoundParameters.ContainsKey('Candidates')) { $parameters['Candidates'] = $Candidates }
    $resolution = if ($PSBoundParameters.ContainsKey('Candidates')) {
        Get-CapsulenvProgramResolution -Requirement $parameters.Requirement -Candidates $parameters.Candidates
    } else {
        Get-CapsulenvProgramResolution -Requirement $parameters.Requirement
    }
    if (-not $resolution.Succeeded) {
        $message = "Bitwarden program '$($requirementRecord.App)' has no compatible trusted realization."
        if ($Criticality -eq 'required') {
            throw $message
        }
        return [pscustomobject][ordered]@{
            Succeeded = $false
            Attached = $false
            OwnedProcess = $false
            CanStop = $false
            Program = $null
            Diagnostics = @($message + ' Optional attach-only integration remains unavailable.')
        }
    }
    $attachedProcessId = if ($null -ne $AgentBinding -and $null -ne $AgentBinding.PSObject.Properties['ProcessId']) { [int]$AgentBinding.ProcessId } else { 0 }
    $attachedProcess = Get-CapsulenvBitwardenAttachedProcess -Program $resolution.Selected -ProcessId $attachedProcessId
    if ($null -eq $attachedProcess) {
        $message = "Bitwarden host process for '$($resolution.Selected.Executable)' is not running; Program availability is not process attachment."
        if ($Criticality -eq 'required') { throw $message }
        return [pscustomobject][ordered]@{
            Succeeded = $false
            ProgramAvailable = $true
            Attached = $false
            OwnedProcess = $false
            CanStop = $false
            Program = $resolution.Selected
            App = $requirementRecord.App
            Diagnostics = @($message + ' Optional attach skipped.')
        }
    }
    $effectiveSessionId = $SessionId
    if ([string]::IsNullOrWhiteSpace($effectiveSessionId)) {
        $effectiveSessionId = (Initialize-CapsulenvSession -Role bitwarden-attach -Ownership attached -Provenance ([string]$resolution.Selected.Provenance)).SessionId
    }
    $processRecord = Register-CapsulenvProcessRecord -SessionId $effectiveSessionId -ProcessId $attachedProcess.PID -Role bitwarden -Ownership attached -ProcessStartIdentity $attachedProcess.ProcessStartIdentity -Provenance ([string]$resolution.Selected.Provenance)
    return [pscustomobject][ordered]@{
        Succeeded = $true
        ProgramAvailable = $true
        Attached = $true
        OwnedProcess = $false
        CanStop = $false
        Program = $resolution.Selected
        App = $requirementRecord.App
        SessionId = $effectiveSessionId
        Process = $attachedProcess.Process
        ProcessRecord = $processRecord
        Diagnostics = @('Bitwarden is a host-local Program and an exact live attached process was recorded; attach-only integration does not claim process ownership')
    }
}

function Invoke-CapsulenvBitwardenSessionIntegration {
    [CmdletBinding()]
    param(
        [string]$App,
        $Requirement,
        [object[]]$Candidates,
        [string]$SshAuthSock,
        [object]$AgentBinding,
        [object]$ResolvedBinding,
        [switch]$ConfigureGit,
        [ValidateSet('required', 'optional')]
        [string]$Criticality = 'optional',
        [string]$SessionId
    )

    $parameters = @{
        App = $App
        Criticality = $Criticality
    }
    if ($null -ne $Requirement) { $parameters['Requirement'] = $Requirement }
    if ($PSBoundParameters.ContainsKey('Candidates')) { $parameters['Candidates'] = $Candidates }
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) { $parameters['SessionId'] = $SessionId }
    if ($null -ne $AgentBinding) { $parameters['AgentBinding'] = $AgentBinding }
    $binding = if ($null -ne $ResolvedBinding) { $ResolvedBinding } else { Resolve-CapsulenvBitwardenBinding @parameters }
    if (-not $binding.Succeeded) {
        return $binding
    }
    $sock = if ([string]::IsNullOrWhiteSpace($SshAuthSock)) {
        [Environment]::GetEnvironmentVariable('SSH_AUTH_SOCK', 'Process')
    } else {
        $SshAuthSock
    }
    if ([string]::IsNullOrWhiteSpace($sock)) {
        $message = 'Bitwarden SSH-agent endpoint is not configured.'
        if ($Criticality -eq 'required') { throw $message }
        $binding.Diagnostics = @($binding.Diagnostics) + @($message + ' Optional integration skipped.')
        $binding.Succeeded = $false
        return $binding
    }
    $bindingContractValid = $false
    if ($null -ne $AgentBinding) {
        $bindingContractValid =
            $null -ne $AgentBinding.PSObject.Properties['Endpoint'] -and
            $null -ne $AgentBinding.PSObject.Properties['ProgramProvenance'] -and
            $null -ne $AgentBinding.PSObject.Properties['ProcessId'] -and
            [System.StringComparer]::Ordinal.Equals([string]$AgentBinding.Endpoint, [string]$sock) -and
            [System.StringComparer]::Ordinal.Equals([string]$AgentBinding.ProgramProvenance, [string]$binding.Program.Provenance) -and
            ([int]$AgentBinding.ProcessId -eq [int]$binding.ProcessRecord.PID)
    }
    if (-not $bindingContractValid) {
        $message = 'Bitwarden SSH-agent integration requires an explicit endpoint binding to the attached process and resolved Program provenance.'
        if ($Criticality -eq 'required') { throw $message }
        $binding.Diagnostics = @($binding.Diagnostics) + @($message + ' Optional integration skipped.')
        $binding.Succeeded = $false
        return $binding
    }
    $agent = Test-CapsulenvBitwardenSshAgentEndpoint -Endpoint $sock
    if (-not $agent.Reachable) {
        $message = "Bitwarden SSH-agent endpoint is unreachable: $($agent.Diagnostics)"
        if ($Criticality -eq 'required') { throw $message }
        $binding.Diagnostics = @($binding.Diagnostics) + @($message + ' Optional integration skipped.')
        $binding.Succeeded = $false
        return $binding
    }
    $snapshot = Get-CapsulenvBitwardenSessionEnvironmentSnapshot
    $snapshot | Add-Member -NotePropertyName GitConfigured -NotePropertyValue ([bool]$ConfigureGit)
    [Environment]::SetEnvironmentVariable('SSH_AUTH_SOCK', $sock, 'Process')
    try {
        if ($ConfigureGit) {
            Set-CapsulenvGitOpenSshSession
        }
    } catch {
        [void](Restore-CapsulenvBitwardenSessionEnvironment -Snapshot $snapshot)
        throw
    }
    $binding | Add-Member -NotePropertyName SSH_AUTH_SOCK -NotePropertyValue $sock
    $binding | Add-Member -NotePropertyName GitConfigured -NotePropertyValue ([bool]$ConfigureGit)
    $binding | Add-Member -NotePropertyName EnvironmentSnapshot -NotePropertyValue $snapshot
    $binding | Add-Member -NotePropertyName AgentProbe -NotePropertyValue $agent
    $binding | Add-Member -NotePropertyName AgentBinding -NotePropertyValue ([pscustomobject][ordered]@{
        Mode = 'explicit-config'
        Endpoint = [string]$AgentBinding.Endpoint
        ProgramProvenance = [string]$AgentBinding.ProgramProvenance
        ProcessId = [int]$AgentBinding.ProcessId
        OwnershipVerified = $false
    })
    return $binding
}

function Restore-CapsulenvBitwardenSessionIntegration {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Binding)

    if ($null -ne $Binding.PSObject.Properties['EnvironmentSnapshot'] -and $null -ne $Binding.EnvironmentSnapshot) {
        [void](Restore-CapsulenvBitwardenSessionEnvironment -Snapshot $Binding.EnvironmentSnapshot)
    }
    return [pscustomobject][ordered]@{ Restored = $true; SSH_AUTH_SOCK = [Environment]::GetEnvironmentVariable('SSH_AUTH_SOCK', 'Process') }
}

function Stop-CapsulenvBitwardenSessionIntegration {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Binding)

    if ([bool]$Binding.Attached -and -not [bool]$Binding.OwnedProcess) {
        $restore = Restore-CapsulenvBitwardenSessionIntegration -Binding $Binding
        return [pscustomobject][ordered]@{
            Stopped = $false
            Restored = $restore.Restored
            Reason = 'attached or foreign Bitwarden process is never stopped by Capsulenv'
        }
    }
    if ($null -eq $Binding.ProcessRecord) {
        return [pscustomobject][ordered]@{
            Stopped = $false
            Reason = 'no exact owned Bitwarden process record was supplied'
        }
    }
    return Stop-CapsulenvOwnedProcessRecord -ProcessRecord $Binding.ProcessRecord
}

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvBitwardenProgramRequirement, Resolve-CapsulenvBitwardenBinding, Invoke-CapsulenvBitwardenSessionIntegration, Restore-CapsulenvBitwardenSessionIntegration, Stop-CapsulenvBitwardenSessionIntegration
