Describe 'Capsulenv session ledger and state leases' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force
        $script:Module = @(Get-Module Capsulenv)[-1]
    }

    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }

    It 'keeps attached and foreign processes outside exact owned-process actions' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-ledger-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'ledger-test'
            $result = & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $session = Initialize-CapsulenvSession -Role test -Provenance test
                [void](Register-CapsulenvProcessRecord -SessionId $session.SessionId -ProcessId $PID -Role attached -Ownership attached -Provenance foreign)
                [void](Register-CapsulenvProcessRecord -SessionId $session.SessionId -ProcessId $PID -Role foreign -Ownership foreign -Provenance foreign)
                $owned = @(Get-CapsulenvOwnedProcessRecords -SessionId $session.SessionId)
                [pscustomobject]@{
                    SessionId = $session.SessionId
                    OwnedCount = $owned.Count
                    OwnedIdentity = $owned[0].ProcessStartIdentity
                    CurrentIdentity = Get-CapsulenvProcessStartIdentity -ProcessId $PID
                }
            } $temporaryRoot

            $result.OwnedCount | Should -Be 1
            $result.OwnedIdentity | Should -Be $result.CurrentIdentity
        } finally {
            if ($null -eq $oldStateRoot) {
                Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_STATE_ROOT = $oldStateRoot
            }
            if ($null -eq $oldBootEpoch) {
                Remove-Item Env:CAPSULENV_HOST_BOOT_EPOCH -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_BOOT_EPOCH = $oldBootEpoch
            }
        }
    }

    It 'does not let public session initialization promote an arbitrary PID to owned' {
        {
            Initialize-CapsulenvSession -ProcessId ($PID + 100000) -Ownership owned
        } | Should -Throw

        {
            Initialize-CapsulenvSession -ProcessId ($PID + 100000)
        } | Should -Throw
    }

    It 'does not let the public registration API promote an arbitrary live PID to owned' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-owned-boundary-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'owned-boundary-test'
            $session = & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                Initialize-CapsulenvSession -Role test -Ownership foreign -Provenance test
            } $temporaryRoot

            {
                Register-CapsulenvProcessRecord -SessionId $session.SessionId -ProcessId $PID -Role foreign -Ownership owned
            } | Should -Throw

            $foreign = [pscustomobject]@{
                PID = $PID
                Ownership = 'foreign'
                ProcessStartIdentity = Get-CapsulenvProcessStartIdentity -ProcessId $PID
            }
            $stop = Stop-CapsulenvOwnedProcessRecord -ProcessRecord $foreign
            $stop.Stopped | Should -BeFalse
        } finally {
            if ($null -eq $oldStateRoot) {
                Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_STATE_ROOT = $oldStateRoot
            }
            if ($null -eq $oldBootEpoch) {
                Remove-Item Env:CAPSULENV_HOST_BOOT_EPOCH -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_BOOT_EPOCH = $oldBootEpoch
            }
        }
    }

    It 'rejects a stale PID identity even when the PID is currently live' {
        $result = & $script:Module {
            $record = [pscustomobject]@{
                PID = $PID
                Ownership = 'owned'
                ProcessStartIdentity = 'stale-start-identity'
            }
            Test-CapsulenvProcessRecordLive -ProcessRecord $record
        }
        $result | Should -BeFalse
    }

    It 'holds an exclusive lease at the OS handle and releases it for reuse' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-lease-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        $first = $null
        $second = $null
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'lease-test'
            $statePath = Join-Path $temporaryRoot 'portable-profile/state.json'
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force)
            '{}' | Set-Content -LiteralPath $statePath -Encoding UTF8

            & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            } $temporaryRoot

            $first = Acquire-CapsulenvStateLease -StatePath $statePath -Policy exclusive
            $first.Acquired | Should -BeTrue
            {
                Acquire-CapsulenvStateLease -StatePath $statePath -Policy exclusive
            } | Should -Throw
            $second = Release-CapsulenvStateLease -Lease $first
            $second.Released | Should -BeTrue
            $replacement = Acquire-CapsulenvStateLease -StatePath $statePath -Policy exclusive
            try {
                $replacement.Acquired | Should -BeTrue
            } finally {
                [void](Release-CapsulenvStateLease -Lease $replacement)
            }
        } finally {
            if ($null -ne $first -and -not $first.Released) {
                [void](Release-CapsulenvStateLease -Lease $first)
            }
            if ($null -eq $oldStateRoot) {
                Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_STATE_ROOT = $oldStateRoot
            }
            if ($null -eq $oldBootEpoch) {
                Remove-Item Env:CAPSULENV_HOST_BOOT_EPOCH -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_BOOT_EPOCH = $oldBootEpoch
            }
        }
    }

    It 'releases an OS lease when session bookkeeping fails' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-lease-failure-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        $first = $null
        $replacement = $null
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'lease-failure-test'
            $statePath = Join-Path $temporaryRoot 'portable-profile/state.json'
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force)
            '{}' | Set-Content -LiteralPath $statePath -Encoding UTF8

            & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            } $temporaryRoot

            {
                Acquire-CapsulenvStateLease -StatePath $statePath -Policy exclusive -SessionId 'missing-session'
            } | Should -Throw

            $replacement = Acquire-CapsulenvStateLease -StatePath $statePath -Policy exclusive
            $replacement.Acquired | Should -BeTrue
        } finally {
            if ($null -ne $replacement -and -not $replacement.Released) {
                [void](Release-CapsulenvStateLease -Lease $replacement)
            }
            if ($null -ne $first -and -not $first.Released) {
                [void](Release-CapsulenvStateLease -Lease $first)
            }
            if ($null -eq $oldStateRoot) {
                Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_STATE_ROOT = $oldStateRoot
            }
            if ($null -eq $oldBootEpoch) {
                Remove-Item Env:CAPSULENV_HOST_BOOT_EPOCH -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_BOOT_EPOCH = $oldBootEpoch
            }
        }
    }

    It 'serializes concurrent session creation without losing either ledger record' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-ledger-concurrent-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        $jobs = @()
        try {
            $stateRoot = Join-Path $temporaryRoot 'host-state'
            $env:CAPSULENV_HOST_STATE_ROOT = $stateRoot
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'ledger-concurrent-test'
            & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $capsuleId = Get-CapsulenvIdentity
                [void](Initialize-CapsulenvHostPlacement -CapsuleId $capsuleId)
            } $temporaryRoot
            $jobScript = {
                param($ModulePath, $CapsuleRoot, $StateRoot, $BootEpoch, $Role)
                $ErrorActionPreference = 'Stop'
                $env:CAPSULENV_HOST_STATE_ROOT = $StateRoot
                $env:CAPSULENV_HOST_BOOT_EPOCH = $BootEpoch
                Import-Module $ModulePath -Force
                $module = @(Get-Module Capsulenv)[-1]
                & $module {
                    param($Root, $SessionRole)
                    Initialize-CapsulenvContext -Root $Root | Out-Null
                    Initialize-CapsulenvSession -Role $SessionRole -Ownership foreign -Provenance test | Out-Null
                } $CapsuleRoot $Role
            }
            foreach ($role in @('concurrent-a', 'concurrent-b')) {
                $jobs += Start-Job -ScriptBlock $jobScript -ArgumentList @(
                    $script:Build.ModulePath,
                    $temporaryRoot,
                    $stateRoot,
                    'ledger-concurrent-test',
                    $role
                )
            }
            $jobs | Wait-Job -Timeout 30 | Out-Null
            foreach ($job in $jobs) {
                if ($job.State -ne 'Completed') {
                    Receive-Job -Job $job -ErrorAction Continue | Out-Host
                    throw "Concurrent ledger job failed: $($job.State)"
                }
                Receive-Job -Job $job -ErrorAction Stop | Out-Null
            }

            $ledger = & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                Get-CapsulenvSessionLedger
            } $temporaryRoot
            @($ledger.Sessions).Count | Should -Be 2
            @($ledger.Sessions | ForEach-Object Role) | Should -Contain 'concurrent-a'
            @($ledger.Sessions | ForEach-Object Role) | Should -Contain 'concurrent-b'
        } finally {
            foreach ($job in $jobs) {
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            }
            if ($null -eq $oldStateRoot) {
                Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_STATE_ROOT = $oldStateRoot
            }
            if ($null -eq $oldBootEpoch) {
                Remove-Item Env:CAPSULENV_HOST_BOOT_EPOCH -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_BOOT_EPOCH = $oldBootEpoch
            }
        }
    }
    It 'requires a ledger nonce and exact identity before stopping an owned process' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-stop-authority-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'stop-authority-test'
            $session = & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                Initialize-CapsulenvSession -Role test -Provenance test
            } $temporaryRoot
            $canonical = @($session.ProcessRecords)[0]
            $forged = [pscustomobject]@{
                SessionId = $canonical.SessionId
                ProcessNonce = 'forged-process-nonce'
                PID = $canonical.PID
                Ownership = 'owned'
                ProcessStartIdentity = $canonical.ProcessStartIdentity
            }

            Mock Stop-Process {} -ModuleName Capsulenv
            $rejected = Stop-CapsulenvOwnedProcessRecord -ProcessRecord $forged
            $rejected.Stopped | Should -BeFalse
            Should -Invoke Stop-Process -ModuleName Capsulenv -Times 0

            $accepted = Stop-CapsulenvOwnedProcessRecord -ProcessRecord $canonical
            $accepted.Stopped | Should -BeTrue
            Should -Invoke Stop-Process -ModuleName Capsulenv -Times 1
        } finally {
            if ($null -eq $oldStateRoot) {
                Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_STATE_ROOT = $oldStateRoot
            }
            if ($null -eq $oldBootEpoch) {
                Remove-Item Env:CAPSULENV_HOST_BOOT_EPOCH -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_BOOT_EPOCH = $oldBootEpoch
            }
        }
    }

    It 'records exclusive leases in the session ledger and removes them on release' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-lease-ledger-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        $lease = $null
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'lease-ledger-test'
            $statePath = Join-Path $temporaryRoot 'portable-profile/state.json'
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force)
            '{}' | Set-Content -LiteralPath $statePath -Encoding UTF8
            $session = & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                Initialize-CapsulenvSession -Role test -Provenance test
            } $temporaryRoot

            { Acquire-CapsulenvStateLease -StatePath $statePath -Policy exclusive } | Should -Throw '*require a session id*'
            $lease = Acquire-CapsulenvStateLease -StatePath $statePath -Policy exclusive -SessionId $session.SessionId
            $ledger = Get-CapsulenvSessionLedger
            @($ledger.Sessions[0].HeldLeases).Count | Should -Be 1
            @((Get-CapsulenvActiveExclusiveStateLeases)).Count | Should -Be 1

            [void](Release-CapsulenvStateLease -Lease $lease)
            $ledgerAfter = Get-CapsulenvSessionLedger
            @($ledgerAfter.Sessions[0].HeldLeases).Count | Should -Be 0
            @((Get-CapsulenvActiveExclusiveStateLeases)).Count | Should -Be 0
        } finally {
            if ($null -ne $lease -and -not $lease.Released) {
                [void](Release-CapsulenvStateLease -Lease $lease)
            }
            if ($null -eq $oldStateRoot) {
                Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_STATE_ROOT = $oldStateRoot
            }
            if ($null -eq $oldBootEpoch) {
                Remove-Item Env:CAPSULENV_HOST_BOOT_EPOCH -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_BOOT_EPOCH = $oldBootEpoch
            }
        }
    }

}
