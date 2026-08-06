# Summary: Replay installed Scoop manifest lifecycle hooks without reinstalling files.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('pre_install', 'post_install')]
    [string]$Hook,

    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Apps
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# This script is copied temporarily to <SCOOP>\shims and invoked as a custom
# Scoop command. The Scoop dispatcher has already loaded core/bucket/config
# state into the parent scope. Load the same libraries used by `scoop reset`.
$scoopRoot = Split-Path -Parent $PSScriptRoot
$scoopLib = Join-Path $scoopRoot 'apps\scoop\current\lib'
foreach ($library in @('manifest.ps1', 'system.ps1', 'install.ps1', 'versions.ps1', 'shortcuts.ps1')) {
    $libraryPath = Join-Path $scoopLib $library
    if (-not (Test-Path -LiteralPath $libraryPath -PathType Leaf)) {
        throw "Required Scoop library was not found: $libraryPath"
    }
    . $libraryPath
}

$failed = $false
foreach ($requestedApp in $Apps) {
    $app, $null, $null = parse_app $requestedApp
    if ($app -eq 'scoop') {
        continue
    }
    $global = $false
    if (-not (installed $app $false)) {
        if (installed $app $true) {
            $global = $true
        } else {
            Write-Host "Skipping '$app': not installed in either portable Scoop root." -ForegroundColor DarkGray
            continue
        }
    }

    $version = Select-CurrentVersion -AppName $app -Global:$global
    $manifest = installed_manifest $app $version $global
    $install = install_info $app $version $global
    if ($null -eq $manifest -or $null -eq $install) {
        Write-Warning "Skipping '$app': installed manifest or install metadata is missing."
        $failed = $true
        continue
    }

    $architecture = [string]$install.architecture
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        $architecture = Get-SupportedArchitecture $manifest (Get-DefaultArchitecture)
    }
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        Write-Warning "Skipping '$app': no supported architecture could be resolved."
        $failed = $true
        continue
    }

    # Recreate the documented Scoop hook context from the installed manifest
    # and install metadata. No download or reinstall is performed.
    $cmd = 'install'
    $bucket = [string]$install.bucket
    $url = $install.url
    $fname = @()
    try {
        $manifestUrls = @(url $manifest $architecture)
        if ($manifestUrls.Count -gt 0) {
            $fname = @(url_filename $manifestUrls)
        }
    } catch {
        # Some installed manifests do not have a downloadable payload. Hook
        # replay can still proceed unless that hook explicitly needs $fname.
    }
    $configVariable = Get-Variable -Name scoopConfig -ErrorAction SilentlyContinue
    $cfg = if ($null -ne $configVariable) { $configVariable.Value } else { [pscustomobject]@{} }
    $original_dir = Convert-Path (versiondir $app $version $global)
    $persist_dir = persistdir $app $global
    $dir = if ($Hook -eq 'post_install') {
        $current = currentdir $app $global
        if (Test-Path -LiteralPath $current -PathType Container) {
            Convert-Path $current
        } else {
            $original_dir
        }
    } else {
        $original_dir
    }

    $script = arch_specific $Hook $manifest $architecture
    if (-not $script) {
        Write-Host "Skipping '$app': manifest has no $Hook hook." -ForegroundColor DarkGray
        continue
    }

    Write-Host "Replaying $Hook for $app ($version)." -ForegroundColor Cyan
    try {
        Invoke-HookScript -HookType $Hook -Manifest $manifest -ProcessorArchitecture $architecture
    } catch {
        Write-Warning "Lifecycle replay failed for '$app' ($Hook): $($_.Exception.Message)"
        $failed = $true
    }
}

if ($failed) {
    exit 1
}
exit 0
