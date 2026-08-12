[CmdletBinding()]
param()

try {
    $testsRoot = Join-Path (Join-Path $PSScriptRoot '..') 'tests'
    & (Join-Path (Join-Path $testsRoot 'smoke') 'Static.Smoke.ps1')
    & (Join-Path (Join-Path $testsRoot 'smoke') 'Bootstrap.Smoke.ps1')
    & (Join-Path (Join-Path $testsRoot 'smoke') 'BuildInstall.Smoke.ps1')
    exit 0
} catch {
    Write-Error $_
    exit 1
}
