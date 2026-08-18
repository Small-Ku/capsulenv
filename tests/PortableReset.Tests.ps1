Describe 'Capsulenv portable Scoop reset process guard' {
    BeforeAll {
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $path = Join-Path $root 'module-runtime/scoop-capsulenv-process-guard.ps1'
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $path,
            [ref]$tokens,
            [ref]$errors
        )
        if ($errors.Count -gt 0) {
            throw "Portable reset script did not parse: $($errors[0].Message)"
        }
        $functionAst = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Test-CapsulenvResetHasBlockingProcesses'
        }, $true)
        if ($null -eq $functionAst) {
            throw 'Capsulenv reset process guard function was not found.'
        }
        $script:GuardDefinition = $functionAst.Extent.Text
    }

    It 'ignores only the portable reset host process' {
        $result = & {
            param($Definition)

            $fakeProcesses = @(
                [pscustomobject]@{
                    Id = $PID
                    Path = 'C:\capsule\scoop\apps\pwsh\7.6.4\pwsh.exe'
                }
            )
            function appdir { param($App, $Global) 'C:\capsule\scoop\apps\pwsh' }
            function Convert-Path {
                [CmdletBinding()]
                param([Parameter(ValueFromPipeline = $true)][string]$Path)
                process { $Path }
            }
            function Get-Process {
                [CmdletBinding()]
                param()
                $fakeProcesses
            }
            function test_running_process { throw 'upstream guard must not run for only the current PID' }

            . ([scriptblock]::Create($Definition))
            Test-CapsulenvResetHasBlockingProcesses -App 'pwsh' -Global $false
        } $script:GuardDefinition

        $result | Should -BeFalse
    }

    It 'delegates to Scoop when another process from the same app is running' {
        {
            & {
                param($Definition)

                $fakeProcesses = @(
                    [pscustomobject]@{
                        Id = $PID
                        Path = 'C:\capsule\scoop\apps\pwsh\7.6.4\pwsh.exe'
                    },
                    [pscustomobject]@{
                        Id = 424242
                        Path = 'C:\capsule\scoop\apps\pwsh\7.6.4\pwsh.exe'
                    }
                )
                function appdir { param($App, $Global) 'C:\capsule\scoop\apps\pwsh' }
                function Convert-Path {
                    [CmdletBinding()]
                    param([Parameter(ValueFromPipeline = $true)][string]$Path)
                    process { $Path }
                }
                function Get-Process {
                    [CmdletBinding()]
                    param()
                    $fakeProcesses
                }
                function test_running_process { throw 'delegated-to-upstream-running-process-guard' }

                . ([scriptblock]::Create($Definition))
                [void](Test-CapsulenvResetHasBlockingProcesses -App 'pwsh' -Global $false)
            } $script:GuardDefinition
        } | Should -Throw '*delegated-to-upstream-running-process-guard*'
    }
}
