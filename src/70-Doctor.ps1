            -Detail ("{0} installed app(s); {1} differ from local bucket manifests" -f $drift.Count, $drifted.Count)))
    } catch {
        $results.Add((New-CapsulenvCheckResult -Name 'Scoop version drift' -Passed $false -Importance Optional -Detail $_.Exception.Message))
    }

    foreach ($registeredResult in @(Invoke-CapsulenvDoctorChecks)) {
        $results.Add($registeredResult)
    }

    Write-CapsulenvDoctorReport -Results $results.ToArray()
    $requiredFailures = @($results | Where-Object { $_.Importance -eq 'Required' -and $_.Status -in @('Unavailable', 'Failed') })
    if ($requiredFailures.Count -gt 0) {
        throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Doctor.RequiredChecksFailed' -Message "capsulenv doctor found $($requiredFailures.Count) required failure(s)." -Context ([ordered]@{ CheckIds = @($requiredFailures.Id) }) -Remediation @('Review failed doctor checks and their remediation before retrying.'))
    }
    return $results.ToArray()
}

function Initialize-CapsulenvIntegrations {
    [CmdletBinding()]
    param(
        [ValidateSet('ShellOnly', 'User')]
        [string]$IntegrationMode = (Get-CapsulenvInstallMode)
    )

    [void](Initialize-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity))
    $session = Initialize-CapsulenvSession -Role activation -Provenance ('capsulenv:{0}' -f $IntegrationMode)
    $configuration = Get-CapsulenvConfiguration
    if ($configuration.Bitwarden.Enabled) {
        $endpoint = if ($configuration.Bitwarden.SetSshAuthSock) { '\\.\pipe\openssh-ssh-agent' } else { [Environment]::GetEnvironmentVariable('SSH_AUTH_SOCK', 'Process') }
        try {
            $bitwardenRequirement = (Get-CapsulenvBitwardenProgramRequirement -App ([string]$configuration.Bitwarden.App) -Criticality optional).Requirement
            $bitwardenProgram = Get-CapsulenvActiveGenerationProgram -Requirement $bitwardenRequirement
            $resolvedBinding = Resolve-CapsulenvBitwardenBinding -App ([string]$configuration.Bitwarden.App) -Requirement $bitwardenRequirement -Program $bitwardenProgram -Criticality optional -SessionId $session.SessionId
            if ($resolvedBinding.Succeeded) {
                $agentBinding = [pscustomobject][ordered]@{
                    Endpoint = $endpoint
                    ProgramProvenance = [string]$resolvedBinding.Program.Provenance
                    ProcessId = [int]$resolvedBinding.ProcessRecord.PID
                }
                $binding = Invoke-CapsulenvBitwardenSessionIntegration -App ([string]$configuration.Bitwarden.App) -SshAuthSock $endpoint -AgentBinding $agentBinding -ResolvedBinding $resolvedBinding -Criticality optional -SessionId $session.SessionId
            } else {
                $binding = $resolvedBinding
            }
            if ($binding.Succeeded) {
                Write-CapsulenvMessage -Level Detail -Message 'Bitwarden activation uses the attach-only binding; foreign process lifecycle remains outside Capsulenv authority.'
            }
        } catch {
            Write-CapsulenvMessage -Level Warning -Message "Optional Bitwarden attach integration was not activated: $($_.Exception.Message)"
        }
    }
    $sessionServiceConfigPath = Join-Path (Get-CapsulenvContext).Root 'state/portable/sing-box/config.json'
    if (Test-Path -LiteralPath $sessionServiceConfigPath -PathType Leaf) {
        try {
            $serviceRequirement = New-CapsulenvProgramRequirement -Name 'sing-box' -RequiredCapabilities @('proxy') -AllowedProviders @('host-scoop', 'capsulenv-local', 'seed', 'provider')
            $servicePlacement = Get-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity)
            $serviceProbes = New-CapsulenvSessionServiceTcpProbes -ConfigPath $sessionServiceConfigPath
            $serviceDefinition = New-CapsulenvSessionServiceDefinition `
                -Name 'sing-box' `
                -Requirement $serviceRequirement `
                -Criticality optional `
                -ConfigPath $sessionServiceConfigPath `
                -RuntimeRoot (Join-Path $servicePlacement.ScratchRoot 'session-service') `
                -LogRoot (Join-Path $servicePlacement.ScratchRoot 'session-service/logs') `
                -ReadinessProbe $serviceProbes.ReadinessProbe `
                -HealthProbe $serviceProbes.HealthProbe
            $serviceProgram = Get-CapsulenvActiveGenerationProgram -Requirement $serviceRequirement
            $serviceBinding = Start-CapsulenvSessionService -Definition $serviceDefinition -Program $serviceProgram -SessionId $session.SessionId
            if ($serviceBinding.Succeeded) {
                Write-CapsulenvMessage -Level Detail -Message 'Configured session service attached through the generic SessionService lifecycle.'
            }
        } catch {
            Write-CapsulenvMessage -Level Warning -Message "Optional configured session service was not activated: $($_.Exception.Message)"
        }
    }
    Write-CapsulenvMessage -Level Detail -Message 'Activation fast path established host placement and session identity; repair and legacy projection reconciliation require explicit commands.'
}

function Initialize-Capsulenv {
    [CmdletBinding()]
    param(
        [switch]$SkipHooks,
        [switch]$SkipPersistRepairs,
        [switch]$SkipToolRepairs,
        [switch]$StrictToolRepairs
    )

    [void](Get-CapsulenvConfiguration -Refresh)
    [void](Set-CapsulenvSessionEnvironment)
    [void](Initialize-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity))
    $session = Initialize-CapsulenvSession -Role activation -Provenance 'capsulenv:init'

