Describe 'Realization with deep PowerShell modules' {
    BeforeAll {
        $script:Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force
        $script:Module = @(Get-Module Capsulenv)[-1]
    }
    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }
    It 'stages and publishes a directory whose nested module would exceed MAX_PATH inside an ephemeral depot' {
        $source = Join-Path $TestDrive 'pwsh-source'
        $moduleFile = Join-Path $source 'Modules/Microsoft.PowerShell.Archive/Microsoft.PowerShell.Archive.psd1'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $moduleFile) -Force)
        [IO.File]::WriteAllText($moduleFile, 'module')
        [IO.File]::WriteAllText((Join-Path $source 'pwsh.exe'), 'binary')
        $padding = 136 - $TestDrive.Length - 1
        $padding | Should -BeGreaterThan 0
        $deepRoot = Join-Path $TestDrive ('d' * $padding)
        $global:CapsulenvLongPathTestPlacement = [pscustomobject]@{
            Root = $deepRoot
            ScratchRoot = Join-Path $deepRoot 'scratch'
            PackagesRoot = Join-Path $deepRoot 'packages'
        }
        $oldRoot = $env:CAPSULENV_HOST_STATE_ROOT
        try {
            $env:CAPSULENV_HOST_STATE_ROOT = $TestDrive
            $expectedStagePath = Join-Path $global:CapsulenvLongPathTestPlacement.ScratchRoot 'realization-staging/00000000000000000000000000000000/payload/Modules/Microsoft.PowerShell.Archive/Microsoft.PowerShell.Archive.psd1'
            $expectedStagePath.Length | Should -BeGreaterOrEqual 260
            Mock Get-CapsulenvIdentity { 'test' } -ModuleName Capsulenv
            Mock Initialize-CapsulenvHostPlacement { $global:CapsulenvLongPathTestPlacement } -ModuleName Capsulenv

            $result = & $script:Module {
                param($Source)
                Acquire-CapsulenvProgramRealization -Name pwsh -Version 7.6.4 -SourcePath $Source -ExecutableRelativePath 'pwsh.exe'
            } $source

            $result.SourceHash | Should -Not -BeNullOrEmpty
            (Test-Path -LiteralPath (Join-Path $result.RealizationRoot 'payload/pwsh.exe') -PathType Leaf) | Should -BeTrue
            $longModuleFile = Join-Path $result.RealizationRoot 'payload/Modules/Microsoft.PowerShell.Archive/Microsoft.PowerShell.Archive.psd1'
            $longModuleFile.Length | Should -BeGreaterOrEqual 260
            (& $script:Module { param($Path) Test-CapsulenvProgramRealization -RealizationRoot $Path -ExpectedName pwsh } $result.RealizationRoot) | Should -BeTrue
        } finally {
            if ($null -eq $oldRoot) {
                Remove-Item Env:CAPSULENV_HOST_STATE_ROOT -ErrorAction SilentlyContinue
            } else {
                $env:CAPSULENV_HOST_STATE_ROOT = $oldRoot
            }
            Remove-Variable -Name CapsulenvLongPathTestPlacement -Scope Global -ErrorAction SilentlyContinue
        }
    }
}