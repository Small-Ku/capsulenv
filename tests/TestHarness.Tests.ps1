Describe 'Capsulenv test harness isolation' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:Pwsh = [string](Get-Process -Id $PID).Path
    }

    It 'routes implicit module builds through the per-suite build root' {
        $buildRoot = Join-Path $TestDrive 'isolated-build'
        $oldBuildRoot = $env:CAPSULENV_BUILD_ROOT
        try {
            $env:CAPSULENV_BUILD_ROOT = $buildRoot
            $build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
            [System.IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $build.ModulePath))) |
                Should -Be ([System.IO.Path]::GetFullPath($buildRoot))
            Test-Path -LiteralPath (Join-Path $buildRoot 'Capsulenv/Capsulenv.psm1') -PathType Leaf |
                Should -BeTrue
        } finally {
            $env:CAPSULENV_BUILD_ROOT = $oldBuildRoot
        }
    }

    It 'always writes a structured result for suite infrastructure failures' {
        $runner = Join-Path (Join-Path $script:Root 'scripts') 'Invoke-CapsulenvPesterSuite.ps1'
        $resultPath = Join-Path $TestDrive 'infrastructure-result.json'
        $oldSuite = $env:CAPSULENV_TEST_SUITE_PATH
        $oldResult = $env:CAPSULENV_TEST_SUITE_RESULT_PATH
        try {
            $env:CAPSULENV_TEST_SUITE_PATH = Join-Path $TestDrive 'missing.Tests.ps1'
            $env:CAPSULENV_TEST_SUITE_RESULT_PATH = $resultPath
            & $script:Pwsh -NoProfile -NonInteractive -File $runner
            $LASTEXITCODE | Should -Be 1
            Test-Path -LiteralPath $resultPath -PathType Leaf | Should -BeTrue
            $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            $result.InfrastructureFailed | Should -Be 1
            [string]$result.InfrastructureError | Should -Match 'does not identify a Pester suite'
        } finally {
            $env:CAPSULENV_TEST_SUITE_PATH = $oldSuite
            $env:CAPSULENV_TEST_SUITE_RESULT_PATH = $oldResult
        }
    }
}
