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
        $allowed = Join-Path $TestDrive 'allowed-user-policy.ps1'
        $violations = @(
            Get-CapsulenvHostIntegrationOwnershipViolations `
                -Paths @($fixture) `
                -AllowedShortcutOverridePath $allowed
        )
        $violations.Count | Should -Be 1
        $violations[0].Rule | Should -Be 'HostStartMenuNamespace'
    }

    It 'allows shortcut_folder only in the capsule-owned User Scoop policy' {
        $fixture = New-CapsulenvStaticFixture -Name 'shortcut-override.ps1' -Source @'
function shortcut_folder($global) {
    return 'owned'
}
'@
        $foreignViolations = @(
            Get-CapsulenvHostIntegrationOwnershipViolations `
                -Paths @($fixture) `
                -AllowedShortcutOverridePath (Join-Path $TestDrive 'somewhere-else.ps1')
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
    if (Test-CapsulenvCurrentUserIntegrationOwnership) {
        return 'User'
    }
    return 'ShellOnly'
}
'@
        $violations = @(Get-CapsulenvSessionModeBoundaryViolations -Path $fixture)
        $violations.Count | Should -Be 1
        $violations[0].Rule | Should -Be 'SessionModeOwnershipSeparation'
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
}
