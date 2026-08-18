[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CapsulenvArguments = @()
)

. ([System.IO.Path]::Combine($PSScriptRoot, 'Initialize-CapsulenvControlHost.ps1'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$env:CAPSULENV_ROOT = $root

$prebuiltModule = Join-Path (Join-Path (Join-Path $root 'modules') 'Capsulenv') 'Capsulenv.psd1'
$mergeScript = Join-Path $root 'Merge-ModuleScripts.ps1'
$sourcePath = Join-Path $root 'src'
$sourceManifest = Join-Path $root 'Capsulenv.psd1'
$canCompileModule = (
    (Test-Path -LiteralPath $mergeScript -PathType Leaf) -and
    (Test-Path -LiteralPath $sourcePath -PathType Container) -and
    (Test-Path -LiteralPath $sourceManifest -PathType Leaf)
)
$forceRebuild = $env:CAPSULENV_FORCE_REBUILD -eq '1'

if ($canCompileModule) {
    # A source checkout is authoritative over any generated/prebuilt module that
    # may have been left behind by an earlier build. Merge on entry so source
    # changes can never silently execute through a stale modules/Capsulenv copy.
    $build = & $mergeScript `
        -ModuleName Capsulenv `
        -SourcePath $sourcePath `
        -ManifestPath $sourceManifest `
        -OutputRoot (Join-Path $root '.build') `
        -Clean
    $modulePath = $build.ModulePath
} elseif (Test-Path -LiteralPath $prebuiltModule -PathType Leaf) {
    # Minimal deployed runtimes intentionally do not ship src/ or the merger.
    # CAPSULENV_FORCE_REBUILD must therefore never make an otherwise valid
    # portable runtime unbootable; updating its merged module requires a newer
    # prebuilt runtime bundle through install.cmd.
    if ($forceRebuild) {
        Write-Warning 'CAPSULENV_FORCE_REBUILD was ignored because this is a deployed prebuilt runtime. Update Capsulenv from a newer runtime bundle to replace modules\Capsulenv.'
    }

    $runtimeMetadataPath = Join-Path $root '.capsulenv-runtime.json'
    if (Test-Path -LiteralPath $runtimeMetadataPath -PathType Leaf) {
        $runtimeMetadata = Get-Content -LiteralPath $runtimeMetadataPath -Raw | ConvertFrom-Json
        $moduleMetadata = Import-PowerShellDataFile -Path $prebuiltModule
        if (
            $null -ne $runtimeMetadata.Version -and
            $null -ne $moduleMetadata.ModuleVersion -and
            -not [System.StringComparer]::OrdinalIgnoreCase.Equals(
                [string]$runtimeMetadata.Version,
                [string]$moduleMetadata.ModuleVersion
            )
        ) {
            throw "Capsulenv runtime metadata version $($runtimeMetadata.Version) does not match prebuilt module version $($moduleMetadata.ModuleVersion). Reinstall/update this capsule from one complete runtime bundle."
        }
    }
    $modulePath = $prebuiltModule
} else {
    throw "Capsulenv has neither a buildable source tree nor a prebuilt module: $prebuiltModule"
}

Import-Module $modulePath -Force -DisableNameChecking
Invoke-Capsulenv @CapsulenvArguments
