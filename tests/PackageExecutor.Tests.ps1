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
        $env:CAPSULENV_ROOT = $null
    }

    It 'orders declarative dependencies before the requested package' {
        foreach ($name in @('helper', 'demo')) {
            $artifact = Join-Path $TestDrive ($name + '.cmd')
            "@echo off`r`necho $name`r`n" | Set-Content -LiteralPath $artifact -Encoding ASCII
            $hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = @{
                version = '1.0.0'
                url = ([System.Uri]::new([System.IO.Path]::GetFullPath($artifact))).AbsoluteUri
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
            url = ([System.Uri]::new([System.IO.Path]::GetFullPath($artifact))).AbsoluteUri
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

        $shortcuts = @(Get-CapsulenvScoopAppShortcuts -App capsule/demo)
        $shortcuts.Count | Should -Be 1
        $shortcuts[0].Name | Should -Be 'Demo'

        $statePath = Join-Path $script:Capsule '.capsulenv/packages/demo.json'
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        [System.IO.Path]::IsPathRooted([string]$state.InstallRoot) | Should -BeFalse
        [System.IO.Path]::IsPathRooted([string]$state.CurrentRoot) | Should -BeFalse
    }

    It 'prefers a Capsulenv-owned package over an unscoped legacy Scoop app with the same name' {
        $artifact = Join-Path $TestDrive 'demo-owned.cmd'
        '@echo off' | Set-Content -LiteralPath $artifact -Encoding ASCII
        $hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
        @{
            version = '1.0.0'
            url = ([System.Uri]::new([System.IO.Path]::GetFullPath($artifact))).AbsoluteUri
            hash = $hash
            bin = 'demo-owned.cmd'
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/demo.json') -Encoding UTF8
        [void](Install-CapsulenvPortablePackage -Reference demo)

        $scoopCurrent = Join-Path $script:Capsule 'scoop/apps/demo/current'
        [void](New-Item -ItemType Directory -Path $scoopCurrent -Force)
        '{}' | Set-Content -LiteralPath (Join-Path $scoopCurrent 'manifest.json') -Encoding UTF8
        '{"architecture":"64bit"}' | Set-Content -LiteralPath (Join-Path $scoopCurrent 'install.json') -Encoding UTF8

        $resolved = & $script:Module { Get-CapsulenvInstalledScoopApp -Selector demo }
        $resolved.Scope | Should -Be 'Capsule'
        $resolved.Selector | Should -Be 'capsule/demo'
        (& $script:Module { Get-CapsulenvInstalledScoopApp -Selector user/demo }).Scope | Should -Be 'User'
    }

    It 'removes obsolete owned shims when a safe package advances to a new version' {
        $artifactV1 = Join-Path $TestDrive 'demo-v1.cmd'
        '@echo off' | Set-Content -LiteralPath $artifactV1 -Encoding ASCII
        $hashV1 = (Get-FileHash -LiteralPath $artifactV1 -Algorithm SHA256).Hash.ToLowerInvariant()
        @{
            version = '1.0.0'
            url = ([System.Uri]::new([System.IO.Path]::GetFullPath($artifactV1))).AbsoluteUri
            hash = $hashV1
            bin = @(,@('demo-v1.cmd', 'old-demo'))
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/demo.json') -Encoding UTF8
        [void](Install-CapsulenvPortablePackage -Reference demo)
        Test-Path -LiteralPath (Join-Path $script:Capsule 'shims/old-demo.cmd') -PathType Leaf | Should -BeTrue

        $artifactV2 = Join-Path $TestDrive 'demo-v2.cmd'
        '@echo off' | Set-Content -LiteralPath $artifactV2 -Encoding ASCII
        $hashV2 = (Get-FileHash -LiteralPath $artifactV2 -Algorithm SHA256).Hash.ToLowerInvariant()
        @{
            version = '2.0.0'
            url = ([System.Uri]::new([System.IO.Path]::GetFullPath($artifactV2))).AbsoluteUri
            hash = $hashV2
            bin = @(,@('demo-v2.cmd', 'new-demo'))
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/demo.json') -Encoding UTF8
        [void](Install-CapsulenvPortablePackage -Reference demo)

        Test-Path -LiteralPath (Join-Path $script:Capsule 'shims/old-demo.cmd') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Capsule 'shims/new-demo.cmd') -PathType Leaf | Should -BeTrue
        $state = & $script:Module { Get-CapsulenvInstalledPackageState -Name demo }
        $state.Version | Should -Be '2.0.0'
        @($state.Shims) | Should -Be @('new-demo')
    }

    It 'keeps an unqualified dependency in the parent bucket when that manifest exists' {
        [void](New-Item -ItemType Directory -Path (Join-Path $script:Capsule 'scoop/buckets/extras/bucket') -Force)
        @{
            version = '1.0.0'
            url = 'https://example.invalid/helper.exe'
            hash = ('a' * 64)
            bin = 'helper.exe'
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/helper.json') -Encoding UTF8
        @{
            version = '1.0.0'
            url = 'https://example.invalid/helper.exe'
            hash = ('b' * 64)
            bin = 'helper.exe'
            post_install = 'Write-Host trusted'
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/extras/bucket/helper.json') -Encoding UTF8
        @{
            version = '1.0.0'
            url = 'https://example.invalid/demo.exe'
            hash = ('c' * 64)
            bin = 'demo.exe'
            depends = @('helper')
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/extras/bucket/demo.json') -Encoding UTF8

        $plan = Get-CapsulenvPackageInstallPlan -Reference extras/demo
        $plan.Classification | Should -Be 'TrustedExecutionRequired'
        @($plan.Packages.Reference) | Should -Be @('extras/helper', 'extras/demo')
        @($plan.BlockedPackages.Reference) | Should -Be @('extras/helper')
    }

    It 'refuses to replace a diverged normal file during persist projection repair' {
        $source = Join-Path $TestDrive 'source.txt'
        $target = Join-Path $TestDrive 'target.txt'
        'source' | Set-Content -LiteralPath $source -Encoding UTF8
        'target' | Set-Content -LiteralPath $target -Encoding UTF8

        {
            & $script:Module {
                param($Source, $Target)
                Repair-CapsulenvPackageFileProjection -Path $Source -Target $Target -OwnershipLabel 'test projection'
            } $source $target
        } | Should -Throw '*Refusing to replace a diverged normal file*'

        (Get-Content -LiteralPath $source -Raw).Trim() | Should -Be 'source'
        (Get-Content -LiteralPath $target -Raw).Trim() | Should -Be 'target'
    }

    It 'streams package executable stdout without mixing the exit code into the success stream' {
        $hostExecutable = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $previousLastExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        Mock Set-CapsulenvSessionEnvironment { [pscustomobject]@{} } -ModuleName Capsulenv
        Mock Get-CapsulenvPackageProcessPlan {
            [pscustomobject]@{
                FilePath = $hostExecutable
                PathEntries = @()
                Variables = [ordered]@{}
            }
        } -ModuleName Capsulenv

        try {
            $output = & $script:Module {
                Invoke-CapsulenvPackageExecutable `
                    -App 'capsule/demo' `
                    -BinName 'demo' `
                    -Arguments @('-NoLogo', '-NoProfile', '-Command', '[Console]::Out.WriteLine(''capsulenv-stream-marker''); exit 7')
            }

            @($output) | Should -Be @('capsulenv-stream-marker')
            $global:LASTEXITCODE | Should -Be 7
        } finally {
            if ($null -eq $previousLastExitCode) {
                Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
            } else {
                $global:LASTEXITCODE = $previousLastExitCode.Value
            }
        }
    }


    It 'detects installed manifest drift before resolving a PortableSafe runtime target' {
        $artifact = Join-Path $TestDrive 'drift.cmd'
        '@echo off' | Set-Content -LiteralPath $artifact -Encoding ASCII
        $hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
        @{
            version = '1.0.0'
            url = ([System.Uri]::new([System.IO.Path]::GetFullPath($artifact))).AbsoluteUri
            hash = $hash
            bin = 'drift.cmd'
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:Capsule 'scoop/buckets/main/bucket/drift.json') -Encoding UTF8
        $installed = @(Install-CapsulenvPortablePackage -Reference drift)[0]

        '{"version":"1.0.0","bin":"C:\\Windows\\System32\\cmd.exe"}' |
            Set-Content -LiteralPath (Join-Path $installed.InstallRoot 'manifest.json') -Encoding UTF8

        { Get-CapsulenvScoopAppBins -App 'capsule/drift' } |
            Should -Throw '*installed manifest changed outside the package executor*'
    }

    It 'does not implicitly replace an installed name with a package from another bucket' {
        [void](New-Item -ItemType Directory -Path (Join-Path $script:Capsule 'scoop/buckets/extras/bucket') -Force)
        foreach ($bucket in @('main', 'extras')) {
            $artifact = Join-Path $TestDrive ("$bucket-demo.cmd")
            "@echo off`r`necho $bucket`r`n" | Set-Content -LiteralPath $artifact -Encoding ASCII
            $hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
            @{
                version = '1.0.0'
                url = ([System.Uri]::new([System.IO.Path]::GetFullPath($artifact))).AbsoluteUri
                hash = $hash
                bin = ("$bucket-demo.cmd")
            } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:Capsule "scoop/buckets/$bucket/bucket/demo.json") -Encoding UTF8
        }

        [void](Install-CapsulenvPortablePackage -Reference main/demo)
        { Install-CapsulenvPortablePackage -Reference extras/demo } |
            Should -Throw "*already owned by 'main/demo'*"
    }

}
