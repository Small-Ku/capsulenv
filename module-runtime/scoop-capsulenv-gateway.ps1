[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Arguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:CapsulenvGatewayPath = [System.IO.Path]::GetFullPath($PSCommandPath)

function Get-CapsulenvGatewayExitCode {
    param([bool]$Succeeded)
    $lastExit = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
    if ($null -ne $lastExit -and $null -ne $lastExit.Value) {
        return [int]$lastExit.Value
    }
    if ($Succeeded) { return 0 }
    return 1
}

function Write-CapsulenvScoopGatewayShims {
    param([Parameter(Mandatory = $true)][string]$ScoopRoot)

    $shimsRoot = Join-Path $ScoopRoot 'shims'
    [void](New-Item -ItemType Directory -Path $shimsRoot -Force)
    $gatewayPath = $script:CapsulenvGatewayPath
    $ps1Path = Join-Path $shimsRoot 'scoop.ps1'
    $ps1Text = ('# {0}{1}' -f $gatewayPath, [Environment]::NewLine) + @'
if ([string]::IsNullOrWhiteSpace($env:CAPSULENV_ROOT)) {
    Write-Error 'Capsulenv Scoop shim requires an active capsulenv shell.'
    exit 2
}
$path = Join-Path $env:CAPSULENV_ROOT 'modules\Capsulenv\runtime\scoop-capsulenv-gateway.ps1'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
    $fallback = Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $fallback) {
        Write-Error 'Capsulenv Scoop gateway requires Windows PowerShell 5.1.'
        exit 2
    }
    $windowsPowerShell = [string]$fallback.Source
}
$controlArguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path) + @($args)
if ($MyInvocation.ExpectingInput) {
    $input | & $windowsPowerShell @controlArguments
} else {
    & $windowsPowerShell @controlArguments
}
exit $LASTEXITCODE
'@
    [System.IO.File]::WriteAllText($ps1Path, $ps1Text, [System.Text.UTF8Encoding]::new($false))

    $cmdPath = Join-Path $shimsRoot 'scoop.cmd'
    $cmdText = ('@rem {0}{1}' -f $gatewayPath, [Environment]::NewLine) + @'
@echo off
setlocal EnableExtensions DisableDelayedExpansion
if "%CAPSULENV_ROOT%"=="" (
  >&2 echo Capsulenv Scoop shim requires an active capsulenv shell.
  exit /b 2
)
set "CAPSULENV_SCOOP_GATEWAY=%CAPSULENV_ROOT%\modules\Capsulenv\runtime\scoop-capsulenv-gateway.ps1"
set "CAPSULENV_CONTROL_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%CAPSULENV_CONTROL_POWERSHELL%" set "CAPSULENV_CONTROL_POWERSHELL=powershell.exe"
"%CAPSULENV_CONTROL_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CAPSULENV_SCOOP_GATEWAY%" %*
exit /b %ERRORLEVEL%
'@
    [System.IO.File]::WriteAllText($cmdPath, $cmdText, [System.Text.UTF8Encoding]::new($false))
}

function Remove-CapsulenvGatewayTemporaryScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScoopRoot,
        [Parameter(Mandatory = $true)][string]$FileName,
        [string]$OriginalPath
    )

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($OriginalPath)) {
        $candidates += $OriginalPath
    }
    foreach ($versionName in @('current', 'old', 'new')) {
        $candidates += Join-Path $ScoopRoot ("apps\scoop\{0}\libexec\{1}" -f $versionName, $FileName)
    }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
    }
}

if ([string]::IsNullOrWhiteSpace($env:SCOOP)) {
    throw 'SCOOP is not set. Run this command from an active capsulenv shell.'
}
$scoopRoot = [System.IO.Path]::GetFullPath($env:SCOOP)
$upstream = Join-Path $scoopRoot 'apps\scoop\current\bin\scoop.ps1'
if (-not (Test-Path -LiteralPath $upstream -PathType Leaf)) {
    throw "Capsule Scoop executable was not found: $upstream"
}

$command = if ($Arguments.Count -gt 0) { [string]$Arguments[0].ToLowerInvariant() } else { '' }
# The first group directly invokes Scoop functions that can persist user state.
# The second group can jump to one of those commands through a sibling libexec
# script, bypassing this gateway unless the call is rewritten below.
$policyCommands = @('install', 'update', 'uninstall', 'reset', 'shim')
$nestedGatewayCommands = @('install', 'download', 'virustotal', 'import')
$intercept = $command -in @($policyCommands + $nestedGatewayCommands | Select-Object -Unique)
if ($env:CAPSULENV_MODE -ne 'ShellOnly' -or -not $intercept) {
    Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    if ($MyInvocation.ExpectingInput) {
        $input | & $upstream @Arguments
    } else {
        & $upstream @Arguments
    }
    $ok = $?
    exit (Get-CapsulenvGatewayExitCode -Succeeded $ok)
}

if ([string]::IsNullOrWhiteSpace($env:CAPSULENV_ROOT)) {
    throw 'CAPSULENV_ROOT is not set. ShellOnly Scoop policy cannot be located.'
}
$policyPath = Join-Path (Split-Path -Parent $script:CapsulenvGatewayPath) 'scoop-capsulenv-shellonly-policy.ps1'
if ($command -in $policyCommands -and -not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
    throw "Capsulenv ShellOnly Scoop policy is missing: $policyPath"
}

$libexec = Join-Path $scoopRoot ("apps\scoop\current\libexec\scoop-{0}.ps1" -f $command)
if (-not (Test-Path -LiteralPath $libexec -PathType Leaf)) {
    throw "Scoop command implementation was not found: $libexec"
}
$source = [System.IO.File]::ReadAllText($libexec)
$changed = $false

if ($command -in $policyCommands) {
    $insertionPoint = [regex]::Match($source, '(?m)^\$opt\s*,')
    if (-not $insertionPoint.Success) {
        throw "Unsupported Scoop $command command layout: Capsulenv could not locate the option parser boundary."
    }
    $escapedPolicy = $policyPath.Replace("'", "''")
    $source = $source.Insert($insertionPoint.Index, ". '$escapedPolicy'`r`n")
    $changed = $true
}

$escapedGateway = $PSCommandPath.Replace("'", "''")
if ($command -in @('install', 'download', 'virustotal')) {
    $pattern = [regex]::Escape('& "$PSScriptRoot\scoop-update.ps1"')
    $replacement = "& '$escapedGateway' update"
    $rewritten = [regex]::Replace($source, $pattern, $replacement)
    if ($rewritten -eq $source) {
        throw "Unsupported Scoop $command command layout: Capsulenv could not guard its nested Scoop update."
    }
    $source = $rewritten
    $changed = $true
}
if ($command -eq 'import') {
    $pattern = [regex]::Escape('& "$PSScriptRoot\scoop-install.ps1" $app @instArgs')
    $replacement = "& '$escapedGateway' install `$app @instArgs"
    $rewritten = [regex]::Replace($source, $pattern, $replacement)
    if ($rewritten -eq $source) {
        throw 'Unsupported Scoop import command layout: Capsulenv could not guard its nested Scoop install.'
    }
    $source = $rewritten
    $changed = $true
}
if (-not $changed) {
    throw "Capsulenv intercepted Scoop $command but did not apply a ShellOnly policy transformation."
}

$tempName = '.capsulenv-{0}-{1}-{2}.ps1' -f $command, $PID, [Guid]::NewGuid().ToString('N').Substring(0, 8)
$tempPath = Join-Path (Split-Path -Parent $libexec) $tempName
$tail = @($Arguments | Select-Object -Skip 1)
$code = 1
try {
    [System.IO.File]::WriteAllText($tempPath, $source, [System.Text.UTF8Encoding]::new($false))
    Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    if ($MyInvocation.ExpectingInput) {
        $input | & $tempPath @tail
    } else {
        & $tempPath @tail
    }
    $ok = $?
    $code = Get-CapsulenvGatewayExitCode -Succeeded $ok
} finally {
    Remove-CapsulenvGatewayTemporaryScript -ScoopRoot $scoopRoot -FileName $tempName -OriginalPath $tempPath
    # `scoop update` recreates its own shim. Reassert the capsule gateway after
    # every intercepted command so a nested update cannot leave a raw Scoop shim.
    Write-CapsulenvScoopGatewayShims -ScoopRoot $scoopRoot
}
exit $code
