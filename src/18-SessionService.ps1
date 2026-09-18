if (-not (Get-Variable -Name CapsulenvSessionServiceBindings -Scope Script -ErrorAction SilentlyContinue)) {
    $script:CapsulenvSessionServiceBindings = @{}
}

function Get-CapsulenvSessionServiceProxyEnvironmentSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$ProxyEnvironment)

    $snapshot = [ordered]@{}
    foreach ($property in @($ProxyEnvironment.GetEnumerator())) {
        $name = [string]$property.Key
        $snapshot[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    return [pscustomobject]$snapshot
}

function Restore-CapsulenvSessionServiceProxyEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Snapshot)

    foreach ($property in @($Snapshot.PSObject.Properties)) {
        [Environment]::SetEnvironmentVariable($property.Name, $property.Value, 'Process')
    }
    return $Snapshot
}

function New-CapsulenvSessionServiceDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Requirement,
        [ValidateSet('required', 'optional')]
        [string]$Criticality = 'optional',
        [string[]]$Arguments = @(),
        [string]$ConfigPath,
        [string]$LogRoot,
        [string]$RuntimeRoot,
        [scriptblock]$ReadinessProbe,
        [scriptblock]$HealthProbe,
        [hashtable]$ProxyEnvironment = @{}
    )

    return [pscustomobject][ordered]@{
        Name = $Name
        Requirement = $Requirement
        Criticality = $Criticality
        Arguments = @($Arguments)
        ConfigPath = $ConfigPath
        LogRoot = $LogRoot
        RuntimeRoot = $RuntimeRoot
        ReadinessProbe = $ReadinessProbe
        HealthProbe = $HealthProbe
        ProxyEnvironment = $ProxyEnvironment
    }
}

function Resolve-CapsulenvSessionService {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Definition,
        [object[]]$Candidates
    )

    $resolution = if ($PSBoundParameters.ContainsKey('Candidates')) {
        Get-CapsulenvProgramResolution -Requirement $Definition.Requirement -Candidates $Candidates
    } else {
        Get-CapsulenvProgramResolution -Requirement $Definition.Requirement
    }
    if (-not $resolution.Succeeded) {
        return [pscustomobject][ordered]@{
            Succeeded = $false
            Service = $Definition
            Program = $null
            Diagnostics = @("SessionService '$($Definition.Name)' has no compatible Program.")
        }
    }
    return [pscustomobject][ordered]@{
        Succeeded = $true
        Service = $Definition
        Program = $resolution.Selected
        Diagnostics = @("SessionService '$($Definition.Name)' resolved its Program once.")
    }
}

function Test-CapsulenvSessionServiceReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [scriptblock]$ReadinessProbe,
        [scriptblock]$HealthProbe,
        [int]$TimeoutMilliseconds = 1500
    )

    if ($null -eq $ReadinessProbe) {
        return [pscustomobject]@{ Ready = $false; Healthy = $false; Reason = 'explicit readiness probe is required' }
    }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        $Process.Refresh()
        if ($Process.HasExited) {
            return [pscustomobject]@{ Ready = $false; Healthy = $false; Reason = 'process exited before readiness' }
        }
        $ready = if ($null -eq $ReadinessProbe) { $true } else { [bool](& $ReadinessProbe $Process) }
        $healthy = if ($ready -and $null -ne $HealthProbe) { [bool](& $HealthProbe $Process) } else { $ready }
        if ($ready -and $healthy) {
            return [pscustomobject]@{ Ready = $true; Healthy = $true; Reason = 'readiness and health checks passed' }
        }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    return [pscustomobject]@{ Ready = $false; Healthy = $false; Reason = 'readiness or health timeout' }
}

function Start-CapsulenvSessionService {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Definition,
        [object[]]$Candidates,
        [string]$SessionId,
        [int]$ReadinessTimeoutMilliseconds = 1500
    )

    $resolved = if ($PSBoundParameters.ContainsKey('Candidates')) {
        Resolve-CapsulenvSessionService -Definition $Definition -Candidates $Candidates
    } else {
        Resolve-CapsulenvSessionService -Definition $Definition
    }
    if (-not $resolved.Succeeded) {
        if ([string]$Definition.Criticality -eq 'required') {
            throw $resolved.Diagnostics[0]
        }
        return $resolved
    }
    $effectiveSessionId = $SessionId
    if ([string]::IsNullOrWhiteSpace($effectiveSessionId)) {
        $effectiveSessionId = (Initialize-CapsulenvSession -Role session-service -Provenance $Definition.Name).SessionId
    }
    foreach ($path in @($Definition.LogRoot, $Definition.RuntimeRoot)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$path)) {
            [void](New-Item -ItemType Directory -Path $path -Force)
        }
    }
    $configPath = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$Definition.ConfigPath)) {
        $configPath = [System.IO.Path]::GetFullPath([string]$Definition.ConfigPath)
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
            throw "SessionService '$($Definition.Name)' config does not exist: $configPath"
        }
    }
    $rawArguments = @()
    if ($null -ne $configPath) { $rawArguments += @('-c', $configPath) }
    $rawArguments += @($Definition.Arguments)
    $argumentList = @($rawArguments | ForEach-Object { ConvertTo-CapsulenvProcessArgument -Argument $_ })
    $lease = $null
    if ($null -ne $configPath) {
        $lease = Acquire-CapsulenvStateLease -StatePath $configPath -Policy exclusive -SessionId $effectiveSessionId
    }
    $proxySnapshot = $null
    $proxyApplied = $false
    $process = $null
    $processStartIdentity = $null
    $record = $null
    $completed = $false
    try {
        $process = Start-Process -FilePath $resolved.Program.Executable -WorkingDirectory (Split-Path -Parent $resolved.Program.Executable) -ArgumentList $argumentList -PassThru
        $processStartIdentity = Get-CapsulenvProcessStartIdentity -ProcessId $process.Id
        $record = Register-CapsulenvOwnedProcessRecord -SessionId $effectiveSessionId -ProcessId $process.Id -Role session-service -ProcessStartIdentity $processStartIdentity -Provenance ([string]$resolved.Program.Provenance) -HeldLeases $(if ($null -eq $lease) { @() } else { @($lease.LeaseId) })
        $readiness = Test-CapsulenvSessionServiceReady -Process $process -ReadinessProbe $Definition.ReadinessProbe -HealthProbe $Definition.HealthProbe -TimeoutMilliseconds $ReadinessTimeoutMilliseconds
        if (-not $readiness.Ready -or -not $readiness.Healthy) {
            [void](Stop-CapsulenvOwnedProcessRecord -ProcessRecord $record)
            if ($null -ne $lease) { [void](Release-CapsulenvStateLease -Lease $lease) }
            $message = "SessionService '$($Definition.Name)' did not reach readiness: $($readiness.Reason)"
            if ([string]$Definition.Criticality -eq 'required') { throw $message }
            return [pscustomobject][ordered]@{ Succeeded = $false; Attached = $false; Service = $Definition; Program = $resolved.Program; ProcessRecord = $record; StateLease = $null; Diagnostics = @($message) }
        }
        $proxySnapshot = Get-CapsulenvSessionServiceProxyEnvironmentSnapshot -ProxyEnvironment $Definition.ProxyEnvironment
        foreach ($property in @($Definition.ProxyEnvironment.GetEnumerator())) {
            [Environment]::SetEnvironmentVariable([string]$property.Key, [string]$property.Value, 'Process')
        }
        $proxyApplied = $true
        $binding = [pscustomobject][ordered]@{
            Succeeded = $true
            Attached = $false
            Service = $Definition
            Program = $resolved.Program
            Process = $process
            ProcessRecord = $record
            Readiness = $readiness
            Arguments = @($argumentList)
            ConfigPath = $configPath
            StateLease = $lease
            SessionId = $effectiveSessionId
            ProxyEnvironmentSnapshot = $proxySnapshot
            Diagnostics = @("SessionService '$($Definition.Name)' is ready and owned exactly.")
        }
        $watcher = Register-CapsulenvSessionServiceExitWatcher -Process $process -Binding $binding
        $binding | Add-Member -NotePropertyName ExitWatcher -NotePropertyValue $watcher
        $script:CapsulenvSessionServiceBindings[[string]$effectiveSessionId] = $binding
        return $binding
    } catch {
        if ($null -ne $record) {
            try { [void](Stop-CapsulenvOwnedProcessRecord -ProcessRecord $record) } catch {}
        } elseif ($null -ne $process -and $null -ne $processStartIdentity) {
            try {
                $currentIdentity = Get-CapsulenvProcessStartIdentity -ProcessId $process.Id
                if ([string]$currentIdentity -eq [string]$processStartIdentity) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
            } catch {}
        }
        if ($proxyApplied -and $null -ne $proxySnapshot) { [void](Restore-CapsulenvSessionServiceProxyEnvironment -Snapshot $proxySnapshot) }
        if ($null -ne $lease -and -not $lease.Released) { [void](Release-CapsulenvStateLease -Lease $lease) }
        throw
    }
}

function Register-CapsulenvSessionServiceExitWatcher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)]$Binding
    )

    $Process.EnableRaisingEvents = $true
    $key = [string]$Binding.SessionId
    $eventData = [pscustomobject][ordered]@{
        SessionId = [string]$Binding.SessionId
        ProxyEnvironmentSnapshot = $Binding.ProxyEnvironmentSnapshot
    }
    $subscription = Register-ObjectEvent -InputObject $Process -EventName Exited -MessageData $eventData -Action {
        $payload = $event.MessageData
        try {
            if ($null -ne $payload.ProxyEnvironmentSnapshot) {
                foreach ($property in @($payload.ProxyEnvironmentSnapshot.PSObject.Properties)) {
                    [Environment]::SetEnvironmentVariable($property.Name, $property.Value, 'Process')
                }
            }
            if ($null -ne $script:CapsulenvSessionServiceBindings) {
                [void]$script:CapsulenvSessionServiceBindings.Remove([string]$payload.SessionId)
            }
        } finally {
            if ($null -ne $event.SubscriptionId) {
                Unregister-Event -SubscriptionId $event.SubscriptionId -ErrorAction SilentlyContinue
            }
        }
    }
    return [pscustomobject][ordered]@{ Key = $key; SubscriptionId = $subscription.Id }
}
function New-CapsulenvAttachedSessionServiceBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$ProcessRecord,
        [Parameter(Mandatory = $true)]$Program,
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [scriptblock]$HealthProbe
    )

    if ([string]$ProcessRecord.Ownership -notin @('attached', 'foreign')) {
        throw 'Attached service binding requires an attached or foreign process record.'
    }
    $identity = Get-CapsulenvProcessStartIdentity -ProcessId ([int]$ProcessRecord.PID)
    if ([string]$identity -ne [string]$ProcessRecord.ProcessStartIdentity) {
        throw 'Attached service process start identity is stale.'
    }
    $process = Get-Process -Id ([int]$ProcessRecord.PID) -ErrorAction Stop
    $processPath = [System.IO.Path]::GetFullPath([string]$process.Path)
    $programPath = [System.IO.Path]::GetFullPath([string]$Program.Executable)
    $comparison = if (Test-CapsulenvWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if (-not $processPath.Equals($programPath, $comparison)) {
        throw "Attached SessionService '$ServiceName' process does not match the resolved Program executable."
    }
    if ($null -eq $ProcessRecord.PSObject.Properties['Role'] -or [string]$ProcessRecord.Role -ne $ServiceName) {
        throw "Attached SessionService record is not identified as '$ServiceName'."
    }
    if ($null -eq $ProcessRecord.PSObject.Properties['Provenance'] -or
        -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$ProcessRecord.Provenance, [string]$Program.Provenance)) {
        throw "Attached SessionService '$ServiceName' provenance does not match the resolved Program."
    }
    $health = if ($null -eq $HealthProbe) { $true } else { [bool](& $HealthProbe $process) }
    if (-not $health) {
        throw 'Attached service failed its explicit health check.'
    }
    return [pscustomobject][ordered]@{
        Succeeded = $true
        Attached = $true
        OwnedProcess = $false
        Process = $process
        ProcessRecord = $ProcessRecord
        Program = $Program
        ServiceName = $ServiceName
        Diagnostics = @('attached service passed identity and health validation; Capsulenv does not own its lifecycle')
    }
}

function Stop-CapsulenvSessionService {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Binding)

    $attached = if ($null -ne $Binding.PSObject.Properties['Attached']) { [bool]$Binding.Attached } else { $false }
    if ($attached -or $null -eq $Binding.ProcessRecord -or ([string]$Binding.ProcessRecord.Ownership -ne 'owned')) {
        return [pscustomobject][ordered]@{
            Stopped = $false
            Reason = 'only an exact owned SessionService process may be stopped'
        }
    }
    try {
        $result = Stop-CapsulenvOwnedProcessRecord -ProcessRecord $Binding.ProcessRecord
        return $result
    } finally {
        if ($null -ne $Binding.PSObject.Properties['ProxyEnvironmentSnapshot'] -and $null -ne $Binding.ProxyEnvironmentSnapshot) {
            [void](Restore-CapsulenvSessionServiceProxyEnvironment -Snapshot $Binding.ProxyEnvironmentSnapshot)
        }
        if ($null -ne $Binding.PSObject.Properties['SessionId']) {
            $script:CapsulenvSessionServiceBindings.Remove([string]$Binding.SessionId)
        }
        if ($null -ne $Binding.PSObject.Properties['StateLease'] -and $null -ne $Binding.StateLease -and -not $Binding.StateLease.Released) {
            [void](Release-CapsulenvStateLease -Lease $Binding.StateLease)
        }
    }
}

function Stop-CapsulenvActiveSessionServices {
    [CmdletBinding()]
    param()

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($binding in @($script:CapsulenvSessionServiceBindings.Values)) {
        try { $results.Add((Stop-CapsulenvSessionService -Binding $binding)) } catch { $results.Add([pscustomobject]@{ Stopped = $false; Error = $_.Exception.Message }) }
    }
    return @($results.ToArray())
}

function New-CapsulenvSingBoxServiceDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Requirement,
        [ValidateSet('required', 'optional')]
        [string]$Criticality = 'optional',
        [string[]]$Arguments = @(),
        [scriptblock]$ReadinessProbe,
        [scriptblock]$HealthProbe,
        [hashtable]$ProxyEnvironment = @{}
    )

    $placement = Get-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity)
    $configPath = Join-Path (Get-CapsulenvContext).Root 'state/portable/sing-box/config.json'
    $runtimeRoot = Join-Path $placement.ScratchRoot 'sing-box'
    $logRoot = Join-Path $runtimeRoot 'logs'
    return New-CapsulenvSessionServiceDefinition -Name sing-box -Requirement $Requirement -Criticality $Criticality -Arguments $Arguments -ConfigPath $configPath -RuntimeRoot $runtimeRoot -LogRoot $logRoot -ReadinessProbe $ReadinessProbe -HealthProbe $HealthProbe -ProxyEnvironment $ProxyEnvironment
}

function Start-CapsulenvSingBoxSessionService {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Definition,
        [object[]]$Candidates,
        [string]$SessionId,
        [int]$ReadinessTimeoutMilliseconds = 1500
    )

    if ([string]$Definition.Name -ne 'sing-box') {
        throw 'Sing-box SessionService wrapper requires a sing-box definition.'
    }
    $parameters = @{
        Definition = $Definition
        ReadinessTimeoutMilliseconds = $ReadinessTimeoutMilliseconds
    }
    if ($PSBoundParameters.ContainsKey('Candidates')) { $parameters['Candidates'] = $Candidates }
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) { $parameters['SessionId'] = $SessionId }
    return Start-CapsulenvSessionService @parameters
}

##MOD_EXEC## Export-ModuleMember -Function New-CapsulenvSessionServiceDefinition, Resolve-CapsulenvSessionService, Start-CapsulenvSessionService, New-CapsulenvAttachedSessionServiceBinding, Stop-CapsulenvSessionService, New-CapsulenvSingBoxServiceDefinition, Start-CapsulenvSingBoxSessionService
