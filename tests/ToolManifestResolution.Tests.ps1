Describe 'Capsulenv tool executable manifest selection' {
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

    It 'resolves uv from the configured installed Scoop app selector instead of hard-coded app paths' {
        Mock Get-CapsulenvToolRelocationConfiguration {
            @{
                Uv = @{ App = 'global/private-uv'; BinName = 'uv-custom' }
                Pixi = @{ App = 'pixi'; BinName = 'pixi' }
            }
        } -ModuleName Capsulenv
        Mock Get-CapsulenvInstalledScoopApp {
            [pscustomobject]@{ Selector = 'global/private-uv' }
        } -ModuleName Capsulenv
        Mock Resolve-CapsulenvScoopAppExecutable { 'X:\scoop-global\apps\private-uv\current\uv.exe' } -ModuleName Capsulenv
        Mock Test-CapsulenvPortableToolExecutable { $true } -ModuleName Capsulenv

        $resolved = & $script:Module { Get-CapsulenvUvExecutable }

        $resolved | Should -Be 'X:\scoop-global\apps\private-uv\current\uv.exe'
        Should -Invoke Get-CapsulenvInstalledScoopApp -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            $Selector -eq 'global/private-uv' -and $AllowMissing
        }
        Should -Invoke Resolve-CapsulenvScoopAppExecutable -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            $App -eq 'global/private-uv' -and $BinName -eq 'uv-custom'
        }
    }

    It 'resolves pixi from a custom Scoop app selector' {
        Mock Get-CapsulenvToolRelocationConfiguration {
            @{
                Uv = @{ App = 'uv'; BinName = 'uv' }
                Pixi = @{ App = 'user/private-pixi'; BinName = 'pixi-custom' }
            }
        } -ModuleName Capsulenv
        Mock Get-CapsulenvInstalledScoopApp {
            [pscustomobject]@{ Selector = 'user/private-pixi' }
        } -ModuleName Capsulenv
        Mock Resolve-CapsulenvScoopAppExecutable { 'X:\scoop\apps\private-pixi\current\pixi.exe' } -ModuleName Capsulenv
        Mock Test-CapsulenvPortableToolExecutable { $true } -ModuleName Capsulenv

        $resolved = & $script:Module { Get-CapsulenvPixiExecutable }

        $resolved | Should -Be 'X:\scoop\apps\private-pixi\current\pixi.exe'
        Should -Invoke Resolve-CapsulenvScoopAppExecutable -ModuleName Capsulenv -Times 1 -Exactly -ParameterFilter {
            $App -eq 'user/private-pixi' -and $BinName -eq 'pixi-custom'
        }
    }

    It 'uses capsule-owned fallback tools only when the selected Scoop app is absent' {
        Mock Get-CapsulenvToolRelocationConfiguration {
            @{
                Uv = @{ App = 'missing-uv'; BinName = 'uv' }
                Pixi = @{ App = 'pixi'; BinName = 'pixi' }
            }
        } -ModuleName Capsulenv
        Mock Get-CapsulenvInstalledScoopApp { $null } -ModuleName Capsulenv
        Mock Resolve-CapsulenvScoopAppExecutable { throw 'must not resolve an absent app' } -ModuleName Capsulenv
        Mock Resolve-CapsulenvPath {
            param($Path, $AllowMissing)
            if ($Path -eq 'tool-data\cargo\bin\uv.exe') { 'X:\tool-data\cargo\bin\uv.exe' } else { 'X:\missing.exe' }
        } -ModuleName Capsulenv
        Mock Test-Path {
            param($LiteralPath, $PathType)
            $LiteralPath -eq 'X:\tool-data\cargo\bin\uv.exe'
        } -ModuleName Capsulenv
        Mock Test-CapsulenvPortableToolExecutable { $true } -ModuleName Capsulenv

        $resolved = & $script:Module { Get-CapsulenvUvExecutable }

        $resolved | Should -Be 'X:\tool-data\cargo\bin\uv.exe'
        Should -Invoke Resolve-CapsulenvScoopAppExecutable -ModuleName Capsulenv -Times 0 -Exactly
    }
}
