function Get-CapsulenvLegacyStateInventory {
    [CmdletBinding()]
    param([string]$BrowserApp)

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
        LegacyScoopProjection = (Test-Path -LiteralPath (Join-Path $context.Root 'scoop') -PathType Container)
        LegacyToolStorage = (Test-Path -LiteralPath (Join-Path $context.Root 'tool-data') -PathType Container)
        MigrationIsExplicit = $true
        AutomaticStartupMigration = $false
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
    $backup = Join-Path $destinationParent ('.capsulenv-migration-{0}.bak' -f [Guid]::NewGuid().ToString('N'))
    $destinationExists = Test-Path -LiteralPath $Destination
    $backupMoved = $false
    $published = $false
    try {
        if (Test-Path -LiteralPath $Source -PathType Leaf) {
            Copy-Item -LiteralPath $Source -Destination $staging -Force
        } else {
            [void](New-Item -ItemType Directory -Path $staging -Force)
            foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force)) {
                Copy-Item -LiteralPath $item.FullName -Destination $staging -Recurse -Force
            }
        }

        if (Test-Path -LiteralPath $Source -PathType Leaf) {
            if ($destinationExists) {
                [System.IO.File]::Replace($staging, $Destination, $null, $true)
            } else {
                Move-Item -LiteralPath $staging -Destination $Destination
            }
        } else {
            if ($destinationExists) {
                Move-Item -LiteralPath $Destination -Destination $backup
                $backupMoved = $true
            }
            Move-Item -LiteralPath $staging -Destination $Destination
        }
        $published = $true
        return [pscustomobject]@{ Status = 'Migrated'; Source = $Source; Destination = $Destination }
    } catch {
        if ($backupMoved -and -not (Test-Path -LiteralPath $Destination) -and (Test-Path -LiteralPath $backup)) {
            Move-Item -LiteralPath $backup -Destination $Destination -ErrorAction SilentlyContinue
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($published -and (Test-Path -LiteralPath $backup)) {
            Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
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
    $inventory = Get-CapsulenvLegacyStateInventory -BrowserApp $BrowserApp
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
            $backup = Join-Path $destinationParent ('.capsulenv-browser-migration-{0}.bak' -f [Guid]::NewGuid().ToString('N'))
            $destinationExists = Test-Path -LiteralPath $destination
            $backupMoved = $false
            $published = $false
            try {
                [void](New-Item -ItemType Directory -Path $staging -Force)
                foreach ($item in @(Get-ChildItem -LiteralPath $source -Force)) {
                    Copy-Item -LiteralPath $item.FullName -Destination $staging -Recurse -Force
                }
                $evidence = Set-CapsulenvMigratedBrowserCompatibilityEvidence -LegacyProfile $source -PortableProfile $staging -BrowserApp $BrowserApp
                if ($destinationExists) {
                    Move-Item -LiteralPath $destination -Destination $backup
                    $backupMoved = $true
                }
                Move-Item -LiteralPath $staging -Destination $destination
                $published = $true
                $copyResult = [pscustomobject]@{ Status = 'Migrated'; Source = $source; Destination = $destination }
                $results.Add($copyResult)
                $results.Add([pscustomobject][ordered]@{ Status = 'CompatibilityEvidenceEstablished'; BrowserApp = $BrowserApp; GeckoMajor = $evidence.GeckoMajor; Source = 'legacy-profile' })
            } catch {
                if ($backupMoved -and -not (Test-Path -LiteralPath $destination) -and (Test-Path -LiteralPath $backup)) {
                    Move-Item -LiteralPath $backup -Destination $destination -ErrorAction SilentlyContinue
                }
                throw
            } finally {
                if (Test-Path -LiteralPath $staging) {
                    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
                }
                if ($published -and (Test-Path -LiteralPath $backup)) {
                    Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
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
    if ($results.Count -eq 0) {
        throw 'Migration requires an explicit supported scope: -MigrateBrowserProfile or -MigratePowerShellProfile.'
    }
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        Inventory = $inventory
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
    $powershell = (Get-Command Get-CapsulenvInteractivePowerShellExecutable -CommandType Function).Definition
    $bitwarden = (Get-Command Assert-CapsulenvNoForeignBitwardenProcess -CommandType Function).Definition
    $userIntegration = (Get-Command Install-CapsulenvUserEnvironment -CommandType Function).Definition
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

##MOD_EXEC## Export-ModuleMember -Function Set-CapsulenvMigratedBrowserCompatibilityEvidence, Get-CapsulenvLegacyStateInventory, Invoke-CapsulenvLegacyMigration, Test-CapsulenvLegacyIsolation
