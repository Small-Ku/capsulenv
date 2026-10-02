function Get-CapsulenvLegacyStateInventory {
    [CmdletBinding()]
    param(
        [string]$BrowserApp,
        [string]$LegacyPowerShellProfilePath,
        [string]$LegacyPowerShellHistoryPath
    )

    $context = Get-CapsulenvContext
    $browserPersist = $null
    if (-not [string]::IsNullOrWhiteSpace($BrowserApp)) {
        try { $browserPersist = Get-CapsulenvBrowserProfilePath -App $BrowserApp } catch {}
    }
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        CapsuleRoot = $context.Root
        BrowserApp = $BrowserApp
        LegacyBrowserProfile = $browserPersist
        LegacyBrowserProfilePresent = (-not [string]::IsNullOrWhiteSpace([string]$browserPersist))
        LegacyPowerShellProfile = $LegacyPowerShellProfilePath
        LegacyPowerShellProfilePresent = (-not [string]::IsNullOrWhiteSpace($LegacyPowerShellProfilePath) -and (Test-Path -LiteralPath $LegacyPowerShellProfilePath -PathType Leaf))
        LegacyPowerShellHistory = $LegacyPowerShellHistoryPath
        LegacyPowerShellHistoryPresent = (-not [string]::IsNullOrWhiteSpace($LegacyPowerShellHistoryPath) -and (Test-Path -LiteralPath $LegacyPowerShellHistoryPath -PathType Leaf))
        LegacyScoopProjection = (Test-Path -LiteralPath (Join-Path $context.Root 'scoop') -PathType Container)
        LegacyScoopPersist = (Test-Path -LiteralPath (Join-Path $context.Root 'scoop/persist') -PathType Container)
        LegacyToolStorage = (Test-Path -LiteralPath (Join-Path $context.Root 'tool-data') -PathType Container)
        MigrationIsExplicit = $true
        AutomaticStartupMigration = $false
    }
}

function Get-CapsulenvMigrationRegistry {
    [CmdletBinding()]
    param()

    # Keep this registry declarative. Every detector exposed by the inventory
    # must have either a supported migration handler or an explicit unsupported
    # handler with remediation; otherwise a new legacy signal can silently
    # become an unowned migration surface.
    return @(
        [pscustomobject][ordered]@{
            LegacyKind = 'BrowserProfile'
            Detect = { param($Inventory) [bool]$Inventory.LegacyBrowserProfilePresent }
            Supported = $true
            Handler = 'Invoke-CapsulenvLegacyMigration'
            Target = 'portable State/browser profile plus compatibility evidence'
            Validate = 'portable profile and .capsulenv-gecko-compatibility.json'
            Rollback = 'directory authority transaction recovery'
            Diagnostic = 'Legacy browser profile can be migrated when Gecko compatibility evidence is present.'
            Remediation = @('Run migrate --browser <app>.')
        }
        [pscustomobject][ordered]@{
            LegacyKind = 'PowerShellProfile'
            Detect = { param($Inventory) [bool]$Inventory.LegacyPowerShellProfilePresent }
            Supported = $true
            Handler = 'Invoke-CapsulenvLegacyMigration'
            Target = 'portable State/PowerShell profile'
            Validate = 'destination file content is published atomically'
            Rollback = 'file authority publication retains the previous file'
            Diagnostic = 'Legacy PowerShell profile can be copied into portable State.'
            Remediation = @('Run migrate --powershell-profile <path>.')
        }
        [pscustomobject][ordered]@{
            LegacyKind = 'PowerShellHistory'
            Detect = { param($Inventory) [bool]$Inventory.LegacyPowerShellHistoryPresent }
            Supported = $true
            Handler = 'Invoke-CapsulenvLegacyMigration'
            Target = 'portable State/PowerShell history'
            Validate = 'destination file content is published atomically'
            Rollback = 'file authority publication retains the previous file'
            Diagnostic = 'Legacy PowerShell history can be copied into portable State.'
            Remediation = @('Run migrate --powershell-history <path>.')
        }
        [pscustomobject][ordered]@{
            LegacyKind = 'LegacyScoopProjection'
            Detect = { param($Inventory) [bool]$Inventory.LegacyScoopProjection }
            Supported = $false
            Handler = 'Invoke-CapsulenvUnsupportedLegacyMigration'
            Target = 'provider-neutral installed Program/State'
            Validate = 'requires installed manifest and ownership evidence for each app'
            Rollback = 'no automatic mutation; foreign or ambiguous state remains untouched'
            Diagnostic = 'Legacy Scoop projections are detected, but no bounded conversion is proven for the complete installed graph.'
            Remediation = @('Inspect installed manifests and ownership with doctor.', 'Use upstream Scoop repair or explicitly reinstall the affected app.', 'Do not delete scoop/ or persist state automatically.')
        }
        [pscustomobject][ordered]@{
            LegacyKind = 'LegacyScoopPersist'
            Detect = { param($Inventory) [bool]$Inventory.LegacyScoopPersist }
            Supported = $false
            Handler = 'Invoke-CapsulenvUnsupportedLegacyMigration'
            Target = 'provider-neutral Program/State data'
            Validate = 'requires app-specific state schema and ownership evidence'
            Rollback = 'no automatic mutation; persistent data remains untouched'
            Diagnostic = 'Legacy Scoop persist data is detected, but generic copying would violate app-state ownership boundaries.'
            Remediation = @('Use the owning app migration or upstream Scoop repair.', 'Keep the original persist data until an app-specific migration is available.')
        }
        [pscustomobject][ordered]@{
            LegacyKind = 'LegacyToolStorage'
            Detect = { param($Inventory) [bool]$Inventory.LegacyToolStorage }
            Supported = $false
            Handler = 'Invoke-CapsulenvUnsupportedLegacyMigration'
            Target = 'explicit tool State scopes'
            Validate = 'requires tool-specific receipt and workspace ownership evidence'
            Rollback = 'no automatic mutation; tool state remains untouched'
            Diagnostic = 'Generic ToolStorage migration is not safe without a tool-specific receipt and state scope.'
            Remediation = @('Use the tool-specific status/repair command.', 'Register project workspaces explicitly before moving their cache state.')
        }
    )
}

function Get-CapsulenvMigrationCoverage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Inventory)

    $coverage = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @(Get-CapsulenvMigrationRegistry)) {
        $detected = [bool](& $entry.Detect $Inventory)
        if ([string]::IsNullOrWhiteSpace([string]$entry.Handler)) {
            throw "Migration registry entry '$($entry.LegacyKind)' has no handler."
        }
        if (-not $entry.Supported -and @($entry.Remediation).Count -eq 0) {
            throw "Unsupported migration registry entry '$($entry.LegacyKind)' has no remediation."
        }
        $coverage.Add([pscustomobject][ordered]@{
            LegacyKind = [string]$entry.LegacyKind
            Detected = $detected
            Supported = [bool]$entry.Supported
            Handler = [string]$entry.Handler
            Target = [string]$entry.Target
            Validate = [string]$entry.Validate
            Rollback = [string]$entry.Rollback
            Diagnostic = [string]$entry.Diagnostic
            Remediation = @($entry.Remediation)
        })
    }
    return $coverage.ToArray()
}

function Invoke-CapsulenvUnsupportedLegacyMigration {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Coverage)

    return [pscustomobject][ordered]@{
        Status = 'Unsupported'
        LegacyKind = [string]$Coverage.LegacyKind
        Diagnostic = [string]$Coverage.Diagnostic
        Remediation = @($Coverage.Remediation)
        Source = 'legacy inventory'
    }
}

function Copy-CapsulenvLegacyStateItem {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$Force
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        return [pscustomobject]@{ Status = 'Skipped'; Source = $Source; Destination = $Destination; Reason = 'source absent' }
    }
    if ((Test-Path -LiteralPath $Destination) -and -not $Force) {
        return [pscustomobject]@{ Status = 'Skipped'; Source = $Source; Destination = $Destination; Reason = 'destination exists; use -Force' }
    }
    if (-not $PSCmdlet.ShouldProcess($Destination, 'Migrate legacy state through a staging boundary')) {
        return [pscustomobject]@{ Status = 'WhatIf'; Source = $Source; Destination = $Destination }
    }

    $destinationParent = Split-Path -Parent $Destination
    [void](New-Item -ItemType Directory -Path $destinationParent -Force)
    $staging = Join-Path $destinationParent ('.capsulenv-migration-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        if (Test-Path -LiteralPath $Source -PathType Leaf) {
            Copy-Item -LiteralPath $Source -Destination $staging -Force
            Publish-CapsulenvFileAuthorityAtomically -Path $Destination -StagedPath $staging
        } else {
            [void](New-Item -ItemType Directory -Path $staging -Force)
            foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force)) {
                Copy-Item -LiteralPath $item.FullName -Destination $staging -Recurse -Force
            }
            Publish-CapsulenvDirectoryAuthorityTransactionally -Path $Destination -StagedPath $staging
        }
        return [pscustomobject]@{ Status = 'Migrated'; Source = $Source; Destination = $Destination }
    } catch {
        throw
    } finally {
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Set-CapsulenvMigratedBrowserCompatibilityEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LegacyProfile,
        [Parameter(Mandatory = $true)][string]$PortableProfile,
        [Parameter(Mandatory = $true)][string]$BrowserApp
    )

    $evidence = $null
    $legacyEvidencePath = Join-Path $LegacyProfile '.capsulenv-gecko-compatibility.json'
    if (Test-Path -LiteralPath $legacyEvidencePath -PathType Leaf) {
        try {
            $legacy = Get-Content -LiteralPath $legacyEvidencePath -Raw | ConvertFrom-Json
            if ([int]$legacy.GeckoMajor -le 0 -or [string]::IsNullOrWhiteSpace([string]$legacy.ProductId)) { throw 'legacy Gecko evidence is invalid' }
            $evidence = [pscustomobject][ordered]@{
                ProductId = [string]$legacy.ProductId
                GeckoMajor = [int]$legacy.GeckoMajor
                ProgramVersion = [string]$legacy.ProgramVersion
            }
        } catch {
            throw "Legacy browser compatibility evidence is unreadable: $($_.Exception.Message)"
        }
    } else {
        $compatibilityPath = Join-Path $LegacyProfile 'compatibility.ini'
        if (-not (Test-Path -LiteralPath $compatibilityPath -PathType Leaf)) {
            throw 'Browser migration requires legacy Gecko compatibility evidence; compatibility.ini is missing.'
        }
        $compatibilityText = Get-Content -LiteralPath $compatibilityPath -Raw
        if ($compatibilityText -notmatch '(?im)^\s*LastVersion\s*=\s*([0-9]+(?:\.[0-9]+)*)') {
            throw 'Browser migration requires legacy Gecko compatibility evidence; compatibility.ini has no LastVersion.'
        }
        $version = [string]$matches[1]
        $evidence = [pscustomobject][ordered]@{
            ProductId = Get-CapsulenvBrowserStateIdentity -App $BrowserApp
            GeckoMajor = [int]([version]$version).Major
            ProgramVersion = $version
        }
    }
    Set-CapsulenvBrowserProfileCompatibility -ProfilePath $PortableProfile -Evidence $evidence
    return $evidence
}
function Invoke-CapsulenvLegacyMigration {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$BrowserApp,
        [string]$LegacyPowerShellProfilePath,
        [string]$LegacyPowerShellHistoryPath,
        [switch]$MigrateBrowserProfile,
        [switch]$MigratePowerShellProfile,
        [switch]$Force
    )

    $results = New-Object System.Collections.Generic.List[object]
    $inventory = Get-CapsulenvLegacyStateInventory `
        -BrowserApp $BrowserApp `
        -LegacyPowerShellProfilePath $LegacyPowerShellProfilePath `
        -LegacyPowerShellHistoryPath $LegacyPowerShellHistoryPath
    $coverage = @(Get-CapsulenvMigrationCoverage -Inventory $inventory)
    $hasRequestedScope = $MigrateBrowserProfile -or $MigratePowerShellProfile
    if (-not $hasRequestedScope) {
        throw 'Migration requires an explicit supported scope: -MigrateBrowserProfile or -MigratePowerShellProfile.'
    }
    foreach ($unsupported in @($coverage | Where-Object { $_.Detected -and -not $_.Supported })) {
        $results.Add((Invoke-CapsulenvUnsupportedLegacyMigration -Coverage $unsupported))
    }
    if ($MigrateBrowserProfile) {
        if ([string]::IsNullOrWhiteSpace($BrowserApp)) {
            throw 'Browser migration requires -BrowserApp.'
        }
        $source = [string]$inventory.LegacyBrowserProfile
        $destination = Get-CapsulenvPortableBrowserProfilePath -App $BrowserApp
        $copyResult = $null
        if (-not (Test-Path -LiteralPath $source)) {
            $copyResult = [pscustomobject]@{ Status = 'Skipped'; Source = $source; Destination = $destination; Reason = 'source absent' }
        } elseif ((Test-Path -LiteralPath $destination) -and -not $Force) {
            $copyResult = [pscustomobject]@{ Status = 'Skipped'; Source = $source; Destination = $destination; Reason = 'destination exists; use -Force' }
        } elseif ($PSCmdlet.ShouldProcess($destination, 'Migrate browser profile through staged validation and publication')) {
            $destinationParent = Split-Path -Parent $destination
            [void](New-Item -ItemType Directory -Path $destinationParent -Force)
            $staging = Join-Path $destinationParent ('.capsulenv-browser-migration-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
            try {
                [void](New-Item -ItemType Directory -Path $staging -Force)
                foreach ($item in @(Get-ChildItem -LiteralPath $source -Force)) {
                    Copy-Item -LiteralPath $item.FullName -Destination $staging -Recurse -Force
                }
                $evidence = Set-CapsulenvMigratedBrowserCompatibilityEvidence -LegacyProfile $source -PortableProfile $staging -BrowserApp $BrowserApp
                Publish-CapsulenvDirectoryAuthorityTransactionally -Path $destination -StagedPath $staging
                $copyResult = [pscustomobject]@{ Status = 'Migrated'; Source = $source; Destination = $destination }
                $results.Add($copyResult)
                $results.Add([pscustomobject][ordered]@{ Status = 'CompatibilityEvidenceEstablished'; BrowserApp = $BrowserApp; GeckoMajor = $evidence.GeckoMajor; Source = 'legacy-profile' })
            } catch {
                throw
            } finally {
                if (Test-Path -LiteralPath $staging) {
                    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        } else {
            $copyResult = [pscustomobject]@{ Status = 'WhatIf'; Source = $source; Destination = $destination }
        }
        if ($null -ne $copyResult -and [string]$copyResult.Status -in @('Skipped', 'WhatIf')) {
            $results.Add($copyResult)
        }
    }
    if ($MigratePowerShellProfile) {
        $paths = Get-CapsulenvPowerShellStatePaths -Create
        if (-not [string]::IsNullOrWhiteSpace($LegacyPowerShellProfilePath)) {
            $results.Add((Copy-CapsulenvLegacyStateItem -Source $LegacyPowerShellProfilePath -Destination $paths.ProfilePath -Force:$Force))
        }
        if (-not [string]::IsNullOrWhiteSpace($LegacyPowerShellHistoryPath)) {
            $results.Add((Copy-CapsulenvLegacyStateItem -Source $LegacyPowerShellHistoryPath -Destination $paths.HistoryPath -Force:$Force))
        }
    }
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        Inventory = $inventory
        Coverage = $coverage
        Results = @($results.ToArray())
        Authority = 'portable desired state plus host-local realization/generation'
        AutomaticStartupRepair = $false
    }
}

function Test-CapsulenvLegacyIsolation {
    [CmdletBinding()]
    param()

    $initialize = (Get-Command Initialize-Capsulenv -CommandType Function).Definition
    $owned = (Get-Command Get-CapsulenvOwnedProcesses -CommandType Function).Definition
    $rehydrate = (Get-Command Invoke-CapsulenvScoopRehydrate -CommandType Function).Definition
    $browser = (Get-Command Start-CapsulenvBrowser -CommandType Function).Definition
    $powershell = (Get-Command Invoke-CapsulenvChildShell -CommandType Function).Definition
    $bitwarden = (Get-Command Assert-CapsulenvNoForeignBitwardenProcess -CommandType Function).Definition
    $userIntegration = (Get-Command Sync-CapsulenvPackageStartMenuShortcuts -CommandType Function).Definition
    return [pscustomobject][ordered]@{
        StartupBroadRehydrate = ($initialize -match 'Invoke-CapsulenvScoopRehydrate')
        ExecutablePathOwnership = ($owned -match 'StartsWith|Get-CapsulenvScoop|CapsulenvContext')
        OnRehydrateSteadyState = ($rehydrate -match 'Invoke-CapsulenvRoutines')
        BrowserScoopPersistAuthority = ($browser -match 'Get-CapsulenvBrowserProfilePath')
        InteractivePowerShellControlFallback = ($powershell -match 'Get-Process|CurrentProcess|Process\.Path')
        ForeignBitwardenRejection = ($bitwarden -match 'throw')
        RemovableUserIntegration = ($userIntegration -match 'Sync-CapsulenvConfiguredDefaultBrowser')
        ExplicitMigrationOnly = $true
        Passed = (
            $initialize -notmatch 'Invoke-CapsulenvScoopRehydrate' -and
            $owned -notmatch 'StartsWith|Get-CapsulenvScoop|CapsulenvContext' -and
            $rehydrate -notmatch 'Invoke-CapsulenvRoutines' -and
            $browser -notmatch 'Get-CapsulenvBrowserProfilePath' -and
            $powershell -notmatch 'Get-Process|CurrentProcess|Process\.Path' -and
            $bitwarden -notmatch 'throw' -and
            $userIntegration -notmatch 'Sync-CapsulenvConfiguredDefaultBrowser'
        )
    }
}

function Invoke-CapsulenvMigrationCommand {
    [CmdletBinding()]
    param([string[]]$Arguments)

    $allowed = @('--browser', '--force', '--powershell-profile', '--powershell-history')
    $unknown = @($Arguments | Where-Object { $_ -like '--*' -and $_ -notin $allowed })
    if ($unknown.Count -gt 0) {
        throw 'Usage: migrate [--browser <app>] [--powershell-profile <path>] [--powershell-history <path>] [--force]'
    }
    $browser = $null
    $profile = $null
    $history = $null
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        switch ([string]$Arguments[$index]) {
            '--browser' { if ($index + 1 -ge $Arguments.Count) { throw 'Usage: migrate --browser <app>' }; $browser = [string]$Arguments[++$index] }
            '--powershell-profile' { if ($index + 1 -ge $Arguments.Count) { throw 'Usage: migrate --powershell-profile <path>' }; $profile = [string]$Arguments[++$index] }
            '--powershell-history' { if ($index + 1 -ge $Arguments.Count) { throw 'Usage: migrate --powershell-history <path>' }; $history = [string]$Arguments[++$index] }
        }
    }
    $parameters = @{
        BrowserApp = $browser
        LegacyPowerShellProfilePath = $profile
        LegacyPowerShellHistoryPath = $history
        MigrateBrowserProfile = (-not [string]::IsNullOrWhiteSpace($browser))
        MigratePowerShellProfile = (-not [string]::IsNullOrWhiteSpace($profile) -or -not [string]::IsNullOrWhiteSpace($history))
        Force = ($Arguments -contains '--force')
    }
    Invoke-CapsulenvLegacyMigration @parameters | Format-List
}

##MOD_EXEC## Export-ModuleMember -Function Set-CapsulenvMigratedBrowserCompatibilityEvidence, Get-CapsulenvLegacyStateInventory, Get-CapsulenvMigrationRegistry, Get-CapsulenvMigrationCoverage, Invoke-CapsulenvLegacyMigration, Invoke-CapsulenvUnsupportedLegacyMigration, Test-CapsulenvLegacyIsolation
