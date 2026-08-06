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

    $scoopExecutable = Get-CapsulenvScoopExecutable
    $results.Add((New-CapsulenvCheckResult `
        -Name 'Scoop command' `
        -Passed ($null -ne $scoopExecutable) `
        -Detail $(if ($scoopExecutable) { $scoopExecutable } else { 'Not found' })))

    $configHome = Resolve-CapsulenvPath -Path $configuration.Scoop.ConfigHome -AllowMissing
    $results.Add((New-CapsulenvCheckResult `
        -Name 'Scoop XDG config home' `
        -Passed ([System.IO.Path]::IsPathRooted($configHome)) `
        -Detail $configHome))

    if ($configuration.Bitwarden.Enabled) {
        $bitwarden = Get-CapsulenvBitwardenExecutable
        $results.Add((New-CapsulenvCheckResult `
            -Name 'Bitwarden desktop' `
            -Passed ($null -ne $bitwarden) `
            -Importance Optional `
            -Detail $(if ($bitwarden) { $bitwarden } else { 'Not found' })))

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
        if (-not $definition.Enabled) { continue }
        $executable = Get-CapsulenvBrowserExecutable -Browser $browser
        $profile = Get-CapsulenvBrowserProfileRoot -Browser $browser
        $results.Add((New-CapsulenvCheckResult `
            -Name "$browser executable" `
            -Passed ($null -ne $executable) `
            -Importance Optional `
            -Detail $(if ($executable) { $executable } else { 'Not found' })))
        $results.Add((New-CapsulenvCheckResult `
            -Name "$browser portable profile" `
            -Passed (Test-Path -LiteralPath $profile -PathType Container) `
            -Importance Optional `
            -Detail $profile))
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
    [void](New-CapsulenvDirectory -Path $configuration.Scoop.Root)
    [void](New-CapsulenvDirectory -Path $configuration.Scoop.ConfigHome)
    if ($configuration.Scoop.ResetShimsOnEnter) {
        [void](Reset-CapsulenvScoopShims -Quiet)
    }
    Initialize-CapsulenvBitwarden
}

function Initialize-Capsulenv {
    [CmdletBinding()]
    param(
        [ValidateSet('None', 'Copy', 'Move')]
        [string]$MigrateBrowserProfiles = 'None',
        [switch]$Force
    )

    $configuration = Get-CapsulenvConfiguration -Refresh
    $context = Get-CapsulenvContext
    [void](New-Item -ItemType Directory -Path $context.StateRoot -Force)
    [void](Set-CapsulenvSessionEnvironment)
    [void](New-CapsulenvDirectory -Path $configuration.Scoop.Root)
    [void](New-CapsulenvDirectory -Path $configuration.Scoop.ConfigHome)
    [void](Reset-CapsulenvScoopShims -Quiet)
    Initialize-CapsulenvBitwarden

    foreach ($browser in @('Firefox', 'Zen')) {
        $definition = Get-CapsulenvBrowserDefinition -Browser $browser
        if ($definition.Enabled -and $definition.AutoRegisterProfile) {
            Register-CapsulenvBrowserProfile `
                -Browser $browser `
                -Migrate $MigrateBrowserProfiles `
                -InstallDefault:$definition.RegisterInstallDefaults `
                -Force:$Force
        }
    }

    Write-CapsulenvMessage -Level Success -Message "capsulenv initialized at $($context.Root)"
}

##MOD_EXEC## Export-ModuleMember -Function Initialize-Capsulenv, Invoke-CapsulenvDoctor
