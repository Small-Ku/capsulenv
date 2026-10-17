function Get-CapsulenvShellPreparationPaths {
    [CmdletBinding()]
    param()
    $placement = Get-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity)
    return [pscustomobject]@{
        Lock = Join-Path $placement.StateRoot 'shell-preparation.lock'
        Status = Join-Path $placement.StateRoot 'shell-preparation.json'
    }
}

function Get-CapsulenvShellPreparationRequirements {
    [CmdletBinding()]
    param()
    $config = Get-CapsulenvConfiguration
    $requirements = New-Object System.Collections.Generic.List[object]
    $requirements.Add((Get-CapsulenvInteractivePowerShellRequirement -Criticality required).Requirement)
    if ($config.Bitwarden.Enabled) {
        $requirements.Add((Get-CapsulenvBitwardenProgramRequirement -App ([string]$config.Bitwarden.App) -Criticality optional).Requirement)
    }
    $singConfig = Join-Path (Get-CapsulenvContext).Root 'state/portable/sing-box/config.json'
    if (Test-Path -LiteralPath $singConfig -PathType Leaf) {
        $requirements.Add((New-CapsulenvProgramRequirement -Name 'sing-box' -RequiredCapabilities @('proxy') -AllowedProviders @('host-scoop', 'capsulenv-local', 'seed', 'provider')))
    }
    return $requirements.ToArray()
}

function Get-CapsulenvShellPreparationPending {
    [CmdletBinding()]
    param($ActivationSnapshot)
    $pending = New-Object System.Collections.Generic.List[string]
    foreach ($requirement in @(Get-CapsulenvShellPreparationRequirements)) {
        $present = $false
        if ($null -ne $ActivationSnapshot) {
            try {
                [void](Get-CapsulenvActiveGenerationProgram -Requirement $requirement -ActivationSnapshot $ActivationSnapshot)
                $present = $true
            } catch {}
        }
        if (-not $present) { $pending.Add([string]$requirement.Name) }
    }
    return [string[]]$pending.ToArray()
}

function Get-CapsulenvShellPreparationStatus {
    [CmdletBinding()]
    param()
    $paths = Get-CapsulenvShellPreparationPaths
    if (-not (Test-Path -LiteralPath $paths.Status -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $paths.Status -Raw | ConvertFrom-Json) } catch { return $null }
}

function Start-CapsulenvShellPreparationWorker {
    [CmdletBinding()]
    param([string[]]$Pending)
    if (@($Pending).Count -eq 0) { return $false }
    if (-not (Test-CapsulenvWindows)) { return $false }
    $root = (Get-CapsulenvContext).Root
    $entry = Join-Path $root 'modules/Capsulenv/runtime/Invoke-Capsulenv.ps1'
    $systemPowerShell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    if (-not (Test-Path -LiteralPath $entry -PathType Leaf) -or
        -not (Test-Path -LiteralPath $systemPowerShell -PathType Leaf)) {
        Write-CapsulenvMessage -Level Warning -Message 'Shell preparation worker is unavailable; run prepare shell in an installed capsule.'
        return $false
    }
    [void](Initialize-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity))
    $paths = Get-CapsulenvShellPreparationPaths
    $status = Get-CapsulenvShellPreparationStatus
    if ($null -ne $status -and [string]$status.State -eq 'failed') {
        $attempted = [DateTime]::MinValue
        if ([DateTime]::TryParse([string]$status.FinishedAtUtc, [ref]$attempted) -and
            ([DateTime]::UtcNow - $attempted.ToUniversalTime()).TotalMinutes -lt 10) {
            return $false
        }
    }
    try {
        $testLock = New-Object System.IO.FileStream(
            $paths.Lock, [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None
        )
        $testLock.Dispose()
    } catch [System.IO.IOException] { return $false }

    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $entry, 'prepare', 'shell', '--worker')
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $systemPowerShell
    $startInfo.Arguments = (@($arguments | ForEach-Object {
        ConvertTo-CapsulenvNativeCommandLineArgument -Argument ([string]$_)
    }) -join ' ')
    $startInfo.WorkingDirectory = $root
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.EnvironmentVariables['CAPSULENV_MODE'] = 'ShellOnly'
    $startInfo.EnvironmentVariables['CAPSULENV_ROOT'] = $root
    $process = New-Object System.Diagnostics.Process
    try {
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { return $false }
        return $true
    } finally { $process.Dispose() }
}

function Invoke-CapsulenvShellPreparation {
    [CmdletBinding()]
    param()
    [void](Initialize-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity))
    $paths = Get-CapsulenvShellPreparationPaths
    try {
        $lock = New-Object System.IO.FileStream(
            $paths.Lock, [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None
        )
    } catch [System.IO.IOException] {
        Write-CapsulenvMessage -Level Detail -Message 'Shell preparation is already running.'
        return
    }
    try {
        [void](Set-CapsulenvSessionEnvironment -IntegrationMode ShellOnly)
        $attempted = [DateTime]::UtcNow.ToString('o')
        $failures = New-Object System.Collections.Generic.List[string]
        $prepared = New-Object System.Collections.Generic.List[string]
        foreach ($requirement in @(Get-CapsulenvShellPreparationRequirements)) {
            try {
                [void](Ensure-CapsulenvProgramGeneration -Requirement $requirement)
                $prepared.Add([string]$requirement.Name)
            } catch {
                $failures.Add(('{0}: {1}' -f [string]$requirement.Name, [string]$_.Exception.Message))
            }
        }
        $status = [ordered]@{
            SchemaVersion = 1
            State = if ($failures.Count -eq 0) { 'completed' } else { 'failed' }
            AttemptedAtUtc = $attempted
            FinishedAtUtc = [DateTime]::UtcNow.ToString('o')
            Prepared = @($prepared.ToArray())
            Errors = @($failures.ToArray())
        }
        Write-CapsulenvHostJsonAtomically -Path $paths.Status -Value $status
        if ($failures.Count -gt 0) {
            Write-CapsulenvMessage -Level Warning -Message ('Shell preparation incomplete: {0}' -f ($failures -join '; '))
        }
        return [pscustomobject]$status
    } finally { $lock.Dispose() }
}

function Invoke-CapsulenvPrepareCommand {
    [CmdletBinding()]
    param([string[]]$Arguments)
    $action = if (@($Arguments).Count -ge 1) { [string]$Arguments[0] } else { '' }
    if ($action -eq 'status' -and @($Arguments).Count -eq 1) {
        $status = Get-CapsulenvShellPreparationStatus
        if ($null -eq $status) {
            Write-CapsulenvMessage -Level Detail -Message 'Shell preparation has no recorded result on this host.'
        } else {
            $status | Format-List
        }
        return
    }
    if ($action -ne 'shell' -or (@($Arguments).Count -gt 1 -and
        (@($Arguments).Count -ne 2 -or [string]$Arguments[1] -ne '--worker'))) {
        throw 'Usage: capsulenv prepare <shell|status>'
    }
    $result = Invoke-CapsulenvShellPreparation
    if ($null -ne $result -and @($Arguments).Count -eq 1) { $result | Format-List }
}
##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvShellPreparationStatus
