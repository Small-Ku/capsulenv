[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-CapsulenvTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$env:CAPSULENV_ROOT = $root

$build = & (Join-Path $root 'Merge-ModuleScripts.ps1') -Clean
Assert-CapsulenvTest `
    -Condition (Test-Path -LiteralPath $build.ModulePath -PathType Leaf) `
    -Message 'Generated module manifest was not created.'

$generatedModulePath = Join-Path (Split-Path -Parent $build.ModulePath) 'Capsulenv.psm1'
$generatedText = [System.IO.File]::ReadAllText($generatedModulePath)
Assert-CapsulenvTest `
    -Condition (-not $generatedText.Contains('##MOD_EXEC##')) `
    -Message 'Generated module still contains merge markers.'

$generatedManifestText = [System.IO.File]::ReadAllText($build.ModulePath)
Assert-CapsulenvTest `
    -Condition (-not $generatedManifestText.Contains('__GENERATED_')) `
    -Message 'Generated manifest still contains export placeholders.'

Import-Module $build.ModulePath -Force
$module = Get-Module Capsulenv
$required = @(
    'Invoke-Capsulenv',
    'Initialize-Capsulenv',
    'Invoke-CapsulenvDoctor',
    'Register-CapsulenvBrowserProfile',
    'Start-CapsulenvBrowser',
    'Start-CapsulenvBitwarden',
    'Test-CapsulenvBitwardenSshAgent',
    'Enable-CapsulenvUserEnvironment',
    'Restore-CapsulenvUserEnvironment'
)
foreach ($name in $required) {
    Assert-CapsulenvTest `
        -Condition ($null -ne (Get-Command $name -Module Capsulenv -ErrorAction SilentlyContinue)) `
        -Message "Missing exported function: $name"
}

$config = Get-CapsulenvConfiguration -Refresh
Assert-CapsulenvTest -Condition ($config.SchemaVersion -eq 1) -Message 'Unexpected configuration schema.'
Assert-CapsulenvTest `
    -Condition (-not [string]::IsNullOrWhiteSpace([string]$config.Scoop.ConfigHome)) `
    -Message 'Scoop.ConfigHome must isolate Scoop configuration.'

$plan = & $module { Get-CapsulenvEnvironmentPlan }
Assert-CapsulenvTest `
    -Condition ([System.IO.Path]::IsPathRooted([string]$plan.Variables['SCOOP'])) `
    -Message 'SCOOP was not resolved to an absolute path.'
Assert-CapsulenvTest `
    -Condition ([System.IO.Path]::IsPathRooted([string]$plan.Variables['XDG_CONFIG_HOME'])) `
    -Message 'XDG_CONFIG_HOME was not resolved to an absolute path.'

$mergedPath = & $module {
    Merge-CapsulenvPath -ExistingPath 'C:\Tools;C:\Else' -Prepend @('c:\tools\', 'C:\New')
}
Assert-CapsulenvTest `
    -Condition ($mergedPath -eq 'c:\tools\;C:\New;C:\Else') `
    -Message "PATH merge was not stable and case-insensitive: $mergedPath"

$quotedArgument = & $module { ConvertTo-CapsulenvProcessArgument -Argument 'C:\Path With Space\' }
Assert-CapsulenvTest `
    -Condition ($quotedArgument -eq '"C:\Path With Space\\"') `
    -Message "Native process argument quoting was incorrect: $quotedArgument"

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("capsulenv-test-{0}" -f [Guid]::NewGuid().ToString('N'))
try {
    [void](New-Item -ItemType Directory -Path $tempRoot -Force)
    $iniPath = Join-Path $tempRoot 'profiles.ini'
    & $module {
        param($Path)
        $data = New-CapsulenvOrderedDictionary
        Set-CapsulenvIniValue -Data $data -Section 'General' -Name 'Version' -Value '2'
        Set-CapsulenvIniValue -Data $data -Section 'Profile0' -Name 'Path' -Value 'Profiles/test'
        Write-CapsulenvIniFile -Path $Path -Data $data
        $roundTrip = Read-CapsulenvIniFile -Path $Path
        if ($roundTrip['Profile0']['Path'] -ne 'Profiles/test') {
            throw 'INI round-trip failed.'
        }
    } $iniPath

    $profilePath = Join-Path $tempRoot 'profile'
    $cachePath = Join-Path $tempRoot 'cache'
    [void](New-Item -ItemType Directory -Path $profilePath -Force)
    [void](New-Item -ItemType Directory -Path $cachePath -Force)
    $originalUserJs = 'user_pref("example.keep", true);' + "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $profilePath 'user.js'), $originalUserJs)
    & $module {
        param($ProfilePath, $CachePath)
        Set-CapsulenvManagedUserJs -Browser Firefox -ProfilePath $ProfilePath -CachePath $CachePath
        [void](Remove-CapsulenvManagedUserJs -ProfilePath $ProfilePath)
    } $profilePath $cachePath
    $restoredUserJs = [System.IO.File]::ReadAllText((Join-Path $profilePath 'user.js'))
    Assert-CapsulenvTest `
        -Condition ($restoredUserJs -eq $originalUserJs) `
        -Message 'Managed browser user.js block was not removed cleanly.'
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

Invoke-Capsulenv help
Write-Host 'capsulenv static smoke tests passed.' -ForegroundColor Green
