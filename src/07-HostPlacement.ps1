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

    # The machine/user tuple is the continuity key. GDID is optional strong
    # evidence and must never change the host-record namespace when a registry
    # read is temporarily unavailable.
    $evidence = Get-CapsulenvHostIdentityEvidence
    $canonical = "capsulenv-host-identity-v1`n" + [string]$evidence.MachineUser.Value
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

function Publish-CapsulenvFileAuthorityAtomically {
    [CmdletBinding(DefaultParameterSetName = 'Value')]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true, ParameterSetName = 'Value')][AllowNull()]$Value,
        [Parameter(Mandatory = $true, ParameterSetName = 'Staged')][string]$StagedPath
    )

    $parent = Split-Path -Parent $Path
    [void](New-Item -ItemType Directory -Path $parent -Force)
    $ownsStagedPath = $false
    if ($PSCmdlet.ParameterSetName -eq 'Value') {
        $StagedPath = Join-Path $parent ('.{0}.{1}.tmp' -f (Split-Path -Leaf $Path), [Guid]::NewGuid().ToString('N'))
        $ownsStagedPath = $true
        $encoding = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText(
            $StagedPath,
            ($Value | ConvertTo-Json -Depth 12),
            $encoding
        )
    } elseif (-not (Test-Path -LiteralPath $StagedPath -PathType Leaf)) {
        throw "The staged authority file does not exist: $StagedPath"
    }

    $backupPath = $null
    try {
        if ((Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Authority path is occupied by a directory or incompatible item: $Path"
        }
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                # File.Replace either publishes the new file or leaves the old
                # authority untouched. There is deliberately no delete-then-
                # move fallback for a durable authority file.
                $backupPath = '{0}.backup-{1}' -f $Path, [Guid]::NewGuid().ToString('N')
                [System.IO.File]::Replace($StagedPath, $Path, $backupPath, $true)
                if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                    Remove-Item -LiteralPath $backupPath -Force
                }
            } catch {
                if ($null -ne $backupPath -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
                    Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
                }
                throw "Could not atomically publish authority '$Path'; the previous valid file was retained. $($_.Exception.Message)"
            }
        } else {
            Move-Item -LiteralPath $StagedPath -Destination $Path
        }
    } finally {
        if (($ownsStagedPath -or $PSCmdlet.ParameterSetName -eq 'Staged') -and (Test-Path -LiteralPath $StagedPath -PathType Leaf)) {
            Remove-Item -LiteralPath $StagedPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-CapsulenvDirectoryAuthorityJournalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\/')
    $parent = Split-Path -Parent $fullPath
    return Join-Path $parent ('.{0}.transaction.json' -f (Split-Path -Leaf $fullPath))
}

function Recover-CapsulenvDirectoryAuthorityTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$JournalPath
    )

    $destination = [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\/')
    if ([string]::IsNullOrWhiteSpace($JournalPath)) {
        $JournalPath = Get-CapsulenvDirectoryAuthorityJournalPath -Path $destination
    }
    if (-not (Test-Path -LiteralPath $JournalPath -PathType Leaf)) {
        return $false
    }
    $journal = Get-Content -LiteralPath $JournalPath -Raw | ConvertFrom-Json
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$journal.Destination, $destination)) {
        throw "Directory authority journal targets a different destination: $JournalPath"
    }
    $backup = [string]$journal.Backup
    $staged = [string]$journal.Staged
    try {
        if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
            if (Test-Path -LiteralPath $backup -PathType Container) {
                Move-Item -LiteralPath $backup -Destination $destination
            } elseif (Test-Path -LiteralPath $staged -PathType Container) {
                Move-Item -LiteralPath $staged -Destination $destination
            } elseif ([string]$journal.Phase -eq 'Prepared') {
                # Nothing was published and no previous authority existed. A
                # fault at this point only leaves transaction metadata behind.
                Remove-Item -LiteralPath $JournalPath -Force
                return $true
            } else {
                throw "Directory authority transaction has no recoverable destination, backup, or staging root: $destination"
            }
        }
        if (Test-Path -LiteralPath $backup) {
            Remove-Item -LiteralPath $backup -Recurse -Force
        }
        if (Test-Path -LiteralPath $staged) {
            Remove-Item -LiteralPath $staged -Recurse -Force
        }
        Remove-Item -LiteralPath $JournalPath -Force
        return $true
    } catch {
        throw "Could not recover directory authority transaction '$destination': $($_.Exception.Message)"
    }
}

function Publish-CapsulenvDirectoryAuthorityTransactionally {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$StagedPath,
        [scriptblock]$FaultInjector
    )

    $destination = [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\/')
    $staged = [System.IO.Path]::GetFullPath($StagedPath).TrimEnd([char[]]'\/')
    if (-not (Test-Path -LiteralPath $staged -PathType Container)) {
        throw "The staged authority directory does not exist: $staged"
    }
    if ((Test-Path -LiteralPath $destination) -and -not (Test-Path -LiteralPath $destination -PathType Container)) {
        throw "Directory authority path is occupied by a file or incompatible item: $destination"
    }
    $parent = Split-Path -Parent $destination
    [void](New-Item -ItemType Directory -Path $parent -Force)
    $journalPath = Get-CapsulenvDirectoryAuthorityJournalPath -Path $destination
    if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
        [void](Recover-CapsulenvDirectoryAuthorityTransaction -Path $destination -JournalPath $journalPath)
    }
    $backup = '{0}.backup-{1}' -f $destination, [Guid]::NewGuid().ToString('N')
    $journal = [ordered]@{
        SchemaVersion = 1
        Destination = $destination
        Staged = $staged
        Backup = $backup
        Phase = 'Prepared'
        CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    Publish-CapsulenvFileAuthorityAtomically -Path $journalPath -Value $journal
    $destinationBackedUp = $false
    $published = $false
    try {
        if (Test-Path -LiteralPath $destination -PathType Container) {
            Move-Item -LiteralPath $destination -Destination $backup
            $destinationBackedUp = $true
            $journal.Phase = 'BackedUp'
            Publish-CapsulenvFileAuthorityAtomically -Path $journalPath -Value $journal
        }
        if ($null -ne $FaultInjector) { & $FaultInjector 'AfterBackup' }
        Move-Item -LiteralPath $staged -Destination $destination
        $published = $true
        $journal.Phase = 'Published'
        Publish-CapsulenvFileAuthorityAtomically -Path $journalPath -Value $journal
        if (Test-Path -LiteralPath $backup) {
            Remove-Item -LiteralPath $backup -Recurse -Force
        }
        Remove-Item -LiteralPath $journalPath -Force
        return [pscustomobject][ordered]@{ Published = $true; Destination = $destination }
    } catch {
        if ($destinationBackedUp -and -not (Test-Path -LiteralPath $destination) -and (Test-Path -LiteralPath $backup -PathType Container)) {
            try {
                Move-Item -LiteralPath $backup -Destination $destination
                Remove-Item -LiteralPath $journalPath -Force -ErrorAction SilentlyContinue
            } catch {
                throw "Directory authority publication failed and recovery is still pending at '$journalPath': $($_.Exception.Message)"
            }
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $staged) {
            Remove-Item -LiteralPath $staged -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($published -and (Test-Path -LiteralPath $backup)) {
            Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-CapsulenvHostJsonAtomically {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    Publish-CapsulenvFileAuthorityAtomically -Path $Path -Value $Value
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
