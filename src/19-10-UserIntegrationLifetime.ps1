# Policy and recovery live on the capsule, independently of disposable placement.
function Get-CapsulenvUserIntegrationPolicyPath {
    return Join-Path (Get-CapsulenvUserIntegrationStateRoot) 'policy.json'
}

function Get-CapsulenvUserIntegrationLeasePath {
    return Join-Path (Get-CapsulenvUserIntegrationStateRoot) 'lease.json'
}

function Assert-CapsulenvUserIntegrationIdentity {
    param([Parameter(Mandatory = $true)]$Record)
    $evidence = Get-CapsulenvHostIdentityEvidence
    if ([int]$Record.SchemaVersion -ne 1 -or
        [string]$Record.CapsuleId -ne [string](Get-CapsulenvIdentity) -or
        [string]$Record.HostIntegrationKey -ne [string](Get-CapsulenvHostIntegrationKey) -or
        [string]$Record.MachineUser -ne [string]$evidence.MachineUser.Value -or
        (-not [string]::IsNullOrWhiteSpace([string]$Record.WindowsGdid) -and
         [string]$Record.WindowsGdid -ne [string]$evidence.WindowsGdid.Value)) {
        throw 'UserIntegration authority does not match the validated capsule/host/user identity.'
    }
}

function Get-CapsulenvUserIntegrationLifetime {
    [CmdletBinding()]
    param()
    $path = Get-CapsulenvUserIntegrationPolicyPath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        Assert-CapsulenvUserIntegrationIdentity -Record $record
        if ([string]$record.Lifetime -notin @('isolated', 'leased', 'persistent')) {
            throw 'Invalid UserIntegration lifetime policy.'
        }
        return [string]$record.Lifetime
    }
    # Narrow migration: only inspect legacy ownership when ownership evidence
    # actually exists. A fresh isolated host must not need Scoop/config merely
    # to prove that no UserIntegration authority was granted.
    $context = Get-CapsulenvContext
    $currentRoot = Get-CapsulenvUserIntegrationStateRoot
    $currentState = Join-Path $currentRoot 'install-mode.json'
    $currentBackup = Join-Path $currentRoot 'environment-backup.json'
    $legacyState = Join-Path $context.StateRoot 'install-mode.json'
    $legacyBackup = Join-Path $context.StateRoot 'user-environment-backup.json'
    $hasCurrentEvidence = (Test-Path -LiteralPath $currentState -PathType Leaf) -or (Test-Path -LiteralPath $currentBackup -PathType Leaf)
    $hasLegacyEvidence = (Test-Path -LiteralPath $legacyState -PathType Leaf) -or (Test-Path -LiteralPath $legacyBackup -PathType Leaf)
    if (-not $hasCurrentEvidence -and -not $hasLegacyEvidence) {
        return 'isolated'
    }
    $state = Get-CapsulenvInstallModeState
    if ($null -ne $state -and [string]$state.Mode -eq 'User' -and
        (Test-Path -LiteralPath (Get-CapsulenvUserEnvironmentBackupPath) -PathType Leaf)) {
        return 'persistent'
    }
    return 'isolated'
}

function Get-CapsulenvPersistentUserIntegrationMarkerPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('environment', 'git-global', 'windows-ssh-agent-service')][string]$Surface)

    $capsule = ([string](Get-CapsulenvIdentity)) -replace '[^A-Za-z0-9._-]', '_'
    $root = Join-Path (Get-CapsulenvHostLocalStateRoot) 'user-integration-ownership'
    $root = Join-Path $root (Get-CapsulenvHostIntegrationKey)
    $root = Join-Path $root $capsule
    return Join-Path $root ($Surface + '.json')
}

function Write-CapsulenvPersistentUserIntegrationMarker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('environment', 'git-global', 'windows-ssh-agent-service')][string]$Surface,
        [AllowNull()][string]$Token,
        [AllowNull()]$Applied
    )

    $evidence = Get-CapsulenvHostIdentityEvidence
    $record = [pscustomobject][ordered]@{
        SchemaVersion = 1
        CapsuleId = Get-CapsulenvIdentity
        HostIntegrationKey = Get-CapsulenvHostIntegrationKey
        MachineUser = [string]$evidence.MachineUser.Value
        WindowsGdid = [string]$evidence.WindowsGdid.Value
        Surface = $Surface
        Token = [string]$Token
        Applied = $Applied
    }
    Write-CapsulenvHostJsonAtomically -Path (Get-CapsulenvPersistentUserIntegrationMarkerPath -Surface $Surface) -Value $record
    return $record
}

function Read-CapsulenvPersistentUserIntegrationMarker {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('environment', 'git-global', 'windows-ssh-agent-service')][string]$Surface)

    $path = Get-CapsulenvPersistentUserIntegrationMarkerPath -Surface $Surface
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-CapsulenvUserIntegrationIdentity -Record $record
    if ([string]$record.Surface -ne $Surface) {
        throw "Persistent UserIntegration marker surface mismatch: $path"
    }
    return $record
}

function Test-CapsulenvPersistentUserIntegrationMarker {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('environment', 'git-global', 'windows-ssh-agent-service')][string]$Surface)

    $path = Get-CapsulenvPersistentUserIntegrationMarkerPath -Surface $Surface
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    try {
        [void](Read-CapsulenvPersistentUserIntegrationMarker -Surface $Surface)
        return $true
    } catch {
        Write-CapsulenvMessage -Level Warning -Message "Persistent UserIntegration marker is invalid and remains fail-closed: $path. $($_.Exception.Message)"
        return $true
    }
}

function Remove-CapsulenvPersistentUserIntegrationMarker {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('environment', 'git-global', 'windows-ssh-agent-service')][string]$Surface)

    $path = Get-CapsulenvPersistentUserIntegrationMarkerPath -Surface $Surface
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Get-CapsulenvPersistentEnvironmentOwnership {
    [CmdletBinding()]
    param()

    $markerPath = Get-CapsulenvPersistentUserIntegrationMarkerPath -Surface environment
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $null }

    $marker = Read-CapsulenvPersistentUserIntegrationMarker -Surface environment
    $backupPath = Get-CapsulenvUserEnvironmentBackupPath
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        throw "Persistent environment ownership marker exists but its portable rollback backup is missing: $backupPath"
    }
    if ([string]::IsNullOrWhiteSpace([string]$marker.Token)) {
        throw "Persistent environment ownership marker is not bound to its portable rollback backup: $markerPath"
    }
    $actualHash = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$marker.Token, $actualHash)) {
        throw "Persistent environment rollback backup no longer matches the current-host ownership marker: $backupPath"
    }
    return [pscustomobject]@{
        Marker = $marker
        BackupPath = $backupPath
        BackupHash = $actualHash
    }
}

function Get-CapsulenvPersistentUserIntegrationSurfaces {
    [CmdletBinding()]
    param()

    $surfaces = New-Object System.Collections.Generic.List[string]
    $state = Get-CapsulenvInstallModeState
    $environmentBackup = Test-Path -LiteralPath (Get-CapsulenvUserEnvironmentBackupPath) -PathType Leaf
    $environmentMarkerPath = Get-CapsulenvPersistentUserIntegrationMarkerPath -Surface environment
    $environmentMarker = Test-Path -LiteralPath $environmentMarkerPath -PathType Leaf
    $environmentEvidence = $environmentMarker -or ($null -ne $state -and [string]$state.Mode -eq 'User') -or $environmentBackup
    if ($environmentEvidence) {
        $environmentOwned = $false
        if ($environmentMarker) {
            try {
                [void](Get-CapsulenvPersistentEnvironmentOwnership)
                $environmentOwned = $true
            } catch {
                Write-CapsulenvMessage -Level Warning -Message "Persistent environment ownership is incomplete or invalid and remains fail-closed: $($_.Exception.Message)"
                $environmentOwned = $true
            }
        } elseif (Test-CapsulenvWindows) {
            try { $environmentOwned = Test-CapsulenvCurrentUserIntegrationOwnership } catch { $environmentOwned = $false }
        } else {
            $environmentOwned = ($null -ne $state -and [string]$state.Mode -eq 'User' -and $environmentBackup)
        }
        if ($environmentOwned) {
            if ($environmentMarker) { $surfaces.Add('environment-marker') }
            if ($null -ne $state -and [string]$state.Mode -eq 'User') { $surfaces.Add('environment-ledger') }
            if ($environmentBackup) { $surfaces.Add('environment-backup') }
        }
    }

    $browserState = Get-CapsulenvDefaultBrowserState
    if ($null -ne $browserState) {
        $browserOwned = if (Test-CapsulenvWindows) {
            -not (Test-CapsulenvDefaultBrowserAlreadyRestored -State $browserState)
        } else {
            $true
        }
        if ($browserOwned) {
            $surfaces.Add('default-browser')
        }
    }

    if (Test-Path -LiteralPath (Get-CapsulenvBitwardenDesktopSettingsBackupPath) -PathType Leaf) {
        $surfaces.Add('bitwarden-desktop')
    }
    if (Test-Path -LiteralPath (Get-CapsulenvGitConfigBackupPath) -PathType Leaf) {
        $surfaces.Add('git-global')
    }
    if (Test-CapsulenvBitwardenHostBackupOwnership -Path (Get-CapsulenvSshAgentServiceStatePath) -Kind Service) {
        $surfaces.Add('windows-ssh-agent-service')
    }
    Write-CapsulenvLegacyBitwardenBackupDiagnostic -Name 'ssh-agent-service.json'
    $bridgeRoot = Get-CapsulenvUserIntegrationBridgeRoot -CapsuleId (Get-CapsulenvIdentity)
    if (-not [string]::IsNullOrWhiteSpace([string]$bridgeRoot) -and (Test-Path -LiteralPath $bridgeRoot -PathType Container)) {
        $surfaces.Add('user-integration-bridge')
    }
    if (Test-CapsulenvWindows) {
        foreach ($entry in @(
            [pscustomobject]@{ Name = 'start-menu-user'; Global = $false },
            [pscustomobject]@{ Name = 'start-menu-global'; Global = $true }
        )) {
            $root = Get-CapsulenvUserStartMenuShortcutRoot -Global:$entry.Global
            if (-not [string]::IsNullOrWhiteSpace([string]$root) -and (Test-Path -LiteralPath $root -PathType Container)) {
                $surfaces.Add([string]$entry.Name)
            }
        }
    }
    return @($surfaces.ToArray())
}

function Set-CapsulenvUserIntegrationLifetime {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('isolated', 'leased', 'persistent')][string]$Lifetime)
    Invoke-CapsulenvUserIntegrationLeaseMutation -Action {
        if (Test-Path -LiteralPath (Get-CapsulenvUserIntegrationLeasePath)) {
            throw 'Release the existing UserIntegration lease before changing lifetime.'
        }
        if ($Lifetime -ne 'persistent') {
            $persistentSurfaces = @(Get-CapsulenvPersistentUserIntegrationSurfaces)
            if ($persistentSurfaces.Count -gt 0) {
                throw "Restore persistent UserIntegration before changing lifetime. Owned surfaces: $($persistentSurfaces -join ', ')."
            }
        }
        $evidence = Get-CapsulenvHostIdentityEvidence
        Write-CapsulenvHostJsonAtomically -Path (Get-CapsulenvUserIntegrationPolicyPath) -Value ([ordered]@{
            SchemaVersion = 1; CapsuleId = Get-CapsulenvIdentity
            HostIntegrationKey = Get-CapsulenvHostIntegrationKey
            MachineUser = [string]$evidence.MachineUser.Value
            WindowsGdid = [string]$evidence.WindowsGdid.Value
            Lifetime = $Lifetime
        })
    }
}

function Get-CapsulenvUserIntegrationLease {
    $path = Get-CapsulenvUserIntegrationLeasePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $lease = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-CapsulenvUserIntegrationIdentity -Record $lease
    if ([string]::IsNullOrWhiteSpace([string]$lease.LeaseId) -or
        [string]::IsNullOrWhiteSpace([string]$lease.SessionId) -or
        [string]::IsNullOrWhiteSpace([string]$lease.BootEpoch) -or
        [string]::IsNullOrWhiteSpace([string]$lease.ProcessStartIdentity) -or
        [int]$lease.ProcessId -le 0 -or
        $null -eq $lease.PSObject.Properties['Environment'] -or
        [string]$lease.Phase -notin @('Prepared', 'Active', 'Releasing', 'Blocked')) {
        throw 'Invalid or incomplete UserIntegration lease.'
    }
    return $lease
}

function Test-CapsulenvUserIntegrationLeaseProcess {
    param([Parameter(Mandatory = $true)]$Lease)
    try {
        return [string]$Lease.ProcessStartIdentity -eq [string](Get-CapsulenvProcessStartIdentity -ProcessId ([int]$Lease.ProcessId))
    } catch { return $false }
}

function Test-CapsulenvUserIntegrationLeaseOwner {
    param([Parameter(Mandatory = $true)]$Lease)
    return [string]$Lease.BootEpoch -eq [string](Get-CapsulenvHostBootEpoch) -and
        (Test-CapsulenvUserIntegrationLeaseProcess -Lease $Lease)
}

function Assert-CapsulenvUserIntegrationAuthority {
    [CmdletBinding()]
    param([switch]$PersistentOnly, [switch]$LeaseApplyOnly)
    $lifetime = Get-CapsulenvUserIntegrationLifetime
    if ($lifetime -eq 'persistent') {
        if (Test-Path -LiteralPath (Get-CapsulenvUserIntegrationLeasePath)) { throw 'A UserIntegration lease must be released before persistent mutation.' }
        return
    }
    if (-not $PersistentOnly -and $lifetime -eq 'leased') {
        $lease = Get-CapsulenvUserIntegrationLease
        if ($null -ne $lease -and [string]$lease.Phase -in @('Prepared', 'Active') -and
            (-not $LeaseApplyOnly -or [string]$lease.Phase -eq 'Prepared') -and
            [string]$lease.LeaseId -eq [string]$env:CAPSULENV_USER_LEASE_ID -and
            (Test-CapsulenvUserIntegrationLeaseOwner -Lease $lease)) { return }
        throw 'UserIntegration lease is stale, incomplete, or belongs to another session; release-user is required.'
    }
    throw 'Explicit UserIntegration authority is required; placement retention and invocation mode do not authorize this mutation.'
}

function Invoke-CapsulenvUserIntegrationLeaseMutation {
    param([Parameter(Mandatory = $true)][scriptblock]$Action)
    $root = Get-CapsulenvUserIntegrationStateRoot
    [void](New-Item -ItemType Directory -Path $root -Force)
    $lock = [System.IO.File]::Open((Join-Path $root 'lease.lock'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try { & $Action } finally { $lock.Dispose() }
}

function Get-CapsulenvUserEnvironmentValue {
    param([Parameter(Mandatory = $true)][string]$Name)
    return [Environment]::GetEnvironmentVariable($Name, 'User')
}

function Set-CapsulenvUserEnvironmentValue {
    param([Parameter(Mandatory = $true)][string]$Name, [AllowNull()][string]$Value)
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
}

function Start-CapsulenvUserIntegrationLease {
    [CmdletBinding()]
    param()
    if ((Get-CapsulenvUserIntegrationLifetime) -ne 'leased') {
        throw 'Select UserIntegration lifetime leased explicitly before acquiring a lease.'
    }
    Invoke-CapsulenvUserIntegrationLeaseMutation -Action {
        if ((Get-CapsulenvUserIntegrationLifetime) -ne 'leased') { throw 'UserIntegration lifetime changed before acquisition.' }
        if (Test-Path -LiteralPath (Get-CapsulenvUserIntegrationLeasePath)) {
            throw 'An active, stale, or incomplete UserIntegration lease exists; run release-user first.'
        }
        $persistentSurfaces = @(Get-CapsulenvPersistentUserIntegrationSurfaces)
        if ($persistentSurfaces.Count -gt 0) {
            throw "Existing persistent UserIntegration ownership must be restored before acquiring a lease. Owned surfaces: $($persistentSurfaces -join ', ')."
        }
        $plan = Get-CapsulenvEnvironmentPlan
        $entries = New-Object System.Collections.Generic.List[object]
        foreach ($name in $plan.Variables.Keys) {
            $entries.Add([pscustomobject]@{ Name = $name; Before = Get-CapsulenvUserEnvironmentValue -Name $name; Applied = [string]$plan.Variables[$name] })
        }
        $beforePath = Get-CapsulenvUserEnvironmentValue -Name PATH
        $addedPaths = @($plan.PathEntries | Where-Object { -not (Test-CapsulenvPathEntryPresent -Path $beforePath -Entry $_) })
        $appliedPath = if ($addedPaths.Count -gt 0) { Merge-CapsulenvPath -ExistingPath $beforePath -Prepend $addedPaths } else { $beforePath }
        $entries.Add([pscustomobject]@{ Name = 'PATH'; Before = $beforePath; Applied = $appliedPath })
        $evidence = Get-CapsulenvHostIdentityEvidence
        $lease = [pscustomobject][ordered]@{
            SchemaVersion = 1; CapsuleId = Get-CapsulenvIdentity
            HostIntegrationKey = Get-CapsulenvHostIntegrationKey
            MachineUser = [string]$evidence.MachineUser.Value; WindowsGdid = [string]$evidence.WindowsGdid.Value
            LeaseId = [Guid]::NewGuid().ToString('N'); SessionId = [Guid]::NewGuid().ToString('N')
            ProcessId = $PID; ProcessStartIdentity = Get-CapsulenvProcessStartIdentity -ProcessId $PID
            BootEpoch = Get-CapsulenvHostBootEpoch; Phase = 'Prepared'; Diagnostic = ''
            Environment = $entries.ToArray(); AddedPaths = $addedPaths; BrowserSnapshot = $null; BridgeSnapshot = @()
        }
        Write-CapsulenvHostJsonAtomically -Path (Get-CapsulenvUserIntegrationLeasePath) -Value $lease
        $env:CAPSULENV_USER_LEASE_ID = [string]$lease.LeaseId
        foreach ($entry in $lease.Environment) { Set-CapsulenvUserEnvironmentValue -Name $entry.Name -Value $entry.Applied }
        $app = Get-CapsulenvConfiguredDefaultBrowser
        if (-not [string]::IsNullOrWhiteSpace($app)) {
            [void](Install-CapsulenvUserIntegration -CapsuleId (Get-CapsulenvIdentity) -BrowserApp $app)
            $bridgeRoot = Get-CapsulenvUserIntegrationBridgeRoot -CapsuleId (Get-CapsulenvIdentity)
            $lease.BridgeSnapshot = @(Get-ChildItem -LiteralPath $bridgeRoot -File -Force | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } })
            Write-CapsulenvHostJsonAtomically -Path (Get-CapsulenvUserIntegrationLeasePath) -Value $lease
            [void](Install-CapsulenvDefaultBrowserRegistration -App $app)
            $lease.BrowserSnapshot = Get-CapsulenvOwnedBrowserRegistrationSnapshot
        }
        $lease.Phase = 'Active'
        Write-CapsulenvHostJsonAtomically -Path (Get-CapsulenvUserIntegrationLeasePath) -Value $lease
        return $lease
    }
}

function Test-CapsulenvPathEntryPresent {
    param([AllowNull()][string]$Path, [Parameter(Mandatory = $true)][string]$Entry)
    return @($Path -split ';' | Where-Object { [StringComparer]::OrdinalIgnoreCase.Equals($_.TrimEnd([char[]]'\\/'), $Entry.TrimEnd([char[]]'\\/')) }).Count -gt 0
}

function Stop-CapsulenvUserIntegrationLease {
    [CmdletBinding()]
    param()
    Invoke-CapsulenvUserIntegrationLeaseMutation -Action {
        $lease = Get-CapsulenvUserIntegrationLease
        if ($null -eq $lease) { return }
        if ((Test-CapsulenvUserIntegrationLeaseProcess -Lease $lease) -and [string]$lease.LeaseId -ne [string]$env:CAPSULENV_USER_LEASE_ID) {
            throw 'UserIntegration lease is owned by another live session.'
        }
        try {
            # Preflight all non-environment ownership before removing handlers.
            $browserState = Get-CapsulenvDefaultBrowserState
            $bridgeRoot = Get-CapsulenvUserIntegrationBridgeRoot -CapsuleId (Get-CapsulenvIdentity)
            $browserRegistrationAlreadyRestored = $false
            if ($null -ne $browserState) {
                Assert-CapsulenvDefaultBrowserRestorable
                $browserRegistrationAlreadyRestored = Test-CapsulenvOwnedBrowserRegistrationAbsent -State $browserState
                if (-not $browserRegistrationAlreadyRestored) {
                    $actual = Get-CapsulenvOwnedBrowserRegistrationSnapshot
                    if ($null -eq $lease.BrowserSnapshot -or
                        (ConvertTo-Json -InputObject $actual -Depth 12 -Compress) -cne (ConvertTo-Json -InputObject $lease.BrowserSnapshot -Depth 12 -Compress)) {
                        throw 'Browser registration changed or lease application was incomplete; preserve it and repair ownership before release-user.'
                    }
                }
            } elseif ($null -ne $lease.BrowserSnapshot) {
                throw 'Tracked leased browser state is missing; release is blocked until ownership can be verified.'
            }
            if (Test-Path -LiteralPath $bridgeRoot) {
                $bridgeItem = Get-Item -LiteralPath $bridgeRoot -Force
                if (($bridgeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Bridge root was replaced with a reparse point; release is blocked.' }
                if (@(Get-ChildItem -LiteralPath $bridgeRoot -Directory -Force).Count -gt 0) { throw 'Unowned bridge directories exist; release is blocked.' }
                $files = @(Get-ChildItem -LiteralPath $bridgeRoot -File -Force)
                if ($files.Count -ne @($lease.BridgeSnapshot).Count) { throw 'Bridge ownership is incomplete or changed; release is blocked.' }
                foreach ($file in $files) {
                    $owned = @($lease.BridgeSnapshot | Where-Object { $_.Name -eq $file.Name })
                    if ($owned.Count -ne 1 -or [string]$owned[0].Hash -ne [string](Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) {
                        throw 'Bridge changed concurrently; release is blocked.'
                    }
                }
            }
            $lease.Phase = 'Releasing'
            Write-CapsulenvHostJsonAtomically -Path (Get-CapsulenvUserIntegrationLeasePath) -Value $lease
            if (-not $browserRegistrationAlreadyRestored -and $null -ne $browserState) {
                Restore-CapsulenvDefaultBrowserRegistration -KeepState
            }
            if (Test-Path -LiteralPath $bridgeRoot) { Remove-Item -LiteralPath $bridgeRoot -Recurse -Force }
            foreach ($entry in @($lease.Environment)) {
                $current = Get-CapsulenvUserEnvironmentValue -Name $entry.Name
                if ([StringComparer]::Ordinal.Equals([string]$current, [string]$entry.Applied)) {
                    Set-CapsulenvUserEnvironmentValue -Name $entry.Name -Value $entry.Before
                } elseif ($entry.Name -eq 'PATH') {
                    $ownedPaths = @($lease.AddedPaths) -join ';'
                    $kept = @($current -split ';' | Where-Object {
                        [string]::IsNullOrWhiteSpace($_) -or -not (Test-CapsulenvPathEntryPresent -Path $ownedPaths -Entry $_)
                    })
                    Set-CapsulenvUserEnvironmentValue -Name PATH -Value ($kept -join ';')
                }
            }
            if ($null -ne $browserState) {
                $browserStatePath = Get-CapsulenvDefaultBrowserStatePath
                if (Test-Path -LiteralPath $browserStatePath -PathType Leaf) {
                    Remove-Item -LiteralPath $browserStatePath -Force
                }
            }
            Remove-Item -LiteralPath (Get-CapsulenvUserIntegrationLeasePath) -Force
            $env:CAPSULENV_USER_LEASE_ID = $null
        } catch {
            $lease.Phase = 'Blocked'; $lease.Diagnostic = $_.Exception.Message
            Write-CapsulenvHostJsonAtomically -Path (Get-CapsulenvUserIntegrationLeasePath) -Value $lease
            throw
        }
    }
}

function Get-CapsulenvUserIntegrationStatus {
    [CmdletBinding()]
    param()
    $requested = 'invalid'; $owned = 'none'; $leaseStatus = 'none'; $diagnostic = ''; $persistentSurfaces = @()
    try {
        $requested = Get-CapsulenvUserIntegrationLifetime
        $lease = Get-CapsulenvUserIntegrationLease
        if ($null -ne $lease) {
            $owned = 'leased'
            $leaseStatus = if ($lease.Phase -ne 'Active') { [string]$lease.Phase } elseif (Test-CapsulenvUserIntegrationLeaseOwner -Lease $lease) { 'Active' } else { 'Stale' }
            $diagnostic = [string]$lease.Diagnostic
        } else {
            $persistentSurfaces = @(Get-CapsulenvPersistentUserIntegrationSurfaces)
            if ($persistentSurfaces.Count -gt 0) {
                $owned = 'persistent'
                if ($requested -ne 'persistent') {
                    $diagnostic = "Persistent UserIntegration surfaces remain while requested lifetime is ${requested}: $($persistentSurfaces -join ', ')."
                }
            }
        }
    } catch { $leaseStatus = 'Invalid'; $diagnostic = $_.Exception.Message }
    $confirmation = $false
    try {
        $browser = Get-CapsulenvDefaultBrowserState
        $confirmation = $null -ne $browser -and (Test-CapsulenvWindows) -and
            -not (Test-CapsulenvDefaultBrowserProgIdsSelected -UrlProgId ([string]$browser.UrlProgId) -HtmlProgId ([string]$browser.HtmlProgId))
    } catch { $diagnostic = $_.Exception.Message; $leaseStatus = 'Invalid' }
    return [pscustomobject]@{ PlacementRetention = [string](Get-CapsulenvHostRecord).Retention; UserIntegration = $requested; OwnedUserIntegration = $owned; PersistentOwnedSurfaces = @($persistentSurfaces); IntegrationLease = $leaseStatus; IntegrationDiagnostic = $diagnostic; DefaultBrowserUserConfirmationRequired = $confirmation }
}

function Enter-CapsulenvLeasedUserShell {
    [CmdletBinding()]
    param()
    [void](Start-CapsulenvUserIntegrationLease)
    try { Invoke-CapsulenvChildShell -IntegrationMode ShellOnly } finally { Stop-CapsulenvUserIntegrationLease }
}

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvUserIntegrationLifetime, Set-CapsulenvUserIntegrationLifetime, Start-CapsulenvUserIntegrationLease, Stop-CapsulenvUserIntegrationLease, Get-CapsulenvUserIntegrationStatus, Enter-CapsulenvLeasedUserShell
