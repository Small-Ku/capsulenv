Describe 'Independent placement and UserIntegration lifetime' {
    BeforeAll {
        $script:Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:Build = Get-CapsulenvTestModuleBuild -Root $script:Root
        Import-Module $script:Build.ModulePath -Force -DisableNameChecking
        $script:Module = Get-Module Capsulenv
        $script:WriteTestBitwardenHostBackup = {
            param($Path, $Values, $HostIntegrationKey, $MachineUser, $WindowsGdid)
            $record = & $script:Module {
                param($BackupValues)
                New-CapsulenvBitwardenHostBackup -Values $BackupValues -Applied ([ordered]@{ Status = 'Stopped'; StartMode = 'Disabled' })
            } $Values
            $sameHost = ($null -eq $HostIntegrationKey -and $null -eq $MachineUser -and $null -eq $WindowsGdid)
            if ($null -ne $HostIntegrationKey) { $record.HostIntegrationKey = $HostIntegrationKey }
            if ($null -ne $MachineUser) { $record.MachineUser = $MachineUser }
            if ($null -ne $WindowsGdid) { $record.WindowsGdid = $WindowsGdid }
            New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
            $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
            if ($sameHost) {
                $leaf = Split-Path -Leaf $Path
                $surface = if ($leaf -eq 'git-ssh-config.json') { 'git-global' } else { 'windows-ssh-agent-service' }
                $applied = if ($surface -eq 'git-global') {
                    [ordered]@{ 'core.sshCommand' = 'C:/Windows/System32/OpenSSH/ssh.exe'; 'gpg.ssh.program' = 'C:/Windows/System32/OpenSSH/ssh-keygen.exe' }
                } else {
                    [ordered]@{ Status = 'Stopped'; StartMode = 'Disabled' }
                }
                & $script:Module {
                    param($Surface, $Token, $Applied)
                    [void](Write-CapsulenvPersistentUserIntegrationMarker -Surface $Surface -Token $Token -Applied $Applied)
                } $surface ([string]$record.OwnershipId) $applied
            }
        }
        $script:WriteTestGitPortableBackup = {
            param($Values, $Applied)
            & $script:Module {
                param($BackupValues, $AppliedValues)
                $path = Get-CapsulenvGitConfigBackupPath
                $target = Get-CapsulenvPortableGitConfigTarget
                $record = New-CapsulenvGitPortableBackup -Values $BackupValues -Applied $AppliedValues -Target $target
                [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
                Write-CapsulenvHostJsonAtomically -Path $path -Value $record
                return $path
            } $Values $Applied
        }
        $script:WriteTestEnvironmentOwnership = {
            param($Backup, $Variables, $PathEntries)
            & $script:Module {
                param($BackupValue, $AppliedVariables, $AppliedPaths)
                $path = Get-CapsulenvUserEnvironmentBackupPath
                Write-CapsulenvUserEnvironmentBackup -Path $path -Backup $BackupValue
                $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
                [void](Write-CapsulenvPersistentUserIntegrationMarker -Surface environment -Token $hash -Applied ([ordered]@{
                    Variables = $AppliedVariables
                    PathEntries = @($AppliedPaths)
                }))
            } $Backup $Variables $PathEntries
        }
    }
    BeforeEach {
        $script:OldHostState = $env:CAPSULENV_HOST_STATE_ROOT
        $script:OldLeaseId = $env:CAPSULENV_USER_LEASE_ID
        $script:OldMode = $env:CAPSULENV_MODE
        $script:OldPath = $env:PATH
        $script:OldRoot = $env:CAPSULENV_ROOT
        $script:Fixture = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $script:Fixture 'host'
        $env:CAPSULENV_USER_LEASE_ID = $null
        $env:CAPSULENV_MODE = $null
        $configRoot = Join-Path $script:Fixture 'capsule/config'
        New-Item -ItemType Directory -Path $configRoot -Force | Out-Null
        Copy-Item (Join-Path $script:Root 'config/capsulenv.psd1') (Join-Path $configRoot 'capsulenv.psd1')
        & $script:Module { param($Root) Initialize-CapsulenvContext -Root $Root | Out-Null } (Join-Path $script:Fixture 'capsule')
        $global:CapsulenvLeaseTestEnv = @{ PATH = '/user/bin;/shared/bin'; SCOOP = 'foreign-scoop'; SCOOP_GLOBAL = 'foreign-global'; SCOOP_CACHE = 'foreign-cache'; ModuleRoot = (Join-Path $script:Fixture 'modules') }
        Mock Get-CapsulenvUserEnvironmentValue { param($Name) $global:CapsulenvLeaseTestEnv[$Name] } -ModuleName Capsulenv
        Mock Set-CapsulenvUserEnvironmentValue { param($Name, $Value) $global:CapsulenvLeaseTestEnv[$Name] = $Value } -ModuleName Capsulenv
        Mock Get-CapsulenvEnvironmentPlan { [pscustomobject]@{ Variables = @{ SCOOP = 'capsule-scoop'; SCOOP_GLOBAL = 'capsule-global'; SCOOP_CACHE = 'capsule-cache'; GIT_CONFIG_GLOBAL = (Join-Path $script:Fixture 'capsule/tool-data/git/config') }; PathEntries = @('/shared/bin', '/capsule/bin'); ToolStorage = [pscustomobject]@{ Enabled=$false; CreateDirectories=$false }; SessionDirectories=@(); ModulePathEntries=@($global:CapsulenvLeaseTestEnv.ModuleRoot) } } -ModuleName Capsulenv
        Mock Get-CapsulenvConfiguredDefaultBrowser { $null } -ModuleName Capsulenv
    }
    AfterEach {
        $env:CAPSULENV_HOST_STATE_ROOT = $script:OldHostState
        $env:CAPSULENV_USER_LEASE_ID = $script:OldLeaseId
        $env:CAPSULENV_MODE = $script:OldMode
        $env:PATH = $script:OldPath
        $env:CAPSULENV_ROOT = $script:OldRoot
        Remove-Variable CapsulenvLeaseTestEnv -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable CapsulenvBitwardenDiagnostics -Scope Global -ErrorAction SilentlyContinue
    }
    AfterAll { Remove-Module Capsulenv -Force }

    It 'keeps persistent placement isolated across repeated session activation' {
        & $script:Module { param($Root) Set-CapsulenvHostEnrollment -Retention persistent -EnrollmentTag desktop -PlacementRoot $Root | Out-Null } (Join-Path $script:Fixture 'depot')
        Get-CapsulenvUserIntegrationLifetime | Should -Be isolated
        1..2 | ForEach-Object {
            & $script:Module { Set-CapsulenvSessionEnvironment -IntegrationMode ShellOnly } | Out-Null
        }
        $status = Get-CapsulenvUserIntegrationStatus
        $status.PlacementRetention | Should -Be persistent
        $status.UserIntegration | Should -Be isolated
        Should -Invoke Set-CapsulenvUserEnvironmentValue -ModuleName Capsulenv -Times 0 -Exactly
        { New-CapsulenvUserIntegrationBridge -CapsuleId (& $script:Module { Get-CapsulenvIdentity }) -BrowserApp firefox } | Should -Throw '*Explicit UserIntegration authority*'
        { & $script:Module { Sync-CapsulenvUserEnvironment } } | Should -Throw '*Explicit UserIntegration authority*'
    }

    It 'does not treat User invocation semantics as persistent authority' {
        $env:CAPSULENV_MODE = 'User'
        { & $script:Module { Assert-CapsulenvUserIntegrationAuthority -PersistentOnly } } | Should -Throw '*Explicit UserIntegration authority*'
        { & $script:Module { Set-CapsulenvBitwardenDesktopSshAgent -NoStart } } | Should -Throw '*Explicit UserIntegration authority*'
        Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
        { Disable-CapsulenvWindowsSshAgent -Confirm:$false } | Should -Throw '*Explicit UserIntegration authority*'
        { Sync-CapsulenvPackageStartMenuShortcuts -IntegrationMode User } | Should -Throw '*Explicit UserIntegration authority*'
        { Set-CapsulenvGitOpenSsh } | Should -Throw '*Explicit UserIntegration authority*'
    }

    It 'applies and releases a lease with <Retention> placement' -ForEach @(@{Retention='ephemeral'}, @{Retention='persistent'}) {
        & $script:Module { param($Retention, $Root) Set-CapsulenvHostEnrollment -Retention $Retention -EnrollmentTag shared -PlacementRoot $Root | Out-Null } $Retention (Join-Path $script:Fixture 'depot')
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        $lease = Start-CapsulenvUserIntegrationLease
        $lease.Phase | Should -Be Active
        $lease.LeaseId | Should -Not -BeNullOrEmpty
        $global:CapsulenvLeaseTestEnv.SCOOP | Should -Be 'capsule-scoop'
        $status = Get-CapsulenvUserIntegrationStatus
        $status.PlacementRetention | Should -Be $Retention
        $fullStatus = & $script:Module { Get-CapsulenvStatus }
        $fullStatus.PlacementRetention | Should -Be $Retention
        $fullStatus.UserIntegration | Should -Be leased
        $fullStatus.OwnedUserIntegration | Should -Be leased
        $status.OwnedUserIntegration | Should -Be leased
        $status.IntegrationLease | Should -Be Active
        (& $script:Module { Get-CapsulenvUserIntegrationMode }) | Should -Be ShellOnly
        Stop-CapsulenvUserIntegrationLease
        $global:CapsulenvLeaseTestEnv.SCOOP | Should -Be 'foreign-scoop'
        $global:CapsulenvLeaseTestEnv.PATH | Should -Be '/user/bin;/shared/bin'
        (Get-CapsulenvUserIntegrationStatus).OwnedUserIntegration | Should -Be none
    }

    It 'preserves concurrent variable and PATH changes and preexisting shared entries' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        Start-CapsulenvUserIntegrationLease | Out-Null
        $global:CapsulenvLeaseTestEnv.SCOOP = 'concurrent-scoop'
        $global:CapsulenvLeaseTestEnv.PATH += ';;/concurrent/bin;'
        Stop-CapsulenvUserIntegrationLease
        $global:CapsulenvLeaseTestEnv.SCOOP | Should -Be 'concurrent-scoop'
        $global:CapsulenvLeaseTestEnv.PATH | Should -Be '/user/bin;/shared/bin;;/concurrent/bin;'
    }

    It 'can lease without introducing any new PATH entries' {
        $global:CapsulenvLeaseTestEnv.PATH = '/user/bin;/shared/bin;/capsule/bin'
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        $lease = Start-CapsulenvUserIntegrationLease
        @($lease.AddedPaths).Count | Should -Be 0
        Stop-CapsulenvUserIntegrationLease
        $global:CapsulenvLeaseTestEnv.PATH | Should -Be '/user/bin;/shared/bin;/capsule/bin'
    }

    It 'restores an owned empty variable when Windows reports the applied deletion as null' {
        $global:CapsulenvLeaseTestEnv['EMPTY'] = 'original'
        Mock Get-CapsulenvEnvironmentPlan { [pscustomobject]@{ Variables=@{ EMPTY='' }; PathEntries=@('/capsule/bin') } } -ModuleName Capsulenv
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        Start-CapsulenvUserIntegrationLease | Out-Null
        $global:CapsulenvLeaseTestEnv['EMPTY'] = $null
        Stop-CapsulenvUserIntegrationLease
        $global:CapsulenvLeaseTestEnv['EMPTY'] | Should -Be original
    }

    It 'retains portable requested policy after disposable host records disappear' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        Remove-Item $env:CAPSULENV_HOST_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
        Get-CapsulenvUserIntegrationLifetime | Should -Be leased
        Start-CapsulenvUserIntegrationLease | Out-Null
        (Get-CapsulenvUserIntegrationStatus).PlacementRetention | Should -Be ephemeral
        Stop-CapsulenvUserIntegrationLease
    }

    It 'rejects policy with mismatched strong host identity evidence' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        & $script:Module {
            $path = Get-CapsulenvUserIntegrationPolicyPath
            $policy = Get-Content $path -Raw | ConvertFrom-Json
            $policy.WindowsGdid = 'unrelated-host'
            Write-CapsulenvHostJsonAtomically -Path $path -Value $policy
        }
        { Get-CapsulenvUserIntegrationLifetime } | Should -Throw '*validated capsule/host/user*'
        { Start-CapsulenvUserIntegrationLease } | Should -Throw '*validated capsule/host/user*'
    }

    It 'fails closed for a stale lease and supports explicit recovery without promotion' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        Start-CapsulenvUserIntegrationLease | Out-Null
        & $script:Module {
            $lease = Get-CapsulenvUserIntegrationLease
            $lease.ProcessStartIdentity = 'not-the-process-start'
            Write-CapsulenvHostJsonAtomically -Path (Get-CapsulenvUserIntegrationLeasePath) -Value $lease
        }
        (Get-CapsulenvUserIntegrationStatus).IntegrationLease | Should -Be Stale
        { & $script:Module { Assert-CapsulenvUserIntegrationAuthority } } | Should -Throw '*stale*'
        { Start-CapsulenvUserIntegrationLease } | Should -Throw '*lease exists*'
        Stop-CapsulenvUserIntegrationLease
        (Get-CapsulenvUserIntegrationStatus).OwnedUserIntegration | Should -Be none
    }

    It 'does not release another live session lease' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        Start-CapsulenvUserIntegrationLease | Out-Null
        $env:CAPSULENV_USER_LEASE_ID = 'another-session'
        { Stop-CapsulenvUserIntegrationLease } | Should -Throw '*another live session*'
        $global:CapsulenvLeaseTestEnv.SCOOP | Should -Be 'capsule-scoop'
    }

    It 'does not release another live owner when boot evidence is unavailable or changed' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        Start-CapsulenvUserIntegrationLease | Out-Null
        & $script:Module {
            $lease = Get-CapsulenvUserIntegrationLease
            $lease.BootEpoch = 'unavailable-other-process'
            Write-CapsulenvHostJsonAtomically -Path (Get-CapsulenvUserIntegrationLeasePath) -Value $lease
        }
        $env:CAPSULENV_USER_LEASE_ID = 'another-session'
        (Get-CapsulenvUserIntegrationStatus).IntegrationLease | Should -Be Stale
        { Stop-CapsulenvUserIntegrationLease } | Should -Throw '*another live session*'
        $global:CapsulenvLeaseTestEnv.SCOOP | Should -Be capsule-scoop
    }

    It 'retains an incomplete journal and restores only successfully applied values' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        Mock Set-CapsulenvUserEnvironmentValue { throw 'injected apply failure' } -ModuleName Capsulenv
        { Start-CapsulenvUserIntegrationLease } | Should -Throw '*injected apply failure*'
        (Get-CapsulenvUserIntegrationStatus).IntegrationLease | Should -Be Prepared
        Mock Set-CapsulenvUserEnvironmentValue { param($Name,$Value) $global:CapsulenvLeaseTestEnv[$Name]=$Value } -ModuleName Capsulenv
        Stop-CapsulenvUserIntegrationLease
        $global:CapsulenvLeaseTestEnv.SCOOP | Should -Be foreign-scoop
    }

    It 'keeps privileged and persistent Bitwarden operations outside an active user lease' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        Start-CapsulenvUserIntegrationLease | Out-Null
        { & $script:Module { Assert-CapsulenvUserIntegrationAuthority -PersistentOnly } } | Should -Throw '*Explicit UserIntegration authority*'
        Stop-CapsulenvUserIntegrationLease
    }

    It 'inventories capsule-wide Bitwarden and Git ownership plus host-scoped ssh-agent ownership independently of install-mode state' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime persistent
        $desktopPath = & $script:Module { Get-CapsulenvBitwardenDesktopSettingsBackupPath }
        $gitPath = & $script:Module { Get-CapsulenvGitConfigBackupPath }
        $servicePath = & $script:Module { Get-CapsulenvSshAgentServiceStatePath }

        New-Item -ItemType Directory -Path (Split-Path -Parent $desktopPath) -Force | Out-Null
        '{"SchemaVersion":1,"Entries":[]}' | Set-Content -LiteralPath $desktopPath -Encoding UTF8
        @((Get-CapsulenvUserIntegrationStatus).PersistentOwnedSurfaces) | Should -Contain 'bitwarden-desktop'
        Remove-Item -LiteralPath $desktopPath -Force

        & $script:WriteTestGitPortableBackup ([pscustomobject][ordered]@{
            'core.sshCommand' = [pscustomobject]@{ Exists = $false; Values = [string[]]@() }
            'gpg.ssh.program' = [pscustomobject]@{ Exists = $false; Values = [string[]]@() }
        }) ([pscustomobject][ordered]@{
            'core.sshCommand' = [string[]]@('C:/Windows/System32/OpenSSH/ssh.exe')
            'gpg.ssh.program' = [string[]]@('C:/Windows/System32/OpenSSH/ssh-keygen.exe')
        }) | Out-Null
        @((Get-CapsulenvUserIntegrationStatus).PersistentOwnedSurfaces) | Should -Contain 'git-global'
        Remove-Item -LiteralPath $gitPath -Force

        & $script:WriteTestBitwardenHostBackup $servicePath ([ordered]@{ Status = 'Stopped'; StartMode = 'Manual' })
        @((Get-CapsulenvUserIntegrationStatus).PersistentOwnedSurfaces) | Should -Contain 'windows-ssh-agent-service'
        { Set-CapsulenvUserIntegrationLifetime -Lifetime isolated } | Should -Throw '*windows-ssh-agent-service*'
        Remove-Item -LiteralPath $servicePath -Force
        & $script:Module { Remove-CapsulenvPersistentUserIntegrationMarker -Surface 'windows-ssh-agent-service' }

        Set-CapsulenvUserIntegrationLifetime -Lifetime isolated
        (Get-CapsulenvUserIntegrationStatus).OwnedUserIntegration | Should -Be none
        $desktopPath | Should -Not -Match 'user-integrations'
        $gitPath | Should -Not -Match 'user-integrations'
        $servicePath | Should -Match 'user-integrations'
    }

    It 'fails closed when an environment ownership marker survives without its portable rollback evidence' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime persistent
        & $script:Module {
            [void](Write-CapsulenvPersistentUserIntegrationMarker -Surface environment)
        }

        $status = Get-CapsulenvUserIntegrationStatus
        $status.OwnedUserIntegration | Should -Be persistent
        @($status.PersistentOwnedSurfaces) | Should -Contain 'environment-marker'
        { Set-CapsulenvUserIntegrationLifetime -Lifetime leased } | Should -Throw '*environment-marker*'

        Remove-Item -LiteralPath $env:CAPSULENV_HOST_STATE_ROOT -Recurse -Force
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        Start-CapsulenvUserIntegrationLease | Out-Null
        Stop-CapsulenvUserIntegrationLease
    }

    It 'refuses a lease when capsule-wide persistent Git ownership appears after leased policy selection' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        & $script:WriteTestGitPortableBackup ([pscustomobject][ordered]@{
            'core.sshCommand' = [pscustomobject]@{ Exists = $false; Values = [string[]]@() }
            'gpg.ssh.program' = [pscustomobject]@{ Exists = $false; Values = [string[]]@() }
        }) ([pscustomobject][ordered]@{
            'core.sshCommand' = [string[]]@('C:/Windows/System32/OpenSSH/ssh.exe')
            'gpg.ssh.program' = [string[]]@('C:/Windows/System32/OpenSSH/ssh-keygen.exe')
        }) | Out-Null

        { Start-CapsulenvUserIntegrationLease } | Should -Throw '*Existing persistent UserIntegration ownership*git-global*'
        (Get-CapsulenvUserIntegrationStatus).OwnedUserIntegration | Should -Be persistent
    }

    It 'does not count a wrong-host ssh-agent backup as current-host ownership and preserves it' {
        $serviceBackup = & $script:Module { Get-CapsulenvSshAgentServiceStatePath }
        & $script:WriteTestBitwardenHostBackup $serviceBackup ([ordered]@{ Status = 'Stopped'; StartMode = 'Manual' }) 'foreign-host-key' 'foreign-machine|foreign\user' 'foreign-gdid'
        & $script:Module { Remove-CapsulenvPersistentUserIntegrationMarker -Surface 'windows-ssh-agent-service' }

        $status = Get-CapsulenvUserIntegrationStatus

        $status.OwnedUserIntegration | Should -Be none
        @($status.PersistentOwnedSurfaces) | Should -Not -Contain 'windows-ssh-agent-service'
        Test-Path -LiteralPath $serviceBackup -PathType Leaf | Should -BeTrue
    }

    It 'refuses wrong-host ssh-agent restore without changing the host' {
        $serviceBackup = & $script:Module { Get-CapsulenvSshAgentServiceStatePath }
        & $script:WriteTestBitwardenHostBackup $serviceBackup ([ordered]@{ Status = 'Stopped'; StartMode = 'Manual' }) 'foreign-host-key' 'foreign-machine|foreign\user' 'foreign-gdid'
        & $script:Module {
            $record = Get-Content -LiteralPath (Get-CapsulenvSshAgentServiceStatePath) -Raw | ConvertFrom-Json
            [void](Write-CapsulenvPersistentUserIntegrationMarker -Surface 'windows-ssh-agent-service' -Token ([string]$record.OwnershipId) -Applied ([ordered]@{ Status='Stopped'; StartMode='Disabled' }))
        }
        Mock Set-Service {} -ModuleName Capsulenv

        { Restore-CapsulenvWindowsSshAgent -Confirm:$false } | Should -Throw '*validated capsule/host/user*'

        Test-Path -LiteralPath $serviceBackup -PathType Leaf | Should -BeTrue
        Should -Invoke Set-Service -ModuleName Capsulenv -Times 0 -Exactly
    }

    It 'preserves unscoped legacy ssh-agent evidence and refuses automatic restore' {
        $legacyService = & $script:Module { Join-Path (Get-CapsulenvContext).StateRoot 'bitwarden\ssh-agent-service.json' }
        New-Item -ItemType Directory -Path (Split-Path -Parent $legacyService) -Force | Out-Null
        '{"legacy":true}' | Set-Content -LiteralPath $legacyService -Encoding UTF8
        $global:CapsulenvBitwardenDiagnostics = @()
        Mock Write-CapsulenvMessage { param($Message) $global:CapsulenvBitwardenDiagnostics += [string]$Message } -ModuleName Capsulenv

        { Restore-CapsulenvWindowsSshAgent -Confirm:$false } | Should -Throw '*stale or unscoped evidence cannot authorize restore*'

        Get-Content -LiteralPath $legacyService -Raw | Should -Be ([string]::Concat('{"legacy":true}', [Environment]::NewLine))
        ($global:CapsulenvBitwardenDiagnostics -join [Environment]::NewLine) | Should -Match 'Legacy unscoped Bitwarden backup preserved'
    }

    It 'keeps Bitwarden desktop and Git state capsule-wide while ssh-agent service state is host-scoped' {
        $desktop = & $script:Module { Get-CapsulenvBitwardenDesktopSettingsBackupPath }
        $git = & $script:Module { Get-CapsulenvGitConfigBackupPath }
        $service = & $script:Module { Get-CapsulenvSshAgentServiceStatePath }

        $desktop | Should -Not -Match 'user-integrations'
        $git | Should -Not -Match 'user-integrations'
        $service | Should -Match 'user-integrations'
    }

    It 'preserves unrelated Bitwarden desktop state through capsule-wide setup and restore' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime persistent
        $statePath = Join-Path $script:Fixture 'bitwarden/data.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force | Out-Null
        '{"unrelated":"keep-me","nested":{"global_desktopSettings_sshAgentEnabled":false},"global_desktopSettings_sshAgentEnabled":false,"user_12345678-1234-1234-1234-123456789abc_desktopSettings_sshAgentRememberAuthorizations":"always"}' | Set-Content -LiteralPath $statePath -Encoding UTF8
        Mock Get-CapsulenvBitwardenExecutable { 'C:\capsule\Bitwarden.exe' } -ModuleName Capsulenv
        Mock Stop-CapsulenvBitwarden {} -ModuleName Capsulenv
        Mock Start-CapsulenvBitwarden {} -ModuleName Capsulenv
        Mock Set-CapsulenvSessionEnvironment {} -ModuleName Capsulenv
        Mock Repair-CapsulenvInstalledAppProjections {} -ModuleName Capsulenv
        Mock Get-CapsulenvBitwardenStatePath { $statePath } -ModuleName Capsulenv

        & $script:Module { Set-CapsulenvBitwardenDesktopSshAgent -Authorization remember-until-lock -NoStart }

        $enabled = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $enabled.global_desktopSettings_sshAgentEnabled | Should -BeTrue
        [string]$enabled.unrelated | Should -Be 'keep-me'
        $desktopBackup = & $script:Module { Get-CapsulenvBitwardenDesktopSettingsBackupPath }
        Test-Path -LiteralPath $desktopBackup -PathType Leaf | Should -BeTrue

        & $script:Module { Restore-CapsulenvBitwardenDesktopSettings -NoStart }

        $restored = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $restored.global_desktopSettings_sshAgentEnabled | Should -BeFalse
        [string]$restored.unrelated | Should -Be 'keep-me'
        Test-Path -LiteralPath $desktopBackup -PathType Leaf | Should -BeFalse
    }

    It 'does not treat stale host-local environment and service recovery evidence as ownership after host reimage' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime persistent
        & $script:Module { Set-CapsulenvInstallMode -Mode User }
        & $script:WriteTestEnvironmentOwnership ([ordered]@{}) @{} @()
        $servicePath = & $script:Module { Get-CapsulenvSshAgentServiceStatePath }
        & $script:WriteTestBitwardenHostBackup $servicePath ([ordered]@{ Status = 'Stopped'; StartMode = 'Manual' })

        Remove-Item -LiteralPath $env:CAPSULENV_HOST_STATE_ROOT -Recurse -Force
        Mock Test-CapsulenvCurrentUserIntegrationOwnership { $false } -ModuleName Capsulenv
        Mock Get-Service { [pscustomobject]@{ Status = 'Stopped' } } -ModuleName Capsulenv
        Mock Get-CimInstance { [pscustomobject]@{ StartMode = 'Manual' } } -ModuleName Capsulenv

        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        $surfaces = & $script:Module { @(Get-CapsulenvPersistentUserIntegrationSurfaces) }
        $surfaces | Should -Not -Contain 'environment-ledger'
        $surfaces | Should -Not -Contain 'environment-backup'
        $surfaces | Should -Not -Contain 'windows-ssh-agent-service'

        Start-CapsulenvUserIntegrationLease | Out-Null
        Stop-CapsulenvUserIntegrationLease
        Test-Path -LiteralPath $servicePath -PathType Leaf | Should -BeTrue
    }

    It 'binds persistent Git to the portable target and restores complete multi-value state despite process target drift' {
        $gitCommand = @(Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($gitCommand.Count -eq 0) { $gitCommand = @(Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1) }
        $global:CapsulenvTestGitCommand = [string]$gitCommand[0].Source
        $target = & $script:Module { Get-CapsulenvPortableGitConfigTarget }
        $otherTarget = Join-Path $script:Fixture 'other.gitconfig'
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        & $global:CapsulenvTestGitCommand config --file $target --add core.sshCommand 'before-a'
        & $global:CapsulenvTestGitCommand config --file $target --add core.sshCommand 'before-b'
        & $global:CapsulenvTestGitCommand config --file $target --add gpg.ssh.program 'before-keygen'
        & $global:CapsulenvTestGitCommand config --file $otherTarget --add core.sshCommand 'other-target'

        Set-CapsulenvUserIntegrationLifetime -Lifetime persistent
        $env:CAPSULENV_MODE = 'User'
        Mock Get-CapsulenvGitCommand { $global:CapsulenvTestGitCommand } -ModuleName Capsulenv
        Mock Get-CapsulenvGitOpenSshPaths { [pscustomobject]@{ Ssh = 'C:/capsule/OpenSSH/ssh.exe'; SshKeygen = 'C:/capsule/OpenSSH/ssh-keygen.exe' } } -ModuleName Capsulenv

        Set-CapsulenvGitOpenSsh

        $backupPath = & $script:Module { Get-CapsulenvGitConfigBackupPath }
        $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
        @($backup.Values.'core.sshCommand'.Values) | Should -Be @('before-a','before-b')
        @(& $global:CapsulenvTestGitCommand config --file $target --get-all core.sshCommand) | Should -Be @('C:/capsule/OpenSSH/ssh.exe')

        $oldGitConfigGlobal = $env:GIT_CONFIG_GLOBAL
        try {
            $env:GIT_CONFIG_GLOBAL = $otherTarget
            & $script:Module { Restore-CapsulenvGitOpenSshGlobal } | Should -BeTrue
        } finally {
            $env:GIT_CONFIG_GLOBAL = $oldGitConfigGlobal
        }

        @(& $global:CapsulenvTestGitCommand config --file $target --get-all core.sshCommand) | Should -Be @('before-a','before-b')
        (& $global:CapsulenvTestGitCommand config --file $target --get gpg.ssh.program) | Should -Be 'before-keygen'
        (& $global:CapsulenvTestGitCommand config --file $otherTarget --get core.sshCommand) | Should -Be 'other-target'
        Test-Path -LiteralPath $backupPath -PathType Leaf | Should -BeFalse
        Remove-Variable CapsulenvTestGitCommand -Scope Global -ErrorAction SilentlyContinue
    }

    It 'restores a partially applied portable Git mutation without overwriting unrelated config' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime persistent
        $env:CAPSULENV_MODE = 'User'
        $backupPath = & $script:WriteTestGitPortableBackup ([pscustomobject][ordered]@{
            'core.sshCommand' = [pscustomobject]@{ Exists = $true; Values = [string[]]@('before-ssh') }
            'gpg.ssh.program' = [pscustomobject]@{ Exists = $true; Values = [string[]]@('before-keygen') }
        }) ([pscustomobject][ordered]@{
            'core.sshCommand' = [string[]]@('C:/Windows/System32/OpenSSH/ssh.exe')
            'gpg.ssh.program' = [string[]]@('C:/Windows/System32/OpenSSH/ssh-keygen.exe')
        })

        Mock Get-CapsulenvGitCommand { 'git.exe' } -ModuleName Capsulenv
        Mock Get-CapsulenvGitOpenSshGlobalValues {
            [pscustomobject][ordered]@{
                'core.sshCommand' = [pscustomobject]@{ Exists = $true; Values = [string[]]@('C:/Windows/System32/OpenSSH/ssh.exe') }
                'gpg.ssh.program' = [pscustomobject]@{ Exists = $true; Values = [string[]]@('before-keygen') }
            }
        } -ModuleName Capsulenv
        Mock Restore-CapsulenvGitValues {} -ModuleName Capsulenv

        (& $script:Module { Restore-CapsulenvGitOpenSshGlobal }) | Should -BeTrue

        Should -Invoke Restore-CapsulenvGitValues -ModuleName Capsulenv -Times 1 -Exactly
        Test-Path -LiteralPath $backupPath -PathType Leaf | Should -BeFalse
    }

    It 'refuses portable Git restore when any tracked key has an extra concurrent value' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime persistent
        $env:CAPSULENV_MODE = 'User'
        $backupPath = & $script:WriteTestGitPortableBackup ([pscustomobject][ordered]@{
            'core.sshCommand' = [pscustomobject]@{ Exists = $true; Values = [string[]]@('before-ssh') }
            'gpg.ssh.program' = [pscustomobject]@{ Exists = $true; Values = [string[]]@('before-keygen') }
        }) ([pscustomobject][ordered]@{
            'core.sshCommand' = [string[]]@('C:/Windows/System32/OpenSSH/ssh.exe')
            'gpg.ssh.program' = [string[]]@('C:/Windows/System32/OpenSSH/ssh-keygen.exe')
        })

        Mock Get-CapsulenvGitCommand { 'git.exe' } -ModuleName Capsulenv
        Mock Get-CapsulenvGitOpenSshGlobalValues {
            [pscustomobject][ordered]@{
                'core.sshCommand' = [pscustomobject]@{ Exists = $true; Values = [string[]]@('C:/Windows/System32/OpenSSH/ssh.exe') }
                'gpg.ssh.program' = [pscustomobject]@{ Exists = $true; Values = [string[]]@('C:/Windows/System32/OpenSSH/ssh-keygen.exe','third-party-keygen') }
            }
        } -ModuleName Capsulenv
        Mock Restore-CapsulenvGitValues {} -ModuleName Capsulenv

        { & $script:Module { Restore-CapsulenvGitOpenSshGlobal } } | Should -Throw '*changed after Capsulenv applied*'

        Should -Invoke Restore-CapsulenvGitValues -ModuleName Capsulenv -Times 0 -Exactly
        Test-Path -LiteralPath $backupPath -PathType Leaf | Should -BeTrue
    }

    It 'keeps ssh-agent ownership fail-closed when only the host-local marker is lost' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime persistent
        $env:CAPSULENV_MODE = 'User'
        $statePath = & $script:Module { Get-CapsulenvSshAgentServiceStatePath }
        & $script:WriteTestBitwardenHostBackup $statePath ([ordered]@{ Status = 'Running'; StartMode = 'Manual' })
        & $script:Module { Remove-CapsulenvPersistentUserIntegrationMarker -Surface 'windows-ssh-agent-service' }
        Mock Get-Service { [pscustomobject]@{ Status = 'Stopped' } } -ModuleName Capsulenv
        Mock Get-CimInstance { [pscustomobject]@{ StartMode = 'Disabled' } } -ModuleName Capsulenv

        $status = Get-CapsulenvUserIntegrationStatus

        $status.OwnedUserIntegration | Should -Be persistent
        @($status.PersistentOwnedSurfaces) | Should -Contain 'windows-ssh-agent-service'
        { Set-CapsulenvUserIntegrationLifetime -Lifetime isolated } | Should -Throw '*windows-ssh-agent-service*'
        { Disable-CapsulenvWindowsSshAgent -Confirm:$false } | Should -Throw '*marker is missing*'
        Test-Path -LiteralPath $statePath -PathType Leaf | Should -BeTrue
    }

    It 'archives stale ssh-agent recovery evidence and snapshots the fresh service state before persistent reapply' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime persistent
        $env:CAPSULENV_MODE = 'User'
        $statePath = & $script:Module { Get-CapsulenvSshAgentServiceStatePath }
        $stale = & $script:Module {
            New-CapsulenvBitwardenHostBackup -Values ([ordered]@{ Status = 'Running'; StartMode = 'Auto' }) -Applied ([ordered]@{ Status = 'Stopped'; StartMode = 'Disabled' })
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force | Out-Null
        $stale | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8

        $global:CapsulenvTestServiceStatus = 'Running'
        $global:CapsulenvTestServiceStartMode = 'Auto'
        Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
        Mock Get-Service { [pscustomobject]@{ Status = $global:CapsulenvTestServiceStatus } } -ModuleName Capsulenv
        Mock Get-CimInstance { [pscustomobject]@{ StartMode = $global:CapsulenvTestServiceStartMode } } -ModuleName Capsulenv
        Mock Stop-Service { $global:CapsulenvTestServiceStatus = 'Stopped' } -ModuleName Capsulenv
        Mock Start-Service { $global:CapsulenvTestServiceStatus = 'Running' } -ModuleName Capsulenv
        Mock Set-Service {
            param($Name, $StartupType)
            $global:CapsulenvTestServiceStartMode = if ([string]$StartupType -eq 'Automatic') { 'Auto' } else { [string]$StartupType }
        } -ModuleName Capsulenv

        Disable-CapsulenvWindowsSshAgent -Confirm:$false

        $fresh = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        [string]$fresh.Values.Status | Should -Be 'Running'
        [string]$fresh.Values.StartMode | Should -Be 'Auto'
        @(Get-ChildItem -LiteralPath (Join-Path (Split-Path -Parent $statePath) 'recovery') -Filter 'ssh-agent-service.stale.*.json' -File).Count | Should -Be 1
        $global:CapsulenvTestServiceStatus | Should -Be 'Stopped'
        $global:CapsulenvTestServiceStartMode | Should -Be 'Disabled'
        (& $script:Module { Test-CapsulenvPersistentUserIntegrationMarker -Surface 'windows-ssh-agent-service' }) | Should -BeTrue

        Restore-CapsulenvWindowsSshAgent -Confirm:$false

        $global:CapsulenvTestServiceStatus | Should -Be 'Running'
        $global:CapsulenvTestServiceStartMode | Should -Be 'Auto'
        Test-Path -LiteralPath $statePath -PathType Leaf | Should -BeFalse
        (& $script:Module { Test-CapsulenvPersistentUserIntegrationMarker -Surface 'windows-ssh-agent-service' }) | Should -BeFalse
        Remove-Variable CapsulenvTestServiceStatus -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable CapsulenvTestServiceStartMode -Scope Global -ErrorAction SilentlyContinue
    }

    It 'refuses ssh-agent reapply when marker is missing and live state is ambiguous' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime persistent
        $env:CAPSULENV_MODE = 'User'
        $statePath = & $script:Module { Get-CapsulenvSshAgentServiceStatePath }
        $record = & $script:Module {
            New-CapsulenvBitwardenHostBackup -Values ([ordered]@{ Status = 'Stopped'; StartMode = 'Manual' }) -Applied ([ordered]@{ Status = 'Stopped'; StartMode = 'Disabled' })
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force | Out-Null
        $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8

        Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } } -ModuleName Capsulenv
        Mock Get-CimInstance { [pscustomobject]@{ StartMode = 'Auto' } } -ModuleName Capsulenv
        Mock Stop-Service {} -ModuleName Capsulenv
        Mock Set-Service {} -ModuleName Capsulenv

        { Disable-CapsulenvWindowsSshAgent -Confirm:$false } | Should -Throw '*active or ambiguous*'

        Should -Invoke Stop-Service -ModuleName Capsulenv -Times 0 -Exactly
        Should -Invoke Set-Service -ModuleName Capsulenv -Times 0 -Exactly
        Test-Path -LiteralPath $statePath -PathType Leaf | Should -BeTrue
    }

    It 'restores a partially applied ssh-agent mutation without overwriting unrelated state' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime persistent
        $env:CAPSULENV_MODE = 'User'
        $statePath = & $script:Module { Get-CapsulenvSshAgentServiceStatePath }
        & $script:WriteTestBitwardenHostBackup $statePath ([ordered]@{ Status = 'Running'; StartMode = 'Auto' })

        $global:CapsulenvTestServiceStatus = 'Stopped'
        $global:CapsulenvTestServiceStartMode = 'Auto'
        Mock Get-Service { [pscustomobject]@{ Status = $global:CapsulenvTestServiceStatus } } -ModuleName Capsulenv
        Mock Get-CimInstance { [pscustomobject]@{ StartMode = $global:CapsulenvTestServiceStartMode } } -ModuleName Capsulenv
        Mock Start-Service { $global:CapsulenvTestServiceStatus = 'Running' } -ModuleName Capsulenv
        Mock Stop-Service { $global:CapsulenvTestServiceStatus = 'Stopped' } -ModuleName Capsulenv
        Mock Set-Service {
            param($Name, $StartupType)
            $global:CapsulenvTestServiceStartMode = if ([string]$StartupType -eq 'Automatic') { 'Auto' } else { [string]$StartupType }
        } -ModuleName Capsulenv

        Restore-CapsulenvWindowsSshAgent -Confirm:$false

        $global:CapsulenvTestServiceStatus | Should -Be 'Running'
        $global:CapsulenvTestServiceStartMode | Should -Be 'Auto'
        Should -Invoke Start-Service -ModuleName Capsulenv -Times 1 -Exactly
        Should -Invoke Set-Service -ModuleName Capsulenv -Times 0 -Exactly
        Test-Path -LiteralPath $statePath -PathType Leaf | Should -BeFalse
        (& $script:Module { Test-CapsulenvPersistentUserIntegrationMarker -Surface 'windows-ssh-agent-service' }) | Should -BeFalse
        Remove-Variable CapsulenvTestServiceStatus -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable CapsulenvTestServiceStartMode -Scope Global -ErrorAction SilentlyContinue
    }

    It 'preserves persistent ownership through ordinary eject' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime persistent
        & $script:Module {
            Set-CapsulenvInstallMode -Mode User
            [void](Write-CapsulenvPersistentUserIntegrationMarker -Surface environment)
        }
        Mock Set-CapsulenvSessionEnvironment {} -ModuleName Capsulenv
        Mock Invoke-CapsulenvRoutines {} -ModuleName Capsulenv
        Mock Stop-CapsulenvActiveSessionServices {} -ModuleName Capsulenv
        Mock Get-CapsulenvDirtyRepositories { @() } -ModuleName Capsulenv
        Mock Stop-CapsulenvOwnedProcesses { @() } -ModuleName Capsulenv
        Mock Get-CapsulenvOwnedProcesses { @() } -ModuleName Capsulenv
        Mock Get-CapsulenvActiveExclusiveStateLeases { @() } -ModuleName Capsulenv
        Mock Write-CapsulenvEjectState { '/fake/eject.json' } -ModuleName Capsulenv
        Mock Get-CapsulenvScratchPath { '/fake/absent-scratch' } -ModuleName Capsulenv
        Invoke-CapsulenvEject | Out-Null
        (Get-CapsulenvUserIntegrationStatus).OwnedUserIntegration | Should -Be persistent
        Get-CapsulenvUserIntegrationLifetime | Should -Be persistent
    }

    It 'releases leased environment through eject' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        Start-CapsulenvUserIntegrationLease | Out-Null
        Mock Set-CapsulenvSessionEnvironment {} -ModuleName Capsulenv
        Mock Invoke-CapsulenvRoutines {} -ModuleName Capsulenv
        Mock Stop-CapsulenvActiveSessionServices {} -ModuleName Capsulenv
        Mock Get-CapsulenvDirtyRepositories { @() } -ModuleName Capsulenv
        Mock Stop-CapsulenvOwnedProcesses { @() } -ModuleName Capsulenv
        Mock Get-CapsulenvOwnedProcesses { @() } -ModuleName Capsulenv
        Mock Get-CapsulenvActiveExclusiveStateLeases { @() } -ModuleName Capsulenv
        Mock Write-CapsulenvEjectState { '/fake/eject.json' } -ModuleName Capsulenv
        Mock Get-CapsulenvScratchPath { '/fake/absent-scratch' } -ModuleName Capsulenv
        Invoke-CapsulenvEject | Out-Null
        $global:CapsulenvLeaseTestEnv.SCOOP | Should -Be foreign-scoop
        (Get-CapsulenvUserIntegrationStatus).OwnedUserIntegration | Should -Be none
    }

    It 'routes restore-user to lease recovery rather than persistent snapshot replay' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        Start-CapsulenvUserIntegrationLease | Out-Null
        Restore-CapsulenvUserEnvironment
        $global:CapsulenvLeaseTestEnv.SCOOP | Should -Be foreign-scoop
    }

    It 'blocks release before modifying environment when browser UserChoice requires Settings' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        Start-CapsulenvUserIntegrationLease | Out-Null
        Mock Get-CapsulenvDefaultBrowserState { [pscustomobject]@{ UrlProgId='owned.URL'; HtmlProgId='owned.HTML' } } -ModuleName Capsulenv
        Mock Assert-CapsulenvDefaultBrowserRestorable { throw 'Choose another default browser in Windows Settings; UserChoice hashes cannot be replayed.' } -ModuleName Capsulenv
        { Stop-CapsulenvUserIntegrationLease } | Should -Throw '*Windows Settings*'
        $global:CapsulenvLeaseTestEnv.SCOOP | Should -Be capsule-scoop
        $status = Get-CapsulenvUserIntegrationStatus
        $status.IntegrationLease | Should -Be Blocked
        $status.IntegrationDiagnostic | Should -Match UserChoice
    }

    It 'blocks release when browser registration changed concurrently' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        Start-CapsulenvUserIntegrationLease | Out-Null
        Mock Get-CapsulenvDefaultBrowserState { [pscustomobject]@{ UrlProgId='owned.URL'; HtmlProgId='owned.HTML' } } -ModuleName Capsulenv
        Mock Assert-CapsulenvDefaultBrowserRestorable {} -ModuleName Capsulenv
        Mock Test-CapsulenvOwnedBrowserRegistrationAbsent { $false } -ModuleName Capsulenv
        Mock Get-CapsulenvOwnedBrowserRegistrationSnapshot { [pscustomobject]@{ Client = 'concurrent' } } -ModuleName Capsulenv
        { Stop-CapsulenvUserIntegrationLease } | Should -Throw '*Browser registration changed*'
        $global:CapsulenvLeaseTestEnv.SCOOP | Should -Be capsule-scoop
    }

    It 'releases a stale leased browser after reset removed all host-owned browser surfaces' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        Start-CapsulenvUserIntegrationLease | Out-Null
        & $script:Module {
            $state = [ordered]@{
                SchemaVersion = 2
                CapsuleId = Get-CapsulenvIdentity
                HostIntegrationKey = Get-CapsulenvHostIntegrationKey
                App = 'firefox'
                RegisteredName = 'Capsulenv Firefox (reset)'
                ClientPath = 'Software\Clients\StartMenuInternet\Capsulenv.Reset'
                UrlClassPath = 'Software\Classes\Capsulenv.Reset.URL'
                HtmlClassPath = 'Software\Classes\Capsulenv.Reset.HTML'
                UrlProgId = 'Capsulenv.Reset.URL'
                HtmlProgId = 'Capsulenv.Reset.HTML'
                PreviousRegisteredApplication = [ordered]@{ Exists = $true; Value = 'Software\Previous\Capabilities' }
                CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
            }
            Write-CapsulenvDefaultBrowserState -State $state
            $lease = Get-CapsulenvUserIntegrationLease
            $lease.BrowserSnapshot = [pscustomobject]@{ Client = 'previous-host-registration' }
            Write-CapsulenvHostJsonAtomically -Path (Get-CapsulenvUserIntegrationLeasePath) -Value $lease
        }
        Mock Assert-CapsulenvDefaultBrowserRestorable {} -ModuleName Capsulenv
        Mock Test-CapsulenvOwnedBrowserRegistrationAbsent { $true } -ModuleName Capsulenv
        Mock Restore-CapsulenvDefaultBrowserRegistration { throw 'reset host must not replay prior-host browser registration' } -ModuleName Capsulenv

        Stop-CapsulenvUserIntegrationLease

        $global:CapsulenvLeaseTestEnv.SCOOP | Should -Be foreign-scoop
        (Get-CapsulenvUserIntegrationStatus).OwnedUserIntegration | Should -Be none
        (& $script:Module { Test-Path -LiteralPath (Get-CapsulenvDefaultBrowserStatePath) -PathType Leaf }) | Should -BeFalse
        Should -Invoke Restore-CapsulenvDefaultBrowserRegistration -ModuleName Capsulenv -Times 0 -Exactly
    }

    It 'keeps explicit persistent integration representable on ephemeral placement' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime persistent
        $bridge = New-CapsulenvUserIntegrationBridge -CapsuleId (& $script:Module { Get-CapsulenvIdentity }) -BrowserApp 'scoop/firefox'
        $bridge.Persistent | Should -BeTrue
        $bridge.BrowserStateIdentity | Should -Be firefox
        (Get-CapsulenvUserIntegrationStatus).PlacementRetention | Should -Be ephemeral
    }

    It 'publishes a lease-bound browser bridge before registration on an ephemeral host' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        Mock Get-CapsulenvConfiguredDefaultBrowser { 'scoop/firefox' } -ModuleName Capsulenv
        Mock Install-CapsulenvDefaultBrowserRegistration {
            param($App)
            $bridge = Get-CapsulenvUserIntegrationBridge -CapsuleId (Get-CapsulenvIdentity)
            if ($null -eq $bridge -or $bridge.LeaseId -ne $env:CAPSULENV_USER_LEASE_ID) { throw 'bridge must be published first' }
        } -ModuleName Capsulenv
        $lease = Start-CapsulenvUserIntegrationLease
        $bridge = Get-CapsulenvUserIntegrationBridge -CapsuleId (& $script:Module { Get-CapsulenvIdentity })
        $bridge.Persistent | Should -BeFalse
        $bridge.LeaseId | Should -Be $lease.LeaseId
        $bridge.BrowserStateIdentity | Should -Be firefox
        $lease.BridgeSnapshot.Count | Should -Be 3
        Should -Invoke Install-CapsulenvDefaultBrowserRegistration -ModuleName Capsulenv -Times 1 -Exactly
        { New-CapsulenvUserIntegrationBridge -CapsuleId $bridge.CapsuleId -BrowserApp firefox } | Should -Throw '*lease is stale, incomplete*'
        Stop-CapsulenvUserIntegrationLease
        Test-Path (Split-Path $bridge.BridgePath) | Should -BeFalse
    }

    It 'blocks release when a bridge file changed concurrently' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        Mock Get-CapsulenvConfiguredDefaultBrowser { 'firefox' } -ModuleName Capsulenv
        Mock Install-CapsulenvDefaultBrowserRegistration {} -ModuleName Capsulenv
        Start-CapsulenvUserIntegrationLease | Out-Null
        $bridge = Get-CapsulenvUserIntegrationBridge -CapsuleId (& $script:Module { Get-CapsulenvIdentity })
        Add-Content -LiteralPath $bridge.BridgePath -Value '# concurrent change'
        { Stop-CapsulenvUserIntegrationLease } | Should -Throw '*Bridge changed concurrently*'
        Test-Path $bridge.BridgePath | Should -BeTrue
        $global:CapsulenvLeaseTestEnv.SCOOP | Should -Be capsule-scoop
    }

    It 'preserves unrelated hidden bridge files added during a lease' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        Mock Get-CapsulenvConfiguredDefaultBrowser { 'firefox' } -ModuleName Capsulenv
        Mock Install-CapsulenvDefaultBrowserRegistration {} -ModuleName Capsulenv
        Start-CapsulenvUserIntegrationLease | Out-Null
        $bridge = Get-CapsulenvUserIntegrationBridge -CapsuleId (& $script:Module { Get-CapsulenvIdentity })
        $extra = Join-Path (Split-Path $bridge.BridgePath) '.concurrent-user-file'
        Set-Content -LiteralPath $extra -Value 'user-owned'
        { Stop-CapsulenvUserIntegrationLease } | Should -Throw '*Bridge ownership*'
        Get-Content -LiteralPath $extra | Should -Be user-owned
        $global:CapsulenvLeaseTestEnv.SCOOP | Should -Be capsule-scoop
    }

    It 'restores capsule-wide Bitwarden desktop ownership before publishing isolated lifetime' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime persistent
        & $script:Module { Set-CapsulenvInstallMode -Mode User }
        & $script:WriteTestEnvironmentOwnership ([ordered]@{}) @{} @()
        $desktopBackup = & $script:Module { Get-CapsulenvBitwardenDesktopSettingsBackupPath }
        New-Item -ItemType Directory -Path (Split-Path -Parent $desktopBackup) -Force | Out-Null
        '{"SchemaVersion":1,"Entries":[]}' | Set-Content -LiteralPath $desktopBackup -Encoding UTF8

        Mock Test-CapsulenvCurrentUserIntegrationOwnership { $true } -ModuleName Capsulenv
        Mock Restore-CapsulenvBitwardenDesktopSettings {
            Remove-Item -LiteralPath $desktopBackup -Force
        } -ModuleName Capsulenv
        Mock Remove-CapsulenvUserStartMenuShortcuts {} -ModuleName Capsulenv
        Mock Remove-CapsulenvUserIntegrationBridge { $true } -ModuleName Capsulenv
        Mock Initialize-CapsulenvGitOpenSshSession {} -ModuleName Capsulenv

        Restore-CapsulenvUserEnvironment

        Should -Invoke Restore-CapsulenvBitwardenDesktopSettings -ModuleName Capsulenv -Times 1 -Exactly
        Test-Path -LiteralPath $desktopBackup -PathType Leaf | Should -BeFalse
        Get-CapsulenvUserIntegrationLifetime | Should -Be isolated
        (Get-CapsulenvUserIntegrationStatus).OwnedUserIntegration | Should -Be none
        (& $script:Module { Test-Path -LiteralPath (Get-CapsulenvPersistentUserIntegrationMarkerPath -Surface environment) }) | Should -BeFalse
    }

    It 'restores legacy persistent ownership through the supported explicit path' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime persistent
        & $script:Module {
            Set-CapsulenvInstallMode -Mode User
            Write-CapsulenvUserEnvironmentBackup -Path (Get-CapsulenvUserEnvironmentBackupPath) -Backup ([ordered]@{})
        }
        Mock Get-CapsulenvSshAgentServiceStatePath { '/fake/absent-service-state' } -ModuleName Capsulenv
        Mock Assert-CapsulenvDefaultBrowserRestorable {} -ModuleName Capsulenv
        Mock Restore-CapsulenvGitOpenSshGlobal {} -ModuleName Capsulenv
        Mock Restore-CapsulenvDefaultBrowserRegistration {} -ModuleName Capsulenv
        Mock Remove-CapsulenvUserStartMenuShortcuts {} -ModuleName Capsulenv
        Mock Initialize-CapsulenvGitOpenSshSession {} -ModuleName Capsulenv
        Restore-CapsulenvUserEnvironment
        (Get-CapsulenvUserIntegrationStatus).OwnedUserIntegration | Should -Be none
        Get-CapsulenvUserIntegrationLifetime | Should -Be isolated
        (& $script:Module { Test-Path (Get-CapsulenvUserEnvironmentBackupPath) }) | Should -BeFalse
    }

    It 'does not refresh the original environment backup while current-host ownership marker survives' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime persistent
        & $script:Module { Set-CapsulenvInstallMode -Mode User }
        & $script:WriteTestEnvironmentOwnership ([ordered]@{
            SCOOP = [ordered]@{ Exists = $true; Value = 'original-scoop' }
            PATH = [ordered]@{ Exists = $true; Value = '/user/bin' }
        }) @{ SCOOP = 'capsule-scoop' } @('/capsule/bin')
        Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
        Mock Get-CapsulenvUserIntegrationMode { 'ShellOnly' } -ModuleName Capsulenv
        Mock Test-CapsulenvCurrentUserIntegrationOwnership { $false } -ModuleName Capsulenv
        Mock Set-CapsulenvSessionEnvironment { throw 'session setup must not be reached' } -ModuleName Capsulenv

        { Install-CapsulenvUserEnvironment } | Should -Throw '*ownership is still active*'

        Should -Invoke Set-CapsulenvSessionEnvironment -ModuleName Capsulenv -Times 0 -Exactly
        $backup = & $script:Module { Get-Content -LiteralPath (Get-CapsulenvUserEnvironmentBackupPath) -Raw | ConvertFrom-Json }
        [string]$backup.SCOOP.Value | Should -Be 'original-scoop'
    }

    It 'restores persistent environment while preserving concurrent PATH additions' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime persistent
        & $script:Module { Set-CapsulenvInstallMode -Mode User }
        & $script:WriteTestEnvironmentOwnership ([ordered]@{
            SCOOP = [ordered]@{ Exists = $true; Value = 'foreign-scoop' }
            PATH = [ordered]@{ Exists = $true; Value = '/user/bin' }
        }) @{ SCOOP = 'capsule-scoop' } @('/capsule/bin')
        $global:CapsulenvLeaseTestEnv.SCOOP = 'capsule-scoop'
        $global:CapsulenvLeaseTestEnv.PATH = '/capsule/bin;/user/bin;/third-party/bin'
        Mock Remove-CapsulenvUserStartMenuShortcuts {} -ModuleName Capsulenv
        Mock Remove-CapsulenvUserIntegrationBridge { $true } -ModuleName Capsulenv
        Mock Initialize-CapsulenvGitOpenSshSession {} -ModuleName Capsulenv

        Restore-CapsulenvUserEnvironment

        $global:CapsulenvLeaseTestEnv.SCOOP | Should -Be 'foreign-scoop'
        $global:CapsulenvLeaseTestEnv.PATH | Should -Be '/user/bin;/third-party/bin'
        Get-CapsulenvUserIntegrationLifetime | Should -Be isolated
    }

    It 'refuses persistent environment restore when a scalar was changed concurrently' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime persistent
        & $script:Module { Set-CapsulenvInstallMode -Mode User }
        & $script:WriteTestEnvironmentOwnership ([ordered]@{
            SCOOP = [ordered]@{ Exists = $true; Value = 'foreign-scoop' }
            PATH = [ordered]@{ Exists = $true; Value = '/user/bin' }
        }) @{ SCOOP = 'capsule-scoop' } @('/capsule/bin')
        $global:CapsulenvLeaseTestEnv.SCOOP = 'third-party-scoop'
        $global:CapsulenvLeaseTestEnv.PATH = '/capsule/bin;/user/bin'
        Mock Restore-CapsulenvBitwardenDesktopSettings { throw 'other surfaces must not be reached' } -ModuleName Capsulenv

        { Restore-CapsulenvUserEnvironment } | Should -Throw '*changed after Capsulenv applied*'

        $global:CapsulenvLeaseTestEnv.SCOOP | Should -Be 'third-party-scoop'
        (& $script:Module { Test-Path -LiteralPath (Get-CapsulenvUserEnvironmentBackupPath) -PathType Leaf }) | Should -BeTrue
        (& $script:Module { Test-Path -LiteralPath (Get-CapsulenvPersistentUserIntegrationMarkerPath -Surface environment) -PathType Leaf }) | Should -BeTrue
    }

    It 'restores independently acquired Bitwarden desktop ownership without an environment backup' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime persistent
        $desktopBackup = & $script:Module { Get-CapsulenvBitwardenDesktopSettingsBackupPath }
        New-Item -ItemType Directory -Path (Split-Path -Parent $desktopBackup) -Force | Out-Null
        '{"SchemaVersion":1,"Entries":[]}' | Set-Content -LiteralPath $desktopBackup -Encoding UTF8
        Mock Restore-CapsulenvBitwardenDesktopSettings { Remove-Item -LiteralPath $desktopBackup -Force } -ModuleName Capsulenv
        Mock Remove-CapsulenvUserStartMenuShortcuts {} -ModuleName Capsulenv
        Mock Remove-CapsulenvUserIntegrationBridge { $true } -ModuleName Capsulenv
        Mock Initialize-CapsulenvGitOpenSshSession {} -ModuleName Capsulenv

        Restore-CapsulenvUserEnvironment

        Should -Invoke Restore-CapsulenvBitwardenDesktopSettings -ModuleName Capsulenv -Times 1 -Exactly
        Get-CapsulenvUserIntegrationLifetime | Should -Be isolated
        (Get-CapsulenvUserIntegrationStatus).OwnedUserIntegration | Should -Be none
    }

    It 'retains the missing-original-backup safety check for untracked User environment residue' {
        Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
        Mock Test-CapsulenvCurrentUserIntegrationOwnership { $true } -ModuleName Capsulenv
        Mock Set-CapsulenvSessionEnvironment { throw 'User mutation must not be reached' } -ModuleName Capsulenv
        { Install-CapsulenvUserEnvironment } | Should -Throw '*reversible environment backup is missing*'
        Should -Invoke Set-CapsulenvSessionEnvironment -ModuleName Capsulenv -Times 0 -Exactly
        Get-CapsulenvUserIntegrationLifetime | Should -Be isolated
    }

    It 'rolls requested lifetime back when ownership marker publication fails before host mutation' {
        Mock Test-CapsulenvWindows { $false } -ModuleName Capsulenv
        Mock Set-CapsulenvSessionEnvironment {
            [pscustomobject]@{
                Variables = @{ SCOOP = 'capsule-scoop' }
                PathEntries = @('/capsule/bin')
                ToolStorage = [pscustomobject]@{ Enabled = $false; CreateDirectories = $false }
                SessionDirectories = @()
                ModulePathEntries = @()
            }
        } -ModuleName Capsulenv
        Mock Initialize-CapsulenvScoopBootstrap {} -ModuleName Capsulenv
        Mock Test-CapsulenvScoopRehydrationRequired { $false } -ModuleName Capsulenv
        Mock Get-CapsulenvScoopPathEnvironmentVariable { 'PATH' } -ModuleName Capsulenv
        Mock Test-CapsulenvGitOpenSshSessionConfigured { $false } -ModuleName Capsulenv
        Mock Write-CapsulenvPersistentUserIntegrationMarker { throw 'injected marker publication failure' } -ModuleName Capsulenv
        Mock Sync-CapsulenvUserEnvironment { throw 'host mutation must not be reached' } -ModuleName Capsulenv

        { Install-CapsulenvUserEnvironment } | Should -Throw '*injected marker publication failure*'

        Get-CapsulenvUserIntegrationLifetime | Should -Be isolated
        (& $script:Module { Test-Path -LiteralPath (Get-CapsulenvUserEnvironmentBackupPath) -PathType Leaf }) | Should -BeTrue
        Should -Invoke Sync-CapsulenvUserEnvironment -ModuleName Capsulenv -Times 0 -Exactly
    }

    It 'keeps persistent authority when failure occurs after rollback evidence is committed' {
        Mock Test-CapsulenvWindows { $false } -ModuleName Capsulenv
        Mock Set-CapsulenvSessionEnvironment {
            [pscustomobject]@{
                Variables = @{ SCOOP = 'capsule-scoop' }
                PathEntries = @('/capsule/bin')
                ToolStorage = [pscustomobject]@{ Enabled = $false; CreateDirectories = $false }
                SessionDirectories = @()
                ModulePathEntries = @()
            }
        } -ModuleName Capsulenv
        Mock Initialize-CapsulenvScoopBootstrap {} -ModuleName Capsulenv
        Mock Test-CapsulenvScoopRehydrationRequired { $false } -ModuleName Capsulenv
        Mock Get-CapsulenvScoopPathEnvironmentVariable { 'PATH' } -ModuleName Capsulenv
        Mock Test-CapsulenvGitOpenSshSessionConfigured { $false } -ModuleName Capsulenv
        Mock Sync-CapsulenvUserEnvironment { throw 'injected persistent mutation failure' } -ModuleName Capsulenv

        { Install-CapsulenvUserEnvironment } | Should -Throw '*injected persistent mutation failure*'

        Get-CapsulenvUserIntegrationLifetime | Should -Be persistent
        (& $script:Module { Test-Path -LiteralPath (Get-CapsulenvUserEnvironmentBackupPath) -PathType Leaf }) | Should -BeTrue
        $status = Get-CapsulenvUserIntegrationStatus
        $status.OwnedUserIntegration | Should -Be persistent
        @($status.PersistentOwnedSurfaces) | Should -Contain environment-backup
    }

    It 'uses only a validated ledger and original backup for legacy lifetime migration' {
        & $script:Module { Set-CapsulenvInstallMode -Mode User }
        Get-CapsulenvUserIntegrationLifetime | Should -Be isolated
        & $script:Module { Write-CapsulenvUserEnvironmentBackup -Path (Get-CapsulenvUserEnvironmentBackupPath) -Backup ([ordered]@{}) }
        Get-CapsulenvUserIntegrationLifetime | Should -Be persistent
    }

    It 'releases the lease when its child shell fails' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        Mock Invoke-CapsulenvChildShell { throw 'child shell failure' } -ModuleName Capsulenv
        { Enter-CapsulenvLeasedUserShell } | Should -Throw '*child shell failure*'
        $global:CapsulenvLeaseTestEnv.SCOOP | Should -Be foreign-scoop
        (Get-CapsulenvUserIntegrationStatus).OwnedUserIntegration | Should -Be none
        Should -Invoke Invoke-CapsulenvChildShell -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter { $IntegrationMode -eq 'ShellOnly' }
    }

    It 'reports independent axes and lease health through doctor' {
        Set-CapsulenvUserIntegrationLifetime -Lifetime leased
        Start-CapsulenvUserIntegrationLease | Out-Null
        # Isolate diagnostic data from platform/report formatting and required host checks.
        Mock New-CapsulenvCheckResult {
            param($Name, $Detail, $Passed)
            [pscustomobject]@{ Name=$Name; Status='Skipped'; Importance='Optional'; Detail=$Detail; Passed=[bool]$Passed }
        } -ModuleName Capsulenv
        Mock Invoke-CapsulenvDoctorChecks { @() } -ModuleName Capsulenv
        Mock Write-CapsulenvDoctorReport {} -ModuleName Capsulenv
        Mock Get-CapsulenvBitwardenExecutable { $null } -ModuleName Capsulenv
        Mock Get-CapsulenvBrowserExecutable { $null } -ModuleName Capsulenv

        $script:DoctorPortableProfilePath = Join-Path $TestDrive 'doctor-portable-librewolf-profile'
        [void](New-Item -ItemType Directory -Path $script:DoctorPortableProfilePath -Force)
        [pscustomobject]@{ SchemaVersion=1; ProductId='librewolf'; GeckoMajor=130; ProgramVersion='130.0' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:DoctorPortableProfilePath '.capsulenv-gecko-compatibility.json') -Encoding UTF8
        Mock Get-CapsulenvPortableBrowserProfilePath {
            param($App)
            if ($App -eq 'librewolf') { return $script:DoctorPortableProfilePath }
            return ($script:DoctorPortableProfilePath + '-missing')
        } -ModuleName Capsulenv

        $checks = @(& $script:Module { Invoke-CapsulenvDoctor })
        $librewolfProfile = $checks | Where-Object Name -eq 'LibreWolf capsule profile'
        $librewolfProfile.Passed | Should -BeTrue
        $librewolfProfile.Detail | Should -Match ([regex]::Escape($script:DoctorPortableProfilePath))
        $librewolfProfile.Detail | Should -Match 'Gecko major=130'
        Should -Invoke Get-CapsulenvPortableBrowserProfilePath -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter { $App -eq 'librewolf' }
        Remove-Variable DoctorPortableProfilePath -Scope Script -ErrorAction SilentlyContinue
        ($checks | Where-Object Name -eq 'Placement retention').Detail | Should -Be ephemeral
        $detail = ($checks | Where-Object Name -eq 'UserIntegration lifetime').Detail | ConvertFrom-Json
        $detail.PlacementRetention | Should -Be ephemeral
        $detail.UserIntegration | Should -Be leased
        $detail.OwnedUserIntegration | Should -Be leased
        $detail.IntegrationLease | Should -Be Active
        Stop-CapsulenvUserIntegrationLease
    }

    It 'dispatches lifetime selection and leased entrypoints with strict arguments' {
        Mock Set-CapsulenvUserIntegrationLifetime {} -ModuleName Capsulenv
        Mock Enter-CapsulenvLeasedUserShell {} -ModuleName Capsulenv
        Mock Stop-CapsulenvUserIntegrationLease {} -ModuleName Capsulenv
        $env:CAPSULENV_ROOT = Join-Path $script:Fixture 'capsule'
        & $script:Module { Invoke-Capsulenv -Arguments @('user-integration','leased') }
        & $script:Module { Invoke-Capsulenv -Arguments @('lease-user') }
        & $script:Module { Invoke-Capsulenv -Arguments @('release-user') }
        Should -Invoke Set-CapsulenvUserIntegrationLifetime -ModuleName Capsulenv -Times 1 -ParameterFilter { $Lifetime -eq 'leased' }
        Should -Invoke Enter-CapsulenvLeasedUserShell -ModuleName Capsulenv -Times 1
        Should -Invoke Stop-CapsulenvUserIntegrationLease -ModuleName Capsulenv -Times 1
        { & $script:Module { Invoke-Capsulenv -Arguments @('lease-user','--force') } } | Should -Throw '*Invalid arguments*'
    }
}
