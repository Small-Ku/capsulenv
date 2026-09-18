function Get-CapsulenvSessionStoreRoot {
    [CmdletBinding()]
    param()

    $placement = Get-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity)
    if (-not $placement.Valid) {
        $placement = Initialize-CapsulenvHostPlacement -CapsuleId $placement.CapsuleId
    }
    return Join-Path $placement.StateRoot 'sessions'
}

function Get-CapsulenvSessionLedgerPath {
    [CmdletBinding()]
    param()

    return Join-Path (Get-CapsulenvSessionStoreRoot) 'ledger.json'
}

function Read-CapsulenvSessionLedgerFile {
    [CmdletBinding()]
    param()

    $path = Get-CapsulenvSessionLedgerPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            SchemaVersion = 1
            Sessions = @()
        }
    }
    try {
        $ledger = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $sessions = if ($null -ne $ledger.PSObject.Properties['Sessions']) {
            @($ledger.Sessions)
        } else {
            @()
        }
        return [pscustomobject][ordered]@{
            SchemaVersion = 1
            Sessions = @($sessions)
        }
    } catch {
        # A corrupt host-local ledger is disposable residue, not ownership
        # authority. Start with an empty ledger and require new exact records.
        return [pscustomobject][ordered]@{
            SchemaVersion = 1
            Sessions = @()
        }
    }
}

function Get-CapsulenvSessionLedger {
    [CmdletBinding()]
    param()

    return Read-CapsulenvSessionLedgerFile
}

function Save-CapsulenvSessionLedger {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Ledger)

    Write-CapsulenvHostJsonAtomically -Path (Get-CapsulenvSessionLedgerPath) -Value ([pscustomobject][ordered]@{
        SchemaVersion = 1
        Sessions = @($Ledger.Sessions)
    })
}

function Invoke-CapsulenvSessionLedgerMutation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][scriptblock]$Mutation)

    $storeRoot = Get-CapsulenvSessionStoreRoot
    [void](New-Item -ItemType Directory -Path $storeRoot -Force)
    $lockPath = Join-Path $storeRoot 'ledger.lock'
    $lockHandle = $null
    $lockHeld = $false
    $lockDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while ($null -eq $lockHandle) {
        $candidate = $null
        try {
            $candidate = [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::ReadWrite
            )
            $candidate.Lock(0, 1)
            $lockHandle = $candidate
            $lockHeld = $true
        } catch {
            if ($null -ne $candidate) {
                $candidate.Dispose()
            }
            if ([DateTime]::UtcNow -ge $lockDeadline) {
                throw "Timed out acquiring session ledger lock: $lockPath"
            }
            Start-Sleep -Milliseconds 25
        }
    }
    try {
        $ledger = Read-CapsulenvSessionLedgerFile
        $result = & $Mutation $ledger
        Save-CapsulenvSessionLedger -Ledger $ledger
        return $result
    } finally {
        if ($null -ne $lockHandle) {
            if ($lockHeld) {
                $lockHandle.Unlock(0, 1)
            }
            $lockHandle.Dispose()
        }
    }
}

function Get-CapsulenvProcessStartIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        return $process.StartTime.ToUniversalTime().Ticks.ToString(
            [Globalization.CultureInfo]::InvariantCulture
        )
    } catch {
        throw "Process start identity is unavailable for PID $ProcessId."
    }
}

function New-CapsulenvProcessRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)]
        [ValidateSet('owned', 'attached', 'foreign')]
        [string]$Ownership,
        [string]$Provenance,
        [string[]]$HeldLeases = @(),
        [string]$ProcessStartIdentity
    )

    if ($Ownership -eq 'owned' -and [string]::IsNullOrWhiteSpace($ProcessStartIdentity)) {
        throw 'Owned process records require the launch boundary to supply ProcessStartIdentity.'
    }
    $startIdentity = if ([string]::IsNullOrWhiteSpace($ProcessStartIdentity)) {
        Get-CapsulenvProcessStartIdentity -ProcessId $ProcessId
    } else {
        $ProcessStartIdentity
    }
    return [pscustomobject][ordered]@{
        SessionId = $SessionId
        SessionProcessId = $ProcessId
        PID = $ProcessId
        ProcessStartIdentity = $startIdentity
        ProcessNonce = [Guid]::NewGuid().ToString('N')
        Role = $Role
        Ownership = $Ownership
        Provenance = $Provenance
        HeldLeases = @($HeldLeases)
        RegisteredAtUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Initialize-CapsulenvSession {
    [CmdletBinding()]
    param(
        [string]$Role = 'control-plane',
        [int]$ProcessId = $PID,
        [ValidateSet('owned', 'attached', 'foreign')]
        [string]$Ownership = 'owned',
        [string]$Provenance = 'capsulenv'
    )

    $sessionId = [Guid]::NewGuid().ToString('N')
    $startIdentity = Get-CapsulenvProcessStartIdentity -ProcessId $ProcessId
    return Invoke-CapsulenvSessionLedgerMutation {
        param($ledger)
        $processRecord = New-CapsulenvProcessRecord -SessionId $sessionId -ProcessId $ProcessId -Role $Role -Ownership $Ownership -Provenance $Provenance -ProcessStartIdentity $startIdentity
        $session = [pscustomobject][ordered]@{
            SessionId = $sessionId
            HostKey = Get-CapsulenvHostKey
            PID = $ProcessId
            ProcessStartIdentity = $processRecord.ProcessStartIdentity
            ProcessNonce = $processRecord.ProcessNonce
            Role = $Role
            Ownership = $Ownership
            Provenance = $Provenance
            ProcessRecords = @($processRecord)
            HeldLeases = @()
            CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
            UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        $ledger.Sessions = @($ledger.Sessions) + @($session)
        return $session
    }
}

function Register-CapsulenvProcessRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)]
        [ValidateSet('attached', 'foreign')]
        [string]$Ownership,
        [string]$Provenance,
        [string[]]$HeldLeases = @(),
        [string]$ProcessStartIdentity
    )

    return Invoke-CapsulenvSessionLedgerMutation {
        param($ledger)
        $session = @($ledger.Sessions | Where-Object { [string]$_.SessionId -eq $SessionId }) | Select-Object -First 1
        if ($null -eq $session) {
            throw "Cannot register a process for unknown session: $SessionId"
        }
        $record = New-CapsulenvProcessRecord -SessionId $SessionId -ProcessId $ProcessId -Role $Role -Ownership $Ownership -Provenance $Provenance -HeldLeases $HeldLeases -ProcessStartIdentity $ProcessStartIdentity
        $session.ProcessRecords = @($session.ProcessRecords) + @($record)
        $session.UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
        return $record
    }
}

function Register-CapsulenvOwnedProcessRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$ProcessStartIdentity,
        [string]$Provenance,
        [string[]]$HeldLeases = @()
    )

    return Invoke-CapsulenvSessionLedgerMutation {
        param($ledger)
        $session = @($ledger.Sessions | Where-Object { [string]$_.SessionId -eq $SessionId }) | Select-Object -First 1
        if ($null -eq $session) {
            throw "Cannot register a process for unknown session: $SessionId"
        }
        $record = New-CapsulenvProcessRecord -SessionId $SessionId -ProcessId $ProcessId -Role $Role -Ownership owned -Provenance $Provenance -HeldLeases $HeldLeases -ProcessStartIdentity $ProcessStartIdentity
        $session.ProcessRecords = @($session.ProcessRecords) + @($record)
        $session.UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
        return $record
    }
}

function Test-CapsulenvProcessRecordLive {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$ProcessRecord)

    if ([string]$ProcessRecord.Ownership -ne 'owned') {
        return $false
    }
    if ([int]$ProcessRecord.PID -le 0 -or [string]::IsNullOrWhiteSpace([string]$ProcessRecord.ProcessStartIdentity)) {
        return $false
    }
    try {
        $current = Get-CapsulenvProcessStartIdentity -ProcessId ([int]$ProcessRecord.PID)
        return [string]$current -eq [string]$ProcessRecord.ProcessStartIdentity
    } catch {
        return $false
    }
}

function Get-CapsulenvOwnedProcessRecords {
    [CmdletBinding()]
    param([string]$SessionId)

    $ledger = Get-CapsulenvSessionLedger
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($session in @($ledger.Sessions)) {
        if (-not [string]::IsNullOrWhiteSpace($SessionId) -and [string]$session.SessionId -ne $SessionId) {
            continue
        }
        foreach ($record in @($session.ProcessRecords)) {
            if ([string]$record.Ownership -eq 'owned' -and (Test-CapsulenvProcessRecordLive -ProcessRecord $record)) {
                $records.Add($record)
            }
        }
    }
    return @($records.ToArray())
}

function Stop-CapsulenvOwnedProcessRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$ProcessRecord)

    if (-not (Test-CapsulenvProcessRecordLive -ProcessRecord $ProcessRecord)) {
        return [pscustomobject][ordered]@{
            Stopped = $false
            PID = $ProcessRecord.PID
            Reason = 'process is not an exact live owned record'
        }
    }
    Stop-Process -Id ([int]$ProcessRecord.PID) -Force -ErrorAction Stop
    return [pscustomobject][ordered]@{
        Stopped = $true
        PID = $ProcessRecord.PID
        Reason = 'exact owned process stopped'
    }
}

function Get-CapsulenvStateLeasePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StatePath)

    $placement = Initialize-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity)
    $normalized = [System.IO.Path]::GetFullPath($StatePath).ToLowerInvariant()
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalized))
    } finally {
        $sha256.Dispose()
    }
    $key = ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
    $root = Join-Path $placement.StateRoot 'leases'
    [void](New-Item -ItemType Directory -Path $root -Force)
    return Join-Path $root ($key + '.lock')
}

function Add-CapsulenvSessionHeldLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)]$LeaseRecord
    )

    Invoke-CapsulenvSessionLedgerMutation {
        param($ledger)
        $session = @($ledger.Sessions | Where-Object { [string]$_.SessionId -eq $SessionId }) | Select-Object -First 1
        if ($null -eq $session) {
            throw "Cannot attach a lease to unknown session: $SessionId"
        }
        $session.HeldLeases = @($session.HeldLeases) + @($LeaseRecord)
        $session.UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Acquire-CapsulenvStateLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)]
        [ValidateSet('exclusive', 'shared-read', 'unmanaged')]
        [string]$Policy,
        [string]$SessionId
    )

    $leaseId = [Guid]::NewGuid().ToString('N')
    $lockPath = Get-CapsulenvStateLeasePath -StatePath $StatePath
    $handle = $null
    try {
        if ($Policy -eq 'exclusive') {
            $handle = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $handle.Lock(0, 1)
        } elseif ($Policy -eq 'shared-read') {
            $handle = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        }
    } catch {
        if ($null -ne $handle) {
            $handle.Dispose()
            $handle = $null
        }
        throw "Unable to acquire $Policy state lease for '$StatePath': $($_.Exception.Message)"
    }

    $lease = [pscustomobject][ordered]@{
        LeaseId = $leaseId
        StatePath = [System.IO.Path]::GetFullPath($StatePath)
        Policy = $Policy
        LockPath = $lockPath
        Handle = $handle
        Acquired = ($Policy -eq 'unmanaged' -or $null -ne $handle)
        Released = $false
        AcquiredAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        try {
            Add-CapsulenvSessionHeldLease -SessionId $SessionId -LeaseRecord ([pscustomobject][ordered]@{
                LeaseId = $lease.LeaseId
                StatePath = $lease.StatePath
                Policy = $lease.Policy
                LockPath = $lease.LockPath
                AcquiredAtUtc = $lease.AcquiredAtUtc
            })
        } catch {
            [void](Release-CapsulenvStateLease -Lease $lease)
            throw
        }
    }
    return $lease
}

function Release-CapsulenvStateLease {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Lease)

    if ($Lease.Released) {
        return $Lease
    }
    if ($null -ne $Lease.Handle) {
        try {
            if ($Lease.Policy -eq 'exclusive') {
                $Lease.Handle.Unlock(0, 1)
            }
        } finally {
            $Lease.Handle.Dispose()
        }
    }
    $Lease.Released = $true
    return $Lease
}

##MOD_EXEC## Export-ModuleMember -Function Initialize-CapsulenvSession, Get-CapsulenvSessionLedger, Register-CapsulenvProcessRecord, Get-CapsulenvOwnedProcessRecords, Test-CapsulenvProcessRecordLive, Stop-CapsulenvOwnedProcessRecord, Get-CapsulenvProcessStartIdentity, Acquire-CapsulenvStateLease, Release-CapsulenvStateLease
