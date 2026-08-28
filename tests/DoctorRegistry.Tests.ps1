Describe 'Capsulenv doctor registry' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force
        $script:Module = Get-Module Capsulenv
    }
    AfterAll { Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue }

    It 'runs subsystem registered checks as object-first results' {
        $results = @(& $script:Module { Invoke-CapsulenvDoctorChecks -Ids @('Capsulenv.Doctor.ProjectCache.Registry','Capsulenv.Doctor.ToolWorkspace.Registry','Capsulenv.Doctor.Package.OwnershipRoots') })
        $results.Count | Should -Be 3
        @($results.Id) | Should -Contain 'Capsulenv.Doctor.Package.OwnershipRoots'
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
