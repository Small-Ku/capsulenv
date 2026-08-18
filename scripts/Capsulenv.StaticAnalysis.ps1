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
    $allowedOverrideFound = $false
    $allowedNamespaceFound = $false
    $violations = New-Object System.Collections.Generic.List[object]

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
            $value = [string]$literal.Value
            if ($value -match '(?i)(^|[\\/])Scoop Apps($|[\\/])') {
                $violations.Add([pscustomobject]@{
                    Rule = 'HostStartMenuNamespace'
                    Path = $fullPath
                    Line = $literal.Extent.StartLineNumber
                    Column = $literal.Extent.StartColumnNumber
                    Detail = 'runtime code must not target the foreign Scoop Apps Start Menu namespace'
                })
            }
            if (
                [System.StringComparer]::OrdinalIgnoreCase.Equals($fullPath, $allowedPath) -and
                $value -eq 'Capsulenv Apps'
            ) {
                $allowedNamespaceFound = $true
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
            if ([System.StringComparer]::OrdinalIgnoreCase.Equals($fullPath, $allowedPath)) {
                $allowedOverrideFound = $true
                continue
            }
            $violations.Add([pscustomobject]@{
                Rule = 'ScoopShortcutOverrideOwnership'
                Path = $fullPath
                Line = $functionAst.Extent.StartLineNumber
                Column = $functionAst.Extent.StartColumnNumber
                Detail = 'shortcut_folder may only be overridden by the capsule-owned User Scoop policy'
            })
        }
    }

    if (-not $allowedOverrideFound) {
        $violations.Add([pscustomobject]@{
            Rule = 'UserShortcutIsolationRequired'
            Path = $allowedPath
            Line = 1
            Column = 1
            Detail = 'capsule-owned User Scoop policy must override shortcut_folder'
        })
    }
    if (-not $allowedNamespaceFound) {
        $violations.Add([pscustomobject]@{
            Rule = 'UserShortcutNamespaceRequired'
            Path = $allowedPath
            Line = 1
            Column = 1
            Detail = 'capsule-owned User Scoop policy must target the Capsulenv Apps namespace'
        })
    }
    return $violations.ToArray()
}

function Get-CapsulenvSessionModeBoundaryViolations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$FunctionName = 'Get-CapsulenvInstallMode'
    )

    $functionAst = Get-CapsulenvFunctionAst -Path $Path -Name $FunctionName
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $violations = New-Object System.Collections.Generic.List[object]

    foreach ($commandAst in @(
        $functionAst.Body.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.CommandAst] },
            $true
        )
    )) {
        $commandName = $commandAst.GetCommandName()
        if ([string]::IsNullOrWhiteSpace($commandName)) {
            $commandName = $commandAst.Extent.Text
        }
        $violations.Add([pscustomobject]@{
            Rule = 'SessionModeCommandDependency'
            Path = $fullPath
            Line = $commandAst.Extent.StartLineNumber
            Column = $commandAst.Extent.StartColumnNumber
            Detail = "session mode resolver must remain process-state-only; command dependency is forbidden: $commandName"
        })
    }

    $processModeSelectorFound = $false
    foreach ($variableAst in @(
        $functionAst.Body.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] },
            $true
        )
    )) {
        if ([string]$variableAst.VariablePath.UserPath -eq 'env:CAPSULENV_MODE') {
            $processModeSelectorFound = $true
            break
        }
    }
    if (-not $processModeSelectorFound) {
        $violations.Add([pscustomobject]@{
            Rule = 'SessionModeProcessSelectorRequired'
            Path = $fullPath
            Line = $functionAst.Extent.StartLineNumber
            Column = $functionAst.Extent.StartColumnNumber
            Detail = 'session mode resolver must select User only from process-scoped CAPSULENV_MODE'
        })
    }
    return $violations.ToArray()
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

function Get-CapsulenvScoopGatewayBootstrapViolations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    [void](Get-CapsulenvStaticAst -Path $fullPath)
    $source = [System.IO.File]::ReadAllText($fullPath)
    $violations = New-Object System.Collections.Generic.List[object]

    $requirements = @(
        [pscustomobject]@{
            Rule = 'ScoopGatewayBootstrapCapture'
            Pattern = '(?m)\$upstreamSource\s*=\s*\[System\.IO\.File\]::ReadAllText\(\$upstream\)'
            Detail = 'intercepted Scoop commands must capture the installed upstream dispatcher bootstrap'
        },
        [pscustomobject]@{
            Rule = 'ScoopGatewayDispatchBoundary'
            Pattern = 'switch\\s\*\\\(\\s\*\\\$subCommand'
            Detail = 'gateway must locate the installed Scoop command-dispatch boundary'
        },
        [pscustomobject]@{
            Rule = 'ScoopGatewayDispatchGuard'
            Pattern = '(?m)if\s*\(\s*-not\s+\$dispatcherBoundary\.Success\s*\)'
            Detail = 'gateway must fail closed when the installed Scoop dispatch boundary is unknown'
        },
        [pscustomobject]@{
            Rule = 'ScoopGatewayBootstrapSlice'
            Pattern = '(?m)\$bootstrapSource\s*=\s*\$upstreamSource\.Substring\(\s*0\s*,\s*\$dispatcherBoundary\.Index\s*\)'
            Detail = 'gateway must slice the installed upstream dispatcher at the validated dispatch boundary'
        },
        [pscustomobject]@{
            Rule = 'ScoopGatewayCoreBootstrapGuard'
            Pattern = 'lib\[\\\\/\]core\\\.ps1'
            Detail = 'captured upstream bootstrap must be checked for Scoop lib/core.ps1'
        },
        [pscustomobject]@{
            Rule = 'ScoopGatewayBootstrapPrepend'
            Pattern = '(?m)\$source\s*=\s*\$bootstrapSource\s*\+[^\r\n]*\+\s*\$source'
            Detail = 'captured upstream bootstrap must execute before the transformed libexec source'
        }
    )

    foreach ($requirement in $requirements) {
        if ($source -notmatch $requirement.Pattern) {
            $violations.Add([pscustomobject]@{
                Rule = $requirement.Rule
                Path = $fullPath
                Line = 1
                Column = 1
                Detail = $requirement.Detail
            })
        }
    }

    $prependMatch = [regex]::Match(
        $source,
        '(?m)^\$source\s*=\s*\$bootstrapSource\s*\+[^\r\n]*\+\s*\$source\s*$'
    )
    $policyInsertMatch = [regex]::Match(
        $source,
        '(?m)^\s*\$source\s*=\s*\$source\.Insert\(\$insertionPoint\.Index,'
    )
    if (
        $prependMatch.Success -and
        $policyInsertMatch.Success -and
        $prependMatch.Index -gt $policyInsertMatch.Index
    ) {
        $violations.Add([pscustomobject]@{
            Rule = 'ScoopGatewayBootstrapOrder'
            Path = $fullPath
            Line = 1
            Column = 1
            Detail = 'upstream Scoop bootstrap must be prepended before Capsulenv policy injection'
        })
    }

    return $violations.ToArray()
}
