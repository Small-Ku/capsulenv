Describe 'Capsulenv static and relocation' {
    It 'passes static, module, relocation, cache, and command contract checks' {
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
        $powerShellSource = [System.IO.File]::ReadAllText(
            (Join-Path (Join-Path $root 'src') '32-PowerShell.ps1')
        )
        Assert-CapsulenvTest `
            -Condition $environmentSource.Contains('Get-CapsulenvPowerShellChildLaunchPlan') `
            -Message 'Child PowerShell launch must be delegated to the mode-aware launch plan.'
        foreach ($requiredLaunchBehavior in @(
            "`$arguments.Add('-ExecutionPolicy')",
            "`$arguments.Add('Bypass')",
            "`$arguments.Add('-NoProfile')",
            'Get-CapsulenvPortablePowerShellProfilePaths',
            'CAPSULENV_PSREADLINE_HISTORY'
        )) {
            Assert-CapsulenvTest `
                -Condition $powerShellSource.Contains($requiredLaunchBehavior) `
                -Message "PowerShell launch plan is missing required isolation behavior: $requiredLaunchBehavior"
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
            'Initialize-CapsulenvScoopBootstrap',
            'Ensure-CapsulenvScoopPortableConfig',
            'Get-CapsulenvInstallMode',
            'Set-CapsulenvInstallMode',
            'Install-CapsulenvUserEnvironment',
            'Enter-CapsulenvUserShell',
            'Enable-CapsulenvUserEnvironment',
            'Restore-CapsulenvUserEnvironment',
            'Initialize-CapsulenvToolStorage',
            'New-CapsulenvProjectCacheLink',
            'Remove-CapsulenvProjectCacheLink',
            'Get-CapsulenvToolStorageStatus',
            'Get-CapsulenvProjectCacheStatus',
            'Repair-CapsulenvProjectCacheLinks',
            'Get-CapsulenvManagedProjectCacheLinks',
            'Invoke-CapsulenvToolRelocationRepair',
            'Repair-CapsulenvUvRelocation',
            'Repair-CapsulenvPixiRelocation',
            'Register-CapsulenvToolWorkspace',
            'Unregister-CapsulenvToolWorkspace',
            'Get-CapsulenvToolWorkspaces',
            'Get-CapsulenvToolRelocationStatus',
            'Get-CapsulenvIdentity',
            'Get-CapsulenvScratchPath',
            'Invoke-CapsulenvEject',
            'Get-CapsulenvOfflineReadiness',
            'Invoke-CapsulenvOfflinePrefetch',
            'Get-CapsulenvVersionDrift',
            'Get-CapsulenvScoopAppShortcuts',
            'Get-CapsulenvScoopShortcutCatalog',
            'Start-CapsulenvScoopShortcut'
        )
        foreach ($name in $required) {
            Assert-CapsulenvTest `
                -Condition ($null -ne (Get-Command $name -Module Capsulenv -ErrorAction SilentlyContinue)) `
                -Message "Missing exported function: $name"
        }

        $config = Get-CapsulenvConfiguration -Refresh
        Assert-CapsulenvTest -Condition ($config.SchemaVersion -eq 10) -Message 'Unexpected configuration schema.'
        Assert-CapsulenvTest -Condition ([bool]$config.Scoop.Bootstrap.Enabled) -Message 'Scoop bootstrap is not enabled by default.'
        Assert-CapsulenvTest -Condition ([int]$config.Scoop.Bootstrap.GitDepth -eq 1) -Message 'Scoop bootstrap must default to a shallow depth of one.'
        Assert-CapsulenvTest -Condition (-not [string]::IsNullOrWhiteSpace([string]$config.Scoop.Bootstrap.Scoop.Repository)) -Message 'Scoop bootstrap repository is missing.'
        Assert-CapsulenvTest -Condition (-not [string]::IsNullOrWhiteSpace([string]$config.Scoop.Bootstrap.Main.Repository)) -Message 'Main bootstrap repository is missing.'
        Assert-CapsulenvTest `
            -Condition (@($config.Environment.ModulePath).Count -gt 0) `
            -Message 'Portable PowerShell module path is not configured.'
        $environmentPlan = & $module { Get-CapsulenvEnvironmentPlan }
        $expectedModuleRoot = [System.IO.Path]::GetFullPath((Join-Path $root 'PowerShell/Modules'))
        Assert-CapsulenvTest `
            -Condition ([string]$environmentPlan.Variables.CAPSULENV_MODULE_ROOT -eq $expectedModuleRoot) `
            -Message 'CAPSULENV_MODULE_ROOT does not resolve to the first portable module path.'
        Assert-CapsulenvTest `
            -Condition (@($environmentPlan.ModulePathEntries) -contains $expectedModuleRoot) `
            -Message 'Portable module root is missing from the environment plan.'
        Assert-CapsulenvTest `
            -Condition ([string]$config.Bitwarden.Authorization -eq 'always') `
            -Message 'Unexpected default Bitwarden SSH authorization behavior.'

        $uvRequirement = & $module {
            $receipt = @'
        [tool]
        requirements = [{ name = "ruff", url = "https://example.invalid/ruff.whl" }]
        python = "C:/Old Capsule/tool-data/uv/python/cpython"
'@
            Get-CapsulenvUvFirstRequirementTable -ReceiptText $receipt
        }
        Assert-CapsulenvTest `
            -Condition ([string]$uvRequirement.Name -eq 'ruff') `
            -Message 'uv receipt parser did not preserve the first requirement name.'

        $toolRelocationSource = [System.IO.File]::ReadAllText(
            (Join-Path (Join-Path $root 'src') '37-ToolRelocation.ps1')
        )
        foreach ($requiredUvBehavior in @(
            '("{0}=={1}" -f $toolName, $version)',
            '[string]$installation.Key,',
            "'--force'",
            "'--no-python-downloads'"
        )) {
            Assert-CapsulenvTest `
                -Condition $toolRelocationSource.Contains($requiredUvBehavior) `
                -Message "uv relocation repair is missing required behavior: $requiredUvBehavior"
        }
        Assert-CapsulenvTest `
            -Condition (-not $toolRelocationSource.Contains('Set-CapsulenvUvReceiptPinnedVersion')) `
            -Message 'uv relocation must not rewrite the saved requirement to pin a version.'

        $pixiRelocationSource = [System.IO.File]::ReadAllText(
            (Join-Path (Join-Path $root 'src') '39-ToolWorkspaceRelocation.ps1')
        )
        foreach ($requiredPixiBehavior in @(
            "'--no-progress', 'global', 'sync'",
            "'--no-progress',",
            "'reinstall',",
            "'--all',",
            "'--locked',",
            "'--manifest-path', [string]`$workspace.ProjectPath"
        )) {
            Assert-CapsulenvTest `
                -Condition $pixiRelocationSource.Contains($requiredPixiBehavior) `
                -Message "Pixi relocation repair is missing required behavior: $requiredPixiBehavior"
        }
        Assert-CapsulenvTest `
            -Condition $pixiRelocationSource.Contains("Status = 'ManualRequired'") `
            -Message 'Pixi global sync must remain explicit by default.'

        foreach ($requiredUvWorkspaceBehavior in @(
            "'venv', `$environmentPath",
            "'--relocatable'",
            "'UV_PROJECT_ENVIRONMENT'",
            "'sync',",
            "'--project', [string]`$Workspace.ProjectPath",
            "Move-Item -LiteralPath `$environmentPath -Destination `$rollbackPath",
            "Move-Item -LiteralPath `$rollbackPath -Destination `$environmentPath"
        )) {
            Assert-CapsulenvTest `
                -Condition $pixiRelocationSource.Contains($requiredUvWorkspaceBehavior) `
                -Message "uv workspace relocation is missing required behavior: $requiredUvWorkspaceBehavior"
        }

        $workspaceRegistrySource = [System.IO.File]::ReadAllText(
            (Join-Path (Join-Path $root 'src') '38-ToolWorkspaceRegistry.ps1')
        )
        foreach ($requiredWorkspaceBehavior in @(
            "'tool-workspaces.json'",
            "SchemaVersion = 2",
            "ProjectScope = [string]`$reference.Scope",
            "ProjectReference = [string]`$reference.Reference"
        )) {
            Assert-CapsulenvTest `
                -Condition $workspaceRegistrySource.Contains($requiredWorkspaceBehavior) `
                -Message "Tool-workspace registry is missing required behavior: $requiredWorkspaceBehavior"
        }

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

        foreach ($toolVariable in @(
            'UV_CACHE_DIR',
            'UV_PYTHON_CACHE_DIR',
            'UV_PYTHON_INSTALL_DIR',
            'UV_PYTHON_BIN_DIR',
            'UV_TOOL_DIR',
            'UV_TOOL_BIN_DIR',
            'PIXI_HOME',
            'PIXI_CACHE_DIR',
            'NPM_CONFIG_CACHE',
            'NPM_CONFIG_PREFIX',
            'PNPM_HOME',
            'PNPM_CONFIG_STORE_DIR',
            'PNPM_CONFIG_CACHE_DIR',
            'PNPM_CONFIG_STATE_DIR',
            'PNPM_CONFIG_GLOBAL_DIR',
            'PNPM_CONFIG_GLOBAL_BIN_DIR',
            'BUN_INSTALL_GLOBAL_DIR',
            'BUN_INSTALL_BIN',
            'BUN_INSTALL_CACHE_DIR',
            'GOPATH',
            'GOBIN',
            'GOCACHE',
            'GOMODCACHE',
            'GIT_CONFIG_GLOBAL',
            'UV_CONFIG_FILE',
            'NPM_CONFIG_USERCONFIG',
            'GOENV',
            'RUSTUP_HOME',
            'CARGO_HOME',
            'SCCACHE_DIR',
            'SCCACHE_CONF',
            'CCACHE_DIR',
            'CCACHE_TEMPDIR',
            'CCACHE_CONFIGPATH'
        )) {
            Assert-CapsulenvTest `
                -Condition ($plan.Variables.Contains($toolVariable) -and [System.IO.Path]::IsPathRooted([string]$plan.Variables[$toolVariable])) `
                -Message "Portable tool variable was not resolved inside the capsule: $toolVariable"
        }
        $toolStorageStatus = @(Get-CapsulenvToolStorageStatus)
        Assert-CapsulenvTest `
            -Condition ($null -ne ($toolStorageStatus | Where-Object { $_.Name -eq 'SCOOP_CACHE' })) `
            -Message 'Scoop-owned package cache is missing from the tool-storage plan.'
        $toolStoragePlan = & $module { Get-CapsulenvToolStoragePlan }
        Assert-CapsulenvTest `
            -Condition (@($toolStoragePlan.Files).Count -eq 8) `
            -Message 'ToolStorage file-valued configuration locations were not planned separately.'
        [void](Initialize-CapsulenvToolStorage)
        foreach ($fileVariable in @('GIT_CONFIG_GLOBAL', 'UV_CONFIG_FILE', 'PIXI_CONFIG_FILE', 'NPM_CONFIG_USERCONFIG', 'CAPSULENV_PSREADLINE_HISTORY', 'GOENV', 'CCACHE_CONFIGPATH', 'SCCACHE_CONF')) {
            $status = $toolStorageStatus | Where-Object { $_.Name -eq $fileVariable } | Select-Object -First 1
            if ($null -eq $status) {
                $status = @(Get-CapsulenvToolStorageStatus) | Where-Object { $_.Name -eq $fileVariable } | Select-Object -First 1
            }
            Assert-CapsulenvTest `
                -Condition ($null -ne $status -and $status.Kind -eq 'File' -and $status.Class -eq 'Config' -and (Test-Path -LiteralPath $status.Value -PathType Leaf)) `
                -Message "Portable file-valued tool config was not initialized correctly: $fileVariable"
        }
        foreach ($cacheVariable in @('UV_CACHE_DIR', 'PIXI_CACHE_DIR', 'NPM_CONFIG_CACHE', 'PNPM_CONFIG_STORE_DIR', 'BUN_INSTALL_CACHE_DIR', 'GOCACHE', 'GOMODCACHE', 'CCACHE_DIR', 'SCCACHE_DIR')) {
            $status = @(Get-CapsulenvToolStorageStatus) | Where-Object { $_.Name -eq $cacheVariable } | Select-Object -First 1
            Assert-CapsulenvTest `
                -Condition ($null -ne $status -and $status.Class -eq 'Cache') `
                -Message "Disposable cache was not classified as Cache: $cacheVariable"
        }
        Assert-CapsulenvTest `
            -Condition (-not $plan.Variables.Contains('CARGO_TARGET_DIR')) `
            -Message 'CARGO_TARGET_DIR must remain project-owned instead of becoming one shared global target directory.'
        Assert-CapsulenvTest `
            -Condition (-not $plan.Variables.Contains('GOTMPDIR')) `
            -Message 'GOTMPDIR is temporary scratch space and must not be treated as persistent capsule cache.'
        Assert-CapsulenvTest `
            -Condition (-not $plan.Variables.Contains('GOTELEMETRYDIR')) `
            -Message 'GOTELEMETRYDIR is reported by Go but is not an environment-settable redirect; do not claim it is capsule-owned.'
        $scoopCacheStatus = $toolStorageStatus | Where-Object { $_.Name -eq 'SCOOP_CACHE' } | Select-Object -First 1
        Assert-CapsulenvTest `
            -Condition ($toolStoragePlan.Directories -notcontains $scoopCacheStatus.Value) `
            -Message 'capsulenv must report but not create the Scoop-owned package cache.'
        Assert-CapsulenvTest `
            -Condition $config.ToolStorage.ProjectLinks.ContainsKey('cargo-target') `
            -Message 'The default cargo-target project cache profile is missing.'
        $capsuleProjectStatus = @(Get-CapsulenvProjectCacheStatus -ProjectPath $root)
        $capsuleProjectStatusAgain = @(Get-CapsulenvProjectCacheStatus -ProjectPath $root)
        Assert-CapsulenvTest `
            -Condition ($capsuleProjectStatus.Count -eq 1 -and $capsuleProjectStatus[0].ProjectId -eq $capsuleProjectStatusAgain[0].ProjectId) `
            -Message 'Capsule-relative project cache identity was not stable.'

        $projectCacheSource = @(
            [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') '35-ToolStorage.ps1')),
            [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'src') '36-ProjectCacheRegistry.ps1'))
        ) -join "`n"
        foreach ($requiredProjectCacheBehavior in @(
            'project-cache-links.json',
            'LastStorePath',
            'Repair-CapsulenvProjectCacheLinks',
            'Get-CapsulenvReparseTarget',
            'Refusing to replace an unrecognized project link',
            'NativeFileIdentity'
        )) {
            Assert-CapsulenvTest `
                -Condition $projectCacheSource.Contains($requiredProjectCacheBehavior) `
                -Message "Project-cache relocation safety is missing: $requiredProjectCacheBehavior"
        }
        Assert-CapsulenvTest `
            -Condition $projectCacheSource.Contains('Windows does not support directory hard links') `
            -Message 'Directory hard links must remain rejected.'
        Assert-CapsulenvTest `
            -Condition ($projectCacheSource.IndexOf('$target = Get-CapsulenvReparseTarget') -lt $projectCacheSource.IndexOf('Test-CapsulenvHardLinkMatch -Left $Plan.LinkPath')) `
            -Message 'File symlinks must be detected before hard-link file identity checks.'

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


        # Scoop dispatches custom-command arguments by collecting them into a string[]
        # and array-splatting that array into scoop-<command>.ps1. Array splatting does
        # not reinterpret '-Hook' as a named parameter, so the replay runner must use
        # positional binding for Hook and Apps.
        $scoopSource = [System.IO.File]::ReadAllText(
            (Join-Path (Join-Path $root 'src') '40-Scoop.ps1')
        )
        Assert-CapsulenvTest `
            -Condition $scoopSource.Contains('$arguments = @($temporaryCommand.Command, $Hook) + @($Apps)') `
            -Message 'Scoop lifecycle replay must pass Hook positionally through the custom-command dispatcher.'
        $legacyNamedHookCall = @'
        @($temporaryCommand.Command, '-Hook', $Hook)
'@
        Assert-CapsulenvTest `
            -Condition (-not $scoopSource.Contains($legacyNamedHookCall.Trim())) `
            -Message 'Scoop custom-command array splatting cannot forward -Hook as a named parameter.'

        $dispatchError = $null
        try {
            [string[]]$scoopStyleArguments = @('post_install', 'firefox')
            & $replayPath @scoopStyleArguments
        } catch {
            $dispatchError = $_.Exception.Message
        }
        Assert-CapsulenvTest `
            -Condition ($null -ne $dispatchError -and $dispatchError.Contains('Required Scoop library was not found')) `
            -Message "Lifecycle replay positional binding did not survive Scoop-style array splatting: $dispatchError"

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

        $distributionRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("capsulenv-distribution-test-{0}" -f [Guid]::NewGuid().ToString('N'))
        try {
            $runtimeRoot = Join-Path $distributionRoot 'runtime'
            $runtime = & (Join-Path (Join-Path $root 'scripts') 'Build-Capsulenv.ps1') -OutputPath $runtimeRoot
            Assert-CapsulenvTest `
                -Condition (Test-Path -LiteralPath $runtime.ModulePath -PathType Leaf) `
                -Message 'Runtime build did not include the prebuilt module manifest.'
            Assert-CapsulenvTest `
                -Condition (Test-Path -LiteralPath (Join-Path $runtimeRoot 'modules\Capsulenv\Capsulenv.psm1') -PathType Leaf) `
                -Message 'Runtime build did not include the merged PowerShell module.'
            Assert-CapsulenvTest `
                -Condition (-not (Test-Path -LiteralPath (Join-Path $runtimeRoot 'src'))) `
                -Message 'Minimal runtime unexpectedly included development source.'
            Assert-CapsulenvTest `
                -Condition (-not (Test-Path -LiteralPath (Join-Path $runtimeRoot 'Merge-ModuleScripts.ps1'))) `
                -Message 'Minimal runtime unexpectedly included the module compiler.'

            $builderSource = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'scripts') 'Build-Capsulenv.ps1'))
            Assert-CapsulenvTest `
                -Condition $builderSource.Contains('Source-local build output must remain under the dist directory') `
                -Message 'Runtime builder does not protect source directories from destructive output paths.'

            & (Join-Path $runtimeRoot 'scripts\Invoke-Capsulenv.ps1') help

            $installRoot = Join-Path $distributionRoot 'installed'
            $installed = & (Join-Path (Join-Path $root 'scripts') 'Install-Capsulenv.ps1') -Destination $installRoot
            Assert-CapsulenvTest `
                -Condition (Test-Path -LiteralPath $installed.Launcher -PathType Leaf) `
                -Message 'Installer did not deploy the batch launcher.'
            Assert-CapsulenvTest `
                -Condition (Test-Path -LiteralPath (Join-Path $installRoot 'modules\Capsulenv\Capsulenv.psd1') -PathType Leaf) `
                -Message 'Installer did not deploy the prebuilt module.'
            foreach ($mutableDirectory in @('scoop', 'scoop-global', 'cache', 'tool-data', 'project-cache', 'workspace', '.capsulenv')) {
                Assert-CapsulenvTest `
                    -Condition (Test-Path -LiteralPath (Join-Path $installRoot $mutableDirectory) -PathType Container) `
                    -Message "Installer did not create mutable directory: $mutableDirectory"
            }
            $sentinel = Join-Path (Join-Path $installRoot 'workspace') 'keep.txt'
            'preserve' | Set-Content -LiteralPath $sentinel -Encoding UTF8
            & (Join-Path (Join-Path $root 'scripts') 'Install-Capsulenv.ps1') -Destination $installRoot | Out-Null
            Assert-CapsulenvTest `
                -Condition ((Get-Content -LiteralPath $sentinel -Raw).Trim() -eq 'preserve') `
                -Message 'Installer update changed mutable workspace data.'

            $installerSource = [System.IO.File]::ReadAllText((Join-Path (Join-Path $root 'scripts') 'Install-Capsulenv.ps1'))
            foreach ($requiredInstallerBehavior in @(
                'rollbackRecords',
                'Copy-CapsulenvInstallFile',
                '.capsulenv-install.json',
                'ManagedFiles',
                'Install destination must not be inside the source repository',
                "[ValidateSet('ShellOnly', 'User')]",
                '[switch]$SkipScoopBootstrap',
                'Initialize-CapsulenvScoopBootstrap',
                'Ensure-CapsulenvScoopPortableConfig',
                'InstallMode = $effectiveMode'
            )) {
                Assert-CapsulenvTest `
                    -Condition $installerSource.Contains($requiredInstallerBehavior) `
                    -Message "Installer is missing transactional/ownership behavior: $requiredInstallerBehavior"
            }
        } finally {
            if (Test-Path -LiteralPath $distributionRoot) {
                Remove-Item -LiteralPath $distributionRoot -Recurse -Force
            }
        }

        Invoke-Capsulenv help
        Write-Host 'capsulenv static Pester checks passed.' -ForegroundColor Green
    }
}
