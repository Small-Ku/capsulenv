Describe 'Capsulenv Gecko browser launch contracts' {
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

    It 'resolves an explicit same-product host executable without relaxing capsule executable lookup' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-browser-host-' + [Guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'config') -Force)
            Copy-Item -LiteralPath (Join-Path $script:Root 'config/capsulenv.psd1') -Destination (Join-Path $temporaryRoot 'config/capsulenv.psd1')
            $hostFirefox = Join-Path $temporaryRoot 'machine-browser/firefox.exe'
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $hostFirefox) -Force)
            '' | Set-Content -LiteralPath $hostFirefox -Encoding UTF8
            @"
@{
    Browsers = @{
        Firefox = @{
            HostExecutableCandidates = @('$($hostFirefox.Replace("'", "''"))')
            HostCommandNames = @()
        }
    }
}
"@ | Set-Content -LiteralPath (Join-Path $temporaryRoot 'config/capsulenv.local.psd1') -Encoding UTF8

            Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
            $resolved = & $script:Module {
                param($CapsuleRoot)
                Initialize-CapsulenvContext -Root $CapsuleRoot | Out-Null
                [void](Get-CapsulenvConfiguration -Refresh)
                Get-CapsulenvHostBrowserExecutable -Browser Firefox
            } $temporaryRoot
            $resolved | Should -Be ([System.IO.Path]::GetFullPath($hostFirefox))
        } finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

    It 'treats --host as a Capsulenv-only leading browser option' {
        Mock Start-CapsulenvBrowser {} -ModuleName Capsulenv
        & $script:Module {
            Invoke-CapsulenvBrowserCommand -Browser Firefox -Arguments @('--host', 'https://example.invalid/')
        }
        Should -Invoke Start-CapsulenvBrowser -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            $Browser -eq 'Firefox' -and $UseHostExecutable -and @($Arguments).Count -eq 1 -and $Arguments[0] -eq 'https://example.invalid/'
        }

        & $script:Module {
            { Invoke-CapsulenvBrowserCommand -Browser Firefox -Arguments @('https://example.invalid/', '--host') } |
                Should -Throw '*--host must be the first browser argument*'
        }
    }
}
