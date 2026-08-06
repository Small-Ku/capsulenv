function Get-CapsulenvScoopRoot {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    return Resolve-CapsulenvPath -Path $configuration.Scoop.Root -AllowMissing
}

function Get-CapsulenvScoopExecutable {
    [CmdletBinding()]
    param()

    $scoopRoot = Get-CapsulenvScoopRoot
    foreach ($candidate in @(
        (Join-Path $scoopRoot 'shims\scoop.ps1'),
        (Join-Path $scoopRoot 'apps\scoop\current\bin\scoop.ps1')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    $command = Get-Command scoop -CommandType Application, ExternalScript -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    return $null
}

function Reset-CapsulenvScoopShims {
    [CmdletBinding()]
    param([switch]$Quiet)

    $scoop = Get-CapsulenvScoopExecutable
    if (-not $scoop) {
        if (-not $Quiet) {
            Write-CapsulenvMessage -Level Warning -Message 'Scoop is not installed in the configured portable root.'
        }
        return $false
    }

    if (-not $Quiet) {
        Write-CapsulenvMessage -Level Info -Message 'Rebuilding portable Scoop shims...'
    }
    & $scoop reset '*'
    if ($LASTEXITCODE -ne 0) {
        throw "scoop reset failed with exit code $LASTEXITCODE"
    }
    return $true
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
    foreach ($name in $CommandNames) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }
    return $null
}

##MOD_EXEC## Export-ModuleMember -Function Reset-CapsulenvScoopShims
