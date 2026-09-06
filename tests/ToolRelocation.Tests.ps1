Describe 'Capsulenv tool relocation parsing' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = Get-CapsulenvTestModuleBuild -Root $script:Root
        Import-Module $script:Build.ModulePath -Force -DisableNameChecking
        $script:Module = @(Get-Module Capsulenv)[-1]
        $script:PythonRoot = Join-Path $script:Root '.build/test-uv-python'
        [void](New-Item -ItemType Directory -Path $script:PythonRoot -Force)
    }

    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:PythonRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Mock Get-CapsulenvUvPythonDirectory { $script:PythonRoot } -ModuleName Capsulenv
        Mock Write-CapsulenvMessage {} -ModuleName Capsulenv
    }

    It 'parses the uv 0.12 JSON schema without direct StrictMode property access' {
        $managedPath = Join-Path $script:PythonRoot 'cpython-3.13.7-windows-x86_64-none'
        $json = @(
            [pscustomobject]@{
                key = 'cpython-3.13.7-windows-x86_64-none'
                version = '3.13.7'
                version_parts = [pscustomobject]@{ major = 3; minor = 13; patch = 7 }
                path = $managedPath
                symlink = $null
                url = $null
                os = 'windows'
                variant = 'default'
                implementation = 'cpython'
                arch = 'x86_64'
                libc = 'none'
            }
        ) | ConvertTo-Json -Compress
        Mock Invoke-CapsulenvNativeToolCapture {
            [pscustomobject]@{ ExitCode = 0; StdOut = $json; StdErr = '' }
        } -ModuleName Capsulenv

        $result = @(& $script:Module { Get-CapsulenvUvManagedPythonInstallations -UvExecutable 'uv.exe' })

        $result.Count | Should -Be 1
        $result[0].Key | Should -Be 'cpython-3.13.7-windows-x86_64-none'
        $result[0].Version | Should -Be '3.13.7'
        $result[0].Path | Should -Be ([System.IO.Path]::GetFullPath($managedPath))
    }

    It 'flattens nested JSON arrays before reading records' {
        $managedPath = Join-Path $script:PythonRoot 'cpython-3.12.11-windows-x86_64-none'
        $json = ConvertTo-Json -Compress -InputObject @(,@(
            [pscustomobject]@{
                key = 'cpython-3.12.11-windows-x86_64-none'
                version = '3.12.11'
                path = $managedPath
            }
        ))
        Mock Invoke-CapsulenvNativeToolCapture {
            [pscustomobject]@{ ExitCode = 0; StdOut = $json; StdErr = '' }
        } -ModuleName Capsulenv

        $result = @(& $script:Module { Get-CapsulenvUvManagedPythonInstallations -UvExecutable 'uv.exe' })

        $result.Count | Should -Be 1
        $result[0].Key | Should -Be 'cpython-3.12.11-windows-x86_64-none'
    }

    It 'ignores malformed uv records without throwing under StrictMode' {
        $managedPath = Join-Path $script:PythonRoot 'cpython-3.11.13-windows-x86_64-none'
        $json = ConvertTo-Json -Compress -InputObject @(
            [pscustomobject]@{ path = $managedPath; version = '3.11.13' },
            [pscustomobject]@{ key = 'cpython-3.10.18-windows-x86_64-none'; version = '3.10.18' },
            [pscustomobject]@{ unexpected = 'metadata' }
        )
        Mock Invoke-CapsulenvNativeToolCapture {
            [pscustomobject]@{ ExitCode = 0; StdOut = $json; StdErr = '' }
        } -ModuleName Capsulenv

        { & $script:Module { Get-CapsulenvUvManagedPythonInstallations -UvExecutable 'uv.exe' } } | Should -Not -Throw
        $result = @(& $script:Module { Get-CapsulenvUvManagedPythonInstallations -UvExecutable 'uv.exe' })
        $result.Count | Should -Be 0
        Should -Invoke Write-CapsulenvMessage -ModuleName Capsulenv -ParameterFilter {
            $Level -eq 'Warning' -and $Message -match 'malformed uv managed-Python JSON record'
        }
    }

    It 'ignores records outside the capsule-owned uv Python directory' {
        $outsidePath = Join-Path ([System.IO.Path]::GetTempPath()) 'foreign-python/cpython-3.13.7-windows-x86_64-none'
        $json = ConvertTo-Json -Compress -InputObject @(
            [pscustomobject]@{
                key = 'cpython-3.13.7-windows-x86_64-none'
                version = '3.13.7'
                path = $outsidePath
            }
        )
        Mock Invoke-CapsulenvNativeToolCapture {
            [pscustomobject]@{ ExitCode = 0; StdOut = $json; StdErr = '' }
        } -ModuleName Capsulenv

        $result = @(& $script:Module { Get-CapsulenvUvManagedPythonInstallations -UvExecutable 'uv.exe' })
        $result.Count | Should -Be 0
    }

    It 'runs native tools with child-local environment and working directory' {
        $pwshName = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { 'pwsh.exe' } else { 'pwsh' }
        $pwshPath = Join-Path $PSHOME $pwshName
        $workRoot = Join-Path $script:Root '.build/test-native-child-context'
        [void](New-Item -ItemType Directory -Path $workRoot -Force)
        $originalLocation = (Get-Location).Path
        $originalValue = [Environment]::GetEnvironmentVariable('CAPSULENV_CHILD_TEST', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('CAPSULENV_CHILD_TEST', 'parent', 'Process')
            $result = & $script:Module {
                param($exe, $cwd)
                Invoke-CapsulenvNativeToolCapture `
                    -Executable $exe `
                    -Arguments @('-NoLogo', '-NoProfile', '-Command', '[Console]::Out.Write(($env:CAPSULENV_CHILD_TEST + "|" + (Get-Location).Path))') `
                    -WorkingDirectory $cwd `
                    -Environment @{ CAPSULENV_CHILD_TEST = 'child' }
            } $pwshPath $workRoot

            $result.ExitCode | Should -Be 0
            $parts = $result.StdOut -split '\|', 2
            $parts[0] | Should -Be 'child'
            [System.IO.Path]::GetFullPath($parts[1]) | Should -Be ([System.IO.Path]::GetFullPath($workRoot))
            [Environment]::GetEnvironmentVariable('CAPSULENV_CHILD_TEST', 'Process') | Should -Be 'parent'
            (Get-Location).Path | Should -Be $originalLocation
        } finally {
            [Environment]::SetEnvironmentVariable('CAPSULENV_CHILD_TEST', $originalValue, 'Process')
            Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'quotes arguments for the Windows PowerShell 5.1 ProcessStartInfo fallback' {
        $quoted = & $script:Module {
            @(
                ConvertTo-CapsulenvNativeCommandLineArgument -Argument 'plain'
                ConvertTo-CapsulenvNativeCommandLineArgument -Argument ''
                ConvertTo-CapsulenvNativeCommandLineArgument -Argument 'two words'
                ConvertTo-CapsulenvNativeCommandLineArgument -Argument 'C:\path with space\'
            )
        }
        $quoted[0] | Should -Be 'plain'
        $quoted[1] | Should -Be '""'
        $quoted[2] | Should -Be '"two words"'
        $quoted[3] | Should -Be '"C:\path with space\\"'
    }

    It 'can skip parent session environment mutation when the lifecycle DAG already prepared it' {
        Mock Set-CapsulenvSessionEnvironment { throw 'must not run' } -ModuleName Capsulenv
        Mock Repair-CapsulenvUvRelocation { @() } -ModuleName Capsulenv
        Mock Repair-CapsulenvPixiRelocation { @() } -ModuleName Capsulenv

        { Invoke-CapsulenvToolRelocationRepair `
            -RelocationContext ([pscustomobject]@{}) `
            -SkipWorkspaces `
            -SessionEnvironmentReady } | Should -Not -Throw
        Should -Invoke Set-CapsulenvSessionEnvironment -ModuleName Capsulenv -Times 0
    }


    It 'passes UV_PROJECT_ENVIRONMENT only to uv child processes during workspace repair' {
        $workRoot = Join-Path $script:Root '.build/test-uv-workspace-child-environment'
        $environmentPath = Join-Path $workRoot '.venv'
        $projectPath = Join-Path $workRoot 'pyproject.toml'
        [void](New-Item -ItemType Directory -Path $environmentPath -Force)
        Set-Content -LiteralPath $projectPath -Value '[project]' -Encoding UTF8
        $workspace = [pscustomobject]@{
            ProjectPath = $projectPath
            EnvironmentPath = $environmentPath
        }
        $originalValue = [Environment]::GetEnvironmentVariable('UV_PROJECT_ENVIRONMENT', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('UV_PROJECT_ENVIRONMENT', 'parent-value', 'Process')
            Mock Invoke-CapsulenvNativeTool { 0 } -ModuleName Capsulenv

            $result = & $script:Module {
                param($workspaceValue)
                Repair-CapsulenvUvWorkspace `
                    -UvExecutable 'uv.exe' `
                    -Workspace $workspaceValue `
                    -RelocatableSupported $true
            } $workspace

            $result.Status | Should -Be 'RecreatedRelocatable'
            Should -Invoke Invoke-CapsulenvNativeTool -ModuleName Capsulenv -Times 2 -Exactly -ParameterFilter {
                $Environment -is [System.Collections.IDictionary] -and
                [string]$Environment['UV_PROJECT_ENVIRONMENT'] -eq $environmentPath
            }
            [Environment]::GetEnvironmentVariable('UV_PROJECT_ENVIRONMENT', 'Process') | Should -Be 'parent-value'
        } finally {
            [Environment]::SetEnvironmentVariable('UV_PROJECT_ENVIRONMENT', $originalValue, 'Process')
            Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not mutate UV_PROJECT_ENVIRONMENT or process working directory inside workspace repair' {
        $workspaceSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/39-ToolWorkspaceRelocation.ps1') -Raw
        $nativeSource = Get-Content -LiteralPath (Join-Path $script:Root 'src/37-ToolRelocation.ps1') -Raw
        $workspaceSource | Should -Not -Match "SetEnvironmentVariable\('UV_PROJECT_ENVIRONMENT'"
        $nativeSource | Should -Not -Match 'Set-Location -LiteralPath \$WorkingDirectory'
    }

}
