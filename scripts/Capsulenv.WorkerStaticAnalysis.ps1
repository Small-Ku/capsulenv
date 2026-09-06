function Get-CapsulenvStaticFunctionIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $index = @{}
    foreach ($path in $Paths) {
        $fullPath = [System.IO.Path]::GetFullPath($path)
        $ast = Get-CapsulenvStaticAst -Path $fullPath
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
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $roots = New-Object System.Collections.Generic.List[object]
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

function Get-CapsulenvWorkerDirectSafetyViolations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Ast,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RootNodeId,
        [Parameter(Mandatory = $true)][string]$RootCallback,
        [Parameter(Mandatory = $true)][string[]]$CallChain
    )

    $violations = New-Object System.Collections.Generic.List[object]
    $chainText = $CallChain -join ' -> '
    foreach ($assignment in @(
        $Ast.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] },
            $true
        )
    )) {
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
            $violations.Add([pscustomobject]@{
                Rule = 'DesiredStateWorkerReachableProcessMutation'
                Path = $Path
                Line = $assignment.Extent.StartLineNumber
                Column = $assignment.Extent.StartColumnNumber
                Detail = "AnyRunspace $RootNodeId/$RootCallback reaches process-global assignment via $chainText"
            })
        }
    }

    foreach ($commandAst in @(
        $Ast.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.CommandAst] },
            $true
        )
    )) {
        $commandName = [string]$commandAst.GetCommandName()
        $invocationOperator = [string]$commandAst.InvocationOperator
        if ([string]::IsNullOrWhiteSpace($commandName)) {
            $violations.Add([pscustomobject]@{
                Rule = 'DesiredStateWorkerOpaqueDynamicInvocation'
                Path = $Path
                Line = $commandAst.Extent.StartLineNumber
                Column = $commandAst.Extent.StartColumnNumber
                Detail = "AnyRunspace $RootNodeId/$RootCallback reaches a dynamic command invocation that cannot be statically resolved via $chainText"
            })
            continue
        }
        if ($invocationOperator -eq 'Dot') {
            $violations.Add([pscustomobject]@{
                Rule = 'DesiredStateWorkerOpaqueDynamicInvocation'
                Path = $Path
                Line = $commandAst.Extent.StartLineNumber
                Column = $commandAst.Extent.StartColumnNumber
                Detail = "AnyRunspace $RootNodeId/$RootCallback reaches dot-sourced execution '$commandName' via $chainText"
            })
        } elseif ($invocationOperator -eq 'Ampersand' -and -not $commandName.StartsWith('Capsulenv', [System.StringComparison]::OrdinalIgnoreCase) -and -not $commandName.Contains('-Capsulenv')) {
            $violations.Add([pscustomobject]@{
                Rule = 'DesiredStateWorkerOpaqueDynamicInvocation'
                Path = $Path
                Line = $commandAst.Extent.StartLineNumber
                Column = $commandAst.Extent.StartColumnNumber
                Detail = "AnyRunspace $RootNodeId/$RootCallback reaches call-operator execution '$commandName' outside the statically indexed Capsulenv call graph via $chainText"
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
            $violations.Add([pscustomobject]@{
                Rule = 'DesiredStateWorkerOpaqueExecutionCommand'
                Path = $Path
                Line = $commandAst.Extent.StartLineNumber
                Column = $commandAst.Extent.StartColumnNumber
                Detail = "AnyRunspace $RootNodeId/$RootCallback reaches opaque or detached execution command '$commandName' via $chainText"
            })
        } elseif ($commandName -eq 'ForEach-Object' -and [string]$commandAst.Extent.Text -match '(?i)(^|\s)-Parallel(\s|$)') {
            $violations.Add([pscustomobject]@{
                Rule = 'DesiredStateWorkerDetachedAsyncExecution'
                Path = $Path
                Line = $commandAst.Extent.StartLineNumber
                Column = $commandAst.Extent.StartColumnNumber
                Detail = "AnyRunspace $RootNodeId/$RootCallback must not spawn nested ForEach-Object -Parallel work outside the desired-state scheduler via $chainText"
            })
        } elseif (
            $commandName -in @('Set-Item','New-Item','Remove-Item','Clear-Item') -and
            [string]$commandAst.Extent.Text -match '(?i)(^|[\s''"])(env:|environment::)'
        ) {
            $forbiddenReason = "process-environment provider mutation '$commandName'"
        }
        if ($null -ne $forbiddenReason) {
            $violations.Add([pscustomobject]@{
                Rule = 'DesiredStateWorkerReachableProcessMutation'
                Path = $Path
                Line = $commandAst.Extent.StartLineNumber
                Column = $commandAst.Extent.StartColumnNumber
                Detail = "AnyRunspace $RootNodeId/$RootCallback reaches $forbiddenReason via $chainText"
            })
        }
    }

    foreach ($memberInvocation in @(
        $Ast.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] },
            $true
        )
    )) {
        $memberName = [string]$memberInvocation.Member.Value
        if ($memberName -in @('BeginInvoke','QueueUserWorkItem','StartNew')) {
            $violations.Add([pscustomobject]@{
                Rule = 'DesiredStateWorkerDetachedAsyncExecution'
                Path = $Path
                Line = $memberInvocation.Extent.StartLineNumber
                Column = $memberInvocation.Extent.StartColumnNumber
                Detail = "AnyRunspace $RootNodeId/$RootCallback reaches detached asynchronous .NET execution '$memberName' via $chainText"
            })
            continue
        }
        if ($memberName -notin @('SetEnvironmentVariable','SetCurrentDirectory')) { continue }
        $violations.Add([pscustomobject]@{
            Rule = 'DesiredStateWorkerReachableProcessMutation'
            Path = $Path
            Line = $memberInvocation.Extent.StartLineNumber
            Column = $memberInvocation.Extent.StartColumnNumber
            Detail = "AnyRunspace $RootNodeId/$RootCallback reaches process-global .NET mutation '$memberName' via $chainText"
        })
    }
    return $violations.ToArray()
}

function Get-CapsulenvDesiredStateWorkerReachabilityViolations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $functionIndex = Get-CapsulenvStaticFunctionIndex -Paths $Paths
    $roots = @(Get-CapsulenvDesiredStateWorkerRootCallbacks -Paths $Paths)
    $violations = New-Object System.Collections.Generic.List[object]

    foreach ($root in $roots) {
        $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($violation in @(Get-CapsulenvWorkerDirectSafetyViolations `
            -Ast $root.Ast `
            -Path ([string]$root.Path) `
            -RootNodeId ([string]$root.NodeId) `
            -RootCallback ([string]$root.Callback) `
            -CallChain @('<callback>'))) {
            $violations.Add($violation)
        }

        $pending = New-Object System.Collections.Generic.Stack[object]
        foreach ($commandAst in @(
            $root.Ast.FindAll(
                { param($node) $node -is [System.Management.Automation.Language.CommandAst] },
                $true
            )
        )) {
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
            $chain = [string[]]@($current.Chain)
            foreach ($violation in @(Get-CapsulenvWorkerDirectSafetyViolations `
                -Ast $entry.Ast.Body `
                -Path ([string]$entry.Path) `
                -RootNodeId ([string]$root.NodeId) `
                -RootCallback ([string]$root.Callback) `
                -CallChain $chain)) {
                $violations.Add($violation)
            }
            foreach ($commandAst in @(
                $entry.Ast.Body.FindAll(
                    { param($node) $node -is [System.Management.Automation.Language.CommandAst] },
                    $true
                )
            )) {
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
