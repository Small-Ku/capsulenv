Describe 'Capsulenv host identity and placement foundation' {
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

    It 'defaults to an ephemeral host placement that is reusable within one boot epoch' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-host-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $temporaryRoot 'config/capsulenv.psd1')
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'boot-a'

            & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $first = Get-CapsulenvHostPlacement -CapsuleId 'capsule-test'
                $second = Get-CapsulenvHostPlacement -CapsuleId 'capsule-test'

                $first.Retention | Should -Be 'ephemeral'
                $first.Enrolled | Should -BeFalse
                $first.Root | Should -Not -BeLike "$CapsuleRoot*"
                $first.Root | Should -Match 'boot-a'
                $second.Root | Should -Be $first.Root
                $first.Valid | Should -BeFalse

                $materialized = Initialize-CapsulenvHostPlacement -CapsuleId 'capsule-test'
                $materialized.Valid | Should -BeTrue
                (Test-Path -LiteralPath $materialized.PackagesRoot -PathType Container) | Should -BeTrue
                (Test-Path -LiteralPath $materialized.GenerationsRoot -PathType Container) | Should -BeTrue
                (Test-Path -LiteralPath $materialized.StateRoot -PathType Container) | Should -BeTrue
            } $temporaryRoot
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
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

    It 'requires explicit enrollment before selecting persistent host storage' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-home-' + [Guid]::NewGuid().ToString('N'))
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $temporaryRoot 'config/capsulenv.psd1')
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'boot-a'
            $persistentRoot = Join-Path $temporaryRoot 'nvme'

            & $script:Module {
                param($CapsuleRoot, $PersistentRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $enrollment = Set-CapsulenvHostEnrollment -EnrollmentTag 'home' -Retention persistent -PlacementRoot $PersistentRoot
                $record = Get-CapsulenvHostRecord
                $first = Get-CapsulenvHostPlacement -CapsuleId 'capsule-test'

                $enrollment.Tag | Should -Be 'home'
                $record.Enrolled | Should -BeTrue
                $record.Retention | Should -Be 'persistent'
                $record.PlacementRoot | Should -Be ([System.IO.Path]::GetFullPath($PersistentRoot))
                $first.Retention | Should -Be 'persistent'
                $first.Root | Should -Be ([System.IO.Path]::GetFullPath((Join-Path (Join-Path $PersistentRoot 'capsules') 'capsule-test')))

                $env:CAPSULENV_HOST_BOOT_EPOCH = 'boot-b'
                $second = Get-CapsulenvHostPlacement -CapsuleId 'capsule-test'
                $second.Root | Should -Be $first.Root
                (Initialize-CapsulenvHostPlacement -CapsuleId 'capsule-test').Valid | Should -BeTrue
            } $temporaryRoot $persistentRoot
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
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }
}
