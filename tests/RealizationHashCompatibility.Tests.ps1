Describe 'Capsulenv realization directory digest compatibility' {
    BeforeAll {
        $script:Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force -DisableNameChecking
        $script:Module = Get-Module Capsulenv
        $script:Source = Join-Path $TestDrive 'directory-payload'
        [void](New-Item -Path $script:Source -ItemType Directory -Force)
        foreach ($filename in @('mscordaccore.dll', 'mscordaccore_amd64_amd64_10.0.1326.46716.dll', 'alpha.txt')) {
            [IO.File]::WriteAllText((Join-Path $script:Source $filename), $filename, [Text.UTF8Encoding]::new($false))
        }
        $script:WinPS = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $script:Probe = Join-Path $TestDrive 'compute-hash.ps1'
        $probeSource = @(
            'param([string]$ModulePath, [string]$SourcePath, [string]$Algorithm)'
            '$ErrorActionPreference = ''Stop'''
            'Import-Module $ModulePath -Force -DisableNameChecking'
            '$module = Get-Module Capsulenv'
            '& $module { param($Path, $Kind) Get-CapsulenvRealizationSourceHash -SourcePath $Path -Algorithm $Kind } $SourcePath $Algorithm'
        ) -join [Environment]::NewLine
        [IO.File]::WriteAllText($script:Probe, $probeSource, [Text.UTF8Encoding]::new($false))

        $script:ActivationProbe = Join-Path $TestDrive 'publish-activation.ps1'
        $source = @(
            'param([string]$ModulePath, [string]$CapsuleRoot, [string]$SourcePath, [string]$StateRoot)'
            '$ErrorActionPreference = ''Stop'''
            '$env:CAPSULENV_HOST_STATE_ROOT = $StateRoot'
            '$env:CAPSULENV_HOST_KEY = ''hash-runtime'''
            '$env:CAPSULENV_HOST_BOOT_EPOCH = ''hash-runtime'''
            'Import-Module $ModulePath -Force -DisableNameChecking'
            '$module = Get-Module Capsulenv'
            '& $module { param($Root, $Source)'
            '    Initialize-CapsulenvContext -Root $Root | Out-Null'
            '    $r = Acquire-CapsulenvProgramRealization -Name demo -Version 1.0 -SourcePath $Source -ExecutableRelativePath alpha.txt -Provider provider'
            '    $g = Publish-CapsulenvGeneration -Realizations @($r)'
            '    Set-CapsulenvActiveGenerationAuthority -GenerationId $g.GenerationId | Out-Null'
            '    Write-Output $g.GenerationId'
            '} $CapsuleRoot $SourcePath'
        ) -join [Environment]::NewLine
        [IO.File]::WriteAllText($script:ActivationProbe, $source, [Text.UTF8Encoding]::new($false))
    }
    AfterAll { Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue }

    It 'computes identical ordinal-v1 digests in WinPS 5.1 and PowerShell 7' {
        $coreHash = & $script:Module { param($Path) Get-CapsulenvRealizationSourceHash -SourcePath $Path } $script:Source
        $winHash = & $script:WinPS -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:Probe $script:Build.ModulePath $script:Source ordinal-v1
        $LASTEXITCODE | Should -Be 0
        $winHash | Should -Be $coreHash
        $coreHash | Should -Match '^[0-9a-f]{64}$'
    }

    It 'loads a schema-v3 active generation published by a separate WinPS5 process' {
        $capsule = Join-Path $TestDrive 'runtime-capsule'
        $stateRoot = Join-Path $TestDrive 'runtime-host'
        $oldState = $env:CAPSULENV_HOST_STATE_ROOT
        $oldHost = $env:CAPSULENV_HOST_KEY
        $oldEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        try {
            $published = & $script:WinPS -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:ActivationProbe $script:Build.ModulePath $capsule $script:Source $stateRoot
            $LASTEXITCODE | Should -Be 0
            $published | Should -Match '^[0-9a-f]{32}$'
            $env:CAPSULENV_HOST_STATE_ROOT = $stateRoot
            $env:CAPSULENV_HOST_KEY = 'hash-runtime'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'hash-runtime'
            $result = & $script:Module {
                param($Root)
                Initialize-CapsulenvContext -Root $Root | Out-Null
                Get-CapsulenvActiveGeneration
            } $capsule
            $result | Should -Not -BeNullOrEmpty
            $result.Generation.GenerationId | Should -Be $published
        } finally {
            if ($null -eq $oldState) { Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:CAPSULENV_HOST_STATE_ROOT = $oldState }
            if ($null -eq $oldHost) { Remove-Item Env:CAPSULENV_HOST_KEY -ErrorAction SilentlyContinue } else { $env:CAPSULENV_HOST_KEY = $oldHost }
            if ($null -eq $oldEpoch) { Remove-Item Env:CAPSULENV_HOST_BOOT_EPOCH -ErrorAction SilentlyContinue } else { $env:CAPSULENV_HOST_BOOT_EPOCH = $oldEpoch }
        }
    }
    It 'matches the WinPS5 legacy hash via Windows NLS instead of current pwsh collation' {
        $oldHash = & $script:WinPS -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:Probe $script:Build.ModulePath $script:Source legacy-runtime
        $LASTEXITCODE | Should -Be 0
        $recovered = & $script:Module { param($Path) Get-CapsulenvRealizationSourceHash -SourcePath $Path -Algorithm 'legacy-windows-nls' } $script:Source
        $recovered | Should -Be $oldHash
        $current = & $script:Module { param($Path) Get-CapsulenvRealizationSourceHash -SourcePath $Path -Algorithm 'legacy-runtime' } $script:Source
        $current | Should -Not -Be $oldHash
    }

    It 'preserves legacy directory seed ExpectedHash without publishing a legacy realization digest' {
        $seedHash = & $script:Module { param($Source) Get-CapsulenvSeedSourceHash -SourcePath $Source } $script:Source
        $ordinalHash = & $script:Module { param($Source) Get-CapsulenvRealizationSourceHash -SourcePath $Source } $script:Source
        $seedHash | Should -Not -Be $ordinalHash
        $previousState = $env:CAPSULENV_HOST_STATE_ROOT
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $TestDrive 'seed-depot'
            $manifest = & $script:Module {
                param($Root, $Source, $Expected)
                Initialize-CapsulenvContext -Root $Root | Out-Null
                Acquire-CapsulenvProgramRealization -Name seeded -Version 1.0 -SourcePath $Source -ExecutableRelativePath alpha.txt -Provider capsulenv-local -AcquisitionProvider seed -ExpectedHash $Expected -Provenance seed/fixture
            } (Join-Path $TestDrive 'seed-capsule') $script:Source $seedHash
            $manifest.SchemaVersion | Should -Be 3
            $manifest.SourceHash | Should -Be $ordinalHash
            $manifest.AcquisitionProvider | Should -Be 'seed'
            & $script:Module { param($Root) Test-CapsulenvProgramRealization -RealizationRoot $Root } $manifest.RealizationRoot | Should -BeTrue
            {
                & $script:Module {
                    param($Source, $Expected)
                    Acquire-CapsulenvProgramRealization -Name forged -Version 1.0 -SourcePath $Source -ExecutableRelativePath alpha.txt -Provider capsulenv-local -AcquisitionProvider seed -ExpectedHash $Expected
                } $script:Source ('0' * 64)
            } | Should -Throw '*source hash mismatch*'
        } finally {
            if ($null -eq $previousState) { Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:CAPSULENV_HOST_STATE_ROOT = $previousState }
        }
    }
    It 'publishes a schema-v3 realization and still validates immutable schema-v2 payloads' {
        $oldState = $env:CAPSULENV_HOST_STATE_ROOT
        $oldEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $TestDrive 'host'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'hash-compatibility'
            $r = & $script:Module {
                param($CapsuleRoot, $SourcePath)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                Acquire-CapsulenvProgramRealization -Name hashfixture -Version 1.0 -SourcePath $SourcePath -ExecutableRelativePath 'alpha.txt' -Provider provider -Provenance 'test/fixture'
            } (Join-Path $TestDrive 'capsule') $script:Source
            $manifestPath = Join-Path $r.RealizationRoot 'realization.json'
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $manifest.SchemaVersion | Should -Be 3
            $manifest.DirectoryHashAlgorithm | Should -Be 'ordinal-v1'
            & $script:Module { param($Root) Test-CapsulenvProgramRealization -RealizationRoot $Root } $r.RealizationRoot | Should -BeTrue

            $oldHash = & $script:WinPS -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:Probe $script:Build.ModulePath $script:Source legacy-runtime
            $LASTEXITCODE | Should -Be 0
            $manifest.SchemaVersion = 2
            $manifest.PSObject.Properties.Remove('DirectoryHashAlgorithm')
            $manifest.SourceHash = [string]$oldHash
            $manifest.PayloadHash = [string]$oldHash
            [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 9), [Text.UTF8Encoding]::new($false))
            & $script:Module { param($Root) Test-CapsulenvProgramRealization -RealizationRoot $Root } $r.RealizationRoot | Should -BeTrue

            [IO.File]::AppendAllText((Join-Path $r.RealizationRoot 'payload/alpha.txt'), 'changed')
            & $script:Module { param($Root) Test-CapsulenvProgramRealization -RealizationRoot $Root } $r.RealizationRoot | Should -BeFalse
        } finally {
            if ($null -eq $oldState) { Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue } else { $env:CAPSULENV_HOST_STATE_ROOT = $oldState }
            if ($null -eq $oldEpoch) { Remove-Item Env:CAPSULENV_HOST_BOOT_EPOCH -ErrorAction SilentlyContinue } else { $env:CAPSULENV_HOST_BOOT_EPOCH = $oldEpoch }
        }
    }
}