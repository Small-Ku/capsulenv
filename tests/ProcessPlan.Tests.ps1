Describe 'Capsulenv process plans' {
    BeforeAll { $script:Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')); Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue; $script:Build=& (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean; Import-Module $script:Build.ModulePath -Force; $script:Module=Get-Module Capsulenv }
    AfterAll { Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue }
    It 'applies child environment path and cwd then restores the parent' {
        $hostExecutable=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName; $work=Join-Path $TestDrive work; $pathEntry=Join-Path $TestDrive path; New-Item -ItemType Directory -Path $work,$pathEntry -Force|Out-Null
        $old=$env:CAPSULENV_PROCESS_PLAN_TEST; $oldPath=$env:PATH; $oldLocation=(Get-Location).Path
        try {
            $output=& $script:Module {param($exe,$work,$path) $p=New-CapsulenvProcessPlan -Executable $exe -Arguments @('-NoLogo','-NoProfile','-Command','[Console]::Out.WriteLine($env:CAPSULENV_PROCESS_PLAN_TEST); [Console]::Out.WriteLine((Get-Location).Path); [Console]::Out.WriteLine($env:PATH); exit 7') -WorkingDirectory $work -Environment ([ordered]@{CAPSULENV_PROCESS_PLAN_TEST='child'}) -PathEntries @($path); Invoke-CapsulenvProcessPlan -Plan $p } $hostExecutable $work $pathEntry
            [string]@($output)[0]|Should -Be 'child'; [string]@($output)[1]|Should -Be ([IO.Path]::GetFullPath($work)); [string]@($output)[2]|Should -Match ([regex]::Escape([IO.Path]::GetFullPath($pathEntry))); $global:LASTEXITCODE|Should -Be 7
            $env:PATH|Should -Be $oldPath; (Get-Location).Path|Should -Be $oldLocation; $env:CAPSULENV_PROCESS_PLAN_TEST|Should -Be $old
        } finally { $env:PATH=$oldPath; if($null -eq $old){Remove-Item Env:CAPSULENV_PROCESS_PLAN_TEST -ErrorAction SilentlyContinue}else{$env:CAPSULENV_PROCESS_PLAN_TEST=$old} }
    }
    It 'keeps a small inspectable object contract' {
        $plan=& $script:Module { New-CapsulenvProcessPlan -Executable 'tool.exe' -Arguments @('a') -ExecutionMode Detached -Metadata ([ordered]@{Owner='test'}) }
        $plan.PSTypeNames | Should -Contain 'Capsulenv.ProcessPlan'; $plan.Executable|Should -Be 'tool.exe'; $plan.ExecutionMode|Should -Be 'Detached'; $plan.Metadata.Owner|Should -Be 'test'
    }
}
