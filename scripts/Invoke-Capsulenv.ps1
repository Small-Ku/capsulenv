[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CapsulenvArguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$env:CAPSULENV_ROOT = $root

$build = & (Join-Path $root 'Merge-ModuleScripts.ps1') `
    -ModuleName Capsulenv `
    -SourcePath (Join-Path $root 'src') `
    -ManifestPath (Join-Path $root 'Capsulenv.psd1') `
    -OutputRoot (Join-Path $root '.build')

Import-Module $build.ModulePath -Force
Invoke-Capsulenv @CapsulenvArguments
