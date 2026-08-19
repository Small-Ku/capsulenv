Describe 'Capsulenv PortableSafe package executor' {
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
        $script:Capsule = Join-Path $TestDrive 'capsule'
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
        $env:CAPSULENV_ROOT = $null
    }

    It 'orders declarative dependencies before the requested package' {
        foreach ($name in @('helper', 'demo')) {
            $artifact = Join-Path $TestDrive ($name + '.cmd')
            "@echo off`r`necho $name`r`n" | Set-Content -LiteralPath $artifact -Encoding ASCII
            $hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = @{
                version = '1.0.0'
                url = ([Uri]$artifact).AbsoluteUri
                hash = $hash
                bin = ($name + '.cmd')
            }
            if ($name -eq 'demo') { $manifest.depends = @('helper') }
            $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:Capsule "scoop/buckets/main/bucket/$name.json") -Encoding UTF8
        }

        $plan = Get-CapsulenvPackageInstallPlan -Reference demo
        $plan.Classification | Should -Be 'PortableSafe'
        @($plan.Packages.Reference) | Should -Be @('main/helper', 'main/demo')
    }

    It 'installs files and records relocation-safe runtime projection and shims' {
        $artifact = Join-Path $TestDrive 'demo.cmd'
        '@echo off' | Set-Content -LiteralPath $artifact -Encoding ASCII
        $hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
        @{
            version = '2.0.0'
            url = ([Uri]$artifact).AbsoluteUri
            hash = $hash
            bin = @(,@('demo.cmd', 'demo'))
            env_add_path = @('.')
            env_set = @{ DEMO_ROOT = '$dir' }
            shortcuts = @(,@('demo.cmd', 'Demo'))
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/demo.json') -Encoding UTF8

        $installed = @(Install-CapsulenvPortablePackage -Reference demo)
        $installed.Count | Should -Be 1
        $installed[0].Name | Should -Be 'demo'
        $installed[0].Version | Should -Be '2.0.0'
        $installed[0].InstallRoot | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $script:Capsule 'packages/demo/2.0.0')))

        $bin = @(Get-CapsulenvScoopAppBins -App demo)
        $bin.Count | Should -Be 1
        $bin[0].Scope | Should -Be 'Capsule'
        $bin[0].Selector | Should -Be 'capsule/demo'
        $bin[0].Name | Should -Be 'demo'

        $shim = Join-Path $script:Capsule 'shims/demo.cmd'
        Test-Path -LiteralPath $shim -PathType Leaf | Should -BeTrue
        (Get-Content -LiteralPath $shim -TotalCount 1) | Should -Be '@rem capsulenv-package: demo'
        (Get-Content -LiteralPath $shim -Raw) | Should -Match 'capsulenv\.cmd" app exec capsule/demo "demo"'

        $statePath = Join-Path $script:Capsule '.capsulenv/packages/demo.json'
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        [System.IO.Path]::IsPathRooted([string]$state.InstallRoot) | Should -BeFalse
        [System.IO.Path]::IsPathRooted([string]$state.CurrentRoot) | Should -BeFalse
    }

    It 'prefers a Capsulenv-owned package over an unscoped legacy Scoop app with the same name' {
        $capsuleCurrent = Join-Path $script:Capsule 'packages/demo/current'
        $scoopCurrent = Join-Path $script:Capsule 'scoop/apps/demo/current'
        foreach ($current in @($capsuleCurrent, $scoopCurrent)) {
            [void](New-Item -ItemType Directory -Path $current -Force)
            '{}' | Set-Content -LiteralPath (Join-Path $current 'manifest.json') -Encoding UTF8
            '{"architecture":"64bit"}' | Set-Content -LiteralPath (Join-Path $current 'install.json') -Encoding UTF8
        }

        $resolved = & $script:Module { Get-CapsulenvInstalledScoopApp -Selector demo }
        $resolved.Scope | Should -Be 'Capsule'
        $resolved.Selector | Should -Be 'capsule/demo'
        (& $script:Module { Get-CapsulenvInstalledScoopApp -Selector user/demo }).Scope | Should -Be 'User'
    }
}
