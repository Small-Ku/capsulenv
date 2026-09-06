Describe 'Capsulenv relocation behavioral contracts' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $env:CAPSULENV_ROOT = $script:Root
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = Get-CapsulenvTestModuleBuild -Root $script:Root
        Import-Module $script:Build.ModulePath -Force -DisableNameChecking
        $script:Module = @(Get-Module Capsulenv)[-1]
    }

    AfterAll {
        & $script:Module { param($OriginalRoot) [void](Initialize-CapsulenvContext -Root $OriginalRoot) } $script:Root
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }

    It 'parses the first uv requirement without pinning saved receipt intent' {
        $requirement = & $script:Module {
            $receipt = @'
[tool]
requirements = [{ name = "ruff", url = "https://example.invalid/ruff.whl" }]
python = "C:/Old Capsule/tool-data/uv/python/cpython"
'@
            Get-CapsulenvUvFirstRequirementTable -ReceiptText $receipt
        }
        [string]$requirement.Name | Should -Be 'ruff'
    }

    It 'relocates only path-boundary matches across native slash and JSON forms' {
        $replacement = & $script:Module {
            $context = [pscustomobject]@{
                HasPathChanges = $true
                PathMappings = @([pscustomobject]@{ Name='Root'; OldPath='C:\Old Capsule'; NewPath='D:\New Capsule' })
            }
            $source = 'native=C:\Old Capsule\scoop;slash=C:/Old Capsule/scoop;json="C:\\Old Capsule\\scoop";lookalike=C:\Old Capsule-backup'
            Convert-CapsulenvRelocatedText -Text $source -RelocationContext $context
        }
        $replacement.ReplacementCount | Should -Be 3
        $replacement.Text | Should -Match ([regex]::Escape('D:\New Capsule\scoop'))
        $replacement.Text | Should -Match ([regex]::Escape('D:/New Capsule/scoop'))
        $replacement.Text | Should -Match ([regex]::Escape('D:\\New Capsule\\scoop'))
        $replacement.Text | Should -Match ([regex]::Escape('C:\Old Capsule-backup'))
    }

    It 'patches and restores only top-level Bitwarden settings' {
        $roundTrip = & $script:Module {
            $source = @'
{"vault_payload":"keep-me","nested":{"global_desktopSettings_sshAgentEnabled":false},"text":"\"global_desktopSettings_sshAgentEnabled\": false","user_12345678-1234-1234-1234-123456789abc_example":true}
'@
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
        $roundTrip.Patched | Should -Match 'global_desktopSettings_sshAgentEnabled'
        $roundTrip.Patched | Should -Match 'sshAgentRememberAuthorizations'
        $roundTrip.TopLevelEnabledExists | Should -BeFalse
        $roundTrip.TopLevelPromptExists | Should -BeFalse
        $roundTrip.Restored | Should -Match ([regex]::Escape('"vault_payload":"keep-me"'))
        $roundTrip.Restored | Should -Match ([regex]::Escape('"nested":{"global_desktopSettings_sshAgentEnabled":false}'))
    }

    It 'treats local relocation configuration as replacement and persists schema-5 retry state atomically' {
        $tempRoot = Join-Path $TestDrive 'rehydration-state'
        $tempConfigRoot = Join-Path $tempRoot 'config'
        [void](New-Item -ItemType Directory -Path $tempConfigRoot -Force)
        Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination $tempConfigRoot
        '@{ Scoop = @{ RelocationRepairs = @{} } }' | Set-Content -LiteralPath (Join-Path $tempConfigRoot 'capsulenv.local.psd1') -Encoding UTF8

        try {
            $result = & $script:Module {
                param($TemporaryRoot)
                [void](Initialize-CapsulenvContext -Root $TemporaryRoot)
                $replacementConfig = Get-CapsulenvConfiguration -Refresh
                [void](New-Item -ItemType Directory -Path (Join-Path $TemporaryRoot '.capsulenv') -Force)
                '{}' | Set-Content -LiteralPath (Join-Path $TemporaryRoot '.capsulenv/scoop-rehydration.json') -Encoding UTF8
                $missingFingerprintIsStale = Test-CapsulenvScoopRehydrationRequired
                Save-CapsulenvRehydrationState -RelocationContext $null -PersistRepairResult $null
                Save-CapsulenvRehydrationState -RelocationContext $null -PersistRepairResult $null
                $statePath = Get-CapsulenvRehydrationStatePath
                $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
                $fingerprint = Get-CapsulenvRelocationFingerprint
                $caseVariant = [ordered]@{}
                foreach ($name in @('CapsuleId', 'Root', 'ScoopRoot', 'ScoopGlobalRoot', 'ComputerName', 'User')) {
                    $caseVariant[$name] = ([string]$fingerprint[$name]).ToUpperInvariant()
                }
                $markerPaths = Get-CapsulenvScoopRehydrationMarkerPaths -Fingerprint $fingerprint -StatePath $statePath
                $caseVariantMarkerPaths = Get-CapsulenvScoopRehydrationMarkerPaths -Fingerprint $caseVariant -StatePath $statePath
                $readyAfterSave = -not (Test-CapsulenvScoopRehydrationRequired)
                '{broken-json' | Set-Content -LiteralPath $statePath -Encoding UTF8
                $corruptStateDeferredFromSteadyPath = -not (Test-CapsulenvScoopRehydrationRequired)
                $corruptStateDoctor = @(Invoke-CapsulenvDoctorChecks -Ids @('Capsulenv.Doctor.Scoop.ProjectionRepairState')) | Select-Object -First 1
                Save-CapsulenvRehydrationState -RelocationContext $null -PersistRepairResult $null -PendingProjectionRepair $true
                [void](Publish-CapsulenvScoopRehydrationMarker -MarkerPath $markerPaths.Ready)
                $pendingWinsOverReady = Test-CapsulenvScoopRehydrationRequired
                Save-CapsulenvRehydrationState -RelocationContext $null -PersistRepairResult $null
                $successClearsPending = -not (Test-CapsulenvScoopRehydrationRequired)
                Save-CapsulenvRehydrationState -RelocationContext $null -PersistRepairResult $null -PendingProjectionRepair $true
                [pscustomobject]@{
                    RepairCount = $replacementConfig.Scoop.RelocationRepairs.Count
                    MissingFingerprintIsStale = $missingFingerprintIsStale
                    SchemaVersion = [int]$saved.SchemaVersion
                    CaseInsensitiveFingerprintMarker = (
                        [System.StringComparer]::OrdinalIgnoreCase.Equals($markerPaths.Ready, $caseVariantMarkerPaths.Ready) -and
                        [System.StringComparer]::OrdinalIgnoreCase.Equals($markerPaths.Pending, $caseVariantMarkerPaths.Pending)
                    )
                    ReadyAfterSave = $readyAfterSave
                    CorruptStateDeferredFromSteadyPath = $corruptStateDeferredFromSteadyPath
                    CorruptStateDoctorStatus = [string]$corruptStateDoctor.Status
                    PendingWinsOverReady = $pendingWinsOverReady
                    SuccessClearsPending = $successClearsPending
                    Pending = Test-CapsulenvScoopRehydrationRequired
                }
            } $tempRoot
            $result.RepairCount | Should -Be 0
            $result.MissingFingerprintIsStale | Should -BeTrue
            $result.SchemaVersion | Should -Be 5
            $result.CaseInsensitiveFingerprintMarker | Should -BeTrue
            $result.ReadyAfterSave | Should -BeTrue
            $result.CorruptStateDeferredFromSteadyPath | Should -BeTrue
            $result.CorruptStateDoctorStatus | Should -Be 'Advisory'
            $result.PendingWinsOverReady | Should -BeTrue
            $result.SuccessClearsPending | Should -BeTrue
            $result.Pending | Should -BeTrue
            @(Get-ChildItem -LiteralPath (Join-Path $tempRoot '.capsulenv') -Filter '.capsulenv-rehydration-*.rollback' -ErrorAction SilentlyContinue).Count | Should -Be 0
        } finally {
            & $script:Module { param($OriginalRoot) [void](Initialize-CapsulenvContext -Root $OriginalRoot) } $script:Root
        }
    }

    It 'repairs only allow-listed persist files transactionally' {
        $repairRoot = Join-Path $TestDrive 'persist-repair'
        $repairConfigRoot = Join-Path $repairRoot 'config'
        $repairPersistRoot = Join-Path $repairRoot 'scoop/persist/test-app'
        [void](New-Item -ItemType Directory -Path $repairConfigRoot -Force)
        [void](New-Item -ItemType Directory -Path $repairPersistRoot -Force)
        Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination $repairConfigRoot
        @'
@{
    Scoop = @{
        RelocationRepairs = @{
            'test-app' = @(@{ Path = 'settings.json'; Format = 'json'; MaxBytes = 1048576 })
        }
    }
}
'@ | Set-Content -LiteralPath (Join-Path $repairConfigRoot 'capsulenv.local.psd1') -Encoding UTF8

        $oldRoot = $repairRoot + '-old'
        $settingsPath = Join-Path $repairPersistRoot 'settings.json'
        $sourceJson = '{"path":"' + ($oldRoot.Replace('\', '\\')) + '\\scoop\\apps","lookalike":"' + ($oldRoot.Replace('\', '\\')) + '-backup"}'
        [System.IO.File]::WriteAllText($settingsPath, $sourceJson, [System.Text.UTF8Encoding]::new($false))
        try {
            $repairResult = & $script:Module {
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
                Invoke-CapsulenvPersistRelocationRepair -RelocationContext (New-CapsulenvRelocationContext -Previous $previous -Current $current)
            } $repairRoot $oldRoot
            $json = [System.IO.File]::ReadAllText($settingsPath)
            $repairResult.FilesChanged | Should -Be 1
            $repairResult.Replacements | Should -Be 1
            $json | Should -Match ([regex]::Escape(($repairRoot.Replace('\', '\\')) + '\\scoop\\apps'))
            $json | Should -Match ([regex]::Escape(($oldRoot.Replace('\', '\\')) + '-backup'))
            { $json | ConvertFrom-Json | Out-Null } | Should -Not -Throw
        } finally {
            & $script:Module { param($OriginalRoot) [void](Initialize-CapsulenvContext -Root $OriginalRoot) } $script:Root
        }
    }

    It 'infers the previous capsule and Scoop roots from stale local shim metadata on Windows' {
        if ($env:OS -ne 'Windows_NT') { return }
        $shimRoot = Join-Path $TestDrive 'shim-inference'
        $oldCapsuleRoot = Join-Path $TestDrive 'old-capsule'
        $configRoot = Join-Path $shimRoot 'config'
        $scoopShimRoot = Join-Path $shimRoot 'scoop/shims'
        [void](New-Item -ItemType Directory -Path $configRoot -Force)
        [void](New-Item -ItemType Directory -Path $scoopShimRoot -Force)
        Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination $configRoot
        $oldScoopRoot = Join-Path $oldCapsuleRoot 'scoop'
        $oldTarget = Join-Path $oldScoopRoot 'apps/pwsh/7.0.0/pwsh.exe'
        ('path = "{0}"' -f $oldTarget) | Set-Content -LiteralPath (Join-Path $scoopShimRoot 'pwsh.shim') -Encoding ASCII
        try {
            $context = & $script:Module {
                param($TemporaryRoot)
                [void](Initialize-CapsulenvContext -Root $TemporaryRoot)
                [void](Get-CapsulenvConfiguration -Refresh)
                Get-CapsulenvRelocationContext
            } $shimRoot
            $context.PreviousSource | Should -Contain 'local-shims'
            @($context.PathMappings | Where-Object Name -eq 'ScoopRoot')[0].OldPath | Should -Be $oldScoopRoot
            @($context.PathMappings | Where-Object Name -eq 'Root')[0].OldPath | Should -Be $oldCapsuleRoot
        } finally {
            & $script:Module { param($OriginalRoot) [void](Initialize-CapsulenvContext -Root $OriginalRoot) } $script:Root
        }
    }
}
