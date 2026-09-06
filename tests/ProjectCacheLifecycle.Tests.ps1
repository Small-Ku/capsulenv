Describe 'Capsulenv project-cache lifecycle' {
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

    BeforeEach {
        $script:Capsule = Join-Path $TestDrive ('capsule-' + [Guid]::NewGuid().ToString('N'))
        $script:Project = Join-Path $TestDrive ('project-' + [Guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path (Join-Path $script:Capsule 'config') -Force)
        [void](New-Item -ItemType Directory -Path $script:Project -Force)
        Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $script:Capsule 'config/capsulenv.psd1')
        $env:CAPSULENV_ROOT = $script:Capsule
        & $script:Module {
            param($CapsuleRoot)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            [void](Get-CapsulenvConfiguration -Refresh)
        } $script:Capsule
        $script:LinkType = if ($env:OS -eq 'Windows_NT') { 'Junction' } else { 'SymbolicLink' }
    }

    AfterEach {
        $env:CAPSULENV_ROOT = $null
    }

    It 'records ownership when the managed link is created' {
        $created = New-CapsulenvProjectCacheLink `
            -Profile 'cargo-target' `
            -ProjectPath $script:Project `
            -LinkType $script:LinkType

        $created.Changed | Should -BeTrue
        $records = @(Get-CapsulenvManagedProjectCacheLinks)
        $records | Should -HaveCount 1
        $records[0].Profile | Should -Be 'cargo-target'
        $records[0].ProjectReference | Should -Be ([System.IO.Path]::GetFullPath($script:Project))
        $status = @(Get-CapsulenvProjectCacheStatus -ProjectPath $script:Project)
        $managed = @($status | Where-Object Profile -eq 'cargo-target')
        $managed | Should -HaveCount 1
        $managed[0].Linked | Should -BeTrue
    }

    It 'removes registry ownership at unlink time instead of relying on later activation repair' {
        [void](New-CapsulenvProjectCacheLink `
            -Profile 'cargo-target' `
            -ProjectPath $script:Project `
            -LinkType $script:LinkType)

        $removed = Remove-CapsulenvProjectCacheLink -Profile 'cargo-target' -ProjectPath $script:Project -Restore
        $removed.Restored | Should -BeTrue
        @(Get-CapsulenvManagedProjectCacheLinks) | Should -HaveCount 0
        Test-Path -LiteralPath (Join-Path $script:Project 'target') -PathType Container | Should -BeTrue
    }
}
