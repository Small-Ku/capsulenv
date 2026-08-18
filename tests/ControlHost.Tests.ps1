Describe 'Capsulenv control-host bootstrap' {
    It 'restores the PowerShell built-in module root without importing Utility' {
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $bootstrap = Join-Path (Join-Path $root 'module-runtime') 'Initialize-CapsulenvControlHost.ps1'
        $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('capsulenv-control-host-' + [Guid]::NewGuid().ToString('N'))
        $fakeModuleRoot = Join-Path (Join-Path (Join-Path $temporaryRoot 'Microsoft.PowerShell.Utility') '99.0.0') 'Microsoft.PowerShell.Utility.psd1'
        $previousModulePath = $env:PSModulePath

        try {
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $fakeModuleRoot) -Force)
            @"
@{
    ModuleVersion = '99.0.0'
    GUID = '4f0d0d09-1c99-4da7-8477-d187936d56f3'
    FunctionsToExport = @()
    CmdletsToExport = @()
}
"@ | Set-Content -LiteralPath $fakeModuleRoot -Encoding UTF8

            $env:PSModulePath = $temporaryRoot
            . $bootstrap

            $builtInModuleRoot = [System.IO.Path]::Combine($PSHOME, 'Modules')
            $firstModulePath = @($env:PSModulePath -split [regex]::Escape([string][System.IO.Path]::PathSeparator))[0]
            $firstModulePath | Should -Be $builtInModuleRoot
        } finally {
            $env:PSModulePath = $previousModulePath
            if (Test-Path -LiteralPath $temporaryRoot) {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
            }
        }
    }

    It 'is idempotent when the built-in module root is already first' {
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $bootstrap = Join-Path (Join-Path $root 'module-runtime') 'Initialize-CapsulenvControlHost.ps1'
        $previousModulePath = $env:PSModulePath
        $builtInModuleRoot = [System.IO.Path]::Combine($PSHOME, 'Modules')
        try {
            $env:PSModulePath = $builtInModuleRoot + [string][System.IO.Path]::PathSeparator + 'capsulenv-sentinel'
            . $bootstrap
            . $bootstrap

            $entries = @($env:PSModulePath -split [regex]::Escape([string][System.IO.Path]::PathSeparator))
            $entries[0] | Should -Be $builtInModuleRoot
            @($entries | Where-Object { $_ -eq $builtInModuleRoot }).Count | Should -Be 1
        } finally {
            $env:PSModulePath = $previousModulePath
        }
    }
}
