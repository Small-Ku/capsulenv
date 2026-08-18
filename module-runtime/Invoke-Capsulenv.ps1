[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CapsulenvArguments = @()
)

. ([System.IO.Path]::Combine($PSScriptRoot, 'Initialize-CapsulenvControlHost.ps1'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $null
$runtimeLeaf = Split-Path -Leaf $PSScriptRoot
if ([System.StringComparer]::OrdinalIgnoreCase.Equals($runtimeLeaf, 'module-runtime')) {
    $root = Split-Path -Parent $PSScriptRoot
} elseif ([System.StringComparer]::OrdinalIgnoreCase.Equals($runtimeLeaf, 'runtime')) {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    $modulesRoot = Split-Path -Parent $moduleRoot
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals((Split-Path -Leaf $modulesRoot), 'modules')) {
        $root = Split-Path -Parent $modulesRoot
    }
}
if ([string]::IsNullOrWhiteSpace($root)) {
    $root = $env:CAPSULENV_ROOT
}
if ([string]::IsNullOrWhiteSpace($root)) {
    throw 'Capsulenv runtime entrypoint could not resolve the capsule root.'
}
$root = [System.IO.Path]::GetFullPath($root)
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
    # A deployed capsule owns one self-contained module package. Runtime entry
    # points and helper resources live beside its manifest, so relocation does
    # not depend on release-bundle metadata or repository build scripts.
    if ($forceRebuild) {
        Write-Warning 'CAPSULENV_FORCE_REBUILD was ignored because this is a deployed module runtime. Update Capsulenv from a development checkout or newer release bundle to replace modules\Capsulenv.'
    }
    $modulePath = $prebuiltModule
} else {
    throw "Capsulenv has neither a buildable source tree nor a prebuilt module: $prebuiltModule"
}

Import-Module $modulePath -Force -DisableNameChecking
Invoke-Capsulenv @CapsulenvArguments
