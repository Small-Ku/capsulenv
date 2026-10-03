function Enter-CapsulenvUserShell {
    [CmdletBinding()]
    param([switch]$Force)

    # A reset/shared host may have a stale host-scoped backup on the USB while
    # its actual User environment has already been restored by the machine.
    # user-shell is the convenience-first entrypoint: if this host is not
    # currently integrated, refresh that host's reversible backup before takeover.
    $refreshBackup = ((Get-CapsulenvUserIntegrationMode) -ne 'User')
    Install-CapsulenvUserEnvironment -Force:$Force -RefreshBackup:$refreshBackup
    # Install-CapsulenvUserEnvironment already synchronized persistent User
    # integrations, including the configured default browser. Do not immediately
    # repeat the prompt while entering the child shell.
    Invoke-CapsulenvChildShell -IntegrationMode User -SkipUserIntegrationSync
}

function Enable-CapsulenvUserEnvironment {
    [CmdletBinding()]
    param([switch]$Force)

    Install-CapsulenvUserEnvironment -Force:$Force
}

function Restore-CapsulenvUserEnvironment {
    [CmdletBinding()]
    param()

    if (Test-Path -LiteralPath (Get-CapsulenvUserIntegrationLeasePath)) {
        Stop-CapsulenvUserIntegrationLease
        return
    }

    $backupPath = Get-CapsulenvUserEnvironmentBackupPath
    $backupExists = Test-Path -LiteralPath $backupPath -PathType Leaf
    $environmentMarkerPath = Get-CapsulenvPersistentUserIntegrationMarkerPath -Surface environment
    $environmentMarkerExists = Test-Path -LiteralPath $environmentMarkerPath -PathType Leaf
    $ledgerState = Get-CapsulenvInstallModeState
    $environmentCurrentlyOwned = if (Test-CapsulenvWindows) {
        try { Test-CapsulenvCurrentUserIntegrationOwnership } catch { $false }
    } else {
        ($null -ne $ledgerState -and [string]$ledgerState.Mode -eq 'User' -and $backupExists)
    }

    $environmentOwnership = $null
    $restoreEnvironment = $false
    if ($environmentMarkerExists) {
        $environmentOwnership = Get-CapsulenvPersistentEnvironmentOwnership
        $restoreEnvironment = $true
    } elseif ($environmentCurrentlyOwned) {
        if (-not $backupExists) {
            throw "The current User environment still belongs to Capsulenv, but its portable rollback backup is missing: $backupPath"
        }
        $restoreEnvironment = $true
    }

    # Preflight the environment restore before changing any other persistent
    # surface. With a current-host marker, only Capsulenv-applied scalar values
    # or the original values are accepted. PATH is ownership-merged by removing
    # only entries Capsulenv added.
    $environmentActions = New-Object System.Collections.Generic.List[object]
    if ($restoreEnvironment) {
        $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
        $marker = if ($null -ne $environmentOwnership) { $environmentOwnership.Marker } else { $null }
        foreach ($property in $backup.PSObject.Properties) {
            $entry = $property.Value
            $beforeValue = if ([bool]$entry.Exists) { [string]$entry.Value } else { $null }
            if ($null -eq $marker) {
                $environmentActions.Add([pscustomobject]@{ Name = $property.Name; Value = $beforeValue })
                continue
            }

            if ($property.Name -eq 'PATH') {
                $currentPath = Get-CapsulenvUserEnvironmentValue -Name PATH
                $ownedPaths = @($marker.Applied.PathEntries)
                $restoredPath = if ($ownedPaths.Count -gt 0) {
                    Remove-CapsulenvPathEntries -ExistingPath $currentPath -Remove $ownedPaths
                } else {
                    $currentPath
                }
                $environmentActions.Add([pscustomobject]@{ Name = 'PATH'; Value = $restoredPath })
                continue
            }

            $appliedProperty = $marker.Applied.Variables.PSObject.Properties[$property.Name]
            if ($null -eq $appliedProperty) {
                continue
            }
            $currentValue = Get-CapsulenvUserEnvironmentValue -Name $property.Name
            $appliedValue = [string]$appliedProperty.Value
            $matchesApplied = [System.StringComparer]::Ordinal.Equals([string]$currentValue, $appliedValue)
            $matchesBefore = if ([bool]$entry.Exists) {
                [System.StringComparer]::Ordinal.Equals([string]$currentValue, [string]$entry.Value)
            } else {
                $null -eq $currentValue
            }
            if (-not $matchesApplied -and -not $matchesBefore) {
                throw "User environment variable $($property.Name) changed after Capsulenv applied persistent integration; refusing to overwrite concurrent User changes."
            }
            if ($matchesApplied) {
                $environmentActions.Add([pscustomobject]@{ Name = $property.Name; Value = $beforeValue })
            }
        }
    }

    $sshAgentStatePath = Get-CapsulenvSshAgentServiceStatePath
    $serviceOwned = Test-CapsulenvBitwardenHostBackupOwnership -Path $sshAgentStatePath -Kind Service
    if ($serviceOwned -and -not (Test-CapsulenvAdministrator)) {
        throw 'User-mode Bitwarden setup changed the Windows ssh-agent service. Run restore-user from an elevated terminal so Capsulenv can restore that machine-level state before returning to ShellOnly.'
    }

    $browserState = Get-CapsulenvDefaultBrowserState
    $browserAlreadyRestored = $null -ne $browserState -and (Test-CapsulenvDefaultBrowserAlreadyRestored -State $browserState)
    if ($null -ne $browserState -and -not $browserAlreadyRestored) {
        Assert-CapsulenvDefaultBrowserRestorable
    }

    $desktopBackup = Get-CapsulenvBitwardenDesktopSettingsBackupPath
    if (Test-Path -LiteralPath $desktopBackup -PathType Leaf) {
        Restore-CapsulenvBitwardenDesktopSettings -NoStart
    }
    if ($serviceOwned) {
        Restore-CapsulenvWindowsSshAgent -Confirm:$false
    }

    $gitBackup = Get-CapsulenvGitConfigBackupPath
    if (Test-Path -LiteralPath $gitBackup -PathType Leaf) {
        [void](Restore-CapsulenvGitOpenSshGlobal)
    }

    if ($null -ne $browserState) {
        Restore-CapsulenvDefaultBrowserRegistration
    }
    Remove-CapsulenvUserStartMenuShortcuts
    [void](Remove-CapsulenvUserIntegrationBridge -CapsuleId (Get-CapsulenvIdentity) -Confirm:$false)

    if ($restoreEnvironment) {
        foreach ($action in $environmentActions) {
            Set-CapsulenvUserEnvironmentValue -Name ([string]$action.Name) -Value $action.Value
        }
        if ($environmentMarkerExists) {
            Remove-CapsulenvPersistentUserIntegrationMarker -Surface environment
            $environmentMarkerExists = $false
        }
        Remove-Item -LiteralPath $backupPath -Force
    } elseif ($backupExists) {
        $recoveryRoot = Join-Path (Get-CapsulenvUserIntegrationStateRoot) 'recovery'
        [void](New-Item -ItemType Directory -Path $recoveryRoot -Force)
        $destination = Join-Path $recoveryRoot ('environment-backup.stale.{0}.{1}.json' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [Guid]::NewGuid().ToString('N'))
        Move-Item -LiteralPath $backupPath -Destination $destination
        Write-CapsulenvMessage -Level Warning -Message "The User environment was already absent on this host incarnation. Its stale portable backup was preserved without replaying it: $destination"
    }
    if ($environmentMarkerExists) {
        Remove-CapsulenvPersistentUserIntegrationMarker -Surface environment
    }

    Set-CapsulenvInstallMode -Mode ShellOnly
    Set-CapsulenvUserIntegrationLifetime -Lifetime isolated
    [Environment]::SetEnvironmentVariable('CAPSULENV_MODE', 'ShellOnly', 'Process')
    try {
        Initialize-CapsulenvGitOpenSshSession
    } catch {
        Write-CapsulenvMessage -Level Warning -Message "ShellOnly mode was restored, but the recorded Bitwarden Git/OpenSSH session intent could not be activated: $($_.Exception.Message)"
    }
    Write-CapsulenvMessage -Level Success -Message 'Capsulenv-owned User environment and reversible Bitwarden integrations restored; capsulenv is shell-only again.'
}

##MOD_EXEC## Export-ModuleMember -Function Enter-CapsulenvUserShell, Enable-CapsulenvUserEnvironment, Restore-CapsulenvUserEnvironment
