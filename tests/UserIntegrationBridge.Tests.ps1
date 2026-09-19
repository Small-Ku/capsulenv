Describe 'Capsulenv host-local UserIntegration bridge' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force
        $script:Module = @(Get-Module Capsulenv)[-1]
    }

    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }

    It 'refuses persistent integration on an unknown ephemeral host' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-user-ephemeral-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $result = & $script:Module {
                    param($CapsuleRoot)
                    Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                    New-CapsulenvUserIntegrationBridge -CapsuleId (Get-CapsulenvIdentity) -BrowserApp firefox
            } (Join-Path $temporaryRoot 'capsule') | Out-Null
        } catch {
                $errorRecord = $_
            }
        finally {
            if ($null -eq $oldStateRoot) {
                Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_STATE_ROOT = $oldStateRoot
            }
        }
        $errorRecord.Exception.Message | Should -Match 'explicit host enrollment'
    }

    It 'fails closed when persistent default-browser registration has no valid bridge' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-user-default-browser-no-bridge-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $message = & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                try { Resolve-CapsulenvRequiredDefaultBrowserBridge -App firefox | Out-Null } catch { $_.Exception.Message }
            } (Join-Path $temporaryRoot 'capsule')
            $message | Should -Match 'valid host-local UserIntegration bridge'
        } finally {
            if ($null -eq $oldStateRoot) { Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:CAPSULENV_HOST_STATE_ROOT = $oldStateRoot }
        }
    }
    It 'creates a host-local bridge without embedding removable executable or profile paths' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-user-persistent-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $result = & $script:Module {
                param($CapsuleRoot, $PlacementRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                [void](Set-CapsulenvHostEnrollment -EnrollmentTag home -Retention persistent -PlacementRoot $PlacementRoot)
                $capsuleId = Get-CapsulenvIdentity
                $binding = [pscustomobject]@{
                    Program = [pscustomobject]@{ Name = 'firefox'; Executable = 'E:\removable\firefox.exe' }
                    ProfilePath = 'E:\removable\profile'
                }
                $bridge = New-CapsulenvUserIntegrationBridge -CapsuleId $capsuleId -BrowserApp firefox -BrowserBinding $binding
                $scriptText = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $bridge.BridgePath) 'capsulenv-bridge.ps1') -Raw
                [pscustomobject]@{
                    Bridge = $bridge
                    ScriptText = $scriptText
                    Manifest = Get-CapsulenvUserIntegrationBridge -CapsuleId $capsuleId
                    BridgeRoot = Split-Path -Parent $bridge.BridgePath
                    CapsuleRoot = $CapsuleRoot
                }
            } (Join-Path $temporaryRoot 'capsule') (Join-Path $temporaryRoot 'nvme')

            $result.Bridge.Persistent | Should -BeTrue
            $result.Bridge.BridgePath | Should -BeLike "$temporaryRoot/host-state*"
            $result.ScriptText | Should -Not -Match 'E:\\removable'
            $result.ScriptText | Should -Not -Match 'CAPSULENV_ROOT'
            $result.ScriptText | Should -Match 'CapsuleRoots'
            $result.Manifest.BrowserStateIdentity | Should -Be 'firefox'
            $result.Manifest.CapsuleRoots | Should -Contain $result.CapsuleRoot
            $result.BridgeRoot | Should -Not -Be $result.CapsuleRoot
        } finally {
            if ($null -eq $oldStateRoot) {
                Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_STATE_ROOT = $oldStateRoot
            }
        }
    }

    It 'discovers the registered capsule without session environment and reports deterministic absence' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-user-absent-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $result = & $script:Module {
                    param($CapsuleRoot, $PlacementRoot)
                    Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                    [void](Set-CapsulenvHostEnrollment -EnrollmentTag home -Retention persistent -PlacementRoot $PlacementRoot)
                    $capsuleId = Get-CapsulenvIdentity
                    Set-Content -LiteralPath (Join-Path $CapsuleRoot 'capsulenv.cmd') -Value '@echo off' -Encoding UTF8
                    [void](New-CapsulenvUserIntegrationBridge -CapsuleId $capsuleId -BrowserApp firefox)
                    Remove-Item Env:CAPSULENV_ROOT -ErrorAction SilentlyContinue
                    $present = Invoke-CapsulenvUserIntegrationBridge -CapsuleId $capsuleId
                [pscustomobject]@{ Present = $present; CapsuleId = $capsuleId }
            } (Join-Path $temporaryRoot 'capsule') (Join-Path $temporaryRoot 'nvme')
            $result.Present.Ready | Should -BeTrue
            $result.Present.CapsuleRoot | Should -BeLike '*capsule*'
            $absent = & $script:Module {
                param($CapsuleRoot, $CapsuleId)
                Remove-Item -LiteralPath $CapsuleRoot -Recurse -Force
                try { Invoke-CapsulenvUserIntegrationBridge -CapsuleId $CapsuleId | Out-Null } catch { $_.Exception.Message }
            } (Join-Path $temporaryRoot 'capsule') $result.CapsuleId
            $absent | Should -Match 'absent'
            $absent | Should -Match 'not guess'
        } finally {
            if ($null -eq $oldStateRoot) {
                Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_STATE_ROOT = $oldStateRoot
            }
        }
    }

    It 'installs a host-local handler command without a removable target' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-user-handler-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $result = & $script:Module {
                param($CapsuleRoot, $PlacementRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                [void](Set-CapsulenvHostEnrollment -EnrollmentTag home -Retention persistent -PlacementRoot $PlacementRoot)
                $capsuleId = Get-CapsulenvIdentity
                Install-CapsulenvUserIntegration -CapsuleId $capsuleId -BrowserApp firefox
            } (Join-Path $temporaryRoot 'capsule') (Join-Path $temporaryRoot 'nvme')
            $result.Handler.Command | Should -Match 'NoProfile'
            $result.Handler.Command | Should -Not -Match 'capsulenv browser'
            $result.Handler.Command | Should -Not -Match 'removable'
        } finally {
            if ($null -eq $oldStateRoot) { Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:CAPSULENV_HOST_STATE_ROOT = $oldStateRoot }
        }
    }

    It 'does not remove the bridge when default-browser restoration fails' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-user-restore-failure-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $result = & $script:Module {
                param($CapsuleRoot, $PlacementRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                [void](Set-CapsulenvHostEnrollment -EnrollmentTag home -Retention persistent -PlacementRoot $PlacementRoot)
                $capsuleId = Get-CapsulenvIdentity
                [void](New-CapsulenvUserIntegrationBridge -CapsuleId $capsuleId -BrowserApp firefox)
                Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
                Mock Restore-CapsulenvDefaultBrowserRegistration { throw 'still the default browser' } -ModuleName Capsulenv
                $threw = $false
                try { Remove-CapsulenvUserIntegrationBridge -CapsuleId $capsuleId | Out-Null } catch { $threw = $true }
                [pscustomobject]@{
                    Threw = $threw
                    RootExists = Test-Path -LiteralPath (Get-CapsulenvUserIntegrationBridgeRoot -CapsuleId $capsuleId) -PathType Container
                }
            } (Join-Path $temporaryRoot 'capsule') (Join-Path $temporaryRoot 'nvme')
            $result.Threw | Should -BeTrue
            $result.RootExists | Should -BeTrue
        } finally {
            if ($null -eq $oldStateRoot) { Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:CAPSULENV_HOST_STATE_ROOT = $oldStateRoot }
        }
    }
}

