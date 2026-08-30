function Write-CapsulenvDoctorReport {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Results)

    $Results | Select-Object Name, Area, Status, Importance | Format-Table -AutoSize | Out-Host
    $attention = @($Results | Where-Object { $_.Status -in @('Advisory', 'Unavailable', 'Failed') })
    if ($attention.Count -eq 0) { return }
    Write-Host ''
    Write-Host 'Details for checks requiring attention:'
    foreach ($result in $attention) {
        Write-Host ('[{0}] {1}' -f $result.Status.ToUpperInvariant(), $result.Name)
        $detail = if (-not [string]::IsNullOrWhiteSpace([string]$result.Detail)) { $result.Detail } else { $result.Summary }
        if (-not [string]::IsNullOrWhiteSpace([string]$detail)) { Write-Host ('  {0}' -f $detail) }
        foreach ($step in @($result.Remediation)) { Write-Host ('  remediation: {0}' -f $step) }
    }
}

function Invoke-CapsulenvDoctor {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration -Refresh
    $results = New-Object System.Collections.Generic.List[object]
    $results.Add((New-CapsulenvCheckResult -Name 'Windows host' -Passed (Test-CapsulenvWindows) -Detail 'capsulenv targets Windows 10/11.'))

    # Scoop health checks are registered by the Scoop subsystem. These roots are
    # still needed here for the legacy install-mode ownership check below.
    $scoopRoot = Get-CapsulenvScoopRoot
    $scoopGlobalRoot = Get-CapsulenvScoopGlobalRoot

    $installMode = Get-CapsulenvInstallMode
    $modePassed = $true
    $modeDetail = if ($installMode -eq 'User') {
        try {
            $userScoop = [Environment]::GetEnvironmentVariable('SCOOP', 'User')
            $userGlobal = [Environment]::GetEnvironmentVariable('SCOOP_GLOBAL', 'User')
            $userCache = [Environment]::GetEnvironmentVariable('SCOOP_CACHE', 'User')
            $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
            $environmentPlanForMode = Get-CapsulenvEnvironmentPlan
            $missingManagedPath = @(
                $environmentPlanForMode.PathEntries | Where-Object {
                    $entry = [regex]::Escape(([string]$_).TrimEnd('\', '/'))
                    -not ([string]$userPath -match "(?i)(^|;)$entry(?=;|$)")
                }
            )
            $modePassed = (
                [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$userScoop, [string]$scoopRoot) -and
                [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$userGlobal, [string]$scoopGlobalRoot) -and
                [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$userCache, [string](Resolve-CapsulenvPath -Path ([string]$configuration.Scoop.Cache) -AllowMissing)) -and
                $missingManagedPath.Count -eq 0
            )
            "User; SCOOP=$userScoop; SCOOP_GLOBAL=$userGlobal; SCOOP_CACHE=$userCache; missing managed PATH entries=$($missingManagedPath.Count)"
        } catch {
            'User; user environment could not be inspected on this host'
        }
    } else {
        try {
            $persistentScoop = [Environment]::GetEnvironmentVariable('SCOOP', 'User')
            $modePassed = -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$persistentScoop, [string]$scoopRoot)
            if ($modePassed) {
                'ShellOnly; capsule Scoop is process-scoped and persistent user Scoop ownership is untouched'
            } else {
                'ShellOnly state conflicts with a persistent User SCOOP pointing at this capsule; run restore-user or install-user to resolve ownership'
            }
        } catch {
            'ShellOnly; persistent user environment could not be inspected on this host'
        }
    }
    $results.Add((New-CapsulenvCheckResult `
        -Name 'Capsulenv install mode' `
        -Passed $modePassed `
        -Importance Optional `
        -Detail $modeDetail))

    $capsuleId = Get-CapsulenvIdentity
    $results.Add((New-CapsulenvCheckResult `
        -Name 'Capsule identity' `
        -Passed (-not [string]::IsNullOrWhiteSpace($capsuleId)) `
        -Importance Optional `
        -Detail $capsuleId))

    $scratchPath = Get-CapsulenvScratchPath
    $results.Add((New-CapsulenvCheckResult `
        -Name 'Host-local scratch' `
        -Passed (-not $scratchPath.StartsWith((Get-CapsulenvContext).Root, [System.StringComparison]::OrdinalIgnoreCase)) `
        -Importance Optional `
        -Detail $scratchPath))

    $toolStoragePlan = Get-CapsulenvToolStoragePlan
    $toolPathValues = @($toolStoragePlan.Directories)
    $missingToolDirectories = @($toolPathValues | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Container) })
    $missingToolFiles = @($toolStoragePlan.Files | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    $results.Add((New-CapsulenvCheckResult `
        -Name 'Portable tool storage' `
        -Passed $toolStoragePlan.Enabled `
        -Importance Optional `
        -Detail $(if (-not $toolStoragePlan.Enabled) {
            'Disabled'
        } else {
            "$($toolStoragePlan.Locations.Count) location(s); $($missingToolDirectories.Count) directorie(s) and $($missingToolFiles.Count) config file(s) will be created on first session/cache init"
        })))

    $environmentPlan = Get-CapsulenvEnvironmentPlan
    $moduleRoots = @($environmentPlan.ModulePathEntries)
    $missingModuleRoots = @($moduleRoots | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Container) })
    $results.Add((New-CapsulenvCheckResult `
        -Name 'Portable PowerShell modules' `
        -Passed ($moduleRoots.Count -gt 0) `
        -Importance Optional `
        -Detail $(if ($moduleRoots.Count -eq 0) {
            'No module roots configured'
        } else {
            "InstallRoot=$($moduleRoots[0]); $($missingModuleRoots.Count) path(s) will be created on first session"
        })))

    $projectProfiles = @($configuration.ToolStorage.ProjectLinks.Keys)
    $results.Add((New-CapsulenvCheckResult `
        -Name 'Project cache links' `
        -Passed ($projectProfiles.Count -gt 0) `
        -Importance Optional `
        -Detail $(if ($projectProfiles.Count -gt 0) { $projectProfiles -join ', ' } else { 'No profiles configured' })))

    if ($configuration.Bitwarden.Enabled) {
        $bitwarden = $null
        try {
            $bitwarden = Get-CapsulenvBitwardenExecutable
            $results.Add((New-CapsulenvCheckResult `
                -Name 'Bitwarden desktop' `
                -Passed ($null -ne $bitwarden) `
                -Importance Optional `
                -Detail $(if ($bitwarden) { $bitwarden } else { 'Not found' })))
        } catch {
            $results.Add((New-CapsulenvCheckResult `
                -Name 'Bitwarden desktop' `
                -Passed $false `
                -Importance Optional `
                -Detail $_.Exception.Message))
        }

        if ($bitwarden) {
            $bitwardenProcesses = @(Get-CapsulenvBitwardenProcesses -IncludeForeign)
            $foreignBitwardenProcesses = @($bitwardenProcesses | Where-Object { -not $_.CapsuleOwned })
            $results.Add((New-CapsulenvCheckResult `
                -Name 'Bitwarden process ownership' `
                -Passed ($foreignBitwardenProcesses.Count -eq 0) `
                -Importance Optional `
                -Detail $(if ($foreignBitwardenProcesses.Count -eq 0) {
                    "$(@($bitwardenProcesses | Where-Object { $_.CapsuleOwned }).Count) capsule-owned process(es); no foreign instance"
                } else {
                    "$($foreignBitwardenProcesses.Count) foreign Bitwarden process(es); Capsulenv start/setup will refuse while they are running"
                })))
            try {
                $bitwardenStatus = Get-CapsulenvBitwardenSshAgentStatus
                $results.Add((New-CapsulenvCheckResult `
                    -Name 'Bitwarden SSH Agent setting' `
                    -Passed ([bool]$bitwardenStatus.DesktopSettingEnabled) `
                    -Importance Optional `
                    -Detail ("Enabled={0}; Authorization={1}" -f $bitwardenStatus.DesktopSettingEnabled, $bitwardenStatus.Authorization)))
                $gitBoundaryPassed = if ($installMode -eq 'ShellOnly') {
                    -not [bool]$bitwardenStatus.GitGlobalManaged
                } else {
                    -not [bool]$bitwardenStatus.GitSessionOverlayActive
                }
                $results.Add((New-CapsulenvCheckResult `
                    -Name 'Bitwarden Git integration scope' `
                    -Passed $gitBoundaryPassed `
                    -Importance Optional `
                    -Detail ("Mode={0}; Scope={1}; SessionIntent={2}; SessionOverlayActive={3}; UserGlobalManaged={4}" -f $installMode, $bitwardenStatus.GitConfigScope, $bitwardenStatus.GitSessionIntent, $bitwardenStatus.GitSessionOverlayActive, $bitwardenStatus.GitGlobalManaged)))
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
            $serviceOverrideRecorded = Test-Path -LiteralPath (Get-CapsulenvSshAgentServiceStatePath) -PathType Leaf
            $servicePassed = if ($installMode -eq 'ShellOnly') {
                -not $serviceOverrideRecorded
            } elseif (-not $serviceOverrideRecorded) {
                $true
            } else {
                (-not $service) -or (
                    $service.Status -eq 'Stopped' -and $startMode -eq 'Disabled'
                )
            }
            if ($installMode -eq 'ShellOnly') {
                $serviceDetail = "ShellOnly must not own a host service override; recorded Capsulenv override=$serviceOverrideRecorded; $serviceDetail"
            } elseif (-not $serviceOverrideRecorded) {
                $serviceDetail = "User mode permits but does not require a service override; none recorded; $serviceDetail"
            }
            $results.Add((New-CapsulenvCheckResult `
                -Name 'Windows ssh-agent conflict' `
                -Passed $servicePassed `
                -Importance Optional `
                -Detail $serviceDetail))
        }
    }

    $browserConfiguration = Get-CapsulenvConfiguration
    foreach ($browserName in @($browserConfiguration.Browsers.Keys)) {
        $definition = $browserConfiguration.Browsers[$browserName]
        if ($definition -isnot [hashtable]) {
            continue
        }
        if ($definition.ContainsKey('Enabled') -and -not [bool]$definition.Enabled) {
            continue
        }
        $app = if ($definition.ContainsKey('App')) { [string]$definition.App } else { [string]$browserName }
        $displayName = if (
            $definition.ContainsKey('DisplayName') -and
            -not [string]::IsNullOrWhiteSpace([string]$definition.DisplayName)
        ) {
            [string]$definition.DisplayName
        } else {
            $app
        }

        try {
            $executable = Get-CapsulenvBrowserExecutable -App $app
            $results.Add((New-CapsulenvCheckResult `
                -Name "$displayName executable" `
                -Passed ($null -ne $executable) `
                -Importance Optional `
                -Detail $(if ($executable) { $executable } else { "Scoop app '$app' is not installed" })))
        } catch {
            $results.Add((New-CapsulenvCheckResult `
                -Name "$displayName executable" `
                -Passed $false `
                -Importance Optional `
                -Detail $_.Exception.Message))
        }

        try {
            $profile = Get-CapsulenvBrowserProfilePath -App $app
            $results.Add((New-CapsulenvCheckResult `
                -Name "$displayName capsule profile" `
                -Passed ($null -ne $profile) `
                -Importance Optional `
                -Detail $(if ($profile) { $profile } else { "No Scoop-persisted profile found for '$app'" })))
        } catch {
            $results.Add((New-CapsulenvCheckResult `
                -Name "$displayName capsule profile" `
                -Passed $false `
                -Importance Optional `
                -Detail $_.Exception.Message))
        }
    }

    try {
        $defaultBrowserCommand = Get-CapsulenvTrackedDefaultBrowserCommandStatus
        if ($null -ne $defaultBrowserCommand) {
            $handlerDetail = if ($defaultBrowserCommand.Matches) {
                "App=$($defaultBrowserCommand.App); ProgId=$($defaultBrowserCommand.ProgId); Command=$($defaultBrowserCommand.ActualCommand)"
            } else {
                "App=$($defaultBrowserCommand.App); ProgId=$($defaultBrowserCommand.ProgId); Registry=$($defaultBrowserCommand.RegistryPath); Actual=$($defaultBrowserCommand.ActualCommand); Expected=$($defaultBrowserCommand.ExpectedCommand)"
            }
            $results.Add((New-CapsulenvCheckResult `
                -Name 'Default-browser URL handler' `
                -Passed ([bool]$defaultBrowserCommand.Matches) `
                -Importance Optional `
                -Detail $handlerDetail))
        }
    } catch {
        $results.Add((New-CapsulenvCheckResult `
            -Name 'Default-browser URL handler' `
            -Passed $false `
            -Importance Optional `
            -Detail $_.Exception.Message))
    }

    try {
        $offline = Get-CapsulenvOfflineReadiness
        $results.Add((New-CapsulenvCheckResult `
            -Name 'Offline run readiness' `
            -Passed ([bool]$offline.RunReady) `
            -Importance Optional `
            -Detail ("InstalledApps={0}; MissingManifests={1}; CacheFiles={2}; CacheBytes={3}" -f $offline.InstalledApps, $offline.MissingInstalledManifests, $offline.CacheFiles, $offline.CacheBytes)))
    } catch {
        $results.Add((New-CapsulenvCheckResult -Name 'Offline run readiness' -Passed $false -Importance Optional -Detail $_.Exception.Message))
    }

    try {
        $drift = @(Get-CapsulenvVersionDrift)
        $drifted = @($drift | Where-Object { $_.Status -eq 'Drift' })
        $results.Add((New-CapsulenvCheckResult `
            -Name 'Scoop version drift' `
            -Passed ($drifted.Count -eq 0) `
            -Importance Optional `
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

    [void](Initialize-CapsulenvScoopBootstrap)
    Repair-CapsulenvPackageProjections
    $configuration = Get-CapsulenvConfiguration
    $didRehydrate = $false
    if (
        $configuration.Scoop.RehydrateOnRelocation -and
        (Test-CapsulenvScoopRehydrationRequired)
    ) {
        Write-CapsulenvMessage -Level Info -Message 'Capsule root or host changed; rehydrating installed package projections...'
        Invoke-CapsulenvScoopRehydrate -IntegrationMode $IntegrationMode
        $didRehydrate = $true
    }
    [void](Repair-CapsulenvProjectCacheLinks -Quiet)
    if ($IntegrationMode -eq 'User' -and -not $didRehydrate) {
        Sync-CapsulenvPackageStartMenuShortcuts
    }
    Initialize-CapsulenvBitwarden
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
    [void](Initialize-CapsulenvScoopBootstrap)
    Invoke-CapsulenvScoopRehydrate `
        -SkipHooks:$SkipHooks `
        -SkipPersistRepairs:$SkipPersistRepairs `
        -SkipToolRepairs:$SkipToolRepairs `
        -StrictToolRepairs:$StrictToolRepairs
    [void](Repair-CapsulenvProjectCacheLinks -Quiet)
    Initialize-CapsulenvBitwarden

    $context = Get-CapsulenvContext
    Write-CapsulenvMessage -Level Success -Message "capsulenv initialized at $($context.Root)"
}

##MOD_EXEC## Export-ModuleMember -Function Initialize-Capsulenv, Invoke-CapsulenvDoctor
