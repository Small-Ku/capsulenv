Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CapsulenvContext = $null
$script:CapsulenvConfiguration = $null
$script:CapsulenvModuleRoot = $PSScriptRoot

function Initialize-CapsulenvContext {
    [CmdletBinding()]
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) {
        $Root = $env:CAPSULENV_ROOT
    }
    if ([string]::IsNullOrWhiteSpace($Root)) {
        throw (New-CapsulenvDiagnosticErrorRecord `
            -Id 'Capsulenv.Context.RootMissing' `
            -Message '[[CapsulenvText:Context.RootMissing.Message]]' `
            -Category ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
            -Remediation @('[[CapsulenvText:Context.RootMissing.Remediation]]'))
    }

    $resolvedRoot = [System.IO.Path]::GetFullPath($Root)
    $configRoot = Join-Path $resolvedRoot 'config'
    $script:CapsulenvContext = [pscustomobject]@{
        Root = $resolvedRoot
        ConfigPath = Join-Path $configRoot 'capsulenv.psd1'
        LocalConfigPath = Join-Path $configRoot 'capsulenv.local.psd1'
        StateRoot = Join-Path $resolvedRoot '.capsulenv'
        BuildRoot = Join-Path $resolvedRoot '.build'
    }
    $script:CapsulenvConfiguration = $null
    return $script:CapsulenvContext
}

function Get-CapsulenvContext {
    [CmdletBinding()]
    param()

    if ($null -eq $script:CapsulenvContext) {
        [void](Initialize-CapsulenvContext)
    }
    return $script:CapsulenvContext
}

function Get-CapsulenvRuntimeContext {
    [CmdletBinding()]
    param()

    $context = Get-CapsulenvContext
    $configuration = Get-CapsulenvConfiguration
    $moduleRoots = @(
        foreach ($entry in @($configuration.Environment.ModulePath)) {
            Resolve-CapsulenvPath -Path ([string]$entry) -AllowMissing
        }
    )
    $currentPowerShell = $null
    try {
        $currentPowerShell = [string](Get-Process -Id $PID).Path
    } catch {
        $currentPowerShell = $null
    }

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        Version = Get-CapsulenvRuntimeVersion
        Id = Get-CapsulenvIdentity
        Root = $context.Root
        Mode = Get-CapsulenvInstallMode
        ModuleRoots = $moduleRoots
        Storage = [pscustomobject][ordered]@{
            DataRoot = Resolve-CapsulenvPath -Path 'tool-data' -AllowMissing
            CacheRoot = Resolve-CapsulenvPath -Path 'cache' -AllowMissing
            ProjectCacheRoot = Resolve-CapsulenvPath -Path 'project-cache' -AllowMissing
            ScratchRoot = Get-CapsulenvScratchPath
        }
        Runtime = [pscustomobject][ordered]@{
            Launcher = Get-CapsulenvControlLauncherPath
            PowerShell = $currentPowerShell
            PowerShellVersion = [string]$PSVersionTable.PSVersion
            PSEdition = [string]$PSVersionTable.PSEdition
        }
        Capabilities = [pscustomobject][ordered]@{
            SessionModes = @('ShellOnly', 'User')
            PackageProviders = @('PortableSafe', 'Scoop')
            PackagePlanFeatures = @('ExecutableAliases')
            PackagePlanSchemaVersion = 2
            TrustModes = @('PortableSafe', 'TrustedExecution')
            InstalledAppExecution = 'ProcessPlanV1'
            LifecycleRoutineTriggers = @('OnEnter', 'OnExit', 'OnRehydrate', 'OnEject')
        }
    }
}

function Get-CapsulenvModuleRuntimePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    $runtimeRoot = Join-Path $script:CapsulenvModuleRoot 'runtime'
    return Join-Path $runtimeRoot $Name
}

function Resolve-CapsulenvPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowMissing
    )

    $context = Get-CapsulenvContext
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return [System.IO.Path]::GetFullPath($expanded)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $context.Root $expanded))
}

function New-CapsulenvDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = Resolve-CapsulenvPath -Path $Path -AllowMissing
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $resolved -Force)
    }
    return $resolved
}

function Write-CapsulenvMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Detail')]
        [string]$Level = 'Info'
    )

    $color = switch ($Level) {
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error' { 'Red' }
        'Detail' { 'DarkGray' }
        default { 'Cyan' }
    }
    Write-Host $Message -ForegroundColor $color
}

function Test-CapsulenvWindows {
    [CmdletBinding()]
    param()

    if ($PSVersionTable.PSVersion.Major -le 5) {
        return $true
    }
    return $IsWindows
}

function Clear-CapsulenvLastExitCode {
    [CmdletBinding()]
    param()

    Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
}

function Get-CapsulenvLastExitCode {
    [CmdletBinding()]
    param(
        [bool]$Succeeded = $true,
        [int]$FailureCode = 1
    )

    $variable = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
    if ($null -ne $variable -and $null -ne $variable.Value) {
        return [int]$variable.Value
    }
    if ($Succeeded) {
        return 0
    }
    return $FailureCode
}

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvRuntimeContext
