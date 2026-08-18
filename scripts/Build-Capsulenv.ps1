[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$OutputPath = (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'dist') 'capsulenv'),
    [switch]$IncludeDevelopmentFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$outputRoot = [System.IO.Path]::GetFullPath($OutputPath)
$sourceComparison = $sourceRoot.TrimEnd([char[]]'\/')
$outputComparison = $outputRoot.TrimEnd([char[]]'\/')
if ([System.StringComparer]::OrdinalIgnoreCase.Equals($sourceComparison, $outputComparison)) {
    throw 'Build output must not be the source repository root.'
}
$outputPrefix = $outputComparison + [System.IO.Path]::DirectorySeparatorChar
if ($sourceComparison.StartsWith($outputPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Build output must not be an ancestor of the source repository.'
}

$sourcePrefix = $sourceComparison + [System.IO.Path]::DirectorySeparatorChar
if ($outputComparison.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    $distributionRoot = [System.IO.Path]::GetFullPath((Join-Path $sourceRoot 'dist')).TrimEnd([char[]]'\/')
    $distributionPrefix = $distributionRoot + [System.IO.Path]::DirectorySeparatorChar
    if (
        -not [System.StringComparer]::OrdinalIgnoreCase.Equals($outputComparison, $distributionRoot) -and
        -not $outputComparison.StartsWith($distributionPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        throw 'Source-local build output must remain under the dist directory.'
    }
}

if (Test-Path -LiteralPath $outputRoot) {
    $existingOutput = Get-Item -LiteralPath $outputRoot -Force
    if (($existingOutput.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Build output must not be a junction or symbolic link: $outputRoot"
    }
    Remove-Item -LiteralPath $outputRoot -Recurse -Force
}
[void](New-Item -ItemType Directory -Path $outputRoot -Force)

$temporaryBuild = Join-Path ([System.IO.Path]::GetTempPath()) ("capsulenv-module-{0}" -f [Guid]::NewGuid().ToString('N'))
try {
    $build = & (Join-Path $sourceRoot 'Merge-ModuleScripts.ps1') `
        -ModuleName Capsulenv `
        -SourcePath (Join-Path $sourceRoot 'src') `
        -ManifestPath (Join-Path $sourceRoot 'Capsulenv.psd1') `
        -OutputRoot $temporaryBuild `
        -Clean

    $files = @(
        @{ Source = 'capsulenv.cmd'; Destination = 'capsulenv.cmd' }
        @{ Source = 'install.cmd'; Destination = 'install.cmd' }
        @{ Source = 'README.md'; Destination = 'README.md' }
        @{ Source = 'scripts/Install-Capsulenv.ps1'; Destination = 'scripts/Install-Capsulenv.ps1' }
        @{ Source = 'scripts/Initialize-CapsulenvControlHost.ps1'; Destination = 'scripts/Initialize-CapsulenvControlHost.ps1' }
        @{ Source = 'bin/firefox-capsulenv.cmd'; Destination = 'bin/firefox-capsulenv.cmd' }
        @{ Source = 'bin/zen-capsulenv.cmd'; Destination = 'bin/zen-capsulenv.cmd' }
        @{ Source = 'bin/librewolf-capsulenv.cmd'; Destination = 'bin/librewolf-capsulenv.cmd' }
        @{ Source = 'config/capsulenv.psd1'; Destination = 'config/capsulenv.psd1' }
        @{ Source = 'config/capsulenv.local.psd1.example'; Destination = 'config/capsulenv.local.psd1.example' }
        @{ Source = 'scripts/Invoke-Capsulenv.ps1'; Destination = 'scripts/Invoke-Capsulenv.ps1' }
        @{ Source = 'scripts/scoop-capsulenv-replay.ps1'; Destination = 'scripts/scoop-capsulenv-replay.ps1' }
        @{ Source = 'scripts/scoop-capsulenv-portable-reset.ps1'; Destination = 'scripts/scoop-capsulenv-portable-reset.ps1' }
        @{ Source = 'scripts/scoop-capsulenv-user-reset.ps1'; Destination = 'scripts/scoop-capsulenv-user-reset.ps1' }
        @{ Source = 'scripts/scoop-capsulenv-process-guard.ps1'; Destination = 'scripts/scoop-capsulenv-process-guard.ps1' }
        @{ Source = 'scripts/scoop-capsulenv-gateway.ps1'; Destination = 'scripts/scoop-capsulenv-gateway.ps1' }
        @{ Source = 'scripts/scoop-capsulenv-shellonly-policy.ps1'; Destination = 'scripts/scoop-capsulenv-shellonly-policy.ps1' }
        @{ Source = 'docs/ARCHITECTURE.md'; Destination = 'docs/ARCHITECTURE.md' }
        @{ Source = 'docs/DEVELOPMENT.md'; Destination = 'docs/DEVELOPMENT.md' }
        @{ Source = 'docs/DEPLOYMENT.md'; Destination = 'docs/DEPLOYMENT.md' }
        @{ Source = 'docs/MIGRATION.md'; Destination = 'docs/MIGRATION.md' }
        @{ Source = 'docs/TOOLS.md'; Destination = 'docs/TOOLS.md' }
    )
    foreach ($entry in $files) {
        $source = Join-Path $sourceRoot $entry.Source
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Runtime source file is missing: $source"
        }
        $destination = Join-Path $outputRoot $entry.Destination
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force)
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }

    $moduleDestination = Join-Path (Join-Path $outputRoot 'modules') 'Capsulenv'
    [void](New-Item -ItemType Directory -Path $moduleDestination -Force)
    Get-ChildItem -LiteralPath (Split-Path -Parent $build.ModulePath) -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $moduleDestination -Recurse -Force
    }

    if ($IncludeDevelopmentFiles) {
        foreach ($directoryName in @('src', 'tests')) {
            Copy-Item -LiteralPath (Join-Path $sourceRoot $directoryName) -Destination (Join-Path $outputRoot $directoryName) -Recurse -Force
        }
        foreach ($fileName in @(
            'AGENTS.md',
            'Capsulenv.psd1',
            'Merge-ModuleScripts.ps1',
            'PSScriptAnalyzerSettings.psd1',
            'scripts/Analyze-Capsulenv.ps1',
            'scripts/Build-Capsulenv.ps1',
            'scripts/Test-Capsulenv.ps1'
        )) {
            $source = Join-Path $sourceRoot $fileName
            if (Test-Path -LiteralPath $source -PathType Leaf) {
                $destination = Join-Path $outputRoot $fileName
                [void](New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force)
                Copy-Item -LiteralPath $source -Destination $destination -Force
            }
        }
    }

    $commit = $null
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $git) {
        $git = Get-Command git -ErrorAction SilentlyContinue
    }
    if ($git) {
        $gitOutput = New-Object System.Collections.Generic.List[string]
        Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        & $git.Source -C $sourceRoot rev-parse HEAD 2>$null | ForEach-Object {
            $gitOutput.Add([string]$_)
        }
        $gitSucceeded = $?
        $gitExitVariable = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
        $gitExitCode = if ($null -eq $gitExitVariable) { 0 } else { [int]$gitExitVariable.Value }
        $commit = $gitOutput | Select-Object -First 1
        if (-not $gitSucceeded -or $gitExitCode -ne 0) {
            $commit = $null
        }
    }

    $managedFiles = @(
        Get-ChildItem -LiteralPath $outputRoot -File -Recurse -Force | ForEach-Object {
            $_.FullName.Substring($outputRoot.TrimEnd([char[]]'\/').Length).TrimStart([char[]]'\/').Replace('\', '/')
        } | Sort-Object -Unique
    )
    $managedFiles = @($managedFiles + '.capsulenv-runtime.json' | Sort-Object -Unique)

    $metadata = [ordered]@{
        SchemaVersion = 2
        Version = [string]$build.ModuleVersion
        SourceCommit = $commit
        BuiltAtUtc = [DateTime]::UtcNow.ToString('o')
        DevelopmentFilesIncluded = [bool]$IncludeDevelopmentFiles
        ManagedFiles = $managedFiles
    }
    $metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $outputRoot '.capsulenv-runtime.json') -Encoding UTF8

    [pscustomobject]@{
        OutputPath = $outputRoot
        Version = [string]$build.ModuleVersion
        ModulePath = Join-Path $moduleDestination 'Capsulenv.psd1'
        SourceCommit = $commit
        ManagedFiles = $managedFiles
    }
} finally {
    if (Test-Path -LiteralPath $temporaryBuild) {
        Remove-Item -LiteralPath $temporaryBuild -Recurse -Force
    }
}
