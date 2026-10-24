Describe 'Program provider single-file executable aliases' {
    BeforeAll {
        $script:Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force
        $script:Module = @(Get-Module Capsulenv)[-1]
    }
    BeforeEach {
        Mock Initialize-CapsulenvScoopBootstrap { } -ModuleName Capsulenv
        Mock Initialize-CapsulenvPortablePackageWorkerRuntime { } -ModuleName Capsulenv
        Mock Assert-CapsulenvRealizationExecutablePathBudget { } -ModuleName Capsulenv
    }
    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }
    It 'uses a verified portable EXE as the declared bin without running pre_install' {
        $capsule = Join-Path $TestDrive 'capsule'
        $config = Join-Path $capsule 'config'
        [void](New-Item -ItemType Directory -Path $config -Force)
        Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $config 'capsulenv.psd1')
        $bucket = Join-Path $capsule 'scoop/buckets/main/bucket'
        [void](New-Item -ItemType Directory -Path $bucket -Force)
        $downloadFile = Join-Path $TestDrive 'Bitwarden-Portable-2026.10.1.exe'
        [IO.File]::WriteAllText($downloadFile, 'portable executable bytes')
        $hash = (Get-FileHash -LiteralPath $downloadFile -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest = @{
            version = '2026.10.1'
            url = ([Uri]::new([IO.Path]::GetFullPath($downloadFile), [UriKind]::Absolute)).AbsoluteUri
            hash = $hash
            bin = 'Bitwarden.exe'
            pre_install = @(
                'Rename-Item "$dir\Bitwarden-Portable-$version.exe" "Bitwarden.exe"'
                'throw "Scoop lifecycle script must not run here"'
            )
        }
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $bucket 'bitwarden.json') -Encoding UTF8

        $oldRoot = $env:CAPSULENV_HOST_STATE_ROOT
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $TestDrive 'host'
            $candidate = & $script:Module {
                param($Capsule)
                Initialize-CapsulenvContext -Root $Capsule | Out-Null
                $requirement = New-CapsulenvProgramRequirement -Name 'bitwarden'
                @(Get-CapsulenvProgramProviderCandidates -Requirement $requirement)[0]
            } $capsule
            try {
                (Split-Path -Leaf $candidate.Executable) | Should -Be 'Bitwarden.exe'
                (Test-Path -LiteralPath $candidate.Executable -PathType Leaf) | Should -BeTrue
                (Get-FileHash -LiteralPath $candidate.Executable -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $hash
                $candidate.Provider | Should -Be 'provider'
                $candidate.AcquisitionProvider | Should -Be 'provider'
                (Test-Path -LiteralPath (Join-Path $candidate.Root 'Bitwarden-Portable-2026.10.1.exe')) | Should -BeFalse
            } finally {
                if ($candidate -and $candidate.AcquisitionCleanupRoot) {
                    Remove-Item -LiteralPath $candidate.AcquisitionCleanupRoot -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        } finally {
            if ($null -eq $oldRoot) {
                Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_STATE_ROOT = $oldRoot
            }
        }
    }
}