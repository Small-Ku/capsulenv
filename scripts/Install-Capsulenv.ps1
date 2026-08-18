[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Destination,
    [switch]$Force,
    [switch]$IncludeDevelopmentFiles,
    [ValidateSet('ShellOnly', 'User')]
    [string]$Mode,
    [switch]$SkipScoopBootstrap
)

. ([System.IO.Path]::Combine($PSScriptRoot, 'Initialize-CapsulenvControlHost.ps1'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-CapsulenvManagedInstallPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Invalid managed install path: $RelativePath"
    }
    $normalizedRelative = $RelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    if ($normalizedRelative -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Managed install path cannot traverse parents: $RelativePath"
    }
    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]'\/')
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $rootPath $normalizedRelative))
    $prefix = $rootPath + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Managed install path escaped the destination: $RelativePath"
    }
    return $candidate
}

function Copy-CapsulenvInstallFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $parent = Split-Path -Parent $Destination
    [void](New-Item -ItemType Directory -Path $parent -Force)
    $temporary = Join-Path $parent ('.capsulenv-new-{0}' -f [Guid]::NewGuid().ToString('N'))
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary -Force
        if (Test-Path -LiteralPath $Destination -PathType Container) {
            throw "A directory blocks a managed runtime file: $Destination"
        }
        if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            try {
                [System.IO.File]::Replace($temporary, $Destination, $null, $true)
            } catch {
                Remove-Item -LiteralPath $Destination -Force
                Move-Item -LiteralPath $temporary -Destination $Destination
            }
        } else {
            Move-Item -LiteralPath $temporary -Destination $Destination
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

$sourceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$destinationRoot = [System.IO.Path]::GetFullPath($Destination)
$sourceComparison = $sourceRoot.TrimEnd([char[]]'\/')
$destinationComparison = $destinationRoot.TrimEnd([char[]]'\/')
if ([System.StringComparer]::OrdinalIgnoreCase.Equals($sourceComparison, $destinationComparison)) {
    throw 'Install destination must not be the source repository root.'
}
$destinationPrefix = $destinationComparison + [System.IO.Path]::DirectorySeparatorChar
if ($sourceComparison.StartsWith($destinationPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Install destination must not be an ancestor of the source repository.'
}
$sourcePrefix = $sourceComparison + [System.IO.Path]::DirectorySeparatorChar
if ($destinationComparison.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Install destination must not be inside the source repository/runtime bundle. Use a separate destination directory.'
}

$runtimeSourceMetadata = $null
$runtimeSourceMetadataPath = Join-Path $sourceRoot '.capsulenv-runtime.json'
if (Test-Path -LiteralPath $runtimeSourceMetadataPath -PathType Leaf) {
    $runtimeSourceMetadata = Get-Content -LiteralPath $runtimeSourceMetadataPath -Raw | ConvertFrom-Json
    if (
        $null -eq $runtimeSourceMetadata.SchemaVersion -or
        [int]$runtimeSourceMetadata.SchemaVersion -ne 2 -or
        $null -eq $runtimeSourceMetadata.ManagedFiles
    ) {
        throw 'This prebuilt capsulenv runtime does not contain an installable runtime manifest. Rebuild it with the current Build-Capsulenv.ps1.'
    }
    if ($IncludeDevelopmentFiles -and -not [bool]$runtimeSourceMetadata.DevelopmentFilesIncluded) {
        throw '-IncludeDevelopmentFiles cannot add source/tests that are not present in this prebuilt runtime bundle.'
    }
}

$markerPath = Join-Path $destinationRoot '.capsulenv-install.json'
$destinationExists = Test-Path -LiteralPath $destinationRoot -PathType Container
$hasContents = $destinationExists -and $null -ne (Get-ChildItem -LiteralPath $destinationRoot -Force | Select-Object -First 1)
$existingMarker = $null
if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
    $existingMarker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
}
if (
    $null -ne $existingMarker -and
    ($null -eq $existingMarker.SchemaVersion -or [int]$existingMarker.SchemaVersion -notin @(1, 2))
) {
    throw "Unsupported capsulenv install marker schema: $($existingMarker.SchemaVersion)"
}
if ($hasContents -and $null -eq $existingMarker -and -not $Force) {
    throw "Destination is not empty and was not installed by capsulenv: $destinationRoot. Pass -Force to adopt it without deleting unrelated data."
}

# Integration mode is host/user ownership, not a capsule-global property. The
# authoritative current mode is resolved by the installed module after runtime
# files are in place. Install metadata only records the last requested mode.
$currentMode = 'ShellOnly'
$effectiveMode = if ($PSBoundParameters.ContainsKey('Mode')) { [string]$Mode } else { $null }
$markerMode = if ($null -ne $existingMarker -and [string]$existingMarker.InstallMode -in @('ShellOnly', 'User')) {
    [string]$existingMarker.InstallMode
} else {
    'ShellOnly'
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("capsulenv-install-{0}" -f [Guid]::NewGuid().ToString('N'))
$buildRoot = Join-Path $temporaryRoot 'runtime'
$rollbackRoot = Join-Path $temporaryRoot 'rollback'
$rollbackRecords = New-Object System.Collections.Generic.List[object]
$mutationStarted = $false
$installResult = $null
try {
    [void](New-Item -ItemType Directory -Path $temporaryRoot -Force)
    [void](New-Item -ItemType Directory -Path $rollbackRoot -Force)
    if ($null -ne $runtimeSourceMetadata) {
        $buildRoot = $sourceRoot
        $build = [pscustomobject]@{
            OutputPath = $sourceRoot
            Version = [string]$runtimeSourceMetadata.Version
            SourceCommit = $runtimeSourceMetadata.SourceCommit
        }
        $newManagedFiles = @(
            $runtimeSourceMetadata.ManagedFiles | ForEach-Object { [string]$_ } | Sort-Object -Unique
        )
        foreach ($relative in $newManagedFiles) {
            $sourcePath = Resolve-CapsulenvManagedInstallPath -Root $buildRoot -RelativePath $relative
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                throw "Prebuilt runtime managed file is missing: $relative"
            }
        }
    } else {
        $build = & (Join-Path $PSScriptRoot 'Build-Capsulenv.ps1') `
            -OutputPath $buildRoot `
            -IncludeDevelopmentFiles:$IncludeDevelopmentFiles
        $newManagedFiles = @(
            $build.ManagedFiles | ForEach-Object { [string]$_ } | Sort-Object -Unique
        )
    }
    $oldManagedFiles = if ($null -ne $existingMarker -and $null -ne $existingMarker.ManagedFiles) {
        @($existingMarker.ManagedFiles | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    } else {
        @()
    }
    $allManagedFiles = @($oldManagedFiles + $newManagedFiles | Sort-Object -Unique)

    [void](New-Item -ItemType Directory -Path $destinationRoot -Force)
    foreach ($relative in $allManagedFiles) {
        $destinationPath = Resolve-CapsulenvManagedInstallPath -Root $destinationRoot -RelativePath $relative
        if (Test-Path -LiteralPath $destinationPath -PathType Container) {
            throw "A directory blocks a managed runtime file: $destinationPath"
        }
        $backupPath = Resolve-CapsulenvManagedInstallPath -Root $rollbackRoot -RelativePath $relative
        $existed = Test-Path -LiteralPath $destinationPath -PathType Leaf
        if ($existed) {
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force)
            Copy-Item -LiteralPath $destinationPath -Destination $backupPath -Force
        }
        $rollbackRecords.Add([pscustomobject]@{
            Path = $destinationPath
            Existed = $existed
            BackupPath = $backupPath
        })
    }

    $markerBackupPath = Join-Path $rollbackRoot '.capsulenv-install.json'
    $markerExisted = Test-Path -LiteralPath $markerPath -PathType Leaf
    if ($markerExisted) {
        Copy-Item -LiteralPath $markerPath -Destination $markerBackupPath -Force
    }
    $rollbackRecords.Add([pscustomobject]@{
        Path = $markerPath
        Existed = $markerExisted
        BackupPath = $markerBackupPath
    })

    $mutationStarted = $true
    foreach ($relative in $oldManagedFiles) {
        if ($relative -notin $newManagedFiles) {
            $oldPath = Resolve-CapsulenvManagedInstallPath -Root $destinationRoot -RelativePath $relative
            if (Test-Path -LiteralPath $oldPath -PathType Leaf) {
                Remove-Item -LiteralPath $oldPath -Force
            }
        }
    }

    foreach ($relative in $newManagedFiles) {
        $source = Resolve-CapsulenvManagedInstallPath -Root $buildRoot -RelativePath $relative
        $destinationPath = Resolve-CapsulenvManagedInstallPath -Root $destinationRoot -RelativePath $relative
        Copy-CapsulenvInstallFile -Source $source -Destination $destinationPath
    }

    foreach ($mutableDirectory in @(
        'scoop',
        'scoop-global',
        'cache',
        'tool-data',
        'project-cache',
        'workspace',
        'PowerShell/Modules',
        '.capsulenv',
        'bin'
    )) {
        [void](New-Item -ItemType Directory -Path (Join-Path $destinationRoot $mutableDirectory) -Force)
    }

    $installMetadata = [ordered]@{
        SchemaVersion = 2
        Version = [string]$build.Version
        InstalledAtUtc = [DateTime]::UtcNow.ToString('o')
        SourceCommit = $build.SourceCommit
        InstallMode = $markerMode
        ManagedFiles = $newManagedFiles
    }
    $temporaryMarker = Join-Path $destinationRoot ('.capsulenv-install-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        $installMetadata | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporaryMarker -Encoding UTF8
        Copy-CapsulenvInstallFile -Source $temporaryMarker -Destination $markerPath
    } finally {
        if (Test-Path -LiteralPath $temporaryMarker) {
            Remove-Item -LiteralPath $temporaryMarker -Force -ErrorAction SilentlyContinue
        }
    }

    $installResult = [pscustomobject]@{
        Destination = $destinationRoot
        Version = [string]$build.Version
        Launcher = Join-Path $destinationRoot 'capsulenv.cmd'
        UpdatedExistingInstallation = $null -ne $existingMarker
        DevelopmentFilesIncluded = [bool]$IncludeDevelopmentFiles
        InstallMode = $effectiveMode
        ScoopBootstrapSkipped = [bool]$SkipScoopBootstrap
    }
} catch {
    $installError = $_
    if ($mutationStarted) {
        $rollbackErrors = New-Object System.Collections.Generic.List[string]
        for ($recordIndex = $rollbackRecords.Count - 1; $recordIndex -ge 0; $recordIndex--) {
            $record = $rollbackRecords[$recordIndex]
            try {
                if ($record.Existed) {
                    Copy-CapsulenvInstallFile -Source $record.BackupPath -Destination $record.Path
                } elseif (Test-Path -LiteralPath $record.Path -PathType Leaf) {
                    Remove-Item -LiteralPath $record.Path -Force
                }
            } catch {
                $rollbackErrors.Add("$($record.Path): $($_.Exception.Message)")
            }
        }
        if ($rollbackErrors.Count -gt 0) {
            throw "capsulenv installation failed: $($installError.Exception.Message)`nRollback also failed:`n$($rollbackErrors -join [Environment]::NewLine)"
        }
    }
    throw $installError
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

$previousProcessEnvironment = @{}
foreach ($entry in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) {
    $previousProcessEnvironment[[string]$entry.Key] = [string]$entry.Value
}
$previousCapsulenvModules = @(Get-Module Capsulenv)
$installedModule = Join-Path (Join-Path (Join-Path $destinationRoot 'modules') 'Capsulenv') 'Capsulenv.psd1'
try {
    $env:CAPSULENV_ROOT = $destinationRoot
    Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    Import-Module $installedModule -Force -DisableNameChecking

    $bootstrapOnThisHost = (-not $SkipScoopBootstrap) -and ($env:OS -eq 'Windows_NT' -or $PSVersionTable.PSVersion.Major -le 5)
    if ($bootstrapOnThisHost) {
        [void](Set-CapsulenvSessionEnvironment)
        [void](Initialize-CapsulenvScoopBootstrap)
    } else {
        [void](Ensure-CapsulenvScoopPortableConfig)
    }

    $currentMode = Get-CapsulenvInstallMode
    if (-not $PSBoundParameters.ContainsKey('Mode')) {
        $effectiveMode = $currentMode
    }

    if ($effectiveMode -eq 'User') {
        Install-CapsulenvUserEnvironment -Force:($currentMode -eq 'User')
    } elseif ($currentMode -eq 'User') {
        Restore-CapsulenvUserEnvironment
    } else {
        Set-CapsulenvInstallMode -Mode ShellOnly
    }
    $installResult.InstallMode = $effectiveMode

    # Commit the requested ownership mode to install metadata only after the
    # mode transition itself succeeded. If restore-user/install-user fails,
    # the marker therefore continues to describe the still-effective mode.
    $committedMarker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    $committedMarker.InstallMode = $effectiveMode
    $temporaryModeMarker = Join-Path $destinationRoot ('.capsulenv-mode-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        $committedMarker | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporaryModeMarker -Encoding UTF8
        Copy-CapsulenvInstallFile -Source $temporaryModeMarker -Destination $markerPath
    } finally {
        if (Test-Path -LiteralPath $temporaryModeMarker -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryModeMarker -Force -ErrorAction SilentlyContinue
        }
    }
} finally {
    Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    foreach ($previousModule in $previousCapsulenvModules) {
        if (
            -not [string]::IsNullOrWhiteSpace([string]$previousModule.Path) -and
            (Test-Path -LiteralPath $previousModule.Path -PathType Leaf)
        ) {
            Import-Module $previousModule.Path -Force -DisableNameChecking
        }
    }
    $currentProcessEnvironment = [Environment]::GetEnvironmentVariables('Process')
    foreach ($name in @($currentProcessEnvironment.Keys)) {
        if (-not $previousProcessEnvironment.ContainsKey([string]$name)) {
            [Environment]::SetEnvironmentVariable([string]$name, $null, 'Process')
        }
    }
    foreach ($name in $previousProcessEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable([string]$name, [string]$previousProcessEnvironment[$name], 'Process')
    }
}

$action = if ($installResult.UpdatedExistingInstallation) { 'updated' } else { 'installed' }
Write-Host ("capsulenv {0} to {1}" -f $action, $installResult.Destination)
Write-Host ('Next: "{0}"' -f $installResult.Launcher)
$installResult
