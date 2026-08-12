Describe 'Capsulenv Scoop bootstrap and isolation smoke suite' {
    It 'passes shallow Git bootstrap, repair, archive fallback, and shell-only isolation checks' {
        & (Join-Path $PSScriptRoot 'smoke/Bootstrap.Smoke.ps1')
    }
}
