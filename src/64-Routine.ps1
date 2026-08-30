function Get-CapsulenvRoutineStatePath {
    [CmdletBinding()]
    param()

    $context = Get-CapsulenvContext
    return Join-Path $context.StateRoot 'routines.json'
}

function Import-CapsulenvRoutineState {
    [CmdletBinding()]
    param()

    $path = Get-CapsulenvRoutineStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [ordered]@{}
    }
    try {
        $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    } catch {
        throw "Routine state is invalid: $path. $($_.Exception.Message)"
    }
    $result = [ordered]@{}
    foreach ($property in @($state.PSObject.Properties)) {
        $result[[string]$property.Name] = $property.Value
    }
    return $result
}

function Export-CapsulenvRoutineState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$State)

    $path = Get-CapsulenvRoutineStatePath
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
}

function Get-CapsulenvRoutineDefinitions {
    [CmdletBinding()]
    param([string]$Trigger = '')

    $configuration = Get-CapsulenvConfiguration
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($name in @($configuration.Routines.Keys | Sort-Object)) {
        $definition = $configuration.Routines[$name]
        $enabled = -not $definition.ContainsKey('Enabled') -or [bool]$definition.Enabled
        $triggers = @($definition.Trigger | ForEach-Object { [string]$_ })
        if (-not [string]::IsNullOrWhiteSpace($Trigger) -and $Trigger -notin $triggers) {
            continue
        }
        $result.Add([pscustomobject][ordered]@{
            Name = [string]$name
            Enabled = $enabled
            Trigger = $triggers
            Command = $(if ($definition.ContainsKey('Command')) { [string]$definition.Command } else { '' })
            App = $(if ($definition.ContainsKey('App')) { [string]$definition.App } else { '' })
            BinName = $(if ($definition.ContainsKey('BinName')) { [string]$definition.BinName } else { '' })
            Arguments = @($definition.Arguments | ForEach-Object { [string]$_ })
            WorkingDirectory = $(if ($definition.ContainsKey('WorkingDirectory')) { [string]$definition.WorkingDirectory } else { '' })
            Mode = $(if ($definition.ContainsKey('Mode') -and -not [string]::IsNullOrWhiteSpace([string]$definition.Mode)) { [string]$definition.Mode } else { 'Passthrough' })
            FailurePolicy = $(if ($definition.ContainsKey('FailurePolicy') -and -not [string]::IsNullOrWhiteSpace([string]$definition.FailurePolicy)) { [string]$definition.FailurePolicy } else { 'Warn' })
            MinimumIntervalSeconds = $(if ($definition.ContainsKey('MinimumIntervalSeconds')) { [int64]$definition.MinimumIntervalSeconds } else { 0 })
        })
    }
    return $result.ToArray()
}

function Test-CapsulenvRoutineDue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Routine,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$State,
        [datetime]$NowUtc = ([DateTime]::UtcNow)
    )

    if ([int64]$Routine.MinimumIntervalSeconds -le 0 -or -not $State.Contains([string]$Routine.Name)) {
        return $true
    }
    $entry = $State[[string]$Routine.Name]
    if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.LastSuccessUtc)) {
        return $true
    }
    $lastSuccess = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$entry.LastSuccessUtc, [ref]$lastSuccess)) {
        return $true
    }
    return (($NowUtc.ToUniversalTime() - $lastSuccess.ToUniversalTime()).TotalSeconds -ge [int64]$Routine.MinimumIntervalSeconds)
}

function Get-CapsulenvRoutineProcessPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Routine)

    $workingDirectory = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$Routine.WorkingDirectory)) {
        $workingDirectory = Resolve-CapsulenvPath -Path ([string]$Routine.WorkingDirectory) -AllowMissing
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Routine.App)) {
        return Get-CapsulenvInstalledAppProcessPlan `
            -App ([string]$Routine.App) `
            -BinName ([string]$Routine.BinName) `
            -Arguments @($Routine.Arguments) `
            -WorkingDirectory $workingDirectory `
            -ExecutionMode ([string]$Routine.Mode)
    }
    return New-CapsulenvProcessPlan `
        -Executable ([string]$Routine.Command) `
        -Arguments @($Routine.Arguments) `
        -WorkingDirectory $workingDirectory `
        -ExecutionMode ([string]$Routine.Mode) `
        -Metadata ([ordered]@{ Routine=[string]$Routine.Name })
}

function Invoke-CapsulenvRoutines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('OnEnter','OnExit','OnRehydrate','OnEject')]
        [string]$Trigger,
        [string]$Name = '',
        [switch]$Force
    )

    [void](Set-CapsulenvSessionEnvironment)
    $state = Import-CapsulenvRoutineState
    $nowUtc = [DateTime]::UtcNow
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($routine in @(Get-CapsulenvRoutineDefinitions -Trigger $Trigger)) {
        if (-not [string]::IsNullOrWhiteSpace($Name) -and -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$routine.Name, $Name)) {
            continue
        }
        if (-not [bool]$routine.Enabled) {
            $results.Add([pscustomobject][ordered]@{ Name=$routine.Name; Trigger=$Trigger; Status='Disabled'; Succeeded=$true; ExitCode=$null })
            continue
        }
        if (-not $Force.IsPresent -and -not (Test-CapsulenvRoutineDue -Routine $routine -State $state -NowUtc $nowUtc)) {
            $results.Add([pscustomobject][ordered]@{ Name=$routine.Name; Trigger=$Trigger; Status='Throttled'; Succeeded=$true; ExitCode=$null })
            continue
        }

        $attempt = [ordered]@{
            LastAttemptUtc = $nowUtc.ToString('o')
            LastTrigger = $Trigger
            LastSuccessUtc = $(if ($state.Contains([string]$routine.Name)) { [string]$state[[string]$routine.Name].LastSuccessUtc } else { '' })
            LastExitCode = $null
            LastError = ''
        }
        $state[[string]$routine.Name] = [pscustomobject]$attempt
        Export-CapsulenvRoutineState -State $state

        try {
            $plan = Get-CapsulenvRoutineProcessPlan -Routine $routine
            Clear-CapsulenvLastExitCode
            $output = Invoke-CapsulenvProcessPlan -Plan $plan
            $exitCode = if ([string]$plan.ExecutionMode -eq 'Detached') { 0 } else { Get-CapsulenvLastExitCode -Succeeded $? }
            $succeeded = ($exitCode -eq 0)
            $attempt.LastExitCode = $exitCode
            if ($succeeded) {
                $attempt.LastSuccessUtc = [DateTime]::UtcNow.ToString('o')
                $state[[string]$routine.Name] = [pscustomobject]$attempt
                Export-CapsulenvRoutineState -State $state
                $results.Add([pscustomobject][ordered]@{ Name=$routine.Name; Trigger=$Trigger; Status='Executed'; Succeeded=$true; ExitCode=$exitCode; Plan=$plan; Output=$output })
                continue
            }
            throw "Routine '$($routine.Name)' exited with code $exitCode."
        } catch {
            $attempt.LastError = [string]$_.Exception.Message
            $state[[string]$routine.Name] = [pscustomobject]$attempt
            Export-CapsulenvRoutineState -State $state
            $results.Add([pscustomobject][ordered]@{ Name=$routine.Name; Trigger=$Trigger; Status='Failed'; Succeeded=$false; ExitCode=$attempt.LastExitCode; Error=$attempt.LastError })
            if ([string]$routine.FailurePolicy -eq 'Stop') {
                throw
            }
            Write-CapsulenvMessage -Level Warning -Message "Capsule routine '$($routine.Name)' failed on ${Trigger}: $($attempt.LastError)"
        }
    }
    return $results.ToArray()
}

function Get-CapsulenvRoutineStatus {
    [CmdletBinding()]
    param()

    $state = Import-CapsulenvRoutineState
    foreach ($routine in @(Get-CapsulenvRoutineDefinitions)) {
        $entry = if ($state.Contains([string]$routine.Name)) { $state[[string]$routine.Name] } else { $null }
        [pscustomobject][ordered]@{
            Name = [string]$routine.Name
            Enabled = [bool]$routine.Enabled
            Trigger = @($routine.Trigger) -join ','
            Target = $(if (-not [string]::IsNullOrWhiteSpace([string]$routine.App)) { "app:$($routine.App)/$($routine.BinName)" } else { "command:$($routine.Command)" })
            MinimumIntervalSeconds = [int64]$routine.MinimumIntervalSeconds
            FailurePolicy = [string]$routine.FailurePolicy
            LastTrigger = $(if ($null -ne $entry) { [string]$entry.LastTrigger } else { '' })
            LastAttemptUtc = $(if ($null -ne $entry) { [string]$entry.LastAttemptUtc } else { '' })
            LastSuccessUtc = $(if ($null -ne $entry) { [string]$entry.LastSuccessUtc } else { '' })
            LastExitCode = $(if ($null -ne $entry) { $entry.LastExitCode } else { $null })
        }
    }
}

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvRoutineStatus, Invoke-CapsulenvRoutines

function Invoke-CapsulenvRoutineCommand {
    [CmdletBinding()]
    param([string[]]$Arguments = @())

    if ($Arguments.Count -lt 1) {
        Show-CapsulenvHelp -Topic routine
        return
    }
    $action = ([string]$Arguments[0]).ToLowerInvariant()
    $remaining = @($Arguments | Select-Object -Skip 1)
    switch ($action) {
        'list' {
            if ($remaining.Count -gt 0) {
                throw (New-CapsulenvCliUsageError -Message 'routine list accepts no additional arguments.' -Usage 'capsulenv routine list' -Topic routine)
            }
            Get-CapsulenvRoutineStatus | Format-Table -AutoSize
        }
        'run' {
            if ($remaining.Count -lt 1 -or $remaining.Count -gt 3) {
                throw (New-CapsulenvCliUsageError -Message 'routine run requires one lifecycle trigger and optional routine name/--force.' -Usage 'capsulenv routine run <OnEnter|OnExit|OnRehydrate|OnEject> [name] [--force]' -Topic routine)
            }
            $trigger = [string]$remaining[0]
            $force = $remaining -contains '--force'
            $names = @($remaining | Select-Object -Skip 1 | Where-Object { [string]$_ -ne '--force' })
            if ($names.Count -gt 1) {
                throw (New-CapsulenvCliUsageError -Message 'routine run accepts at most one routine name.' -Usage 'capsulenv routine run <OnEnter|OnExit|OnRehydrate|OnEject> [name] [--force]' -Topic routine)
            }
            $name = if ($names.Count -eq 1) { [string]$names[0] } else { '' }
            Invoke-CapsulenvRoutines -Trigger $trigger -Name $name -Force:$force | Format-Table -AutoSize
        }
        default {
            throw (New-CapsulenvCliUnknownActionError -Group routine -Action $action -Id 'Capsulenv.Cli.UnknownRoutineAction')
        }
    }
}
