[CmdletBinding()]
param(
    [switch]$RequireWindowsPowerShell51
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($RequireWindowsPowerShell51) {
    $isDesktop51 = (
        $PSVersionTable.PSEdition -eq 'Desktop' -and
        $PSVersionTable.PSVersion.Major -eq 5 -and
        $PSVersionTable.PSVersion.Minor -eq 1
    )
    if (-not $isDesktop51) {
        throw "This contract must run in Windows PowerShell 5.1; found $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
    }
}

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$merge = Join-Path $root 'Merge-ModuleScripts.ps1'
$previousRoot = $env:CAPSULENV_ROOT
try {
    $env:CAPSULENV_ROOT = $root
    Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    $build = & $merge -Clean
    Import-Module $build.ModulePath -Force -DisableNameChecking

    $rehydrate = Get-CapsulenvScoopRehydratePlan -IntegrationMode ShellOnly
    $nodes = @($rehydrate.Plan.Nodes)
    if ($nodes.Count -lt 9) {
        throw "Windows PowerShell rehydrate contract expected at least 9 nodes; found $($nodes.Count)."
    }
    if (@($nodes | Where-Object Id -eq 'package-projections').Count -ne 1) {
        throw 'Windows PowerShell rehydrate contract requires exactly one package-projections aggregate node.'
    }

    foreach ($decision in $nodes) {
        foreach ($callbackName in @('Plan', 'Apply', 'Verify')) {
            $callback = $decision.Node.$callbackName
            if ($callback -isnot [scriptblock]) {
                $typeName = if ($null -eq $callback) { '<null>' } else { $callback.GetType().FullName }
                throw "Windows PowerShell rehydrate contract: node '$($decision.Id)' callback '$callbackName' is $typeName, not ScriptBlock."
            }
        }
    }

    [pscustomobject][ordered]@{
        Runtime = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
        NodeCount = $nodes.Count
        CallbackCount = $nodes.Count * 3
        Status = 'Passed'
    }
} finally {
    Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    if ($null -eq $previousRoot) {
        Remove-Item Env:CAPSULENV_ROOT -ErrorAction SilentlyContinue
    } else {
        $env:CAPSULENV_ROOT = $previousRoot
    }
}
