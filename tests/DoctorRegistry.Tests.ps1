Describe 'Capsulenv doctor registry' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = Get-CapsulenvTestModuleBuild -Root $script:Root
        Import-Module $script:Build.ModulePath -Force
        $script:Module = Get-Module Capsulenv
    }
    AfterAll { Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue }

    It 'runs subsystem registered checks as object-first results' {
        $results = @(& $script:Module { Invoke-CapsulenvDoctorChecks -Ids @(
            'Capsulenv.Doctor.ProjectCache.Registry',
            'Capsulenv.Doctor.ToolWorkspace.Registry',
            'Capsulenv.Doctor.Package.OwnershipRoots',
            'Capsulenv.Doctor.Scoop.Root',
            'Capsulenv.Doctor.Scoop.Command',
            'Capsulenv.Doctor.Scoop.ProjectionRepairState',
            'Capsulenv.Doctor.Relocation.Rehydration',
            'Capsulenv.Doctor.Relocation.PersistRepair',
            'Capsulenv.Doctor.HostIntegration.PackageLauncher'
        ) })
        $results.Count | Should -Be 9
        @($results.Id) | Should -Contain 'Capsulenv.Doctor.Package.OwnershipRoots'
        @($results.Id) | Should -Contain 'Capsulenv.Doctor.Scoop.ProjectionRepairState'
        @($results.Id) | Should -Contain 'Capsulenv.Doctor.Relocation.PersistRepair'
        @($results.Id) | Should -Contain 'Capsulenv.Doctor.HostIntegration.PackageLauncher'
        @($results.Status | Where-Object { $_ -notin @('Healthy','Advisory','Unavailable','Failed','Skipped') }).Count | Should -Be 0
    }

    It 'isolates a failing registered check' {
        $result = & $script:Module {
            $id = 'Capsulenv.Doctor.Test.Failure'
            Register-CapsulenvDoctorCheck -Id $id -Area Test -Name 'failure isolation' -Importance Optional -Handler { throw 'boom' }
            Invoke-CapsulenvDoctorChecks -Ids @($id)
        }
        $result.Status | Should -Be 'Failed'
        $result.Summary | Should -Match 'boom'
    }
}
