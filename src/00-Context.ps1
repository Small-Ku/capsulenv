Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CapsulenvContext = $null
$script:CapsulenvConfiguration = $null

function Initialize-CapsulenvContext {
    [CmdletBinding()]
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) {
        $Root = $env:CAPSULENV_ROOT
    }
    if ([string]::IsNullOrWhiteSpace($Root)) {
        throw 'CAPSULENV_ROOT is not set and no root path was supplied.'
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
