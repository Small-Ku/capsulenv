function Read-CapsulenvRelocationTextFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $encoding = $null
    $preambleLength = 0

    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
        $encoding = [System.Text.UTF32Encoding]::new($true, $true, $true)
        $preambleLength = 4
    } elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) {
        $encoding = [System.Text.UTF32Encoding]::new($false, $true, $true)
        $preambleLength = 4
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = [System.Text.UTF8Encoding]::new($true, $true)
        $preambleLength = 3
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = [System.Text.UnicodeEncoding]::new($true, $true, $true)
        $preambleLength = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [System.Text.UnicodeEncoding]::new($false, $true, $true)
        $preambleLength = 2
    } else {
        $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    }

    try {
        $text = $encoding.GetString($bytes, $preambleLength, $bytes.Length - $preambleLength)
    } catch {
        throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Relocation.Persist.InvalidText' -Message ('[[CapsulenvText:PersistRelocation.InvalidText.Message]]' -f $Path) -TargetObject $Path -Cause $_)
    }

    return [pscustomobject]@{
        Path = $Path
        Bytes = $bytes
        Text = $text
        Encoding = $encoding
        HasPreamble = ($preambleLength -gt 0)
    }
}

function ConvertTo-CapsulenvEncodedBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)]$Encoding,
        [Parameter(Mandatory = $true)][bool]$IncludePreamble
    )

    [byte[]]$body = $Encoding.GetBytes($Text)
    if (-not $IncludePreamble) {
        return $body
    }

    [byte[]]$preamble = $Encoding.GetPreamble()
    [byte[]]$result = [byte[]]::new($preamble.Length + $body.Length)
    [System.Buffer]::BlockCopy($preamble, 0, $result, 0, $preamble.Length)
    [System.Buffer]::BlockCopy($body, 0, $result, $preamble.Length, $body.Length)
    return $result
}

function Assert-CapsulenvRelocationRuleFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Format,
        [Parameter(Mandatory = $true)][string]$Path
    )

    switch ($Format.ToLowerInvariant()) {
        'text' { return }
        'json' {
            try {
                [void]($Text | ConvertFrom-Json)
            } catch {
                throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Relocation.Persist.InvalidJson' -Message ('[[CapsulenvText:PersistRelocation.InvalidJson.Message]]' -f $Path) -TargetObject $Path -Cause $_ -Remediation @('Repair the JSON file before retrying relocation.'))
            }
        }
        default { throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Relocation.Persist.UnsupportedFormat' -Message ('[[CapsulenvText:PersistRelocation.UnsupportedFormat.Message]]' -f $Format, $Path) -TargetObject $Path -Context ([ordered]@{ Format=$Format })) }
    }
}

function Get-CapsulenvPersistRootsForApp {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$App)

    $selector = Split-CapsulenvScoopAppSelector -Selector $App
    $rootRecords = if ($null -eq $selector.Scope) {
        @(
            (Get-CapsulenvScoopAppRootRecord -Scope User),
            (Get-CapsulenvScoopAppRootRecord -Scope Global)
        )
    } else {
        @(Get-CapsulenvScoopAppRootRecord -Scope ([string]$selector.Scope))
    }

    $roots = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($rootRecord in $rootRecords) {
        $candidate = Join-Path $rootRecord.PersistRoot $selector.Name
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
            continue
        }
        $resolved = [System.IO.Path]::GetFullPath($candidate)
        $key = $resolved.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true
        $roots.Add($resolved)
    }
    return $roots.ToArray()
}

function Resolve-CapsulenvPersistRepairPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PersistRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Relocation.Persist.PathMustBeRelative' -Message ('[[CapsulenvText:PersistRelocation.PathMustBeRelative.Message]]' -f $RelativePath) -TargetObject $RelativePath)
    }
    $root = [System.IO.Path]::GetFullPath($PersistRoot).TrimEnd('\', '/')
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Relocation.Persist.PathEscapesStore' -Message ('[[CapsulenvText:PersistRelocation.PathEscapesStore.Message]]' -f $RelativePath) -TargetObject $RelativePath -Context ([ordered]@{ PersistRoot=$root }))
    }
    return $candidate
}

function Get-CapsulenvPersistRelocationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$RelocationContext,
        [string[]]$Apps
    )

    if (-not $RelocationContext.HasPathChanges) {
        return @()
    }

    $configuration = Get-CapsulenvConfiguration
    $repairs = $configuration.Scoop.RelocationRepairs
    $selectedApps = if ($Apps -and $Apps.Count -gt 0) {
        @($Apps | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    } else {
        @($repairs.Keys | Sort-Object)
    }

    $plan = New-Object System.Collections.Generic.List[object]
    $plannedPaths = @{}
    foreach ($app in $selectedApps) {
        if (-not $repairs.ContainsKey($app)) {
            throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Relocation.Persist.RepairNotConfigured' -Message ('[[CapsulenvText:PersistRelocation.RepairNotConfigured.Message]]' -f $app) -TargetObject $app)
        }
        $persistRoots = @(Get-CapsulenvPersistRootsForApp -App $app)
        if ($persistRoots.Count -eq 0) {
            continue
        }

        foreach ($rule in @($repairs[$app])) {
            $relativePath = [string]$rule.Path
            $format = if ($rule.ContainsKey('Format')) { [string]$rule.Format } else { 'text' }
            $required = $rule.ContainsKey('Required') -and [bool]$rule.Required
            $maxBytes = if ($rule.ContainsKey('MaxBytes')) { [int64]$rule.MaxBytes } else { 16777216 }
            $processes = if ($rule.ContainsKey('Processes')) { @($rule.Processes | ForEach-Object { [string]$_ }) } else { @() }

            foreach ($persistRoot in $persistRoots) {
                $path = Resolve-CapsulenvPersistRepairPath -PersistRoot $persistRoot -RelativePath $relativePath
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                    if ($required) {
                        throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Relocation.Persist.RequiredFileMissing' -Message ('[[CapsulenvText:PersistRelocation.RequiredFileMissing.Message]]' -f $path) -TargetObject $path -Context ([ordered]@{ App=$app; RelativePath=$relativePath }))
                    }
                    continue
                }
                $length = (Get-Item -LiteralPath $path).Length
                if ($length -gt $maxBytes) {
                    throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Relocation.Persist.FileTooLarge' -Message ('[[CapsulenvText:PersistRelocation.FileTooLarge.Message]]' -f $maxBytes, $path) -TargetObject $path -Context ([ordered]@{ MaxBytes=$maxBytes; ActualBytes=$length; App=$app }))
                }

                $pathKey = $path.ToLowerInvariant()
                if ($plannedPaths.ContainsKey($pathKey)) {
                    throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Relocation.Persist.DuplicateTarget' -Message ('[[CapsulenvText:PersistRelocation.DuplicateTarget.Message]]' -f $path) -TargetObject $path -Context ([ordered]@{ App=$app; RelativePath=$relativePath }))
                }
                $plannedPaths[$pathKey] = $true

                $source = Read-CapsulenvRelocationTextFile -Path $path
                Assert-CapsulenvRelocationRuleFile -Text $source.Text -Format $format -Path $path
                $relocated = Convert-CapsulenvRelocatedText -Text $source.Text -RelocationContext $RelocationContext
                if (-not $relocated.Changed) {
                    continue
                }
                Assert-CapsulenvRelocationRuleFile -Text $relocated.Text -Format $format -Path $path
                $newBytes = ConvertTo-CapsulenvEncodedBytes `
                    -Text $relocated.Text `
                    -Encoding $source.Encoding `
                    -IncludePreamble ([bool]$source.HasPreamble)

                $plan.Add([pscustomobject]@{
                    App = $app
                    Path = $path
                    RelativePath = $relativePath
                    Format = $format
                    Processes = $processes
                    OriginalBytes = $source.Bytes
                    NewBytes = $newBytes
                    ReplacementCount = [int]$relocated.ReplacementCount
                })
            }
        }
    }

    return $plan.ToArray()
}

function Assert-CapsulenvPersistRepairProcessesStopped {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Plan)

    $names = @(
        $Plan |
            ForEach-Object { @($_.Processes) } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Sort-Object -Unique
    )
    foreach ($name in $names) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) {
            throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Relocation.Persist.ProcessRunning' -Message ('[[CapsulenvText:PersistRelocation.ProcessRunning.Message]]' -f $name) -TargetObject $name -Remediation @("Close '$name' and retry the relocation repair."))
        }
    }
}

function Test-CapsulenvByteArrayEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][byte[]]$Left,
        [Parameter(Mandatory = $true)][byte[]]$Right
    )

    if ($Left.Length -ne $Right.Length) {
        return $false
    }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) {
            return $false
        }
    }
    return $true
}

function Invoke-CapsulenvPersistRelocationRepair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$RelocationContext,
        [string[]]$Apps,
        [switch]$DryRun
    )

    $plan = @(Get-CapsulenvPersistRelocationPlan -RelocationContext $RelocationContext -Apps $Apps)
    if ($plan.Count -eq 0) {
        Write-CapsulenvMessage -Level Detail -Message 'No allow-listed Scoop persist files contain paths from the previous capsule location.'
        return [pscustomobject]@{ FilesChanged = 0; Replacements = 0; DryRun = [bool]$DryRun }
    }

    $totalReplacements = [int](($plan | Measure-Object -Property ReplacementCount -Sum).Sum)
    if ($DryRun) {
        foreach ($item in $plan) {
            Write-CapsulenvMessage -Level Detail -Message ("Would repair {0}: {1} replacement(s)" -f $item.Path, $item.ReplacementCount)
        }
        return [pscustomobject]@{ FilesChanged = $plan.Count; Replacements = $totalReplacements; DryRun = $true }
    }

    Assert-CapsulenvPersistRepairProcessesStopped -Plan $plan
    $prepared = New-Object System.Collections.Generic.List[object]
    $preserveRollbackFiles = $false
    try {
        foreach ($item in $plan) {
            Assert-CapsulenvPersistRepairProcessesStopped -Plan @($item)
            $directory = Split-Path -Parent $item.Path
            $token = [Guid]::NewGuid().ToString('N')
            $tempPath = Join-Path $directory ('.capsulenv-relocation-{0}.tmp' -f $token)
            $rollbackPath = Join-Path $directory ('.capsulenv-relocation-{0}.rollback' -f $token)
            $entry = [pscustomobject]@{
                Path = $item.Path
                TempPath = $tempPath
                RollbackPath = $rollbackPath
                Applied = $false
            }
            $prepared.Add($entry)

            $currentBytes = [System.IO.File]::ReadAllBytes($item.Path)
            if (-not (Test-CapsulenvByteArrayEqual -Left $currentBytes -Right ([byte[]]$item.OriginalBytes))) {
                throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Relocation.Persist.ChangedAfterValidation' -Message ('[[CapsulenvText:PersistRelocation.ChangedAfterValidation.Message]]' -f $item.Path) -TargetObject $item.Path -Remediation @('Retry after the owning application has stopped changing the file.'))
            }
            [System.IO.File]::WriteAllBytes($tempPath, [byte[]]$item.NewBytes)
            [System.IO.File]::Replace($tempPath, $item.Path, $rollbackPath, $true)
            $entry.Applied = $true
            Write-CapsulenvMessage -Level Detail -Message ("Repaired {0}: {1} replacement(s)" -f $item.Path, $item.ReplacementCount)
        }
    } catch {
        $originalError = $_
        $rollbackFailures = New-Object System.Collections.Generic.List[string]
        $rollbackFailurePaths = New-Object System.Collections.Generic.List[string]
        for ($index = $prepared.Count - 1; $index -ge 0; $index--) {
            $entry = $prepared[$index]
            if (-not (Test-Path -LiteralPath $entry.RollbackPath -PathType Leaf)) {
                continue
            }
            try {
                [System.IO.File]::Copy($entry.RollbackPath, $entry.Path, $true)
            } catch {
                $rollbackFailurePaths.Add([string]$entry.Path)
                $rollbackFailures.Add("$($entry.Path): $($_.Exception.Message)")
            }
        }
        if ($rollbackFailures.Count -gt 0) {
            $preserveRollbackFiles = $true
            throw (New-CapsulenvDiagnosticErrorRecord `
                -Id 'Capsulenv.Relocation.Persist.RollbackFailed' `
                -Message '[[CapsulenvText:PersistRelocation.RollbackFailed.Message]]' `
                -Cause $originalError `
                -Context ([ordered]@{ RollbackFailureCount=$rollbackFailures.Count; Paths=$rollbackFailurePaths.ToArray() }) `
                -Remediation @('Inspect the preserved .capsulenv-relocation-*.rollback files before retrying.'))
        }
        throw $originalError
    } finally {
        foreach ($entry in $prepared.ToArray()) {
            if (Test-Path -LiteralPath $entry.TempPath -PathType Leaf) {
                Remove-Item -LiteralPath $entry.TempPath -Force
            }
            if (-not $preserveRollbackFiles -and (Test-Path -LiteralPath $entry.RollbackPath -PathType Leaf)) {
                Remove-Item -LiteralPath $entry.RollbackPath -Force
            }
        }
    }

    Write-CapsulenvMessage -Level Success -Message ("Repaired {0} Scoop-persisted configuration file(s) for the new capsule location." -f $plan.Count)
    return [pscustomobject]@{ FilesChanged = $plan.Count; Replacements = $totalReplacements; DryRun = $false }
}

Register-CapsulenvDoctorCheck -Id 'Capsulenv.Doctor.Relocation.PersistRepair' -Area 'Relocation' -Name 'Persist path repair' -Importance Optional -Handler {
    $configuration = Get-CapsulenvConfiguration
    $context = Get-CapsulenvRelocationContext
    $configuredRepairFiles = [int](@($configuration.Scoop.RelocationRepairs.Keys | ForEach-Object { @($configuration.Scoop.RelocationRepairs[$_]).Count } | Measure-Object -Sum).Sum)
    $moves = @($context.PathMappings | ForEach-Object { '{0}: {1} -> {2}' -f $_.Name, $_.OldPath, $_.NewPath })
    $detail = if ($context.HasPathChanges) { "Pending (source=$($context.PreviousSource)); $configuredRepairFiles allow-listed file rule(s); $($moves -join '; ')" } else { "$configuredRepairFiles allow-listed file rule(s); no pending path relocation" }
    New-CapsulenvDoctorResult -Id 'Capsulenv.Doctor.Relocation.PersistRepair' -Name 'Persist path repair' -Area 'Relocation' -Status $(if($context.HasPathChanges){'Advisory'}else{'Healthy'}) -Importance Optional -Summary $detail -Detail $detail -Data ([ordered]@{ ConfiguredRepairFiles=$configuredRepairFiles; HasPathChanges=[bool]$context.HasPathChanges; Mappings=@($context.PathMappings) }) -Remediation $(if($context.HasPathChanges){@('Run capsulenv rehydrate to apply allow-listed persist relocation repairs.')}else{@()})
}

##MOD_EXEC## Export-ModuleMember -Function Invoke-CapsulenvPersistRelocationRepair
