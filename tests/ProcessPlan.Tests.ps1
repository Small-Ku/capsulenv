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
    It 'records and completes the exact interactive child instead of the controller process' {
        $hostExecutable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $capsuleRoot = Join-Path $TestDrive 'owned-child'
        $result = & $script:Module {
            param($Executable, $CapsuleRoot)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            $plan = New-CapsulenvProcessPlan -Executable $Executable -Arguments @('-NoLogo', '-NoProfile', '-Command', 'exit 0')
            $launch = Invoke-CapsulenvOwnedProcessPlan -Plan $plan -Role child-shell -Provenance test
            [pscustomobject]@{
                ControllerPid = $PID
                ChildPid = $launch.ProcessId
                LedgerPid = $launch.ProcessRecord.PID
                HasNonce = -not [string]::IsNullOrWhiteSpace([string]$launch.ProcessRecord.ProcessNonce)
                ChildResidue = @(Get-CapsulenvOwnedProcessRecords | Where-Object { [int]$_.PID -eq [int]$launch.ProcessId }).Count
            }
        } $hostExecutable $capsuleRoot

        $result.ChildPid | Should -Not -Be $result.ControllerPid
        $result.LedgerPid | Should -Be $result.ChildPid
        $result.HasNonce | Should -BeTrue
        $result.ChildResidue | Should -Be 0
    }

    It 'does not kill a reused PID when registration fails after spawn' {
        InModuleScope Capsulenv {
            $script:registrationIdentityCalls = 0
            Mock Start-Process { [pscustomobject]@{ Id = 4242 } }
            Mock Get-CapsulenvProcessStartIdentity {
                $script:registrationIdentityCalls++
                if ($script:registrationIdentityCalls -eq 1) { return 'spawned-identity' }
                return 'reused-identity'
            }
            Mock Initialize-CapsulenvOwnedChildSession { throw 'registration failed' }
            Mock Stop-Process {}
            $plan = New-CapsulenvProcessPlan -Executable 'tool.exe'
            { Invoke-CapsulenvOwnedProcessPlan -Plan $plan } | Should -Throw '*registration failed*'
            Should -Invoke Stop-Process -Times 0 -Exactly
        }
    }
}
