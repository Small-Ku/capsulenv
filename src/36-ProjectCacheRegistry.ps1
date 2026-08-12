function Get-CapsulenvProjectCacheRegistryPath {
    [CmdletBinding()]
    param()

    return Join-Path (Get-CapsulenvContext).StateRoot 'project-cache-links.json'
}

function Get-CapsulenvProjectCacheRecordKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][string]$ProjectScope,
        [Parameter(Mandatory = $true)][string]$ProjectReference
    )

    return ('{0}|{1}|{2}' -f $Profile, $ProjectScope, $ProjectReference.Replace('\', '/')).ToLowerInvariant()
}

function Get-CapsulenvProjectCacheReference {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    $context = Get-CapsulenvContext
    $project = [System.IO.Path]::GetFullPath($ProjectPath).TrimEnd([char[]]'\/')
    $root = $context.Root.TrimEnd([char[]]'\/')
    $rootPrefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($project, $root)) {
        return [pscustomobject]@{ Scope = 'Capsule'; Reference = '.' }
    }
    if ($project.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{
            Scope = 'Capsule'
            Reference = $project.Substring($rootPrefix.Length).Replace('\', '/')
        }
    }
    return [pscustomobject]@{ Scope = 'Absolute'; Reference = $project }
}

function Resolve-CapsulenvProjectCacheRecordPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Record)

    $scope = [string]$Record.ProjectScope
    $reference = [string]$Record.ProjectReference
    if ($scope -eq 'Absolute') {
        if (-not [System.IO.Path]::IsPathRooted($reference)) {
            throw "Managed project-cache record has a non-rooted absolute reference: $reference"
        }
        return [System.IO.Path]::GetFullPath($reference)
    }
    if ($scope -ne 'Capsule') {
        throw "Managed project-cache record has an unsupported scope: $scope"
    }
    if (
        [string]::IsNullOrWhiteSpace($reference) -or
        [System.IO.Path]::IsPathRooted($reference) -or
        $reference -match '(^|[\\/])\.\.([\\/]|$)'
    ) {
        throw "Managed project-cache record has an invalid capsule-relative reference: $reference"
    }
    return Resolve-CapsulenvPath -Path $reference -AllowMissing
}

function Read-CapsulenvProjectCacheRegistry {
    [CmdletBinding()]
    param()

    $path = Get-CapsulenvProjectCacheRegistryPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @()
    }
    $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($null -eq $state.SchemaVersion -or [int]$state.SchemaVersion -ne 1) {
        throw "Unsupported project-cache registry schema: $($state.SchemaVersion)"
    }
    return @($state.Links)
}

function Write-CapsulenvProjectCacheRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records)

    $path = Get-CapsulenvProjectCacheRegistryPath
    $parent = Split-Path -Parent $path
    [void](New-Item -ItemType Directory -Path $parent -Force)
    $temporary = Join-Path $parent ('.project-cache-links-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    $rollback = $null
    try {
        [ordered]@{
            SchemaVersion = 1
            Links = @($Records | Sort-Object Profile, ProjectScope, ProjectReference)
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8

        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                [System.IO.File]::Replace($temporary, $path, $null, $true)
            } catch {
                $rollback = Join-Path $parent ('.project-cache-links-{0}.rollback' -f [Guid]::NewGuid().ToString('N'))
                Move-Item -LiteralPath $path -Destination $rollback
                try {
                    Move-Item -LiteralPath $temporary -Destination $path
                    Remove-Item -LiteralPath $rollback -Force
                    $rollback = $null
                } catch {
                    if (Test-Path -LiteralPath $path) {
                        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                    }
                    Move-Item -LiteralPath $rollback -Destination $path -ErrorAction SilentlyContinue
                    throw
                }
            }
        } else {
            Move-Item -LiteralPath $temporary -Destination $path
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $rollback -and (Test-Path -LiteralPath $rollback)) {
            Write-CapsulenvMessage -Level Warning -Message "Project-cache registry recovery file remains at: $rollback"
        }
    }
}


function Get-CapsulenvProjectCacheFileFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $item = Get-Item -LiteralPath $Path -Force
    $hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256
    return [pscustomobject][ordered]@{
        Length = [long]$item.Length
        Sha256 = ([string]$hash.Hash).ToLowerInvariant()
    }
}

function Test-CapsulenvProjectCacheFileFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Fingerprint
    )

    if ($null -eq $Fingerprint) {
        return $false
    }
    $shaProperty = $Fingerprint.PSObject.Properties['Sha256']
    $lengthProperty = $Fingerprint.PSObject.Properties['Length']
    if ($null -eq $shaProperty -or $null -eq $lengthProperty) {
        return $false
    }
    $current = Get-CapsulenvProjectCacheFileFingerprint -Path $Path
    if ($null -eq $current) {
        return $false
    }
    return (
        [long]$current.Length -eq [long]$lengthProperty.Value -and
        [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$current.Sha256, [string]$shaProperty.Value)
    )
}

function Register-CapsulenvProjectCacheLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$ActualLinkType
    )

    $reference = Get-CapsulenvProjectCacheReference -ProjectPath $Plan.ProjectRoot
    $key = Get-CapsulenvProjectCacheRecordKey `
        -Profile $Plan.Profile `
        -ProjectScope $reference.Scope `
        -ProjectReference $reference.Reference
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($record in @(Read-CapsulenvProjectCacheRegistry)) {
        $recordKey = Get-CapsulenvProjectCacheRecordKey `
            -Profile ([string]$record.Profile) `
            -ProjectScope ([string]$record.ProjectScope) `
            -ProjectReference ([string]$record.ProjectReference)
        if ($recordKey -ne $key) {
            $records.Add($record)
        }
    }
    $managedFileFingerprint = if ($ActualLinkType -eq 'HardLink') {
        Get-CapsulenvProjectCacheFileFingerprint -Path $Plan.LinkPath
    } else {
        $null
    }
    $records.Add([pscustomobject][ordered]@{
        Profile = [string]$Plan.Profile
        ProjectScope = [string]$reference.Scope
        ProjectReference = [string]$reference.Reference
        LinkType = $ActualLinkType
        LastLinkPath = [string]$Plan.LinkPath
        LastStorePath = [string]$Plan.StorePath
        LastFileFingerprint = $managedFileFingerprint
    })
    Write-CapsulenvProjectCacheRegistry -Records $records.ToArray()
}

function Unregister-CapsulenvProjectCacheLink {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan)

    $reference = Get-CapsulenvProjectCacheReference -ProjectPath $Plan.ProjectRoot
    $key = Get-CapsulenvProjectCacheRecordKey `
        -Profile $Plan.Profile `
        -ProjectScope $reference.Scope `
        -ProjectReference $reference.Reference
    $remaining = @(
        Read-CapsulenvProjectCacheRegistry | Where-Object {
            (Get-CapsulenvProjectCacheRecordKey `
                -Profile ([string]$_.Profile) `
                -ProjectScope ([string]$_.ProjectScope) `
                -ProjectReference ([string]$_.ProjectReference)) -ne $key
        }
    )
    Write-CapsulenvProjectCacheRegistry -Records $remaining
}

function Repair-CapsulenvProjectCacheLinks {
    [CmdletBinding()]
    param(
        [switch]$Strict,
        [switch]$Quiet
    )

    try {
        $records = @(Read-CapsulenvProjectCacheRegistry)
    } catch {
        if ($Strict) {
            throw
        }
        if (-not $Quiet) {
            Write-CapsulenvMessage -Level Warning -Message $_.Exception.Message
        }
        return @([pscustomobject]@{
            Profile = $null
            ProjectPath = $null
            LinkPath = $null
            StorePath = $null
            LinkType = $null
            Changed = $false
            Status = 'RegistryError'
            Detail = $_.Exception.Message
        })
    }
    if ($records.Count -eq 0) {
        return @()
    }

    $configuration = Get-CapsulenvConfiguration
    $updated = New-Object System.Collections.Generic.List[object]
    $results = New-Object System.Collections.Generic.List[object]
    $registryChanged = $false

    foreach ($record in $records) {
        try {
            $profile = [string]$record.Profile
            if (-not $configuration.ToolStorage.ProjectLinks.ContainsKey($profile)) {
                throw "The configured project-cache profile no longer exists: $profile"
            }
            $projectPath = Resolve-CapsulenvProjectCacheRecordPath -Record $record
            if (-not (Test-Path -LiteralPath $projectPath -PathType Container)) {
                throw "The managed project directory is unavailable: $projectPath"
            }
            $plan = Resolve-CapsulenvProjectLinkPlan `
                -Profile $profile `
                -ProjectPath $projectPath `
                -LinkType ([string]$record.LinkType)
            if (-not (Test-Path -LiteralPath $plan.StorePath)) {
                throw "The managed capsule cache store is unavailable: $($plan.StorePath)"
            }
            Assert-CapsulenvProjectCachePathKind -Path $plan.StorePath -Kind $plan.Kind

            $linkInfo = Get-CapsulenvProjectLinkInfo -Plan $plan
            $changed = $false
            if (-not $linkInfo.Linked) {
                $oldTarget = Get-CapsulenvReparseTarget -Path $plan.LinkPath
                $removedRecognizedLink = $false
                $removedRecognizedFileCopy = $false
                if ($null -ne $oldTarget) {
                    if (
                        [string]::IsNullOrWhiteSpace([string]$record.LastStorePath) -or
                        -not (Test-CapsulenvSamePath -Left $oldTarget -Right ([string]$record.LastStorePath))
                    ) {
                        throw "Refusing to replace an unrecognized project link: $($plan.LinkPath) -> $oldTarget"
                    }
                    Remove-Item -LiteralPath $plan.LinkPath -Force
                    $removedRecognizedLink = $true
                } elseif (Test-Path -LiteralPath $plan.LinkPath) {
                    if ([string]$record.LinkType -ne 'HardLink') {
                        throw "Refusing to replace a normal project path: $($plan.LinkPath)"
                    }
                    $fingerprintProperty = $record.PSObject.Properties['LastFileFingerprint']
                    if (
                        $null -eq $fingerprintProperty -or
                        $null -eq $fingerprintProperty.Value -or
                        -not (Test-CapsulenvProjectCacheFileFingerprint -Path $plan.LinkPath -Fingerprint $fingerprintProperty.Value)
                    ) {
                        throw "Refusing to replace an unrecognized file after hard-link relocation: $($plan.LinkPath)"
                    }
                    if (-not (Test-CapsulenvProjectCacheFileFingerprint -Path $plan.StorePath -Fingerprint $fingerprintProperty.Value)) {
                        throw "Managed hard-link copies diverged after relocation; refusing to discard either copy: $($plan.LinkPath) <-> $($plan.StorePath)"
                    }
                    $linkVolume = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($plan.LinkPath))
                    $storeVolume = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($plan.StorePath))
                    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($linkVolume, $storeVolume)) {
                        throw "Managed file hardlink cannot be recreated across volumes: $linkVolume <-> $storeVolume"
                    }
                    Remove-Item -LiteralPath $plan.LinkPath -Force
                    $removedRecognizedLink = $true
                    $removedRecognizedFileCopy = $true
                }

                try {
                    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $plan.LinkPath) -Force)
                    [void](New-Item -ItemType $plan.LinkType -Path $plan.LinkPath -Target $plan.StorePath -Force)
                    $linkInfo = Get-CapsulenvProjectLinkInfo -Plan $plan
                    if (-not $linkInfo.Linked) {
                        throw "Recreated project-cache link could not be verified: $($plan.LinkPath)"
                    }
                } catch {
                    $repairError = $_
                    if ($removedRecognizedFileCopy -and -not (Test-Path -LiteralPath $plan.LinkPath)) {
                        try {
                            Copy-Item -LiteralPath $plan.StorePath -Destination $plan.LinkPath -Force
                        } catch {
                            throw "Project-cache repair failed: $($repairError.Exception.Message) Restoring the recognized file copy also failed: $($_.Exception.Message)"
                        }
                    } elseif ($removedRecognizedLink -and $null -ne $oldTarget -and $null -eq (Get-CapsulenvReparseTarget -Path $plan.LinkPath)) {
                        try {
                            [void](New-Item `
                                -ItemType ([string]$record.LinkType) `
                                -Path $plan.LinkPath `
                                -Target $oldTarget `
                                -Force)
                        } catch {
                            throw "Project-cache repair failed: $($repairError.Exception.Message) Restoring the previous link also failed: $($_.Exception.Message)"
                        }
                    }
                    throw $repairError
                }
                $changed = $true
            }

            $newFileFingerprint = if ([string]$linkInfo.LinkType -eq 'HardLink') {
                Get-CapsulenvProjectCacheFileFingerprint -Path $plan.LinkPath
            } else {
                $null
            }
            $oldFingerprintProperty = $record.PSObject.Properties['LastFileFingerprint']
            $oldFileFingerprint = if ($null -ne $oldFingerprintProperty) { $oldFingerprintProperty.Value } else { $null }
            $newRecord = [pscustomobject][ordered]@{
                Profile = $profile
                ProjectScope = [string]$record.ProjectScope
                ProjectReference = [string]$record.ProjectReference
                LinkType = [string]$linkInfo.LinkType
                LastLinkPath = [string]$plan.LinkPath
                LastStorePath = [string]$plan.StorePath
                LastFileFingerprint = $newFileFingerprint
            }
            $updated.Add($newRecord)
            if (
                $changed -or
                -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$record.LastLinkPath, [string]$plan.LinkPath) -or
                -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$record.LastStorePath, [string]$plan.StorePath) -or
                -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$record.LinkType, [string]$linkInfo.LinkType) -or
                ([string]($oldFileFingerprint | ConvertTo-Json -Compress)) -ne ([string]($newFileFingerprint | ConvertTo-Json -Compress))
            ) {
                $registryChanged = $true
            }
            $results.Add([pscustomobject]@{
                Profile = $profile
                ProjectPath = $projectPath
                LinkPath = $plan.LinkPath
                StorePath = $plan.StorePath
                LinkType = $linkInfo.LinkType
                Changed = $changed
                Status = 'Ready'
                Detail = $null
            })
        } catch {
            $updated.Add($record)
            $results.Add([pscustomobject]@{
                Profile = [string]$record.Profile
                ProjectPath = [string]$record.ProjectReference
                LinkPath = [string]$record.LastLinkPath
                StorePath = [string]$record.LastStorePath
                LinkType = [string]$record.LinkType
                Changed = $false
                Status = 'Skipped'
                Detail = $_.Exception.Message
            })
            if ($Strict) {
                throw
            }
            if (-not $Quiet) {
                Write-CapsulenvMessage -Level Warning -Message $_.Exception.Message
            }
        }
    }

    if ($registryChanged) {
        Write-CapsulenvProjectCacheRegistry -Records $updated.ToArray()
    }
    return $results.ToArray()
}

function Get-CapsulenvManagedProjectCacheLinks {
    [CmdletBinding()]
    param()

    return @(Read-CapsulenvProjectCacheRegistry)
}

##MOD_EXEC## Export-ModuleMember -Function Repair-CapsulenvProjectCacheLinks, Get-CapsulenvManagedProjectCacheLinks
