Describe 'Capsulenv package TrustedExecution review' {
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
        $review.RequestReference | Should -Be 'user/demo'
        $review.Reference | Should -Be 'main/demo'
        $review.Operation | Should -Be 'Update'
        $review.ExecutionBoundary | Should -Be 'TrustedExecution'
        $review.ReviewRequired | Should -BeTrue
        $review.InstalledSelector | Should -Be 'user/demo'
        $review.Packages[0].Version | Should -Be '2.0.0'
        ($review.Packages[0].ReviewItems[0].Lines -join ' ') | Should -Match 'new-update-script'
        $review.RecommendedAction | Should -Match 'app update user/demo --allow-trusted'
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
        $review.RecommendedAction | Should -Match 'app update user/demo --allow-trusted'
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
}
