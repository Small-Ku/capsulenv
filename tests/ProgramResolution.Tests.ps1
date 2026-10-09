Describe 'Capsulenv program requirement and provider resolution' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force
        $script:Module = @(Get-Module Capsulenv)[-1]
    }

    BeforeEach {
        # Tests supply host evidence explicitly; never discover the developer's Scoop.
        Mock Find-CapsulenvHostScoop { $null } -ModuleName Capsulenv
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
        Mock Find-CapsulenvHostScoop { $null } -ModuleName Capsulenv
        Mock Get-CapsulenvInstalledApp { throw 'portable Scoop resolver must not supply host candidates' } -ModuleName Capsulenv
        Mock Get-CapsulenvLocalRealizationCandidates { @() } -ModuleName Capsulenv

        $result = & $script:Module {
            $requirement = New-CapsulenvProgramRequirement -Name demo
            Get-CapsulenvProgramCandidates -Requirement $requirement
        }

        @($result).Count | Should -Be 0
        Should -Invoke Get-CapsulenvInstalledApp -ModuleName Capsulenv -Times 0 -Exactly
    }

    It 'resolves a trusted host Scoop app from the discovered foreign root' {
        $hostRoot = Join-Path $TestDrive 'foreign-scoop'
        $current = Join-Path $hostRoot 'apps/pwsh/current'
        New-Item -ItemType Directory -Path $current -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $current 'manifest.json') -Value '{"version":"7.6.5","bin":"pwsh.exe"}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $current 'install.json') -Value '{"bucket":"main","architecture":"64bit"}' -Encoding utf8
        New-Item -ItemType File -Path (Join-Path $current 'pwsh.exe') -Force | Out-Null

        $script:ForeignHostScoopRoot = $hostRoot
        Mock Find-CapsulenvHostScoop {
            [pscustomobject]@{
                Root = $script:ForeignHostScoopRoot
                GlobalRoot = (Join-Path $script:ForeignHostScoopRoot 'global')
                Command = (Join-Path $script:ForeignHostScoopRoot 'shims/scoop.ps1')
            }
        } -ModuleName Capsulenv
        Mock Get-CapsulenvInstalledApp { throw 'capsule Scoop resolver must not be used for host discovery' } -ModuleName Capsulenv
        Mock Get-CapsulenvLocalRealizationCandidates { @() } -ModuleName Capsulenv

        $result = & $script:Module {
            $requirement = New-CapsulenvProgramRequirement -Name pwsh -RequiredCapabilities @('interactive')
            $candidates = @(Get-CapsulenvProgramCandidates -Requirement $requirement)
            [pscustomobject]@{
                Candidates = $candidates
                Resolution = Resolve-CapsulenvProgram -Requirement $requirement -Candidates $candidates
            }
        }

        $result.Candidates.Count | Should -Be 1
        $candidate = $result.Candidates[0]
        $candidate.Provider | Should -Be 'host-scoop'
        $candidate.Scope | Should -Be 'user'
        $candidate.Version | Should -Be '7.6.5'
        $candidate.Executable | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $current 'pwsh.exe')))
        $candidate.Root | Should -Be ([System.IO.Path]::GetFullPath($current))
        $candidate.Trusted | Should -BeTrue
        $candidate.OwnsLifecycle | Should -BeFalse
        $candidate.Provenance | Should -Be 'scoop:user/pwsh'
        $result.Resolution.Succeeded | Should -BeTrue
        $result.Resolution.Selected.Provider | Should -Be 'host-scoop'
        Should -Invoke Get-CapsulenvInstalledApp -ModuleName Capsulenv -Times 0 -Exactly
    }

    It 'rejects unusable host metadata: <Case>' -ForEach @(
        @{ Case = 'missing manifest'; Manifest = $null; Install = '{}'; Bin = 'pwsh.exe'; ExpectedCount = 0 },
        @{ Case = 'missing install'; Manifest = '{"version":"7.6.5","bin":"pwsh.exe"}'; Install = $null; Bin = 'pwsh.exe'; ExpectedCount = 0 },
        @{ Case = 'malformed manifest'; Manifest = '{'; Install = '{}'; Bin = 'pwsh.exe'; ExpectedCount = 0 },
        @{ Case = 'malformed install'; Manifest = '{"version":"7.6.5","bin":"pwsh.exe"}'; Install = '{'; Bin = 'pwsh.exe'; ExpectedCount = 0 },
        @{ Case = 'missing version'; Manifest = '{"bin":"pwsh.exe"}'; Install = '{}'; Bin = 'pwsh.exe'; ExpectedCount = 0 },
        @{ Case = 'nonscalar version'; Manifest = '{"version":["7.6.5"],"bin":"pwsh.exe"}'; Install = '{}'; Bin = 'pwsh.exe'; ExpectedCount = 0 },
        @{ Case = 'nonobject install'; Manifest = '{"version":"7.6.5","bin":"pwsh.exe"}'; Install = '[]'; Bin = 'pwsh.exe'; ExpectedCount = 0 },
        @{ Case = 'singleton manifest array'; Manifest = '[{"version":"7.6.5","bin":"pwsh.exe"}]'; Install = '{}'; Bin = 'pwsh.exe'; ExpectedCount = 0 },
        @{ Case = 'singleton install array'; Manifest = '{"version":"7.6.5","bin":"pwsh.exe"}'; Install = '[{}]'; Bin = 'pwsh.exe'; ExpectedCount = 0 },
        @{ Case = 'missing executable'; Manifest = '{"version":"7.6.5","bin":"missing.exe"}'; Install = '{}'; Bin = 'pwsh.exe'; ExpectedCount = 0 },
        @{ Case = 'relative traversal'; Manifest = '{"version":"7.6.5","bin":"../outside.exe"}'; Install = '{}'; Bin = 'pwsh.exe'; ExpectedCount = 0 },
        @{ Case = 'rooted outside executable'; Manifest = 'outside'; Install = '{}'; Bin = 'pwsh.exe'; ExpectedCount = 1 }
    ) {
        $hostRoot = Join-Path $TestDrive ('metadata-host-' + [Guid]::NewGuid().ToString('N'))
        $current = Join-Path $hostRoot 'apps/pwsh/current'
        New-Item -ItemType Directory -Path $current -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $current $Bin) -Force | Out-Null
        $outside = Join-Path $hostRoot 'apps/pwsh/outside.exe'
        New-Item -ItemType File -Path $outside -Force | Out-Null
        if ($Manifest -eq 'outside') {
            $Manifest = @{ version = '7.6.5'; bin = $outside } | ConvertTo-Json -Compress
        }
        if ($null -ne $Manifest) { Set-Content -LiteralPath (Join-Path $current 'manifest.json') -Value $Manifest -Encoding utf8 }
        if ($null -ne $Install) { Set-Content -LiteralPath (Join-Path $current 'install.json') -Value $Install -Encoding utf8 }
        $script:MetadataHostRoot = $hostRoot
        Mock Find-CapsulenvHostScoop {
            [pscustomobject]@{ Root = $script:MetadataHostRoot; GlobalRoot = $null }
        } -ModuleName Capsulenv
        Mock Get-CapsulenvLocalRealizationCandidates { @() } -ModuleName Capsulenv
        $result = & $script:Module {
            $requirement = New-CapsulenvProgramRequirement -Name pwsh
            $candidates = @(Get-CapsulenvProgramCandidates -Requirement $requirement)
            [pscustomobject]@{ Candidates = $candidates; Resolution = Resolve-CapsulenvProgram -Requirement $requirement -Candidates $candidates }
        }
        $result.Candidates.Count | Should -Be $ExpectedCount
        $result.Resolution.Succeeded | Should -BeFalse
        if ($ExpectedCount -eq 1) {
            $result.Candidates[0].Trusted | Should -BeFalse
            $result.Candidates[0].OwnsLifecycle | Should -BeFalse
            $result.Candidates[0].TrustReason | Should -Match 'outside'
        }
    }

    It 'rejects app names that could escape the standard apps directory' {
        $result = & $script:Module {
            param($HostRoot)
            $hostScoop = [pscustomobject]@{ Root = $HostRoot; GlobalRoot = $null }
            Get-CapsulenvDiscoveredHostScoopApp -HostScoop $hostScoop -Name '../outside' -Scope User
        } $TestDrive
        $result | Should -BeNullOrEmpty
    }

    It 'derives the trusted sing-box proxy capability during host discovery' {
        $executable = Join-Path $TestDrive 'sing-box.exe'
        New-Item -ItemType File -Path $executable -Force | Out-Null
        Mock Find-CapsulenvHostScoop {
            [pscustomobject]@{ Root = $TestDrive; GlobalRoot = (Join-Path $TestDrive 'global'); Command = 'unused' }
        } -ModuleName Capsulenv
        Mock Get-CapsulenvDiscoveredHostScoopApp {
            if ($Scope -ne 'User') { return $null }
            [pscustomobject]@{
                Selector = 'scoop:user/sing-box'
                Current = (Split-Path -Parent $executable)
                Manifest = [pscustomobject]@{ version = '1.0.0' }
            }
        } -ModuleName Capsulenv
        Mock Resolve-CapsulenvDiscoveredHostScoopExecutable { $executable } -ModuleName Capsulenv
        Mock Get-CapsulenvDiscoveredProgramTrustDecision {
            [pscustomobject]@{ Trusted = $true; Policy = 'test'; Reason = 'verified test host' }
        } -ModuleName Capsulenv
        Mock Get-CapsulenvLocalRealizationCandidates { @() } -ModuleName Capsulenv

        $result = & $script:Module {
            $requirement = New-CapsulenvProgramRequirement -Name sing-box -RequiredCapabilities @('proxy')
            $candidates = @(Get-CapsulenvProgramCandidates -Requirement $requirement)
            [pscustomobject]@{
                Candidate = @($candidates | Where-Object Provider -eq 'host-scoop')[0]
                Resolution = Resolve-CapsulenvProgram -Requirement $requirement -Candidates $candidates
            }
        }

        $result.Candidate.Capabilities | Should -Contain 'proxy'
        $result.Resolution.Succeeded | Should -BeTrue
    }
    It 'uses SemVer prerelease precedence for minimum and maximum ranges' {
        $executable = Join-Path $TestDrive 'semver-range.exe'
        New-Item -ItemType File -Path $executable -Force | Out-Null
        $result = & $script:Module {
            param($Executable)
            $minimum = New-CapsulenvProgramRequirement -Name demo -MinimumVersion '1.2.3'
            $maximum = New-CapsulenvProgramRequirement -Name demo -MaximumVersion '1.2.3-beta'
            $candidateBeta = New-CapsulenvProgramCandidate -Name demo -Executable $Executable -Provider host-scoop -Version '1.2.3-beta'
            $candidateStable = New-CapsulenvProgramCandidate -Name demo -Executable $Executable -Provider host-scoop -Version '1.2.3'
            [pscustomobject]@{
                BetaAgainstStableMinimum = Test-CapsulenvProgramCandidate -Requirement $minimum -Candidate $candidateBeta
                StableAgainstBetaMaximum = Test-CapsulenvProgramCandidate -Requirement $maximum -Candidate $candidateStable
                StableVsBeta = Compare-CapsulenvProgramVersionInfo -Left (Get-CapsulenvProgramVersionInfo -Version '1.2.3') -Right (Get-CapsulenvProgramVersionInfo -Version '1.2.3-beta')
            }
        } $executable

        $result.BetaAgainstStableMinimum.Compatible | Should -BeFalse
        $result.BetaAgainstStableMinimum.Reasons | Should -Contain 'below-minimum-version'
        $result.StableAgainstBetaMaximum.Compatible | Should -BeFalse
        $result.StableAgainstBetaMaximum.Reasons | Should -Contain 'above-maximum-version'
        $result.StableVsBeta | Should -BeGreaterThan 0
    }

    It 'normalizes a legacy materialized seed into the host-local authority model' {
        $result = & $script:Module {
            $authority = Get-CapsulenvRealizationAuthority -Manifest ([pscustomobject][ordered]@{
                SchemaVersion = 1
                Provider = 'seed'
                Provenance = 'portable-seed/sing-box'
            })
            $candidate = New-CapsulenvProgramCandidate -Name sing-box -Executable '/tmp/sing-box' -Provider $authority.Provider -AcquisitionProvider $authority.AcquisitionProvider -Scope $authority.Scope -OwnsLifecycle:$authority.OwnsLifecycle -Provenance $authority.Provenance
            [pscustomobject]@{
                Authority = $authority
                Candidate = $candidate
            }
        }

        $result.Authority.Provider | Should -Be 'capsulenv-local'
        $result.Authority.AcquisitionProvider | Should -Be 'seed'
        $result.Authority.Scope | Should -Be 'host-local'
        $result.Authority.OwnsLifecycle | Should -BeTrue
        $result.Candidate.Provider | Should -Be 'capsulenv-local'
        $result.Candidate.AcquisitionProvider | Should -Be 'seed'
        $result.Candidate.OwnsLifecycle | Should -BeTrue
    }

    It 'preserves explicit current authority and acquisition origin independently' {
        $result = & $script:Module {
            Get-CapsulenvRealizationAuthority -Manifest ([pscustomobject][ordered]@{
                SchemaVersion = 2
                Provider = 'capsulenv-local'
                AcquisitionProvider = 'provider'
                Provenance = 'provider/cache'
            })
        }

        $result.Provider | Should -Be 'capsulenv-local'
        $result.AcquisitionProvider | Should -Be 'provider'
        $result.Scope | Should -Be 'host-local'
        $result.OwnsLifecycle | Should -BeTrue
    }

    It 'normalizes a legacy materialized provider into the host-local authority model' {
        $result = & $script:Module {
            Get-CapsulenvRealizationAuthority -Manifest ([pscustomobject][ordered]@{
                SchemaVersion = 1
                Provider = 'provider'
                Provenance = 'provider/cache'
            })
        }

        $result.Provider | Should -Be 'capsulenv-local'
        $result.AcquisitionProvider | Should -Be 'provider'
        $result.Scope | Should -Be 'host-local'
        $result.OwnsLifecycle | Should -BeTrue
    }

}

Describe 'Capsulenv foreign Scoop root discovery' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = Get-CapsulenvTestModuleBuild -Root $script:Root
        Import-Module $script:Build.ModulePath -Force
        $script:Module = @(Get-Module Capsulenv)[-1]
    }

    BeforeEach {
        $script:DiscoveryFixtureRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $script:DiscoveryCapsuleRoot = Join-Path $script:DiscoveryFixtureRoot 'capsule'
        $script:DiscoveryHostRoot = Join-Path $script:DiscoveryFixtureRoot 'host-scoop'
        $script:DiscoveryCommandPath = Join-Path $script:DiscoveryHostRoot 'shims/scoop.ps1'
        & $script:Module { param($Root) Initialize-CapsulenvContext -Root $Root | Out-Null } $script:DiscoveryCapsuleRoot
        Mock Get-CapsulenvScoopRoot { throw 'minimal capsule context has no configured Scoop root' } -ModuleName Capsulenv
        Mock Get-CapsulenvScoopGlobalRoot { throw 'minimal capsule context has no configured global root' } -ModuleName Capsulenv
        Mock Get-Command { Microsoft.PowerShell.Core\Get-Command -Name $Name -ErrorAction SilentlyContinue } -ModuleName Capsulenv
        Mock Get-Command {
            [pscustomobject]@{ Path = $script:DiscoveryCommandPath; Definition = $script:DiscoveryCommandPath }
        } -ModuleName Capsulenv -ParameterFilter { $Name -eq 'scoop' }
        # Hide all host filesystem evidence outside this fixture, including roots
        # supplied by User/Machine environment variables and USERPROFILE.
        Mock Test-Path {
            if ($PathType -eq 'Container') { return [System.IO.Directory]::Exists($LiteralPath) }
            if ($PathType -eq 'Leaf') { return [System.IO.File]::Exists($LiteralPath) }
            return ([System.IO.Directory]::Exists($LiteralPath) -or [System.IO.File]::Exists($LiteralPath))
        } -ModuleName Capsulenv
        Mock Test-Path { $false } -ModuleName Capsulenv -ParameterFilter {
            -not ([System.IO.Path]::GetFullPath([string]$LiteralPath)).StartsWith(
                $script:DiscoveryFixtureRoot + [System.IO.Path]::DirectorySeparatorChar,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        }
    }

    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }

    It 'discovers and resolves foreign user and global apps from <CommandPath> with minimal capsule context' -ForEach @(
        @{ CommandPath = 'shims/scoop.ps1' },
        @{ CommandPath = 'shims/scoop.cmd' },
        @{ CommandPath = 'apps/scoop/current/bin/scoop.ps1' }
    ) {
        $script:DiscoveryCommandPath = Join-Path $script:DiscoveryHostRoot $CommandPath
        $canonical = Join-Path $script:DiscoveryHostRoot 'apps/scoop/current/bin/scoop.ps1'
        New-Item -ItemType Directory -Path (Split-Path -Parent $canonical) -Force | Out-Null
        Set-Content -LiteralPath $canonical -Value "throw 'discovery must not execute Scoop'" -Encoding utf8
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:DiscoveryCommandPath) -Force | Out-Null
        Set-Content -LiteralPath $script:DiscoveryCommandPath -Value "throw 'discovery must not execute the command shim'" -Encoding utf8
        $globalRoot = Join-Path $script:DiscoveryFixtureRoot 'host-global'
        @{ global_path = $globalRoot } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:DiscoveryHostRoot 'config.json') -Encoding utf8
        $pwshCurrent = Join-Path $script:DiscoveryHostRoot 'apps/pwsh/current'
        $browserCurrent = Join-Path $globalRoot 'apps/skykakapo/current'
        foreach ($current in @($pwshCurrent, $browserCurrent)) {
            New-Item -ItemType Directory -Path $current -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $current 'scoop-install.json') -Value '{"bucket":"main","architecture":"64bit"}' -Encoding utf8
        }
        Set-Content -LiteralPath (Join-Path $pwshCurrent 'scoop-manifest.json') -Value '{"version":"7.6.5","architecture":{"64bit":{"bin":[["pwsh.exe","pwsh"]]}}}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $browserCurrent 'manifest.json') -Value '{"version":"156.0.1","shortcuts":[["skykakapo.exe","SkyKakapo"]]}' -Encoding utf8
        New-Item -ItemType File -Path (Join-Path $pwshCurrent 'pwsh.exe') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $browserCurrent 'skykakapo.exe') -Force | Out-Null
        Mock Get-CapsulenvLocalRealizationCandidates { @() } -ModuleName Capsulenv
        Mock Get-CapsulenvInstalledApp { throw 'capsule installed-app resolver must not be used' } -ModuleName Capsulenv

        $result = & $script:Module {
            $hostScoop = Find-CapsulenvHostScoop
            [pscustomobject]@{
                Host = $hostScoop
                Pwsh = Get-CapsulenvProgramResolution -Requirement (New-CapsulenvProgramRequirement -Name pwsh -BinName pwsh -RequiredCapabilities @('interactive'))
                Browser = Get-CapsulenvProgramResolution -Requirement (New-CapsulenvProgramRequirement -Name skykakapo -ShortcutName SkyKakapo)
            }
        }
        $result.Host.Root | Should -Be $script:DiscoveryHostRoot
        $result.Host.GlobalRoot | Should -Be $globalRoot
        $result.Pwsh.Selected.Executable | Should -Be (Join-Path $pwshCurrent 'pwsh.exe')
        $result.Browser.Selected.Executable | Should -Be (Join-Path $browserCurrent 'skykakapo.exe')
        $result.Pwsh.Selected.Provenance | Should -Be 'scoop:user/pwsh'
        $result.Browser.Selected.Provenance | Should -Be 'scoop:global/skykakapo'
        foreach ($resolution in @($result.Pwsh, $result.Browser)) {
            $resolution.Succeeded | Should -BeTrue
            $resolution.Selected.Provider | Should -Be 'host-scoop'
            $resolution.Selected.Trusted | Should -BeTrue
            $resolution.Selected.OwnsLifecycle | Should -BeFalse
        }
        Should -Invoke Get-Command -ModuleName Capsulenv -ParameterFilter {
            $Name -eq 'scoop' -and $All -and
            ($CommandType -band [System.Management.Automation.CommandTypes]::ExternalScript) -and
            ($CommandType -band [System.Management.Automation.CommandTypes]::Application)
        }
        Should -Invoke Get-CapsulenvInstalledApp -ModuleName Capsulenv -Times 0 -Exactly
    }

    It 'does not infer a Scoop root from an arbitrary PATH executable' {
        $script:DiscoveryCommandPath = Join-Path $script:DiscoveryHostRoot 'scoop.ps1'
        New-Item -ItemType Directory -Path $script:DiscoveryHostRoot -Force | Out-Null
        New-Item -ItemType File -Path $script:DiscoveryCommandPath -Force | Out-Null
        & $script:Module { Find-CapsulenvHostScoop } | Should -BeNullOrEmpty
    }

    It 'requires a live canonical Scoop command under a standard discovered root' {
        & $script:Module { Find-CapsulenvHostScoop } | Should -BeNullOrEmpty
    }

    It 'excludes default capsule <Directory> even when configuration is unavailable' -ForEach @(
        @{ Directory = 'scoop' },
        @{ Directory = 'scoop-global' }
    ) {
        $script:DiscoveryCommandPath = Join-Path $script:DiscoveryCapsuleRoot "$Directory/shims/scoop.ps1"
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:DiscoveryCommandPath) -Force | Out-Null
        New-Item -ItemType File -Path $script:DiscoveryCommandPath -Force | Out-Null
        & $script:Module { Find-CapsulenvHostScoop } | Should -BeNullOrEmpty
    }

    It 'excludes configured capsule <Scope> roots outside the default capsule tree' -ForEach @(
        @{ Scope = 'User' },
        @{ Scope = 'Global' }
    ) {
        if ($Scope -eq 'User') {
            Mock Get-CapsulenvScoopRoot { $script:DiscoveryHostRoot } -ModuleName Capsulenv
        } else {
            Mock Get-CapsulenvScoopGlobalRoot { $script:DiscoveryHostRoot } -ModuleName Capsulenv
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:DiscoveryCommandPath) -Force | Out-Null
        New-Item -ItemType File -Path $script:DiscoveryCommandPath -Force | Out-Null
        & $script:Module { Find-CapsulenvHostScoop } | Should -BeNullOrEmpty
    }

    It 'rejects capsule <Directory> nominated by foreign global configuration' -ForEach @(
        @{ Directory = 'scoop' },
        @{ Directory = 'scoop-global' }
    ) {
        $capsuleScoop = Join-Path $script:DiscoveryCapsuleRoot $Directory
        New-Item -ItemType Directory -Path $script:DiscoveryHostRoot -Force | Out-Null
        @{ global_path = $capsuleScoop } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:DiscoveryHostRoot 'config.json') -Encoding utf8
        $result = & $script:Module { param($Root) Get-CapsulenvHostScoopGlobalRoot -HostRoot $Root } $script:DiscoveryHostRoot
        $result | Should -Not -Be $capsuleScoop
    }

    It 'rejects excluded global environment roots and the ProgramData fallback' {
        $script:ExcludedGlobalRoots = @(
            foreach ($target in @('User', 'Machine', 'Process')) {
                $value = [Environment]::GetEnvironmentVariable('SCOOP_GLOBAL', $target)
                if (-not [string]::IsNullOrWhiteSpace($value)) { [System.IO.Path]::GetFullPath($value).TrimEnd('\', '/') }
            }
            if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) { Join-Path $env:ProgramData 'scoop' }
        )
        Mock Get-CapsulenvScoopRootExclusions { $script:ExcludedGlobalRoots } -ModuleName Capsulenv
        & $script:Module { param($Root) Get-CapsulenvHostScoopGlobalRoot -HostRoot $Root } $script:DiscoveryHostRoot | Should -BeNullOrEmpty
    }
}
