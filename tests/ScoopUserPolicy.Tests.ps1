Describe 'Capsulenv User Scoop shortcut isolation' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:PolicyPath = Join-Path $script:Root 'module-runtime/scoop-capsulenv-user-policy.ps1'
        $script:GatewayPath = Join-Path $script:Root 'module-runtime/scoop-capsulenv-gateway.ps1'
    }

    It 'derives a stable capsule-specific shortcut identity without touching the host' {
        $oldId = $env:CAPSULENV_ID
        try {
            $env:CAPSULENV_ID = '12345678-90ab-cdef-1234-567890abcdef'
            . $script:PolicyPath
            Get-CapsulenvScoopShortcutIdentity | Should -Be '1234567890ab'
        } finally {
            $env:CAPSULENV_ID = $oldId
            Remove-Item Function:Get-CapsulenvScoopShortcutIdentity -ErrorAction SilentlyContinue
            Remove-Item Function:shortcut_folder -ErrorAction SilentlyContinue
        }
    }

    It 'keeps User-mode shortcuts out of Scoop shared Start Menu namespace' {
        $source = [System.IO.File]::ReadAllText($script:PolicyPath)
        $source | Should -Match "'Capsulenv Apps'"
        $source | Should -Not -Match "'Scoop Apps'"
        $source | Should -Match 'CAPSULENV_ID'
    }

    It 'routes User-mode mutating Scoop commands through the User policy' {
        $source = [System.IO.File]::ReadAllText($script:GatewayPath)
        $source | Should -Match "integrationMode -eq 'User'"
        $source | Should -Match 'scoop-capsulenv-user-policy\.ps1'
        $source | Should -Match '\$command -in \$policyCommands'
    }
}
