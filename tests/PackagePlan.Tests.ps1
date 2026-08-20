Describe 'Capsulenv package manifest planning' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force
        $script:Module = @(Get-Module Capsulenv)[-1]
    }

    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:Capsule = Join-Path $TestDrive ('capsule-' + [Guid]::NewGuid().ToString('N'))
        foreach ($directory in @(
            'config',
            'scoop/buckets/main/bucket',
            'scoop/buckets/extras/bucket'
        )) {
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
        $env:CAPSULENV_ROOT = $null
    }

    It 'classifies a declarative manifest as PortableSafe and selects architecture-specific values' {
        @{
            version = '1.2.3'
            url = 'https://example.invalid/demo-x86.zip'
            hash = ('a' * 64)
            architecture = @{
                '64bit' = @{
                    url = 'https://example.invalid/demo-x64.zip#/demo.zip'
                    hash = ('b' * 64)
                    bin = @('bin\\demo.exe')
                }
            }
            persist = @('data')
            env_add_path = @('tools')
            env_set = @{ DEMO_HOME = '$dir\\data' }
            shortcuts = @(,@('bin\\demo.exe', 'Demo'))
            depends = @('helper')
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/demo.json') -Encoding UTF8

        @{
            version = '1.0.0'
            url = 'https://example.invalid/helper.exe'
            hash = ('c' * 64)
            bin = 'helper.exe'
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/helper.json') -Encoding UTF8

        $plan = Get-CapsulenvPackageManifestPlan -Reference demo
        $plan.Classification | Should -Be 'PortableSafe'
        $plan.Architecture | Should -Be '64bit'
        $plan.Downloads.Count | Should -Be 1
        $plan.Downloads[0].FileName | Should -Be 'demo.zip'
        $plan.Downloads[0].Hash | Should -Be ('b' * 64)
        $plan.Capabilities | Should -Contain 'Persist'
        $plan.Capabilities | Should -Contain 'ProcessEnvironment'
        $plan.Dependencies | Should -Contain 'helper'
        @($plan.Reasons).Count | Should -Be 0
    }

    It 'classifies arbitrary hooks as TrustedScript without trying to sanitize them' {
        @{
            version = '1.0.0'
            url = 'https://example.invalid/demo.zip'
            hash = ('a' * 64)
            bin = 'demo.exe'
            post_install = 'Set-ItemProperty HKCU:\\Software\\Demo value 1'
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/demo.json') -Encoding UTF8

        $plan = Get-CapsulenvPackageManifestPlan -Reference demo
        $plan.Classification | Should -Be 'TrustedScript'
        @($plan.Reasons -join ' ') | Should -Match 'post_install'
    }

    It 'classifies an external installer separately from arbitrary script execution' {
        @{
            version = '1.0.0'
            url = 'https://example.invalid/setup.exe'
            hash = ('a' * 64)
            installer = @{ args = @('/S') }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/demo.json') -Encoding UTF8

        (Get-CapsulenvPackageManifestPlan -Reference demo).Classification | Should -Be 'ExternalInstaller'
    }

    It 'rejects unsupported archives and paths that escape the package root' {
        @{
            version = '1.0.0'
            url = 'https://example.invalid/demo.7z'
            hash = ('a' * 64)
            bin = '..\\host.exe'
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/demo.json') -Encoding UTF8

        $plan = Get-CapsulenvPackageManifestPlan -Reference demo
        $plan.Classification | Should -Be 'Unsupported'
        ($plan.Reasons -join ' ') | Should -Match 'archive type'
        ($plan.Reasons -join ' ') | Should -Match 'escapes the package root'
    }

    It 'requires an explicit bucket when the package is ambiguous outside main' {
        Remove-Item -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main') -Recurse -Force
        foreach ($bucket in @('extras', 'versions')) {
            [void](New-Item -ItemType Directory -Path (Join-Path $script:Capsule "scoop/buckets/$bucket/bucket") -Force)
            @{ version = '1.0'; url = 'https://example.invalid/demo.exe'; hash = ('a' * 64) } |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:Capsule "scoop/buckets/$bucket/bucket/demo.json") -Encoding UTF8
        }

        { Get-CapsulenvPackageManifestPlan -Reference demo } | Should -Throw '*multiple non-main buckets*'
        (Get-CapsulenvPackageManifestPlan -Reference extras/demo).Bucket | Should -Be 'extras'
    }

    It 'fails closed for unsafe host-facing names while supporting bounded shortcut subdirectories and icons' {
        @{
            version = 'CON'
            url = 'https://example.invalid/demo.exe'
            hash = ('a' * 64)
            bin = @(,@('demo.exe', 'NUL'))
            shortcuts = @(,@('demo.exe', 'Tools\Demo', '', 'demo.ico'))
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/demo.json') -Encoding UTF8

        $plan = Get-CapsulenvPackageManifestPlan -Reference demo
        $plan.Classification | Should -Be 'Unsupported'
        ($plan.Reasons -join ' ') | Should -Match 'version cannot be represented'
        ($plan.Reasons -join ' ') | Should -Match 'bin alias is reserved or invalid'
        ($plan.Reasons -join ' ') | Should -Not -Match 'shortcut name|shortcut icon'
    }

    It 'fails closed for manifest semantics not implemented by PortableSafe' {
        @{
            version = '1.0.0'
            url = 'https://example.invalid/demo.exe'
            hash = ('a' * 64)
            cookie = @{ session = 'secret' }
            psmodule = @{ name = 'Demo' }
            future_install_mode = 'host'
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/demo.json') -Encoding UTF8

        $plan = Get-CapsulenvPackageManifestPlan -Reference demo
        $plan.Classification | Should -Be 'Unsupported'
        ($plan.Reasons -join ' ') | Should -Match "does not implement Scoop 'cookie' semantics"
        ($plan.Reasons -join ' ') | Should -Match "does not implement Scoop 'psmodule' semantics"
        ($plan.Reasons -join ' ') | Should -Match 'Unsupported Scoop manifest property: future_install_mode'
    }

    It 'rejects invalid env_set shapes and extract_dir semantics for non-ZIP artifacts' {
        @{
            version = '1.0.0'
            url = 'https://example.invalid/demo.exe'
            hash = ('a' * 64)
            extract_dir = 'payload'
            env_set = @('DEMO=value')
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/demo.json') -Encoding UTF8

        $plan = Get-CapsulenvPackageManifestPlan -Reference demo
        $plan.Classification | Should -Be 'Unsupported'
        ($plan.Reasons -join ' ') | Should -Match 'env_set must be a JSON object'
        ($plan.Reasons -join ' ') | Should -Match 'extract_dir is only implemented for ZIP'
    }

    It 'rejects package reference components that could escape or alias Windows paths' {
        { Get-CapsulenvPackageManifestPlan -Reference '../demo' } | Should -Throw '*Invalid package reference component*'
        { Get-CapsulenvPackageManifestPlan -Reference 'CON' } | Should -Throw '*Invalid package reference component*'
    }

}
