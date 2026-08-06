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
    'Get-CapsulenvRelocationContext',
    'Invoke-CapsulenvPersistRelocationRepair',
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
Assert-CapsulenvTest -Condition ($config.SchemaVersion -eq 3) -Message 'Unexpected configuration schema.'
Assert-CapsulenvTest `
    -Condition ([string]$config.Bitwarden.Authorization -eq 'always') `
    -Message 'Unexpected default Bitwarden SSH authorization behavior.'

$relocationReplacement = & $module {
    $context = [pscustomobject]@{
        HasPathChanges = $true
        PathMappings = @(
            [pscustomobject]@{
                Name = 'Root'
                OldPath = 'C:\Old Capsule'
                NewPath = 'D:\New Capsule'
            }
        )
    }
    $source = 'native=C:\Old Capsule\scoop;slash=C:/Old Capsule/scoop;json="C:\\Old Capsule\\scoop";lookalike=C:\Old Capsule-backup'
    Convert-CapsulenvRelocatedText -Text $source -RelocationContext $context
}
Assert-CapsulenvTest `
    -Condition ($relocationReplacement.ReplacementCount -eq 3) `
    -Message "Relocation replacement count was incorrect: $($relocationReplacement.ReplacementCount)"
Assert-CapsulenvTest `
    -Condition $relocationReplacement.Text.Contains('D:\New Capsule\scoop') `
    -Message 'Native Windows path was not relocated.'
Assert-CapsulenvTest `
    -Condition $relocationReplacement.Text.Contains('D:/New Capsule/scoop') `
    -Message 'Forward-slash path was not relocated.'
Assert-CapsulenvTest `
    -Condition $relocationReplacement.Text.Contains('D:\\New Capsule\\scoop') `
    -Message 'JSON-escaped path was not relocated.'
Assert-CapsulenvTest `
    -Condition $relocationReplacement.Text.Contains('C:\Old Capsule-backup') `
    -Message 'Relocation replaced a lookalike path without a path boundary.'

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
    '@{ Scoop = @{ ReplayHooks = @{}; RelocationRepairs = @{} } }' |
        Set-Content -LiteralPath (Join-Path $tempConfigRoot 'capsulenv.local.psd1') -Encoding UTF8

    $replacementConfig = & $module {
        param($TemporaryRoot)
        [void](Initialize-CapsulenvContext -Root $TemporaryRoot)
        Get-CapsulenvConfiguration -Refresh
    } $tempRoot
    Assert-CapsulenvTest `
        -Condition ($replacementConfig.Scoop.ReplayHooks.Count -eq 0) `
        -Message 'Local ReplayHooks must replace the default allow-list as one unit.'
    Assert-CapsulenvTest `
        -Condition ($replacementConfig.Scoop.RelocationRepairs.Count -eq 0) `
        -Message 'Local RelocationRepairs must replace the default allow-list as one unit.'

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
if ($env:OS -eq 'Windows_NT') {
    $shimInferenceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("capsulenv-shim-test-{0}" -f [Guid]::NewGuid().ToString('N'))
    $oldCapsuleRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("capsulenv-shim-old-{0}" -f [Guid]::NewGuid().ToString('N'))
    try {
        $shimConfigRoot = Join-Path $shimInferenceRoot 'config'
        $shimRoot = Join-Path (Join-Path $shimInferenceRoot 'scoop') 'shims'
        [void](New-Item -ItemType Directory -Path $shimConfigRoot -Force)
        [void](New-Item -ItemType Directory -Path $shimRoot -Force)
        Copy-Item -LiteralPath (Join-Path (Join-Path $root 'config') 'capsulenv.psd1') -Destination $shimConfigRoot
        $oldScoopRoot = Join-Path $oldCapsuleRoot 'scoop'
        $oldTarget = Join-Path (Join-Path (Join-Path $oldScoopRoot 'apps') 'pwsh') '7.0.0\pwsh.exe'
        ('path = "{0}"' -f $oldTarget) |
            Set-Content -LiteralPath (Join-Path $shimRoot 'pwsh.shim') -Encoding ASCII

        $inferredContext = & $module {
            param($TemporaryRoot)
            [void](Initialize-CapsulenvContext -Root $TemporaryRoot)
            [void](Get-CapsulenvConfiguration -Refresh)
            Get-CapsulenvRelocationContext
        } $shimInferenceRoot
        $inferredScoopMapping = @($inferredContext.PathMappings | Where-Object { $_.Name -eq 'ScoopRoot' })
        $inferredRootMapping = @($inferredContext.PathMappings | Where-Object { $_.Name -eq 'Root' })
        Assert-CapsulenvTest `
            -Condition ($inferredContext.PreviousSource.Contains('local-shims')) `
            -Message 'Relocation context did not report stale local shim inference.'
        Assert-CapsulenvTest `
            -Condition ($inferredScoopMapping.Count -eq 1 -and $inferredScoopMapping[0].OldPath -eq $oldScoopRoot) `
            -Message 'Relocation context did not infer the previous Scoop root from shim metadata.'
        Assert-CapsulenvTest `
            -Condition ($inferredRootMapping.Count -eq 1 -and $inferredRootMapping[0].OldPath -eq $oldCapsuleRoot) `
            -Message 'Relocation context did not infer the previous capsule root from the Scoop-relative layout.'
    } finally {
        & $module { param($OriginalRoot) [void](Initialize-CapsulenvContext -Root $OriginalRoot) } $root
        if (Test-Path -LiteralPath $shimInferenceRoot) {
            Remove-Item -LiteralPath $shimInferenceRoot -Recurse -Force
        }
    }
}

$repairRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("capsulenv-repair-test-{0}" -f [Guid]::NewGuid().ToString('N'))
try {
    $repairConfigRoot = Join-Path $repairRoot 'config'
    $repairPersistRoot = Join-Path (Join-Path (Join-Path $repairRoot 'scoop') 'persist') 'test-app'
    [void](New-Item -ItemType Directory -Path $repairConfigRoot -Force)
    [void](New-Item -ItemType Directory -Path $repairPersistRoot -Force)
    Copy-Item -LiteralPath (Join-Path (Join-Path $root 'config') 'capsulenv.psd1') -Destination $repairConfigRoot
    @'
@{
    Scoop = @{
        ReplayHooks = @{}
        RelocationRepairs = @{
            'test-app' = @(
                @{ Path = 'settings.json'; Format = 'json'; MaxBytes = 1048576 }
            )
        }
    }
}
'@ | Set-Content -LiteralPath (Join-Path $repairConfigRoot 'capsulenv.local.psd1') -Encoding UTF8

    $oldRoot = $repairRoot + '-old'
    $settingsPath = Join-Path $repairPersistRoot 'settings.json'
    $sourceJson = '{"path":"' + ($oldRoot.Replace('\', '\\')) + '\\scoop\\apps","lookalike":"' + ($oldRoot.Replace('\', '\\')) + '-backup"}'
    [System.IO.File]::WriteAllText($settingsPath, $sourceJson, [System.Text.UTF8Encoding]::new($false))

    $repairResult = & $module {
        param($TemporaryRoot, $PreviousRoot)
        [void](Initialize-CapsulenvContext -Root $TemporaryRoot)
        [void](Get-CapsulenvConfiguration -Refresh)
        $current = Get-CapsulenvRelocationFingerprint
        $previous = [ordered]@{
            Root = $PreviousRoot
            ScoopRoot = Join-Path $PreviousRoot 'scoop'
            ScoopGlobalRoot = Join-Path $PreviousRoot 'scoop-global'
            ComputerName = [Environment]::MachineName
            User = ('{0}\{1}' -f [Environment]::UserDomainName, [Environment]::UserName)
        }
        $context = New-CapsulenvRelocationContext -Previous $previous -Current $current
        Invoke-CapsulenvPersistRelocationRepair -RelocationContext $context
    } $repairRoot $oldRoot

    $repairedJson = [System.IO.File]::ReadAllText($settingsPath)
    Assert-CapsulenvTest `
        -Condition ($repairResult.FilesChanged -eq 1 -and $repairResult.Replacements -eq 1) `
        -Message 'Transactional persist repair did not report the expected change.'
    Assert-CapsulenvTest `
        -Condition $repairedJson.Contains(($repairRoot.Replace('\', '\\')) + '\\scoop\\apps') `
        -Message 'Transactional persist repair did not write the current root.'
    Assert-CapsulenvTest `
        -Condition $repairedJson.Contains(($oldRoot.Replace('\', '\\')) + '-backup') `
        -Message 'Transactional persist repair changed a lookalike path.'
    Assert-CapsulenvTest `
        -Condition ($null -ne ($repairedJson | ConvertFrom-Json)) `
        -Message 'Transactional persist repair produced invalid JSON.'
} finally {
    & $module { param($OriginalRoot) [void](Initialize-CapsulenvContext -Root $OriginalRoot) } $root
    if (Test-Path -LiteralPath $repairRoot) {
        Remove-Item -LiteralPath $repairRoot -Recurse -Force
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
    -Condition (-not $config.Scoop.RelocationRepairs.ContainsKey('bitwarden')) `
    -Message 'Bitwarden app state must not receive generic path replacement by default.'
foreach ($browserApp in @('firefox', 'firefox-esr', 'zen-browser')) {
    Assert-CapsulenvTest `
        -Condition $config.Scoop.RelocationRepairs.ContainsKey($browserApp) `
        -Message "Missing default browser persist relocation rules: $browserApp"
}
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

$relocationSource = @(
    [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') '45-Relocation.ps1')),
    [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') '46-PersistRelocation.ps1'))
) -join "`n"
foreach ($requiredRelocationBehavior in @(
    'RelocationRepairs',
    'Resolve-CapsulenvPersistRepairPath',
    'Assert-CapsulenvPersistRepairProcessesStopped',
    '[System.IO.File]::Replace',
    'ConvertFrom-Json',
    'MaxBytes'
)) {
    Assert-CapsulenvTest `
        -Condition $relocationSource.Contains($requiredRelocationBehavior) `
        -Message "Persist relocation engine is missing required safety behavior: $requiredRelocationBehavior"
}
Assert-CapsulenvTest `
    -Condition (-not $relocationSource.Contains('Get-ChildItem -Recurse')) `
    -Message 'Persist relocation must not recursively scan unapproved app data.'

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
