Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CapsulenvTestModuleBuild {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)

    $sharedModulePath = [string]$env:CAPSULENV_TEST_PREBUILT_MODULE_PATH
    if (-not [string]::IsNullOrWhiteSpace($sharedModulePath)) {
        $sharedModulePath = [System.IO.Path]::GetFullPath($sharedModulePath)
        if (-not (Test-Path -LiteralPath $sharedModulePath -PathType Leaf)) {
            throw "CAPSULENV_TEST_PREBUILT_MODULE_PATH does not identify a prebuilt module: $sharedModulePath"
        }
        return [pscustomobject][ordered]@{
            ModulePath = $sharedModulePath
            Shared = $true
        }
    }

    return & (Join-Path ([System.IO.Path]::GetFullPath($Root)) 'Merge-ModuleScripts.ps1') -Clean
}
