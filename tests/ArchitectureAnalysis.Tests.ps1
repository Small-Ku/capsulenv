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

        function New-CapsulenvOwnedShortcutPolicy {
            $source = @'
function shortcut_folder($global) {
    return [System.IO.Path]::Combine('C:\Users\test', 'Programs', 'Capsulenv Apps', '0123456789ab')
}
'@
            return New-CapsulenvStaticFixture -Name 'owned-user-policy.ps1' -Source $source
        }
    }

    It 'rejects foreign Scoop Start Menu namespace literals in runtime code' {
        $fixture = New-CapsulenvStaticFixture -Name 'foreign-startmenu.ps1' -Source @'
function Invoke-BadShortcutTarget {
    return [System.IO.Path]::Combine('C:\Users\test', 'Programs', 'Scoop Apps')
}
'@
        $allowed = New-CapsulenvOwnedShortcutPolicy
        $violations = @(
            Get-CapsulenvHostIntegrationOwnershipViolations `
                -Paths @($fixture, $allowed) `
                -AllowedShortcutOverridePath $allowed
        )
        $violations.Count | Should -Be 1
        $violations[0].Rule | Should -Be 'HostStartMenuNamespace'
    }

    It 'allows shortcut_folder only in the capsule-owned User Scoop policy' {
        $fixture = New-CapsulenvStaticFixture -Name 'shortcut-override.ps1' -Source @'
function shortcut_folder($global) {
    return [System.IO.Path]::Combine('Programs', 'Capsulenv Apps')
}
'@
        $allowed = New-CapsulenvOwnedShortcutPolicy
        $foreignViolations = @(
            Get-CapsulenvHostIntegrationOwnershipViolations `
                -Paths @($fixture, $allowed) `
                -AllowedShortcutOverridePath $allowed
        )
        $foreignViolations.Count | Should -Be 1
        $foreignViolations[0].Rule | Should -Be 'ScoopShortcutOverrideOwnership'

        $ownedViolations = @(
            Get-CapsulenvHostIntegrationOwnershipViolations `
                -Paths @($fixture) `
                -AllowedShortcutOverridePath $fixture
        )
        $ownedViolations.Count | Should -Be 0
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

    It 'rejects a Scoop gateway that executes transformed libexec without upstream bootstrap' {
        $fixture = New-CapsulenvStaticFixture -Name 'gateway-no-bootstrap.ps1' -Source @'
$upstream = 'scoop.ps1'
$source = [System.IO.File]::ReadAllText('scoop-install.ps1')
$insertionPoint = [regex]::Match($source, '(?m)^\$opt\s*,')
$source = $source.Insert($insertionPoint.Index, '. policy.ps1')
'@
        $violations = @(Get-CapsulenvScoopGatewayBootstrapViolations -Path $fixture)
        $violations.Count | Should -BeGreaterThan 0
        @($violations.Rule) | Should -Contain 'ScoopGatewayBootstrapCapture'
        @($violations.Rule) | Should -Contain 'ScoopGatewayBootstrapPrepend'
    }

    It 'accepts a Scoop gateway that replays the installed dispatcher bootstrap before policy injection' {
        $fixture = New-CapsulenvStaticFixture -Name 'gateway-bootstrap.ps1' -Source @'
$upstream = 'scoop.ps1'
$source = [System.IO.File]::ReadAllText('scoop-install.ps1')
$upstreamSource = [System.IO.File]::ReadAllText($upstream)
$dispatcherBoundary = [regex]::Match($upstreamSource, '(?m)^switch\s*\(\s*\$subCommand\s*\)\s*\{')
if (-not $dispatcherBoundary.Success) { throw 'bad dispatch boundary' }
$bootstrapSource = $upstreamSource.Substring(0, $dispatcherBoundary.Index)
if ($bootstrapSource -notmatch '(?i)lib[\\/]core\.ps1') { throw 'bad core bootstrap' }
$source = $bootstrapSource + "`r`n" + $source
$insertionPoint = [regex]::Match($source, '(?m)^\$opt\s*,')
$source = $source.Insert($insertionPoint.Index, '. policy.ps1')
'@
        @(Get-CapsulenvScoopGatewayBootstrapViolations -Path $fixture).Count | Should -Be 0
    }

}
