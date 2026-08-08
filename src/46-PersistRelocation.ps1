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
        throw "Persist repair only accepts valid UTF text files: $Path"
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
                throw "Persist relocation JSON validation failed for $Path`: $($_.Exception.Message)"
            }
        }
        default { throw "Unsupported persist relocation format '$Format' for $Path" }
    }
}

function Get-CapsulenvPersistRootsForApp {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$App)

    $roots = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($scoopRoot in @((Get-CapsulenvScoopRoot), (Get-CapsulenvScoopGlobalRoot))) {
        $candidate = Join-Path (Join-Path $scoopRoot 'persist') $App
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
        throw "Persist repair paths must be relative: $RelativePath"
    }
    $root = [System.IO.Path]::GetFullPath($PersistRoot).TrimEnd('\', '/')
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Persist repair path escapes its app store: $RelativePath"
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
            throw "No persist relocation repair is configured for Scoop app '$app'."
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
                        throw "Required persist relocation file is missing: $path"
                    }
                    continue
                }
                $length = (Get-Item -LiteralPath $path).Length
                if ($length -gt $maxBytes) {
                    throw "Persist relocation file exceeds its MaxBytes limit ($maxBytes): $path"
                }

                $pathKey = $path.ToLowerInvariant()
                if ($plannedPaths.ContainsKey($pathKey)) {
                    throw "Duplicate persist relocation rule resolves to the same file: $path"
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
            throw "Close '$name' before repairing its Scoop-persisted configuration."
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
                throw "Persist relocation file changed after validation; refusing to overwrite it: $($item.Path)"
            }
            [System.IO.File]::WriteAllBytes($tempPath, [byte[]]$item.NewBytes)
            [System.IO.File]::Replace($tempPath, $item.Path, $rollbackPath, $true)
            $entry.Applied = $true
            Write-CapsulenvMessage -Level Detail -Message ("Repaired {0}: {1} replacement(s)" -f $item.Path, $item.ReplacementCount)
        }
    } catch {
        $originalError = $_
        $rollbackFailures = New-Object System.Collections.Generic.List[string]
        for ($index = $prepared.Count - 1; $index -ge 0; $index--) {
            $entry = $prepared[$index]
            if (-not (Test-Path -LiteralPath $entry.RollbackPath -PathType Leaf)) {
                continue
            }
            try {
                [System.IO.File]::Copy($entry.RollbackPath, $entry.Path, $true)
            } catch {
                $rollbackFailures.Add("$($entry.Path): $($_.Exception.Message)")
            }
        }
        if ($rollbackFailures.Count -gt 0) {
            $preserveRollbackFiles = $true
            throw ("Persist relocation failed: {0}. Rollback also failed; recovery files were preserved: {1}" -f `
                $originalError.Exception.Message, ($rollbackFailures.ToArray() -join '; '))
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

##MOD_EXEC## Export-ModuleMember -Function Invoke-CapsulenvPersistRelocationRepair
