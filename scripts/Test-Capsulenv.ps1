[CmdletBinding()]
param()

try {
    & (Join-Path $PSScriptRoot '..\tests\Static.Tests.ps1')
    exit 0
} catch {
    Write-Error $_
    exit 1
}
