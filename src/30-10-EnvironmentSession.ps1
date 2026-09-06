function Get-CapsulenvControlLauncherPath {
    [CmdletBinding()]
    param()

    $root = (Get-CapsulenvContext).Root
    $installed = Join-Path $root 'capsulenv.cmd'
    if (Test-Path -LiteralPath $installed -PathType Leaf) {
        return [System.IO.Path]::GetFullPath($installed)
    }

    # Development checkouts deliberately do not expose capsulenv.cmd at root.
    # Keep the interactive `capsulenv` function useful there without weakening
    # the installed/source root-role boundary.
    $development = Join-Path $root 'scripts\capsulenv-dev.cmd'
    if (Test-Path -LiteralPath $development -PathType Leaf) {
        return [System.IO.Path]::GetFullPath($development)
    }

    # Preserve the intended installed location in plans built for an incomplete
    # test/staging root. Invocation still fails closed if the file is absent.
    return [System.IO.Path]::GetFullPath($installed)
}

function Get-CapsulenvEnvironmentPlan {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    $context = Get-CapsulenvContext
    $scoopRoot = Resolve-CapsulenvPath -Path $configuration.Scoop.Root -AllowMissing
    $scoopGlobalRoot = Resolve-CapsulenvPath -Path $configuration.Scoop.GlobalRoot -AllowMissing
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($scoopRoot, $scoopGlobalRoot)) {
        throw 'Scoop.Root and Scoop.GlobalRoot must resolve to different directories.'
    }

    $variables = [ordered]@{
        CAPSULENV_ROOT = $context.Root
        CAPSULENV_LAUNCHER = (Get-CapsulenvControlLauncherPath)
        SCOOP = $scoopRoot
        SCOOP_GLOBAL = $scoopGlobalRoot
        SCOOP_CACHE = (Resolve-CapsulenvPath -Path ([string]$configuration.Scoop.Cache) -AllowMissing)
        CAPSULENV_ID = (Get-CapsulenvIdentity)
        CAPSULENV_SCRATCH = (Get-CapsulenvScratchPath)
        CAPSULENV_TOOL_DATA_ROOT = (Resolve-CapsulenvPath -Path 'tool-data' -AllowMissing)
        CAPSULENV_CACHE_ROOT = (Resolve-CapsulenvPath -Path 'cache' -AllowMissing)
        CAPSULENV_PROJECT_CACHE_ROOT = (Resolve-CapsulenvPath -Path 'project-cache' -AllowMissing)
    }

    if ($configuration.Bitwarden.Enabled -and $configuration.Bitwarden.SetSshAuthSock) {
        $variables['SSH_AUTH_SOCK'] = '\\.\pipe\openssh-ssh-agent'
    }

    foreach ($name in $configuration.Environment.PathVariables.Keys) {
        $variables[$name] = Resolve-CapsulenvPath `
            -Path ([string]$configuration.Environment.PathVariables[$name]) `
            -AllowMissing
    }
    foreach ($name in $configuration.Environment.Variables.Keys) {
        $variables[$name] = [Environment]::ExpandEnvironmentVariables(
            [string]$configuration.Environment.Variables[$name]
        )
    }

    $toolStorage = Get-CapsulenvToolStoragePlan
    foreach ($name in $toolStorage.Variables.Keys) {
        $variables[$name] = [string]$toolStorage.Variables[$name]
    }

    $modulePathEntries = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($configuration.Environment.ModulePath)) {
        $resolved = Resolve-CapsulenvPath -Path ([string]$entry) -AllowMissing
        if (-not ($modulePathEntries -contains $resolved)) {
            $modulePathEntries.Add($resolved)
        }
    }
    if ($modulePathEntries.Count -gt 0) {
        $variables['CAPSULENV_MODULE_ROOT'] = $modulePathEntries[0]
    }

    $pathEntries = New-Object System.Collections.Generic.List[string]
    # The active capsule control plane must win command resolution before any
    # package/Scoop shim directories. PowerShell also installs an exact-bound
    # `capsulenv` function for interactive shells; this PATH entry is the
    # compatibility surface for cmd.exe and child processes.
    if (-not ($pathEntries -contains $context.Root)) {
        $pathEntries.Add($context.Root)
    }
    $packageShims = Get-CapsulenvPackageShimRoot
    if (-not ($pathEntries -contains $packageShims)) {
        $pathEntries.Add($packageShims)
    }
    # PowerShell resolves the genuine upstream dispatcher before Scoop's shim
    # directory. `scoop` therefore means upstream Scoop rather than a Capsulenv
    # command gateway. scoop.cmd remains only a cmd.exe compatibility trampoline.
    $scoopBin = Join-Path $variables.SCOOP 'apps\scoop\current\bin'
    if (-not ($pathEntries -contains $scoopBin)) {
        $pathEntries.Add($scoopBin)
    }
    foreach ($scoopShims in @(
        (Join-Path $variables.SCOOP 'shims'),
        (Join-Path $variables.SCOOP_GLOBAL 'shims')
    )) {
        if (-not ($pathEntries -contains $scoopShims)) {
            $pathEntries.Add($scoopShims)
        }
    }
    foreach ($entry in $configuration.Environment.Path) {
        $resolved = Resolve-CapsulenvPath -Path ([string]$entry) -AllowMissing
        if (-not ($pathEntries -contains $resolved)) {
            $pathEntries.Add($resolved)
        }
    }
    foreach ($entry in $toolStorage.PathEntries) {
        if (-not ($pathEntries -contains $entry)) {
            $pathEntries.Add($entry)
        }
    }

    return [pscustomobject]@{
        Variables = $variables
        PathEntries = $pathEntries.ToArray()
        ModulePathEntries = $modulePathEntries.ToArray()
        Directories = @($toolStorage.Directories) + @([string]$variables.CAPSULENV_SCRATCH)
    }
}

function Merge-CapsulenvPath {
    [CmdletBinding()]
    param(
        [string]$ExistingPath,
        [Parameter(Mandatory = $true)][string[]]$Prepend
    )

    $result = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($item in @($Prepend) + @($ExistingPath -split ';')) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            continue
        }
        $trimmed = $item.Trim()
        $normalized = $trimmed.TrimEnd([char[]]'\/')
        if (-not $seen.ContainsKey($normalized)) {
            $seen[$normalized] = $true
            $result.Add($trimmed)
        }
    }
    return ($result -join ';')
}

function Merge-CapsulenvModulePath {
    [CmdletBinding()]
    param(
        [string]$ExistingPath,
        [Parameter(Mandatory = $true)][string[]]$Prepend
    )

    $separator = [System.IO.Path]::PathSeparator
    $result = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($item in @($Prepend) + @($ExistingPath -split [regex]::Escape([string]$separator))) {
        if ([string]::IsNullOrWhiteSpace($item)) {
            continue
        }
        $trimmed = $item.Trim()
        $normalized = $trimmed.TrimEnd([char[]]'\/')
        if (-not $seen.ContainsKey($normalized)) {
            $seen[$normalized] = $true
            $result.Add($trimmed)
        }
    }
    return ($result -join [string]$separator)
}

function Select-CapsulenvForeignScoopShimPaths {
    [CmdletBinding()]
    param(
        [string]$ExistingPath,
        [string[]]$CandidateRoots
    )

    $capsuleRoots = @(
        ([System.IO.Path]::GetFullPath((Get-CapsulenvScoopRoot))).TrimEnd('\', '/'),
        ([System.IO.Path]::GetFullPath((Get-CapsulenvScoopGlobalRoot))).TrimEnd('\', '/')
    )
    $pathEntries = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($ExistingPath -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        try {
            $full = [System.IO.Path]::GetFullPath($entry.Trim()).TrimEnd('\', '/')
        } catch {
            continue
        }
        if (-not ($pathEntries | Where-Object { [System.StringComparer]::OrdinalIgnoreCase.Equals($_, $full) })) {
            $pathEntries.Add($full)
        }
    }

    $result = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @($CandidateRoots)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            $root = [System.IO.Path]::GetFullPath($candidate).TrimEnd('\', '/')
        } catch {
            continue
        }
        $owned = $false
        foreach ($capsuleRoot in $capsuleRoots) {
            if ([System.StringComparer]::OrdinalIgnoreCase.Equals($root, $capsuleRoot)) {
                $owned = $true
                break
            }
        }
        if ($owned) { continue }

        $shim = [System.IO.Path]::GetFullPath((Join-Path $root 'shims')).TrimEnd('\', '/')
        if (-not ($pathEntries | Where-Object { [System.StringComparer]::OrdinalIgnoreCase.Equals($_, $shim) })) { continue }
        if (-not ($result | Where-Object { [System.StringComparer]::OrdinalIgnoreCase.Equals($_, $shim) })) {
            $result.Add($shim)
        }
    }
    return $result.ToArray()
}

function Get-CapsulenvForeignScoopShimPaths {
    [CmdletBinding()]
    param([string]$ExistingPath = $env:PATH)

    # Steady session setup only needs evidence visible to the current process.
    # Persistent User/Machine environment and the reversible User backup cannot
    # affect current command resolution unless their paths were inherited into
    # this process, in which case Process SCOOP* / PATH already provide evidence.
    $candidateRoots = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('SCOOP', 'SCOOP_GLOBAL')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not [string]::IsNullOrWhiteSpace($value)) { $candidateRoots.Add($value) }
    }
    if (Test-CapsulenvWindows) {
        $userProfile = [Environment]::GetFolderPath('UserProfile')
        if (-not [string]::IsNullOrWhiteSpace($userProfile)) { $candidateRoots.Add((Join-Path $userProfile 'scoop')) }
        $programData = [Environment]::GetEnvironmentVariable('ProgramData', 'Process')
        if (-not [string]::IsNullOrWhiteSpace($programData)) { $candidateRoots.Add((Join-Path $programData 'scoop')) }
    }
    return @(Select-CapsulenvForeignScoopShimPaths -ExistingPath $ExistingPath -CandidateRoots $candidateRoots.ToArray())
}

function Get-CapsulenvPersistentForeignScoopShimPaths {
    [CmdletBinding()]
    param([string]$ExistingPath)

    # Persistent User synchronization is explicit/low-frequency, so it may use
    # broader evidence to clean stale host Scoop paths from persistent PATH.
    $candidateRoots = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('SCOOP', 'SCOOP_GLOBAL')) {
        foreach ($target in @('Process', 'User', 'Machine')) {
            try {
                $value = [Environment]::GetEnvironmentVariable($name, $target)
                if (-not [string]::IsNullOrWhiteSpace($value)) { $candidateRoots.Add($value) }
            } catch {
                # User/Machine targets are unavailable on some test hosts.
            }
        }
    }

    $backupPath = Get-CapsulenvUserEnvironmentBackupPath
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        try {
            $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
            foreach ($name in @('SCOOP', 'SCOOP_GLOBAL')) {
                $property = $backup.PSObject.Properties[$name]
                if ($null -ne $property -and [bool]$property.Value.Exists -and -not [string]::IsNullOrWhiteSpace([string]$property.Value.Value)) {
                    $candidateRoots.Add([string]$property.Value.Value)
                }
            }
        } catch {
            Write-CapsulenvMessage -Level Warning -Message "Ignoring unreadable User environment backup while isolating host Scoop shims: $($_.Exception.Message)"
        }
    }

    if (Test-CapsulenvWindows) {
        $userProfile = [Environment]::GetFolderPath('UserProfile')
        if (-not [string]::IsNullOrWhiteSpace($userProfile)) { $candidateRoots.Add((Join-Path $userProfile 'scoop')) }
        $programData = [Environment]::GetEnvironmentVariable('ProgramData', 'Process')
        if (-not [string]::IsNullOrWhiteSpace($programData)) { $candidateRoots.Add((Join-Path $programData 'scoop')) }
    }
    return @(Select-CapsulenvForeignScoopShimPaths -ExistingPath $ExistingPath -CandidateRoots $candidateRoots.ToArray())
}

function Set-CapsulenvSessionEnvironment {
    [CmdletBinding()]
    param(
        [ValidateSet('ShellOnly', 'User')]
        [string]$IntegrationMode = (Get-CapsulenvInstallMode)
    )

    $plan = Get-CapsulenvEnvironmentPlan
    $configuration = Get-CapsulenvConfiguration
    if ($configuration.ToolStorage.Enabled -and $configuration.ToolStorage.CreateDirectories) {
        [void](Initialize-CapsulenvToolStorage)
    }
    foreach ($directory in @($plan.Directories)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $directory -Force)
        }
    }
    foreach ($modulePathEntry in @($plan.ModulePathEntries)) {
        if (-not (Test-Path -LiteralPath $modulePathEntry -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $modulePathEntry -Force)
        }
    }
    $foreignScoopShimPaths = @(Get-CapsulenvForeignScoopShimPaths -ExistingPath $env:PATH)
    foreach ($name in $plan.Variables.Keys) {
        [Environment]::SetEnvironmentVariable($name, [string]$plan.Variables[$name], 'Process')
    }
    # Session mode remains process-only; package safety is selected by the
    # Capsulenv command surface rather than by rewriting Scoop lifecycle code.
    [Environment]::SetEnvironmentVariable('CAPSULENV_MODE', $IntegrationMode, 'Process')
    $sessionPath = Remove-CapsulenvPathEntries `
        -ExistingPath $env:PATH `
        -Remove $foreignScoopShimPaths
    $env:PATH = Merge-CapsulenvPath -ExistingPath $sessionPath -Prepend $plan.PathEntries
    $env:PSModulePath = Merge-CapsulenvModulePath -ExistingPath $env:PSModulePath -Prepend $plan.ModulePathEntries
    return $plan
}

##MOD_EXEC## Export-ModuleMember -Function Set-CapsulenvSessionEnvironment
