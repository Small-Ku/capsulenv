Describe 'Capsulenv host-local executable path budget' {
    BeforeAll {
        $script:Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force -DisableNameChecking
        $script:Module = Get-Module Capsulenv
    }
    AfterAll { Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue }

    It 'accepts a Windows realization whose projected executable path fits MAX_PATH' {
        Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
        Mock Get-CapsulenvIdentity { 'fixture' } -ModuleName Capsulenv
        Mock Get-CapsulenvHostPlacement { [pscustomobject]@{ PackagesRoot=(Join-Path $TestDrive 'short') } } -ModuleName Capsulenv
        { & $script:Module { Assert-CapsulenvRealizationExecutablePathBudget -Name pwsh -Version 7.6.7 -ExecutableRelativePath pwsh.exe } } | Should -Not -Throw
    }

    It 'rejects a deeply nested provider executable path without creating a host placement' {
        $longRoot = Join-Path $TestDrive ('long-' + ('x' * 135))
        Mock Test-CapsulenvWindows { $true } -ModuleName Capsulenv
        Mock Get-CapsulenvIdentity { 'fixture' } -ModuleName Capsulenv
        Mock Get-CapsulenvHostPlacement { [pscustomobject]@{ PackagesRoot=$longRoot } } -ModuleName Capsulenv
        Mock Initialize-CapsulenvHostPlacement { throw 'must not create placement' } -ModuleName Capsulenv
        {
            & $script:Module { Assert-CapsulenvRealizationExecutablePathBudget -Name pwsh -Version 7.6.7 -ExecutableRelativePath pwsh.exe }
        } | Should -Throw '*shorter CAPSULENV_HOST_STATE_ROOT*'
        Test-Path -LiteralPath $longRoot | Should -BeFalse
        Should -Invoke Initialize-CapsulenvHostPlacement -ModuleName Capsulenv -Exactly -Times 0
    }
    It 'rejects an unusable provider destination before downloading the payload' {
        Mock Initialize-CapsulenvScoopBootstrap {} -ModuleName Capsulenv
        Mock Get-CapsulenvPackageManifestPlan { [pscustomobject]@{ Version='7.6.7'; Reference='main/pwsh' } } -ModuleName Capsulenv
        Mock Test-CapsulenvProgramProviderPayloadPlan { [pscustomobject]@{ Compatible=$true; Reasons=@() } } -ModuleName Capsulenv
        Mock Get-CapsulenvProgramProviderExecutableRelativePath { 'pwsh.exe' } -ModuleName Capsulenv
        Mock Assert-CapsulenvRealizationExecutablePathBudget { throw 'host-local executable path is too long' } -ModuleName Capsulenv
        Mock Initialize-CapsulenvPortablePackageWorkerRuntime { throw 'payload download boundary was reached' } -ModuleName Capsulenv
        $requirement = & $script:Module { Get-CapsulenvInteractivePowerShellRequirement }
        {
            & $script:Module { param($Required) Get-CapsulenvProgramProviderCandidates -Requirement $Required } $requirement.Requirement
        } | Should -Throw '*host-local executable path is too long*'
        Should -Invoke Initialize-CapsulenvPortablePackageWorkerRuntime -ModuleName Capsulenv -Times 0 -Exactly
    }
}