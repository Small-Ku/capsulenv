function Get-CapsulenvIdentityPath {
    [CmdletBinding()]
    param()

    $context = Get-CapsulenvContext
    return Join-Path $context.StateRoot 'identity.json'
}

function Write-CapsulenvIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Guid]$Id)

    $path = Get-CapsulenvIdentityPath
    $parent = Split-Path -Parent $path
    [void](New-Item -ItemType Directory -Path $parent -Force)
    $temporary = Join-Path $parent ('.identity-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        [ordered]@{
            SchemaVersion = 1
            Id = $Id.ToString('D')
            CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $temporary -Encoding UTF8
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                [System.IO.File]::Replace($temporary, $path, $null, $true)
            } catch {
                Remove-Item -LiteralPath $path -Force
                Move-Item -LiteralPath $temporary -Destination $path
            }
        } else {
            Move-Item -LiteralPath $temporary -Destination $path
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-CapsulenvIdentity {
    [CmdletBinding()]
    param()

    $path = Get-CapsulenvIdentityPath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $id = [Guid]::Empty
            if (
                [int]$state.SchemaVersion -eq 1 -and
                [Guid]::TryParse([string]$state.Id, [ref]$id) -and
                $id -ne [Guid]::Empty
            ) {
                return $id.ToString('D')
            }
        } catch {
            Write-CapsulenvMessage -Level Warning -Message "Replacing invalid capsule identity: $path"
        }
    }

    $newId = [Guid]::NewGuid()
    Write-CapsulenvIdentity -Id $newId
    return $newId.ToString('D')
}

function ConvertTo-CapsulenvStatePathReference {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $context = Get-CapsulenvContext
    $root = [System.IO.Path]::GetFullPath($context.Root).TrimEnd([char[]]'\/')
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\/')
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($root, $fullPath)) {
        return 'capsule://.'
    }
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if ($fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $fullPath.Substring($prefix.Length).Replace('\', '/')
        return 'capsule://' + $relative
    }
    return 'absolute://' + $fullPath
}

function Resolve-CapsulenvStatePathReference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Reference,
        [string]$CapsuleRoot
    )

    if ($Reference.StartsWith('capsule://', [System.StringComparison]::OrdinalIgnoreCase)) {
        if ([string]::IsNullOrWhiteSpace($CapsuleRoot)) {
            $CapsuleRoot = (Get-CapsulenvContext).Root
        }
        $relative = $Reference.Substring('capsule://'.Length)
        if ($relative -eq '.' -or [string]::IsNullOrWhiteSpace($relative)) {
            return [System.IO.Path]::GetFullPath($CapsuleRoot)
        }
        $relative = $relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        return [System.IO.Path]::GetFullPath((Join-Path $CapsuleRoot $relative))
    }
    if ($Reference.StartsWith('absolute://', [System.StringComparison]::OrdinalIgnoreCase)) {
        return [System.IO.Path]::GetFullPath($Reference.Substring('absolute://'.Length))
    }
    # Schema v2 install-mode state stored absolute paths directly.
    return [System.IO.Path]::GetFullPath($Reference)
}


function Get-CapsulenvHostIntegrationKey {
    [CmdletBinding()]
    param()

    $identityText = ('{0}|{1}\{2}' -f [Environment]::MachineName, [Environment]::UserDomainName, [Environment]::UserName).ToLowerInvariant()
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($identityText)
        $hash = $sha256.ComputeHash($bytes)
    } finally {
        $sha256.Dispose()
    }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 24)
}

function Get-CapsulenvUserIntegrationStateRoot {
    [CmdletBinding()]
    param()

    $context = Get-CapsulenvContext
    return Join-Path (Join-Path $context.StateRoot 'user-integrations') (Get-CapsulenvHostIntegrationKey)
}


function Test-CapsulenvCurrentUserIntegrationOwnership {
    [CmdletBinding()]
    param()

    if (-not (Test-CapsulenvWindows)) {
        return $false
    }

    try {
        $userScoop = [Environment]::GetEnvironmentVariable('SCOOP', 'User')
        $userGlobal = [Environment]::GetEnvironmentVariable('SCOOP_GLOBAL', 'User')
    } catch {
        return $false
    }
    if (
        [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$userScoop, [string](Get-CapsulenvScoopRoot)) -and
        [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$userGlobal, [string](Get-CapsulenvScoopGlobalRoot))
    ) {
        return $true
    }

    # A drive-letter move leaves the User environment pointing at the previous
    # roots until rehydrate runs. The relocation fingerprint proves ownership
    # only when it belongs to this same machine/user and capsule identity.
    try {
        $previous = Get-CapsulenvPreviousRelocationFingerprint
    } catch {
        return $false
    }
    if ($null -eq $previous -or $previous -isnot [System.Collections.IDictionary]) {
        return $false
    }
    foreach ($requiredName in @('ComputerName', 'User', 'ScoopRoot', 'ScoopGlobalRoot')) {
        if (-not $previous.Contains($requiredName)) {
            return $false
        }
    }
    $currentUser = ('{0}\\{1}' -f [Environment]::UserDomainName, [Environment]::UserName)
    $previousComputer = [string]$previous['ComputerName']
    $previousUser = [string]$previous['User']
    $previousScoop = [string]$previous['ScoopRoot']
    $previousGlobal = [string]$previous['ScoopGlobalRoot']
    return (
        [System.StringComparer]::OrdinalIgnoreCase.Equals($previousComputer, [Environment]::MachineName) -and
        [System.StringComparer]::OrdinalIgnoreCase.Equals($previousUser, $currentUser) -and
        -not [string]::IsNullOrWhiteSpace($previousScoop) -and
        -not [string]::IsNullOrWhiteSpace($previousGlobal) -and
        [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$userScoop, $previousScoop) -and
        [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$userGlobal, $previousGlobal)
    )
}

function Move-CapsulenvLegacyUserIntegrationState {
    [CmdletBinding()]
    param()

    if (-not (Test-CapsulenvCurrentUserIntegrationOwnership)) {
        return
    }

    $context = Get-CapsulenvContext
    $hostRoot = Join-Path (Join-Path $context.StateRoot 'user-integrations') (Get-CapsulenvHostIntegrationKey)
    $mappings = @(
        @{ Legacy = (Join-Path $context.StateRoot 'user-environment-backup.json'); Current = (Join-Path $hostRoot 'environment-backup.json') },
        @{ Legacy = (Join-Path $context.StateRoot 'install-mode.json'); Current = (Join-Path $hostRoot 'install-mode.json') }
    )
    foreach ($mapping in $mappings) {
        if (
            (Test-Path -LiteralPath $mapping.Legacy -PathType Leaf) -and
            -not (Test-Path -LiteralPath $mapping.Current -PathType Leaf)
        ) {
            [void](New-Item -ItemType Directory -Path $hostRoot -Force)
            Move-Item -LiteralPath $mapping.Legacy -Destination $mapping.Current
        }
    }
}

function Get-CapsulenvScratchPath {
    [CmdletBinding()]
    param()

    $temporaryRoot = [Environment]::GetEnvironmentVariable('TEMP', 'Process')
    if ([string]::IsNullOrWhiteSpace($temporaryRoot)) {
        $temporaryRoot = [System.IO.Path]::GetTempPath()
    }
    return [System.IO.Path]::GetFullPath(
        (Join-Path (Join-Path $temporaryRoot 'capsulenv') (Get-CapsulenvIdentity))
    )
}

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvIdentity, Get-CapsulenvScratchPath
