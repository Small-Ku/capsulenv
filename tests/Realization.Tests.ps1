Describe 'Capsulenv host-local realization and generation authority' {
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

    It 'rejects rooted Windows executable paths before publishing a realization' {
        $source = Join-Path $TestDrive 'source.exe'
        'payload' | Set-Content -LiteralPath $source -NoNewline
        $rooted = if (Test-CapsulenvWindows) { 'C:\outside.exe' } else { 'C:/outside.exe' }

        {
            & $script:Module {
                param($Source, $ExecutableRelativePath)
                Initialize-CapsulenvContext -Root (Join-Path $TestDrive 'capsule') | Out-Null
                Acquire-CapsulenvProgramRealization -Name demo -Version 1.0.0 -SourcePath $Source -ExecutableRelativePath $ExecutableRelativePath
            } $source $rooted
        } | Should -Throw '*non-rooted relative path*'
    }

    It 'publishes a verified immutable realization before activating a small generation' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-realization-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'realization-test'
            $source = Join-Path $temporaryRoot 'source/demo.exe'
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force)
            'demo' | Set-Content -LiteralPath $source -Encoding UTF8
            $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash

            $result = & $script:Module {
                param($CapsuleRoot, $Source, $Hash)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $realization = Acquire-CapsulenvProgramRealization -Name demo -Version 1.0.0 -SourcePath $Source -ExpectedHash $Hash -Provider provider -Provenance test
                $generation = Publish-CapsulenvGeneration -Realizations @($realization)
                [void](Set-CapsulenvActiveGenerationAuthority -GenerationId $generation.GenerationId)
                $active = Get-CapsulenvActiveGeneration
                [pscustomobject]@{
                    RealizationRoot = $realization.RealizationRoot
                    Valid = Test-CapsulenvProgramRealization -RealizationRoot $realization.RealizationRoot -ExpectedName demo
                    GenerationId = $generation.GenerationId
                    ActiveGenerationId = $active.Generation.GenerationId
                    SelectionRoot = $active.Generation.Selections[0].RealizationRoot
                }
            } $temporaryRoot $source $hash

            $result.Valid | Should -BeTrue
            $result.ActiveGenerationId | Should -Be $result.GenerationId
            $result.SelectionRoot | Should -Be $result.RealizationRoot
            (Test-Path -LiteralPath (Join-Path $result.RealizationRoot 'payload/demo.exe') -PathType Leaf) | Should -BeTrue
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

    It 'rejects a hash-mismatched acquire without publishing partial content' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-failed-realization-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'failed-realization-test'
            $source = Join-Path $temporaryRoot 'source/demo.exe'
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force)
            'demo' | Set-Content -LiteralPath $source -Encoding UTF8
            & $script:Module {
                param($CapsuleRoot, $Source)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                {
                    Acquire-CapsulenvProgramRealization -Name demo -Version 1.0.0 -SourcePath $Source -ExpectedHash ('0' * 64)
                } | Should -Throw
                $placement = Get-CapsulenvHostPlacement -CapsuleId (Get-CapsulenvIdentity)
                @(Get-ChildItem -LiteralPath $placement.PackagesRoot -Filter realization.json -File -Recurse -ErrorAction SilentlyContinue).Count
            } $temporaryRoot $source | Should -Be 0
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

    It 'preserves the previous active generation when a new generation is invalid' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-generation-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'generation-test'
            $source = Join-Path $temporaryRoot 'source/demo.exe'
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force)
            'demo' | Set-Content -LiteralPath $source -Encoding UTF8

            $activeId = & $script:Module {
                param($CapsuleRoot, $Source)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $realization = Acquire-CapsulenvProgramRealization -Name demo -Version 1.0.0 -SourcePath $Source
                $generation = Publish-CapsulenvGeneration -Realizations @($realization)
                [void](Set-CapsulenvActiveGenerationAuthority -GenerationId $generation.GenerationId)
                $generation.GenerationId
            } $temporaryRoot $source

            & $script:Module {
                param($InvalidRoot, $PreviousId)
                { Publish-CapsulenvGeneration -Realizations @([pscustomobject]@{ RealizationRoot = $InvalidRoot }) } | Should -Throw
                (Get-CapsulenvActiveGeneration).Generation.GenerationId | Should -Be $PreviousId
            } (Join-Path $temporaryRoot 'missing-realization') $activeId
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

    It 'detects mutation of a published payload' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-payload-mutation-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'payload-mutation-test'
            $source = Join-Path $temporaryRoot 'source/demo.exe'
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force)
            'demo' | Set-Content -LiteralPath $source -Encoding UTF8
            $root = & $script:Module {
                param($CapsuleRoot, $Source)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                (Acquire-CapsulenvProgramRealization -Name demo -Version 1.0.0 -SourcePath $Source).RealizationRoot
            } $temporaryRoot $source

            'mutated' | Set-Content -LiteralPath (Join-Path $root 'payload/demo.exe') -Encoding UTF8
            Test-CapsulenvProgramRealization -RealizationRoot $root | Should -BeFalse
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

    It 'rejects source mutation between acquisition hash and staging copy' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-source-race-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        $global:CapsulenvRealizationCopyCount = 0
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'source-race-test'
            $source = Join-Path $temporaryRoot 'source/demo.exe'
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force)
            'before' | Set-Content -LiteralPath $source -Encoding UTF8
            $expectedHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
            Mock Copy-Item {
                param(
                    [string]$LiteralPath,
                    [string]$Path,
                    [string]$Destination,
                    [switch]$Recurse,
                    [switch]$Force
                )
                $global:CapsulenvRealizationCopyCount++
                if ($global:CapsulenvRealizationCopyCount -eq 1) {
                    'after' | Set-Content -LiteralPath $source -Encoding UTF8
                }
                if (-not [string]::IsNullOrWhiteSpace($LiteralPath)) {
                    Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
                } else {
                    Microsoft.PowerShell.Management\Copy-Item -Path $Path -Destination $Destination -Recurse:$Recurse -Force:$Force
                }
            } -ModuleName Capsulenv

            & $script:Module {
                param($CapsuleRoot, $Source, $Hash)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                {
                    Acquire-CapsulenvProgramRealization -Name demo -Version 1.0.0 -SourcePath $Source -ExpectedHash $Hash
                } | Should -Throw
            } $temporaryRoot $source $expectedHash
            $global:CapsulenvRealizationCopyCount | Should -Be 1
        } finally {
            Remove-Variable -Name CapsulenvRealizationCopyCount -Scope Global -ErrorAction SilentlyContinue
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

    It 'represents a trusted host program without taking lifecycle ownership' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-host-program-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'host-program-test'
            $executable = Join-Path $temporaryRoot 'scoop/firefox.exe'
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $executable) -Force)
            New-Item -ItemType File -Path $executable -Force | Out-Null
            $result = & $script:Module {
                param($CapsuleRoot, $Executable)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $candidate = [pscustomobject]@{
                    Name = 'firefox'
                    Provider = 'host-scoop'
                    Scope = 'user'
                    Version = '1.0.0'
                    Provenance = 'scoop:user/firefox'
                    Executable = $Executable
                    Root = (Split-Path -Parent $Executable)
                    Trusted = $true
                    OwnsLifecycle = $false
                }
                $generation = Publish-CapsulenvGeneration -Realizations @([pscustomobject]@{
                    Kind = 'host-program'
                    Program = $candidate
                })
                [void](Set-CapsulenvActiveGenerationAuthority -GenerationId $generation.GenerationId)
                Get-CapsulenvActiveGeneration
            } $temporaryRoot $executable

            $result.Generation.Selections[0].Kind | Should -Be 'host-program'
            $result.Generation.Selections[0].Executable | Should -Be ([System.IO.Path]::GetFullPath($executable))
            $result.Generation.Selections[0].OwnsLifecycle | Should -BeFalse
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

    It 'traverses generation-declared pins during reachability collection' {
        $temporaryRoot = Join-Path $TestDrive ('capsulenv-generation-pins-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'generation-pins-test'
            $sourceA = Join-Path $temporaryRoot 'source/a.exe'
            $sourceB = Join-Path $temporaryRoot 'source/b.exe'
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $sourceA) -Force)
            'a' | Set-Content -LiteralPath $sourceA -Encoding UTF8
            'b' | Set-Content -LiteralPath $sourceB -Encoding UTF8
            $result = & $script:Module {
                param($CapsuleRoot, $SourceA, $SourceB)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $a = Acquire-CapsulenvProgramRealization -Name alpha -Version 1.0.0 -SourcePath $SourceA
                $generationA = Publish-CapsulenvGeneration -Realizations @($a)
                $b = Acquire-CapsulenvProgramRealization -Name beta -Version 1.0.0 -SourcePath $SourceB
                $generationB = Publish-CapsulenvGeneration -Realizations @($b) -PinnedGenerationIds @($generationA.GenerationId)
                [void](Set-CapsulenvActiveGenerationAuthority -GenerationId $generationB.GenerationId)
                [pscustomobject]@{
                    PinnedRoot = $a.RealizationRoot
                    Reachable = @(Get-CapsulenvReachableRealizationRoots)
                }
            } $temporaryRoot $sourceA $sourceB

            $result.Reachable | Should -Contain ([System.IO.Path]::GetFullPath($result.PinnedRoot))
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
}
