function Install-CapsulenvPortablePackageNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [switch]$AllowSourceManifestReplacement
    )

    if ([string]$Plan.Classification -ne 'PortableSafe') {
        throw "Package '$($Plan.Reference)' is not PortableSafe: $($Plan.Classification)"
    }
    $existing = Get-CapsulenvInstalledPackageState -Name ([string]$Plan.Name) -AllowMissing
    $sourceManifestSha256 = Get-CapsulenvFileSha256 -Path ([string]$Plan.ManifestPath)
    $replaceSameVersion = $false
    if ($null -ne $existing) {
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$existing.Reference, [string]$Plan.Reference)) {
            throw "Capsulenv package name '$($Plan.Name)' is already owned by '$($existing.Reference)'; refusing to replace it implicitly with '$($Plan.Reference)'."
        }
        if (
            [string]$existing.Version -eq [string]$Plan.Version -and
            [string]$existing.Architecture -eq [string]$Plan.Architecture
        ) {
            if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$existing.SourceManifestSha256, $sourceManifestSha256)) {
                if (-not $AllowSourceManifestReplacement) {
                    throw "The source manifest changed for already-installed package '$($Plan.Reference)' version '$($Plan.Version)'. Explicit update/reinstall semantics are required."
                }
                $replaceSameVersion = $true
            } else {
                if (-not (Test-Path -LiteralPath $existing.InstallRoot -PathType Container)) {
                    throw "Installed Capsulenv package files are missing: $($existing.Name) $($existing.InstallRoot)"
                }
                Repair-CapsulenvPackageProjection -State $existing
                $shims = @(Sync-CapsulenvPackageShims -Name ([string]$Plan.Name))
                Save-CapsulenvPackageInstalledState `
                    -Plan $Plan `
                    -VersionRoot $existing.InstallRoot `
                    -PersistMappings @($existing.PersistMappings) `
                    -Shims $shims
                return Get-CapsulenvInstalledPackageState -Name ([string]$Plan.Name)
            }
        }
        if ([string]$existing.Version -eq [string]$Plan.Version -and -not $replaceSameVersion) {
            throw "Package '$($Plan.Reference)' version '$($Plan.Version)' is already installed for architecture '$($existing.Architecture)'; architecture replacement is not implicit."
        }
    }

    $appRoot = Join-Path (Get-CapsulenvPackageRoot) ([string]$Plan.Name)
    $versionRoot = Join-Path $appRoot ([string]$Plan.Version)
    if ((Test-Path -LiteralPath $versionRoot) -and -not $replaceSameVersion) {
        throw "Capsulenv package version path already exists but is not the active installed state: $versionRoot"
    }
    [void](New-Item -ItemType Directory -Path $appRoot -Force)
    $temporaryRoot = Join-Path $appRoot ('.install-{0}' -f [Guid]::NewGuid().ToString('N'))
    $rollbackRoot = $null
    $stateBackupPath = $null
    try {
        [void](New-Item -ItemType Directory -Path $temporaryRoot -Force)
        Expand-CapsulenvPackageDownloads -Plan $Plan -Destination $temporaryRoot
        $persistMappings = @(Initialize-CapsulenvPackagePersistence -Plan $Plan -VersionRoot $temporaryRoot)
        $Plan.SourceManifest | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath (Join-Path $temporaryRoot 'manifest.json') -Encoding UTF8
        [ordered]@{
            architecture = [string]$Plan.Architecture
            bucket = [string]$Plan.Bucket
            provider = 'capsulenv'
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $temporaryRoot 'install.json') -Encoding UTF8

        if ($null -ne $existing) {
            $stateBackupPath = Join-Path (Split-Path -Parent $existing.Path) ('.update-state-{0}.json' -f [Guid]::NewGuid().ToString('N'))
            Copy-Item -LiteralPath $existing.Path -Destination $stateBackupPath
        }
        if ($replaceSameVersion) {
            $rollbackRoot = Join-Path $appRoot ('.update-rollback-{0}' -f [Guid]::NewGuid().ToString('N'))
            Move-Item -LiteralPath $versionRoot -Destination $rollbackRoot
        }
        try {
            Move-Item -LiteralPath $temporaryRoot -Destination $versionRoot
        } catch {
            if ($replaceSameVersion -and $null -ne $rollbackRoot -and (Test-Path -LiteralPath $rollbackRoot)) {
                Move-Item -LiteralPath $rollbackRoot -Destination $versionRoot -ErrorAction SilentlyContinue
            }
            throw
        }

        Set-CapsulenvPackageDirectoryLink -Path (Join-Path $appRoot 'current') -Target $versionRoot
        $previousShims = if ($null -ne $existing) { @($existing.Shims) } else { @() }
        # Seed the new state with prior shim ownership until reconciliation has
        # removed aliases no longer declared by the new version. Otherwise an
        # update could forget which stale shim it is allowed to delete.
        Save-CapsulenvPackageInstalledState `
            -Plan $Plan `
            -VersionRoot $versionRoot `
            -PersistMappings $persistMappings `
            -Shims $previousShims
        $shims = @(Sync-CapsulenvPackageShims -Name ([string]$Plan.Name))
        Save-CapsulenvPackageInstalledState -Plan $Plan -VersionRoot $versionRoot -PersistMappings $persistMappings -Shims $shims
        if ($null -ne $rollbackRoot -and (Test-Path -LiteralPath $rollbackRoot)) {
            Remove-Item -LiteralPath $rollbackRoot -Recurse -Force
            $rollbackRoot = $null
        }
        if ($null -ne $stateBackupPath -and (Test-Path -LiteralPath $stateBackupPath -PathType Leaf)) {
            Remove-Item -LiteralPath $stateBackupPath -Force
            $stateBackupPath = $null
        }
        return Get-CapsulenvInstalledPackageState -Name ([string]$Plan.Name)
    } catch {
        if (Test-Path -LiteralPath $temporaryRoot) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($replaceSameVersion -and $null -ne $rollbackRoot -and (Test-Path -LiteralPath $rollbackRoot)) {
            if (Test-Path -LiteralPath $versionRoot) {
                Remove-Item -LiteralPath $versionRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            Move-Item -LiteralPath $rollbackRoot -Destination $versionRoot -ErrorAction SilentlyContinue
        } elseif ($null -ne $existing) {
            try {
                Set-CapsulenvPackageDirectoryLink -Path (Join-Path $appRoot 'current') -Target ([string]$existing.InstallRoot)
            } catch {}
            if (
                -not (Test-CapsulenvSamePath -Left $versionRoot -Right ([string]$existing.InstallRoot)) -and
                (Test-Path -LiteralPath $versionRoot)
            ) {
                Remove-Item -LiteralPath $versionRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if ($null -ne $existing -and $null -ne $stateBackupPath -and (Test-Path -LiteralPath $stateBackupPath -PathType Leaf)) {
            Copy-Item -LiteralPath $stateBackupPath -Destination ([string]$existing.Path) -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $stateBackupPath -Force -ErrorAction SilentlyContinue
            try { [void](Sync-CapsulenvPackageShims -Name ([string]$existing.Name)) } catch {}
        }
        throw
    }
}

function Install-CapsulenvPortablePackage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Reference)

    $installPlan = Get-CapsulenvPackageInstallPlan -Reference $Reference
    if ([string]$installPlan.Classification -ne 'PortableSafe') {
        $blocked = @($installPlan.BlockedPackages | ForEach-Object {
            '{0} [{1}] {2}' -f $_.Reference, $_.Classification, (@($_.Reasons) -join '; ')
        }) -join [Environment]::NewLine
        throw "PortableSafe installation is unavailable because trusted/unsupported package semantics are required:`n$blocked"
    }
    $results = @(Invoke-CapsulenvPortablePackageInstallPlan -InstallPlan $installPlan)
    if ((Get-CapsulenvInstallMode) -eq 'User') {
        Sync-CapsulenvPackageStartMenuShortcuts
    }
    return $results
}

function Update-CapsulenvPortablePackage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Reference)

    $parsed = Split-CapsulenvPackageReference -Reference $Reference
    $existing = Get-CapsulenvInstalledPackageState -Name ([string]$parsed.Name) -AllowMissing
    if ($null -eq $existing) {
        throw (New-CapsulenvDiagnosticErrorRecord `
            -Id 'Capsulenv.Package.NotInstalled' `
            -Message "PortableSafe package is not installed: $($parsed.Name)" `
            -Category ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
            -TargetObject $Reference `
            -Remediation @("Install it first with 'capsulenv app install $Reference'."))
    }
    if (
        $null -ne $parsed.Bucket -and
        -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$existing.Reference, [string]$parsed.Reference)
    ) {
        throw (New-CapsulenvDiagnosticErrorRecord `
            -Id 'Capsulenv.Package.SourceMismatch' `
            -Message "Installed package '$($existing.Name)' is owned by '$($existing.Reference)', not '$($parsed.Reference)'." `
            -Category ([System.Management.Automation.ErrorCategory]::InvalidArgument) `
            -TargetObject $Reference `
            -Remediation @("Update the installed source with 'capsulenv app update capsule/$($existing.Name)'."))
    }

    $installPlan = Get-CapsulenvPackageInstallPlan -Reference ([string]$existing.Reference)
    if ([string]$installPlan.Classification -ne 'PortableSafe') {
        $blocked = @($installPlan.BlockedPackages | ForEach-Object {
            '{0} [{1}] {2}' -f $_.Reference, $_.Classification, (@($_.Reasons) -join '; ')
        }) -join [Environment]::NewLine
        throw (New-CapsulenvDiagnosticErrorRecord `
            -Id 'Capsulenv.Package.UpdateRequiresTrustedExecution' `
            -Message "The current bucket metadata no longer fits PortableSafe, so Capsulenv will not execute it as an owned update.`n$blocked" `
            -Category ([System.Management.Automation.ErrorCategory]::PermissionDenied) `
            -TargetObject ([string]$existing.Reference) `
            -Remediation @(
                "Run 'capsulenv app review $($existing.Reference)' to inspect why current metadata requires TrustedExecution.",
                "Use 'capsulenv app update scoop/<app> --allow-trusted' only for an upstream Scoop-owned install; Capsulenv does not silently transfer ownership."
            ))
    }

    $results = @(Invoke-CapsulenvPortablePackageInstallPlan -InstallPlan $installPlan -AllowSourceManifestReplacement)
    if ((Get-CapsulenvInstallMode) -eq 'User') {
        Sync-CapsulenvPackageStartMenuShortcuts
    }
    return $results
}

function Repair-CapsulenvPackageProjection {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State)

    if (-not (Test-Path -LiteralPath $State.InstallRoot -PathType Container)) {
        throw "Installed Capsulenv package files are missing: $($State.Name) $($State.InstallRoot)"
    }
    Set-CapsulenvPackageDirectoryLink -Path $State.CurrentRoot -Target $State.InstallRoot
    foreach ($mapping in @($State.PersistMappings)) {
        $source = Resolve-CapsulenvScoopAppRelativePath -Root $State.InstallRoot -RelativePath ([string]$mapping.Source)
        $target = Resolve-CapsulenvScoopAppRelativePath -Root $State.PersistRoot -RelativePath ([string]$mapping.Target)
        if (-not (Test-Path -LiteralPath $target)) {
            throw "Persist target is missing for $($State.Name): $target"
        }
        if ([string]$mapping.Kind -eq 'Directory') {
            $existingTarget = Get-CapsulenvReparseTarget -Path $source
            if ($null -ne $existingTarget -and -not (Test-CapsulenvSamePath -Left $existingTarget -Right $target)) {
                Remove-CapsulenvPackageReparsePoint -Path $source
            }
            if ($null -eq (Get-CapsulenvReparseTarget -Path $source)) {
                if (Test-Path -LiteralPath $source) {
                    throw "Persist projection was replaced by a normal path: $source"
                }
                Set-CapsulenvPackageDirectoryLink -Path $source -Target $target
            }
        } else {
            Repair-CapsulenvPackageFileProjection `
                -Path $source `
                -Target $target `
                -OwnershipLabel ("Capsulenv package '$($State.Name)' persist projection")
        }
    }
}

function Repair-CapsulenvPackageProjections {
    [CmdletBinding()]
    param()

    Initialize-CapsulenvFileIdentityRuntime
    foreach ($state in @(Get-CapsulenvInstalledPackageStates -Strict)) {
        Repair-CapsulenvPackageProjection -State $state
    }
}

##MOD_EXEC## Export-ModuleMember -Function Install-CapsulenvPortablePackage, Update-CapsulenvPortablePackage, Repair-CapsulenvPackageProjections
