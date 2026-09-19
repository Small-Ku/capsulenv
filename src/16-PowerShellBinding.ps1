function Get-CapsulenvPowerShellStatePaths {
    [CmdletBinding()]
    param([switch]$Create)

    $context = Get-CapsulenvContext
    $root = Join-Path $context.Root 'state/portable/powershell'
    $hostPlacement = Get-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity)
    if ($Create) {
        # A host-local descendant is only materialized after its placement
        # marker has been published and validated.
        $hostPlacement = Initialize-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity)
    }
    $paths = [pscustomobject][ordered]@{
        Root = $root
        ProfilePath = Join-Path $root 'Microsoft.PowerShell_profile.ps1'
        HistoryRoot = Join-Path $root 'history'
        HistoryPath = Join-Path (Join-Path $root 'history') 'ConsoleHost_history.txt'
        PortableModulesRoot = Join-Path $root 'modules'
        HostModulesRoot = $hostPlacement.ModulesRoot
        BootstrapPath = Join-Path $root 'Capsulenv.PowerShellBootstrap.ps1'
    }
    if ($Create) {
        foreach ($path in @($paths.Root, $paths.HistoryRoot, $paths.PortableModulesRoot, $paths.HostModulesRoot)) {
            [void](New-Item -ItemType Directory -Path $path -Force)
        }
        if (-not (Test-Path -LiteralPath $paths.ProfilePath -PathType Leaf)) {
            New-Item -ItemType File -Path $paths.ProfilePath -Force | Out-Null
        }
    }
    return $paths
}

function Write-CapsulenvPowerShellBootstrap {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Paths)

    $content = @'
$portableProfile = [Environment]::GetEnvironmentVariable('CAPSULENV_POWERSHELL_PROFILE', 'Process')
if (-not [string]::IsNullOrWhiteSpace($portableProfile) -and (Test-Path -LiteralPath $portableProfile -PathType Leaf)) {
    . $portableProfile
}
$historyPath = [Environment]::GetEnvironmentVariable('CAPSULENV_POWERSHELL_HISTORY', 'Process')
if (-not [string]::IsNullOrWhiteSpace($historyPath)) {
    $setHistory = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue
    if ($null -ne $setHistory) {
        Set-PSReadLineOption -HistorySavePath $historyPath
    }
}
'@
    [System.IO.File]::WriteAllText(
        $Paths.BootstrapPath,
        $content,
        (New-Object System.Text.UTF8Encoding($true))
    )
    return $Paths.BootstrapPath
}

function ConvertTo-CapsulenvPowerShellLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'$(($Value -replace "'", "''"))'"
}

function Get-CapsulenvInteractivePowerShellRequirement {
    [CmdletBinding()]
    param(
        [string]$MinimumVersion,
        [ValidateSet('required', 'optional')]
        [string]$Criticality = 'required'
    )

    return [pscustomobject][ordered]@{
        Requirement = New-CapsulenvProgramRequirement -Name pwsh -MinimumVersion $MinimumVersion -RequiredCapabilities @('interactive') -AllowedProviders @('host-scoop', 'capsulenv-local', 'seed', 'provider')
        Criticality = $Criticality
    }
}

function Resolve-CapsulenvPowerShellBinding {
    [CmdletBinding()]
    param(
        $Requirement,
        [object[]]$Candidates,
        [ValidateSet('required', 'optional')]
        [string]$Criticality = 'required',
        [string[]]$TrustedHostModulePaths = @()
    )

    if ($null -eq $Requirement) {
        $Requirement = (Get-CapsulenvInteractivePowerShellRequirement -Criticality $Criticality).Requirement
    }
    $effectiveCandidates = if ($PSBoundParameters.ContainsKey('Candidates')) {
        @($Candidates)
    } else {
        @(Get-CapsulenvProgramCandidates -Requirement $Requirement | ForEach-Object {
            [pscustomobject][ordered]@{
                Name = $_.Name
                Executable = $_.Executable
                Root = $_.Root
                Provider = $_.Provider
                Scope = $_.Scope
                Version = $_.Version
                Capabilities = @('interactive')
                Trusted = $_.Trusted
                OwnsLifecycle = $_.OwnsLifecycle
                Provenance = $_.Provenance
            }
        })
    }
    $resolution = Get-CapsulenvProgramResolution -Requirement $Requirement -Candidates $effectiveCandidates
    if (-not $resolution.Succeeded -and -not $PSBoundParameters.ContainsKey('Candidates')) {
        $seed = @(Get-CapsulenvSeedAcquisitionCandidates -Requirement $Requirement | Select-Object -First 1)
        if ($seed.Count -eq 1) {
            $source = Resolve-CapsulenvPortableSeedSourcePath -Entry $seed[0]
            $manifest = Acquire-CapsulenvProgramRealization -Name ([string]$seed[0].Name) -Version ([string]$seed[0].Version) -SourcePath $source -ExecutableRelativePath ([string]$seed[0].ExecutableRelativePath) -ExpectedHash ([string]$seed[0].ExpectedHash) -Provider seed -Provenance ([string]$seed[0].Provenance)
            $payload = Join-Path $manifest.RealizationRoot 'payload'
            $seedExecutable = Resolve-CapsulenvRealizationPayloadPath -PayloadRoot $payload -ExecutableRelativePath ([string]$manifest.ExecutableRelativePath)
            $effectiveCandidates = @($effectiveCandidates) + @(New-CapsulenvProgramCandidate -Name ([string]$manifest.Name) -Executable $seedExecutable -Root ([string]$manifest.RealizationRoot) -Provider seed -Scope host-local -Version ([string]$manifest.Version) -Capabilities @('interactive') -Trusted:$true -Provenance ([string]$manifest.Provenance))
            $resolution = Get-CapsulenvProgramResolution -Requirement $Requirement -Candidates $effectiveCandidates
        }
    }
    if (-not $resolution.Succeeded) {
        $message = 'Required interactive pwsh has no compatible trusted realization.'
        if ($Criticality -eq 'required') {
            throw $message
        }
        return [pscustomobject][ordered]@{
            Succeeded = $false
            Diagnostics = @($message + ' Optional interactive shell skipped.')
            Program = $null
        }
    }

    $paths = Get-CapsulenvPowerShellStatePaths -Create
    $modulePaths = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($paths.PortableModulesRoot, $paths.HostModulesRoot) + @($TrustedHostModulePaths)) {
        if ([string]::IsNullOrWhiteSpace([string]$path)) { continue }
        if ($modulePaths -notcontains [string]$path) {
            $modulePaths.Add([string]$path)
        }
    }
    $bootstrapPath = $null
    $profileLiteral = ConvertTo-CapsulenvPowerShellLiteral -Value ([string]$paths.ProfilePath)
    $historyLiteral = ConvertTo-CapsulenvPowerShellLiteral -Value ([string]$paths.HistoryPath)
    $bootstrapCommand = "& { if (Test-Path -LiteralPath $profileLiteral -PathType Leaf) { . $profileLiteral }; `$setHistory = Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue; if (`$null -ne `$setHistory) { Set-PSReadLineOption -HistorySavePath $historyLiteral } }"
    return [pscustomobject][ordered]@{
        Succeeded = $true
        Program = $resolution.Selected
        ProfilePath = $paths.ProfilePath
        HistoryPath = $paths.HistoryPath
        PortableModuleRoot = $paths.PortableModulesRoot
        HostModuleRoot = $paths.HostModulesRoot
        BootstrapPath = $bootstrapPath
        BootstrapCommand = $bootstrapCommand
        LaunchArguments = @('-NoLogo', '-NoProfile', '-NoExit', '-Command', $bootstrapCommand)
        PSModulePath = ($modulePaths.ToArray() -join [System.IO.Path]::PathSeparator)
        Environment = [pscustomobject][ordered]@{
            PSModulePath = ($modulePaths.ToArray() -join [System.IO.Path]::PathSeparator)
            CAPSULENV_POWERSHELL_PROFILE = $paths.ProfilePath
            CAPSULENV_POWERSHELL_HISTORY = $paths.HistoryPath
        }
        ControlPlaneFallback = $false
        Diagnostics = @('interactive pwsh resolved independently from the control plane', 'child bootstrap dot-sources the portable profile and configures PSReadLine history')
    }
}

function Invoke-CapsulenvPowerShellActivation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Binding,
        [switch]$Apply
    )

    if (-not $Binding.Succeeded) {
        throw 'PowerShell activation failed because the interactive program was not resolved.'
    }
    if ($Apply) {
        foreach ($property in @($Binding.Environment.PSObject.Properties)) {
            [Environment]::SetEnvironmentVariable($property.Name, [string]$property.Value, 'Process')
        }
    }
    return $Binding
}

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvPowerShellStatePaths, Get-CapsulenvInteractivePowerShellRequirement, Resolve-CapsulenvPowerShellBinding, Invoke-CapsulenvPowerShellActivation
