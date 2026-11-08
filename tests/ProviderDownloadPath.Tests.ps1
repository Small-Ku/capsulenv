Describe 'Provider download staging paths' {
    BeforeAll {
        $script:Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force
        $script:Module = @(Get-Module Capsulenv)[-1]
    }

    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }

    It 'downloads and verifies a provider payload without a 260-character temporary path' {
        $source = Join-Path $TestDrive 'source.zip'
        [IO.File]::WriteAllBytes($source, [Text.Encoding]::UTF8.GetBytes('verified local payload'))
        $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        $paddingLength = 140 - $TestDrive.Length - 1
        $paddingLength | Should -BeGreaterThan 0
        $cacheRoot = Join-Path $TestDrive ('x' * $paddingLength)
        $hashDirectory = Join-Path (Join-Path $cacheRoot 'provider-artifacts') $hash
        ((Join-Path $hashDirectory ('.download-' + ('0' * 32))).Length) | Should -BeGreaterOrEqual 260

        $global:CapsulenvTestProviderCacheRoot = $cacheRoot
        $global:CapsulenvTestDownloadDestinations = New-Object System.Collections.Generic.List[string]
        try {
            Mock Get-CapsulenvIdentity { 'test-capsule' } -ModuleName Capsulenv
            Mock Initialize-CapsulenvHostPlacement {
                [pscustomobject]@{ CacheRoot = $global:CapsulenvTestProviderCacheRoot }
            } -ModuleName Capsulenv
            Mock Copy-Item {
                param($LiteralPath, $Destination, $Force)
                $global:CapsulenvTestDownloadDestinations.Add([string]$Destination)
                [IO.File]::Copy([string]$LiteralPath, [string]$Destination, $true)
            } -ModuleName Capsulenv

            $download = [pscustomobject]@{
                Index = 0
                FileName = 'provider.zip'
                Hash = $hash
                Url = ([Uri]::new([IO.Path]::GetFullPath($source), [UriKind]::Absolute)).AbsoluteUri
            }
            $destination = Join-Path $TestDrive 'downloads'
            $result = & $script:Module {
                param($Download, $Destination)
                Copy-CapsulenvProgramProviderDownload -Download $Download -Destination $Destination
            } $download $destination

            $global:CapsulenvTestDownloadDestinations.Count | Should -Be 2
            $temporary = [string]$global:CapsulenvTestDownloadDestinations[0]
            (Split-Path -Parent $temporary) | Should -Be $cacheRoot
            $temporary.Length | Should -BeLessThan 260
            (Get-FileHash -LiteralPath $result -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $hash
            (Get-FileHash -LiteralPath (Join-Path $hashDirectory 'provider.zip') -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $hash
            (Test-Path -LiteralPath $temporary) | Should -BeFalse

            $again = & $script:Module {
                param($Download, $Destination)
                Copy-CapsulenvProgramProviderDownload -Download $Download -Destination $Destination
            } $download (Join-Path $TestDrive 'downloads-again')
            $global:CapsulenvTestDownloadDestinations.Count | Should -Be 3
            (Get-FileHash -LiteralPath $again -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $hash
        } finally {
            Remove-Variable -Name CapsulenvTestProviderCacheRoot, CapsulenvTestDownloadDestinations -Scope Global -ErrorAction SilentlyContinue
        }
    }
}