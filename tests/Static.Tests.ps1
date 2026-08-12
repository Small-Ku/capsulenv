Describe 'Capsulenv static and relocation smoke suite' {
    It 'passes static, module, relocation, cache, and command contract checks' {
        & (Join-Path $PSScriptRoot 'smoke/Static.Smoke.ps1')
    }
}
