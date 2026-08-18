[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Destination,
    [switch]$Force,
    [switch]$IncludeDevelopmentFiles
)

$sourceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$controlBootstrap = Join-Path $sourceRoot 'module-runtime\Initialize-CapsulenvControlHost.ps1'
if (-not (Test-Path -LiteralPath $controlBootstrap -PathType Leaf)) {
    $controlBootstrap = Join-Path $sourceRoot 'modules\Capsulenv\runtime\Initialize-CapsulenvControlHost.ps1'
}
if (-not (Test-Path -LiteralPath $controlBootstrap -PathType Leaf)) {
    throw "Capsulenv control-host bootstrap is missing: $controlBootstrap"
}
. $controlBootstrap

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
        [int]$runtimeSourceMetadata.SchemaVersion -notin @(2, 3) -or
        $null -eq $runtimeSourceMetadata.ManagedFiles -or
        ([int]$runtimeSourceMetadata.SchemaVersion -ge 3 -and $null -eq $runtimeSourceMetadata.PSObject.Properties['InstallFiles'])
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
    ($null -eq $existingMarker.SchemaVersion -or [int]$existingMarker.SchemaVersion -notin @(1, 2, 3))
) {
    throw "Unsupported capsulenv install marker schema: $($existingMarker.SchemaVersion)"
}
if ($hasContents -and $null -eq $existingMarker -and -not $Force) {
    throw "Destination is not empty and was not installed by capsulenv: $destinationRoot. Pass -Force to adopt it without deleting unrelated data."
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
        $installFileProperty = $runtimeSourceMetadata.PSObject.Properties['InstallFiles']
        $installFiles = if ($null -ne $installFileProperty) {
            @($installFileProperty.Value)
        } else {
            @($runtimeSourceMetadata.ManagedFiles)
        }
        $newManagedFiles = @(
            $installFiles | ForEach-Object { [string]$_ } | Sort-Object -Unique
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
            $build.InstallFiles | ForEach-Object { [string]$_ } | Sort-Object -Unique
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

    $installMetadata = [ordered]@{
        SchemaVersion = 3
        Version = [string]$build.Version
        InstalledAtUtc = [DateTime]::UtcNow.ToString('o')
        SourceCommit = $build.SourceCommit
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

$action = if ($installResult.UpdatedExistingInstallation) { 'updated' } else { 'installed' }
Write-Host ("capsulenv {0} to {1}" -f $action, $installResult.Destination)
Write-Host ('Next: "{0}"' -f $installResult.Launcher)
$installResult
