Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$dagStaticAnalysisLibrary = Join-Path $PSScriptRoot 'Capsulenv.DagStaticAnalysis.ps1'
if (Test-Path -LiteralPath $dagStaticAnalysisLibrary -PathType Leaf) {
    . $dagStaticAnalysisLibrary
}

$workerStaticAnalysisLibrary = Join-Path $PSScriptRoot 'Capsulenv.WorkerStaticAnalysis.ps1'
if (Test-Path -LiteralPath $workerStaticAnalysisLibrary -PathType Leaf) {
    . $workerStaticAnalysisLibrary
}

$contractStaticAnalysisLibrary = Join-Path $PSScriptRoot 'Capsulenv.ContractStaticAnalysis.ps1'
if (Test-Path -LiteralPath $contractStaticAnalysisLibrary -PathType Leaf) {
    . $contractStaticAnalysisLibrary
}

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
    param([Parameter(Mandatory = $true)][string[]]$Paths)

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
                    Detail = 'Capsulenv-owned host integration must not target upstream Scoop''s Start Menu namespace'
                })
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
            $violations.Add([pscustomobject]@{
                Rule = 'ScoopShortcutOverrideForbidden'
                Path = $fullPath
                Line = $functionAst.Extent.StartLineNumber
                Column = $functionAst.Extent.StartColumnNumber
                Detail = 'Capsulenv must not override Scoop shortcut_folder; host shortcuts are a Capsulenv launcher projection'
            })
        }
    }
    return $violations.ToArray()
}


function Get-CapsulenvWorkloadSpecializationViolations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $violations = New-Object System.Collections.Generic.List[object]
    foreach ($path in $Paths) {
        $fullPath = [System.IO.Path]::GetFullPath($path)
        $ast = Get-CapsulenvStaticAst -Path $fullPath
        foreach ($functionAst in @(
            $ast.FindAll(
                {
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    [string]$node.Name -match '(?i)(SingBox|Rclone)'
                },
                $true
            )
        )) {
            $violations.Add([pscustomobject]@{
                Rule = 'NoWorkloadSpecializedRuntime'
                Path = $fullPath
                Line = $functionAst.Extent.StartLineNumber
                Column = $functionAst.Extent.StartColumnNumber
                Detail = 'sing-box and rclone workload policy belongs to an external orchestrator; Capsulenv runtime must stay application-agnostic'
            })
        }
        foreach ($memberAst in @(
            $ast.FindAll(
                {
                    param($node)
                    $node -is [System.Management.Automation.Language.MemberExpressionAst] -and
                    [string]$node.Member.Value -match '^(?i:SingBox|Rclone)$'
                },
                $true
            )
        )) {
            $violations.Add([pscustomobject]@{
                Rule = 'NoWorkloadSpecializedConfiguration'
                Path = $fullPath
                Line = $memberAst.Extent.StartLineNumber
                Column = $memberAst.Extent.StartColumnNumber
                Detail = 'runtime configuration must use generic lifecycle routines instead of sing-box or rclone sections'
            })
        }
    }
    return $violations.ToArray()
}

function Get-CapsulenvScoopRuntimeAdapterViolations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot)

    $violations = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $RuntimeRoot -Filter 'scoop-capsulenv-*' -File -Recurse -ErrorAction SilentlyContinue)) {
        $violations.Add([pscustomobject]@{
            Rule = 'NoScoopRuntimeAdapters'
            Path = [string]$file.FullName
            Line = 1
            Column = 1
            Detail = 'runtime Scoop source adapters are forbidden; direct Scoop must remain upstream and package safety belongs to the Capsulenv planner/executor'
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

function Get-CapsulenvStockScoopBoundaryViolations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $ast = Get-CapsulenvStaticAst -Path $fullPath
    $violations = New-Object System.Collections.Generic.List[object]
    $functionAst = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$node.Name, 'Install-CapsulenvScoopShim')
    }, $true)) | Select-Object -First 1
    if ($null -eq $functionAst) {
        $violations.Add([pscustomobject]@{
            Rule = 'StockScoopShimDefinition'
            Path = $fullPath
            Line = 1
            Column = 1
            Detail = 'Install-CapsulenvScoopShim must exist and own only the cmd.exe compatibility trampoline'
        })
        return $violations.ToArray()
    }

    $source = [string]$functionAst.Extent.Text
    $templateCall = @($functionAst.Body.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        [string]$node.GetCommandName() -eq 'Get-CapsulenvScoopCmdShimText'
    }, $true) | Select-Object -First 1)
    if ($templateCall.Count -gt 0) {
        $templateAst = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$node.Name, 'Get-CapsulenvScoopCmdShimText')
        }, $true) | Select-Object -First 1)
        if ($templateAst.Count -gt 0) {
            $source += [Environment]::NewLine + [string]$templateAst[0].Extent.Text
        }
    }
    foreach ($forbidden in @(
        [pscustomobject]@{ Pattern = 'scoop-capsulenv-gateway'; Rule = 'StockScoopNoGateway'; Detail = 'direct Scoop must not route through the Capsulenv gateway' },
        [pscustomobject]@{ Pattern = 'scoop-capsulenv-shellonly-policy'; Rule = 'StockScoopNoPolicyInjection'; Detail = 'direct Scoop must not inject Capsulenv lifecycle policy' },
        [pscustomobject]@{ Pattern = '\bUseGateway\b'; Rule = 'StockScoopNoGatewaySwitch'; Detail = 'direct Scoop must not expose a gateway execution switch' },
        [pscustomobject]@{ Pattern = 'Get-CapsulenvModuleRuntimePath'; Rule = 'StockScoopNoRuntimeTransform'; Detail = 'the Scoop shim must not dispatch through a Capsulenv runtime transformer' }
    )) {
        if ($source -match $forbidden.Pattern) {
            $violations.Add([pscustomobject]@{
                Rule = $forbidden.Rule
                Path = $fullPath
                Line = [int]$functionAst.Extent.StartLineNumber
                Column = [int]$functionAst.Extent.StartColumnNumber
                Detail = $forbidden.Detail
            })
        }
    }

    if ($source -match '\$ps1Text\b|\$PSScriptRoot') {
        $violations.Add([pscustomobject]@{
            Rule = 'StockScoopNoPowerShellWrapper'
            Path = $fullPath
            Line = [int]$functionAst.Extent.StartLineNumber
            Column = [int]$functionAst.Extent.StartColumnNumber
            Detail = 'PowerShell must resolve the genuine upstream dispatcher from PATH instead of a Capsulenv scoop.ps1 wrapper'
        })
    }

    foreach ($required in @(
        [pscustomobject]@{ Pattern = '\.\.\\apps\\scoop\\current\\bin\\scoop\.ps1'; Rule = 'StockScoopUpstreamDispatcher'; Detail = 'cmd trampoline must target the installed upstream Scoop dispatcher' },
        [pscustomobject]@{ Pattern = '%~dp0'; Rule = 'StockScoopCmdRelativeRoot'; Detail = 'cmd trampoline must resolve upstream Scoop relative to its own shim directory' }
    )) {
        if ($source -notmatch $required.Pattern) {
            $violations.Add([pscustomobject]@{
                Rule = $required.Rule
                Path = $fullPath
                Line = [int]$functionAst.Extent.StartLineNumber
                Column = [int]$functionAst.Extent.StartColumnNumber
                Detail = $required.Detail
            })
        }
    }
    return $violations.ToArray()
}

function Get-CapsulenvMandatoryParameterBindingViolations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $functionContracts = @{}
    $asts = @{}
    foreach ($path in $Paths) {
        $fullPath = [System.IO.Path]::GetFullPath($path)
        $ast = Get-CapsulenvStaticAst -Path $fullPath
        $asts[$fullPath] = $ast
        foreach ($functionAst in @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
            $parameters = @{}
            $parameterAsts = New-Object System.Collections.Generic.List[object]
            foreach ($parameterAst in @($functionAst.Parameters)) { if ($null -ne $parameterAst) { $parameterAsts.Add($parameterAst) } }
            if ($null -ne $functionAst.Body.ParamBlock) {
                foreach ($parameterAst in @($functionAst.Body.ParamBlock.Parameters)) { $parameterAsts.Add($parameterAst) }
            }
            foreach ($parameterAst in $parameterAsts) {
                $mandatory = $false
                $allowNull = $false
                $allowEmptyString = $false
                $allowEmptyCollection = $false
                foreach ($attribute in @($parameterAst.Attributes)) {
                    $typeName = [string]$attribute.TypeName.FullName
                    if ($typeName -eq 'Parameter') {
                        foreach ($namedArgument in @($attribute.NamedArguments)) {
                            if ([string]$namedArgument.ArgumentName -eq 'Mandatory') {
                                $value = $namedArgument.Argument.SafeGetValue()
                                if ($null -eq $value -or [bool]$value) { $mandatory = $true }
                            }
                        }
                    } elseif ($typeName -eq 'AllowNull') {
                        $allowNull = $true
                    } elseif ($typeName -eq 'AllowEmptyString') {
                        $allowEmptyString = $true
                    } elseif ($typeName -eq 'AllowEmptyCollection') {
                        $allowEmptyCollection = $true
                    }
                }
                if ($mandatory) {
                    $parameters[[string]$parameterAst.Name.VariablePath.UserPath] = [pscustomobject]@{
                        AllowNull = $allowNull
                        AllowEmptyString = $allowEmptyString
                        AllowEmptyCollection = $allowEmptyCollection
                    }
                }
            }
            if ($parameters.Count -gt 0) {
                $functionContracts[[string]$functionAst.Name] = $parameters
            }
        }
    }

    $violations = New-Object System.Collections.Generic.List[object]
    foreach ($path in $asts.Keys) {
        $ast = $asts[$path]
        foreach ($commandAst in @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))) {
            $commandName = $commandAst.GetCommandName()
            if ([string]::IsNullOrWhiteSpace($commandName) -or -not $functionContracts.ContainsKey($commandName)) { continue }
            $contracts = $functionContracts[$commandName]
            $elements = @($commandAst.CommandElements)
            for ($index = 1; $index -lt $elements.Count; $index++) {
                $parameterElement = $elements[$index]
                if ($parameterElement -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                $parameterName = [string]$parameterElement.ParameterName
                if (-not $contracts.ContainsKey($parameterName)) { continue }
                if ($index + 1 -ge $elements.Count -or $elements[$index + 1] -is [System.Management.Automation.Language.CommandParameterAst]) { continue }
                $valueAst = $elements[$index + 1]
                $kind = $null
                if ($valueAst -is [System.Management.Automation.Language.VariableExpressionAst] -and [string]$valueAst.VariablePath.UserPath -eq 'null') {
                    $kind = 'Null'
                } elseif (($valueAst -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $valueAst -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and [string]$valueAst.Value -eq '') {
                    $kind = 'EmptyString'
                } elseif ($valueAst -is [System.Management.Automation.Language.ArrayExpressionAst] -and @($valueAst.SubExpression.Statements).Count -eq 0) {
                    $kind = 'EmptyCollection'
                }
                if ($null -eq $kind) { continue }
                $contract = $contracts[$parameterName]
                $allowed = ($kind -eq 'Null' -and $contract.AllowNull) -or
                    ($kind -eq 'EmptyString' -and $contract.AllowEmptyString) -or
                    ($kind -eq 'EmptyCollection' -and $contract.AllowEmptyCollection)
                if ($allowed) { continue }
                $violations.Add([pscustomobject]@{
                    Rule = 'MandatoryParameterExplicitEmptyValue'
                    Path = $path
                    Line = [int]$valueAst.Extent.StartLineNumber
                    Column = [int]$valueAst.Extent.StartColumnNumber
                    Detail = "local function '$commandName' mandatory parameter '-$parameterName' receives explicit $kind without the matching Allow attribute"
                })
            }
        }
    }
    return $violations.ToArray()
}


function Get-CapsulenvDesiredStateNodeBindingBoundaryViolations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $violations = New-Object System.Collections.Generic.List[object]
    foreach ($path in $Paths) {
        $fullPath = [System.IO.Path]::GetFullPath($path)
        $ast = Get-CapsulenvStaticAst -Path $fullPath
        foreach ($commandAst in @(
            $ast.FindAll(
                {
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    [string]$node.GetCommandName() -eq 'New-CapsulenvDesiredStateNode'
                },
                $true
            )
        )) {
            $cursor = $commandAst.Parent
            $insideArrayExpression = $false
            $hasExplicitExpressionBoundary = $false
            while ($null -ne $cursor) {
                if ($cursor -is [System.Management.Automation.Language.ParenExpressionAst]) {
                    $hasExplicitExpressionBoundary = $true
                }
                if ($cursor -is [System.Management.Automation.Language.ArrayExpressionAst]) {
                    $insideArrayExpression = $true
                    break
                }
                if ($cursor -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    break
                }
                $cursor = $cursor.Parent
            }
            if ($insideArrayExpression -and -not $hasExplicitExpressionBoundary) {
                $violations.Add([pscustomobject]@{
                    Rule = 'DesiredStateNodeScriptBlockBoundary'
                    Path = $fullPath
                    Line = $commandAst.Extent.StartLineNumber
                    Column = $commandAst.Extent.StartColumnNumber
                    Detail = 'New-CapsulenvDesiredStateNode must be parenthesized when emitted from @(...); its trailing scriptblock parameters require an explicit Windows PowerShell 5.1 binding boundary'
                })
            }
        }
    }
    return $violations.ToArray()
}

function Get-CapsulenvLoopArrayAppendViolations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $violations = New-Object System.Collections.Generic.List[object]
    foreach ($path in $Paths) {
        $fullPath = [System.IO.Path]::GetFullPath($path)
        $ast = Get-CapsulenvStaticAst -Path $fullPath
        $arrayVariables = @{}
        foreach ($assignment in @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))) {
            if ($assignment.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            if ([string]$assignment.Operator -ne 'Equals') { continue }
            $right = $assignment.Right
            if ($right -is [System.Management.Automation.Language.CommandExpressionAst]) { $right = $right.Expression }
            $knownArray = $right -is [System.Management.Automation.Language.ArrayExpressionAst] -or
                $right -is [System.Management.Automation.Language.ArrayLiteralAst]
            if ($knownArray) { $arrayVariables[[string]$assignment.Left.VariablePath.UserPath] = $true }
        }
        foreach ($assignment in @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))) {
            if ([string]$assignment.Operator -ne 'PlusEquals' -or $assignment.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            $variableName = [string]$assignment.Left.VariablePath.UserPath
            if (-not $arrayVariables.ContainsKey($variableName)) { continue }
            $insideLoop = $false
            $parent = $assignment.Parent
            while ($null -ne $parent) {
                if ($parent -is [System.Management.Automation.Language.ForEachStatementAst] -or
                    $parent -is [System.Management.Automation.Language.ForStatementAst] -or
                    $parent -is [System.Management.Automation.Language.WhileStatementAst] -or
                    $parent -is [System.Management.Automation.Language.DoWhileStatementAst] -or
                    $parent -is [System.Management.Automation.Language.DoUntilStatementAst]) {
                    $insideLoop = $true
                    break
                }
                $parent = $parent.Parent
            }
            if (-not $insideLoop) { continue }
            $violations.Add([pscustomobject]@{
                Rule = 'LoopArrayAppend'
                Path = $fullPath
                Line = [int]$assignment.Extent.StartLineNumber
                Column = [int]$assignment.Extent.StartColumnNumber
                Detail = "PowerShell array '$variableName' uses += inside a loop; use a List[T], ArrayList, or pipeline collection instead"
            })
        }
    }
    return $violations.ToArray()
}
