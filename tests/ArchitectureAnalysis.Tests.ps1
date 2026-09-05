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


    It 'rejects sing-box or rclone runtime specializations' {
        $fixture = New-CapsulenvStaticFixture -Name 'workload-specialization.ps1' -Source @'
function Connect-CapsulenvSingBox {
    $config = Get-CapsulenvConfiguration
    return $config.SingBox
}
'@
        $violations = @(Get-CapsulenvWorkloadSpecializationViolations -Paths @($fixture))
        @($violations.Rule) | Should -Contain 'NoWorkloadSpecializedRuntime'
        @($violations.Rule) | Should -Contain 'NoWorkloadSpecializedConfiguration'
    }

    It 'accepts generic lifecycle routine runtime code' {
        $fixture = New-CapsulenvStaticFixture -Name 'generic-routine.ps1' -Source @'
function Invoke-CapsulenvRoutine {
    $config = Get-CapsulenvConfiguration
    return $config.Routines
}
'@
        @(Get-CapsulenvWorkloadSpecializationViolations -Paths @($fixture)).Count | Should -Be 0
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

    It 'rejects explicit null passed to a mandatory local function parameter without AllowNull' {
        $fixture = New-CapsulenvStaticFixture -Name 'mandatory-null.ps1' -Source @'
function Invoke-Target {
    param([Parameter(Mandatory = $true)][string]$Name)
}
Invoke-Target -Name $null
'@
        $violations = @(Get-CapsulenvMandatoryParameterBindingViolations -Paths @($fixture))
        $violations.Count | Should -Be 1
        $violations[0].Rule | Should -Be 'MandatoryParameterExplicitEmptyValue'
    }

    It 'accepts explicit null when the mandatory local function parameter allows null' {
        $fixture = New-CapsulenvStaticFixture -Name 'mandatory-null-allowed.ps1' -Source @'
function Invoke-Target {
    param([AllowNull()][Parameter(Mandatory = $true)][string]$Name)
}
Invoke-Target -Name $null
'@
        @(Get-CapsulenvMandatoryParameterBindingViolations -Paths @($fixture)).Count | Should -Be 0
    }

    It 'rejects unparenthesized desired-state node constructors inside array subexpressions' {
        $fixture = New-CapsulenvStaticFixture -Name 'desired-state-binding-unsafe.ps1' -Source @'
$nodes = @(
    New-CapsulenvDesiredStateNode -Id a -Plan { 1 } -Apply { 2 } -Verify { 3 }
    New-CapsulenvDesiredStateNode -Id b -Plan { 1 } -Apply { 2 } -Verify { 3 }
)
'@
        $violations = @(Get-CapsulenvDesiredStateNodeBindingBoundaryViolations -Paths @($fixture))
        $violations.Count | Should -Be 2
        @($violations.Rule | Select-Object -Unique) | Should -Be @('DesiredStateNodeScriptBlockBoundary')
    }

    It 'accepts explicit desired-state node expression boundaries inside array subexpressions' {
        $fixture = New-CapsulenvStaticFixture -Name 'desired-state-binding-safe.ps1' -Source @'
$nodes = @(
    (New-CapsulenvDesiredStateNode -Id a -Plan { 1 } -Apply { 2 } -Verify { 3 })
    (New-CapsulenvDesiredStateNode -Id b -Plan { 1 } -Apply { 2 } -Verify { 3 })
)
'@
        @(Get-CapsulenvDesiredStateNodeBindingBoundaryViolations -Paths @($fixture)).Count | Should -Be 0
    }

    It 'rejects PowerShell array += inside a loop when the variable is known to be an array' {
        $fixture = New-CapsulenvStaticFixture -Name 'loop-array-append.ps1' -Source @'
$items = @()
foreach ($item in 1..3) {
    $items += $item
}
'@
        $violations = @(Get-CapsulenvLoopArrayAppendViolations -Paths @($fixture))
        $violations.Count | Should -Be 1
        $violations[0].Rule | Should -Be 'LoopArrayAppend'
    }

    It 'accepts List[T].Add inside a loop' {
        $fixture = New-CapsulenvStaticFixture -Name 'loop-list-add.ps1' -Source @'
$items = New-Object System.Collections.Generic.List[object]
foreach ($item in 1..3) {
    $items.Add($item)
}
'@
        @(Get-CapsulenvLoopArrayAppendViolations -Paths @($fixture)).Count | Should -Be 0
    }

}
