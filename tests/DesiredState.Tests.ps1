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

Describe 'Capsulenv desired-state resource claims' {
    BeforeAll {
        $script:Root=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')); Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build=& (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean; Import-Module $script:Build.ModulePath -Force; $script:Module=Get-Module Capsulenv
    }
    AfterAll { Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue }

    It 'normalizes claims and keeps read-only peers in the same execution wave' {
        $result = & $script:Module {
            $a=New-CapsulenvDesiredStateNode -Id a -ReadResources @('CAPSULE:///Tool-Data/') -Plan {param($c)[pscustomobject]@{Operation='Apply';CanApply=$true}} -Apply {param($c,$d)} -Verify {param($c,$d,$o)$true}
            $b=New-CapsulenvDesiredStateNode -Id b -ReadResources @('capsule:///Tool-Data') -Plan {param($c)[pscustomobject]@{Operation='Apply';CanApply=$true}} -Apply {param($c,$d)} -Verify {param($c,$d,$o)$true}
            $plan=Get-CapsulenvDesiredStatePlan -Nodes @($a,$b)
            [pscustomobject]@{ Claims=@($plan.ResourceClaims.ResourceUri); Waves=@($plan.ExecutionWaves | ForEach-Object { @($_.NodeIds) -join ',' }) }
        }
        @($result.Claims | Where-Object { $_ -eq 'capsule:///Tool-Data' }).Count | Should -Be 2
        $result.Waves.Count | Should -Be 1
        $result.Waves[0] | Should -Be 'a,b'
    }

    It 'separates independent nodes when a write claim conflicts with a read claim' {
        $waves = & $script:Module {
            $writer=New-CapsulenvDesiredStateNode -Id writer -WriteResources @('capsule:///tool-data') -Plan {param($c)[pscustomobject]@{Operation='Apply';CanApply=$true}} -Apply {param($c,$d)} -Verify {param($c,$d,$o)$true}
            $reader=New-CapsulenvDesiredStateNode -Id reader -ReadResources @('capsule:///tool-data') -Plan {param($c)[pscustomobject]@{Operation='Apply';CanApply=$true}} -Apply {param($c,$d)} -Verify {param($c,$d,$o)$true}
            @(Get-CapsulenvDesiredStatePlan -Nodes @($writer,$reader)).ExecutionWaves | ForEach-Object { @($_.NodeIds) -join ',' }
        }
        @($waves).Count | Should -Be 2
        $waves[0] | Should -Be 'writer'
        $waves[1] | Should -Be 'reader'
    }

    It 'does not let a no-op dependency collapse transitive execution ordering' {
        $waves = & $script:Module {
            $a=New-CapsulenvDesiredStateNode -Id a -Plan {param($c)[pscustomobject]@{Operation='Apply';CanApply=$true}} -Apply {param($c,$d)} -Verify {param($c,$d,$o)$true}
            $b=New-CapsulenvDesiredStateNode -Id b -DependsOn a -Plan {param($c)[pscustomobject]@{Operation='NoOp';CanApply=$true}} -Apply {param($c,$d)} -Verify {param($c,$d,$o)$true}
            $c=New-CapsulenvDesiredStateNode -Id c -DependsOn b -Plan {param($c)[pscustomobject]@{Operation='Apply';CanApply=$true}} -Apply {param($c,$d)} -Verify {param($c,$d,$o)$true}
            @(Get-CapsulenvDesiredStatePlan -Nodes @($a,$b,$c)).ExecutionWaves | ForEach-Object { @($_.NodeIds) -join ',' }
        }
        @($waves).Count | Should -Be 2
        $waves[0] | Should -Be 'a'
        $waves[1] | Should -Be 'c'
    }

    It 'rejects unstable non-URI resource claims with a stable diagnostic id' {
        $record = & $script:Module {
            try {
                New-CapsulenvDesiredStateNode -Id broken -WriteResources @('tool-data') -Plan {param($c)[pscustomobject]@{Operation='Apply';CanApply=$true}} -Apply {param($c,$d)} -Verify {param($c,$d,$o)$true} | Out-Null
            } catch { $_ }
        }
        $record.FullyQualifiedErrorId | Should -Be 'Capsulenv.DesiredState.ResourceUriInvalid'
    }
}
