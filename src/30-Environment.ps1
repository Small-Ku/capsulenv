    if ((Test-Path -LiteralPath $sshAgentStatePath -PathType Leaf) -and -not (Test-CapsulenvAdministrator)) {
        throw 'User-mode Bitwarden setup changed the Windows ssh-agent service. Run restore-user from an elevated terminal so Capsulenv can restore that machine-level state before returning to ShellOnly.'
    }
    Assert-CapsulenvDefaultBrowserRestorable
    if (Test-Path -LiteralPath $sshAgentStatePath -PathType Leaf) {
        Restore-CapsulenvWindowsSshAgent -Confirm:$false
    }
    [void](Restore-CapsulenvGitOpenSshGlobal -IfPresent)
    Restore-CapsulenvDefaultBrowserRegistration
    Remove-CapsulenvUserStartMenuShortcuts

    $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
    foreach ($property in $backup.PSObject.Properties) {
        $entry = $property.Value
        $value = if ($entry.Exists) { [string]$entry.Value } else { $null }
        [Environment]::SetEnvironmentVariable($property.Name, $value, 'User')
    }
    Remove-Item -LiteralPath $backupPath -Force
    Set-CapsulenvInstallMode -Mode ShellOnly
    [Environment]::SetEnvironmentVariable('CAPSULENV_MODE', 'ShellOnly', 'Process')
    try {
        Initialize-CapsulenvGitOpenSshSession
    } catch {
        Write-CapsulenvMessage -Level Warning -Message "ShellOnly mode was restored, but the recorded Bitwarden Git/OpenSSH session intent could not be activated: $($_.Exception.Message)"
    }
    Write-CapsulenvMessage -Level Success -Message 'Capsulenv-owned User environment and reversible Bitwarden integrations restored; capsulenv is shell-only again.'
}

function Invoke-CapsulenvChildShell {
    [CmdletBinding()]
    param(
        [string]$Command,
        [ValidateSet('ShellOnly', 'User')]
        [string]$IntegrationMode = (Get-CapsulenvInstallMode),
        [switch]$SkipUserIntegrationSync
    )

    [void](Set-CapsulenvSessionEnvironment -IntegrationMode $IntegrationMode)
    Initialize-CapsulenvIntegrations -IntegrationMode $IntegrationMode
    if (-not $SkipUserIntegrationSync -and $IntegrationMode -eq 'User') {
        # A normal `capsulenv.cmd` activation must observe persistent User
        # integration config changes too. Previously DefaultBrowser was parsed
        # and validated here but only synchronized by install-user/user-shell,
        # which made changing it on an already-integrated host look like a no-op.
        Sync-CapsulenvConfiguredDefaultBrowser
    }

    $powerShellRequirement = (Get-CapsulenvInteractivePowerShellRequirement -Criticality required).Requirement
    $powerShellProgram = Get-CapsulenvActiveGenerationProgram -Requirement $powerShellRequirement
    $binding = Resolve-CapsulenvPowerShellBinding -Requirement $powerShellRequirement -Program $powerShellProgram -Criticality required
    if (-not $binding.Succeeded) {
        throw 'Required interactive pwsh binding could not be established.'
    }
    $launchArguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @($binding.LaunchArguments)) {
        if (-not ([string]::IsNullOrWhiteSpace($Command)) -and [string]$argument -eq '-NoExit') {
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
    $planParameters = @{
        Executable = [string]$binding.Program.Executable
        Arguments = $launchArguments.ToArray()
        WorkingDirectory = (Split-Path -Parent ([string]$binding.Program.Executable))
        Environment = ([System.Collections.IDictionary]$binding.Environment)
        Metadata = [ordered]@{
            IntegrationMode = $IntegrationMode
            ProfilePath = $binding.ProfilePath
            HistoryPath = $binding.HistoryPath
            PSModulePath = $binding.PSModulePath
            BootstrapPath = $binding.BootstrapPath
        }
    }
    $launchPlan = New-CapsulenvProcessPlan @planParameters
    if ([string]::IsNullOrWhiteSpace($Command)) {
        Write-CapsulenvMessage -Level Success -Message "capsulenv active at $env:CAPSULENV_ROOT"
    }
    [void](Invoke-CapsulenvRoutines -Trigger OnEnter)
    try {
        Invoke-CapsulenvOwnedProcessPlan -Plan $launchPlan -Role child-shell -Provenance ('capsulenv/child-shell/{0}' -f $IntegrationMode)
    } finally {
        [void](Stop-CapsulenvActiveSessionServices)
        [void](Invoke-CapsulenvRoutines -Trigger OnExit)
    }
}

function Invoke-CapsulenvExternalCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @()
    )

    [void](Set-CapsulenvSessionEnvironment)
