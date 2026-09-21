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
    $ensure = Ensure-CapsulenvProgramGeneration -Requirement $powerShellRequirement
    if ($null -eq $ensure -or -not [bool]$ensure.Succeeded -or $null -eq $ensure.ActivationSnapshot) {
        throw 'Required interactive pwsh generation could not provide an activation snapshot.'
    }
    $activationSnapshot = $ensure.ActivationSnapshot
    Initialize-CapsulenvIntegrations -IntegrationMode $IntegrationMode -ActivationSnapshot $activationSnapshot
    $powerShellProgram = Get-CapsulenvActiveGenerationProgram `
        -Requirement $powerShellRequirement `
        -ActivationSnapshot $activationSnapshot
    $binding = Resolve-CapsulenvPowerShellBinding `
        -Requirement $powerShellRequirement `
        -Program $powerShellProgram `
        -ActivationSnapshot $activationSnapshot `
        -Criticality required
    if (-not $binding.Succeeded) {
        throw 'Required interactive pwsh binding could not be established.'
    }
    $launchArguments = New-Object System.Collections.Generic.List[string]
    foreach ($argument in @($binding.LaunchArguments)) {
        if (-not [string]::IsNullOrWhiteSpace($Command) -and [string]$argument -eq '-NoExit') {
            continue
        }
        $launchArguments.Add([string]$argument)
    }
    if (-not [string]::IsNullOrWhiteSpace($Command)) {
        $commandIndex = $launchArguments.IndexOf('-Command')
        if ($commandIndex -lt 0 -or $commandIndex -ge ($launchArguments.Count - 1)) {
            throw 'PowerShell binding did not provide a command launch boundary.'
        }
        $launchArguments[$commandIndex + 1] = [string]$binding.BootstrapCommand + '; ' + $Command
    }
    $launchPlan = New-CapsulenvProcessPlan `
        -Executable ([string]$binding.Program.Executable) `
        -Arguments $launchArguments.ToArray() `
        -WorkingDirectory (Split-Path -Parent ([string]$binding.Program.Executable)) `
        -Environment ([System.Collections.IDictionary]$binding.Environment) `
        -Metadata ([ordered]@{
            IntegrationMode = $IntegrationMode
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
        Invoke-CapsulenvOwnedProcessPlan `
            -Plan $launchPlan `
            -Role child-shell `
            -Provenance ('capsulenv/child-shell/{0}' -f $IntegrationMode)
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
