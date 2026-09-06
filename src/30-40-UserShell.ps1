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

    $backupPath = Get-CapsulenvUserEnvironmentBackupPath
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        throw "No user-environment backup exists: $backupPath"
    }

    $sshAgentStatePath = Get-CapsulenvSshAgentServiceStatePath
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

##MOD_EXEC## Export-ModuleMember -Function Enter-CapsulenvUserShell, Enable-CapsulenvUserEnvironment, Restore-CapsulenvUserEnvironment
