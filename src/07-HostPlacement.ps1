$script:CapsulenvUnavailableBootEpoch = $null

function Get-CapsulenvHostIdentityEvidence {
    [CmdletBinding()]
    param()

    $machineUser = ('{0}|{1}\{2}' -f [Environment]::MachineName, [Environment]::UserDomainName, [Environment]::UserName).ToLowerInvariant()
    $gdid = $null
    if (Test-CapsulenvWindows) {
        try {
            $properties = Get-ItemProperty `
                -LiteralPath 'Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\IdentityCRL\ExtendedProperties' `
                -Name LID `
                -ErrorAction Stop
            try {
                $gdid = [UInt64]::Parse(
                    [string]$properties.LID,
                    [Globalization.NumberStyles]::Integer,
                    [Globalization.CultureInfo]::InvariantCulture
                ).ToString([Globalization.CultureInfo]::InvariantCulture)
            } catch {
                $gdid = $null
            }
        } catch {
            $gdid = $null
        }
    }

    return [pscustomobject][ordered]@{
        MachineUser = [pscustomobject][ordered]@{
            Available = $true
            Strength = 'fallback'
            Value = $machineUser
        }
        WindowsGdid = [pscustomobject][ordered]@{
            Available = (-not [string]::IsNullOrWhiteSpace([string]$gdid))
            Strength = 'strong'
            Value = $gdid
            Source = 'HKCU\\SOFTWARE\\Microsoft\\IdentityCRL\\ExtendedProperties\\LID'
        }
    }
}

function Get-CapsulenvHostIdentityDigest {
    [CmdletBinding()]
    param()

    $evidence = Get-CapsulenvHostIdentityEvidence
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add(('machine-user={0}' -f [string]$evidence.MachineUser.Value))
    if ([bool]$evidence.WindowsGdid.Available) {
        $parts.Add(('windows-gdid={0}' -f [string]$evidence.WindowsGdid.Value))
    }
    $canonical = "capsulenv-host-identity-v1`n" + ($parts -join "`n")
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical)
        $hash = $sha256.ComputeHash($bytes)
    } finally {
        $sha256.Dispose()
    }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 24)
}

function Get-CapsulenvHostKey {
    [CmdletBinding()]
    param()

    $override = [Environment]::GetEnvironmentVariable('CAPSULENV_HOST_KEY', 'Process')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $key = $override.Trim().ToLowerInvariant()
        if ($key -notmatch '^[a-z0-9][a-z0-9._-]*$') {
            throw 'CAPSULENV_HOST_KEY must be a safe path segment.'
        }
        return $key
    }

    return 'host-{0}' -f (Get-CapsulenvHostIntegrationKey)
}

function Get-CapsulenvHostLocalStateRoot {
    [CmdletBinding()]
    param()

    $override = [Environment]::GetEnvironmentVariable('CAPSULENV_HOST_STATE_ROOT', 'Process')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        return [System.IO.Path]::GetFullPath($override)
    }

    $base = [Environment]::GetEnvironmentVariable('LOCALAPPDATA', 'Process')
    if ([string]::IsNullOrWhiteSpace($base) -and (Test-CapsulenvWindows)) {
        $base = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    }
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = [Environment]::GetEnvironmentVariable('XDG_STATE_HOME', 'Process')
    }
    if ([string]::IsNullOrWhiteSpace($base)) {
        $home = [Environment]::GetEnvironmentVariable('HOME', 'Process')
        if (-not [string]::IsNullOrWhiteSpace($home)) {
            $base = Join-Path $home '.local/state'
        }
    }
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = [System.IO.Path]::GetTempPath()
    }

    return [System.IO.Path]::GetFullPath((Join-Path $base 'Capsulenv'))
}

function Get-CapsulenvHostRecordPath {
    [CmdletBinding()]
    param()

    return Join-Path (Join-Path (Get-CapsulenvHostLocalStateRoot) 'hosts') (
        '{0}.json' -f (Get-CapsulenvHostKey)
    )
}

function Get-CapsulenvHostBootEpoch {
    [CmdletBinding()]
    param()

    $override = [Environment]::GetEnvironmentVariable('CAPSULENV_HOST_BOOT_EPOCH', 'Process')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $epoch = $override.Trim()
        if ($epoch -notmatch '^[A-Za-z0-9._-]+$') {
            throw 'CAPSULENV_HOST_BOOT_EPOCH must be a safe path segment.'
        }
        return $epoch
    }

    if ($null -ne $script:CapsulenvUnavailableBootEpoch) {
        return $script:CapsulenvUnavailableBootEpoch
    }

    if (-not (Test-CapsulenvWindows)) {
        $bootIdPath = '/proc/sys/kernel/random/boot_id'
        if (Test-Path -LiteralPath $bootIdPath -PathType Leaf) {
            try {
                $bootId = [System.IO.File]::ReadAllText($bootIdPath).Trim()
                if (-not [string]::IsNullOrWhiteSpace($bootId)) {
                    return $bootId
                }
            } catch {}
        }
    } else {
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $rawLastBoot = $os.LastBootUpTime
            if ($rawLastBoot -is [DateTime]) {
                $lastBoot = [DateTime]$rawLastBoot
            } elseif ($rawLastBoot -is [DateTimeOffset]) {
                $lastBoot = ([DateTimeOffset]$rawLastBoot).UtcDateTime
            } else {
                $lastBoot = [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$rawLastBoot)
            }
            return $lastBoot.ToUniversalTime().ToString(
                'yyyyMMddTHHmmssfffffffZ',
                [Globalization.CultureInfo]::InvariantCulture
            )
        } catch {}
    }

    # Reusing an unknown ephemeral depot across a reboot is unsafe. A unique
    # fallback therefore trades reuse for correctness only on hosts where the
    # platform boot identity is unavailable.
    $script:CapsulenvUnavailableBootEpoch = 'unavailable-{0}' -f [Guid]::NewGuid().ToString('N')
    return $script:CapsulenvUnavailableBootEpoch
}

function Write-CapsulenvHostJsonAtomically {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $parent = Split-Path -Parent $Path
    [void](New-Item -ItemType Directory -Path $parent -Force)
    $temporary = Join-Path $parent ('.{0}.{1}.tmp' -f (Split-Path -Leaf $Path), [Guid]::NewGuid().ToString('N'))
    try {
        $encoding = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText(
            $temporary,
            ($Value | ConvertTo-Json -Depth 8),
            $encoding
        )
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $backupPath = '{0}.backup-{1}' -f $Path, [Guid]::NewGuid().ToString('N')
            try {
                [System.IO.File]::Replace($temporary, $Path, $backupPath, $true)
                if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                    Remove-Item -LiteralPath $backupPath -Force
                }
            } catch {
                throw "Could not atomically publish host state '$Path'; the previous valid file was retained. $($_.Exception.Message)"
            }
        } else {
            Move-Item -LiteralPath $temporary -Destination $Path
        }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Assert-CapsulenvHostPlacementRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PlacementRoot)

    if (-not [System.IO.Path]::IsPathRooted($PlacementRoot)) {
        throw 'Host placement root must be an absolute host-local path.'
    }
    $candidate = [System.IO.Path]::GetFullPath($PlacementRoot).TrimEnd([char[]]'\\/')
    $capsuleRoot = [System.IO.Path]::GetFullPath((Get-CapsulenvContext).Root).TrimEnd([char[]]'\\/')
    $comparison = if (Test-CapsulenvWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    $prefix = $capsuleRoot + [System.IO.Path]::DirectorySeparatorChar
    $equal = if (Test-CapsulenvWindows) {
        [System.StringComparer]::OrdinalIgnoreCase.Equals($candidate, $capsuleRoot)
    } else {
        [System.StringComparer]::Ordinal.Equals($candidate, $capsuleRoot)
    }
    if ($equal -or $candidate.StartsWith($prefix, $comparison)) {
        throw "Host placement root must not equal or descend from the portable capsule root: $candidate"
    }
    return $candidate
}

function Get-CapsulenvDefaultHostRecord {
    [CmdletBinding()]
    param()

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        HostKey = Get-CapsulenvHostKey
        Tag = $null
        Enrolled = $false
        Retention = 'ephemeral'
        PlacementRoot = $null
        UpdatedAtUtc = $null
    }
}

function Get-CapsulenvHostRecord {
    [CmdletBinding()]
    param()

    $default = Get-CapsulenvDefaultHostRecord
    $path = Get-CapsulenvHostRecordPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $default
    }

    try {
        $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if (
            [int]$record.SchemaVersion -ne 1 -or
            [string]$record.HostKey -ne [string]$default.HostKey -or
            [string]$record.Retention -notin @('ephemeral', 'persistent') -or
            [bool]$record.Enrolled -ne $true
        ) {
            return $default
        }

        $placementRoot = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$record.PlacementRoot)) {
            $placementRoot = [System.IO.Path]::GetFullPath([string]$record.PlacementRoot)
        }
        return [pscustomobject][ordered]@{
            SchemaVersion = 1
            HostKey = [string]$record.HostKey
            Tag = [string]$record.Tag
            Enrolled = $true
            Retention = [string]$record.Retention
            PlacementRoot = $placementRoot
            UpdatedAtUtc = [string]$record.UpdatedAtUtc
        }
    } catch {
        # A stale/corrupt host-local record is not portable authority.
        return $default
    }
}

function Set-CapsulenvHostEnrollment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$EnrollmentTag,
        [ValidateSet('ephemeral', 'persistent')][string]$Retention = 'persistent',
        [string]$PlacementRoot
    )

    $resolvedPlacementRoot = $null
    if (-not [string]::IsNullOrWhiteSpace($PlacementRoot)) {
        $resolvedPlacementRoot = Assert-CapsulenvHostPlacementRoot -PlacementRoot $PlacementRoot
    }

    $record = [pscustomobject][ordered]@{
        SchemaVersion = 1
        HostKey = Get-CapsulenvHostKey
        Tag = $EnrollmentTag.Trim()
        Enrolled = $true
        Retention = $Retention
        PlacementRoot = $resolvedPlacementRoot
        UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-CapsulenvHostJsonAtomically -Path (Get-CapsulenvHostRecordPath) -Value $record
    return $record
}

function Get-CapsulenvHostPlacement {
    [CmdletBinding()]
    param([string]$CapsuleId)

    if ([string]::IsNullOrWhiteSpace($CapsuleId)) {
        $CapsuleId = Get-CapsulenvIdentity
    }
    $CapsuleId = $CapsuleId.Trim()
    if ($CapsuleId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Invalid capsule identity for host placement: $CapsuleId"
    }

    $hostKey = Get-CapsulenvHostKey
    $bootEpoch = Get-CapsulenvHostBootEpoch
    $record = Get-CapsulenvHostRecord
    $localRoot = Get-CapsulenvHostLocalStateRoot
    if ([string]$record.Retention -eq 'persistent') {
        $depotRoot = if (-not [string]::IsNullOrWhiteSpace([string]$record.PlacementRoot)) {
            Assert-CapsulenvHostPlacementRoot -PlacementRoot ([string]$record.PlacementRoot)
        } else {
            Join-Path $localRoot 'depots'
        }
        $root = Join-Path (Join-Path $depotRoot 'capsules') $CapsuleId
    } else {
        $root = Join-Path (
            Join-Path (Join-Path (Join-Path $localRoot 'ephemeral') $hostKey) $bootEpoch
        ) $CapsuleId
    }
    $root = [System.IO.Path]::GetFullPath($root)

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        CapsuleId = $CapsuleId
        HostKey = $hostKey
        Tag = $record.Tag
        Enrolled = [bool]$record.Enrolled
        Retention = [string]$record.Retention
        BootEpoch = $bootEpoch
        Root = $root
        PackagesRoot = Join-Path $root 'packages'
        GenerationsRoot = Join-Path $root 'generations'
        ModulesRoot = Join-Path $root 'modules'
        StateRoot = Join-Path $root 'state/host'
        CacheRoot = Join-Path $root 'cache'
        ScratchRoot = Join-Path $root 'scratch'
        MarkerPath = Join-Path $root 'host-placement.json'
        Materialized = Test-Path -LiteralPath $root -PathType Container
        Valid = Test-CapsulenvHostPlacement -PlacementRoot $root -CapsuleId $CapsuleId -HostKey $hostKey -Retention ([string]$record.Retention) -BootEpoch $bootEpoch
    }
}

function Test-CapsulenvHostPlacement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PlacementRoot,
        [Parameter(Mandatory = $true)][string]$CapsuleId,
        [Parameter(Mandatory = $true)][string]$HostKey,
        [Parameter(Mandatory = $true)][ValidateSet('ephemeral', 'persistent')][string]$Retention,
        [Parameter(Mandatory = $true)][string]$BootEpoch
    )

    $markerPath = Join-Path $PlacementRoot 'host-placement.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        return $false
    }
    try {
        $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        return (
            [int]$marker.SchemaVersion -eq 1 -and
            [string]$marker.CapsuleId -eq $CapsuleId -and
            [string]$marker.HostKey -eq $HostKey -and
            [string]$marker.Retention -eq $Retention -and
            ($Retention -eq 'persistent' -or [string]$marker.BootEpoch -eq $BootEpoch)
        )
    } catch {
        return $false
    }
}

function Initialize-CapsulenvHostPlacement {
    [CmdletBinding()]
    param([string]$CapsuleId)

    $placement = Get-CapsulenvHostPlacement -CapsuleId $CapsuleId
    if ($placement.Materialized -and -not $placement.Valid) {
        if ($placement.Retention -eq 'persistent') {
            throw "Persistent host placement exists but its identity marker is not valid: $($placement.Root)"
        }
        $staleRoot = '{0}.stale-{1}' -f $placement.Root, [Guid]::NewGuid().ToString('N')
        Move-Item -LiteralPath $placement.Root -Destination $staleRoot
        $placement = Get-CapsulenvHostPlacement -CapsuleId $CapsuleId
    }

    foreach ($path in @(
        $placement.Root,
        $placement.PackagesRoot,
        $placement.GenerationsRoot,
        $placement.ModulesRoot,
        $placement.StateRoot,
        $placement.CacheRoot,
        $placement.ScratchRoot
    )) {
        [void](New-Item -ItemType Directory -Path $path -Force)
    }

    $marker = [pscustomobject][ordered]@{
        SchemaVersion = 1
        CapsuleId = $placement.CapsuleId
        HostKey = $placement.HostKey
        Retention = $placement.Retention
        BootEpoch = $placement.BootEpoch
        CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-CapsulenvHostJsonAtomically -Path $placement.MarkerPath -Value $marker
    return Get-CapsulenvHostPlacement -CapsuleId $placement.CapsuleId
}

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvHostIdentityEvidence, Get-CapsulenvHostIdentityDigest, Get-CapsulenvHostKey, Get-CapsulenvHostLocalStateRoot, Get-CapsulenvHostRecord, Set-CapsulenvHostEnrollment, Get-CapsulenvHostPlacement, Test-CapsulenvHostPlacement, Initialize-CapsulenvHostPlacement
