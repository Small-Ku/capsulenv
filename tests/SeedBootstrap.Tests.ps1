Describe 'Capsulenv portable seed and bootstrap tier' {
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

    It 'accepts a verified immutable seed and exposes it as a seed provider candidate' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-seed-' + [Guid]::NewGuid().ToString('N'))
        $capsuleRoot = Join-Path $temporaryRoot 'capsule'
        $source = Join-Path $capsuleRoot 'seed/pwsh.exe'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force)
        'seed-pwsh' | Set-Content -LiteralPath $source -Encoding UTF8
        $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $result = & $script:Module {
            param($CapsuleRoot, $Source, $Hash)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $entry = New-CapsulenvPortableSeedEntry -Name pwsh -Version 7.5.0 -SourcePath $Source -ExpectedHash $Hash
            Set-CapsulenvPortableSeedManifest -Entries @($entry) | Out-Null
            $loaded = Get-CapsulenvPortableSeedEntry -Name pwsh
            $candidate = @(Get-CapsulenvSeedProgramCandidates -Requirement (New-CapsulenvProgramRequirement -Name pwsh))[0]
            [pscustomobject]@{
                Verified = Test-CapsulenvPortableSeedEntry -Entry $loaded
                Provider = $candidate.Provider
                Kind = $candidate.Kind
            }
        } $capsuleRoot $source $hash

        $result.Verified | Should -BeTrue
        $result.Provider | Should -Be 'seed'
        $result.Kind | Should -Be 'seed-acquisition'
        $result.PSObject.Properties.Name | Should -Not -Contain 'Executable'
    }

    It 'materializes a valid seed through the production acquisition boundary' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-seed-materialize-' + [Guid]::NewGuid().ToString('N'))
        $capsuleRoot = Join-Path $temporaryRoot 'capsule'
        $source = Join-Path $capsuleRoot 'seed/sing-box'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force)
        'seed-sing-box' | Set-Content -LiteralPath $source -Encoding UTF8 -NoNewline
        $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $result = & $script:Module {
            param($CapsuleRoot, $Source, $Hash)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $entry = New-CapsulenvPortableSeedEntry -Name sing-box -Version 1.0.0 -SourcePath $Source -ExpectedHash $Hash -Provenance 'seed/sing-box'
            Set-CapsulenvPortableSeedManifest -Entries @($entry) | Out-Null
            $requirement = New-CapsulenvProgramRequirement -Name sing-box -ExactVersion 1.0.0
            $resolved = Resolve-CapsulenvProgramWithAcquisition -Requirement $requirement -HostCandidates @() -SeedCandidates @(Get-CapsulenvSeedAcquisitionCandidates -Requirement $requirement)
            $rediscovered = Get-CapsulenvProgramResolution -Requirement $requirement
            [pscustomobject]@{
                Stage = $resolved.Stage
                AcquiredProvider = $resolved.Selected.Provider
                AcquiredOrigin = $resolved.Selected.AcquisitionProvider
                AcquiredScope = $resolved.Selected.Scope
                AcquiredOwnsLifecycle = $resolved.Selected.OwnsLifecycle
                NormalSucceeded = $rediscovered.Succeeded
                NormalProvider = $rediscovered.Selected.Provider
                NormalOrigin = $rediscovered.Selected.AcquisitionProvider
            }
        } $capsuleRoot $source $hash

        $result.Stage | Should -Be 'materialized-portable-seed'
        $result.AcquiredProvider | Should -Be 'capsulenv-local'
        $result.AcquiredOrigin | Should -Be 'seed'
        $result.AcquiredScope | Should -Be 'host-local'
        $result.AcquiredOwnsLifecycle | Should -BeTrue
        $result.NormalSucceeded | Should -BeTrue
        $result.NormalProvider | Should -Be 'capsulenv-local'
        $result.NormalOrigin | Should -Be 'seed'
    }

    It 'ensures a seeded program is published and activated when no generation exists' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-seed-ensure-' + [Guid]::NewGuid().ToString('N'))
        $capsuleRoot = Join-Path $temporaryRoot 'capsule'
        $source = Join-Path $capsuleRoot 'seed/pwsh.exe'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force)
        'seed-pwsh' | Set-Content -LiteralPath $source -Encoding UTF8 -NoNewline
        $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $result = & $script:Module {
            param($CapsuleRoot, $Source, $Hash)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $entry = New-CapsulenvPortableSeedEntry -Name pwsh -Version 7.5.0 -SourcePath $Source -ExpectedHash $Hash -Capabilities @('interactive')
            Set-CapsulenvPortableSeedManifest -Entries @($entry) | Out-Null
            $requirement = New-CapsulenvProgramRequirement -Name pwsh -ExactVersion 7.5.0 -RequiredCapabilities @('interactive')
            $ensured = Ensure-CapsulenvProgramGeneration -Requirement $requirement
            $active = Get-CapsulenvActiveGeneration
            [pscustomobject]@{ Stage = $ensured.Stage; SelectedProvider = $ensured.Selected.Provider; ActiveId = $active.Generation.GenerationId; ActiveSelection = $active.Generation.Selections[0].Name }
        } $capsuleRoot $source $hash

        $result.Stage | Should -Be 'materialized-portable-seed'
        $result.SelectedProvider | Should -Be 'capsulenv-local'
        $result.ActiveId | Should -Not -BeNullOrEmpty
        $result.ActiveSelection | Should -Be 'pwsh'
    }

    It 'enforces seed version provider and capability requirements before acquisition' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-seed-requirement-' + [Guid]::NewGuid().ToString('N'))
        $capsuleRoot = Join-Path $temporaryRoot 'capsule'
        $source = Join-Path $capsuleRoot 'seed/pwsh.exe'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force)
        'seed-pwsh' | Set-Content -LiteralPath $source -Encoding UTF8
        $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $result = & $script:Module {
            param($CapsuleRoot, $Source, $Hash)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $entry = New-CapsulenvPortableSeedEntry -Name pwsh -Version 7.5.0 -SourcePath $Source -ExpectedHash $Hash
            Set-CapsulenvPortableSeedManifest -Entries @($entry) | Out-Null
            $exactMiss = @(Get-CapsulenvSeedProgramCandidates -Requirement (New-CapsulenvProgramRequirement -Name pwsh -ExactVersion 7.6.4))
            $exactHit = @(Get-CapsulenvSeedProgramCandidates -Requirement (New-CapsulenvProgramRequirement -Name pwsh -ExactVersion 7.5.0 -AllowedProviders @('seed')))
            $capabilityMiss = @(Get-CapsulenvSeedProgramCandidates -Requirement (New-CapsulenvProgramRequirement -Name pwsh -ExactVersion 7.5.0 -RequiredCapabilities @('interactive') -AllowedProviders @('seed')))
            [pscustomobject]@{
                ExactMiss = $exactMiss.Count
                ExactHit = $exactHit.Count
                CapabilityMiss = $capabilityMiss.Count
            }
        } $capsuleRoot $source $hash

        $result.ExactMiss | Should -Be 0
        $result.ExactHit | Should -Be 1
        $result.CapabilityMiss | Should -Be 0
    }

    It 'rejects a corrupt seed and materializes a normal provider fallback as local authority' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-seed-fallback-' + [Guid]::NewGuid().ToString('N'))
        $capsuleRoot = Join-Path $temporaryRoot 'capsule'
        $source = Join-Path $capsuleRoot 'seed/bad.exe'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force)
        'bad-seed' | Set-Content -LiteralPath $source -Encoding UTF8
        $provider = Join-Path $temporaryRoot 'provider.exe'
        'provider' | Set-Content -LiteralPath $provider -Encoding UTF8
        $result = & $script:Module {
            param($CapsuleRoot, $Source, $Provider)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $entry = New-CapsulenvPortableSeedEntry -Name git -Version 2.0.0 -SourcePath $Source -ExpectedHash ('0' * 64)
            Set-CapsulenvPortableSeedManifest -Entries @($entry) | Out-Null
            $requirement = New-CapsulenvProgramRequirement -Name git
            $providerCandidate = New-CapsulenvProgramCandidate -Name git -Executable $Provider -Provider provider -Version 2.0.0
            $bootstrap = Invoke-CapsulenvBootstrapAcquisition -Requirement $requirement -SeedCandidates @(Get-CapsulenvSeedProgramCandidates -Requirement $requirement) -ProviderCandidates @($providerCandidate)
            [pscustomobject]@{
                SeedVerified = Test-CapsulenvPortableSeedEntry -Entry $entry
                Stage = $bootstrap.Stage
                Provider = $bootstrap.Selected.Provider
            }
        } $capsuleRoot $source $provider

        $result.SeedVerified | Should -BeFalse
        $result.Provider | Should -Be 'capsulenv-local'
        $result.Stage | Should -Be 'materialized-normal-provider'
    }

    It 'resolves a capsule-relative seed after the capsule root moves' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-seed-relocation-' + [Guid]::NewGuid().ToString('N'))
        $originalRoot = Join-Path $temporaryRoot 'original-capsule'
        $movedRoot = Join-Path $temporaryRoot 'moved-capsule'
        $source = Join-Path $originalRoot 'seed/git.exe'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force)
        'seed-git' | Set-Content -LiteralPath $source -Encoding UTF8
        $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $reference = & $script:Module {
            param($CapsuleRoot, $Source, $Hash)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $entry = New-CapsulenvPortableSeedEntry -Name git -Version 2.0.0 -SourcePath $Source -ExpectedHash $Hash
            Set-CapsulenvPortableSeedManifest -Entries @($entry) | Out-Null
            $entry.SourceReference
        } $originalRoot $source $hash
        Move-Item -LiteralPath $originalRoot -Destination $movedRoot

        $result = & $script:Module {
            param($CapsuleRoot, $Reference)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $entry = [pscustomobject]@{
                Immutable = $true
                SourceReference = $Reference
                ExpectedHash = (Get-FileHash -LiteralPath (Join-Path $CapsuleRoot 'seed/git.exe') -Algorithm SHA256).Hash
            }
            [pscustomobject]@{
                Resolved = Resolve-CapsulenvPortableSeedSourcePath -Entry $entry
                Verified = Test-CapsulenvPortableSeedEntry -Entry $entry
            }
        } $movedRoot $reference

        $result.Verified | Should -BeTrue
        $result.Resolved | Should -Be (Join-Path $movedRoot 'seed/git.exe')
    }

    It 'rejects rooted and traversal executable paths and never returns a direct Program executable' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-seed-boundary-' + [Guid]::NewGuid().ToString('N'))
        $capsuleRoot = Join-Path $temporaryRoot 'capsule'
        $source = Join-Path $capsuleRoot 'seed/root'
        [void](New-Item -ItemType Directory -Path $source -Force)
        'inside' | Set-Content -LiteralPath (Join-Path $source 'inside.exe') -Encoding UTF8
        'outside' | Set-Content -LiteralPath (Join-Path $capsuleRoot 'outside.exe') -Encoding UTF8
        $hash = & $script:Module {
            param($CapsuleRoot, $Source)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            Get-CapsulenvSeedSourceHash -SourcePath $Source
        } $capsuleRoot $source
        $result = & $script:Module {
            param($CapsuleRoot, $Source, $Hash)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $valid = New-CapsulenvPortableSeedEntry -Name demo -Version 1.0.0 -SourcePath $Source -ExpectedHash $Hash -ExecutableRelativePath 'inside.exe'
            Set-CapsulenvPortableSeedManifest -Entries @($valid) | Out-Null
            $traversal = [pscustomobject]@{
                SchemaVersion = 1
                Immutable = $true
                Name = 'demo'
                Version = '1.0.0'
                SourceReference = $valid.SourceReference
                ExpectedHash = $Hash
                ExecutableRelativePath = '../outside.exe'
            }
            $rooted = [pscustomobject]@{
                SchemaVersion = 1
                Immutable = $true
                Name = 'demo'
                Version = '1.0.0'
                SourceReference = $valid.SourceReference
                ExpectedHash = $Hash
                ExecutableRelativePath = [System.IO.Path]::GetPathRoot($Source) + 'outside.exe'
            }
            $result = [pscustomobject]@{
                ValidKind = (@(Get-CapsulenvSeedAcquisitionCandidates -Requirement (New-CapsulenvProgramRequirement -Name demo))[0]).Kind
                TraversalValid = Test-CapsulenvPortableSeedEntry -Entry $traversal
                RootedThrows = $false
            }
            try { Resolve-CapsulenvPortableSeedExecutablePath -SeedRoot $Source -RelativePath $rooted.ExecutableRelativePath | Out-Null } catch { $result.RootedThrows = $true }
            return $result
        } $capsuleRoot $source $hash

        $result.ValidKind | Should -Be 'seed-acquisition'
        $result.TraversalValid | Should -BeFalse
        $result.RootedThrows | Should -BeTrue
    }

    It 'blocks provider acquisition when bootstrap networking is required and unavailable' {
        $requirement = New-CapsulenvProgramRequirement -Name sing-box
        {
            Invoke-CapsulenvBootstrapAcquisition -Requirement $requirement -RequireBootstrapNetwork
        } | Should -Throw
    }
    It 'rechecks caller-supplied seed bytes against ExpectedHash before selection' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-seed-caller-' + [Guid]::NewGuid().ToString('N'))
        $capsuleRoot = Join-Path $temporaryRoot 'capsule'
        $source = Join-Path $capsuleRoot 'seed/pwsh.exe'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force)
        'seed-pwsh' | Set-Content -LiteralPath $source -Encoding UTF8
        try {
            $result = & $script:Module {
                param($CapsuleRoot, $Source)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $candidate = [pscustomobject]@{
                    Kind = 'seed-acquisition'
                    Name = 'pwsh'
                    Version = '7.6.5'
                    SourceReference = ConvertTo-CapsulenvStatePathReference -Path $Source
                    ExpectedHash = ('0' * 64)
                    ExecutableRelativePath = $null
                    Capabilities = @()
                    Provenance = 'caller'
                }
                Test-CapsulenvSeedAcquisitionCandidateAgainstRequirement -Requirement (New-CapsulenvProgramRequirement -Name pwsh -AllowedProviders @('seed')) -Candidate $candidate
            } $capsuleRoot $source
            $result.Compatible | Should -BeFalse
            $result.Reasons | Should -Contain 'seed-source-invalid'
        } finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

}

