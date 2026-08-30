Describe 'Capsulenv CLI UX' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force
        $script:Module = Get-Module Capsulenv
        $script:OldRoot = $env:CAPSULENV_ROOT
        $env:CAPSULENV_ROOT = $script:Root
    }

    AfterAll {
        if ($null -eq $script:OldRoot) { Remove-Item Env:CAPSULENV_ROOT -ErrorAction SilentlyContinue } else { $env:CAPSULENV_ROOT = $script:OldRoot }
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }

    It 'exposes a categorized command discovery catalog with focused action metadata' {
        $model = & $script:Module {
            [pscustomobject]@{
                Commands = @(Get-CapsulenvCliCommandCatalog)
                AppActions = @(Get-CapsulenvCliActionCatalog -Group app)
                Update = @(Get-CapsulenvCliActionCatalog -Group app | Where-Object Name -eq update)[0]
            }
        }
        @($model.Commands.Category) | Should -Contain 'Packages'
        @($model.Commands.Name) | Should -Contain 'doctor'
        @($model.AppActions.Name) | Should -Contain 'update'
        $model.Update.Usage | Should -Be 'capsulenv app update <app|bucket/app|scope/app> [--allow-trusted] [--local]'
    }

    It 'suggests the nearest top-level command for a typo' {
        $record = & $script:Module {
            try { Invoke-Capsulenv buckte } catch { $_ }
        }
        $record.FullyQualifiedErrorId | Should -Be 'Capsulenv.Cli.UnknownCommand'
        $remediation = & $script:Module { param($r) @(Get-CapsulenvDiagnosticRemediation -ErrorRecord $r) } $record
        ($remediation -join ' ') | Should -Match "Did you mean 'capsulenv bucket'"
    }

    It 'suggests the nearest group action while preserving the stable app diagnostic id' {
        $record = & $script:Module {
            try { Invoke-Capsulenv app udpate } catch { $_ }
        }
        $record.FullyQualifiedErrorId | Should -Be 'Capsulenv.Cli.UnknownAppAction'
        $remediation = & $script:Module { param($r) @(Get-CapsulenvDiagnosticRemediation -ErrorRecord $r) } $record
        ($remediation -join ' ') | Should -Match "capsulenv app update"
        ($remediation -join ' ') | Should -Match 'Available actions:'
    }

    It 'converts legacy Usage exceptions at the dispatcher boundary into structured guidance' {
        $record = & $script:Module {
            try { Invoke-Capsulenv status extra } catch { $_ }
        }
        $record.FullyQualifiedErrorId | Should -Be 'Capsulenv.Cli.Usage'
        $record.Exception.Message | Should -Be "Invalid arguments for 'status'."
        $remediation = & $script:Module { param($r) @(Get-CapsulenvDiagnosticRemediation -ErrorRecord $r) } $record
        $remediation | Should -Contain 'Usage: capsulenv status'
        $remediation | Should -Contain "Run 'capsulenv help status' for details."
    }

    It 'supports direct --help for simple top-level commands' {
        $inline = & $script:Module {
            $InformationPreference = 'Continue'
            Invoke-Capsulenv status --help 6>&1 | Out-String
        }
        $inline | Should -Match 'Usage: capsulenv status'
        $inline | Should -Match 'compact capsule readiness'
    }

    It 'supports focused action help through both help and group --help forms' {
        $focused = & $script:Module {
            $InformationPreference = 'Continue'
            Invoke-Capsulenv help app update 6>&1 | Out-String
        }
        $inline = & $script:Module {
            $InformationPreference = 'Continue'
            Invoke-Capsulenv cache status --help 6>&1 | Out-String
        }
        $focused | Should -Match 'Usage: capsulenv app update'
        $inline | Should -Match 'Usage: capsulenv cache status'
    }

    It 'gives typo guidance for unknown help topics' {
        $record = & $script:Module {
            try { Invoke-Capsulenv help buckte } catch { $_ }
        }
        $record.FullyQualifiedErrorId | Should -Be 'Capsulenv.Cli.UnknownHelpTopic'
        $remediation = & $script:Module { param($r) @(Get-CapsulenvDiagnosticRemediation -ErrorRecord $r) } $record
        ($remediation -join ' ') | Should -Match 'help bucket'
    }
}
