Describe 'Capsulenv Scoop gateway execution context' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:PowerShellExecutable = (Get-Process -Id $PID).Path

        function ConvertTo-CapsulenvSingleQuotedLiteral {
            param([Parameter(Mandatory = $true)][string]$Value)
            return "'" + $Value.Replace("'", "''") + "'"
        }

        function New-CapsulenvGatewayFixture {
            param([Parameter(Mandatory = $true)][string]$RootPath)

            $runtime = Join-Path $RootPath 'runtime'
            $scoop = Join-Path $RootPath 'scoop'
            $current = Join-Path $scoop 'apps/scoop/current'
            foreach ($path in @(
                $runtime,
                (Join-Path $current 'bin'),
                (Join-Path $current 'lib'),
                (Join-Path $current 'libexec'),
                (Join-Path $scoop 'shims')
            )) {
                [void](New-Item -ItemType Directory -Path $path -Force)
            }

            foreach ($name in @(
                'scoop-capsulenv-gateway.ps1',
                'scoop-capsulenv-shellonly-policy.ps1',
                'scoop-capsulenv-user-policy.ps1'
            )) {
                Copy-Item `
                    -LiteralPath (Join-Path (Join-Path $script:Root 'module-runtime') $name) `
                    -Destination (Join-Path $runtime $name) `
                    -Force
            }

            @'
#Requires -Version 5
Set-StrictMode -Off
. "$PSScriptRoot\..\lib\core.ps1"
. "$PSScriptRoot\..\lib\buckets.ps1"
. "$PSScriptRoot\..\lib\commands.ps1"
. "$PSScriptRoot\..\lib\help.ps1"
$subCommand = $Args[0]
$aliases = @()
switch ($subCommand) {
    default { exit 0 }
}
'@ | Set-Content -LiteralPath (Join-Path $current 'bin/scoop.ps1') -Encoding UTF8

            @'
$scoopConfig = [pscustomobject]@{
    sentinel = 'core-loaded'
    use_sqlite_cache = $false
}
function get_config($name, $default) {
    $property = $scoopConfig.PSObject.Properties[[string]$name.ToLowerInvariant()]
    if ($null -eq $property) { return $default }
    return $property.Value
}
'@ | Set-Content -LiteralPath (Join-Path $current 'lib/core.ps1') -Encoding UTF8

            foreach ($name in @('buckets', 'commands', 'help')) {
                '# fixture bootstrap dependency' |
                    Set-Content -LiteralPath (Join-Path $current ("lib/{0}.ps1" -f $name)) -Encoding UTF8
            }

            @'
$beforePolicy = get_config 'sentinel' 'missing'
if ($false) { & "$PSScriptRoot\scoop-update.ps1" }
$opt, $apps, $err = @{}, @($args), $null
[System.IO.File]::WriteAllText($env:CAPSULENV_GATEWAY_SENTINEL, $beforePolicy)
exit 0
'@ | Set-Content -LiteralPath (Join-Path $current 'libexec/scoop-install.ps1') -Encoding UTF8

            return [pscustomobject]@{
                Root = $RootPath
                Scoop = $scoop
                Current = $current
                Gateway = Join-Path $runtime 'scoop-capsulenv-gateway.ps1'
                Sentinel = Join-Path $RootPath 'gateway-sentinel.txt'
            }
        }

        function Invoke-CapsulenvGatewayFixture {
            param(
                [Parameter(Mandatory = $true)]$Fixture,
                [string[]]$Arguments = @('install', 'mysql', 'mysql-workbench')
            )

            $scoopLiteral = ConvertTo-CapsulenvSingleQuotedLiteral $Fixture.Scoop
            $rootLiteral = ConvertTo-CapsulenvSingleQuotedLiteral $Fixture.Root
            $sentinelLiteral = ConvertTo-CapsulenvSingleQuotedLiteral $Fixture.Sentinel
            $gatewayLiteral = ConvertTo-CapsulenvSingleQuotedLiteral $Fixture.Gateway
            $argumentText = (@($Arguments) | ForEach-Object { ConvertTo-CapsulenvSingleQuotedLiteral $_ }) -join ', '
            $command = @"
`$env:SCOOP = $scoopLiteral
`$env:CAPSULENV_ROOT = $rootLiteral
`$env:CAPSULENV_MODE = 'ShellOnly'
`$env:CAPSULENV_GATEWAY_SENTINEL = $sentinelLiteral
& $gatewayLiteral @($argumentText)
"@
            $output = @(& $script:PowerShellExecutable -NoLogo -NoProfile -Command $command 2>&1)
            return [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output = ($output | Out-String)
            }
        }
    }

    It 'replays Scoop dispatcher bootstrap before the transformed install libexec needs get_config' {
        $fixture = New-CapsulenvGatewayFixture -RootPath (Join-Path $TestDrive 'bootstrap-context')
        $result = Invoke-CapsulenvGatewayFixture -Fixture $fixture

        $result.ExitCode | Should -Be 0
        (Get-Content -LiteralPath $fixture.Sentinel -Raw).Trim() | Should -Be 'core-loaded'
        @(Get-ChildItem -LiteralPath (Join-Path $fixture.Current 'libexec') -Filter '.capsulenv-*.ps1' -File).Count |
            Should -Be 0
    }

    It 'fails closed when the installed Scoop dispatcher bootstrap boundary is unknown' {
        $fixture = New-CapsulenvGatewayFixture -RootPath (Join-Path $TestDrive 'unsupported-dispatcher')
        @'
Set-StrictMode -Off
. "$PSScriptRoot\..\lib\core.ps1"
'@ | Set-Content -LiteralPath (Join-Path $fixture.Current 'bin/scoop.ps1') -Encoding UTF8

        $result = Invoke-CapsulenvGatewayFixture -Fixture $fixture

        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'Unsupported Scoop dispatcher layout'
        Test-Path -LiteralPath $fixture.Sentinel | Should -BeFalse
    }
}
