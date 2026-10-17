function Invoke-CapsulenvChildShell {
    [CmdletBinding()]
    param(
        [string]$Command,
        [ValidateSet('ShellOnly', 'User')]
        [string]$IntegrationMode = (Get-CapsulenvInstallMode),
        [switch]$SkipUserIntegrationSync
    )

    [void](Set-CapsulenvSessionEnvironment -IntegrationMode $IntegrationMode)
    $powerShellRequirement = (Get-CapsulenvInteractivePowerShellRequirement -Criticality required).Requirement
    $activationSnapshot = $null
    $powerShellProgram = $null

    # Freeze an already-published generation once; foreground activation does
    # not download packages or extract a portable seed.
    $active = Get-CapsulenvActiveGeneration
    if ($null -ne $active) {
        $activationSnapshot = New-CapsulenvActivationSnapshot -ActiveGeneration $active
        try {
            $powerShellProgram = Get-CapsulenvActiveGenerationProgram -Requirement $powerShellRequirement -ActivationSnapshot $activationSnapshot
        } catch {}
    }
    if ($null -eq $powerShellProgram) {
        $hostCandidates = @(Get-CapsulenvProgramCandidates -Requirement $powerShellRequirement)
        $resolution = Resolve-CapsulenvProgram -Requirement $powerShellRequirement -Candidates $hostCandidates
        if ($resolution.Succeeded) {
            $ensured = Ensure-CapsulenvProgramGeneration -Requirement $powerShellRequirement -HostCandidates $hostCandidates -SeedCandidates @() -ProviderCandidates @()
            $activationSnapshot = $ensured.ActivationSnapshot
            $powerShellProgram = Get-CapsulenvActiveGenerationProgram -Requirement $powerShellRequirement -ActivationSnapshot $activationSnapshot
        }
    }

    $pending = @(Get-CapsulenvShellPreparationPending -ActivationSnapshot $activationSnapshot)
    $workerStarted = $false
    if ($pending.Count -gt 0) {
        $workerStarted = [bool](Start-CapsulenvShellPreparationWorker -Pending $pending)
    }

    if ($null -eq $powerShellProgram) {
        # A degraded control host is NOT a pwsh Program candidate or generation.
        $fallback = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        if (-not (Test-CapsulenvWindows) -or -not (Test-Path -LiteralPath $fallback -PathType Leaf)) {
            throw 'PowerShell 7 is unavailable and Windows PowerShell 5.1 is unavailable for the degraded shell.'
        }
        [void](Initialize-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity))
        [void](Initialize-CapsulenvSession -Role activation -Provenance 'capsulenv:degraded-shell')
        $paths = Get-CapsulenvPowerShellStatePaths -Create
        $history = ConvertTo-CapsulenvPowerShellLiteral -Value ([string]$paths.HistoryPath)
        $bootstrap = '$setHistory = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue; if ($null -ne $setHistory) { Set-PSReadLineOption -HistorySavePath ' + $history + ' }'
        $arguments = @('-NoLogo', '-NoProfile', '-NoExit', '-Command', $bootstrap)
        if (-not [string]::IsNullOrWhiteSpace($Command)) {
            $arguments = @('-NoLogo', '-NoProfile', '-Command', ($bootstrap + '; ' + $Command))
        }
        $planParams = @{
            Executable = $fallback
            Arguments = $arguments
            Environment = [ordered]@{ CAPSULENV_SHELL_STATUS='degraded'; CAPSULENV_SHELL_REASON='powershell7-unavailable' }
            Metadata = [ordered]@{ IntegrationMode=$IntegrationMode; ShellStatus='degraded' }
        }
        $launchPlan = New-CapsulenvProcessPlan @planParams
        $preparationMessage = if ($workerStarted) {
            'PowerShell 7 background preparation was started.'
        } else {
            'Background preparation was not started; use capsulenv prepare status or capsulenv prepare shell.'
        }
        Write-CapsulenvMessage -Level Warning -Message (
            'DEGRADED shell: using Windows PowerShell 5.1. PowerShell 7 profile and optional integrations are not active. ' + $preparationMessage
        )
        Invoke-CapsulenvOwnedProcessPlan -Plan $launchPlan -Role child-shell -Provenance ('capsulenv/degraded-shell/{0}' -f $IntegrationMode)
        return
    }

    Initialize-CapsulenvIntegrations -IntegrationMode $IntegrationMode -ActivationSnapshot $activationSnapshot
    $bindingParams = @{
        Requirement = $powerShellRequirement
        Program = $powerShellProgram
        ActivationSnapshot = $activationSnapshot
        Criticality = 'required'
    }
    $binding = Resolve-CapsulenvPowerShellBinding @bindingParams
    if (-not $binding.Succeeded) { throw 'Required interactive pwsh binding could not be established.' }
    $launchArguments = New-Object System.Collections.Generic.List[string]
    foreach ($argument in @($binding.LaunchArguments)) {
        if (-not [string]::IsNullOrWhiteSpace($Command) -and [string]$argument -eq '-NoExit') { continue }
        $launchArguments.Add([string]$argument)
    }
    if (-not [string]::IsNullOrWhiteSpace($Command)) {
        $commandIndex = $launchArguments.IndexOf('-Command')
        if ($commandIndex -lt 0 -or $commandIndex -ge ($launchArguments.Count - 1)) {
            throw 'PowerShell binding did not provide a command launch boundary.'
        }
        $launchArguments[$commandIndex + 1] = [string]$binding.BootstrapCommand + '; ' + $Command
    }
    $environment = [ordered]@{ CAPSULENV_SHELL_STATUS='ready' }
    if ($binding.Environment -is [System.Collections.IDictionary]) {
        foreach ($key in $binding.Environment.Keys) {
            $environment[[string]$key] = [string]$binding.Environment[$key]
        }
    } else {
        foreach ($property in @($binding.Environment.PSObject.Properties)) {
            $environment[[string]$property.Name] = [string]$property.Value
        }
    }
    $launchPlan = New-CapsulenvProcessPlan -Executable ([string]$binding.Program.Executable) -Arguments $launchArguments.ToArray() -WorkingDirectory (Split-Path -Parent ([string]$binding.Program.Executable)) -Environment $environment -Metadata ([ordered]@{
        IntegrationMode = $IntegrationMode
        ShellStatus = 'ready'
        ProfilePath = $binding.ProfilePath
        HistoryPath = $binding.HistoryPath
        PSModulePath = $binding.PSModulePath
        BootstrapPath = $binding.BootstrapPath
    })
    if ([string]::IsNullOrWhiteSpace($Command)) {
        Write-CapsulenvMessage -Level Success -Message "capsulenv active at $env:CAPSULENV_ROOT"
    }
    [void](Invoke-CapsulenvRoutines -Trigger OnEnter)
    try {
        Invoke-CapsulenvOwnedProcessPlan -Plan $launchPlan -Role child-shell -Provenance ('capsulenv/child-shell/{0}' -f $IntegrationMode)
    } finally {
        if ($null -ne (Get-Command Stop-CapsulenvActiveSessionServices -ErrorAction SilentlyContinue)) {
            [void](Stop-CapsulenvActiveSessionServices)
        }
        [void](Invoke-CapsulenvRoutines -Trigger OnExit)
    }
}
function Invoke-CapsulenvExternalCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @()
    )

    Initialize-CapsulenvIntegrations
    $plan = New-CapsulenvProcessPlan -Executable $Command -Arguments $Arguments
    Invoke-CapsulenvProcessPlan -Plan $plan
}

