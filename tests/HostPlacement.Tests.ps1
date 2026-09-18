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
        $capsuleRoot = Join-Path $temporaryRoot 'capsule'
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $capsuleRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $capsuleRoot 'config/capsulenv.psd1')
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
            } $capsuleRoot
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
        $capsuleRoot = Join-Path $temporaryRoot 'capsule'
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $capsuleRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $capsuleRoot 'config/capsulenv.psd1')
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'boot-a'
            $persistentRoot = Join-Path $temporaryRoot 'nvme'

            & $script:Module {
                param($CapsuleRoot, $PersistentRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                {
                    Set-CapsulenvHostEnrollment -EnrollmentTag 'invalid' -Retention persistent -PlacementRoot (Join-Path $CapsuleRoot 'nvme')
                } | Should -Throw '*must not equal or descend*'
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
            } $capsuleRoot $persistentRoot
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

    It 'recovers an ephemeral placement whose marker was never published' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-stale-' + [Guid]::NewGuid().ToString('N'))
        $capsuleRoot = Join-Path $temporaryRoot 'capsule'
        $oldStateRoot = $env:CAPSULENV_HOST_STATE_ROOT
        $oldBootEpoch = $env:CAPSULENV_HOST_BOOT_EPOCH
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $capsuleRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $capsuleRoot 'config/capsulenv.psd1')
            $env:CAPSULENV_HOST_STATE_ROOT = Join-Path $temporaryRoot 'host-state'
            $env:CAPSULENV_HOST_BOOT_EPOCH = 'stale-epoch'

            & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                $first = Initialize-CapsulenvHostPlacement -CapsuleId 'capsule-test'
                Remove-Item -LiteralPath $first.MarkerPath -Force
                $second = Initialize-CapsulenvHostPlacement -CapsuleId 'capsule-test'
                $second.Valid | Should -BeTrue
                @(Get-ChildItem -LiteralPath (Split-Path -Parent $first.Root) -Directory -Filter '*.stale-*').Count | Should -Be 1
            } $capsuleRoot
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

    It 'uses optional GDID evidence without making enrollment implicit' {
        Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
        Mock Get-ItemProperty {
            [pscustomobject]@{ LID = [UInt64]123456789 }
        } -ModuleName Capsulenv

        $evidence = & $script:Module { Get-CapsulenvHostIdentityEvidence }
        $evidence.WindowsGdid.Available | Should -BeTrue
        $evidence.WindowsGdid.Strength | Should -Be 'strong'
        $evidence.WindowsGdid.Value | Should -Be '123456789'
        $evidence.MachineUser.Available | Should -BeTrue

        Mock Get-ItemProperty { throw 'GDID unavailable' } -ModuleName Capsulenv
        $fallback = & $script:Module { Get-CapsulenvHostIdentityEvidence }
        $fallback.WindowsGdid.Available | Should -BeFalse
        $fallback.MachineUser.Available | Should -BeTrue
    }

    It 'keeps the primary host key stable when optional GDID evidence flaps' {
        Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
        Mock Get-ItemProperty {
            [pscustomobject]@{ LID = [UInt64]123456789 }
        } -ModuleName Capsulenv

        $withGdid = & $script:Module {
            [pscustomobject]@{
                Key = Get-CapsulenvHostKey
                Digest = Get-CapsulenvHostIdentityDigest
            }
        }

        Mock Get-ItemProperty { throw 'GDID temporarily unavailable' } -ModuleName Capsulenv
        $withoutGdid = & $script:Module {
            [pscustomobject]@{
                Key = Get-CapsulenvHostKey
                Digest = Get-CapsulenvHostIdentityDigest
            }
        }

        Mock Get-ItemProperty {
            [pscustomobject]@{ LID = [UInt64]123456789 }
        } -ModuleName Capsulenv
        $again = & $script:Module {
            [pscustomobject]@{
                Key = Get-CapsulenvHostKey
                Digest = Get-CapsulenvHostIdentityDigest
            }
        }

        $withoutGdid.Key | Should -Be $withGdid.Key
        $again.Key | Should -Be $withGdid.Key
        $withoutGdid.Digest | Should -Be $withGdid.Digest
        $again.Digest | Should -Be $withGdid.Digest
    }

    It 'keeps host identity independent from portable root relocation' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-identity-' + [Guid]::NewGuid().ToString('N'))
        try {
            $first = & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                [pscustomobject]@{ Key = Get-CapsulenvHostKey; Digest = Get-CapsulenvHostIdentityDigest }
            } (Join-Path $temporaryRoot 'capsule-a')
            $second = & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                [pscustomobject]@{ Key = Get-CapsulenvHostKey; Digest = Get-CapsulenvHostIdentityDigest }
            } (Join-Path $temporaryRoot 'capsule-b')

            $second.Key | Should -Be $first.Key
            $second.Digest | Should -Be $first.Digest
        } finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

    It 'uses a CIM DateTime directly and caches an unavailable Windows epoch' {
        $source = Get-Content -LiteralPath (Join-Path $script:Root 'src/07-HostPlacement.ps1') -Raw
        $source | Should -Match '\$rawLastBoot -is \[DateTime\]'
        Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
        & $script:Module { $script:CapsulenvUnavailableBootEpoch = $null }
        $fallback = & $script:Module {
            [pscustomobject]@{
                First = Get-CapsulenvHostBootEpoch
                Second = Get-CapsulenvHostBootEpoch
            }
        }
        $fallback.First | Should -Be $fallback.Second
        $fallback.First | Should -Match '^unavailable-'

    It 'fails closed when portable identity authority is corrupt' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-corrupt-identity-' + [Guid]::NewGuid().ToString('N'))
        $capsuleRoot = Join-Path $temporaryRoot 'capsule'
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $capsuleRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $capsuleRoot 'config/capsulenv.psd1')
            $identityRoot = Join-Path $capsuleRoot '.capsulenv'
            [void](New-Item -ItemType Directory -Path $identityRoot -Force)
            $identityPath = Join-Path $identityRoot 'identity.json'
            $original = '{"SchemaVersion":1,"Id":"not-a-guid"}'
            Set-Content -LiteralPath $identityPath -Value $original -Encoding UTF8

            & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                { Get-CapsulenvIdentity } | Should -Throw '*Refusing to replace*'
            } $capsuleRoot

            (Get-Content -LiteralPath $identityPath -Raw).Trim() | Should -Be $original
        } finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

    It 'does not contain a destructive identity replacement fallback' {
        $source = Get-Content -LiteralPath (Join-Path $script:Root 'src/05-Identity.ps1') -Raw
        $source | Should -Not -Match "Remove-Item -LiteralPath \\$path"
        $source | Should -Match 'previous valid identity was retained'
    }
    }
}
