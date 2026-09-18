Describe 'Capsulenv program requirement and provider resolution' {
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

    It 'prefers trusted host Scoop over local, provider, and arbitrary PATH candidates' {
        $hostPath = Join-Path $TestDrive 'host.exe'
        $localPath = Join-Path $TestDrive 'local.exe'
        $providerPath = Join-Path $TestDrive 'provider.exe'
        $pathPath = Join-Path $TestDrive 'path.exe'
        foreach ($path in @($hostPath, $localPath, $providerPath, $pathPath)) {
            New-Item -ItemType File -Path $path -Force | Out-Null
        }

        $result = & $script:Module {
            param($HostPath, $LocalPath, $ProviderPath, $PathPath)
            $requirement = New-CapsulenvProgramRequirement -Name demo
            $candidates = @(
                (New-CapsulenvProgramCandidate -Name demo -Executable $LocalPath -Provider capsulenv-local -Version 99.0.0),
                (New-CapsulenvProgramCandidate -Name demo -Executable $HostPath -Provider host-scoop -Version 1.0.0),
                (New-CapsulenvProgramCandidate -Name demo -Executable $ProviderPath -Provider provider -Version 100.0.0),
                [pscustomobject]@{
                    Name = 'demo'
                    Executable = $PathPath
                    Provider = 'path'
                    Version = '200.0.0'
                    Capabilities = @()
                    Trusted = $true
                }
            )
            Resolve-CapsulenvProgram -Requirement $requirement -Candidates $candidates
        } $hostPath $localPath $providerPath $pathPath

        $result.Succeeded | Should -BeTrue
        $result.Selected.Provider | Should -Be 'host-scoop'
        $result.Selected.Executable | Should -Be ([System.IO.Path]::GetFullPath($hostPath))
        ($result.Candidates | Where-Object { $_.Candidate.Provider -eq 'path' }).Compatible | Should -BeFalse
    }

    It 'rejects a candidate above the requirement maximum with a diagnostic reason' {
        $executable = Join-Path $TestDrive 'too-new.exe'
        New-Item -ItemType File -Path $executable -Force | Out-Null
        $result = & $script:Module {
            param($Executable)
            $requirement = New-CapsulenvProgramRequirement -Name demo -MaximumVersion 2.0.0
            $candidate = New-CapsulenvProgramCandidate -Name demo -Executable $Executable -Provider host-scoop -Version 3.0.0
            Resolve-CapsulenvProgram -Requirement $requirement -Candidates @($candidate)
        } $executable

        $result.Succeeded | Should -BeFalse
        $result.Candidates[0].Reasons | Should -Contain 'above-maximum-version'
    }

    It 'accepts an exact trusted capability match' {
        $executable = Join-Path $TestDrive 'capable.exe'
        New-Item -ItemType File -Path $executable -Force | Out-Null
        $result = & $script:Module {
            param($Executable)
            $requirement = New-CapsulenvProgramRequirement -Name demo -ExactVersion 2.4.0 -RequiredCapabilities @('interactive', 'ssh-agent')
            $candidate = New-CapsulenvProgramCandidate -Name demo -Executable $Executable -Provider host-scoop -Version 2.4.0 -Capabilities @('ssh-agent', 'interactive')
            Test-CapsulenvProgramCandidate -Requirement $requirement -Candidate $candidate
        } $executable

        $result.Compatible | Should -BeTrue
        $result.Reasons.Count | Should -Be 0
    }

    It 'does not collapse prerelease or invalid versions into an exact match' {
        $executable = Join-Path $TestDrive 'version.exe'
        New-Item -ItemType File -Path $executable -Force | Out-Null
        $result = & $script:Module {
            param($Executable)
            $requirement = New-CapsulenvProgramRequirement -Name demo -ExactVersion 1.2.3
            $prerelease = New-CapsulenvProgramCandidate -Name demo -Executable $Executable -Provider host-scoop -Version '1.2.3-beta'
            $invalid = New-CapsulenvProgramCandidate -Name demo -Executable $Executable -Provider seed -Version 'not-a-version'
            [pscustomobject]@{
                Prerelease = Test-CapsulenvProgramCandidate -Requirement $requirement -Candidate $prerelease
                Invalid = Test-CapsulenvProgramCandidate -Requirement $requirement -Candidate $invalid
            }
        } $executable

        $result.Prerelease.Compatible | Should -BeFalse
        $result.Prerelease.Reasons | Should -Contain 'version-not-exact'
        $result.Invalid.Compatible | Should -BeFalse
        $result.Invalid.Reasons | Should -Contain 'version-invalid'
    }

    It 'does not expose legacy portable capsule apps as host-local candidates' {
        Mock Get-CapsulenvInstalledApp { $null } -ModuleName Capsulenv
        $result = & $script:Module {
            $requirement = New-CapsulenvProgramRequirement -Name demo
            Get-CapsulenvProgramCandidates -Requirement $requirement
        }

        @($result).Count | Should -Be 0
        Should -Invoke Get-CapsulenvInstalledApp -ModuleName Capsulenv -Times 2 -Exactly
    }
}
