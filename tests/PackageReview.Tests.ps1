Describe 'Capsulenv package TrustedExecution review' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = Get-CapsulenvTestModuleBuild -Root $script:Root
        Import-Module $script:Build.ModulePath -Force
        $script:Module = @(Get-Module Capsulenv)[-1]
    }

    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $script:Capsule = Join-Path $TestDrive ('capsule-' + [Guid]::NewGuid().ToString('N'))
        foreach ($directory in @('config', 'scoop/buckets/main/bucket')) {
            [void](New-Item -ItemType Directory -Path (Join-Path $script:Capsule $directory) -Force)
        }
        Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $script:Capsule 'config/capsulenv.psd1')
        $env:CAPSULENV_ROOT = $script:Capsule
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'
        & $script:Module {
            param($CapsuleRoot)
            Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
            [void](Get-CapsulenvConfiguration -Refresh)
        } $script:Capsule
    }

    AfterEach {
        Remove-Item Env:CAPSULENV_ROOT -ErrorAction SilentlyContinue
    }

    It 'shows the effective architecture lifecycle scripts and external installer surface with source hashes' {
        @{
            version = '1.0.0'
            url = 'https://example.invalid/helper.exe'
            hash = ('b' * 64)
            installer = @{ args = @('/quiet'); file = 'helper.exe' }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/helper.json') -Encoding UTF8

        @{
            version = '2.0.0'
            url = 'https://example.invalid/demo.zip'
            hash = ('a' * 64)
            post_install = 'Write-Output root-script-must-be-overridden'
            depends = @('helper')
            architecture = @{
                '64bit' = @{
                    post_install = @(
                        'Write-Output architecture-script',
                        'Set-ItemProperty HKCU:\Software\Demo Enabled 1'
                    )
                }
            }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/demo.json') -Encoding UTF8

        $review = & $script:Module { Get-CapsulenvPackageReviewPlan -Reference demo }
        $review.RequestReference | Should -Be 'demo'
        $review.Operation | Should -Be 'Install'
        $review.ReviewRequired | Should -BeTrue
        $review.Classification | Should -Be 'TrustedExecutionRequired'
        $review.Packages | Should -HaveCount 2

        $demo = @($review.Packages | Where-Object Reference -eq 'main/demo')[0]
        $helper = @($review.Packages | Where-Object Reference -eq 'main/helper')[0]
        $demo.ManifestSha256 | Should -Match '^[0-9a-f]{64}$'
        $helper.ManifestSha256 | Should -Match '^[0-9a-f]{64}$'
        $demoItem = @($demo.ReviewItems | Where-Object Field -eq 'architecture.64bit.post_install')[0]
        $demoItem.Kind | Should -Be 'LifecycleScript'
        ($demoItem.Lines -join "`n") | Should -Match 'architecture-script'
        ($demoItem.Lines -join "`n") | Should -Not -Match 'root-script-must-be-overridden'
        @($helper.ReviewItems | Where-Object Field -eq 'installer').Kind | Should -Contain 'ExternalInstaller'
        ($review.Checklist -join ' ') | Should -Match 'network endpoint'
        $review.RecommendedAction | Should -Match '--allow-trusted'
    }

    It 'returns a clean no-review decision for a fully PortableSafe graph' {
        @{
            version = '1.0.0'
            url = 'https://example.invalid/demo.exe'
            hash = ('a' * 64)
            bin = 'demo.exe'
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/demo.json') -Encoding UTF8

        $review = & $script:Module { Get-CapsulenvPackageReviewPlan -Reference demo }
        $review.ReviewRequired | Should -BeFalse
        $review.ExecutionBoundary | Should -Be 'PortableSafe'
        $review.Packages | Should -HaveCount 0
        $review.RecommendedAction | Should -Match 'app install demo'
    }

    It 'reviews the current bucket manifest for an upstream Scoop-owned update selector' {
        $installedCurrent = Join-Path $script:Capsule 'scoop/apps/demo/current'
        [void](New-Item -ItemType Directory -Path $installedCurrent -Force)
        @{
            version = '1.0.0'
            url = 'https://example.invalid/demo-old.exe'
            hash = ('c' * 64)
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $installedCurrent 'manifest.json') -Encoding UTF8
        @{ bucket='main'; architecture='64bit' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $installedCurrent 'install.json') -Encoding UTF8

        @{
            version = '2.0.0'
            url = 'https://example.invalid/demo-new.exe'
            hash = ('d' * 64)
            post_install = 'Write-Output new-update-script'
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/demo.json') -Encoding UTF8

        $review = & $script:Module { Get-CapsulenvPackageReviewPlan -Reference 'user/demo' }
        $review.RequestReference | Should -Be 'scoop:user/demo'
        $review.Reference | Should -Be 'main/demo'
        $review.Operation | Should -Be 'Update'
        $review.ExecutionBoundary | Should -Be 'TrustedExecution'
        $review.ReviewRequired | Should -BeTrue
        $review.InstalledSelector | Should -Be 'scoop:user/demo'
        $review.Packages[0].Version | Should -Be '2.0.0'
        ($review.Packages[0].ReviewItems[0].Lines -join ' ') | Should -Match 'new-update-script'
        $review.RecommendedAction | Should -Match 'app update scoop:user/demo --allow-trusted'
    }

    It 'keeps upstream ownership as a TrustedExecution review boundary even when the new manifest is declarative' {
        $installedCurrent = Join-Path $script:Capsule 'scoop/apps/demo/current'
        [void](New-Item -ItemType Directory -Path $installedCurrent -Force)
        @{ version='1.0.0'; url='https://example.invalid/old.exe'; hash=('a' * 64) } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $installedCurrent 'manifest.json') -Encoding UTF8
        @{ bucket='main'; architecture='64bit' } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $installedCurrent 'install.json') -Encoding UTF8
        @{ version='2.0.0'; url='https://example.invalid/new.exe'; hash=('b' * 64); bin='demo.exe' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/demo.json') -Encoding UTF8

        $review = & $script:Module { Get-CapsulenvPackageReviewPlan -Reference 'user/demo' }
        $review.Classification | Should -Be 'PortableSafe'
        $review.ExecutionBoundary | Should -Be 'TrustedExecution'
        $review.ReviewRequired | Should -BeTrue
        $review.Packages | Should -HaveCount 1
        ($review.Packages[0].Reasons -join ' ') | Should -Match 'upstream Scoop-owned'
        $review.RecommendedAction | Should -Match 'app update scoop:user/demo --allow-trusted'
    }

    It 'escapes terminal control characters in the review screen without changing the review contract' {
        $escaped = & $script:Module { ConvertTo-CapsulenvReviewDisplayText -Text ("before" + [char]27 + "[31mafter" + [char]7) }
        $escaped | Should -Be 'before<0x1B>[31mafter<0x07>'
        $escaped | Should -Not -Match ([string][char]27)
    }

    It 'renders scripts with line numbers and explicit inspection guidance' {
        @{
            version = '1.0.0'
            url = 'https://example.invalid/demo.exe'
            hash = ('a' * 64)
            pre_install = @('Write-Output first', 'Write-Output second')
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/demo.json') -Encoding UTF8

        $text = & $script:Module {
            $InformationPreference = 'Continue'
            $review = Get-CapsulenvPackageReviewPlan -Reference demo
            Write-CapsulenvPackageReview -Review $review 6>&1 | Out-String
        }
        $text | Should -Match 'Trusted package review'
        $text | Should -Match 'Execution\s+: TrustedExecution'
        $text | Should -Match 'pre_install.*LifecycleScript'
        $text | Should -Match '1\s+\| Write-Output first'
        $text | Should -Match '2\s+\| Write-Output second'
        $text | Should -Match 'Get-Content -LiteralPath'
        $text | Should -Match 'Review checklist'
        $text | Should -Match 'app review demo --raw'
    }

    It 'propagates a descendant TrustedExecution blocker through every dependency ancestor with an auditable path' {
        @{
            version = '1.0.0'; url = 'https://example.invalid/trusted.exe'; hash = ('c' * 64)
            post_install = 'Write-Output descendant-trusted-script'
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/trusted.json') -Encoding UTF8
        @{
            version = '1.0.0'; url = 'https://example.invalid/middle.exe'; hash = ('b' * 64); depends = 'trusted'
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/middle.json') -Encoding UTF8
        @{
            version = '1.0.0'; url = 'https://example.invalid/demo.exe'; hash = ('a' * 64); depends = 'middle'
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/demo.json') -Encoding UTF8

        $review = & $script:Module { Get-CapsulenvPackageReviewPlan -Reference demo }
        $root = @($review.Graph.Nodes | Where-Object Reference -eq 'main/demo')[0]
        $middle = @($review.Graph.Nodes | Where-Object Reference -eq 'main/middle')[0]
        $trusted = @($review.Graph.Nodes | Where-Object Reference -eq 'main/trusted')[0]

        $root.DirectReviewRequired | Should -BeFalse
        $root.EffectiveReviewRequired | Should -BeTrue
        $root.ExecutionBoundary | Should -Be 'TrustedExecution'
        $root.BlockingDescendants | Should -Contain 'main/trusted'
        $middle.DirectReviewRequired | Should -BeFalse
        $middle.EffectiveReviewRequired | Should -BeTrue
        $middle.BlockingDescendants | Should -Contain 'main/trusted'
        $trusted.DirectReviewRequired | Should -BeTrue
        $review.Packages | Should -HaveCount 1
        $review.Packages[0].Reference | Should -Be 'main/trusted'
        $review.Graph.ReviewPaths | Should -HaveCount 1
        @($review.Graph.ReviewPaths[0].Path) | Should -Be @('main/demo', 'main/middle', 'main/trusted')

        $text = & $script:Module {
            param($Review)
            $InformationPreference = 'Continue'
            Write-CapsulenvPackageReview -Review $Review 6>&1 | Out-String
        } $review
        $text | Should -Match 'Dependency trust propagation'
        $text | Should -Match 'main/demo -> main/middle -> main/trusted'
    }

    It 'diffs the installed-old and current-bucket-new update DAG including execution-relevant effects and edges' {
        foreach ($name in @('demo', 'helper', 'legacy')) {
            [void](New-Item -ItemType Directory -Path (Join-Path $script:Capsule "scoop/apps/$name/current") -Force)
            @{ bucket='main'; architecture='64bit' } | ConvertTo-Json |
                Set-Content -LiteralPath (Join-Path $script:Capsule "scoop/apps/$name/current/install.json") -Encoding UTF8
        }
        @{
            version='1.0.0'; url='https://example.invalid/demo-old.exe'; hash=('a' * 64)
            depends=@('helper','legacy'); persist='OldData'
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/apps/demo/current/manifest.json') -Encoding UTF8
        @{
            version='1.0.0'; url='https://example.invalid/helper.exe'; hash=('b' * 64)
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/apps/helper/current/manifest.json') -Encoding UTF8
        @{
            version='1.0.0'; url='https://example.invalid/legacy.exe'; hash=('c' * 64)
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/apps/legacy/current/manifest.json') -Encoding UTF8

        @{
            version='2.0.0'; url='https://example.invalid/demo-new.exe'; hash=('d' * 64)
            depends=@('helper','scriptdep'); persist='NewData'
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/demo.json') -Encoding UTF8
        @{
            version='1.0.0'; url='https://example.invalid/helper.exe'; hash=('b' * 64)
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/helper.json') -Encoding UTF8
        @{
            version='1.0.0'; url='https://example.invalid/scriptdep.exe'; hash=('e' * 64)
            post_install='Write-Output new-dependency-script'
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/scriptdep.json') -Encoding UTF8

        $review = & $script:Module { Get-CapsulenvPackageReviewPlan -Reference 'user/demo' }
        $review.Diff.CompleteOldClosure | Should -BeTrue
        $review.Diff.AddedNodes | Should -Contain 'scriptdep'
        $review.Diff.RemovedNodes | Should -Contain 'legacy'
        $review.Diff.ChangedNodes | Should -Contain 'demo'
        $review.Diff.AddedEdges | Should -HaveCount 1
        $review.Diff.AddedEdges[0].From | Should -Be 'demo'
        $review.Diff.AddedEdges[0].To | Should -Be 'scriptdep'
        $review.Diff.RemovedEdges | Should -HaveCount 1
        $review.Diff.RemovedEdges[0].From | Should -Be 'demo'
        $review.Diff.RemovedEdges[0].To | Should -Be 'legacy'

        $demoDiff = @($review.Diff.Nodes | Where-Object Name -eq 'demo')[0]
        @($demoDiff.Changes | ForEach-Object Name) | Should -Contain 'url'
        @($demoDiff.Changes | ForEach-Object Name) | Should -Contain 'hash'
        @($demoDiff.Changes | ForEach-Object Name) | Should -Contain 'depends'
        @($demoDiff.Changes | ForEach-Object Name) | Should -Contain 'persist'
        $scriptNode = @($review.Graph.Nodes | Where-Object Reference -eq 'main/scriptdep')[0]
        $scriptNode.DirectReviewRequired | Should -BeTrue
        $review.Graph.ReviewPaths | Where-Object Blocker -eq 'main/scriptdep' | Should -HaveCount 1

        $text = & $script:Module {
            param($Review)
            $InformationPreference = 'Continue'
            Write-CapsulenvPackageReview -Review $Review 6>&1 | Out-String
        } $review
        $text | Should -Match 'Update DAG / effect delta'
        $text | Should -Match 'dependency added\s+: demo -> scriptdep'
        $text | Should -Match 'dependency removed: demo -> legacy'
        $text | Should -Match '\[Artifact\] url: Changed'
    }

    It 'uses the full resolved DAG for raw review output, including PortableSafe ancestors' {
        @{
            version='1.0.0'; url='https://example.invalid/helper.exe'; hash=('b' * 64); post_install='Write-Output helper'
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/helper.json') -Encoding UTF8
        @{
            version='1.0.0'; url='https://example.invalid/demo.exe'; hash=('a' * 64); depends='helper'
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/demo.json') -Encoding UTF8

        $text = & $script:Module {
            $InformationPreference = 'Continue'
            $review = Get-CapsulenvPackageReviewPlan -Reference demo
            Write-CapsulenvPackageReview -Review $review -Raw 6>&1 | Out-String
        }
        $text | Should -Match '=== main/demo ::'
        $text | Should -Match '=== main/helper ::'
    }


    It 'keeps update DAG removal conclusions conservative when the installed dependency closure is incomplete' {
        $installedCurrent = Join-Path $script:Capsule 'scoop/apps/demo/current'
        [void](New-Item -ItemType Directory -Path $installedCurrent -Force)
        @{
            version='1.0.0'; url='https://example.invalid/old.exe'; hash=('a' * 64); depends='missingdep'
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $installedCurrent 'manifest.json') -Encoding UTF8
        @{ bucket='main'; architecture='64bit' } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $installedCurrent 'install.json') -Encoding UTF8
        @{
            version='2.0.0'; url='https://example.invalid/new.exe'; hash=('b' * 64)
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/demo.json') -Encoding UTF8

        $review = & $script:Module { Get-CapsulenvPackageReviewPlan -Reference 'user/demo' }
        $review.Diff.CompleteOldClosure | Should -BeFalse
        ($review.Diff.Warnings -join ' ') | Should -Match 'scoop:user/missingdep'
        $review.Diff.RemovedNodes | Should -Not -Contain 'missingdep'
        @($review.Diff.RemovedEdges) | Should -HaveCount 0
    }

    It 'surfaces newly introduced unknown active manifest semantics as an Unsupported effect delta' {
        $installedCurrent = Join-Path $script:Capsule 'scoop/apps/demo/current'
        [void](New-Item -ItemType Directory -Path $installedCurrent -Force)
        @{
            version='1.0.0'; url='https://example.invalid/old.exe'; hash=('a' * 64)
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $installedCurrent 'manifest.json') -Encoding UTF8
        @{ bucket='main'; architecture='64bit' } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $installedCurrent 'install.json') -Encoding UTF8
        @{
            version='2.0.0'; url='https://example.invalid/new.exe'; hash=('b' * 64)
            future_active_semantics=@{ mode='host-mutation' }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/demo.json') -Encoding UTF8

        $review = & $script:Module { Get-CapsulenvPackageReviewPlan -Reference 'user/demo' }
        $review.Classification | Should -Be 'TrustedExecutionRequired'
        $demoDiff = @($review.Diff.Nodes | Where-Object Name -eq 'demo')[0]
        $unknown = @($demoDiff.Changes | Where-Object Name -eq 'unknown:future_active_semantics')[0]
        $unknown.Category | Should -Be 'Unsupported'
        $unknown.Change | Should -Be 'Added'
    }

}
