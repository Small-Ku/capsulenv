function Get-CapsulenvSingBoxDefinition {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    return $configuration.SingBox
}

function Get-CapsulenvSingBoxExecutable {
    [CmdletBinding()]
    param()

    $definition = Get-CapsulenvSingBoxDefinition
    $parameters = @{ App = [string]$definition.App }
    foreach ($pair in @(
        [pscustomobject]@{ Config = 'ExecutablePath'; Parameter = 'RelativePath' },
        [pscustomobject]@{ Config = 'BinName'; Parameter = 'BinName' },
        [pscustomobject]@{ Config = 'ShortcutName'; Parameter = 'ShortcutName' }
    )) {
        if (
            $definition.ContainsKey($pair.Config) -and
            -not [string]::IsNullOrWhiteSpace([string]$definition[$pair.Config])
        ) {
            $parameters[$pair.Parameter] = [string]$definition[$pair.Config]
        }
    }
    return Resolve-CapsulenvScoopAppExecutable @parameters
}

function Get-CapsulenvSingBoxLaunchPlan {
    [CmdletBinding()]
    param([ValidateSet('Run', 'Check')][string]$Action = 'Run')

    $definition = Get-CapsulenvSingBoxDefinition
    $app = [string]$definition.App
    $executable = Get-CapsulenvSingBoxExecutable
    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add($(if ($Action -eq 'Check') { 'check' } else { 'run' }))

    $configDirectory = if ($definition.ContainsKey('ConfigDirectory')) { [string]$definition.ConfigDirectory } else { '' }
    $configPath = if ($definition.ContainsKey('ConfigPath')) { [string]$definition.ConfigPath } else { '' }
    $resolvedConfiguration = $null
    $configurationKind = $null
    if (-not [string]::IsNullOrWhiteSpace($configDirectory)) {
        $resolvedConfiguration = Resolve-CapsulenvScoopAppPersistPath -App $app -RelativePath $configDirectory
        if (-not (Test-Path -LiteralPath $resolvedConfiguration -PathType Container)) {
            throw "Configured sing-box directory is missing: $resolvedConfiguration"
        }
        $configurationKind = 'Directory'
        $arguments.Add('-C')
        $arguments.Add($resolvedConfiguration)
    } elseif (-not [string]::IsNullOrWhiteSpace($configPath)) {
        $resolvedConfiguration = Resolve-CapsulenvScoopAppPersistPath -App $app -RelativePath $configPath
        if (-not (Test-Path -LiteralPath $resolvedConfiguration -PathType Leaf)) {
            throw "Configured sing-box file is missing: $resolvedConfiguration"
        }
        $configurationKind = 'File'
        $arguments.Add('-c')
        $arguments.Add($resolvedConfiguration)
    } else {
        throw 'SingBox must configure ConfigPath or ConfigDirectory relative to the selected Scoop app persist root.'
    }

    if ($Action -eq 'Run') {
        foreach ($argument in @($definition.ExtraArguments)) {
            $arguments.Add([string]$argument)
        }
    }

    return [pscustomobject]@{
        App = $app
        Executable = $executable
        Configuration = $resolvedConfiguration
        ConfigurationKind = $configurationKind
        Arguments = $arguments.ToArray()
    }
}

function Test-CapsulenvSingBoxConfigured {
    [CmdletBinding()]
    param()

    try {
        $plan = Get-CapsulenvSingBoxLaunchPlan -Action Check
    } catch {
        return $false
    }
    if ($plan.ConfigurationKind -eq 'Directory') {
        return @(
            Get-ChildItem -LiteralPath $plan.Configuration -File -Filter '*.json' -ErrorAction SilentlyContinue
        ).Count -gt 0
    }
    try {
        $content = [System.IO.File]::ReadAllText([string]$plan.Configuration).Trim()
    } catch {
        return $false
    }
    return (
        -not [string]::IsNullOrWhiteSpace($content) -and
        $content -ne '{}'
    )
}

function Test-CapsulenvSingBoxConfiguration {
    [CmdletBinding()]
    param()

    $plan = Get-CapsulenvSingBoxLaunchPlan -Action Check
    Clear-CapsulenvLastExitCode
    $output = & $plan.Executable @($plan.Arguments) 2>&1
    $succeeded = $?
    $exitCode = Get-CapsulenvLastExitCode -Succeeded $succeeded
    return [pscustomobject]@{
        Valid = ($exitCode -eq 0)
        ExitCode = $exitCode
        App = $plan.App
        Configuration = $plan.Configuration
        Output = ($output -join [Environment]::NewLine)
    }
}

function Get-CapsulenvSingBoxProcesses {
    [CmdletBinding()]
    param([switch]$IncludeForeign)

    $definition = Get-CapsulenvSingBoxDefinition
    $app = [string]$definition.App
    $executable = Get-CapsulenvSingBoxExecutable
    $processName = [System.IO.Path]::GetFileNameWithoutExtension($executable)
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($process in @(Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = [string]$process.Path } catch {}
        $owned = $false
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            try { $owned = Test-CapsulenvScoopAppOwnsPath -App $app -Path $path } catch { $owned = $false }
        }
        if ($owned -or $IncludeForeign) {
            $results.Add([pscustomobject]@{
                Process = $process
                Path = $path
                CapsuleOwned = $owned
            })
        }
    }
    return $results.ToArray()
}

function Get-CapsulenvSingBoxStatus {
    [CmdletBinding()]
    param()

    $definition = Get-CapsulenvSingBoxDefinition
    $app = [string]$definition.App
    $installed = $true
    $executable = $null
    $availabilityError = $null
    try {
        $executable = Get-CapsulenvSingBoxExecutable
    } catch {
        $installed = $false
        $availabilityError = $_.Exception.Message
    }
    $configuration = $null
    if ($installed) {
        try { $configuration = (Get-CapsulenvSingBoxLaunchPlan -Action Run).Configuration } catch {}
    }
    $processes = if ($installed) { @(Get-CapsulenvSingBoxProcesses -IncludeForeign) } else { @() }
    return [pscustomobject]@{
        Enabled = [bool]$definition.Enabled
        AutoConnect = [bool]$definition.AutoConnect
        App = $app
        Installed = $installed
        Executable = $executable
        AvailabilityError = $availabilityError
        Configured = if ($installed) { Test-CapsulenvSingBoxConfigured } else { $false }
        Configuration = $configuration
        Running = @($processes | Where-Object { $_.CapsuleOwned }).Count -gt 0
        CapsuleOwnedPids = @($processes | Where-Object { $_.CapsuleOwned } | ForEach-Object { $_.Process.Id })
        ForeignProcesses = @($processes | Where-Object { -not $_.CapsuleOwned }).Count
    }
}

function Start-CapsulenvSingBox {
    [CmdletBinding()]
    param()

    $definition = Get-CapsulenvSingBoxDefinition
    if (-not [bool]$definition.Enabled) {
        throw 'sing-box integration is disabled.'
    }
    [void](Set-CapsulenvSessionEnvironment)
    # Fail with the selected manifest/executable error before process/config
    # probes can turn an absent or ambiguous app into a misleading config error.
    [void](Get-CapsulenvSingBoxExecutable)
    $existing = @(Get-CapsulenvSingBoxProcesses -IncludeForeign)
    $foreign = @($existing | Where-Object { -not $_.CapsuleOwned })
    if ($foreign.Count -gt 0) {
        throw 'A non-capsule process using the configured sing-box executable name is already running. Capsulenv will not reuse or stop it.'
    }
    if (@($existing | Where-Object { $_.CapsuleOwned }).Count -gt 0) {
        Write-CapsulenvMessage -Level Detail -Message 'Capsule-owned sing-box is already running.'
        return
    }
    if (-not (Test-CapsulenvSingBoxConfigured)) {
        throw 'sing-box is installed but its selected Scoop-persisted configuration is empty or missing.'
    }

    $check = Test-CapsulenvSingBoxConfiguration
    if (-not $check.Valid) {
        throw "sing-box configuration check failed (exit $($check.ExitCode)): $($check.Output)"
    }
    $plan = Get-CapsulenvSingBoxLaunchPlan -Action Run
    $launchArguments = @($plan.Arguments | ForEach-Object { ConvertTo-CapsulenvProcessArgument -Argument ([string]$_) })
    $process = Start-Process `
        -FilePath $plan.Executable `
        -ArgumentList $launchArguments `
        -WorkingDirectory (Split-Path -Parent $plan.Executable) `
        -PassThru
    Start-Sleep -Milliseconds 300
    if ($process.HasExited) {
        throw "sing-box exited immediately after launch (exit $($process.ExitCode))."
    }
    Write-CapsulenvMessage -Level Success -Message "sing-box started from Scoop app '$($plan.App)' (PID $($process.Id))."
}

function Stop-CapsulenvSingBox {
    [CmdletBinding()]
    param([switch]$Force)

    $records = @(Get-CapsulenvSingBoxProcesses -IncludeForeign)
    $foreign = @($records | Where-Object { -not $_.CapsuleOwned })
    if ($foreign.Count -gt 0) {
        throw 'A foreign sing-box process is running. Capsulenv will not stop a process it cannot prove belongs to the configured Scoop app.'
    }
    $owned = @($records | Where-Object { $_.CapsuleOwned })
    if ($owned.Count -eq 0) {
        return
    }
    if (-not $Force) {
        foreach ($record in $owned) {
            try { [void]$record.Process.CloseMainWindow() } catch {}
        }
        Start-Sleep -Milliseconds 500
    }
    $remaining = @($owned | Where-Object { $null -ne (Get-Process -Id $_.Process.Id -ErrorAction SilentlyContinue) })
    foreach ($record in $remaining) {
        Stop-Process -Id $record.Process.Id -Force:$Force -ErrorAction Stop
    }
}

function Initialize-CapsulenvSingBox {
    [CmdletBinding()]
    param()

    $definition = Get-CapsulenvSingBoxDefinition
    if (-not [bool]$definition.Enabled -or -not [bool]$definition.AutoConnect) {
        return
    }
    try {
        [void](Get-CapsulenvInstalledScoopApp -Selector ([string]$definition.App))
    } catch {
        Write-CapsulenvMessage -Level Detail -Message "Configured sing-box Scoop app '$($definition.App)' is unavailable; automatic private-network connection is skipped. $($_.Exception.Message)"
        return
    }
    if (-not (Test-CapsulenvSingBoxConfigured)) {
        Write-CapsulenvMessage -Level Detail -Message 'sing-box is installed but no non-empty persisted configuration is present; automatic connection is skipped.'
        return
    }
    try {
        Start-CapsulenvSingBox
    } catch {
        Write-CapsulenvMessage -Level Warning -Message "Automatic sing-box connection was skipped: $($_.Exception.Message)"
    }
}

function Invoke-CapsulenvSingBoxCommand {
    [CmdletBinding()]
    param([string[]]$Arguments = @())

    $action = if ($Arguments.Count -gt 0) { [string]$Arguments[0] } else { 'status' }
    $remaining = @($Arguments | Select-Object -Skip 1)
    switch ($action.ToLowerInvariant()) {
        'status' {
            if ($remaining.Count -gt 0) { throw 'Usage: sing-box status' }
            Get-CapsulenvSingBoxStatus | Format-List
        }
        'check' {
            if ($remaining.Count -gt 0) { throw 'Usage: sing-box check' }
            Test-CapsulenvSingBoxConfiguration | Format-List
        }
        'connect' {
            if ($remaining.Count -gt 0) { throw 'Usage: sing-box connect' }
            Start-CapsulenvSingBox
        }
        'disconnect' {
            $unknown = @($remaining | Where-Object { $_ -ne '--force' })
            if ($unknown.Count -gt 0 -or @($remaining | Where-Object { $_ -eq '--force' }).Count -gt 1) {
                throw 'Usage: sing-box disconnect [--force]'
            }
            Stop-CapsulenvSingBox -Force:($remaining -contains '--force')
        }
        default { throw "Unknown sing-box action: $action. Use status, check, connect, or disconnect." }
    }
}

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvSingBoxStatus, Start-CapsulenvSingBox, Stop-CapsulenvSingBox, Test-CapsulenvSingBoxConfiguration
