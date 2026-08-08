[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-CapsulenvBuildInstallTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("capsulenv-build-install-test-{0}" -f [Guid]::NewGuid().ToString('N'))
$buildRoot = Join-Path $temporaryRoot 'build'
$installRoot = Join-Path $temporaryRoot 'install'

try {
    [void](New-Item -ItemType Directory -Path $temporaryRoot -Force)

    $build = & (Join-Path (Join-Path $root 'scripts') 'Build-Capsulenv.ps1') -OutputPath $buildRoot
    Assert-CapsulenvBuildInstallTest `
        -Condition (Test-Path -LiteralPath $build.ModulePath -PathType Leaf) `
        -Message 'Runtime build did not create the generated module manifest.'
    Assert-CapsulenvBuildInstallTest `
        -Condition (Test-Path -LiteralPath (Join-Path $buildRoot '.capsulenv-runtime.json') -PathType Leaf) `
        -Message 'Runtime build metadata was not created.'

    $install = & (Join-Path (Join-Path $root 'scripts') 'Install-Capsulenv.ps1') $installRoot
    Assert-CapsulenvBuildInstallTest `
        -Condition (Test-Path -LiteralPath $install.Launcher -PathType Leaf) `
        -Message 'Installer did not create the capsulenv launcher.'

    $installMarkerPath = Join-Path $installRoot '.capsulenv-install.json'
    $runtimeMetadataPath = Join-Path $installRoot '.capsulenv-runtime.json'
    Assert-CapsulenvBuildInstallTest `
        -Condition (Test-Path -LiteralPath $runtimeMetadataPath -PathType Leaf) `
        -Message 'Installer did not copy runtime metadata.'
    $installMarker = Get-Content -LiteralPath $installMarkerPath -Raw | ConvertFrom-Json
    Assert-CapsulenvBuildInstallTest `
        -Condition (@($installMarker.ManagedFiles) -contains '.capsulenv-runtime.json') `
        -Message 'Installer does not own the runtime metadata file.'

    $unmanagedPath = Join-Path $installRoot 'unmanaged.txt'
    $localConfigPath = Join-Path (Join-Path $installRoot 'config') 'capsulenv.local.psd1'
    $cacheStatePath = Join-Path (Join-Path $installRoot 'cache') 'preserved.txt'
    'keep-me' | Set-Content -LiteralPath $unmanagedPath -Encoding UTF8
    '@{ ToolStorage = @{ Enabled = $false } }' | Set-Content -LiteralPath $localConfigPath -Encoding UTF8
    'cache-state' | Set-Content -LiteralPath $cacheStatePath -Encoding UTF8

    [void](& (Join-Path (Join-Path $root 'scripts') 'Install-Capsulenv.ps1') $installRoot)
    Assert-CapsulenvBuildInstallTest `
        -Condition ((Get-Content -LiteralPath $unmanagedPath -Raw).Trim() -eq 'keep-me') `
        -Message 'Installer update changed an unmanaged destination file.'
    Assert-CapsulenvBuildInstallTest `
        -Condition ((Get-Content -LiteralPath $localConfigPath -Raw).Contains('Enabled = $false')) `
        -Message 'Installer update replaced the local capsulenv configuration.'
    Assert-CapsulenvBuildInstallTest `
        -Condition ((Get-Content -LiteralPath $cacheStatePath -Raw).Trim() -eq 'cache-state') `
        -Message 'Installer update changed mutable cache state.'

    Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    $installedModulePath = Join-Path (Join-Path (Join-Path $installRoot 'modules') 'Capsulenv') 'Capsulenv.psd1'
    Import-Module $installedModulePath -Force
    Assert-CapsulenvBuildInstallTest `
        -Condition ($null -ne (Get-Command Invoke-Capsulenv -Module Capsulenv -ErrorAction SilentlyContinue)) `
        -Message 'Installed prebuilt module does not export Invoke-Capsulenv.'
    Assert-CapsulenvBuildInstallTest `
        -Condition ((Get-Alias cenv -ErrorAction Stop).Definition -eq 'Invoke-Capsulenv') `
        -Message 'Installed prebuilt module does not export the cenv alias.'

    & (Join-Path (Join-Path $installRoot 'scripts') 'Invoke-Capsulenv.ps1') help
    Write-Host 'capsulenv build/install smoke tests passed.' -ForegroundColor Green
} finally {
    Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
