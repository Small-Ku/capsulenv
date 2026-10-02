Describe 'Capsulenv host-local PowerShell binding' {
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

    It 'reuses a trusted host pwsh while keeping profile, history, and modules portable or host-local' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-pwsh-binding-' + [Guid]::NewGuid().ToString('N'))
        $executable = Join-Path $temporaryRoot 'host/pwsh'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $executable) -Force)
        'pwsh' | Set-Content -LiteralPath $executable -Encoding UTF8
        $binding = & $script:Module {
            param($CapsuleRoot, $Executable)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $requirement = (Get-CapsulenvInteractivePowerShellRequirement -MinimumVersion 7.0.0).Requirement
            $candidate = New-CapsulenvProgramCandidate -Name pwsh -Executable $Executable -Provider host-scoop -Version 7.5.0 -Capabilities @('interactive')
            Resolve-CapsulenvPowerShellBinding -Requirement $requirement -Candidates @($candidate) -TrustedHostModulePaths @('/trusted/modules')
        } $temporaryRoot $executable

        $binding.Succeeded | Should -BeTrue
        $binding.Program.Provider | Should -Be 'host-scoop'
        $binding.ControlPlaneFallback | Should -BeFalse
        $binding.ProfilePath | Should -BeLike "$temporaryRoot/state/portable/powershell/*"
        $binding.HistoryPath | Should -BeLike "$temporaryRoot/state/portable/powershell/history/*"
        $binding.PSModulePath.Split([System.IO.Path]::PathSeparator)[0] | Should -BeLike '*state/portable/powershell/modules'
        $binding.PSModulePath | Should -Match '/trusted/modules'
    }

    It 'resolves an active capsulenv-local pwsh realization through the normal candidate path' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-pwsh-local-resolution-' + [Guid]::NewGuid().ToString('N'))
        $pwsh = Join-Path $PSHOME 'pwsh'
        if (-not (Test-Path -LiteralPath $pwsh -PathType Leaf)) { $pwsh = Join-Path $PSHOME 'pwsh.exe' }
        $result = & $script:Module {
            param($CapsuleRoot, $Executable)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $manifest = Acquire-CapsulenvProgramRealization -Name pwsh -Version 7.6.4 -SourcePath $Executable -Provider capsulenv-local -Provenance 'capsulenv-local/pwsh'
            $generation = Publish-CapsulenvGeneration -Realizations @($manifest)
            Set-CapsulenvActiveGenerationAuthority -GenerationId $generation.GenerationId | Out-Null
            $requirement = (Get-CapsulenvInteractivePowerShellRequirement -MinimumVersion 7.0.0).Requirement
            $candidate = @(Get-CapsulenvProgramCandidates -Requirement $requirement | Where-Object Provider -eq 'capsulenv-local')
            [pscustomobject]@{ Count = $candidate.Count; Provider = $candidate[0].Provider; Executable = $candidate[0].Executable }
        } $temporaryRoot $pwsh

        $result.Count | Should -Be 1
        $result.Provider | Should -Be 'capsulenv-local'
        Test-Path -LiteralPath $result.Executable -PathType Leaf | Should -BeTrue
    }
    It 'keeps the activation-selected pwsh program instead of re-resolving a newer local candidate' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-pwsh-selected-program-' + [Guid]::NewGuid().ToString('N'))
        $selectedPath = Join-Path $temporaryRoot 'pwsh-7.5'
        $newerPath = Join-Path $temporaryRoot 'pwsh-7.6'
        [void](New-Item -ItemType Directory -Path $temporaryRoot -Force)
        'selected' | Set-Content -LiteralPath $selectedPath -NoNewline
        'newer' | Set-Content -LiteralPath $newerPath -NoNewline
        $result = & $script:Module {
            param($CapsuleRoot, $SelectedPath, $NewerPath)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $requirement = (Get-CapsulenvInteractivePowerShellRequirement -MinimumVersion 7.0.0).Requirement
            $selected = New-CapsulenvProgramCandidate -Name pwsh -Executable $SelectedPath -Provider capsulenv-local -Scope host-local -Version 7.5.0 -Capabilities @('interactive') -OwnsLifecycle:$true -Provenance 'generation/7.5'
            $newer = New-CapsulenvProgramCandidate -Name pwsh -Executable $NewerPath -Provider capsulenv-local -Scope host-local -Version 7.6.5 -Capabilities @('interactive') -OwnsLifecycle:$true -Provenance 'unselected/7.6'
            $binding = Resolve-CapsulenvPowerShellBinding -Requirement $requirement -Program $selected -Candidates @($newer)
            [pscustomobject]@{ Version = $binding.Program.Version; Provenance = $binding.Program.Provenance }
        } $temporaryRoot $selectedPath $newerPath

        $result.Version | Should -Be '7.5.0'
        $result.Provenance | Should -Be 'generation/7.5'
    }

    It 'fails closed for required pwsh and does not return a control-plane substitute' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-pwsh-missing-' + [Guid]::NewGuid().ToString('N'))
        $bindingError = $null
        try {
            & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                Resolve-CapsulenvPowerShellBinding -Requirement (Get-CapsulenvInteractivePowerShellRequirement).Requirement -Candidates @()
            } $temporaryRoot | Out-Null
        } catch {
            $bindingError = $_
        }
        $bindingError | Should -Not -BeNullOrEmpty
        $bindingError.Exception.Message | Should -Match 'interactive pwsh'
        $bindingError.Exception.Message | Should -Not -Match 'control'
    }

    It 'materializes a valid host placement before creating host-local module storage' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-pwsh-placement-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'powershell-placement-test'
            $result = & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $paths = Get-CapsulenvPowerShellStatePaths -Create
                $placement = Get-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity)
                [pscustomobject]@{
                    HostModulesRoot = $paths.HostModulesRoot
                    MarkerExists = Test-Path -LiteralPath $placement.MarkerPath -PathType Leaf
                    PlacementValid = $placement.Valid
                }
            } $temporaryRoot
            $result.MarkerExists | Should -BeTrue
            $result.PlacementValid | Should -BeTrue
            $result.HostModulesRoot | Should -BeLike '*modules'
        } finally {
            if ($null -eq $oldStateRoot) { Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:CAPSULENV_HOST_STATE_ROOT = $oldStateRoot }
            if ($null -eq $oldBootEpoch) { Remove-Item Env:CAPSULENV_HOST_BOOT_EPOCH -ErrorAction SilentlyContinue } else { $env:CAPSULENV_HOST_BOOT_EPOCH = $oldBootEpoch }
        }
    }

    It 'excludes inherited module paths unless explicitly trusted' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-pwsh-module-policy-' + [Guid]::NewGuid().ToString('N'))
        $oldModulePath = $env:PSModulePath
        try {
            $env:PSModulePath = [System.IO.Path]::PathSeparator -join @('/untrusted/inherited', '/trusted/inherited')
            $binding = & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $requirement = (Get-CapsulenvInteractivePowerShellRequirement -MinimumVersion 7.0.0).Requirement
                $candidate = New-CapsulenvProgramCandidate -Name pwsh -Executable (Join-Path $PSHOME 'pwsh') -Provider host-scoop -Version 7.5.0 -Capabilities @('interactive')
                Resolve-CapsulenvPowerShellBinding -Requirement $requirement -Candidates @($candidate) -TrustedHostModulePaths @('/trusted/inherited')
            } $temporaryRoot
            $binding.PSModulePath | Should -Match '/trusted/inherited'
            $binding.PSModulePath | Should -Not -Match '/untrusted/inherited'
        } finally {
            $env:PSModulePath = $oldModulePath
        }
    }

    It 'runs a real child pwsh bootstrap that loads the portable profile and configures history' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-pwsh-child-' + [Guid]::NewGuid().ToString('N'))
        $pwsh = Join-Path $PSHOME 'pwsh'
        if (-not (Test-Path -LiteralPath $pwsh -PathType Leaf)) {
            $pwsh = Join-Path $PSHOME 'pwsh.exe'
        }
        $marker = Join-Path $temporaryRoot 'profile-ran.txt'
        $oldMarker = $env:CAPSULENV_TEST_PROFILE_MARKER
        try {
            $env:CAPSULENV_TEST_PROFILE_MARKER = $marker
            $result = & $script:Module {
                param($CapsuleRoot, $Executable, $Marker)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $requirement = (Get-CapsulenvInteractivePowerShellRequirement -MinimumVersion 7.0.0).Requirement
                $candidate = New-CapsulenvProgramCandidate -Name pwsh -Executable $Executable -Provider host-scoop -Version 7.6.4 -Capabilities @('interactive')
                $binding = Resolve-CapsulenvPowerShellBinding -Requirement $requirement -Candidates @($candidate)
                "Set-Content -LiteralPath `$env:CAPSULENV_TEST_PROFILE_MARKER -Value 'profile-ran'" | Set-Content -LiteralPath $binding.ProfilePath -Encoding UTF8
                Invoke-CapsulenvPowerShellActivation -Binding $binding -Apply | Out-Null
                $command = $binding.BootstrapCommand + "; [Console]::WriteLine((Get-PSReadLineOption).HistorySavePath)"
                $output = & $Executable -NoLogo -NoProfile -Command $command
                [pscustomobject]@{ Binding = $binding; Output = @($output) }
            } $temporaryRoot $pwsh $marker
            (Get-Content -LiteralPath $marker -Raw).Trim() | Should -Be 'profile-ran'
            ($result.Output -join "`n") | Should -Match ([regex]::Escape($result.Binding.HistoryPath))
        } finally {
            if ($null -eq $oldMarker) { Remove-Item Env:CAPSULENV_TEST_PROFILE_MARKER -ErrorAction SilentlyContinue } else { $env:CAPSULENV_TEST_PROFILE_MARKER = $oldMarker }
        }
    }
}

