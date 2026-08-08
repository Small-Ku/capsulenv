function Test-CapsulenvPortableToolExecutable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $probe = Invoke-CapsulenvNativeToolCapture `
            -Executable $Path `
            -Arguments @('--version') `
            -AllowFailure
        return $probe.ExitCode -eq 0
    } catch {
        return $false
    }
}

function Get-CapsulenvPortableToolExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Candidates,
        [Parameter(Mandatory = $true)][string[]]$CommandNames
    )

    foreach ($candidate in $Candidates) {
        $resolved = Resolve-CapsulenvPath -Path $candidate -AllowMissing
        if (
            (Test-Path -LiteralPath $resolved -PathType Leaf) -and
            (Test-CapsulenvPortableToolExecutable -Path $resolved)
        ) {
            return $resolved
        }
    }

    $root = (Get-CapsulenvContext).Root.TrimEnd([char[]]'\/')
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    foreach ($name in $CommandNames) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            continue
        }
        $source = [System.IO.Path]::GetFullPath([string]$command.Source)
        if (
            (
                [System.StringComparer]::OrdinalIgnoreCase.Equals($source, $root) -or
                $source.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
            ) -and
            (Test-CapsulenvPortableToolExecutable -Path $source)
        ) {
            return $source
        }
    }
    return $null
}

function Get-CapsulenvUvExecutable {
    [CmdletBinding()]
    param()

    return Get-CapsulenvPortableToolExecutable `
        -Candidates @(
            'scoop\shims\uv.exe'
            'scoop\apps\uv\current\uv.exe'
            'scoop-global\shims\uv.exe'
            'scoop-global\apps\uv\current\uv.exe'
            'tool-data\cargo\bin\uv.exe'
            'bin\uv.exe'
        ) `
        -CommandNames @('uv.exe', 'uv')
}

function Invoke-CapsulenvNativeTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
        [string]$WorkingDirectory,
        [switch]$AllowFailure
    )

    $previous = $null
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $previous = Get-Location
        Set-Location -LiteralPath $WorkingDirectory
    }
    try {
        Clear-CapsulenvLastExitCode
        & $Executable @Arguments
        $succeeded = $?
        $exitCode = Get-CapsulenvLastExitCode -Succeeded $succeeded
    } finally {
        if ($null -ne $previous) {
            Set-Location -LiteralPath $previous.Path
        }
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Native tool failed with exit code ${exitCode}: $Executable $($Arguments -join ' ')"
    }
    return $exitCode
}

function Invoke-CapsulenvNativeToolCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
        [string]$WorkingDirectory,
        [switch]$AllowFailure
    )

    $token = [Guid]::NewGuid().ToString('N')
    $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("capsulenv-native-$token.stdout")
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("capsulenv-native-$token.stderr")
    $previous = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $previous = Get-Location
            Set-Location -LiteralPath $WorkingDirectory
        }
        Clear-CapsulenvLastExitCode
        & $Executable @Arguments 1> $stdoutPath 2> $stderrPath
        $succeeded = $?
        $exitCode = Get-CapsulenvLastExitCode -Succeeded $succeeded
        $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
            [System.IO.File]::ReadAllText($stdoutPath)
        } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            [System.IO.File]::ReadAllText($stderrPath)
        } else { '' }
    } finally {
        if ($null -ne $previous) {
            Set-Location -LiteralPath $previous.Path
        }
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $detail = $stderr.Trim()
        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = $stdout.Trim()
        }
        throw "Native tool failed with exit code $exitCode`: $Executable $($Arguments -join ' ')`n$detail"
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        StdOut = $stdout
        StdErr = $stderr
    }
}

function Get-CapsulenvToolRelocationConfiguration {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    return $configuration.ToolStorage.Relocation
}

function Get-CapsulenvUvToolDirectory {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    return Resolve-CapsulenvPath -Path ([string]$configuration.ToolStorage.PathVariables.UV_TOOL_DIR) -AllowMissing
}

function Get-CapsulenvUvPythonDirectory {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    return Resolve-CapsulenvPath -Path ([string]$configuration.ToolStorage.PathVariables.UV_PYTHON_INSTALL_DIR) -AllowMissing
}

function Get-CapsulenvUvToolReceipts {
    [CmdletBinding()]
    param()

    $root = Get-CapsulenvUvToolDirectory
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return @()
    }
    return @(
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $receipt = Join-Path $_.FullName 'uv-receipt.toml'
                if (Test-Path -LiteralPath $receipt -PathType Leaf) {
                    [pscustomobject]@{
                        Name = $_.Name
                        ToolDirectory = $_.FullName
                        ReceiptPath = $receipt
                    }
                }
            }
    )
}

function ConvertTo-CapsulenvNormalizedPythonPackageName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    return (($Name.ToLowerInvariant() -replace '[-_.]+', '-').Trim('-'))
}

function Get-CapsulenvUvInstalledToolVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ToolName,
        [Parameter(Mandatory = $true)][string]$ToolDirectory
    )

    $expected = ConvertTo-CapsulenvNormalizedPythonPackageName -Name $ToolName
    $metadataFiles = @(
        Get-ChildItem -LiteralPath $ToolDirectory -Recurse -Filter 'METADATA' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -match '\.dist-info$' }
    )
    foreach ($metadata in $metadataFiles) {
        $name = $null
        $version = $null
        foreach ($line in @(Get-Content -LiteralPath $metadata.FullName -TotalCount 80 -ErrorAction SilentlyContinue)) {
            if ($null -eq $name -and $line -match '^Name:\s*(.+?)\s*$') {
                $name = $Matches[1]
            } elseif ($null -eq $version -and $line -match '^Version:\s*(.+?)\s*$') {
                $version = $Matches[1]
            }
            if ($null -ne $name -and $null -ne $version) {
                break
            }
        }
        if (
            -not [string]::IsNullOrWhiteSpace($name) -and
            -not [string]::IsNullOrWhiteSpace($version) -and
            (ConvertTo-CapsulenvNormalizedPythonPackageName -Name $name) -eq $expected
        ) {
            return [string]$version
        }
    }
    return $null
}

function Get-CapsulenvUvFirstRequirementTable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ReceiptText)

    $match = [regex]::Match(
        $ReceiptText,
        '(?ms)^\s*requirements\s*=\s*\[\s*(?<table>\{.*?\})',
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    if (-not $match.Success) {
        return $null
    }
    $table = $match.Groups['table']
    $nameMatch = [regex]::Match($table.Value, '\bname\s*=\s*"(?<value>(?:\\.|[^"])*)"')
    if (-not $nameMatch.Success) {
        return $null
    }
    return [pscustomobject]@{
        Index = $table.Index
        Length = $table.Length
        Text = $table.Value
        Name = [regex]::Unescape($nameMatch.Groups['value'].Value)
    }
}

function Write-CapsulenvUvReceiptText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "uv receipt disappeared before it could be updated: $Path"
    }
    $parent = Split-Path -Parent $Path
    $temporary = Join-Path $parent ('.uv-receipt-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($temporary, $Text, [System.Text.UTF8Encoding]::new($false))
    try {
        [System.IO.File]::Replace($temporary, $Path, $null, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-CapsulenvTextReferencesRelocation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)]$RelocationContext
    )

    if ($null -eq $RelocationContext -or -not $RelocationContext.HasPathChanges) {
        return $false
    }
    $converted = Convert-CapsulenvRelocatedText -Text $Text -RelocationContext $RelocationContext
    return [int]$converted.ReplacementCount -gt 0
}

function Get-CapsulenvUvManagedPythonInstallations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$UvExecutable)

    $pythonRoot = [System.IO.Path]::GetFullPath((Get-CapsulenvUvPythonDirectory)).TrimEnd([char[]]'\/')
    $result = Invoke-CapsulenvNativeToolCapture `
        -Executable $UvExecutable `
        -Arguments @(
            'python', 'list',
            '--only-installed',
            '--output-format', 'json',
            '--managed-python',
            '--no-python-downloads',
            '--no-progress'
        )
    try {
        $items = @($result.StdOut | ConvertFrom-Json)
    } catch {
        throw "uv returned invalid JSON while listing managed Python installations: $($_.Exception.Message)"
    }

    $prefix = $pythonRoot + [System.IO.Path]::DirectorySeparatorChar
    $seen = @{}
    $installations = New-Object System.Collections.Generic.List[object]
    foreach ($item in $items) {
        $key = [string]$item.key
        $path = [string]$item.path
        if ([string]::IsNullOrWhiteSpace($key) -or [string]::IsNullOrWhiteSpace($path)) {
            continue
        }
        try {
            $fullPath = [System.IO.Path]::GetFullPath($path)
        } catch {
            continue
        }
        if (
            -not [System.StringComparer]::OrdinalIgnoreCase.Equals($fullPath, $pythonRoot) -and
            -not $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            continue
        }
        $identity = $key.ToLowerInvariant()
        if ($seen.ContainsKey($identity)) {
            continue
        }
        $seen[$identity] = $true
        $installations.Add([pscustomobject]@{
            Key = $key
            Version = [string]$item.version
            Path = $fullPath
        })
    }
    return $installations.ToArray()
}

function Repair-CapsulenvUvManagedPython {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$UvExecutable,
        [switch]$DryRun
    )

    $pythonRoot = Get-CapsulenvUvPythonDirectory
    $installations = @(Get-CapsulenvUvManagedPythonInstallations -UvExecutable $UvExecutable)
    if ($installations.Count -eq 0) {
        return @([pscustomobject]@{ Component = 'uv-python'; Status = 'NotInstalled'; Changed = $false; Detail = $pythonRoot })
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($installation in $installations) {
        if ($DryRun) {
            $results.Add([pscustomobject]@{
                Component = "uv-python:$($installation.Key)"
                Status = 'WouldReinstall'
                Changed = $false
                Detail = $installation.Path
            })
            continue
        }
        [void](Invoke-CapsulenvNativeTool `
            -Executable $UvExecutable `
            -Arguments @(
                'python', 'install',
                [string]$installation.Key,
                '--reinstall',
                '--force',
                '--no-progress'
            ))
        $results.Add([pscustomobject]@{
            Component = "uv-python:$($installation.Key)"
            Status = 'Reinstalled'
            Changed = $true
            Detail = $installation.Path
        })
    }
    return $results.ToArray()
}

function Repair-CapsulenvUvGlobalTools {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$UvExecutable,
        [Parameter(Mandatory = $true)]$RelocationContext,
        [switch]$DryRun
    )

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($receipt in @(Get-CapsulenvUvToolReceipts)) {
        $original = [System.IO.File]::ReadAllText($receipt.ReceiptPath)
        $relocated = Convert-CapsulenvRelocatedText -Text $original -RelocationContext $RelocationContext
        $pyvenvPath = Join-Path $receipt.ToolDirectory 'pyvenv.cfg'
        $pyvenvStale = $false
        if (Test-Path -LiteralPath $pyvenvPath -PathType Leaf) {
            $pyvenvText = [System.IO.File]::ReadAllText($pyvenvPath)
            $pyvenvStale = Test-CapsulenvTextReferencesRelocation -Text $pyvenvText -RelocationContext $RelocationContext
        }
        if ([int]$relocated.ReplacementCount -eq 0 -and -not $pyvenvStale) {
            $results.Add([pscustomobject]@{ Component = "uv-tool:$($receipt.Name)"; Status = 'Current'; Changed = $false; Detail = $receipt.ReceiptPath })
            continue
        }

        $requirement = Get-CapsulenvUvFirstRequirementTable -ReceiptText $original
        if ($null -eq $requirement) {
            $results.Add([pscustomobject]@{ Component = "uv-tool:$($receipt.Name)"; Status = 'Unsupported'; Changed = $false; Detail = 'uv receipt does not contain a supported first requirement table.' })
            continue
        }
        $toolName = [string]$requirement.Name
        $version = Get-CapsulenvUvInstalledToolVersion -ToolName $toolName -ToolDirectory $receipt.ToolDirectory
        if ([string]::IsNullOrWhiteSpace($version)) {
            $results.Add([pscustomobject]@{ Component = "uv-tool:$toolName"; Status = 'Unsupported'; Changed = $false; Detail = 'Installed tool version could not be determined safely.' })
            continue
        }

        if ($DryRun) {
            $results.Add([pscustomobject]@{ Component = "uv-tool:$toolName"; Status = 'WouldReinstall'; Changed = $false; Detail = "version $version" })
            continue
        }

        # Relocate the receipt first so uv replays its complete original source,
        # Python and index settings from valid paths. Supplying an exact current
        # version as the command argument prevents an accidental package update
        # without changing the requirement intent stored in the receipt.
        Write-CapsulenvUvReceiptText -Path $receipt.ReceiptPath -Text ([string]$relocated.Text)
        try {
            [void](Invoke-CapsulenvNativeTool `
                -Executable $UvExecutable `
                -Arguments @(
                    'tool', 'upgrade',
                    '--reinstall',
                    '--no-progress',
                    ("{0}=={1}" -f $toolName, $version)
                ))
            $results.Add([pscustomobject]@{ Component = "uv-tool:$toolName"; Status = 'Reinstalled'; Changed = $true; Detail = "version $version" })
        } catch {
            Write-CapsulenvUvReceiptText -Path $receipt.ReceiptPath -Text $original
            throw "Failed to repair uv tool '$toolName': $($_.Exception.Message)"
        }
    }
    return $results.ToArray()
}

function Repair-CapsulenvUvRelocation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$RelocationContext,
        [switch]$DryRun
    )

    $settings = (Get-CapsulenvToolRelocationConfiguration).Uv
    if (-not $settings.Enabled) {
        return @([pscustomobject]@{ Component = 'uv'; Status = 'Disabled'; Changed = $false; Detail = $null })
    }
    $uv = Get-CapsulenvUvExecutable
    if ([string]::IsNullOrWhiteSpace($uv)) {
        return @([pscustomobject]@{ Component = 'uv'; Status = 'NotInstalled'; Changed = $false; Detail = 'Portable uv executable not found.' })
    }

    $results = New-Object System.Collections.Generic.List[object]
    if ($settings.RepairManagedPython) {
        foreach ($result in @(Repair-CapsulenvUvManagedPython -UvExecutable $uv -DryRun:$DryRun)) {
            $results.Add($result)
        }
    }
    if ($settings.RepairGlobalTools) {
        foreach ($result in @(Repair-CapsulenvUvGlobalTools -UvExecutable $uv -RelocationContext $RelocationContext -DryRun:$DryRun)) {
            $results.Add($result)
        }
    }
    return $results.ToArray()
}

function Invoke-CapsulenvToolRelocationRepair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$RelocationContext,
        [ValidateSet('uv', 'pixi', 'all')][string]$Tool = 'all',
        [switch]$DryRun,
        [switch]$Strict,
        [switch]$SkipWorkspaces,
        [switch]$IncludePixiGlobal
    )

    [void](Set-CapsulenvSessionEnvironment)
    $results = New-Object System.Collections.Generic.List[object]

    if ($Tool -in @('uv', 'all')) {
        try {
            foreach ($result in @(Repair-CapsulenvUvRelocation -RelocationContext $RelocationContext -DryRun:$DryRun)) {
                $results.Add($result)
            }
        } catch {
            if ($Strict) {
                throw
            }
            $results.Add([pscustomobject]@{ Component = 'uv'; Status = 'Failed'; Changed = $false; Detail = $_.Exception.Message })
            Write-CapsulenvMessage -Level Warning -Message $_.Exception.Message
        }
    }

    if ($Tool -in @('pixi', 'all')) {
        try {
            foreach ($result in @(Repair-CapsulenvPixiRelocation -DryRun:$DryRun -IncludeGlobal:$IncludePixiGlobal)) {
                $results.Add($result)
            }
        } catch {
            if ($Strict) {
                throw
            }
            $results.Add([pscustomobject]@{ Component = 'pixi-global'; Status = 'Failed'; Changed = $false; Detail = $_.Exception.Message })
            Write-CapsulenvMessage -Level Warning -Message $_.Exception.Message
        }
    }

    if (-not $SkipWorkspaces) {
        try {
            foreach ($result in @(Repair-CapsulenvRegisteredToolWorkspaces -Tool $Tool -DryRun:$DryRun -Strict:$Strict)) {
                $results.Add($result)
            }
        } catch {
            if ($Strict) {
                throw
            }
            $results.Add([pscustomobject]@{ Component = 'workspaces'; Status = 'Failed'; Changed = $false; Detail = $_.Exception.Message })
            Write-CapsulenvMessage -Level Warning -Message $_.Exception.Message
        }
    }
    return $results.ToArray()
}

##MOD_EXEC## Export-ModuleMember -Function Invoke-CapsulenvToolRelocationRepair, Repair-CapsulenvUvRelocation
