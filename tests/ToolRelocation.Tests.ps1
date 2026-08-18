Describe 'Capsulenv tool relocation parsing' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
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
}
