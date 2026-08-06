[CmdletBinding()]
param()

try {
    $testsRoot = Join-Path (Join-Path $PSScriptRoot '..') 'tests'
    & (Join-Path $testsRoot 'Static.Tests.ps1')
    exit 0
} catch {
    Write-Error $_
    exit 1
}
