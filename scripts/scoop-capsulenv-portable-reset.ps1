# Summary: Rebuild Scoop-owned portable links without touching user/machine integration.
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Apps = @('*')
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$scoopRoot = Split-Path -Parent $PSScriptRoot
$scoopLib = Join-Path $scoopRoot 'apps\scoop\current\lib'
foreach ($library in @('manifest.ps1', 'system.ps1', 'install.ps1', 'versions.ps1')) {
    $libraryPath = Join-Path $scoopLib $library
    if (-not (Test-Path -LiteralPath $libraryPath -PathType Leaf)) {
        throw "Required Scoop library was not found: $libraryPath"
    }
    . $libraryPath
}

# Scoop's shim() calls Add-Path even when we only want to recreate shim files.
# The upstream Add-Path persists to the User (or Machine with -Global) registry.
# Override it inside this temporary command so ShellOnly repair remains process-only.
function Add-Path {
    param(
        [string[]]$Path,
        [string]$TargetEnvVar = 'PATH',
        [switch]$Global,
        [switch]$Force,
        [switch]$Quiet
    )

    $currentTarget = [Environment]::GetEnvironmentVariable($TargetEnvVar, 'Process')
    $inTarget, $strippedTarget = Split-PathLikeEnvVar $Path $currentTarget
    if (!$inTarget -or $Force) {
        [Environment]::SetEnvironmentVariable(
            $TargetEnvVar,
            ((@($Path) + $strippedTarget) -join ';'),
            'Process'
        )
    }

    # Preserve Scoop's immediate-session behavior when an isolated target path
    # variable is used, but never persist either value beyond this process.
    if ($TargetEnvVar -ne 'PATH') {
        $inPath, $strippedPath = Split-PathLikeEnvVar $Path $env:PATH
        if (!$inPath -or $Force) {
            $env:PATH = (@($Path) + $strippedPath) -join ';'
        }
    }
}

$requested = @($Apps)
if ($requested.Count -eq 0 -or $requested -contains '*') {
    $local = installed_apps $false | ForEach-Object { ,@($_, $false) }
    $global = installed_apps $true | ForEach-Object { ,@($_, $true) }
    $requested = @($local) + @($global)
}

$failed = $false
foreach ($entry in $requested) {
    $global = $null
    $requestedApp = $entry
    if ($entry -is [array] -and $entry.Count -ge 2) {
        $requestedApp = [string]$entry[0]
        $global = [bool]$entry[1]
    }

    $app, $null, $version = parse_app $requestedApp
    if ($app -eq 'scoop') {
        continue
    }
    if ($null -eq $global) {
        if (installed $app $false) {
            $global = $false
        } elseif (installed $app $true) {
            $global = $true
        } else {
            Write-Host "Skipping '$app': not installed in either portable Scoop root." -ForegroundColor DarkGray
            continue
        }
    }
    if ($global -and !(is_admin)) {
        Write-Warning "Skipping global app '$app': portable global reset requires Administrator rights."
        $failed = $true
        continue
    }
    if ($null -eq $version) {
        $version = Select-CurrentVersion -AppName $app -Global:$global
    }

    $manifest = installed_manifest $app $version $global
    $install = install_info $app $version $global
    if ($null -eq $manifest -or $null -eq $install) {
        Write-Warning "Skipping '$app': installed manifest or install metadata is missing."
        $failed = $true
        continue
    }
    if (test_running_process $app $global) {
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

    Write-Host "Portable-resetting $app ($version)." -ForegroundColor Cyan
    try {
        $dir = Convert-Path (versiondir $app $version $global)
        $original_dir = $dir
        $persist_dir = persistdir $app $global
        $dir = link_current $dir
        create_shims $manifest $dir $global $architecture
        unlink_persist_data $manifest $original_dir
        persist_data $manifest $original_dir $persist_dir
        persist_permission $manifest $global
    } catch {
        Write-Warning "Portable reset failed for '$app': $($_.Exception.Message)"
        $failed = $true
    }
}

if ($failed) {
    exit 1
}
exit 0
