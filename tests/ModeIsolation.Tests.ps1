Describe 'Capsulenv install-mode isolation contracts' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $env:CAPSULENV_ROOT = $script:Root
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force -DisableNameChecking
        $script:Module = @(Get-Module Capsulenv)[-1]
        . (Join-Path $script:Root 'src/05-DataFile.ps1')
    }

    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }

    It 'keeps local, global, and PortableSafe shims inside the capsule session plan' {
        $contract = & $script:Module {
            $plan = Get-CapsulenvEnvironmentPlan
            [pscustomobject]@{
                PathEntries = @($plan.PathEntries)
                Scoop = [string]$plan.Variables['SCOOP']
                ScoopGlobal = [string]$plan.Variables['SCOOP_GLOBAL']
                PackageShims = [string](Get-CapsulenvPackageShimRoot)
            }
        }

        $contract.PathEntries | Should -Contain (Join-Path $contract.Scoop 'shims')
        $contract.PathEntries | Should -Contain (Join-Path $contract.ScoopGlobal 'shims')
        $contract.PathEntries | Should -Contain $contract.PackageShims
    }

    It 'selects invocation mode only through process CAPSULENV_MODE' {
        $oldMode = $env:CAPSULENV_MODE
        try {
            Remove-Item Env:CAPSULENV_MODE -ErrorAction SilentlyContinue
            (& $script:Module { Get-CapsulenvInstallMode }) | Should -Be 'ShellOnly'

            $env:CAPSULENV_MODE = 'User'
            (& $script:Module { Get-CapsulenvInstallMode }) | Should -Be 'User'

            $env:CAPSULENV_MODE = 'invalid'
            (& $script:Module { Get-CapsulenvInstallMode }) | Should -Be 'ShellOnly'
        } finally {
            if ($null -eq $oldMode) {
                Remove-Item Env:CAPSULENV_MODE -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_MODE = $oldMode
            }
        }
    }

    It 'does not enter persistent package host integration in ShellOnly mode' {
        Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
        Mock Get-CapsulenvUserStartMenuShortcutRoot { throw 'host UI must not be inspected in ShellOnly' } -ModuleName Capsulenv

        Sync-CapsulenvPackageStartMenuShortcuts -IntegrationMode ShellOnly

        Should -Invoke Get-CapsulenvUserStartMenuShortcutRoot -ModuleName Capsulenv -Times 0 -Exactly
    }

    It 'uses the process-only Git OpenSSH overlay in ShellOnly mode' {
        Mock Get-CapsulenvInstallMode { 'ShellOnly' } -ModuleName Capsulenv
        Mock Get-CapsulenvGitOpenSshPaths { [pscustomobject]@{ Ssh = 'ssh.exe'; SshKeygen = 'ssh-keygen.exe' } } -ModuleName Capsulenv
        Mock Enable-CapsulenvGitOpenSshSession {} -ModuleName Capsulenv
        Mock Get-CapsulenvGitCommand { throw 'persistent git config must not be resolved in ShellOnly' } -ModuleName Capsulenv
        Mock Write-CapsulenvMessage {} -ModuleName Capsulenv

        Set-CapsulenvGitOpenSsh

        Should -Invoke Enable-CapsulenvGitOpenSshSession -ModuleName Capsulenv -Times 1 -Exactly
        Should -Invoke Get-CapsulenvGitCommand -ModuleName Capsulenv -Times 0 -Exactly
    }

    It 'refuses Windows ssh-agent service mutation before inspecting the service in ShellOnly mode' {
        Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
        Mock Get-CapsulenvInstallMode { 'ShellOnly' } -ModuleName Capsulenv
        { Disable-CapsulenvWindowsSshAgent -Confirm:$false } | Should -Throw '*ShellOnly mode cannot change the Windows ssh-agent service*'
    }

    It 'keeps browser profiles capsule-owned and requests no-remote isolation in ShellOnly' {
        $config = Import-CapsulenvPowerShellDataFile -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1')
        $config.UserIntegration.DefaultBrowser | Should -Be ''
        foreach ($browser in @('Firefox', 'Zen', 'LibreWolf')) {
            [string]$config.Browsers[$browser].App | Should -Not -BeNullOrEmpty
            [string]$config.Browsers[$browser].ProfilePath | Should -Not -BeNullOrEmpty
            [string]$config.Browsers[$browser].ProfileArgument | Should -Be '-profile'
            @($config.Browsers[$browser].ShellOnlyArguments) | Should -Contain '-no-remote'
        }
        [string]$config.Browsers.LibreWolf.ProfilePath | Should -Be 'Profiles\Default'
    }

    It 'records cryptographic file ownership evidence for project-cache repair' {
        $path = Join-Path $TestDrive 'owned-cache-file.bin'
        [System.IO.File]::WriteAllText($path, 'capsulenv-mode-isolation')

        $fingerprint = & $script:Module { param($Path) Get-CapsulenvProjectCacheFileFingerprint -Path $Path } $path
        $fingerprint.Length | Should -BeGreaterThan 0
        $fingerprint.Sha256 | Should -Match '^[0-9a-f]{64}$'
        (& $script:Module { param($Path, $Fingerprint) Test-CapsulenvProjectCacheFileFingerprint -Path $Path -Fingerprint $Fingerprint } $path $fingerprint) |
            Should -BeTrue

        Add-Content -LiteralPath $path -Value 'diverged'
        (& $script:Module { param($Path, $Fingerprint) Test-CapsulenvProjectCacheFileFingerprint -Path $Path -Fingerprint $Fingerprint } $path $fingerprint) |
            Should -BeFalse
    }
}
