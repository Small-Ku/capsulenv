Describe 'Capsulenv build-time text resources' {
    BeforeAll { $script:Root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')); . (Join-Path $script:Root 'build/CapsulenvTextResource.ps1'); $script:Catalog=Import-CapsulenvTextResourceCatalog -Path (Join-Path $script:Root 'build/i18n/en-US.json') }
    It 'loads the UTF-8 catalog' { $script:Catalog.Language|Should -Be 'en-US'; (Get-CapsulenvTextResourceValue -Catalog $script:Catalog -Key 'Context.RootMissing.Message')|Should -Match 'CAPSULENV_ROOT' }
    It 'expands a complete quoted token to a PowerShell literal' { $expanded=Expand-CapsulenvTextResourceTokens -Content "throw '[[CapsulenvText:Context.RootMissing.Message]]'" -Catalog $script:Catalog; $expanded|Should -Not -Match '\[\[CapsulenvText:'; $expanded|Should -Match "throw 'CAPSULENV_ROOT" }
    It 'rejects unknown resource keys' { { Expand-CapsulenvTextResourceTokens -Content "'[[CapsulenvText:Missing.Key]]'" -Catalog $script:Catalog } | Should -Throw '*Unknown Capsulenv text resource key*' }
    It 'leaves no text tokens or catalog dependency in the merged module' { $b=& (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean; (Get-Content -LiteralPath (Join-Path (Split-Path $b.ModulePath) 'Capsulenv.psm1') -Raw)|Should -Not -Match '\[\[CapsulenvText:'; Test-Path -LiteralPath (Join-Path (Split-Path $b.ModulePath) 'build/i18n')|Should -BeFalse }
}
