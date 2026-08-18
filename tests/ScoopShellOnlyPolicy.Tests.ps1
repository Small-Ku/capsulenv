Describe 'Capsulenv ShellOnly Scoop lifecycle policy' {
    BeforeEach {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:PolicyPath = Join-Path $script:Root 'module-runtime/scoop-capsulenv-shellonly-policy.ps1'
        $script:OriginalPolicyEnvironment = $env:CAPSULENV_SCOOP_LIFECYCLE_POLICY
        $env:CAPSULENV_SCOOP_LIFECYCLE_POLICY = $null
        $script:OriginalHookCalled = $false

        function arch_specific {
            param($name, $manifest, $arch)
            $property = $manifest.PSObject.Properties[[string]$name]
            if ($null -ne $property) {
                return $property.Value
            }
        }

        function Split-PathLikeEnvVar {
            param([string[]]$Pattern, [string]$Path)
            if ([string]::IsNullOrEmpty($Path)) {
                return $null, $null
            }
            $patterns = @($Pattern | ForEach-Object { @($_ -split ';') } | Where-Object { $_ })
            $parts = @($Path -split ';' | Where-Object { $_ })
            $matching = @($parts | Where-Object { $patterns -contains $_ })
            $rest = @($parts | Where-Object { $patterns -notcontains $_ })
            return ($matching -join ';'), ($rest -join ';')
        }

        function Invoke-HookScript {
            param(
                [string]$HookType,
                [pscustomobject]$Manifest,
                [string]$ProcessorArchitecture
            )
            $script:OriginalHookCalled = $true
        }

        . $script:PolicyPath
    }

    AfterEach {
        $env:CAPSULENV_SCOOP_LIFECYCLE_POLICY = $script:OriginalPolicyEnvironment
    }

    It 'blocks an unreviewed install hook before Scoop can execute it' {
        $manifest = [pscustomobject]@{
            version = '1.0'
            pre_install = 'Write-Host unsafe'
        }

        { Invoke-HookScript -HookType pre_install -Manifest $manifest -ProcessorArchitecture 64bit } |
            Should -Throw '*ShellOnly blocked unreviewed Scoop lifecycle*pre_install*Fingerprint:*'
        $script:OriginalHookCalled | Should -BeFalse
    }

    It 'blocks an unreviewed external installer even when there is no pre-install hook' {
        $manifest = [pscustomobject]@{
            version = '1.0'
            installer = [pscustomobject]@{
                file = 'setup.exe'
                args = @('/S')
            }
        }

        { Invoke-HookScript -HookType pre_install -Manifest $manifest -ProcessorArchitecture 64bit } |
            Should -Throw '*ShellOnly blocked unreviewed Scoop lifecycle*installer-external*'
    }

    It 'does not make an install depend on unrelated uninstall lifecycle approval' {
        $manifest = [pscustomobject]@{
            version = '1.0'
            uninstaller = [pscustomobject]@{
                script = 'Remove-Item HKCU:\Software\Example -Recurse'
            }
        }

        { Invoke-HookScript -HookType pre_install -Manifest $manifest -ProcessorArchitecture 64bit } |
            Should -Not -Throw
    }


    It 'executes an exact reviewed hook and skips an exact reviewed host cleanup hook' {
        $installScript = 'Set-Content "$dir\portable.txt" ok'
        $installFingerprint = Get-CapsulenvScoopLifecycleFingerprint -Kind pre_install -Value $installScript
        $script:CapsulenvScoopPolicyMap[$installFingerprint] = 'Allow'
        $manifest = [pscustomobject]@{
            version = '1.0'
            pre_install = $installScript
        }

        Invoke-HookScript -HookType pre_install -Manifest $manifest -ProcessorArchitecture 64bit
        $script:OriginalHookCalled | Should -BeTrue

        $script:OriginalHookCalled = $false
        $uninstallScript = 'reg import "$dir\cleanup.reg"'
        $uninstallFingerprint = Get-CapsulenvScoopLifecycleFingerprint -Kind uninstaller -Value $uninstallScript
        $script:CapsulenvScoopPolicyMap[$uninstallFingerprint] = 'Skip'
        $uninstallManifest = [pscustomobject]@{
            version = '1.0'
            uninstaller = [pscustomobject]@{ script = $uninstallScript }
        }

        Invoke-HookScript -HookType pre_uninstall -Manifest $uninstallManifest -ProcessorArchitecture 64bit
        Invoke-HookScript -HookType uninstaller -Manifest $uninstallManifest -ProcessorArchitecture 64bit
        $script:OriginalHookCalled | Should -BeFalse
    }

    It 'does not permit Skip to bypass an actual installer script' {
        $installerScript = 'Start-Process setup.exe -Wait'
        $fingerprint = Get-CapsulenvScoopLifecycleFingerprint -Kind installer -Value $installerScript
        $script:CapsulenvScoopPolicyMap[$fingerprint] = 'Skip'
        $manifest = [pscustomobject]@{
            version = '1.0'
            installer = [pscustomobject]@{ script = $installerScript }
        }

        { Invoke-HookScript -HookType pre_install -Manifest $manifest -ProcessorArchitecture 64bit } |
            Should -Throw '*ShellOnly blocked unreviewed Scoop lifecycle*installer*'
    }

    It 'keeps Scoop environment mutations process-only' {
        $name = 'CAPSULENV_PESTER_SCOOP_ENV'
        $pathName = 'CAPSULENV_PESTER_SCOOP_PATH'
        $oldValue = [Environment]::GetEnvironmentVariable($name, 'Process')
        $oldPathValue = [Environment]::GetEnvironmentVariable($pathName, 'Process')
        try {
            Set-EnvVar -Name $name -Value 'capsule-value'
            [Environment]::GetEnvironmentVariable($name, 'Process') | Should -Be 'capsule-value'

            [Environment]::SetEnvironmentVariable($pathName, 'host-entry', 'Process')
            Add-Path -Path @('capsule-entry') -TargetEnvVar $pathName
            [Environment]::GetEnvironmentVariable($pathName, 'Process') | Should -Be 'capsule-entry;host-entry'
            Remove-Path -Path @('capsule-entry') -TargetEnvVar $pathName
            [Environment]::GetEnvironmentVariable($pathName, 'Process') | Should -Be 'host-entry'
        } finally {
            [Environment]::SetEnvironmentVariable($name, $oldValue, 'Process')
            [Environment]::SetEnvironmentVariable($pathName, $oldPathValue, 'Process')
        }
    }

    It 'suppresses Start Menu creation and removal under ShellOnly' {
        $manifest = [pscustomobject]@{
            shortcuts = @(@('app.exe', 'Example'))
        }
        { create_startmenu_shortcuts $manifest 'capsule-app' $false '64bit' } | Should -Not -Throw
        { rm_startmenu_shortcuts $manifest $false '64bit' } | Should -Not -Throw
    }
}
