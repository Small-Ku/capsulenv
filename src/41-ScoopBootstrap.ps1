function Get-CapsulenvScoopBootstrapConfiguration {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    return $configuration.Scoop.Bootstrap
}

function Get-CapsulenvGitExecutable {
    [CmdletBinding()]
    param()

    $scoopRoot = Get-CapsulenvScoopRoot
    foreach ($candidate in @(
        (Join-Path (Join-Path (Join-Path (Join-Path $scoopRoot 'apps') 'git') 'current') 'cmd\git.exe'),
        (Join-Path (Join-Path $scoopRoot 'shims') 'git.exe'),
        (Join-Path (Join-Path $scoopRoot 'shims') 'git.cmd')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    foreach ($commandName in @('git.exe', 'git')) {
        $command = Get-Command $commandName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            return [string]$command.Source
        }
    }
    return $null
}

function Ensure-CapsulenvScoopPortableConfig {
    [CmdletBinding()]
    param()

    $scoopRoot = Get-CapsulenvScoopRoot
    [void](New-Item -ItemType Directory -Path $scoopRoot -Force)
    $configPath = Join-Path $scoopRoot 'config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        [System.IO.File]::WriteAllText($configPath, '{}', [System.Text.UTF8Encoding]::new($false))
    }
    return $configPath
}

function Invoke-CapsulenvGit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Git,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    Clear-CapsulenvLastExitCode
    & $Git @Arguments
    $succeeded = $?
    $exitCode = Get-CapsulenvLastExitCode -Succeeded $succeeded
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "git $($Arguments -join ' ') failed with exit code $exitCode"
    }
    return $exitCode
}

function Copy-CapsulenvArchiveSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$RequiredPath
    )

    $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-archive-{0}' -f [Guid]::NewGuid().ToString('N'))
    $archivePath = Join-Path $temporaryRoot 'source.zip'
    $extractRoot = Join-Path $temporaryRoot 'extract'
    try {
        [void](New-Item -ItemType Directory -Path $temporaryRoot -Force)
        if (Test-Path -LiteralPath $Archive -PathType Leaf) {
            Copy-Item -LiteralPath $Archive -Destination $archivePath -Force
        } else {
            $webRequestParameters = @{
                Uri = $Archive
                OutFile = $archivePath
                ErrorAction = 'Stop'
            }
            if ($PSVersionTable.PSVersion.Major -le 5) {
                $webRequestParameters['UseBasicParsing'] = $true
            }
            Invoke-WebRequest @webRequestParameters
        }

        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force
        $sourceRoot = $null
        foreach ($candidate in @($extractRoot) + @(Get-ChildItem -LiteralPath $extractRoot -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
            if (Test-Path -LiteralPath (Join-Path $candidate $RequiredPath)) {
                $sourceRoot = $candidate
                break
            }
        }
        if ($null -eq $sourceRoot) {
            throw "Downloaded archive does not contain required path '$RequiredPath': $Archive"
        }

        if (Test-Path -LiteralPath $Destination) {
            Remove-Item -LiteralPath $Destination -Recurse -Force
        }
        [void](New-Item -ItemType Directory -Path $Destination -Force)
        Get-ChildItem -LiteralPath $sourceRoot -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryRoot) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Repair-CapsulenvBootstrapGitRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Git,
        [Parameter(Mandatory = $true)][hashtable]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$RequiredPath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $gitMetadata = Join-Path $Destination '.git'
    if (-not (Test-Path -LiteralPath $gitMetadata)) {
        return $false
    }

    $depth = [int](Get-CapsulenvScoopBootstrapConfiguration).GitDepth
    Write-CapsulenvMessage -Level Warning -Message "$Name repository is incomplete; repairing it with a shallow Git fetch."
    $fetchExitCode = Invoke-CapsulenvGit -Git $Git -Arguments @(
        '-C', $Destination, 'fetch', '--quiet', '--depth', [string]$depth, '--force',
        'origin', [string]$Source.Branch
    ) -AllowFailure
    if ($fetchExitCode -ne 0) {
        return $false
    }
    $resetExitCode = Invoke-CapsulenvGit -Git $Git -Arguments @(
        '-C', $Destination, 'reset', '--hard', '--quiet', 'FETCH_HEAD'
    ) -AllowFailure
    if ($resetExitCode -ne 0) {
        return $false
    }
    return (Test-Path -LiteralPath (Join-Path $Destination $RequiredPath))
}

function Install-CapsulenvBootstrapRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$RequiredPath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $parent = Split-Path -Parent $Destination
    [void](New-Item -ItemType Directory -Path $parent -Force)
    $temporaryDestination = Join-Path $parent ('.capsulenv-bootstrap-{0}-{1}' -f $Name.ToLowerInvariant(), [Guid]::NewGuid().ToString('N'))
    $git = Get-CapsulenvGitExecutable
    $transport = 'archive'

    if (
        $git -and
        (Test-Path -LiteralPath $Destination -PathType Container) -and
        (Repair-CapsulenvBootstrapGitRepository `
            -Git $git `
            -Source $Source `
            -Destination $Destination `
            -RequiredPath $RequiredPath `
            -Name $Name)
    ) {
        return 'git-fetch'
    }

    try {
        if ($git) {
            $depth = [int](Get-CapsulenvScoopBootstrapConfiguration).GitDepth
            $cloneArguments = @(
                'clone', '--quiet', '--depth', [string]$depth, '--single-branch',
                '--branch', [string]$Source.Branch, [string]$Source.Repository, $temporaryDestination
            )
            $cloneExitCode = Invoke-CapsulenvGit -Git $git -Arguments $cloneArguments -AllowFailure
            if ($cloneExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $temporaryDestination $RequiredPath))) {
                $transport = 'git'
            } else {
                if (Test-Path -LiteralPath $temporaryDestination) {
                    Remove-Item -LiteralPath $temporaryDestination -Recurse -Force -ErrorAction SilentlyContinue
                }
                Write-CapsulenvMessage -Level Warning -Message "Shallow Git bootstrap failed for $Name; falling back to archive download."
            }
        }

        if ($transport -eq 'archive') {
            Copy-CapsulenvArchiveSource `
                -Archive ([string]$Source.Archive) `
                -Destination $temporaryDestination `
                -RequiredPath $RequiredPath
        }

        if (-not (Test-Path -LiteralPath (Join-Path $temporaryDestination $RequiredPath))) {
            throw "$Name bootstrap did not produce required path '$RequiredPath'."
        }
        if (Test-Path -LiteralPath $Destination) {
            if ($null -ne (Get-ChildItem -LiteralPath $Destination -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                throw "$Name bootstrap destination exists but is incomplete: $Destination"
            }
            Remove-Item -LiteralPath $Destination -Recurse -Force
        }
        Move-Item -LiteralPath $temporaryDestination -Destination $Destination
        return $transport
    } finally {
        if (Test-Path -LiteralPath $temporaryDestination) {
            Remove-Item -LiteralPath $temporaryDestination -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-CapsulenvScoopShim {
    [CmdletBinding()]
    param()

    $scoopRoot = Get-CapsulenvScoopRoot
    $shimsRoot = Join-Path $scoopRoot 'shims'
    [void](New-Item -ItemType Directory -Path $shimsRoot -Force)

    $gatewayPath = Get-CapsulenvModuleRuntimePath -Name 'scoop-capsulenv-gateway.ps1'
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
    if (-not (Test-Path -LiteralPath $ps1Path -PathType Leaf) -or [System.IO.File]::ReadAllText($ps1Path) -ne $ps1Text) {
        [System.IO.File]::WriteAllText($ps1Path, $ps1Text, [System.Text.UTF8Encoding]::new($false))
    }

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
    if (-not (Test-Path -LiteralPath $cmdPath -PathType Leaf) -or [System.IO.File]::ReadAllText($cmdPath) -ne $cmdText) {
        [System.IO.File]::WriteAllText($cmdPath, $cmdText, [System.Text.UTF8Encoding]::new($false))
    }

    return $ps1Path
}

function Initialize-CapsulenvScoopBootstrap {
    [CmdletBinding()]
    param()

    $bootstrap = Get-CapsulenvScoopBootstrapConfiguration
    if (-not $bootstrap.Enabled) {
        return [pscustomobject]@{
            Enabled = $false
            ScoopInstalled = [bool](Get-CapsulenvScoopExecutable)
            MainInstalled = $false
            ScoopTransport = $null
            MainTransport = $null
        }
    }

    [void](Ensure-CapsulenvScoopPortableConfig)
    $scoopRoot = Get-CapsulenvScoopRoot
    $scoopCurrent = Join-Path (Join-Path (Join-Path $scoopRoot 'apps') 'scoop') 'current'
    $mainRoot = Join-Path (Join-Path $scoopRoot 'buckets') 'main'
    $scoopTransport = $null
    $mainTransport = $null

    if (-not (Test-Path -LiteralPath (Join-Path $scoopCurrent 'bin\scoop.ps1') -PathType Leaf)) {
        $scoopTransport = Install-CapsulenvBootstrapRepository `
            -Source $bootstrap.Scoop `
            -Destination $scoopCurrent `
            -RequiredPath 'bin\scoop.ps1' `
            -Name 'Scoop'
    }

    [void](Install-CapsulenvScoopShim)

    if (-not (Test-Path -LiteralPath (Join-Path $mainRoot 'bucket') -PathType Container)) {
        $mainTransport = Install-CapsulenvBootstrapRepository `
            -Source $bootstrap.Main `
            -Destination $mainRoot `
            -RequiredPath 'bucket' `
            -Name 'Main'
    }

    return [pscustomobject]@{
        Enabled = $true
        ScoopInstalled = $true
        MainInstalled = $true
        ScoopTransport = $scoopTransport
        MainTransport = $mainTransport
    }
}

##MOD_EXEC## Export-ModuleMember -Function Initialize-CapsulenvScoopBootstrap, Ensure-CapsulenvScoopPortableConfig
