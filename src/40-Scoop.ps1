function Get-CapsulenvScoopRoot {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    return Resolve-CapsulenvPath -Path $configuration.Scoop.Root -AllowMissing
}


function Get-CapsulenvScoopGlobalRoot {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    return Resolve-CapsulenvPath -Path $configuration.Scoop.GlobalRoot -AllowMissing
}

function Get-CapsulenvScoopExecutable {
    [CmdletBinding()]
    param()

    $scoopRoot = Get-CapsulenvScoopRoot
    $shimsRoot = Join-Path $scoopRoot 'shims'
    $scoopAppRoot = Join-Path (Join-Path (Join-Path $scoopRoot 'apps') 'scoop') 'current'
    foreach ($candidate in @(
        (Join-Path $shimsRoot 'scoop.ps1'),
        (Join-Path (Join-Path $scoopAppRoot 'bin') 'scoop.ps1')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    return $null
}

function Invoke-CapsulenvScoopCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $scoop = Get-CapsulenvScoopExecutable
    if (-not $scoop) {
        throw 'Scoop is not installed in the configured portable root.'
    }

    & $scoop @Arguments
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "scoop $($Arguments -join ' ') failed with exit code $exitCode"
    }
    return $exitCode
}

function Reset-CapsulenvScoop {
    [CmdletBinding()]
    param(
        [string[]]$Apps = @('*'),
        [switch]$Quiet
    )

    if (-not $Quiet) {
        Write-CapsulenvMessage -Level Info -Message 'Rebuilding Scoop current links, shims, shortcuts, environment entries, and persist links...'
    }
    $arguments = @('reset') + @($Apps)
    [void](Invoke-CapsulenvScoopCommand -Arguments $arguments)
    return $true
}

function Get-CapsulenvScoopReplayScriptPath {
    [CmdletBinding()]
    param()

    $context = Get-CapsulenvContext
    return Join-Path (Join-Path $context.Root 'scripts') 'scoop-capsulenv-replay.ps1'
}

function Install-CapsulenvScoopReplayCommand {
    [CmdletBinding()]
    param()

    $source = Get-CapsulenvScoopReplayScriptPath
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Missing Scoop lifecycle runner: $source"
    }
    if (-not (Get-CapsulenvScoopExecutable)) {
        throw 'Scoop is not installed in the configured portable root.'
    }

    $shims = Join-Path (Get-CapsulenvScoopRoot) 'shims'
    [void](New-Item -ItemType Directory -Path $shims -Force)
    $suffix = ('{0}-{1}' -f $PID, ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
    $commandName = "capsulenv-replay-$suffix"
    $target = Join-Path $shims ("scoop-{0}.ps1" -f $commandName)
    Copy-Item -LiteralPath $source -Destination $target -ErrorAction Stop
    return [pscustomobject]@{
        Command = $commandName
        Path = $target
    }
}

function Invoke-CapsulenvScoopHookReplay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('pre_install', 'post_install')]
        [string]$Hook,
        [Parameter(Mandatory = $true)][string[]]$Apps
    )

    if ($Apps.Count -eq 0) {
        return
    }

    [void](Set-CapsulenvSessionEnvironment)
    $temporaryCommand = Install-CapsulenvScoopReplayCommand
    try {
        $arguments = @($temporaryCommand.Command, '-Hook', $Hook) + @($Apps)
        [void](Invoke-CapsulenvScoopCommand -Arguments $arguments)
    } finally {
        if (Test-Path -LiteralPath $temporaryCommand.Path -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryCommand.Path -Force
        }
    }
}

function Invoke-CapsulenvConfiguredHookReplay {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    $groups = @{
        pre_install = New-Object System.Collections.Generic.List[string]
        post_install = New-Object System.Collections.Generic.List[string]
    }

    foreach ($app in ($configuration.Scoop.ReplayHooks.Keys | Sort-Object)) {
        foreach ($hook in @($configuration.Scoop.ReplayHooks[$app])) {
            $hookName = [string]$hook
            $groups[$hookName].Add([string]$app)
        }
    }

    foreach ($hook in @('pre_install', 'post_install')) {
        if ($groups[$hook].Count -gt 0) {
            Invoke-CapsulenvScoopHookReplay -Hook $hook -Apps @($groups[$hook])
        }
    }
}

function Get-CapsulenvRehydrationStatePath {
    [CmdletBinding()]
    param()

    $context = Get-CapsulenvContext
    return Join-Path $context.StateRoot 'scoop-rehydration.json'
}

function Get-CapsulenvRelocationFingerprint {
    [CmdletBinding()]
    param()

    $context = Get-CapsulenvContext
    [ordered]@{
        Root = $context.Root
        ScoopRoot = (Get-CapsulenvScoopRoot)
        ScoopGlobalRoot = (Get-CapsulenvScoopGlobalRoot)
        ComputerName = [Environment]::MachineName
        User = ('{0}\{1}' -f [Environment]::UserDomainName, [Environment]::UserName)
    }
}

function Test-CapsulenvScoopRehydrationRequired {
    [CmdletBinding()]
    param()

    $statePath = Get-CapsulenvRehydrationStatePath
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $true
    }

    try {
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    } catch {
        return $true
    }
    $current = Get-CapsulenvRelocationFingerprint
    foreach ($name in @('Root', 'ScoopRoot', 'ScoopGlobalRoot', 'ComputerName', 'User')) {
        $property = $saved.PSObject.Properties[$name]
        if ($null -eq $property -or [string]$property.Value -ne [string]$current[$name]) {
            return $true
        }
    }
    return $false
}

function Save-CapsulenvRehydrationState {
    [CmdletBinding()]
    param()

    $statePath = Get-CapsulenvRehydrationStatePath
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force)
    $state = Get-CapsulenvRelocationFingerprint
    $state['CompletedAtUtc'] = [DateTime]::UtcNow.ToString('o')
    $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding UTF8
}

function Invoke-CapsulenvScoopRehydrate {
    [CmdletBinding()]
    param([switch]$SkipHooks)

    [void](Set-CapsulenvSessionEnvironment)
    [void](Reset-CapsulenvScoop)
    if (-not $SkipHooks) {
        Invoke-CapsulenvConfiguredHookReplay
    }
    Save-CapsulenvRehydrationState
    Write-CapsulenvMessage -Level Success -Message 'Portable Scoop rehydration completed.'
}

function Find-CapsulenvExecutable {
    [CmdletBinding()]
    param(
        [string[]]$Candidates,
        [string[]]$CommandNames
    )

    foreach ($candidate in $Candidates) {
        $resolved = Resolve-CapsulenvPath -Path $candidate -AllowMissing
        if (Test-Path -LiteralPath $resolved -PathType Leaf) {
            return $resolved
        }
    }
    $portableRoots = @(
        [System.IO.Path]::GetFullPath((Get-CapsulenvScoopRoot)).TrimEnd('\', '/'),
        [System.IO.Path]::GetFullPath((Get-CapsulenvScoopGlobalRoot)).TrimEnd('\', '/')
    )
    foreach ($name in $CommandNames) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue
        if (-not $command) {
            continue
        }
        $source = [System.IO.Path]::GetFullPath([string]$command.Source)
        $separator = [System.IO.Path]::DirectorySeparatorChar
        foreach ($portableRoot in $portableRoots) {
            $rootPrefix = $portableRoot + $separator
            if ($source.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $source
            }
        }
    }
    return $null
}

##MOD_EXEC## Export-ModuleMember -Function Reset-CapsulenvScoop, Invoke-CapsulenvScoopRehydrate, Invoke-CapsulenvScoopHookReplay, Test-CapsulenvScoopRehydrationRequired
