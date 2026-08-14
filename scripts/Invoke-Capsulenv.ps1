[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CapsulenvArguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$env:CAPSULENV_ROOT = $root

$prebuiltModule = Join-Path (Join-Path (Join-Path $root 'modules') 'Capsulenv') 'Capsulenv.psd1'
$forceRebuild = $env:CAPSULENV_FORCE_REBUILD -eq '1'
if ((Test-Path -LiteralPath $prebuiltModule -PathType Leaf) -and -not $forceRebuild) {
    $modulePath = $prebuiltModule
} else {
    $mergeScript = Join-Path $root 'Merge-ModuleScripts.ps1'
    if (-not (Test-Path -LiteralPath $mergeScript -PathType Leaf)) {
        throw "The prebuilt module is missing and this installation has no module compiler: $prebuiltModule"
    }
    $build = & $mergeScript `
        -ModuleName Capsulenv `
        -SourcePath (Join-Path $root 'src') `
        -ManifestPath (Join-Path $root 'Capsulenv.psd1') `
        -OutputRoot (Join-Path $root '.build')
    $modulePath = $build.ModulePath
}

Import-Module $modulePath -Force -DisableNameChecking
Invoke-Capsulenv @CapsulenvArguments
