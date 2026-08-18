Describe 'Capsulenv PowerShell data-file reader' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force -DisableNameChecking
        $script:Module = @(Get-Module Capsulenv)[-1]
    }

    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }

    It 'reads the shipped configuration without Import-PowerShellDataFile' {
        $path = Join-Path $script:Root 'config/capsulenv.psd1'
        $configuration = & $script:Module { param($dataPath) Import-CapsulenvPowerShellDataFile -LiteralPath $dataPath } $path

        $configuration.SchemaVersion | Should -Be 11
        $configuration.Scoop.RehydrateOnRelocation | Should -BeTrue
        $configuration.Browsers.ContainsKey('LibreWolf') | Should -BeTrue
    }

    It 'accepts only one safe hashtable expression' {
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-data-file-' + [Guid]::NewGuid().ToString('N'))
        $safePath = Join-Path $temporaryRoot 'safe.psd1'
        $dynamicPath = Join-Path $temporaryRoot 'dynamic.psd1'
        $multiplePath = Join-Path $temporaryRoot 'multiple.psd1'
        try {
            [void](New-Item -ItemType Directory -Path $temporaryRoot -Force)
            "@{ Enabled = `$true; Nested = @{ Values = @(1, 'two') } }" | Set-Content -LiteralPath $safePath -Encoding UTF8
            "@{ Value = (Get-Date) }" | Set-Content -LiteralPath $dynamicPath -Encoding UTF8
            "@{ A = 1 }; @{ B = 2 }" | Set-Content -LiteralPath $multiplePath -Encoding UTF8

            $safe = & $script:Module { param($dataPath) Import-CapsulenvPowerShellDataFile -LiteralPath $dataPath } $safePath
            $safe.Enabled | Should -BeTrue
            $safe.Nested.Values.Count | Should -Be 2

            {
                & $script:Module { param($dataPath) Import-CapsulenvPowerShellDataFile -LiteralPath $dataPath } $dynamicPath
            } | Should -Throw '*unsafe or dynamic expression*'
            {
                & $script:Module { param($dataPath) Import-CapsulenvPowerShellDataFile -LiteralPath $dataPath } $multiplePath
            } | Should -Throw '*exactly one hashtable expression*'
        } finally {
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }
}
