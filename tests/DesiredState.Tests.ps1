Describe 'Capsulenv desired-state graph' {
    BeforeAll {
        $script:Root=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')); Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build=& (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean; Import-Module $script:Build.ModulePath -Force; $script:Module=Get-Module Capsulenv
    }
    AfterAll { Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue }
    It 'orders dependencies and executes Plan Apply Verify' {
        $result=& $script:Module {
            $log=New-Object System.Collections.Generic.List[string]
            $a=New-CapsulenvDesiredStateNode -Id a -Plan {param($c)[pscustomobject]@{Operation='Apply';CanApply=$true}} -Apply {param($c,$d)$c.Log.Add('a')|Out-Null;'A'} -Verify {param($c,$d,$o)$o -eq 'A'}
            $b=New-CapsulenvDesiredStateNode -Id b -DependsOn a -Plan {param($c)[pscustomobject]@{Operation='Apply';CanApply=$true}} -Apply {param($c,$d)$c.Log.Add('b')|Out-Null;'B'} -Verify {param($c,$d,$o)$o -eq 'B'}
            $ctx=@{Log=$log}; $plan=Get-CapsulenvDesiredStatePlan -Nodes @($b,$a) -Context $ctx; $runs=@(Invoke-CapsulenvDesiredStatePlan -Plan $plan -Context $ctx)
            [pscustomobject]@{Ids=@($plan.Nodes.Id);Log=@($log);Verified=@($runs.Verified)}
        }
        $result.Ids -join ',' | Should -Be 'a,b'; $result.Log -join ',' | Should -Be 'a,b'; @($result.Verified | Where-Object { -not $_ }).Count | Should -Be 0
    }
    It 'blocks dependents when a dependency cannot apply' {
        $plan=& $script:Module {
            $a=New-CapsulenvDesiredStateNode -Id a -Plan {param($c)[pscustomobject]@{Operation='Blocked';CanApply=$false;Reason='no'}} -Apply {param($c,$d)} -Verify {param($c,$d,$o)$true}
            $b=New-CapsulenvDesiredStateNode -Id b -DependsOn a -Plan {param($c)[pscustomobject]@{Operation='Apply';CanApply=$true}} -Apply {param($c,$d)} -Verify {param($c,$d,$o)$true}
            Get-CapsulenvDesiredStatePlan -Nodes @($a,$b)
        }
        $plan.CanApply | Should -BeFalse; $plan.Nodes[1].Operation | Should -Be 'Blocked'; $plan.Nodes[1].Reason | Should -Match 'a'
    }
}
