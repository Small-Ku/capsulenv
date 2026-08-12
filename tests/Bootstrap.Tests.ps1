Describe 'Capsulenv Scoop bootstrap and isolation' {
    It 'passes shallow Git bootstrap, repair, archive fallback, and shell-only isolation checks' {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        function Assert-CapsulenvBootstrapTest {
            param(
                [Parameter(Mandatory = $true)][bool]$Condition,
                [Parameter(Mandatory = $true)][string]$Message
            )
            if (-not $Condition) {
                throw $Message
            }
        }

        function Invoke-CapsulenvBootstrapTestGit {
            param(
                [Parameter(Mandatory = $true)][string]$Git,
                [Parameter(Mandatory = $true)][string[]]$Arguments
            )
            & $Git @Arguments | Out-Null
            if (-not $?) {
                throw "git $($Arguments -join ' ') failed."
            }
            if ($LASTEXITCODE -ne 0) {
                throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
            }
        }

        function New-CapsulenvBootstrapTestRepository {
            param(
                [Parameter(Mandatory = $true)][string]$Git,
                [Parameter(Mandatory = $true)][string]$Path,
                [Parameter(Mandatory = $true)][string]$RelativeFile,
                [Parameter(Mandatory = $true)][string]$Content
            )

            $target = Join-Path $Path $RelativeFile
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force)
            Set-Content -LiteralPath $target -Value $Content -Encoding UTF8
            Invoke-CapsulenvBootstrapTestGit -Git $Git -Arguments @('-C', $Path, 'init', '-q', '-b', 'master')
            Invoke-CapsulenvBootstrapTestGit -Git $Git -Arguments @('-C', $Path, 'config', 'user.email', 'capsulenv-tests@example.invalid')
            Invoke-CapsulenvBootstrapTestGit -Git $Git -Arguments @('-C', $Path, 'config', 'user.name', 'capsulenv tests')
            Invoke-CapsulenvBootstrapTestGit -Git $Git -Arguments @('-C', $Path, 'add', '.')
            Invoke-CapsulenvBootstrapTestGit -Git $Git -Arguments @('-C', $Path, 'commit', '-q', '-m', 'initial fixture')

            # A second commit makes depth=1 observable instead of accidentally looking
            # complete because the source repository contains only one commit.
            Add-Content -LiteralPath $target -Value '# second fixture revision'
            Invoke-CapsulenvBootstrapTestGit -Git $Git -Arguments @('-C', $Path, 'add', '.')
            Invoke-CapsulenvBootstrapTestGit -Git $Git -Arguments @('-C', $Path, 'commit', '-q', '-m', 'second fixture')
        }

        function New-CapsulenvBootstrapTestCapsule {
            param(
                [Parameter(Mandatory = $true)][string]$Root,
                [Parameter(Mandatory = $true)][string]$BaseConfig,
                [Parameter(Mandatory = $true)][string]$ScoopRepository,
                [Parameter(Mandatory = $true)][string]$MainRepository,
                [Parameter(Mandatory = $true)][string]$ScoopArchive,
                [Parameter(Mandatory = $true)][string]$MainArchive
            )

            $configRoot = Join-Path $Root 'config'
            [void](New-Item -ItemType Directory -Path $configRoot -Force)
            Copy-Item -LiteralPath $BaseConfig -Destination (Join-Path $configRoot 'capsulenv.psd1') -Force
            @"
        @{
            Scoop = @{
                Bootstrap = @{
                    Enabled = `$true
                    GitDepth = 1
                    Scoop = @{
                        Repository = '$($ScoopRepository.Replace("'", "''"))'
                        Branch = 'master'
                        Archive = '$($ScoopArchive.Replace("'", "''"))'
                    }
                    Main = @{
                        Repository = '$($MainRepository.Replace("'", "''"))'
                        Branch = 'master'
                        Archive = '$($MainArchive.Replace("'", "''"))'
                    }
                }
                ReplayHooks = @{}
                RelocationRepairs = @{}
            }
            Bitwarden = @{
                Enabled = `$false
                SetSshAuthSock = `$false
            }
        }
"@ | Set-Content -LiteralPath (Join-Path $configRoot 'capsulenv.local.psd1') -Encoding UTF8
        }

        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $gitCommand = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $gitCommand) {
            Write-Host 'capsulenv bootstrap tests skipped: Git is unavailable.' -ForegroundColor Yellow
            return
        }
        $git = [string]$gitCommand.Source
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-bootstrap-tests-{0}' -f [Guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Path $temporaryRoot -Force)
            $scoopSource = Join-Path $temporaryRoot 'scoop-source'
            $mainSource = Join-Path $temporaryRoot 'main-source'
            [void](New-Item -ItemType Directory -Path $scoopSource -Force)
            [void](New-Item -ItemType Directory -Path $mainSource -Force)
            New-CapsulenvBootstrapTestRepository -Git $git -Path $scoopSource -RelativeFile 'bin/scoop.ps1' -Content 'param()'
            New-CapsulenvBootstrapTestRepository -Git $git -Path $mainSource -RelativeFile 'bucket/test.json' -Content '{}'

            $buildRoot = Join-Path $temporaryRoot 'module-build'
            $build = & (Join-Path $root 'Merge-ModuleScripts.ps1') -OutputRoot $buildRoot -Clean
            Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
            Import-Module $build.ModulePath -Force
            $module = Get-Module Capsulenv | Select-Object -First 1

            $scoopUri = ([System.Uri]::new([System.IO.Path]::GetFullPath($scoopSource))).AbsoluteUri
            $mainUri = ([System.Uri]::new([System.IO.Path]::GetFullPath($mainSource))).AbsoluteUri
            $capsule = Join-Path $temporaryRoot 'capsule-git'
            New-CapsulenvBootstrapTestCapsule `
                -Root $capsule `
                -BaseConfig (Join-Path (Join-Path $root 'config') 'capsulenv.psd1') `
                -ScoopRepository $scoopUri `
                -MainRepository $mainUri `
                -ScoopArchive (Join-Path $temporaryRoot 'unused-scoop.zip') `
                -MainArchive (Join-Path $temporaryRoot 'unused-main.zip')

            $oldRoot = $env:CAPSULENV_ROOT
            $oldScoop = $env:SCOOP
            $oldGlobal = $env:SCOOP_GLOBAL
            $oldCache = $env:SCOOP_CACHE
            $oldPath = $env:PATH
            try {
                $hostScoopSentinel = Join-Path $temporaryRoot 'host-scoop-sentinel.txt'
                'untouched' | Set-Content -LiteralPath $hostScoopSentinel -Encoding UTF8
                $env:CAPSULENV_ROOT = $capsule
                [void](& $module { param($CapsuleRoot) Initialize-CapsulenvContext -Root $CapsuleRoot } $capsule)
                $hostScoopRoot = Join-Path $temporaryRoot 'host-scoop-that-must-not-be-adopted'
                $hostGlobalRoot = Join-Path $temporaryRoot 'host-global-that-must-not-be-adopted'
                $hostScoopShims = Join-Path $hostScoopRoot 'shims'
                $hostGlobalShims = Join-Path $hostGlobalRoot 'shims'
                [void](New-Item -ItemType Directory -Path $hostScoopShims -Force)
                [void](New-Item -ItemType Directory -Path $hostGlobalShims -Force)
                $env:SCOOP = $hostScoopRoot
                $env:SCOOP_GLOBAL = $hostGlobalRoot
                $env:PATH = (@($hostScoopShims, $hostGlobalShims, $env:PATH) -join ';')

                $plan = Set-CapsulenvSessionEnvironment
                Assert-CapsulenvBootstrapTest `
                    -Condition ([string]$env:SCOOP -eq [System.IO.Path]::GetFullPath((Join-Path $capsule 'scoop'))) `
                    -Message 'Shell-only session did not replace inherited SCOOP in process scope.'
                Assert-CapsulenvBootstrapTest `
                    -Condition ([string]$env:SCOOP_GLOBAL -eq [System.IO.Path]::GetFullPath((Join-Path $capsule 'scoop-global'))) `
                    -Message 'Shell-only session did not replace inherited SCOOP_GLOBAL in process scope.'
                Assert-CapsulenvBootstrapTest `
                    -Condition ([string]$env:SCOOP_CACHE -eq [System.IO.Path]::GetFullPath((Join-Path $capsule 'cache/scoop'))) `
                    -Message 'Shell-only session did not root SCOOP_CACHE inside the capsule.'
                $sessionPaths = @($env:PATH -split ';')
                Assert-CapsulenvBootstrapTest `
                    -Condition (-not ($sessionPaths -contains $hostScoopShims)) `
                    -Message 'Shell-only session retained the inherited host Scoop shim directory.'
                Assert-CapsulenvBootstrapTest `
                    -Condition (-not ($sessionPaths -contains $hostGlobalShims)) `
                    -Message 'Shell-only session retained the inherited host global Scoop shim directory.'

                $bootstrap = Initialize-CapsulenvScoopBootstrap
                Assert-CapsulenvBootstrapTest -Condition ($bootstrap.ScoopTransport -eq 'git') -Message 'Scoop did not use Git bootstrap.'
                Assert-CapsulenvBootstrapTest -Condition ($bootstrap.MainTransport -eq 'git') -Message 'Main did not use Git bootstrap.'
                Assert-CapsulenvBootstrapTest `
                    -Condition (Test-Path -LiteralPath (Join-Path $capsule 'scoop/apps/scoop/current/.git/shallow') -PathType Leaf) `
                    -Message 'Scoop bootstrap repository is not shallow.'
                Assert-CapsulenvBootstrapTest `
                    -Condition (Test-Path -LiteralPath (Join-Path $capsule 'scoop/buckets/main/.git/shallow') -PathType Leaf) `
                    -Message 'Main bootstrap repository is not shallow.'
                Assert-CapsulenvBootstrapTest `
                    -Condition ((Get-Content -LiteralPath (Join-Path $capsule 'scoop/config.json') -Raw).Trim() -eq '{}') `
                    -Message 'Portable Scoop config was not created before first use.'
                $shim = Get-Content -LiteralPath (Join-Path $capsule 'scoop/shims/scoop.ps1') -Raw
                Assert-CapsulenvBootstrapTest `
                    -Condition ($shim.Contains("Join-Path `$PSScriptRoot '..\apps\scoop\current\bin\scoop.ps1'")) `
                    -Message 'Scoop PowerShell shim is not relocation-safe.'
                Assert-CapsulenvBootstrapTest `
                    -Condition (-not $shim.Contains([System.IO.Path]::GetFullPath($capsule))) `
                    -Message 'Scoop shim captured an absolute capsule path.'

                $cmdShimPath = Join-Path $capsule 'scoop/shims/scoop.cmd'
                ('@echo off' + [Environment]::NewLine + ('powershell -File "{0}\scoop\apps\scoop\current\bin\scoop.ps1" %*' -f $capsule)) |
                    Set-Content -LiteralPath $cmdShimPath -Encoding ASCII
                [void](Initialize-CapsulenvScoopBootstrap)
                $cmdShim = Get-Content -LiteralPath $cmdShimPath -Raw
                Assert-CapsulenvBootstrapTest `
                    -Condition ($cmdShim.Contains('set "SCOOP_PS1=%~dp0..\apps\scoop\current\bin\scoop.ps1"')) `
                    -Message 'Bootstrap did not normalize a stale absolute scoop.cmd to a relative launcher.'
                Assert-CapsulenvBootstrapTest `
                    -Condition (-not $cmdShim.Contains([System.IO.Path]::GetFullPath($capsule))) `
                    -Message 'Normalized scoop.cmd still captured the absolute capsule path.'

                Assert-CapsulenvBootstrapTest `
                    -Condition ((Get-Content -LiteralPath $hostScoopSentinel -Raw).Trim() -eq 'untouched') `
                    -Message 'Shell-only bootstrap touched host Scoop state.'
                Assert-CapsulenvBootstrapTest `
                    -Condition ((Get-CapsulenvInstallMode) -eq 'ShellOnly') `
                    -Message 'Fresh capsule mode must default to ShellOnly.'
            } finally {
                $env:CAPSULENV_ROOT = $oldRoot
                $env:SCOOP = $oldScoop
                $env:SCOOP_GLOBAL = $oldGlobal
                $env:SCOOP_CACHE = $oldCache
                $env:PATH = $oldPath
            }

            # Corrupt only a required working-tree file. Because Git metadata is
            # healthy, bootstrap must repair this repo with a depth-limited fetch/reset
            # instead of replacing it with an archive or a fresh clone.
            Remove-Item -LiteralPath (Join-Path $capsule 'scoop/apps/scoop/current/bin/scoop.ps1') -Force
            $env:CAPSULENV_ROOT = $capsule
            [void](& $module { param($CapsuleRoot) Initialize-CapsulenvContext -Root $CapsuleRoot } $capsule)
            try {
                $repairBootstrap = Initialize-CapsulenvScoopBootstrap
                Assert-CapsulenvBootstrapTest `
                    -Condition ($repairBootstrap.ScoopTransport -eq 'git-fetch') `
                    -Message 'Incomplete Scoop Git repository was not repaired with shallow fetch/reset.'
                Assert-CapsulenvBootstrapTest `
                    -Condition (Test-Path -LiteralPath (Join-Path $capsule 'scoop/apps/scoop/current/bin/scoop.ps1') -PathType Leaf) `
                    -Message 'Shallow Git repair did not restore the Scoop core file.'
                Assert-CapsulenvBootstrapTest `
                    -Condition (Test-Path -LiteralPath (Join-Path $capsule 'scoop/apps/scoop/current/.git/shallow') -PathType Leaf) `
                    -Message 'Shallow Git repair unexpectedly unshallowed the Scoop repository.'
            } finally {
                $env:CAPSULENV_ROOT = $oldRoot
            }

            # Exercise the Git-failure -> local archive fallback without network access.
            $scoopArchiveLayout = Join-Path $temporaryRoot 'scoop-archive-layout'
            $mainArchiveLayout = Join-Path $temporaryRoot 'main-archive-layout'
            [void](New-Item -ItemType Directory -Path (Join-Path $scoopArchiveLayout 'Scoop-master/bin') -Force)
            [void](New-Item -ItemType Directory -Path (Join-Path $mainArchiveLayout 'Main-master/bucket') -Force)
            'param()' | Set-Content -LiteralPath (Join-Path $scoopArchiveLayout 'Scoop-master/bin/scoop.ps1') -Encoding UTF8
            '{}' | Set-Content -LiteralPath (Join-Path $mainArchiveLayout 'Main-master/bucket/test.json') -Encoding UTF8
            $scoopArchive = Join-Path $temporaryRoot 'scoop.zip'
            $mainArchive = Join-Path $temporaryRoot 'main.zip'
            Compress-Archive -Path (Join-Path $scoopArchiveLayout 'Scoop-master') -DestinationPath $scoopArchive -Force
            Compress-Archive -Path (Join-Path $mainArchiveLayout 'Main-master') -DestinationPath $mainArchive -Force

            $archiveCapsule = Join-Path $temporaryRoot 'capsule-archive'
            New-CapsulenvBootstrapTestCapsule `
                -Root $archiveCapsule `
                -BaseConfig (Join-Path (Join-Path $root 'config') 'capsulenv.psd1') `
                -ScoopRepository (Join-Path $temporaryRoot 'missing-scoop-repository') `
                -MainRepository (Join-Path $temporaryRoot 'missing-main-repository') `
                -ScoopArchive $scoopArchive `
                -MainArchive $mainArchive
            $env:CAPSULENV_ROOT = $archiveCapsule
            [void](& $module { param($CapsuleRoot) Initialize-CapsulenvContext -Root $CapsuleRoot } $archiveCapsule)
            try {
                $archiveBootstrap = Initialize-CapsulenvScoopBootstrap
                Assert-CapsulenvBootstrapTest -Condition ($archiveBootstrap.ScoopTransport -eq 'archive') -Message 'Scoop archive fallback was not used.'
                Assert-CapsulenvBootstrapTest -Condition ($archiveBootstrap.MainTransport -eq 'archive') -Message 'Main archive fallback was not used.'
                Assert-CapsulenvBootstrapTest `
                    -Condition (Test-Path -LiteralPath (Join-Path $archiveCapsule 'scoop/apps/scoop/current/bin/scoop.ps1') -PathType Leaf) `
                    -Message 'Scoop archive fallback did not install the core.'
                Assert-CapsulenvBootstrapTest `
                    -Condition (-not (Test-Path -LiteralPath (Join-Path $archiveCapsule 'scoop/apps/scoop/current/.git'))) `
                    -Message 'Archive fallback unexpectedly created Git metadata.'
            } finally {
                $env:CAPSULENV_ROOT = $oldRoot
            }

            Write-Host 'capsulenv bootstrap/isolation tests passed.' -ForegroundColor Green
        } finally {
            Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }
}
