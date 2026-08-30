[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CapsulenvArguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -lt 1) {
    throw 'capsulenv-runtime.ps1 must run under Windows PowerShell 5.1.'
}

$root = [System.IO.Path]::GetFullPath((Split-Path -Parent $MyInvocation.MyCommand.Path))
$installMarker = Join-Path $root '.capsulenv-install.json'
if (-not (Test-Path -LiteralPath $installMarker -PathType Leaf)) {
    throw "capsulenv runtime bridge requires an installed capsule: $root"
}

$env:CAPSULENV_ROOT = $root
$entry = Join-Path (Join-Path (Join-Path $root 'modules') 'Capsulenv') 'runtime/Invoke-Capsulenv.ps1'
if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) {
    throw "capsulenv installed runtime entrypoint is missing: $entry"
}

& $entry @CapsulenvArguments
