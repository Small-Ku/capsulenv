# Summary: Preserve Scoop's running-process guard while allowing the current Capsulenv reset host.
function Test-CapsulenvResetHasBlockingProcesses {
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [Parameter(Mandatory = $true)][bool]$Global
    )

    $appDirectory = appdir $App $Global | Convert-Path
    $running = @(
        Get-Process -ErrorAction SilentlyContinue | Where-Object {
            try {
                -not [string]::IsNullOrWhiteSpace([string]$_.Path) -and
                    $_.Path -like "$appDirectory\*"
            } catch {
                $false
            }
        }
    )
    if ($running.Count -eq 0) {
        return $false
    }

    $blocking = @($running | Where-Object { $_.Id -ne $PID })
    if ($blocking.Count -eq 0) {
        Write-Host "Capsulenv reset is running from '$App'; ignoring only the reset host process (PID $PID)." -ForegroundColor DarkGray
        return $false
    }

    return [bool](test_running_process $App $Global)
}
