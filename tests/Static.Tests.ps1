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

function Assert-PowerShellFileParses {
    param([Parameter(Mandatory = $true)][string]$Path)

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors -and $errors.Count -gt 0) {
        $detail = $errors | ForEach-Object {
            '{0}:{1}: {2}' -f $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Message
        }
        throw "PowerShell parse failed for $Path`n$($detail -join [Environment]::NewLine)"
    }
}

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$env:CAPSULENV_ROOT = $root

Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1' |
    Where-Object { $_.FullName -notlike "$(Join-Path $root '.build')*" } |
    ForEach-Object { Assert-PowerShellFileParses -Path $_.FullName }

$build = & (Join-Path $root 'Merge-ModuleScripts.ps1') -Clean
Assert-CapsulenvTest `
    -Condition (Test-Path -LiteralPath $build.ModulePath -PathType Leaf) `
    -Message 'Generated module manifest was not created.'

$generatedModulePath = Join-Path (Split-Path -Parent $build.ModulePath) 'Capsulenv.psm1'
$generatedText = [System.IO.File]::ReadAllText($generatedModulePath)
Assert-CapsulenvTest `
    -Condition (-not $generatedText.Contains('##MOD_EXEC##')) `
    -Message 'Generated module still contains merge markers.'

$launcherSource = [System.IO.File]::ReadAllText((Join-Path $root 'capsulenv.cmd'))
$bootstrapOrder = @(
    'call :FindScoopPwsh "%CAPSULENV_BOOTSTRAP_SCOOP_ROOT%"',
    'call :FindScoopPwsh "%CAPSULENV_BOOTSTRAP_SCOOP_GLOBAL_ROOT%"',
    'where pwsh.exe',
    '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'
)
$previousBootstrapIndex = -1
foreach ($bootstrapStep in $bootstrapOrder) {
    $bootstrapIndex = $launcherSource.IndexOf($bootstrapStep, [System.StringComparison]::OrdinalIgnoreCase)
    Assert-CapsulenvTest `
        -Condition ($bootstrapIndex -gt $previousBootstrapIndex) `
        -Message "PowerShell bootstrap search order is missing or unsafe at: $bootstrapStep"
    $previousBootstrapIndex = $bootstrapIndex
}
foreach ($requiredBootstrapBehavior in @(
    'dir /b /ad /o-d',
    'if /i not "%%D"=="current"',
    'call :SelectPowerShell "%CAPSULENV_PWSH_APP_ROOT%\current\pwsh.exe"',
    'call :SelectPowerShell "%~1\shims\pwsh.exe"',
    '"%~1" -NoLogo -NoProfile -Command "exit 0" >nul 2>nul'
)) {
    Assert-CapsulenvTest `
        -Condition $launcherSource.Contains($requiredBootstrapBehavior) `
        -Message "PowerShell bootstrap resolver is missing required behavior: $requiredBootstrapBehavior"
}

$environmentSource = [System.IO.File]::ReadAllText(
    (Join-Path (Join-Path $root 'src') '30-Environment.ps1')
)
foreach ($requiredLaunch in @(
    '& $shellPath -NoLogo -NoExit -ExecutionPolicy Bypass',
    '& $shellPath -NoLogo -ExecutionPolicy Bypass -Command $Command'
)) {
    Assert-CapsulenvTest `
        -Condition $environmentSource.Contains($requiredLaunch) `
        -Message "Child PowerShell launch must explicitly use Process-scope ExecutionPolicy Bypass: $requiredLaunch"
}

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
    'Invoke-CapsulenvScoopRehydrate',
    'Invoke-CapsulenvScoopHookReplay',
    'Reset-CapsulenvScoop',
    'Test-CapsulenvScoopRehydrationRequired',
    'Start-CapsulenvBrowser',
    'Start-CapsulenvBitwarden',
    'Set-CapsulenvBitwardenDesktopSshAgent',
    'Restore-CapsulenvBitwardenDesktopSettings',
    'Get-CapsulenvBitwardenSshAgentStatus',
    'Invoke-CapsulenvBitwardenSshAgentSetup',
    'Restore-CapsulenvBitwardenSshAgentSetup',
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
Assert-CapsulenvTest -Condition ($config.SchemaVersion -eq 2) -Message 'Unexpected configuration schema.'
Assert-CapsulenvTest `
    -Condition ([string]$config.Bitwarden.Authorization -eq 'always') `
    -Message 'Unexpected default Bitwarden SSH authorization behavior.'

$bitwardenJsonRoundTrip = & $module {
    $source = '{"vault_payload":"keep-me","nested":{"global_desktopSettings_sshAgentEnabled":false},"text":"\"global_desktopSettings_sshAgentEnabled\": false","user_12345678-1234-1234-1234-123456789abc_example":true}'
    $enabledName = 'global_desktopSettings_sshAgentEnabled'
    $promptName = 'user_12345678-1234-1234-1234-123456789abc_desktopSettings_sshAgentRememberAuthorizations'

    $patched = Set-CapsulenvJsonPropertyLiteral -JsonText $source -Name $enabledName -Literal 'true'
    $patched = Set-CapsulenvJsonPropertyLiteral -JsonText $patched -Name $promptName -Literal '"rememberUntilLock"'
    Assert-CapsulenvJsonObjectText -Text $patched

    $restored = Remove-CapsulenvJsonProperty -JsonText $patched -Name $enabledName
    $restored = Remove-CapsulenvJsonProperty -JsonText $restored -Name $promptName
    Assert-CapsulenvJsonObjectText -Text $restored

    [pscustomobject]@{
        Patched = $patched
        Restored = $restored
        TopLevelEnabledExists = (Get-CapsulenvJsonPropertySnapshot -JsonText $restored -Name $enabledName).Exists
        TopLevelPromptExists = (Get-CapsulenvJsonPropertySnapshot -JsonText $restored -Name $promptName).Exists
    }
}
Assert-CapsulenvTest `
    -Condition ($bitwardenJsonRoundTrip.Patched.Contains('global_desktopSettings_sshAgentEnabled')) `
    -Message 'Bitwarden SSH Agent global setting was not inserted.'
Assert-CapsulenvTest `
    -Condition ($bitwardenJsonRoundTrip.Patched.Contains('sshAgentRememberAuthorizations')) `
    -Message 'Bitwarden authorization setting was not inserted.'
Assert-CapsulenvTest `
    -Condition (-not $bitwardenJsonRoundTrip.TopLevelEnabledExists) `
    -Message 'Bitwarden inserted SSH Agent setting was not removed during precise restore.'
Assert-CapsulenvTest `
    -Condition (-not $bitwardenJsonRoundTrip.TopLevelPromptExists) `
    -Message 'Bitwarden inserted authorization setting was not removed during precise restore.'
Assert-CapsulenvTest `
    -Condition ($bitwardenJsonRoundTrip.Restored.Contains('"vault_payload":"keep-me"')) `
    -Message 'Bitwarden setting restore changed unrelated JSON state.'
Assert-CapsulenvTest `
    -Condition ($bitwardenJsonRoundTrip.Restored.Contains('"nested":{"global_desktopSettings_sshAgentEnabled":false}')) `
    -Message 'Bitwarden setting patch touched a nested property with the same name.'
Assert-CapsulenvTest `
    -Condition ($bitwardenJsonRoundTrip.Restored.Contains('\"global_desktopSettings_sshAgentEnabled\": false')) `
    -Message 'Bitwarden setting patch touched key-like text inside a JSON string.'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("capsulenv-test-{0}" -f [Guid]::NewGuid().ToString('N'))
try {
    $tempConfigRoot = Join-Path $tempRoot 'config'
    [void](New-Item -ItemType Directory -Path $tempConfigRoot -Force)
    Copy-Item -LiteralPath (Join-Path (Join-Path $root 'config') 'capsulenv.psd1') -Destination $tempConfigRoot
    '@{ Scoop = @{ ReplayHooks = @{} } }' |
        Set-Content -LiteralPath (Join-Path $tempConfigRoot 'capsulenv.local.psd1') -Encoding UTF8

    $replacementConfig = & $module {
        param($TemporaryRoot)
        [void](Initialize-CapsulenvContext -Root $TemporaryRoot)
        Get-CapsulenvConfiguration -Refresh
    } $tempRoot
    Assert-CapsulenvTest `
        -Condition ($replacementConfig.Scoop.ReplayHooks.Count -eq 0) `
        -Message 'Local ReplayHooks must replace the default allow-list as one unit.'

    [void](New-Item -ItemType Directory -Path (Join-Path $tempRoot '.capsulenv') -Force)
    '{}' | Set-Content -LiteralPath (Join-Path (Join-Path $tempRoot '.capsulenv') 'scoop-rehydration.json') -Encoding UTF8
    $missingFingerprintIsStale = & $module { Test-CapsulenvScoopRehydrationRequired }
    Assert-CapsulenvTest `
        -Condition $missingFingerprintIsStale `
        -Message 'Incomplete relocation state must require rehydration.'
} finally {
    & $module { param($OriginalRoot) [void](Initialize-CapsulenvContext -Root $OriginalRoot) } $root
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
$config = Get-CapsulenvConfiguration -Refresh
Assert-CapsulenvTest `
    -Condition (-not $config.Scoop.ContainsKey('ConfigHome')) `
    -Message 'Scoop.ConfigHome must not create a parallel data store.'
Assert-CapsulenvTest `
    -Condition (-not $config.Bitwarden.ContainsKey('AppDataDir')) `
    -Message 'Bitwarden app-data must be owned by Scoop persist.'
Assert-CapsulenvTest `
    -Condition (-not $config.Scoop.ReplayHooks.ContainsKey('bitwarden')) `
    -Message 'Bitwarden pre_install must not be replayed automatically.'
Assert-CapsulenvTest `
    -Condition ($config.Bitwarden.Authorization -in @('always', 'never', 'remember-until-lock')) `
    -Message 'Bitwarden.Authorization is invalid.'
Assert-CapsulenvTest `
    -Condition (-not $config.Scoop.ReplayHooks.ContainsKey('zen')) `
    -Message 'Ambiguous app aliases must not receive automatic lifecycle replay.'
foreach ($browser in @('Firefox', 'Zen')) {
    Assert-CapsulenvTest `
        -Condition (-not $config.Browsers[$browser].ContainsKey('ProfileDir')) `
        -Message "$browser profile must be owned by Scoop persist."
    Assert-CapsulenvTest `
        -Condition (-not $config.Browsers[$browser].ContainsKey('CacheDir')) `
        -Message "$browser cache must not be owned by capsulenv."
}

$plan = & $module { Get-CapsulenvEnvironmentPlan }
Assert-CapsulenvTest `
    -Condition ([System.IO.Path]::IsPathRooted([string]$plan.Variables['SCOOP'])) `
    -Message 'SCOOP was not resolved to an absolute path.'
Assert-CapsulenvTest `
    -Condition ([System.IO.Path]::IsPathRooted([string]$plan.Variables['SCOOP_GLOBAL'])) `
    -Message 'SCOOP_GLOBAL was not isolated to an absolute portable path.'
Assert-CapsulenvTest `
    -Condition (-not $plan.Variables.Contains('XDG_CONFIG_HOME')) `
    -Message 'XDG_CONFIG_HOME should not be redirected by capsulenv.'
Assert-CapsulenvTest `
    -Condition (-not $plan.Variables.Contains('BITWARDEN_APPDATA_DIR')) `
    -Message 'BITWARDEN_APPDATA_DIR should be owned by the Scoop package.'

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

$replayPath = Join-Path (Join-Path $root 'scripts') 'scoop-capsulenv-replay.ps1'
$replayText = [System.IO.File]::ReadAllText($replayPath)
foreach ($requiredText in @('installed_manifest', 'install_info', 'Invoke-HookScript', 'pre_install', 'post_install')) {
    Assert-CapsulenvTest `
        -Condition $replayText.Contains($requiredText) `
        -Message "Lifecycle runner is missing required installed-manifest behavior: $requiredText"
}
Assert-CapsulenvTest `
    -Condition (-not $replayText.Contains('scoop install')) `
    -Message 'Lifecycle replay must not reinstall or download applications.'

$bitwardenSource = [System.IO.File]::ReadAllText(
    (Join-Path (Join-Path $root 'src') '55-BitwardenSshAgent.ps1')
)
foreach ($requiredStateKey in @(
    'global_desktopSettings_sshAgentEnabled',
    'desktopSettings_sshAgentRememberAuthorizations'
)) {
    Assert-CapsulenvTest `
        -Condition $bitwardenSource.Contains($requiredStateKey) `
        -Message "Bitwarden setting patch is missing its scoped state key: $requiredStateKey"
}
Assert-CapsulenvTest `
    -Condition $bitwardenSource.Contains('Assert-CapsulenvJsonObjectText') `
    -Message 'Bitwarden setting writes must validate JSON before replacement.'
Assert-CapsulenvTest `
    -Condition $bitwardenSource.Contains('Get-CapsulenvJsonTopLevelProperties') `
    -Message 'Bitwarden setting patch must locate only top-level JSON properties.'
Assert-CapsulenvTest `
    -Condition $bitwardenSource.Contains('Reset-CapsulenvScoop -Apps') `
    -Message 'Bitwarden setup must let Scoop rebuild its persist link before patching settings.'
Assert-CapsulenvTest `
    -Condition (-not $bitwardenSource.Contains('ConvertTo-Json -Depth 100')) `
    -Message 'Bitwarden state must not be wholesale reserialized.'

$trackedText = @(
    [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'config') 'capsulenv.psd1')),
    [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') '60-Browser.ps1'))
) -join "`n"
foreach ($forbidden in @('data\browsers', 'data\bitwarden', 'ProfileDir', 'CacheDir')) {
    Assert-CapsulenvTest `
        -Condition (-not $trackedText.Contains($forbidden)) `
        -Message "Parallel app-data ownership remains in tracked configuration/code: $forbidden"
}

Invoke-Capsulenv help
Write-Host 'capsulenv static smoke tests passed.' -ForegroundColor Green
