Describe 'Capsulenv verified portable Scoop shim relocation' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = Get-CapsulenvTestModuleBuild -Root $script:Root
        Import-Module $script:Build.ModulePath -Force -DisableNameChecking
        $script:Module = Get-Module Capsulenv
    }
    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }
    BeforeEach {
        Remove-Item -LiteralPath (Join-Path $TestDrive 'new-capsule') -Recurse -Force -ErrorAction SilentlyContinue
        $script:CapsuleRoot = Join-Path $TestDrive 'new-capsule'
        $script:StateRoot = Join-Path $script:CapsuleRoot '.capsulenv'
        $script:ScoopRoot = Join-Path $script:CapsuleRoot 'scoop'
        $script:GlobalRoot = Join-Path $script:CapsuleRoot 'scoop-global'
        $script:OldScoopRoot = Join-Path (Join-Path $TestDrive 'old-capsule') 'scoop'
        $script:ShimPath = Join-Path $script:ScoopRoot 'shims/git.shim'
        $script:CurrentTarget = Join-Path $script:ScoopRoot 'apps/git/current/bin/git.exe'
        $script:OldTarget = Join-Path $script:OldScoopRoot 'apps/git/current/bin/git.exe'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $script:ShimPath) -Force)
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $script:CurrentTarget) -Force)
        [void](New-Item -ItemType File -Path $script:CurrentTarget -Force)
        ('path = "{0}"' -f $script:OldTarget) | Set-Content -LiteralPath $script:ShimPath -Encoding ASCII

        Mock Get-CapsulenvContext { [pscustomobject]@{ Root=$script:CapsuleRoot; StateRoot=$script:StateRoot } } -ModuleName Capsulenv
        Mock Get-CapsulenvIdentity { 'test-capsule' } -ModuleName Capsulenv
        Mock Get-CapsulenvScoopRoot { $script:ScoopRoot } -ModuleName Capsulenv
        Mock Get-CapsulenvScoopGlobalRoot { $script:GlobalRoot } -ModuleName Capsulenv
        Mock Get-CapsulenvRelocationContext {
            [pscustomobject]@{ PathMappings=@([pscustomobject]@{
                Name='ScoopRoot';OldPath=$script:OldScoopRoot;NewPath=$script:ScoopRoot
            }) }
        } -ModuleName Capsulenv
        Mock Get-CapsulenvLastRelocationContext { $null } -ModuleName Capsulenv
        Mock Get-CapsulenvInstalledScoopApps {
            @([pscustomobject]@{ ProviderScope='User'; Scope='User'; Name='git'; Ready=$true; Selector='scoop:user/git' })
        } -ModuleName Capsulenv
        Mock Get-CapsulenvLegacyScoopLocation { [pscustomobject]@{ AppRoot=(Split-Path -Parent (Split-Path -Parent $script:CurrentTarget)); CurrentRoot=(Split-Path -Parent (Split-Path -Parent $script:CurrentTarget)) } } -ModuleName Capsulenv
        Mock Resolve-CapsulenvLegacyScoopVersionRoot { $script:CurrentTarget } -ModuleName Capsulenv
        Mock Get-CapsulenvScoopAppBins {
            @([pscustomobject]@{ Name='git'; Target=$script:CurrentTarget })
        } -ModuleName Capsulenv
    }

    It 'repairs a previously relocated shim only after checking its installed bin target' {
        $plan = @(& $script:Module { Get-CapsulenvLegacyScoopShimRepairPlan })
        $plan | Should -HaveCount 1
        $plan[0].Status | Should -Be 'Repairable'

        $result = & $script:Module { Repair-CapsulenvLegacyScoopShims }
        $result.Repaired | Should -Be 1
        @($result.Conflicts) | Should -HaveCount 0
        (Get-Content $script:ShimPath -Raw) | Should -Match ([regex]::Escape($script:CurrentTarget))
        (Get-Content $script:ShimPath -Raw) | Should -Not -Match ([regex]::Escape($script:OldTarget))
        @(Get-ChildItem (Join-Path $script:StateRoot 'scoop-shim-backups') -File) | Should -HaveCount 1
        @(& $script:Module { Get-CapsulenvLegacyScoopShimRepairPlan }) | Should -HaveCount 0
    }

    It 'does not overwrite a shim whose previous path lacks matching relocation evidence' {
        'path = "C:\unrelated\git.exe"' | Set-Content -LiteralPath $script:ShimPath -Encoding ASCII
        $plan = @(& $script:Module { Get-CapsulenvLegacyScoopShimRepairPlan })
        $plan | Should -HaveCount 1
        $plan[0].Status | Should -Be 'Conflict'
        $result = & $script:Module { Repair-CapsulenvLegacyScoopShims }
        $result.Repaired | Should -Be 0
        @($result.Conflicts) | Should -HaveCount 1
        (Get-Content $script:ShimPath -Raw) | Should -Match 'C:\\unrelated\\git.exe'
        (Test-Path (Join-Path $script:StateRoot 'scoop-shim-backups')) | Should -BeFalse
    }

    It 'does not modify host Scoop shims or unknown aliases' {
        $hostShim = Join-Path $TestDrive 'host-scoop/shims/git.shim'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $hostShim) -Force)
        'path = "C:\host-scoop\git.exe"' | Set-Content -LiteralPath $hostShim -Encoding ASCII
        $unknownShim = Join-Path (Split-Path -Parent $script:ShimPath) 'custom.shim'
        'path = "C:\foreign\custom.exe"' | Set-Content -LiteralPath $unknownShim -Encoding ASCII
        [void](& $script:Module { Repair-CapsulenvLegacyScoopShims })
        (Get-Content $hostShim -Raw) | Should -Match 'C:\\host-scoop\\git.exe'
        (Get-Content $unknownShim -Raw) | Should -Match 'C:\\foreign\\custom.exe'
    }

    It 'skips the shim inventory after recording the same capsule location' {
        & $script:Module { Sync-CapsulenvLegacyScoopShimsAfterRelocation }
        (Test-Path (Join-Path $script:StateRoot 'scoop-shim-location.json')) | Should -BeTrue
        Mock Repair-CapsulenvLegacyScoopShims { throw 'healthy location must not rebuild shims' } -ModuleName Capsulenv
        { & $script:Module { Sync-CapsulenvLegacyScoopShimsAfterRelocation } } | Should -Not -Throw
        Should -Invoke Repair-CapsulenvLegacyScoopShims -ModuleName Capsulenv -Times 0 -Exactly
    }
    It 'does not inspect or alter a configured Scoop root outside the capsule' {
        $script:ForeignScoopRoot = Join-Path $TestDrive 'host-scoop'
        $foreignShim = Join-Path $script:ForeignScoopRoot 'shims/git.shim'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $foreignShim) -Force)
        ('path = "{0}"' -f $script:OldTarget) | Set-Content -LiteralPath $foreignShim -Encoding ASCII
        Mock Get-CapsulenvScoopRoot { $script:ForeignScoopRoot } -ModuleName Capsulenv
        @(& $script:Module { Get-CapsulenvLegacyScoopShimRepairPlan }) | Should -HaveCount 0
        $result = & $script:Module { Repair-CapsulenvLegacyScoopShims }
        $result.Repaired | Should -Be 0
        (Get-Content $foreignShim -Raw) | Should -Match ([regex]::Escape($script:OldTarget))
    }
}
