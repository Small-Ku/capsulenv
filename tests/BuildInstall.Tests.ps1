Describe 'Capsulenv build and install smoke suite' {
    It 'passes runtime build, shell-only install, update preservation, and installed-module checks' {
        & (Join-Path $PSScriptRoot 'smoke/BuildInstall.Smoke.ps1')
    }
}
