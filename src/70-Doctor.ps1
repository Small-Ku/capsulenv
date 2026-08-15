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

function Write-CapsulenvDoctorReport {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Results)

    $summary = @($Results | Select-Object `
        Name, `
        @{ Name = 'Status'; Expression = { if ($_.Passed) { 'PASS' } elseif ($_.Importance -eq 'Required') { 'FAIL' } else { 'WARN' } } }, `
        Importance)
    $summary | Format-Table -AutoSize | Out-Host

    $attention = @($Results | Where-Object { -not $_.Passed })
    if ($attention.Count -eq 0) {
        return
    }

    Write-Host ''
    Write-Host 'Details for checks requiring attention:'
    foreach ($result in $attention) {
        $status = if ($result.Importance -eq 'Required') { 'FAIL' } else { 'WARN' }
        Write-Host ('[{0}] {1}' -f $status, $result.Name)
        Write-Host ('  {0}' -f $result.Detail)
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
        -Detail $(if ($scoopExecutable) { $scoopExecutable } else { 'Not found; bootstrap will install it on first session' })))

    $portableScoopConfig = Join-Path $scoopRoot 'config.json'
    $results.Add((New-CapsulenvCheckResult `
        -Name 'Portable Scoop config' `
        -Passed (Test-Path -LiteralPath $portableScoopConfig -PathType Leaf) `
        -Importance Optional `
        -Detail $portableScoopConfig))

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

    try {
        $managedProjectLinks = @(Get-CapsulenvManagedProjectCacheLinks)
        $managedProjectLinksPassed = $true
        $managedProjectLinksDetail = "{0} registered link(s)" -f $managedProjectLinks.Count
    } catch {
        $managedProjectLinksPassed = $false
        $managedProjectLinksDetail = $_.Exception.Message
    }
    $results.Add((New-CapsulenvCheckResult `
        -Name 'Managed project cache registry' `
        -Passed $managedProjectLinksPassed `
        -Importance Optional `
        -Detail $managedProjectLinksDetail))

    try {
        $toolWorkspaces = @(Get-CapsulenvToolWorkspaces)
        $invalidToolWorkspaces = @($toolWorkspaces | Where-Object { $_.Status -ne 'Ready' })
        $toolWorkspacesPassed = ($invalidToolWorkspaces.Count -eq 0)
        $toolWorkspacesDetail = "{0} registered workspace(s); {1} unavailable" -f $toolWorkspaces.Count, $invalidToolWorkspaces.Count
    } catch {
        $toolWorkspacesPassed = $false
        $toolWorkspacesDetail = $_.Exception.Message
    }
    $results.Add((New-CapsulenvCheckResult `
        -Name 'Tool workspace registry' `
        -Passed $toolWorkspacesPassed `
        -Importance Optional `
        -Detail $toolWorkspacesDetail))

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

    $relocationContext = Get-CapsulenvRelocationContext
    $configuredRepairFiles = [int](
        @($configuration.Scoop.RelocationRepairs.Keys | ForEach-Object {
            @($configuration.Scoop.RelocationRepairs[$_]).Count
        } | Measure-Object -Sum).Sum
    )
    $repairDetail = if ($relocationContext.HasPathChanges) {
        $moves = @($relocationContext.PathMappings | ForEach-Object {
            '{0}: {1} -> {2}' -f $_.Name, $_.OldPath, $_.NewPath
        })
        "Pending (source=$($relocationContext.PreviousSource)); $configuredRepairFiles allow-listed file rule(s); $($moves -join '; ')"
    } else {
        "$configuredRepairFiles allow-listed file rule(s); no pending path relocation"
    }
    $results.Add((New-CapsulenvCheckResult `
        -Name 'Persist path repair' `
        -Passed (-not $relocationContext.HasPathChanges) `
        -Importance Optional `
        -Detail $repairDetail))

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

    if ($configuration.SingBox.Enabled) {
        try {
            $singBoxStatus = Get-CapsulenvSingBoxStatus
            $availabilityDetail = if ($singBoxStatus.Installed) {
                [string]$singBoxStatus.Executable
            } elseif (-not [string]::IsNullOrWhiteSpace([string]$singBoxStatus.AvailabilityError)) {
                [string]$singBoxStatus.AvailabilityError
            } else {
                "Scoop app '$($singBoxStatus.App)' is not installed"
            }
            $results.Add((New-CapsulenvCheckResult `
                -Name 'sing-box selected app' `
                -Passed ([bool]$singBoxStatus.Installed) `
                -Importance Optional `
                -Detail $availabilityDetail))
            if ($singBoxStatus.Installed) {
                $results.Add((New-CapsulenvCheckResult `
                    -Name 'sing-box persisted configuration' `
                    -Passed ([bool]$singBoxStatus.Configured) `
                    -Importance Optional `
                    -Detail $(if ($singBoxStatus.Configured) { [string]$singBoxStatus.Configuration } else { 'No non-empty selected Scoop-persisted configuration' })))
                $results.Add((New-CapsulenvCheckResult `
                    -Name 'sing-box process ownership' `
                    -Passed ([int]$singBoxStatus.ForeignProcesses -eq 0) `
                    -Importance Optional `
                    -Detail ("Running={0}; capsule-owned PIDs={1}; foreign same-name processes={2}" -f $singBoxStatus.Running, (@($singBoxStatus.CapsuleOwnedPids) -join ','), $singBoxStatus.ForeignProcesses)))
            }
        } catch {
            $results.Add((New-CapsulenvCheckResult `
                -Name 'sing-box selected app' `
                -Passed $false `
                -Importance Optional `
                -Detail $_.Exception.Message))
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

    Write-CapsulenvDoctorReport -Results $results.ToArray()
    $requiredFailures = @($results | Where-Object { -not $_.Passed -and $_.Importance -eq 'Required' })
    if ($requiredFailures.Count -gt 0) {
        throw "capsulenv doctor found $($requiredFailures.Count) required failure(s)."
    }
    return $results.ToArray()
}

function Initialize-CapsulenvIntegrations {
    [CmdletBinding()]
    param()

    [void](Initialize-CapsulenvScoopBootstrap)
    $configuration = Get-CapsulenvConfiguration
    if (
        $configuration.Scoop.RehydrateOnRelocation -and
        (Test-CapsulenvScoopRehydrationRequired)
    ) {
        Write-CapsulenvMessage -Level Info -Message 'Portable Scoop root or host changed; rehydrating installed apps...'
        Invoke-CapsulenvScoopRehydrate
    }
    [void](Repair-CapsulenvProjectCacheLinks -Quiet)
    Initialize-CapsulenvBitwarden
    Initialize-CapsulenvSingBox
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
    Initialize-CapsulenvSingBox

    $context = Get-CapsulenvContext
    Write-CapsulenvMessage -Level Success -Message "capsulenv initialized at $($context.Root)"
}

##MOD_EXEC## Export-ModuleMember -Function Initialize-Capsulenv, Invoke-CapsulenvDoctor
