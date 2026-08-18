Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CapsulenvStaticAst {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $detail = $parseErrors | ForEach-Object {
            '{0}:{1}: {2}' -f $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Message
        }
        throw "Static analysis parse failed: $Path`n$($detail -join [Environment]::NewLine)"
    }
    return $ast
}

function Get-CapsulenvCommandAsts {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $ast = Get-CapsulenvStaticAst -Path $Path
    return @(
        $ast.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.CommandAst] },
            $true
        )
    )
}

function Get-CapsulenvFunctionAst {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $ast = Get-CapsulenvStaticAst -Path $Path
    $functions = @(
        $ast.FindAll(
            {
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                [string]$node.Name -eq $Name
            },
            $true
        )
    )
    if ($functions.Count -ne 1) {
        throw "Expected exactly one function '$Name' in ${Path}; found $($functions.Count)."
    }
    return $functions[0]
}

function Get-CapsulenvHostIntegrationOwnershipViolations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [Parameter(Mandatory = $true)][string]$AllowedShortcutOverridePath
    )

    $allowedPath = [System.IO.Path]::GetFullPath($AllowedShortcutOverridePath)
    return @(
        foreach ($path in $Paths) {
            $fullPath = [System.IO.Path]::GetFullPath($path)
            $ast = Get-CapsulenvStaticAst -Path $fullPath

            foreach ($literal in @(
                $ast.FindAll(
                    {
                        param($node)
                        $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                        $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
                    },
                    $true
                )
            )) {
                if ([string]$literal.Value -match '(?i)(^|[\\/])Scoop Apps($|[\\/])') {
                    [pscustomobject]@{
                        Rule = 'HostStartMenuNamespace'
                        Path = $fullPath
                        Line = $literal.Extent.StartLineNumber
                        Column = $literal.Extent.StartColumnNumber
                        Detail = 'runtime code must not target the foreign Scoop Apps Start Menu namespace'
                    }
                }
            }

            foreach ($functionAst in @(
                $ast.FindAll(
                    {
                        param($node)
                        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        [string]$node.Name -eq 'shortcut_folder'
                    },
                    $true
                )
            )) {
                if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($fullPath, $allowedPath)) {
                    [pscustomobject]@{
                        Rule = 'ScoopShortcutOverrideOwnership'
                        Path = $fullPath
                        Line = $functionAst.Extent.StartLineNumber
                        Column = $functionAst.Extent.StartColumnNumber
                        Detail = 'shortcut_folder may only be overridden by the capsule-owned User Scoop policy'
                    }
                }
            }
        }
    )
}

function Get-CapsulenvSessionModeBoundaryViolations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$FunctionName = 'Get-CapsulenvInstallMode'
    )

    $functionAst = Get-CapsulenvFunctionAst -Path $Path -Name $FunctionName
    $persistentOwnershipCommands = @(
        'Get-CapsulenvUserIntegrationMode',
        'Test-CapsulenvCurrentUserIntegrationOwnership',
        'Get-CapsulenvInstallModeState',
        'Get-CapsulenvInstallModeStatePath'
    )
    return @(
        foreach ($commandAst in @(
            $functionAst.Body.FindAll(
                { param($node) $node -is [System.Management.Automation.Language.CommandAst] },
                $true
            )
        )) {
            $commandName = $commandAst.GetCommandName()
            if ($commandName -and $commandName -in $persistentOwnershipCommands) {
                [pscustomobject]@{
                    Rule = 'SessionModeOwnershipSeparation'
                    Path = [System.IO.Path]::GetFullPath($Path)
                    Line = $commandAst.Extent.StartLineNumber
                    Column = $commandAst.Extent.StartColumnNumber
                    Detail = "session mode resolver must not read persistent ownership through $commandName"
                }
            }
        }
    )
}

function Get-CapsulenvExternalJsonMemberViolations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$FunctionName,
        [Parameter(Mandatory = $true)][string[]]$RecordVariables
    )

    $functionAst = Get-CapsulenvFunctionAst -Path $Path -Name $FunctionName
    $variableNames = @{}
    foreach ($name in $RecordVariables) {
        $variableNames[[string]$name] = $true
    }

    return @(
        foreach ($memberAst in @(
            $functionAst.Body.FindAll(
                { param($node) $node -is [System.Management.Automation.Language.MemberExpressionAst] },
                $true
            )
        )) {
            if ($memberAst.Expression -isnot [System.Management.Automation.Language.VariableExpressionAst]) {
                continue
            }
            $name = [string]$memberAst.Expression.VariablePath.UserPath
            if (-not $variableNames.ContainsKey($name)) {
                continue
            }
            [pscustomobject]@{
                Rule = 'ExternalJsonSafePropertyAccess'
                Path = [System.IO.Path]::GetFullPath($Path)
                Line = $memberAst.Extent.StartLineNumber
                Column = $memberAst.Extent.StartColumnNumber
                Detail = "external JSON record `$$name must use the safe property accessor instead of direct member access"
            }
        }
    )
}
