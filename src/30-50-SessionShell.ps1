function Invoke-CapsulenvChildShell {
    [CmdletBinding()]
    param(
        [string]$Command,
        [ValidateSet('ShellOnly', 'User')]
        [string]$IntegrationMode = (Get-CapsulenvInstallMode),
        [switch]$SkipUserIntegrationSync
    )

    Initialize-CapsulenvIntegrations -IntegrationMode $IntegrationMode
    if (-not $SkipUserIntegrationSync -and $IntegrationMode -eq 'User') {
        # A normal `capsulenv.cmd` activation must observe persistent User
        # integration config changes too. Previously DefaultBrowser was parsed
        # and validated here but only synchronized by install-user/user-shell,
        # which made changing it on an already-integrated host look like a no-op.
        Sync-CapsulenvConfiguredDefaultBrowser
    }

    $shellPath = Get-CapsulenvInteractivePowerShellExecutable
    $launchPlan = Get-CapsulenvPowerShellChildLaunchPlan `
        -ShellPath $shellPath `
        -IntegrationMode $IntegrationMode `
        -Command $Command
    if ([string]::IsNullOrWhiteSpace($Command)) {
        Write-CapsulenvMessage -Level Success -Message "capsulenv active at $env:CAPSULENV_ROOT"
    }
    [void](Invoke-CapsulenvRoutines -Trigger OnEnter)
    try {
        Invoke-CapsulenvProcessPlan -Plan $launchPlan
    } finally {
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
