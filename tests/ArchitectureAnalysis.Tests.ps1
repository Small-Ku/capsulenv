Describe 'Capsulenv architecture static analysis' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        . (Join-Path (Join-Path $script:Root 'scripts') 'Capsulenv.StaticAnalysis.ps1')

        function New-CapsulenvStaticFixture {
            param(
                [Parameter(Mandatory = $true)][string]$Name,
                [Parameter(Mandatory = $true)][string]$Source
            )

            $path = Join-Path $TestDrive $Name
            [System.IO.File]::WriteAllText($path, $Source)
            return $path
        }
    }

    It 'rejects foreign Scoop Start Menu namespace literals in runtime code' {
        $fixture = New-CapsulenvStaticFixture -Name 'foreign-startmenu.ps1' -Source @'
function Invoke-BadShortcutTarget {
    return [System.IO.Path]::Combine('C:\Users\test', 'Programs', 'Scoop Apps')
}
'@
        $violations = @(Get-CapsulenvHostIntegrationOwnershipViolations -Paths @($fixture))
        $violations.Count | Should -Be 1
        $violations[0].Rule | Should -Be 'HostStartMenuNamespace'
    }

    It 'rejects every Scoop shortcut_folder override' {
        $fixture = New-CapsulenvStaticFixture -Name 'shortcut-override.ps1' -Source @'
function shortcut_folder($global) {
    return [System.IO.Path]::Combine('Programs', 'Capsulenv Apps')
}
'@
        $violations = @(Get-CapsulenvHostIntegrationOwnershipViolations -Paths @($fixture))
        $violations.Count | Should -Be 1
        $violations[0].Rule | Should -Be 'ScoopShortcutOverrideForbidden'
    }

    It 'rejects Scoop runtime source adapters by filename' {
        $runtimeRoot = Join-Path $TestDrive 'runtime-adapters'
        [void](New-Item -ItemType Directory -Path $runtimeRoot -Force)
        Set-Content -LiteralPath (Join-Path $runtimeRoot 'scoop-capsulenv-transform.ps1') -Value '# forbidden'
        $violations = @(Get-CapsulenvScoopRuntimeAdapterViolations -RuntimeRoot $runtimeRoot)
        $violations.Count | Should -Be 1
        $violations[0].Rule | Should -Be 'NoScoopRuntimeAdapters'
    }

    It 'accepts a runtime directory with no Scoop source adapters' {
        $runtimeRoot = Join-Path $TestDrive 'runtime-clean'
        [void](New-Item -ItemType Directory -Path $runtimeRoot -Force)
        Set-Content -LiteralPath (Join-Path $runtimeRoot 'Invoke-Capsulenv.ps1') -Value 'param()'
        @(Get-CapsulenvScoopRuntimeAdapterViolations -RuntimeRoot $runtimeRoot).Count | Should -Be 0
    }

    It 'rejects persistent ownership reads from the session mode resolver' {
        $fixture = New-CapsulenvStaticFixture -Name 'mode-persistent.ps1' -Source @'
function Get-CapsulenvInstallMode {
    if ([string]$env:CAPSULENV_MODE -eq 'User') {
        return 'User'
    }
    if (Test-CapsulenvCurrentUserIntegrationOwnership) {
        return 'User'
    }
    return 'ShellOnly'
}
'@
        $violations = @(Get-CapsulenvSessionModeBoundaryViolations -Path $fixture)
        $violations.Count | Should -Be 1
        $violations[0].Rule | Should -Be 'SessionModeCommandDependency'
    }

    It 'accepts invocation-scoped CAPSULENV_MODE as the session selector' {
        $fixture = New-CapsulenvStaticFixture -Name 'mode-process.ps1' -Source @'
function Get-CapsulenvInstallMode {
    if ([string]$env:CAPSULENV_MODE -eq 'User') {
        return 'User'
    }
    return 'ShellOnly'
}
'@
        @(Get-CapsulenvSessionModeBoundaryViolations -Path $fixture).Count | Should -Be 0
    }

    It 'rejects direct member access on declared external JSON record variables' {
        $fixture = New-CapsulenvStaticFixture -Name 'external-json-unsafe.ps1' -Source @'
function Get-CapsulenvUvManagedPythonInstallations {
    foreach ($item in @()) {
        $key = $item.key
    }
}
'@
        $violations = @(
            Get-CapsulenvExternalJsonMemberViolations `
                -Path $fixture `
                -FunctionName 'Get-CapsulenvUvManagedPythonInstallations' `
                -RecordVariables @('item')
        )
        $violations.Count | Should -Be 1
        $violations[0].Rule | Should -Be 'ExternalJsonSafePropertyAccess'
    }

    It 'accepts the safe property accessor for external JSON records' {
        $fixture = New-CapsulenvStaticFixture -Name 'external-json-safe.ps1' -Source @'
function Get-CapsulenvUvManagedPythonInstallations {
    foreach ($item in @()) {
        $key = Get-CapsulenvObjectPropertyValue -InputObject $item -Name 'key'
    }
}
'@
        @(
            Get-CapsulenvExternalJsonMemberViolations `
                -Path $fixture `
                -FunctionName 'Get-CapsulenvUvManagedPythonInstallations' `
                -RecordVariables @('item')
        ).Count | Should -Be 0
    }

    It 'rejects a Scoop shim that routes direct commands through a Capsulenv gateway' {
        $fixture = New-CapsulenvStaticFixture -Name 'gateway-shim.ps1' -Source @'
function Install-CapsulenvScoopShim {
    $path = Get-CapsulenvModuleRuntimePath -Name 'scoop-capsulenv-gateway.ps1'
    $ps1Text = '$PSScriptRoot'
    $cmdText = '%~dp0'
}
'@
        $violations = @(Get-CapsulenvStockScoopBoundaryViolations -Path $fixture)
        @($violations.Rule) | Should -Contain 'StockScoopNoGateway'
        @($violations.Rule) | Should -Contain 'StockScoopNoRuntimeTransform'
    }

    It 'accepts a cmd-only trampoline while PowerShell resolves upstream Scoop directly from PATH' {
        $fixture = New-CapsulenvStaticFixture -Name 'stock-shim.ps1' -Source @'
function Install-CapsulenvScoopShim {
    $cmdText = @"
set "UPSTREAM=%~dp0..\apps\scoop\current\bin\scoop.ps1"
"@
}
'@
        @(Get-CapsulenvStockScoopBoundaryViolations -Path $fixture).Count | Should -Be 0
    }

}
