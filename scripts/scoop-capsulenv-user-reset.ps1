# Summary: Rebuild Scoop-owned links and explicit current-user integration without self-deadlocking on the Capsulenv host process.
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$ModeOrApp = ':strict',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Apps = @()
)

# Scoop dispatches subcommand arguments through a string[] splat. Named
# parameters are not reparsed in that path, so keep the private protocol
# positional. The fallback treats an unknown first token as an app name for
# compatibility with older/direct invocations of this helper.
$deferRunningApps = $false
switch ($ModeOrApp.ToLowerInvariant()) {
    ':strict' { }
    ':defer' { $deferRunningApps = $true }
    default { $Apps = @($ModeOrApp) + @($Apps) }
}
if ($Apps.Count -eq 0) {
    $Apps = @('*')
}

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$scoopRoot = Split-Path -Parent $PSScriptRoot
$scoopLib = Join-Path $scoopRoot 'apps\scoop\current\lib'
foreach ($library in @('manifest.ps1', 'system.ps1', 'install.ps1', 'versions.ps1', 'shortcuts.ps1')) {
    $libraryPath = Join-Path $scoopLib $library
    if (-not (Test-Path -LiteralPath $libraryPath -PathType Leaf)) {
        throw "Required Scoop library was not found: $libraryPath"
    }
    . $libraryPath
}
$guardPath = Join-Path (Join-Path $env:CAPSULENV_ROOT 'scripts') 'scoop-capsulenv-process-guard.ps1'
if (-not (Test-Path -LiteralPath $guardPath -PathType Leaf)) {
    throw "Required Capsulenv reset guard was not found: $guardPath"
}
. $guardPath

$requested = @($Apps)
if ($requested.Count -eq 0 -or $requested -contains '*') {
    $local = installed_apps $false | ForEach-Object { ,@($_, $false) }
    $global = installed_apps $true | ForEach-Object { ,@($_, $true) }
    $requested = @($local) + @($global)
}

$failed = $false
$deferred = $false
foreach ($entry in $requested) {
    $global = $null
    $requestedApp = $entry
    if ($entry -is [array] -and $entry.Count -ge 2) {
        $requestedApp = [string]$entry[0]
        $global = [bool]$entry[1]
    } elseif ($requestedApp -match '^(?i:(user|global))/(.+)$') {
        $scope = [string]$Matches[1]
        $requestedApp = [string]$Matches[2]
        $global = [System.StringComparer]::OrdinalIgnoreCase.Equals($scope, 'global')
    }

    $app, $null, $version = parse_app $requestedApp
    if ($app -eq 'scoop') { continue }
    if ($null -eq $global) {
        if (installed $app $false) { $global = $false }
        elseif (installed $app $true) { $global = $true }
        else {
            Write-Host "Skipping '$app': not installed in either portable Scoop root." -ForegroundColor DarkGray
            continue
        }
    }
    if ($null -ne $global -and -not (installed $app $global)) {
        $scopeLabel = if ($global) { 'global' } else { 'user' }
        Write-Host "Skipping '$scopeLabel/$app': not installed in that portable Scoop root." -ForegroundColor DarkGray
        continue
    }
    if ($global -and !(is_admin)) {
        Write-Warning "Skipping global app '$app': user reset requires Administrator rights."
        $failed = $true
        continue
    }
    if ($null -eq $version) { $version = Select-CurrentVersion -AppName $app -Global:$global }

    $manifest = installed_manifest $app $version $global
    $install = install_info $app $version $global
    if ($null -eq $manifest -or $null -eq $install) {
        Write-Warning "Skipping '$app': installed manifest or install metadata is missing."
        $failed = $true
        continue
    }
    if (Test-CapsulenvResetHasBlockingProcesses -App $app -Global $global) {
        if ($deferRunningApps) {
            Write-Warning "Deferring user reset for '$app' until its running processes have exited."
            $deferred = $true
        } else {
            $failed = $true
        }
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

    Write-Host "Resetting $app ($version)." -ForegroundColor Cyan
    try {
        $dir = Convert-Path (versiondir $app $version $global)
        $original_dir = $dir
        $persist_dir = persistdir $app $global
        $dir = link_current $dir
        create_shims $manifest $dir $global $architecture
        create_startmenu_shortcuts $manifest $dir $global $architecture
        env_rm_path $manifest $dir $global $architecture
        env_rm $manifest $global $architecture
        env_add_path $manifest $dir $global $architecture
        env_set $manifest $global $architecture
        unlink_persist_data $manifest $original_dir
        persist_data $manifest $original_dir $persist_dir
        persist_permission $manifest $global
    } catch {
        Write-Warning "User reset failed for '$app': $($_.Exception.Message)"
        $failed = $true
    }
}

if ($failed) { exit 1 }
if ($deferred) { exit 2 }
exit 0
