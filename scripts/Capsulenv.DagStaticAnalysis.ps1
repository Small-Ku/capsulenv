function Get-CapsulenvDesiredStateNodeContractViolations {
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
            $parameters = @{}
            $elements = @($commandAst.CommandElements)
            for ($index = 1; $index -lt $elements.Count; $index++) {
                $element = $elements[$index]
                if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                    continue
                }
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

            if ($parameters.ContainsKey('ParallelSafe')) {
                $violations.Add([pscustomobject]@{
                    Rule = 'DesiredStateLegacyParallelSafeUsage'
                    Path = $fullPath
                    Line = $commandAst.Extent.StartLineNumber
                    Column = $commandAst.Extent.StartColumnNumber
                    Detail = 'desired-state node declarations must use explicit ExecutionAffinity and ConcurrencyPolicy instead of the legacy ParallelSafe shorthand'
                })
            }

            foreach ($requiredParameter in @(
                [pscustomobject]@{ Name='ExecutionAffinity'; Rule='DesiredStateExecutionAffinityRequired' },
                [pscustomobject]@{ Name='ConcurrencyPolicy'; Rule='DesiredStateConcurrencyPolicyRequired' },
                [pscustomobject]@{ Name='ReadResources'; Rule='DesiredStateReadResourcesRequired' },
                [pscustomobject]@{ Name='WriteResources'; Rule='DesiredStateWriteResourcesRequired' }
            )) {
                if (-not $parameters.ContainsKey([string]$requiredParameter.Name)) {
                    $violations.Add([pscustomobject]@{
                        Rule = [string]$requiredParameter.Rule
                        Path = $fullPath
                        Line = $commandAst.Extent.StartLineNumber
                        Column = $commandAst.Extent.StartColumnNumber
                        Detail = "desired-state node declarations must explicitly bind -$($requiredParameter.Name)"
                    })
                }
            }

            foreach ($callbackName in @('Plan','Apply','Verify')) {
                if (-not $parameters.ContainsKey($callbackName)) {
                    continue
                }
                $valueAst = $parameters[$callbackName]
                if ($valueAst -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                    $violations.Add([pscustomobject]@{
                        Rule = 'DesiredStateCallbackLiteralRequired'
                        Path = $fullPath
                        Line = if ($null -ne $valueAst) { $valueAst.Extent.StartLineNumber } else { $commandAst.Extent.StartLineNumber }
                        Column = if ($null -ne $valueAst) { $valueAst.Extent.StartColumnNumber } else { $commandAst.Extent.StartColumnNumber }
                        Detail = "desired-state node callback -$callbackName must be a literal scriptblock so Windows PowerShell 5.1 binding and worker detachment stay statically verifiable"
                    })
                }
            }

            $affinity = ''
            if ($parameters.ContainsKey('ExecutionAffinity')) {
                $affinityAst = $parameters['ExecutionAffinity']
                if ($affinityAst -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $affinity = [string]$affinityAst.Value
                } else {
                    $violations.Add([pscustomobject]@{
                        Rule = 'DesiredStateExecutionAffinityLiteralRequired'
                        Path = $fullPath
                        Line = if ($null -ne $affinityAst) { $affinityAst.Extent.StartLineNumber } else { $commandAst.Extent.StartLineNumber }
                        Column = if ($null -ne $affinityAst) { $affinityAst.Extent.StartColumnNumber } else { $commandAst.Extent.StartColumnNumber }
                        Detail = 'desired-state ExecutionAffinity must be a static MainRunspace or AnyRunspace literal in runtime declarations'
                    })
                }
            }

            $concurrencyPolicy = ''
            if ($parameters.ContainsKey('ConcurrencyPolicy')) {
                $policyAst = $parameters['ConcurrencyPolicy']
                if ($policyAst -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $concurrencyPolicy = [string]$policyAst.Value
                    if ($concurrencyPolicy -eq 'Auto') {
                        $violations.Add([pscustomobject]@{
                            Rule = 'DesiredStateAutoConcurrencyForbidden'
                            Path = $fullPath
                            Line = $policyAst.Extent.StartLineNumber
                            Column = $policyAst.Extent.StartColumnNumber
                            Detail = 'runtime desired-state declarations must choose Exclusive or ResourceBound explicitly instead of Auto'
                        })
                    }
                } else {
                    $violations.Add([pscustomobject]@{
                        Rule = 'DesiredStateConcurrencyPolicyLiteralRequired'
                        Path = $fullPath
                        Line = if ($null -ne $policyAst) { $policyAst.Extent.StartLineNumber } else { $commandAst.Extent.StartLineNumber }
                        Column = if ($null -ne $policyAst) { $policyAst.Extent.StartColumnNumber } else { $commandAst.Extent.StartColumnNumber }
                        Detail = 'desired-state ConcurrencyPolicy must be a static Exclusive or ResourceBound literal in runtime declarations'
                    })
                }
            }

            if ($affinity -eq 'AnyRunspace' -and $concurrencyPolicy -ne 'ResourceBound') {
                $violations.Add([pscustomobject]@{
                    Rule = 'DesiredStateAnyRunspaceMustBeResourceBound'
                    Path = $fullPath
                    Line = $commandAst.Extent.StartLineNumber
                    Column = $commandAst.Extent.StartColumnNumber
                    Detail = 'AnyRunspace nodes must use ResourceBound concurrency; Exclusive work belongs on MainRunspace'
                })
            }

            if ($concurrencyPolicy -eq 'ResourceBound') {
                $readAst = if ($parameters.ContainsKey('ReadResources')) { $parameters['ReadResources'] } else { $null }
                $writeAst = if ($parameters.ContainsKey('WriteResources')) { $parameters['WriteResources'] } else { $null }
                $readEmpty = $readAst -is [System.Management.Automation.Language.ArrayExpressionAst] -and
                    @($readAst.SubExpression.Statements).Count -eq 0
                $writeEmpty = $writeAst -is [System.Management.Automation.Language.ArrayExpressionAst] -and
                    @($writeAst.SubExpression.Statements).Count -eq 0
                if ($readEmpty -and $writeEmpty) {
                    $violations.Add([pscustomobject]@{
                        Rule = 'DesiredStateResourceBoundClaimsRequired'
                        Path = $fullPath
                        Line = $commandAst.Extent.StartLineNumber
                        Column = $commandAst.Extent.StartColumnNumber
                        Detail = 'ResourceBound nodes must declare at least one read or write resource claim; use Exclusive for claim-free coordination nodes'
                    })
                }
            }

            if ($affinity -eq 'AnyRunspace') {
                foreach ($resourceParameter in @('ReadResources','WriteResources')) {
                    if (-not $parameters.ContainsKey($resourceParameter)) {
                        continue
                    }
                    $resourceAst = $parameters[$resourceParameter]
                    if ($null -ne $resourceAst -and [string]$resourceAst.Extent.Text -match '(?i)process:///') {
                        $violations.Add([pscustomobject]@{
                            Rule = 'DesiredStateWorkerProcessResourceClaim'
                            Path = $fullPath
                            Line = $resourceAst.Extent.StartLineNumber
                            Column = $resourceAst.Extent.StartColumnNumber
                            Detail = "AnyRunspace nodes must not claim process-scoped resources in -$resourceParameter"
                        })
                    }
                }
            }

            if ($affinity -ne 'AnyRunspace') {
                continue
            }

            foreach ($callbackName in @('Plan','Apply','Verify')) {
                if (-not $parameters.ContainsKey($callbackName)) {
                    continue
                }
                $callbackAst = $parameters[$callbackName]
                if ($callbackAst -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                    continue
                }
                $scriptBlockAst = $callbackAst.ScriptBlock

                foreach ($assignment in @(
                    $scriptBlockAst.FindAll(
                        { param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] },
                        $true
                    )
                )) {
                    $leftVariables = @(
                        $assignment.Left.FindAll(
                            { param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] },
                            $true
                        )
                    )
                    $processGlobal = $false
                    foreach ($variableAst in $leftVariables) {
                        if ([string]$variableAst.VariablePath.UserPath -match '^(?i:env:)') {
                            $processGlobal = $true
                            break
                        }
                    }
                    if (-not $processGlobal -and [string]$assignment.Left.Extent.Text -match '(?i)Environment\]::CurrentDirectory') {
                        $processGlobal = $true
                    }
                    if ($processGlobal) {
                        $violations.Add([pscustomobject]@{
                            Rule = 'DesiredStateWorkerProcessGlobalMutation'
                            Path = $fullPath
                            Line = $assignment.Extent.StartLineNumber
                            Column = $assignment.Extent.StartColumnNumber
                            Detail = "AnyRunspace callback -$callbackName must not mutate process-global environment or current-directory state"
                        })
                    }
                }

                foreach ($nestedCommand in @(
                    $scriptBlockAst.FindAll(
                        { param($node) $node -is [System.Management.Automation.Language.CommandAst] },
                        $true
                    )
                )) {
                    $nestedCommandName = [string]$nestedCommand.GetCommandName()
                    $forbidden = $nestedCommandName -in @(
                        'Set-Location',
                        'Push-Location',
                        'Pop-Location',
                        'Set-CapsulenvSessionEnvironment'
                    )
                    if (
                        -not $forbidden -and
                        $nestedCommandName -in @('Set-Item','New-Item','Remove-Item','Clear-Item') -and
                        [string]$nestedCommand.Extent.Text -match '(?i)(^|[\s''"])(env:|environment::)'
                    ) {
                        $forbidden = $true
                    }
                    if ($forbidden) {
                        $violations.Add([pscustomobject]@{
                            Rule = 'DesiredStateWorkerProcessGlobalMutation'
                            Path = $fullPath
                            Line = $nestedCommand.Extent.StartLineNumber
                            Column = $nestedCommand.Extent.StartColumnNumber
                            Detail = "AnyRunspace callback -$callbackName must not invoke process-global mutation command '$nestedCommandName'"
                        })
                    }
                }

                foreach ($memberInvocation in @(
                    $scriptBlockAst.FindAll(
                        { param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] },
                        $true
                    )
                )) {
                    $memberName = [string]$memberInvocation.Member.Value
                    if ($memberName -notin @('SetEnvironmentVariable','SetCurrentDirectory')) {
                        continue
                    }
                    $violations.Add([pscustomobject]@{
                        Rule = 'DesiredStateWorkerProcessGlobalMutation'
                        Path = $fullPath
                        Line = $memberInvocation.Extent.StartLineNumber
                        Column = $memberInvocation.Extent.StartColumnNumber
                        Detail = "AnyRunspace callback -$callbackName must not invoke process-global .NET mutation '$memberName'"
                    })
                }
            }
        }
    }
    return $violations.ToArray()
}

function Get-CapsulenvTestHarnessIsolationViolations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $ast = Get-CapsulenvStaticAst -Path $fullPath
    $violations = New-Object System.Collections.Generic.List[object]

    foreach ($assignment in @(
        $ast.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] },
            $true
        )
    )) {
        foreach ($variableAst in @(
            $assignment.Left.FindAll(
                { param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] },
                $true
            )
        )) {
            if ([string]$variableAst.VariablePath.UserPath -match '^(?i:env:CAPSULENV_TEST_SUITE_|env:CAPSULENV_BUILD_ROOT$|env:TMP$|env:TEMP$|env:TMPDIR$)') {
                $violations.Add([pscustomobject]@{
                    Rule = 'TestHarnessParentEnvironmentMutation'
                    Path = $fullPath
                    Line = $assignment.Extent.StartLineNumber
                    Column = $assignment.Extent.StartColumnNumber
                    Detail = 'canonical test runner must configure suite environment through ProcessStartInfo.EnvironmentVariables instead of mutating its own process environment'
                })
            }
        }
    }

    $requiredNames = @(
        'CAPSULENV_TEST_SUITE_PATH',
        'CAPSULENV_TEST_SUITE_RESULT_PATH',
        'CAPSULENV_TEST_ARTIFACT_ROOT',
        'CAPSULENV_BUILD_ROOT',
        'TMP',
        'TEMP',
        'TMPDIR'
    )
    $source = [System.IO.File]::ReadAllText($fullPath)
    foreach ($name in $requiredNames) {
        $escaped = [regex]::Escape("EnvironmentVariables['$name']")
        if ($source -notmatch $escaped) {
            $violations.Add([pscustomobject]@{
                Rule = 'TestHarnessChildIsolationVariableRequired'
                Path = $fullPath
                Line = 1
                Column = 1
                Detail = "canonical test runner must set child isolation variable '$name' through ProcessStartInfo.EnvironmentVariables"
            })
        }
    }
    return $violations.ToArray()
}


function Get-CapsulenvDesiredStateSchedulerBoundaryViolations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $ast = Get-CapsulenvStaticAst -Path $fullPath
    $violations = New-Object System.Collections.Generic.List[object]
    $executor = Get-CapsulenvFunctionAst -Path $fullPath -Name 'Invoke-CapsulenvDesiredStatePlan'

    $readyQueueCallFound = $false
    foreach ($commandAst in @(
        $executor.Body.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.CommandAst] },
            $true
        )
    )) {
        $name = [string]$commandAst.GetCommandName()
        if ($name -eq 'Invoke-CapsulenvDesiredStateReadyQueue') {
            $readyQueueCallFound = $true
        }
    }
    if (-not $readyQueueCallFound) {
        $violations.Add([pscustomobject]@{
            Rule = 'DesiredStateDynamicReadyQueueRequired'
            Path = $fullPath
            Line = $executor.Extent.StartLineNumber
            Column = $executor.Extent.StartColumnNumber
            Detail = 'non-sequential desired-state execution must dispatch through the dynamic ready queue'
        })
    }

    foreach ($memberAst in @(
        $executor.Body.FindAll(
            {
                param($node)
                $node -is [System.Management.Automation.Language.MemberExpressionAst] -and
                [string]$node.Member.Value -eq 'ExecutionWaves'
            },
            $true
        )
    )) {
        $violations.Add([pscustomobject]@{
            Rule = 'DesiredStateRuntimeWaveBarrierForbidden'
            Path = $fullPath
            Line = $memberAst.Extent.StartLineNumber
            Column = $memberAst.Extent.StartColumnNumber
            Detail = 'ExecutionWaves are diagnostic topology only; runtime execution must not reintroduce a wave barrier'
        })
    }

    foreach ($legacyFunction in @(
        $ast.FindAll(
            {
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                [string]$node.Name -eq 'Invoke-CapsulenvDesiredStateParallelBatch'
            },
            $true
        )
    )) {
        $violations.Add([pscustomobject]@{
            Rule = 'DesiredStateLegacyWaveBatchHelperForbidden'
            Path = $fullPath
            Line = $legacyFunction.Extent.StartLineNumber
            Column = $legacyFunction.Extent.StartColumnNumber
            Detail = 'legacy batch/wave executor helper is forbidden after dynamic ready-queue scheduling became authoritative'
        })
    }

    return $violations.ToArray()
}

function Get-CapsulenvPortablePackageExecutionBoundaryViolations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $violations = New-Object System.Collections.Generic.List[object]
    foreach ($path in $Paths) {
        $fullPath = [System.IO.Path]::GetFullPath($path)
        $leaf = [System.IO.Path]::GetFileName($fullPath)
        $ast = Get-CapsulenvStaticAst -Path $fullPath
        foreach ($commandAst in @(
            $ast.FindAll(
                {
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    [string]$node.GetCommandName() -eq 'Install-CapsulenvPortablePackageNode'
                },
                $true
            )
        )) {
            if ($leaf -ne '45-PackageExecutionGraph.ps1') {
                $violations.Add([pscustomobject]@{
                    Rule = 'PortablePackageDirectExecutorForbidden'
                    Path = $fullPath
                    Line = $commandAst.Extent.StartLineNumber
                    Column = $commandAst.Extent.StartColumnNumber
                    Detail = 'PortableSafe package-node execution must stay inside the package desired-state graph instead of being flattened into a caller loop'
                })
                continue
            }

            $insideDesiredStateApply = $false
            $cursor = $commandAst.Parent
            while ($null -ne $cursor) {
                if ($cursor -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                    $parentCommand = $cursor.Parent
                    while ($null -ne $parentCommand -and $parentCommand -isnot [System.Management.Automation.Language.CommandAst]) {
                        $parentCommand = $parentCommand.Parent
                    }
                    if (
                        $null -ne $parentCommand -and
                        [string]$parentCommand.GetCommandName() -eq 'New-CapsulenvDesiredStateNode'
                    ) {
                        $elements = @($parentCommand.CommandElements)
                        for ($index = 1; $index -lt $elements.Count; $index++) {
                            if (
                                $elements[$index] -is [System.Management.Automation.Language.CommandParameterAst] -and
                                [string]$elements[$index].ParameterName -eq 'Apply' -and
                                $index + 1 -lt $elements.Count -and
                                $elements[$index + 1] -eq $cursor
                            ) {
                                $insideDesiredStateApply = $true
                                break
                            }
                        }
                    }
                    break
                }
                $cursor = $cursor.Parent
            }

            if (-not $insideDesiredStateApply) {
                $violations.Add([pscustomobject]@{
                    Rule = 'PortablePackageExecutorMustBeDagApply'
                    Path = $fullPath
                    Line = $commandAst.Extent.StartLineNumber
                    Column = $commandAst.Extent.StartColumnNumber
                    Detail = 'Install-CapsulenvPortablePackageNode must only execute from a desired-state node Apply callback'
                })
            }
        }
    }
    return $violations.ToArray()
}
