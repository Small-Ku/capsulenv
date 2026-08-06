function New-CapsulenvCheckResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail,
        [ValidateSet('Required', 'Optional')][string]$Importance = 'Required'
    )

    [pscustomobject]@{
        Name = $Name
        Passed = $Passed
        Importance = $Importance
        Detail = $Detail
    }
}

function Invoke-CapsulenvDoctor {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration -Refresh
    $results = New-Object System.Collections.Generic.List[object]
    $results.Add((New-CapsulenvCheckResult -Name 'Windows host' -Passed (Test-CapsulenvWindows) -Detail 'capsulenv targets Windows 10/11.'))

    $scoopRoot = Get-CapsulenvScoopRoot
    $results.Add((New-CapsulenvCheckResult `
        -Name 'Portable Scoop root' `
        -Passed (Test-Path -LiteralPath $scoopRoot -PathType Container) `
        -Detail $scoopRoot))

    $scoopGlobalRoot = Get-CapsulenvScoopGlobalRoot
    $results.Add((New-CapsulenvCheckResult `
        -Name 'Portable Scoop global root' `
        -Passed (-not [string]::IsNullOrWhiteSpace($scoopGlobalRoot)) `
        -Detail $scoopGlobalRoot))

    $scoopExecutable = Get-CapsulenvScoopExecutable
    $results.Add((New-CapsulenvCheckResult `
        -Name 'Scoop command' `
        -Passed ($null -ne $scoopExecutable) `
        -Detail $(if ($scoopExecutable) { $scoopExecutable } else { 'Not found' })))

    $persistRoot = Join-Path $scoopRoot 'persist'
    $results.Add((New-CapsulenvCheckResult `
        -Name 'Scoop persist store' `
        -Passed (Test-Path -LiteralPath $persistRoot -PathType Container) `
        -Importance Optional `
        -Detail $persistRoot))

    $runner = Get-CapsulenvScoopReplayScriptPath
    $results.Add((New-CapsulenvCheckResult `
        -Name 'Lifecycle replay runner' `
        -Passed (Test-Path -LiteralPath $runner -PathType Leaf) `
        -Detail $runner))

    $rehydrationRequired = Test-CapsulenvScoopRehydrationRequired
    $results.Add((New-CapsulenvCheckResult `
        -Name 'Relocation rehydration' `
        -Passed (-not $rehydrationRequired) `
        -Importance Optional `
        -Detail $(if ($rehydrationRequired) { 'Required before normal use' } else { 'Current root and host match the last successful run' })))

    if ($configuration.Bitwarden.Enabled) {
        $bitwarden = Get-CapsulenvBitwardenExecutable
        $results.Add((New-CapsulenvCheckResult `
            -Name 'Bitwarden desktop' `
            -Passed ($null -ne $bitwarden) `
            -Importance Optional `
            -Detail $(if ($bitwarden) { $bitwarden } else { 'Not found' })))

        if ($bitwarden) {
            try {
                $bitwardenStatus = Get-CapsulenvBitwardenSshAgentStatus
                $results.Add((New-CapsulenvCheckResult `
                    -Name 'Bitwarden SSH Agent setting' `
                    -Passed ([bool]$bitwardenStatus.DesktopSettingEnabled) `
                    -Importance Optional `
                    -Detail ("Enabled={0}; Authorization={1}" -f $bitwardenStatus.DesktopSettingEnabled, $bitwardenStatus.Authorization)))
            } catch {
                $results.Add((New-CapsulenvCheckResult `
                    -Name 'Bitwarden SSH Agent setting' `
                    -Passed $false `
                    -Importance Optional `
                    -Detail $_.Exception.Message))
            }
        }

        if (Test-CapsulenvWindows) {
            $service = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
            $serviceInfo = if ($service) { Get-CimInstance Win32_Service -Filter "Name='ssh-agent'" -ErrorAction SilentlyContinue } else { $null }
            $startMode = if ($serviceInfo) { [string]$serviceInfo.StartMode } else { 'Unknown' }
            $serviceDetail = if (-not $service) {
                'Service is not installed'
            } else {
                "Status=$($service.Status); StartMode=$startMode"
            }
            $servicePassed = (-not $service) -or (
                $service.Status -eq 'Stopped' -and $startMode -eq 'Disabled'
            )
            $results.Add((New-CapsulenvCheckResult `
                -Name 'Windows ssh-agent conflict' `
                -Passed $servicePassed `
                -Importance Optional `
                -Detail $serviceDetail))
        }
    }

    foreach ($browser in @('Firefox', 'Zen')) {
        $definition = Get-CapsulenvBrowserDefinition -Browser $browser
        if (-not $definition.Enabled) {
            continue
        }
        $executable = Get-CapsulenvBrowserExecutable -Browser $browser
        $results.Add((New-CapsulenvCheckResult `
            -Name "$browser executable" `
            -Passed ($null -ne $executable) `
            -Importance Optional `
            -Detail $(if ($executable) { $executable } else { 'Not found' })))
    }

    $results | Format-Table -AutoSize | Out-Host
    $requiredFailures = @($results | Where-Object { -not $_.Passed -and $_.Importance -eq 'Required' })
    if ($requiredFailures.Count -gt 0) {
        throw "capsulenv doctor found $($requiredFailures.Count) required failure(s)."
    }
    return @($results)
}

function Initialize-CapsulenvIntegrations {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    if (
        $configuration.Scoop.RehydrateOnRelocation -and
        (Test-CapsulenvScoopRehydrationRequired)
    ) {
        Write-CapsulenvMessage -Level Info -Message 'Portable Scoop root or host changed; rehydrating installed apps...'
        Invoke-CapsulenvScoopRehydrate
    }
    Initialize-CapsulenvBitwarden
}

function Initialize-Capsulenv {
    [CmdletBinding()]
    param([switch]$SkipHooks)

    [void](Get-CapsulenvConfiguration -Refresh)
    [void](Set-CapsulenvSessionEnvironment)
    Invoke-CapsulenvScoopRehydrate -SkipHooks:$SkipHooks
    Initialize-CapsulenvBitwarden

    $context = Get-CapsulenvContext
    Write-CapsulenvMessage -Level Success -Message "capsulenv initialized at $($context.Root)"
}

##MOD_EXEC## Export-ModuleMember -Function Initialize-Capsulenv, Invoke-CapsulenvDoctor
