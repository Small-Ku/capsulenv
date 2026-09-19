Describe 'Capsulenv activation fast path and criticality' {
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

    It 'resolves a generation once and degrades optional resources diagnostically' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-activation-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'activation-test'
            $source = Join-Path $temporaryRoot 'source/demo.exe'
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force)
            'demo' | Set-Content -LiteralPath $source -Encoding UTF8

            $plan = & $script:Module {
                param($CapsuleRoot, $Source)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $realization = Acquire-CapsulenvProgramRealization -Name demo -Version 1.0.0 -SourcePath $Source
                $generation = Publish-CapsulenvGeneration -Realizations @($realization)
                [void](Set-CapsulenvActiveGenerationAuthority -GenerationId $generation.GenerationId)
                $demo = New-CapsulenvProgramRequirement -Name demo -ExactVersion 1.0.0
                $browser = New-CapsulenvProgramRequirement -Name firefox
                $resources = @(
                    (New-CapsulenvActivationResource -Name demo -Criticality required -Kind program -Requirement $demo),
                    (New-CapsulenvActivationResource -Name firefox -Criticality optional -Kind program -Requirement $browser)
                )
                $bindings = @(
                    (New-CapsulenvActivationBinding -Name CAPSULENV_TEST -Value enabled -Kind environment),
                    (New-CapsulenvActivationBinding -Name demo-root -Value $realization.RealizationRoot -Kind path)
                )
                Resolve-CapsulenvActivation -Resources $resources -Bindings $bindings
            } $temporaryRoot $source

            $plan.Succeeded | Should -BeTrue
            $plan.ResolvedPrograms.Count | Should -Be 1
            $plan.ResolvedPrograms[0].Name | Should -Be 'demo'
            $plan.Environment.CAPSULENV_TEST | Should -Be 'enabled'
            $plan.Path | Should -Match 'demo'
            $plan.Diagnostics -join ' ' | Should -Match 'firefox'
            { Invoke-CapsulenvActivation -Plan $plan } | Should -Not -Throw
        } finally {
            if ($null -eq $oldStateRoot) {
                Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_STATE_ROOT = $oldStateRoot
            }
            if ($null -eq $oldBootEpoch) {
                Remove-Item Env:CAPSULENV_HOST_BOOT_EPOCH -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_BOOT_EPOCH = $oldBootEpoch
            }
        }
    }

    It 'fails closed for required interactive pwsh instead of using the control host' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-required-pwsh-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'missing-pwsh-test'
            $plan = & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $pwsh = New-CapsulenvProgramRequirement -Name pwsh
                $resource = New-CapsulenvActivationResource -Name pwsh -Criticality required -Kind program -Requirement $pwsh
                Resolve-CapsulenvActivation -Resources @($resource)
            } $temporaryRoot

            $plan.Succeeded | Should -BeFalse
            $plan.RequiredFailures -join ' ' | Should -Match 'pwsh'
            { Invoke-CapsulenvActivation -Plan $plan } | Should -Throw
        } finally {
            if ($null -eq $oldStateRoot) {
                Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_STATE_ROOT = $oldStateRoot
            }
            if ($null -eq $oldBootEpoch) {
                Remove-Item Env:CAPSULENV_HOST_BOOT_EPOCH -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_BOOT_EPOCH = $oldBootEpoch
            }
        }
    }

    It 'revalidates mutable host-program selections against current provider state' {
        $executable = Join-Path $TestDrive 'current-firefox.exe'
        New-Item -ItemType File -Path $executable -Force | Out-Null
        Mock Get-CapsulenvActiveGeneration {
            [pscustomobject]@{
                Generation = [pscustomobject]@{
                    GenerationId = 'host-refresh'
                    Selections = @([pscustomobject]@{
                        Kind = 'host-program'
                        Name = 'firefox'
                        Provider = 'host-scoop'
                        Scope = 'user'
                        Provenance = 'scoop:user/firefox'
                        Version = '1.0.0'
                        Executable = 'C:\stale\firefox.exe'
                        Root = 'C:\stale'
                        Trusted = $true
                        OwnsLifecycle = $false
                    })
                }
            }
        } -ModuleName Capsulenv
        Mock Get-CapsulenvProgramCandidates {
            @(
                (New-CapsulenvProgramCandidate -Name firefox -Executable $executable -Provider host-scoop -Scope user -Version 2.0.0 -Provenance 'scoop:user/firefox')
            )
        } -ModuleName Capsulenv

        $plan = & $script:Module {
            $requirement = New-CapsulenvProgramRequirement -Name firefox
            $resource = New-CapsulenvActivationResource -Name firefox -Criticality required -Kind program -Requirement $requirement
            Resolve-CapsulenvActivation -Resources @($resource)
        }

        $plan.Succeeded | Should -BeTrue
        $plan.ResolvedPrograms[0].Version | Should -Be '2.0.0'
        $plan.ResolvedPrograms[0].Executable | Should -Be ([System.IO.Path]::GetFullPath($executable))
    }

    It 'uses the active generation selection instead of a newer unselected local realization' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-active-generation-authority-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'active-generation-authority-test'
            $result = & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $pwsh75 = Join-Path $CapsuleRoot 'source/pwsh-7.5.0'
                $pwsh76 = Join-Path $CapsuleRoot 'source/pwsh-7.6.5'
                [void](New-Item -ItemType Directory -Path (Split-Path -Parent $pwsh75) -Force)
                '7.5' | Set-Content -LiteralPath $pwsh75 -NoNewline
                '7.6' | Set-Content -LiteralPath $pwsh76 -NoNewline
                $older = Acquire-CapsulenvProgramRealization -Name pwsh -Version 7.5.0 -SourcePath $pwsh75 -Provider capsulenv-local -Provenance 'local/7.5'
                $newer = Acquire-CapsulenvProgramRealization -Name pwsh -Version 7.6.5 -SourcePath $pwsh76 -Provider capsulenv-local -Provenance 'local/7.6'
                $generation = Publish-CapsulenvGeneration -Realizations @($older)
                Set-CapsulenvActiveGenerationAuthority -GenerationId $generation.GenerationId | Out-Null
                $requirement = (Get-CapsulenvInteractivePowerShellRequirement -MinimumVersion 7.0.0).Requirement
                $selected = Get-CapsulenvActiveGenerationProgram -Requirement $requirement
                $allLocal = @(Get-CapsulenvProgramCandidates -Requirement $requirement | Where-Object Provider -eq 'capsulenv-local')
                [pscustomobject]@{
                    SelectedVersion = $selected.Version
                    SelectedProvenance = $selected.Provenance
                    LocalVersions = @($allLocal.Version)
                    NewerRoot = $newer.RealizationRoot
                }
            } $temporaryRoot

            $result.SelectedVersion | Should -Be '7.5.0'
            $result.SelectedProvenance | Should -Be 'local/7.5'
            @($result.LocalVersions) | Should -Contain '7.6.5'
        } finally {
            if ($null -eq $oldStateRoot) { Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:CAPSULENV_HOST_STATE_ROOT = $oldStateRoot }
            if ($null -eq $oldBootEpoch) { Remove-Item Env:CAPSULENV_HOST_BOOT_EPOCH -ErrorAction SilentlyContinue } else { $env:CAPSULENV_HOST_BOOT_EPOCH = $oldBootEpoch }
        }
    }

    It 'keeps the activation generation snapshot stable across later active-generation changes' {
        $activeA = [pscustomobject]@{
            Authority = [pscustomobject]@{ GenerationId = 'generation-a' }
            Generation = [pscustomobject]@{
                GenerationId = 'generation-a'
                Selections = @([pscustomobject]@{ Name = 'pwsh'; Kind = 'host-program'; Provider = 'host-scoop'; Scope = 'user'; Provenance = 'scoop:user/pwsh'; Version = '7.5.0'; Executable = 'pwsh.exe'; Trusted = $true; OwnsLifecycle = $false })
            }
        }
        $activeB = [pscustomobject]@{
            Authority = [pscustomobject]@{ GenerationId = 'generation-b' }
            Generation = [pscustomobject]@{ GenerationId = 'generation-b'; Selections = @() }
        }
        Mock Get-CapsulenvActiveGeneration { $activeA } -ModuleName Capsulenv
        Mock ConvertTo-CapsulenvGenerationProgramCandidate {
            New-CapsulenvProgramCandidate -Name 'pwsh' -Executable 'pwsh.exe' -Provider host-scoop -Scope user -Version '7.5.0' -Provenance 'scoop:user/pwsh' -Capabilities @('interactive')
        } -ModuleName Capsulenv

        $result = & $script:Module {
            $requirement = New-CapsulenvProgramRequirement -Name pwsh -RequiredCapabilities @('interactive')
            $snapshot = New-CapsulenvActivationSnapshot
            $first = Get-CapsulenvActiveGenerationProgram -Requirement $requirement -ActivationSnapshot $snapshot
            [pscustomobject]@{ GenerationId = $snapshot.GenerationId; Version = $first.Version }
        }

        $result.GenerationId | Should -Be 'generation-a'
        $result.Version | Should -Be '7.5.0'
        Should -Invoke Get-CapsulenvActiveGeneration -ModuleName Capsulenv -Times 1 -Exactly
    }

    It 'does not silently drop required binding or session-service resources' {
        $plan = & $script:Module {
            $binding = New-CapsulenvActivationResource -Name git -Criticality required -Kind binding -Value $null
            $service = New-CapsulenvActivationResource -Name sing-box -Criticality required -Kind session-service -Value $null
            Resolve-CapsulenvActivation -Resources @($binding, $service)
        }

        $plan.Succeeded | Should -BeFalse
        ($plan.RequiredFailures -join ' ') | Should -Match 'Binding resource.*git'
        ($plan.RequiredFailures -join ' ') | Should -Match 'SessionService resource.*sing-box'
    }

    It 'fails closed when resource, requirement, and selection identities disagree' {
        Mock Get-CapsulenvActiveGeneration {
            [pscustomobject]@{
                Generation = [pscustomobject]@{
                    GenerationId = 'identity-test'
                    Selections = @([pscustomobject]@{
                        Kind = 'host-program'
                        Name = 'firefox'
                        Provider = 'host-scoop'
                        Version = '1.0.0'
                        Provenance = 'scoop:user/firefox'
                        Executable = '/does/not/exist'
                        Trusted = $true
                        OwnsLifecycle = $false
                    })
                }
            }
        } -ModuleName Capsulenv

        $plan = & $script:Module {
            $requirement = New-CapsulenvProgramRequirement -Name pwsh
            $resource = New-CapsulenvActivationResource -Name firefox -Criticality required -Kind program -Requirement $requirement
            Resolve-CapsulenvActivation -Resources @($resource)
        }

        $plan.Succeeded | Should -BeFalse
        ($plan.RequiredFailures -join ' ') | Should -Match 'identities disagree'
    }
}
