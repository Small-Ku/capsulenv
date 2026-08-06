function Get-CapsulenvBitwardenExecutable {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    return Find-CapsulenvExecutable `
        -Candidates @($configuration.Bitwarden.ExecutableCandidates) `
        -CommandNames @('Bitwarden.exe', 'bitwarden.exe')
}

function Initialize-CapsulenvBitwarden {
    [CmdletBinding()]
    param([switch]$Start)

    $configuration = Get-CapsulenvConfiguration
    if (-not $configuration.Bitwarden.Enabled) {
        return
    }

    $appData = New-CapsulenvDirectory -Path $configuration.Bitwarden.AppDataDir
    [Environment]::SetEnvironmentVariable('BITWARDEN_APPDATA_DIR', $appData, 'Process')
    if ($configuration.Bitwarden.SetSshAuthSock) {
        [Environment]::SetEnvironmentVariable('SSH_AUTH_SOCK', '\\.\pipe\openssh-ssh-agent', 'Process')
    }

    if ($Start -or $configuration.Bitwarden.StartOnEnter) {
        Start-CapsulenvBitwarden
    }
}

function Start-CapsulenvBitwarden {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    if (-not $configuration.Bitwarden.Enabled) {
        return
    }

    $existing = Get-Process -Name 'Bitwarden' -ErrorAction SilentlyContinue
    if ($existing) {
        Write-CapsulenvMessage -Level Detail -Message 'Bitwarden desktop is already running; its existing app-data location cannot be changed for this process.'
        return
    }

    $executable = Get-CapsulenvBitwardenExecutable
    if (-not $executable) {
        Write-CapsulenvMessage -Level Warning -Message 'Bitwarden desktop executable was not found. Install it in Scoop or update config/capsulenv.local.psd1.'
        return
    }

    [void](Start-Process -FilePath $executable -WorkingDirectory (Split-Path -Parent $executable))
    Write-CapsulenvMessage -Level Success -Message 'Bitwarden desktop started with portable app-data.'
}

function Get-CapsulenvSshAgentServiceStatePath {
    $context = Get-CapsulenvContext
    return Join-Path $context.StateRoot 'bitwarden\ssh-agent-service.json'
}

function Disable-CapsulenvWindowsSshAgent {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if (-not (Test-CapsulenvWindows)) {
        throw 'The Windows OpenSSH Authentication Agent service exists only on Windows.'
    }

    $service = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-CapsulenvMessage -Level Warning -Message 'Windows OpenSSH Authentication Agent service is not installed.'
        return
    }

    if (-not $PSCmdlet.ShouldProcess('ssh-agent', 'Stop and disable Windows OpenSSH Authentication Agent')) {
        return
    }

    $statePath = Get-CapsulenvSshAgentServiceStatePath
    if (-not (Test-Path -LiteralPath $statePath)) {
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force)
        $serviceInfo = Get-CimInstance Win32_Service -Filter "Name='ssh-agent'"
        [ordered]@{
            Status = [string]$service.Status
            StartMode = [string]$serviceInfo.StartMode
        } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    }

    if ($service.Status -ne 'Stopped') {
        Stop-Service -Name 'ssh-agent' -Force
    }
    Set-Service -Name 'ssh-agent' -StartupType Disabled
    Write-CapsulenvMessage -Level Success -Message 'Windows OpenSSH Authentication Agent disabled for Bitwarden SSH Agent.'
}

function Restore-CapsulenvWindowsSshAgent {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $statePath = Get-CapsulenvSshAgentServiceStatePath
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw 'No saved Windows ssh-agent service state exists.'
    }

    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $startupType = switch ([string]$state.StartMode) {
        'Auto' { 'Automatic' }
        'Manual' { 'Manual' }
        'Disabled' { 'Disabled' }
        default { 'Manual' }
    }

    if ($PSCmdlet.ShouldProcess('ssh-agent', "Restore startup type $startupType")) {
        Set-Service -Name 'ssh-agent' -StartupType $startupType
        if ($state.Status -eq 'Running') {
            Start-Service -Name 'ssh-agent'
        }
        Remove-Item -LiteralPath $statePath -Force
        Write-CapsulenvMessage -Level Success -Message 'Windows OpenSSH Authentication Agent service restored.'
    }
}

function Test-CapsulenvBitwardenSshAgent {
    [CmdletBinding()]
    param()

    [void](Set-CapsulenvSessionEnvironment)
    $sshAdd = Get-Command ssh-add.exe -CommandType Application -ErrorAction SilentlyContinue
    if (-not $sshAdd) {
        $sshAdd = Get-Command ssh-add -CommandType Application -ErrorAction SilentlyContinue
    }
    if (-not $sshAdd) {
        throw 'ssh-add was not found. Install the Windows OpenSSH client.'
    }

    $output = & $sshAdd.Source -L 2>&1
    $exitCode = $LASTEXITCODE
    [pscustomobject]@{
        Reachable = ($exitCode -eq 0 -or ($output -match 'no identities'))
        ExitCode = $exitCode
        Output = ($output -join [Environment]::NewLine)
    }
}

function Get-CapsulenvGitConfigBackupPath {
    $context = Get-CapsulenvContext
    return Join-Path $context.StateRoot 'bitwarden\git-ssh-config.json'
}

function Get-CapsulenvGitCommand {
    [CmdletBinding()]
    param()

    $git = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue
    if (-not $git) {
        $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue
    }
    if (-not $git) {
        throw 'Git was not found.'
    }
    return $git.Source
}

function Restore-CapsulenvGitValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Git,
        [Parameter(Mandatory = $true)]$Backup
    )

    foreach ($property in $Backup.PSObject.Properties) {
        $entry = $property.Value
        if ($entry.Exists) {
            & $Git config --global --replace-all $property.Name ([string]$entry.Value)
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to restore Git setting: $($property.Name)"
            }
        } else {
            & $Git config --global --unset-all $property.Name 2>$null
            if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 5) {
                throw "Failed to remove Git setting: $($property.Name)"
            }
        }
    }
}

function Set-CapsulenvGitOpenSsh {
    [CmdletBinding()]
    param([switch]$Force)

    $git = Get-CapsulenvGitCommand
    $windowsDirectory = [Environment]::GetEnvironmentVariable('WINDIR')
    if ([string]::IsNullOrWhiteSpace($windowsDirectory)) {
        throw 'WINDIR is not set; Microsoft OpenSSH paths cannot be resolved.'
    }
    $openSshRoot = Join-Path $windowsDirectory 'System32\OpenSSH'
    $sshPath = Join-Path $openSshRoot 'ssh.exe'
    $sshKeygenPath = Join-Path $openSshRoot 'ssh-keygen.exe'
    if (-not (Test-Path -LiteralPath $sshPath -PathType Leaf)) {
        throw "Microsoft OpenSSH client was not found: $sshPath"
    }
    if (-not (Test-Path -LiteralPath $sshKeygenPath -PathType Leaf)) {
        throw "Microsoft OpenSSH ssh-keygen was not found: $sshKeygenPath"
    }
    $gitSshPath = ([System.IO.Path]::GetFullPath($sshPath) -replace '\\', '/')
    $gitSshKeygenPath = ([System.IO.Path]::GetFullPath($sshKeygenPath) -replace '\\', '/')

    $backupPath = Get-CapsulenvGitConfigBackupPath
    $backupExists = Test-Path -LiteralPath $backupPath -PathType Leaf
    if ($backupExists -and -not $Force) {
        throw 'A Git SSH configuration backup already exists. Restore it first or pass -Force to reapply without replacing the original backup.'
    }

    if ($backupExists) {
        $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
    } else {
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force)
        $keys = @('core.sshCommand', 'gpg.ssh.program')
        $captured = [ordered]@{}
        foreach ($key in $keys) {
            $value = & $git config --global --get $key 2>$null
            $captured[$key] = [ordered]@{
                Exists = ($LASTEXITCODE -eq 0)
                Value = ($value -join [Environment]::NewLine)
            }
        }
        $captured | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $backupPath -Encoding UTF8
        $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
    }

    try {
        & $git config --global --replace-all core.sshCommand $gitSshPath
        if ($LASTEXITCODE -ne 0) { throw 'Failed to set Git core.sshCommand.' }
        & $git config --global --replace-all gpg.ssh.program $gitSshKeygenPath
        if ($LASTEXITCODE -ne 0) { throw 'Failed to set Git gpg.ssh.program.' }
    } catch {
        $configurationError = $_
        try {
            Restore-CapsulenvGitValues -Git $git -Backup $backup
            if (-not $backupExists) {
                Remove-Item -LiteralPath $backupPath -Force
            }
        } catch {
            Write-Warning "Git configuration rollback failed; the original backup was retained at $backupPath. $($_.Exception.Message)"
        }
        throw $configurationError
    }

    Write-CapsulenvMessage -Level Success -Message 'Git now uses Microsoft OpenSSH for Bitwarden SSH Agent compatibility.'
}

function Restore-CapsulenvGitOpenSsh {
    [CmdletBinding()]
    param()

    $git = Get-CapsulenvGitCommand
    $backupPath = Get-CapsulenvGitConfigBackupPath
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        throw 'No Git SSH configuration backup exists.'
    }

    $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
    Restore-CapsulenvGitValues -Git $git -Backup $backup
    Remove-Item -LiteralPath $backupPath -Force
    Write-CapsulenvMessage -Level Success -Message 'Git SSH configuration restored.'
}

##MOD_EXEC## Export-ModuleMember -Function Start-CapsulenvBitwarden, Disable-CapsulenvWindowsSshAgent, Restore-CapsulenvWindowsSshAgent, Test-CapsulenvBitwardenSshAgent, Set-CapsulenvGitOpenSsh, Restore-CapsulenvGitOpenSsh
