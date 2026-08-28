Describe 'Capsulenv structured diagnostics' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force
        $script:Module = Get-Module Capsulenv
    }
    AfterAll { Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue }

    It 'preserves stable id, context, hints, and remediation' {
        $record = & $script:Module {
            New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Test.Sample' -Message 'sample' -Context ([ordered]@{ Item = 'demo' }) -Hints @('hint') -Remediation @('repair')
        }
        $record.FullyQualifiedErrorId | Should -Be 'Capsulenv.Test.Sample'
        (& $script:Module { param($r) (Get-CapsulenvDiagnosticContext -ErrorRecord $r).Item } $record) | Should -Be 'demo'
        @(& $script:Module { param($r) Get-CapsulenvDiagnosticHints -ErrorRecord $r } $record) | Should -Contain 'hint'
        @(& $script:Module { param($r) Get-CapsulenvDiagnosticRemediation -ErrorRecord $r } $record) | Should -Contain 'repair'
    }

    It 'keeps only safe metadata from an upstream cause' {
        $cause = $null
        try { throw ([System.Exception]::new('secret-body')) } catch { $cause = $_ }
        $record = & $script:Module { param($c) New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Test.Wrapped' -Message 'wrapped' -Cause $c } $cause
        $record.Exception.InnerException | Should -BeNullOrEmpty
        $record.Exception.Data['CapsulenvDiagnosticCauseType'] | Should -Be 'System.Exception'
        $record.Exception.Data.Contains('Response') | Should -BeFalse
    }

    It 'does not overwrite an existing Capsulenv diagnostic' {
        $existing = & $script:Module { New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Test.Existing' -Message 'existing' }
        $converted = & $script:Module { param($r) ConvertTo-CapsulenvDiagnosticErrorRecord -ErrorRecord $r -Id 'Capsulenv.Test.Other' -Message 'other' } $existing
        $converted.FullyQualifiedErrorId | Should -Be 'Capsulenv.Test.Existing'
    }
}
