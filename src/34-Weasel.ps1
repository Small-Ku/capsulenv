function Get-CapsulenvWeaselInstallation {
    [CmdletBinding()]
    param()

    if (-not (Test-CapsulenvWindows)) {
        return $null
    }

    $machineKey = 'Software\Rime\Weasel'
    $uninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\Weasel'
    $weaselRoot = Get-CapsulenvRegistryStringValue -Hive LocalMachine -SubKey $machineKey -Name 'WeaselRoot'
    $installDir = Get-CapsulenvRegistryStringValue -Hive LocalMachine -SubKey $machineKey -Name 'InstallDir'
    $uninstallString = Get-CapsulenvRegistryStringValue -Hive LocalMachine -SubKey $uninstallKey -Name 'UninstallString'
    $version = Get-CapsulenvRegistryStringValue -Hive LocalMachine -SubKey $uninstallKey -Name 'DisplayVersion'

    # A random Rime-looking directory is not enough. Require official machine
    # install registry evidence before Capsulenv will touch host Weasel state.
    if (
        [string]::IsNullOrWhiteSpace($weaselRoot) -and
        [string]::IsNullOrWhiteSpace($installDir) -and
        [string]::IsNullOrWhiteSpace($uninstallString)
    ) {
        return $null
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @($weaselRoot, $installDir)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
            try { $candidates.Add([System.IO.Path]::GetFullPath([string]$candidate)) } catch {}
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($uninstallString)) {
        $uninstallPath = $uninstallString.Trim().Trim('"')
        if ($uninstallPath -match '^"([^\"]+)"') {
            $uninstallPath = $matches[1]
        } elseif ($uninstallPath -match '^([^\s]+\.exe)') {
            $uninstallPath = $matches[1]
        }
        try {
            $uninstallParent = Split-Path -Parent ([System.IO.Path]::GetFullPath($uninstallPath))
            if (-not [string]::IsNullOrWhiteSpace($uninstallParent)) {
                $candidates.Add($uninstallParent)
            }
        } catch {}
    }
    if (-not [string]::IsNullOrWhiteSpace($installDir) -and (Test-Path -LiteralPath $installDir -PathType Container)) {
        Get-ChildItem -LiteralPath $installDir -Directory -Filter 'weasel-*' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            ForEach-Object { $candidates.Add($_.FullName) }
    }

    $seen = @{}
    $resolvedRoot = $null
    foreach ($candidate in $candidates) {
        try { $full = [System.IO.Path]::GetFullPath([string]$candidate).TrimEnd([char[]]'\/') } catch { continue }
        $key = $full.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        if (
            (Test-Path -LiteralPath (Join-Path $full 'WeaselServer.exe') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $full 'WeaselDeployer.exe') -PathType Leaf)
        ) {
            $resolvedRoot = $full
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($resolvedRoot)) {
        return $null
    }

    $userDataDir = Get-CapsulenvRegistryStringValue `
        -Hive CurrentUser `
        -SubKey 'Software\Rime\Weasel' `
        -Name 'RimeUserDir'
    if ([string]::IsNullOrWhiteSpace($userDataDir) -and -not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $userDataDir = Join-Path $env:APPDATA 'Rime'
    }
    if (-not [string]::IsNullOrWhiteSpace($userDataDir)) {
        try { $userDataDir = [System.IO.Path]::GetFullPath($userDataDir) } catch { $userDataDir = $null }
    }

    return [pscustomobject]@{
        InstallRoot = $resolvedRoot
        ServerPath = Join-Path $resolvedRoot 'WeaselServer.exe'
        DeployerPath = Join-Path $resolvedRoot 'WeaselDeployer.exe'
        UserDataDir = $userDataDir
        Version = $version
        RegistryConfirmed = $true
    }
}

function Get-CapsulenvWeaselSeedRoot {
    [CmdletBinding()]
    param()

    return Resolve-CapsulenvPath -Path 'tool-data\weasel' -AllowMissing
}

function Test-CapsulenvWeaselPathsOverlap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$First,
        [Parameter(Mandatory = $true)][string]$Second
    )

    $firstPath = [System.IO.Path]::GetFullPath($First).TrimEnd([char[]]'\\/')
    $secondPath = [System.IO.Path]::GetFullPath($Second).TrimEnd([char[]]'\\/')
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($firstPath, $secondPath)) {
        return $true
    }
    $separator = [System.IO.Path]::DirectorySeparatorChar
    return (
        $firstPath.StartsWith($secondPath + $separator, [System.StringComparison]::OrdinalIgnoreCase) -or
        $secondPath.StartsWith($firstPath + $separator, [System.StringComparison]::OrdinalIgnoreCase)
    )
}

function Test-CapsulenvWeaselTreeSafeToCopy {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Weasel data directory does not exist: $Path"
    }

    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push([System.IO.Path]::GetFullPath($Path))
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        $root = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
        if (($root.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Weasel seed refuses to traverse a reparse point: $($root.FullName)"
        }
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Weasel seed refuses to traverse a reparse point: $($item.FullName)"
            }
            if ($item.PSIsContainer) {
                $pending.Push($item.FullName)
            }
        }
    }
    return $true
}

function Copy-CapsulenvWeaselTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    [void](Test-CapsulenvWeaselTreeSafeToCopy -Path $Source)
    [void](New-Item -ItemType Directory -Path $Destination -Force)
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
}

function Test-CapsulenvWeaselServerRunning {
    [CmdletBinding()]
    param()

    return ($null -ne (Get-Process -Name 'WeaselServer' -ErrorAction SilentlyContinue | Select-Object -First 1))
}

function Stop-CapsulenvWeaselServer {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Installation)

    Clear-CapsulenvLastExitCode
    & $Installation.ServerPath /quit
    $exitCode = Get-CapsulenvLastExitCode -Succeeded $?
    if ($exitCode -ne 0) {
        throw "WeaselServer /quit failed with exit code $exitCode."
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ((Test-CapsulenvWeaselServerRunning) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if (Test-CapsulenvWeaselServerRunning) {
        throw 'WeaselServer is still running after /quit; refusing to copy live Rime state.'
    }
}

function Start-CapsulenvWeaselServer {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Installation)

    [void](Start-Process -FilePath ([string]$Installation.ServerPath) -WorkingDirectory ([string]$Installation.InstallRoot))
}

function Invoke-CapsulenvWeaselDeploy {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Installation)

    Clear-CapsulenvLastExitCode
    & $Installation.DeployerPath /deploy
    $exitCode = Get-CapsulenvLastExitCode -Succeeded $?
    if ($exitCode -ne 0) {
        throw "WeaselDeployer /deploy failed with exit code $exitCode."
    }
}

function Assert-CapsulenvWeaselInstalledForSeed {
    [CmdletBinding()]
    param()

    $installation = Get-CapsulenvWeaselInstallation
    if ($null -eq $installation -or -not [bool]$installation.RegistryConfirmed) {
        throw 'No registry-confirmed machine installation of Weasel was found. Capsulenv will not seed or restore Rime data on an unconfirmed host.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$installation.UserDataDir)) {
        throw 'Weasel is installed, but its current Rime user data directory could not be resolved.'
    }
    return $installation
}

function Save-CapsulenvWeaselSeed {
    [CmdletBinding()]
    param([switch]$Force)

    $installation = Assert-CapsulenvWeaselInstalledForSeed
    $source = [string]$installation.UserDataDir
    [void](Test-CapsulenvWeaselTreeSafeToCopy -Path $source)

    $seedRoot = Get-CapsulenvWeaselSeedRoot
    if (Test-CapsulenvWeaselPathsOverlap -First $source -Second $seedRoot) {
        throw 'Weasel user data directory must not overlap tool-data\weasel; live host state and portable seed must remain distinct.'
    }
    $seedParent = Split-Path -Parent $seedRoot
    [void](New-Item -ItemType Directory -Path $seedParent -Force)
    if ((Test-Path -LiteralPath $seedRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $seedRoot -Force).Count -gt 0 -and -not $Force) {
        throw "Portable Weasel seed already contains data: $seedRoot. Pass --force to replace it."
    }

    $staging = Join-Path $seedParent ('.weasel-seed-{0}' -f [Guid]::NewGuid().ToString('N'))
    $rollback = Join-Path $seedParent ('.weasel-seed-rollback-{0}' -f [Guid]::NewGuid().ToString('N'))
    $wasRunning = Test-CapsulenvWeaselServerRunning
    $stopped = $false
    try {
        if ($wasRunning) {
            Stop-CapsulenvWeaselServer -Installation $installation
            $stopped = $true
        }
        $dataRoot = Join-Path $staging 'user-data'
        Copy-CapsulenvWeaselTree -Source $source -Destination $dataRoot
        [ordered]@{
            SchemaVersion = 1
            CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
            WeaselVersion = [string]$installation.Version
            SourceUserDataDir = $source
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $staging 'seed.json') -Encoding UTF8

        $hadExisting = Test-Path -LiteralPath $seedRoot
        if ($hadExisting) {
            Move-Item -LiteralPath $seedRoot -Destination $rollback
        }
        try {
            Move-Item -LiteralPath $staging -Destination $seedRoot
        } catch {
            if ($hadExisting -and (Test-Path -LiteralPath $rollback) -and -not (Test-Path -LiteralPath $seedRoot)) {
                Move-Item -LiteralPath $rollback -Destination $seedRoot
            }
            throw
        }
        if (Test-Path -LiteralPath $rollback) {
            Remove-Item -LiteralPath $rollback -Recurse -Force
        }
    } finally {
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($wasRunning -and $stopped -and -not (Test-CapsulenvWeaselServerRunning)) {
            Start-CapsulenvWeaselServer -Installation $installation
        }
    }

    return [pscustomobject]@{
        Action = 'Backup'
        Destination = $seedRoot
        UserDataDir = $source
        WeaselVersion = [string]$installation.Version
    }
}

function Save-CapsulenvWeaselHostRollback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$UserDataDir,
        [Parameter(Mandatory = $true)]$Installation
    )

    $backupParent = Join-Path (Join-Path (Get-CapsulenvUserIntegrationStateRoot) 'weasel') 'restore-backups'
    $backupRoot = Join-Path $backupParent ('{0}-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [Guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $backupRoot -Force)
    $existed = Test-Path -LiteralPath $UserDataDir -PathType Container
    if ($existed) {
        Copy-CapsulenvWeaselTree -Source $UserDataDir -Destination (Join-Path $backupRoot 'user-data')
    }
    [ordered]@{
        SchemaVersion = 1
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        UserDataDir = $UserDataDir
        UserDataExisted = [bool]$existed
        WeaselVersion = [string]$Installation.Version
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backupRoot 'host-state.json') -Encoding UTF8
    return $backupRoot
}

function Restore-CapsulenvWeaselSeed {
    [CmdletBinding()]
    param()

    $installation = Assert-CapsulenvWeaselInstalledForSeed
    $seedRoot = Get-CapsulenvWeaselSeedRoot
    $seedData = Join-Path $seedRoot 'user-data'
    $seedMetadata = Join-Path $seedRoot 'seed.json'
    if (-not (Test-Path -LiteralPath $seedData -PathType Container) -or -not (Test-Path -LiteralPath $seedMetadata -PathType Leaf)) {
        throw "No complete portable Weasel seed exists: $seedRoot"
    }
    try {
        $metadata = Get-Content -LiteralPath $seedMetadata -Raw | ConvertFrom-Json
        if ([int]$metadata.SchemaVersion -ne 1) {
            throw "Unsupported Weasel seed schema: $($metadata.SchemaVersion)"
        }
    } catch {
        throw "Portable Weasel seed metadata is invalid: $($_.Exception.Message)"
    }
    [void](Test-CapsulenvWeaselTreeSafeToCopy -Path $seedData)

    $target = [System.IO.Path]::GetFullPath([string]$installation.UserDataDir)
    if (Test-CapsulenvWeaselPathsOverlap -First $target -Second $seedRoot) {
        throw 'Weasel user data directory must not overlap tool-data\weasel; restore requires distinct host and portable trees.'
    }
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        throw "Weasel user data path is occupied by a file: $target"
    }
    if (Test-Path -LiteralPath $target -PathType Container) {
        [void](Test-CapsulenvWeaselTreeSafeToCopy -Path $target)
    }
    $targetParent = Split-Path -Parent $target
    [void](New-Item -ItemType Directory -Path $targetParent -Force)
    $staging = Join-Path $targetParent ('.capsulenv-weasel-restore-{0}' -f [Guid]::NewGuid().ToString('N'))
    $oldTarget = Join-Path $targetParent ('.capsulenv-weasel-old-{0}' -f [Guid]::NewGuid().ToString('N'))
    Copy-CapsulenvWeaselTree -Source $seedData -Destination $staging

    $wasRunning = Test-CapsulenvWeaselServerRunning
    $stopped = $false
    $hostBackup = $null
    $movedOld = $false
    $installedNew = $false
    try {
        if ($wasRunning) {
            Stop-CapsulenvWeaselServer -Installation $installation
            $stopped = $true
        }

        $hostBackup = Save-CapsulenvWeaselHostRollback -UserDataDir $target -Installation $installation
        if (Test-Path -LiteralPath $target -PathType Container) {
            Move-Item -LiteralPath $target -Destination $oldTarget
            $movedOld = $true
        }
        Move-Item -LiteralPath $staging -Destination $target
        $installedNew = $true

        try {
            Invoke-CapsulenvWeaselDeploy -Installation $installation
        } catch {
            if ($installedNew -and (Test-Path -LiteralPath $target)) {
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
            }
            if ($movedOld -and (Test-Path -LiteralPath $oldTarget) -and -not (Test-Path -LiteralPath $target)) {
                Move-Item -LiteralPath $oldTarget -Destination $target
                $movedOld = $false
            }
            throw
        }

        if ($movedOld -and (Test-Path -LiteralPath $oldTarget)) {
            Remove-Item -LiteralPath $oldTarget -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $oldTarget)) {
                $movedOld = $false
            }
        }
    } finally {
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($movedOld -and (Test-Path -LiteralPath $oldTarget) -and -not (Test-Path -LiteralPath $target)) {
            Move-Item -LiteralPath $oldTarget -Destination $target -ErrorAction SilentlyContinue
        }
        if ($wasRunning -and $stopped -and -not (Test-CapsulenvWeaselServerRunning)) {
            Start-CapsulenvWeaselServer -Installation $installation
        }
    }

    return [pscustomobject]@{
        Action = 'Restore'
        Source = $seedRoot
        UserDataDir = $target
        HostRollback = $hostBackup
        WeaselVersion = [string]$installation.Version
    }
}

##MOD_EXEC## Export-ModuleMember -Function Save-CapsulenvWeaselSeed, Restore-CapsulenvWeaselSeed, Get-CapsulenvWeaselInstallation
