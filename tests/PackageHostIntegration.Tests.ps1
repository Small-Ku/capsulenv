Describe 'Capsulenv User package Start Menu integration' {
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

    It 'writes package shortcuts to a host-local bridge instead of the removable capsule launcher' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-package-host-integration-' + [Guid]::NewGuid().ToString('N'))
        $capsuleRoot = Join-Path $temporaryRoot 'capsule'
        $hostRoot = Join-Path $temporaryRoot 'host-state'
        $startMenuRoot = Join-Path $temporaryRoot 'start-menu'
        $hostPowerShell = Join-Path $hostRoot 'WindowsPowerShell/powershell.exe'
        $packageBridge = Join-Path $hostRoot 'capsulenv-package-bridge.ps1'
        [void](New-Item -ItemType Directory -Path $capsuleRoot -Force)
        $script:PackageShortcutShell = [pscustomobject]@{ LastShortcut = $null }
        $script:PackageShortcutShell | Add-Member -MemberType ScriptMethod -Name CreateShortcut -Value {
            param([string]$Path)
            $shortcut = [pscustomobject]@{
                Path = $Path
                TargetPath = $null
                Arguments = $null
                WorkingDirectory = $null
                Description = $null
                IconLocation = $null
                Saved = $false
            }
            $shortcut | Add-Member -MemberType ScriptMethod -Name Save -Value {
                $this.Saved = $true
            }
            $this.LastShortcut = $shortcut
            return $shortcut
        }
        $global:CapsulenvPackageShortcutShell = $script:PackageShortcutShell

        Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
        Mock Get-CapsulenvUserStartMenuShortcutRoot { $startMenuRoot } -ModuleName Capsulenv
        Mock Get-CapsulenvContext { [pscustomobject]@{ Root = $capsuleRoot } } -ModuleName Capsulenv
        Mock Get-CapsulenvIdentity { '11111111-2222-3333-4444-555555555555' } -ModuleName Capsulenv
        Mock Get-CapsulenvInstalledPackageStates {
            @([pscustomobject]@{ Name = 'demo' })
        } -ModuleName Capsulenv
        Mock Get-CapsulenvScoopAppShortcuts {
            @([pscustomobject]@{
                Name = 'Demo'
                Target = (Join-Path $capsuleRoot 'packages/demo/demo.exe')
                Icon = (Join-Path $capsuleRoot 'packages/demo/demo.ico')
            })
        } -ModuleName Capsulenv
        Mock New-CapsulenvUserIntegrationPackageBridge { $packageBridge } -ModuleName Capsulenv
        Mock Get-CapsulenvPersistentHostPowerShellExecutable { $hostPowerShell } -ModuleName Capsulenv
        Mock New-CapsulenvStartMenuShortcutShell { $global:CapsulenvPackageShortcutShell } -ModuleName Capsulenv

        & $script:Module {
            Sync-CapsulenvPackageStartMenuShortcuts -IntegrationMode User
        }

        $shortcut = $script:PackageShortcutShell.LastShortcut
        $shortcut.Saved | Should -BeTrue
        $shortcut.TargetPath | Should -Be $hostPowerShell
        $shortcut.TargetPath | Should -Not -BeLike '*capsulenv.cmd'
        $shortcut.TargetPath | Should -Not -BeLike ($capsuleRoot + '*')
        $shortcut.WorkingDirectory | Should -Be (Split-Path -Parent $packageBridge)
        $shortcut.WorkingDirectory | Should -Not -Be $capsuleRoot
        $shortcut.Arguments | Should -Match ([regex]::Escape('-File "' + $packageBridge + '"'))
        $shortcut.Arguments | Should -Match ([regex]::Escape('-CapsuleId "11111111-2222-3333-4444-555555555555"'))
        $shortcut.Arguments | Should -Match ([regex]::Escape('-Package "capsule/demo"'))
        $shortcut.Arguments | Should -Match ([regex]::Escape('-Shortcut "Demo"'))
        $shortcut.Arguments | Should -Not -Match 'capsulenv\.cmd'
        $shortcut.IconLocation | Should -Be ($hostPowerShell + ',0')
        Should -Invoke New-CapsulenvUserIntegrationPackageBridge -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            $CapsuleId -eq '11111111-2222-3333-4444-555555555555'
        }
        Remove-Variable CapsulenvPackageShortcutShell -Scope Global -ErrorAction SilentlyContinue
    }
}
