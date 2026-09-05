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
    It 'adds actionable remediation when an unexpected node apply error is wrapped' {
        $record = & $script:Module {
            $node = New-CapsulenvDesiredStateNode `
                -Id broken `
                -Plan { param($c) [pscustomobject]@{ Operation='Apply'; CanApply=$true } } `
                -Apply { param($c,$d) throw 'raw fixture failure' } `
                -Verify { param($c,$d,$o) $true }
            $plan = Get-CapsulenvDesiredStatePlan -Nodes @($node)
            try { Invoke-CapsulenvDesiredStatePlan -Plan $plan | Out-Null } catch { $_ }
        }

        $record.FullyQualifiedErrorId | Should -Be 'Capsulenv.DesiredState.ApplyFailed'
        $record.ErrorDetails.Message | Should -Match 'broken'
        $remediation = @(& $script:Module { param($Record) Get-CapsulenvDiagnosticRemediation -ErrorRecord $Record } $record)
        $remediation -join ' ' | Should -Match 'doctor'
        $remediation -join ' ' | Should -Match 'CAPSULENV_DEBUG=1'
        $record.Exception.Message | Should -Not -Match 'raw fixture failure'
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

    It 'reports dependency-ordered resource conflicts as serialized diagnostics' {
        $diagnostics = & $script:Module {
            $writer=New-CapsulenvDesiredStateNode -Id writer -WriteResources @('capsule:///state/shared') -Plan {param($c)[pscustomobject]@{Operation='Apply';CanApply=$true}} -Apply {param($c,$d)} -Verify {param($c,$d,$o)$true}
            $reader=New-CapsulenvDesiredStateNode -Id reader -DependsOn writer -ReadResources @('capsule:///state/shared') -Plan {param($c)[pscustomobject]@{Operation='Apply';CanApply=$true}} -Apply {param($c,$d)} -Verify {param($c,$d,$o)$true}
            (Get-CapsulenvDesiredStatePlan -Nodes @($writer,$reader)).OwnershipDiagnostics
        }
        @($diagnostics.SerializedConflicts) | Should -HaveCount 1
        $diagnostics.SerializedConflicts[0].OrderedByDependency | Should -BeTrue
        @($diagnostics.UnorderedWriteWrite) | Should -HaveCount 0
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

Describe 'Capsulenv desired-state parallel execution' {
    BeforeAll {
        $script:Root=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')); Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build=& (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean; Import-Module $script:Build.ModulePath -Force; $script:Module=Get-Module Capsulenv
    }
    AfterAll { Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue }

    It 'treats ancestor and descendant write/read claims as conflicting resources' {
        $waves = & $script:Module {
            $writer=New-CapsulenvDesiredStateNode -Id writer -WriteResources @('capsule:///tool-data') -Plan {param($c)[pscustomobject]@{Operation='Apply';CanApply=$true}} -Apply {param($c,$d)} -Verify {param($c,$d,$o)$true}
            $reader=New-CapsulenvDesiredStateNode -Id reader -ReadResources @('capsule:///tool-data/python/cache') -Plan {param($c)[pscustomobject]@{Operation='Apply';CanApply=$true}} -Apply {param($c,$d)} -Verify {param($c,$d,$o)$true}
            $plan=Get-CapsulenvDesiredStatePlan -Nodes @($writer,$reader)
            [pscustomobject]@{ Waves=@($plan.ExecutionWaves | ForEach-Object { @($_.NodeIds) -join ',' }); Conflicts=@($plan.ResourceConflicts) }
        }
        $waves.Waves.Count | Should -Be 2
        $waves.Conflicts | Should -HaveCount 1
        $waves.Conflicts[0].Kind | Should -Be 'ReadWrite'
        $waves.Conflicts[0].OrderedByDependency | Should -BeFalse
    }

    It 'requires parallel-safe nodes to declare claims' {
        $record = & $script:Module {
            try {
                $node=New-CapsulenvDesiredStateNode -Id unsafe -ParallelSafe -Plan {param($c)[pscustomobject]@{Operation='Apply';CanApply=$true}} -Apply {param($c,$d)} -Verify {param($c,$d,$o)$true}
                Get-CapsulenvDesiredStatePlan -Nodes @($node) | Out-Null
            } catch { $_ }
        }
        $record.FullyQualifiedErrorId | Should -Be 'Capsulenv.DesiredState.ParallelClaimsRequired'
    }

    It 'keeps process-scoped mutations out of parallel worker runspaces' {
        $record = & $script:Module {
            try {
                $node=New-CapsulenvDesiredStateNode -Id process -ParallelSafe -WriteResources @('process:///environment') -Plan {param($c)[pscustomobject]@{Operation='Apply';CanApply=$true}} -Apply {param($c,$d)} -Verify {param($c,$d,$o)$true}
                Get-CapsulenvDesiredStatePlan -Nodes @($node) | Out-Null
            } catch { $_ }
        }
        $record.FullyQualifiedErrorId | Should -Be 'Capsulenv.DesiredState.ParallelProcessResource'
    }

    It 'runs claim-safe peers concurrently and publishes their outputs before the next dependency wave' {
        $result = & $script:Module {
            $barrier=[System.Threading.Barrier]::new(2)
            try {
                $a=New-CapsulenvDesiredStateNode -Id a -ParallelSafe -WriteResources @('capsule:///cache/a') -Plan {param($c)[pscustomobject]@{Operation='Apply';CanApply=$true}} -Apply {param($c,$d) if(-not $c.Barrier.SignalAndWait(5000)){throw 'a did not overlap'};'A'} -Verify {param($c,$d,$o)$o -eq 'A'}
                $b=New-CapsulenvDesiredStateNode -Id b -ParallelSafe -WriteResources @('capsule:///cache/b') -Plan {param($c)[pscustomobject]@{Operation='Apply';CanApply=$true}} -Apply {param($c,$d) if(-not $c.Barrier.SignalAndWait(5000)){throw 'b did not overlap'};'B'} -Verify {param($c,$d,$o)$o -eq 'B'}
                $c=New-CapsulenvDesiredStateNode -Id c -DependsOn @('a','b') -ReadResources @('capsule:///cache/a','capsule:///cache/b') -Plan {param($c)[pscustomobject]@{Operation='Apply';CanApply=$true}} -Apply {param($c,$d) ([string]$c.Outputs['a']) + ([string]$c.Outputs['b'])} -Verify {param($c,$d,$o)$o -eq 'AB'}
                $ctx=@{Barrier=$barrier};$plan=Get-CapsulenvDesiredStatePlan -Nodes @($a,$b,$c) -Context $ctx
                $runs=@(Invoke-CapsulenvDesiredStatePlan -Plan $plan -Context $ctx -ExecutionMode Auto -ThrottleLimit 2)
                [pscustomobject]@{ Outputs=@($runs.Output); Waves=@($plan.ExecutionWaves | ForEach-Object { @($_.NodeIds) -join ',' }) }
            } finally { $barrier.Dispose() }
        }
        $result.Waves[0] | Should -Be 'a,b'
        $result.Outputs[-1] | Should -Be 'AB'
    }
}

Describe 'Capsulenv desired-state module worker boundary' {
    BeforeAll {
        $script:Root=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')); Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build=& (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean; Import-Module $script:Build.ModulePath -Force; $script:Module=Get-Module Capsulenv
    }
    AfterAll { Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue }
    It 'preserves Capsulenv private command resolution inside parallel worker runspaces' {
        $result = & $script:Module {
            $a=New-CapsulenvDesiredStateNode -Id a -ParallelSafe -ReadResources @('capsule:///config/a') -Plan {param($c)[pscustomobject]@{Operation='Apply';CanApply=$true}} -Apply {param($c,$d) Get-CapsulenvInstallMode} -Verify {param($c,$d,$o) $o -in @('ShellOnly','User')}
            $b=New-CapsulenvDesiredStateNode -Id b -ParallelSafe -ReadResources @('capsule:///config/b') -Plan {param($c)[pscustomobject]@{Operation='Apply';CanApply=$true}} -Apply {param($c,$d) Get-CapsulenvInstallMode} -Verify {param($c,$d,$o) $o -in @('ShellOnly','User')}
            $plan=Get-CapsulenvDesiredStatePlan -Nodes @($a,$b)
            @(Invoke-CapsulenvDesiredStatePlan -Plan $plan -ExecutionMode Parallel -ThrottleLimit 2).Output
        }
        @($result).Count | Should -Be 2
        @($result | Where-Object { $_ -notin @('ShellOnly','User') }).Count | Should -Be 0
    }
}
