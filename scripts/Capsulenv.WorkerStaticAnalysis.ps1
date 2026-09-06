function Get-CapsulenvWorkerFileAstIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $index = @{}
    foreach ($path in $Paths) {
        $fullPath = [System.IO.Path]::GetFullPath($path)
        if (-not $index.ContainsKey($fullPath)) {
            $index[$fullPath] = Get-CapsulenvStaticAst -Path $fullPath
        }
    }
    return $index
}

function Get-CapsulenvStaticFunctionIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Paths,
        $AstIndex
    )

    if ($null -eq $AstIndex) {
        $AstIndex = Get-CapsulenvWorkerFileAstIndex -Paths $Paths
    }
    $index = @{}
    foreach ($path in $Paths) {
        $fullPath = [System.IO.Path]::GetFullPath($path)
        $ast = $AstIndex[$fullPath]
        foreach ($functionAst in @(
            $ast.FindAll(
                { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
                $true
            )
        )) {
            $name = [string]$functionAst.Name
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($index.ContainsKey($name)) {
                throw "Static worker call-graph analysis found duplicate function definition '$name': $($index[$name].Path) and $fullPath"
            }
            $index[$name] = [pscustomobject]@{
                Name = $name
                Path = $fullPath
                Ast = $functionAst
            }
        }
    }
    return $index
}

function Get-CapsulenvDesiredStateWorkerRootCallbacks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Paths,
        $AstIndex
    )

    if ($null -eq $AstIndex) {
        $AstIndex = Get-CapsulenvWorkerFileAstIndex -Paths $Paths
    }
    $roots = New-Object System.Collections.Generic.List[object]
    foreach ($path in $Paths) {
        $fullPath = [System.IO.Path]::GetFullPath($path)
        $ast = $AstIndex[$fullPath]
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
            $parameters = @{}
            $elements = @($commandAst.CommandElements)
            for ($index = 1; $index -lt $elements.Count; $index++) {
                $element = $elements[$index]
                if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                $name = [string]$element.ParameterName
                $valueAst = $null
                if (
                    $index + 1 -lt $elements.Count -and
                    $elements[$index + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]
                ) {
                    $valueAst = $elements[$index + 1]
                    $index++
                }
                $parameters[$name] = $valueAst
            }
            if (-not $parameters.ContainsKey('ExecutionAffinity')) { continue }
            $affinityAst = $parameters['ExecutionAffinity']
            if (
                $affinityAst -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or
                [string]$affinityAst.Value -ne 'AnyRunspace'
            ) { continue }

            $nodeId = '<dynamic>'
            if ($parameters.ContainsKey('Id')) {
                $idAst = $parameters['Id']
                if ($idAst -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $nodeId = [string]$idAst.Value
                } elseif ($null -ne $idAst) {
                    $nodeId = [string]$idAst.Extent.Text
                }
            }
            foreach ($callbackName in @('Plan','Apply','Verify')) {
                if (-not $parameters.ContainsKey($callbackName)) { continue }
                $callbackAst = $parameters[$callbackName]
                if ($callbackAst -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) { continue }
                $roots.Add([pscustomobject]@{
                    NodeId = $nodeId
                    Callback = $callbackName
                    Path = $fullPath
                    Ast = $callbackAst.ScriptBlock
                })
            }
        }
    }
    return $roots.ToArray()
}

function Get-CapsulenvWorkerAstInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Ast)

    return [pscustomobject]@{
        Assignments = @(
            $Ast.FindAll(
                { param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] },
                $true
            )
        )
        Commands = @(
            $Ast.FindAll(
                { param($node) $node -is [System.Management.Automation.Language.CommandAst] },
                $true
            )
        )
        MemberInvocations = @(
            $Ast.FindAll(
                { param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] },
                $true
            )
        )
    }
}

function Get-CapsulenvWorkerDirectSafetyFindings {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Inventory)

    $findings = New-Object System.Collections.Generic.List[object]
    foreach ($assignment in @($Inventory.Assignments)) {
        $unsafe = $false
        foreach ($variableAst in @(
            $assignment.Left.FindAll(
                { param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] },
                $true
            )
        )) {
            if ([string]$variableAst.VariablePath.UserPath -match '^(?i:env:)') { $unsafe = $true; break }
        }
        if (-not $unsafe -and [string]$assignment.Left.Extent.Text -match '(?i)Environment\]::CurrentDirectory') {
            $unsafe = $true
        }
        if ($unsafe) {
            $findings.Add([pscustomobject]@{
                Rule = 'DesiredStateWorkerReachableProcessMutation'
                Line = $assignment.Extent.StartLineNumber
                Column = $assignment.Extent.StartColumnNumber
                DetailFormat = 'AnyRunspace {0}/{1} reaches process-global assignment via {2}'
            })
        }
    }

    foreach ($commandAst in @($Inventory.Commands)) {
        $commandName = [string]$commandAst.GetCommandName()
        $invocationOperator = [string]$commandAst.InvocationOperator
        if ([string]::IsNullOrWhiteSpace($commandName)) {
            $findings.Add([pscustomobject]@{
                Rule = 'DesiredStateWorkerOpaqueDynamicInvocation'
                Line = $commandAst.Extent.StartLineNumber
                Column = $commandAst.Extent.StartColumnNumber
                DetailFormat = 'AnyRunspace {0}/{1} reaches a dynamic command invocation that cannot be statically resolved via {2}'
            })
            continue
        }
        if ($invocationOperator -eq 'Dot') {
            $findings.Add([pscustomobject]@{
                Rule = 'DesiredStateWorkerOpaqueDynamicInvocation'
                Line = $commandAst.Extent.StartLineNumber
                Column = $commandAst.Extent.StartColumnNumber
                DetailFormat = "AnyRunspace {0}/{1} reaches dot-sourced execution '$commandName' via {2}"
            })
        } elseif ($invocationOperator -eq 'Ampersand' -and -not $commandName.StartsWith('Capsulenv', [System.StringComparison]::OrdinalIgnoreCase) -and -not $commandName.Contains('-Capsulenv')) {
            $findings.Add([pscustomobject]@{
                Rule = 'DesiredStateWorkerOpaqueDynamicInvocation'
                Line = $commandAst.Extent.StartLineNumber
                Column = $commandAst.Extent.StartColumnNumber
                DetailFormat = "AnyRunspace {0}/{1} reaches call-operator execution '$commandName' outside the statically indexed Capsulenv call graph via {2}"
            })
        }
        $forbiddenReason = $null
        if ($commandName -in @(
            'Set-Location','Push-Location','Pop-Location',
            'Set-CapsulenvSessionEnvironment',
            'Add-Type','Import-Module','Remove-Module'
        )) {
            $forbiddenReason = "process-global command '$commandName'"
        } elseif ($commandName -in @(
            'Invoke-Expression','Invoke-Command',
            'Start-Job','Start-ThreadJob',
            'Register-ObjectEvent','Register-EngineEvent','Register-WmiEvent'
        )) {
            $findings.Add([pscustomobject]@{
                Rule = 'DesiredStateWorkerOpaqueExecutionCommand'
                Line = $commandAst.Extent.StartLineNumber
                Column = $commandAst.Extent.StartColumnNumber
                DetailFormat = "AnyRunspace {0}/{1} reaches opaque or detached execution command '$commandName' via {2}"
            })
        } elseif ($commandName -eq 'ForEach-Object' -and [string]$commandAst.Extent.Text -match '(?i)(^|\s)-Parallel(\s|$)') {
            $findings.Add([pscustomobject]@{
                Rule = 'DesiredStateWorkerDetachedAsyncExecution'
                Line = $commandAst.Extent.StartLineNumber
                Column = $commandAst.Extent.StartColumnNumber
                DetailFormat = 'AnyRunspace {0}/{1} must not spawn nested ForEach-Object -Parallel work outside the desired-state scheduler via {2}'
            })
        } elseif (
            $commandName -in @('Set-Item','New-Item','Remove-Item','Clear-Item') -and
            [string]$commandAst.Extent.Text -match '(?i)(^|[\s''"])(env:|environment::)'
        ) {
            $forbiddenReason = "process-environment provider mutation '$commandName'"
        }
        if ($null -ne $forbiddenReason) {
            $findings.Add([pscustomobject]@{
                Rule = 'DesiredStateWorkerReachableProcessMutation'
                Line = $commandAst.Extent.StartLineNumber
                Column = $commandAst.Extent.StartColumnNumber
                DetailFormat = "AnyRunspace {0}/{1} reaches $forbiddenReason via {2}"
            })
        }
    }

    foreach ($memberInvocation in @($Inventory.MemberInvocations)) {
        $memberName = [string]$memberInvocation.Member.Value
        if ($memberName -in @('BeginInvoke','QueueUserWorkItem','StartNew')) {
            $findings.Add([pscustomobject]@{
                Rule = 'DesiredStateWorkerDetachedAsyncExecution'
                Line = $memberInvocation.Extent.StartLineNumber
                Column = $memberInvocation.Extent.StartColumnNumber
                DetailFormat = "AnyRunspace {0}/{1} reaches detached asynchronous .NET execution '$memberName' via {2}"
            })
            continue
        }
        if ($memberName -notin @('SetEnvironmentVariable','SetCurrentDirectory')) { continue }
        $findings.Add([pscustomobject]@{
            Rule = 'DesiredStateWorkerReachableProcessMutation'
            Line = $memberInvocation.Extent.StartLineNumber
            Column = $memberInvocation.Extent.StartColumnNumber
            DetailFormat = "AnyRunspace {0}/{1} reaches process-global .NET mutation '$memberName' via {2}"
        })
    }
    return $findings.ToArray()
}

function Get-CapsulenvWorkerDirectSafetyViolations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Ast,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RootNodeId,
        [Parameter(Mandatory = $true)][string]$RootCallback,
        [Parameter(Mandatory = $true)][string[]]$CallChain,
        $Inventory,
        $Findings
    )

    if ($null -eq $Inventory) {
        $Inventory = Get-CapsulenvWorkerAstInventory -Ast $Ast
    }
    if ($null -eq $Findings) {
        $Findings = @(Get-CapsulenvWorkerDirectSafetyFindings -Inventory $Inventory)
    }
    $chainText = $CallChain -join ' -> '
    return @(
        foreach ($finding in @($Findings)) {
            [pscustomobject]@{
                Rule = [string]$finding.Rule
                Path = $Path
                Line = [int]$finding.Line
                Column = [int]$finding.Column
                Detail = ([string]$finding.DetailFormat -f $RootNodeId, $RootCallback, $chainText)
            }
        }
    )
}

function Get-CapsulenvDesiredStateWorkerReachabilityViolations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $astIndex = Get-CapsulenvWorkerFileAstIndex -Paths $Paths
    $functionIndex = Get-CapsulenvStaticFunctionIndex -Paths $Paths -AstIndex $astIndex
    $roots = @(Get-CapsulenvDesiredStateWorkerRootCallbacks -Paths $Paths -AstIndex $astIndex)
    $functionFacts = @{}
    $violations = New-Object System.Collections.Generic.List[object]

    foreach ($root in $roots) {
        $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $rootInventory = Get-CapsulenvWorkerAstInventory -Ast $root.Ast
        $rootFindings = @(Get-CapsulenvWorkerDirectSafetyFindings -Inventory $rootInventory)
        foreach ($violation in @(Get-CapsulenvWorkerDirectSafetyViolations `
            -Ast $root.Ast `
            -Path ([string]$root.Path) `
            -RootNodeId ([string]$root.NodeId) `
            -RootCallback ([string]$root.Callback) `
            -CallChain @('<callback>') `
            -Inventory $rootInventory `
            -Findings $rootFindings)) {
            $violations.Add($violation)
        }

        $pending = New-Object System.Collections.Generic.Stack[object]
        foreach ($commandAst in @($rootInventory.Commands)) {
            $commandName = [string]$commandAst.GetCommandName()
            if ([string]::IsNullOrWhiteSpace($commandName)) { continue }
            if ($functionIndex.ContainsKey($commandName)) {
                $pending.Push([pscustomobject]@{ Name=$commandName; Chain=[string[]]@($commandName) })
            } elseif ($commandName -match '(?i)Capsulenv') {
                $violations.Add([pscustomobject]@{
                    Rule = 'DesiredStateWorkerUnresolvedCapsulenvCall'
                    Path = [string]$root.Path
                    Line = $commandAst.Extent.StartLineNumber
                    Column = $commandAst.Extent.StartColumnNumber
                    Detail = "AnyRunspace $($root.NodeId)/$($root.Callback) calls unresolved Capsulenv helper '$commandName'; worker safety cannot be proven"
                })
            }
        }

        while ($pending.Count -gt 0) {
            $current = $pending.Pop()
            $name = [string]$current.Name
            if (-not $visited.Add($name)) { continue }
            $entry = $functionIndex[$name]
            if (-not $functionFacts.ContainsKey($name)) {
                $inventory = Get-CapsulenvWorkerAstInventory -Ast $entry.Ast.Body
                $functionFacts[$name] = [pscustomobject]@{
                    Inventory = $inventory
                    Findings = @(Get-CapsulenvWorkerDirectSafetyFindings -Inventory $inventory)
                }
            }
            $facts = $functionFacts[$name]
            $chain = [string[]]@($current.Chain)
            foreach ($violation in @(Get-CapsulenvWorkerDirectSafetyViolations `
                -Ast $entry.Ast.Body `
                -Path ([string]$entry.Path) `
                -RootNodeId ([string]$root.NodeId) `
                -RootCallback ([string]$root.Callback) `
                -CallChain $chain `
                -Inventory $facts.Inventory `
                -Findings $facts.Findings)) {
                $violations.Add($violation)
            }
            foreach ($commandAst in @($facts.Inventory.Commands)) {
                $commandName = [string]$commandAst.GetCommandName()
                if ([string]::IsNullOrWhiteSpace($commandName)) { continue }
                if ($functionIndex.ContainsKey($commandName)) {
                    if (-not $visited.Contains($commandName)) {
                        $nextChain = New-Object System.Collections.Generic.List[string]
                        foreach ($item in $chain) { $nextChain.Add([string]$item) }
                        $nextChain.Add($commandName)
                        $pending.Push([pscustomobject]@{ Name=$commandName; Chain=[string[]]$nextChain.ToArray() })
                    }
                } elseif ($commandName -match '(?i)Capsulenv') {
                    $violations.Add([pscustomobject]@{
                        Rule = 'DesiredStateWorkerUnresolvedCapsulenvCall'
                        Path = [string]$entry.Path
                        Line = $commandAst.Extent.StartLineNumber
                        Column = $commandAst.Extent.StartColumnNumber
                        Detail = "AnyRunspace $($root.NodeId)/$($root.Callback) reaches unresolved Capsulenv helper '$commandName' via $($chain -join ' -> '); worker safety cannot be proven"
                    })
                }
            }
        }
    }
    return $violations.ToArray()
}

function Get-CapsulenvDesiredStateWorkerPreflightViolations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IntegrationPath,
        [Parameter(Mandatory = $true)][string]$PackageGraphPath
    )

    $violations = New-Object System.Collections.Generic.List[object]
    $checks = @(
        [pscustomobject]@{
            Path = [System.IO.Path]::GetFullPath($IntegrationPath)
            Function = 'Get-CapsulenvIntegrationDesiredStatePlan'
            Preflight = 'Initialize-CapsulenvFileIdentityRuntime'
            Boundaries = [string[]]@('Get-CapsulenvPackageProjectionRepairDescriptors','Get-CapsulenvProjectCacheRepairDescriptorSet','New-CapsulenvDesiredStateNode')
        },
        [pscustomobject]@{
            Path = [System.IO.Path]::GetFullPath($PackageGraphPath)
            Function = 'Get-CapsulenvPortablePackageDesiredStatePlan'
            Preflight = 'Initialize-CapsulenvPortablePackageWorkerRuntime'
            Boundaries = [string[]]@('New-CapsulenvDesiredStateNode')
        }
    )

    foreach ($check in $checks) {
        $functionAst = Get-CapsulenvFunctionAst -Path ([string]$check.Path) -Name ([string]$check.Function)
        $commands = @(
            $functionAst.Body.FindAll(
                { param($node) $node -is [System.Management.Automation.Language.CommandAst] },
                $true
            )
        )
        $preflight = @($commands | Where-Object { [string]$_.GetCommandName() -eq [string]$check.Preflight } | Select-Object -First 1)
        if ($preflight.Count -eq 0) {
            $violations.Add([pscustomobject]@{
                Rule = 'DesiredStateWorkerParentPreflightRequired'
                Path = [string]$check.Path
                Line = $functionAst.Extent.StartLineNumber
                Column = $functionAst.Extent.StartColumnNumber
                Detail = "Function '$($check.Function)' must call '$($check.Preflight)' before constructing worker-dependent state"
            })
            continue
        }
        $boundary = @(
            $commands |
                Where-Object { [string]$_.GetCommandName() -in @($check.Boundaries) } |
                Sort-Object { $_.Extent.StartOffset } |
                Select-Object -First 1
        )
        if ($boundary.Count -gt 0 -and $preflight[0].Extent.StartOffset -gt $boundary[0].Extent.StartOffset) {
            $violations.Add([pscustomobject]@{
                Rule = 'DesiredStateWorkerParentPreflightOrder'
                Path = [string]$check.Path
                Line = $preflight[0].Extent.StartLineNumber
                Column = $preflight[0].Extent.StartColumnNumber
                Detail = "Function '$($check.Function)' must call '$($check.Preflight)' before worker-dependent command '$([string]$boundary[0].GetCommandName())'"
            })
        }
    }
    return $violations.ToArray()
}
