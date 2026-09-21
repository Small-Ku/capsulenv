Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CapsulenvTestModuleBuild {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)

    $sharedModulePath = [string]$env:CAPSULENV_TEST_PREBUILT_MODULE_PATH
    if (-not [string]::IsNullOrWhiteSpace($sharedModulePath)) {
        $sharedModulePath = [System.IO.Path]::GetFullPath($sharedModulePath)
        if (-not (Test-Path -LiteralPath $sharedModulePath -PathType Leaf)) {
            throw "CAPSULENV_TEST_PREBUILT_MODULE_PATH does not identify a prebuilt module: $sharedModulePath"
        }
        return [pscustomobject][ordered]@{
            ModulePath = $sharedModulePath
            Shared = $true
        }
    }

    return & (Join-Path ([System.IO.Path]::GetFullPath($Root)) 'Merge-ModuleScripts.ps1') -Clean
}

function Get-CapsulenvTestPowerShellExecutable {
    [CmdletBinding()]
    param()

    $command = Get-Command pwsh.exe, pwsh -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) {
        throw 'The test process cannot resolve a PowerShell executable for a child-process fixture.'
    }
    return [string]$command.Source
}

function Start-CapsulenvTestSleepProcess {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 300)][int]$Seconds = 30,
        [string]$WritePidPath
    )

    $executable = Get-CapsulenvTestPowerShellExecutable
    $command = if ([string]::IsNullOrWhiteSpace($WritePidPath)) {
        'Start-Sleep -Seconds {0}' -f $Seconds
    } else {
        $literalPath = $WritePidPath.Replace("'", "''")
        "Set-Content -LiteralPath '$literalPath' -Value `$PID; Start-Sleep -Seconds $Seconds"
    }
    return Microsoft.PowerShell.Management\Start-Process `
        -FilePath $executable `
        -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $command) `
        -PassThru
}
