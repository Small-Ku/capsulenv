Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CapsulenvToolStorageHotPathViolations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ReadinessPath,
        [Parameter(Mandatory = $true)][string]$ToolStoragePath,
        [Parameter(Mandatory = $true)][string]$SessionEnvironmentPath,
        [Parameter(Mandatory = $true)][string]$CacheCommandPath,
        [Parameter(Mandatory = $true)][string]$DoctorPath
    )

    $violations = New-Object System.Collections.Generic.List[object]
    function Add-ToolStorageHotPathViolation {
        param($Ast, [string]$Path, [string]$Rule, [string]$Detail)
        $violations.Add([pscustomobject]@{
            Rule = $Rule
            Path = [System.IO.Path]::GetFullPath($Path)
            Line = [int]$Ast.Extent.StartLineNumber
            Column = [int]$Ast.Extent.StartColumnNumber
            Detail = $Detail
        })
    }
    function Get-HotPathCommands {
        param($FunctionAst)
        return @($FunctionAst.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    }
    function Test-HotPathCommandParameter {
        param($CommandAst, [string]$Name)
        return @($CommandAst.CommandElements | Where-Object {
            $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
            [string]$_.ParameterName -eq $Name
        }).Count -gt 0
    }

    $ready = Get-CapsulenvFunctionAst -Path $ReadinessPath -Name 'Test-CapsulenvToolStorageReady'
    foreach ($commandAst in @(Get-HotPathCommands $ready)) {
        $name = [string]$commandAst.GetCommandName()
        if ($name -in @('Get-ChildItem','Get-Content','ConvertFrom-Json','New-Item','Remove-Item','Set-Content','Add-Content','Copy-Item','Move-Item')) {
            Add-ToolStorageHotPathViolation -Ast $commandAst -Path $ReadinessPath -Rule 'ToolStorageReadyMetadataOnly' -Detail "ToolStorage readiness must remain metadata-only: $name"
        }
    }
    foreach ($memberAst in @($ready.Body.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]
    }, $true))) {
        $member = [string]$memberAst.Member.Value
        if ($member -in @('ReadAllText','ReadAllBytes','WriteAllText','WriteAllBytes','Open','OpenRead','OpenWrite')) {
            Add-ToolStorageHotPathViolation -Ast $memberAst -Path $ReadinessPath -Rule 'ToolStorageReadyMetadataOnly' -Detail "ToolStorage readiness must not read/write file contents: $member"
        }
    }

    $initialize = Get-CapsulenvFunctionAst -Path $ToolStoragePath -Name 'Initialize-CapsulenvToolStorage'
    $initializeCommands = @(Get-HotPathCommands $initialize | Sort-Object { $_.Extent.StartOffset })
    $readyCall = @($initializeCommands | Where-Object { [string]$_.GetCommandName() -eq 'Test-CapsulenvToolStorageReady' } | Select-Object -First 1)
    if ($readyCall.Count -eq 0) {
        Add-ToolStorageHotPathViolation -Ast $initialize -Path $ToolStoragePath -Rule 'ToolStorageReadyGateRequired' -Detail 'ToolStorage initialization must gate steady activation through Test-CapsulenvToolStorageReady'
    } else {
        foreach ($commandAst in $initializeCommands) {
            if ($commandAst.Extent.StartOffset -ge $readyCall[0].Extent.StartOffset) { break }
            $name = [string]$commandAst.GetCommandName()
            if ($name -in @('Test-Path','New-Item','Remove-Item','Get-ChildItem')) {
                Add-ToolStorageHotPathViolation -Ast $commandAst -Path $ToolStoragePath -Rule 'ToolStorageReadyGateBeforeIntegritySweep' -Detail "ToolStorage filesystem probing/mutation must occur after the readiness gate: $name"
            }
        }
    }

    $session = Get-CapsulenvFunctionAst -Path $SessionEnvironmentPath -Name 'Set-CapsulenvSessionEnvironment'
    foreach ($call in @(Get-HotPathCommands $session | Where-Object { [string]$_.GetCommandName() -eq 'Initialize-CapsulenvToolStorage' })) {
        if (Test-HotPathCommandParameter -CommandAst $call -Name 'ForceRepair') {
            Add-ToolStorageHotPathViolation -Ast $call -Path $SessionEnvironmentPath -Rule 'ToolStorageSteadySessionNotForced' -Detail 'steady session activation must use the readiness fast path instead of forcing a full ToolStorage integrity sweep'
        }
    }

    $cache = Get-CapsulenvFunctionAst -Path $CacheCommandPath -Name 'Invoke-CapsulenvCacheCommand'
    $cacheInitCalls = @(Get-HotPathCommands $cache | Where-Object { [string]$_.GetCommandName() -eq 'Initialize-CapsulenvToolStorage' })
    if ($cacheInitCalls.Count -ne 1 -or -not (Test-HotPathCommandParameter -CommandAst $cacheInitCalls[0] -Name 'ForceRepair')) {
        Add-ToolStorageHotPathViolation -Ast $cache -Path $CacheCommandPath -Rule 'ToolStorageExplicitRepairForced' -Detail 'capsulenv cache init must force a full ToolStorage normalization even when the readiness marker is valid'
    }

    $doctor = Get-CapsulenvFunctionAst -Path $DoctorPath -Name 'Invoke-CapsulenvDoctor'
    $doctorCommands = @(Get-HotPathCommands $doctor | ForEach-Object { [string]$_.GetCommandName() })
    foreach ($required in @('Get-CapsulenvToolStoragePlan','Test-CapsulenvToolStorageReady')) {
        if ($doctorCommands -contains $required) { continue }
        Add-ToolStorageHotPathViolation -Ast $doctor -Path $DoctorPath -Rule 'ToolStorageDoctorIntegrityPreserved' -Detail "doctor must retain explicit ToolStorage integrity/readiness diagnostics: $required"
    }

    return $violations.ToArray()
}

function Get-CapsulenvRehydrationHotPathViolations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScoopPath,
        [Parameter(Mandatory = $true)][string]$IntegrationsPath
    )

    $violations = New-Object System.Collections.Generic.List[object]
    function Add-RehydrationHotPathViolation {
        param($Ast, [string]$Rule, [string]$Detail)
        $violations.Add([pscustomobject]@{
            Rule = $Rule
            Path = [System.IO.Path]::GetFullPath($ScoopPath)
            Line = [int]$Ast.Extent.StartLineNumber
            Column = [int]$Ast.Extent.StartColumnNumber
            Detail = $Detail
        })
    }
    function Get-RehydrationCommands {
        param($FunctionAst)
        return @($FunctionAst.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    }
    function Get-RehydrationFileMembers {
        param($FunctionAst)
        return @($FunctionAst.Body.FindAll({
            param($node)
            if ($node -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst]) { return $false }
            if ([string]$node.Member.Value -notin @('ReadAllText','ReadAllBytes','WriteAllText','WriteAllBytes','Open','OpenRead','OpenWrite','Replace','Move')) { return $false }
            if ($node.Expression -isnot [System.Management.Automation.Language.TypeExpressionAst]) { return $false }
            return [string]$node.Expression.TypeName.FullName -eq 'System.IO.File'
        }, $true))
    }

    foreach ($functionName in @('Get-CapsulenvScoopRehydrationMarkerPaths','Test-CapsulenvScoopRehydrationRequired')) {
        $functionAst = Get-CapsulenvFunctionAst -Path $ScoopPath -Name $functionName
        foreach ($commandAst in @(Get-RehydrationCommands $functionAst)) {
            $name = [string]$commandAst.GetCommandName()
            if ($name -in @('Get-Content','ConvertFrom-Json','Get-ChildItem','New-Item','Remove-Item','Set-Content','Add-Content','Copy-Item','Move-Item')) {
                Add-RehydrationHotPathViolation -Ast $commandAst -Rule 'RehydrationReadyNoDetailIo' -Detail "rehydration readiness must not parse or mutate detail state on the steady path: $functionName -> $name"
            }
        }
        foreach ($memberAst in @(Get-RehydrationFileMembers $functionAst)) {
            Add-RehydrationHotPathViolation -Ast $memberAst -Rule 'RehydrationReadyNoDetailIo' -Detail "rehydration readiness must not read/write detail-state contents: $functionName -> $([string]$memberAst.Member.Value)"
        }
    }

    $test = Get-CapsulenvFunctionAst -Path $ScoopPath -Name 'Test-CapsulenvScoopRehydrationRequired'
    $markerCalls = @(Get-RehydrationCommands $test | Where-Object { [string]$_.GetCommandName() -eq 'Get-CapsulenvScoopRehydrationMarkerPaths' })
    if ($markerCalls.Count -ne 1) {
        Add-RehydrationHotPathViolation -Ast $test -Rule 'RehydrationReadyMarkerRequired' -Detail 'steady rehydration detection must derive exactly one generation/fingerprint marker set'
    }

    $invoke = Get-CapsulenvFunctionAst -Path $ScoopPath -Name 'Invoke-CapsulenvIntegrationDesiredState'
    $invokeCommands = @(Get-RehydrationCommands $invoke)
    $planCommands = @($invokeCommands | Where-Object { [string]$_.GetCommandName() -in @('Get-CapsulenvIntegrationDesiredStatePlan','Invoke-CapsulenvDesiredStatePlan') })
    foreach ($commandAst in $planCommands) {
        $guarded = $false
        for ($ancestor = $commandAst.Parent; $null -ne $ancestor -and $ancestor -ne $invoke; $ancestor = $ancestor.Parent) {
            if ($ancestor -isnot [System.Management.Automation.Language.IfStatementAst]) { continue }
            foreach ($clause in @($ancestor.Clauses)) {
                $condition = $clause.Item1
                $body = $clause.Item2
                if ($null -eq $condition -or $null -eq $body) { continue }
                if ($commandAst.Extent.StartOffset -lt $body.Extent.StartOffset -or $commandAst.Extent.EndOffset -gt $body.Extent.EndOffset) { continue }
                if ([string]$condition.Extent.Text -match '(?i)rehydrationRequired') { $guarded = $true; break }
            }
            if ($guarded) { break }
        }
        if (-not $guarded) {
            Add-RehydrationHotPathViolation -Ast $commandAst -Rule 'RehydrationSteadyBypassesDesiredStatePlan' -Detail 'normal activation must not build or execute the relocation desired-state graph after readiness is established'
        }
    }
    if (@($invokeCommands | Where-Object { [string]$_.GetCommandName() -eq 'Set-CapsulenvSessionEnvironment' }).Count -eq 0) {
        Add-RehydrationHotPathViolation -Ast $invoke -Rule 'RehydrationSteadySessionRequired' -Detail 'normal activation must retain direct session-environment setup when relocation repair is not required'
    }

    $integrations = Get-CapsulenvFunctionAst -Path $IntegrationsPath -Name 'Initialize-CapsulenvIntegrations'
    foreach ($commandAst in @(Get-RehydrationCommands $integrations | Where-Object { [string]$_.GetCommandName() -in @('Get-CapsulenvIntegrationDesiredStatePlan','Invoke-CapsulenvDesiredStatePlan') })) {
        $violations.Add([pscustomobject]@{
            Rule = 'RehydrationDisabledBypassesDesiredStatePlan'
            Path = [System.IO.Path]::GetFullPath($IntegrationsPath)
            Line = [int]$commandAst.Extent.StartLineNumber
            Column = [int]$commandAst.Extent.StartColumnNumber
            Detail = 'RehydrateOnRelocation=false must initialize the session directly instead of materializing a relocation graph'
        })
    }

    $save = Get-CapsulenvFunctionAst -Path $ScoopPath -Name 'Save-CapsulenvRehydrationState'
    $saveCommands = @(Get-RehydrationCommands $save | Sort-Object { $_.Extent.StartOffset })
    $invalidate = @($saveCommands | Where-Object { [string]$_.GetCommandName() -eq 'Remove-CapsulenvScoopRehydrationMarker' } | Select-Object -First 1)
    $commit = @($saveCommands | Where-Object { [string]$_.GetCommandName() -eq 'Publish-CapsulenvScoopRehydrationMarker' } | Select-Object -First 1)
    $stateWrites = @(Get-RehydrationFileMembers $save | Where-Object { [string]$_.Member.Value -in @('WriteAllText','WriteAllBytes','Replace','Move') } | Sort-Object { $_.Extent.StartOffset })
    if ($invalidate.Count -ne 1) {
        Add-RehydrationHotPathViolation -Ast $save -Rule 'RehydrationReadyInvalidationRequired' -Detail 'rehydration state publication must invalidate readiness before mutation'
    } elseif ($stateWrites.Count -gt 0 -and $invalidate[0].Extent.StartOffset -gt $stateWrites[0].Extent.StartOffset) {
        Add-RehydrationHotPathViolation -Ast $invalidate[0] -Rule 'RehydrationReadyInvalidatedBeforeStateWrite' -Detail 'readiness must be invalidated before the first rehydration state write'
    }
    if ($commit.Count -ne 1) {
        Add-RehydrationHotPathViolation -Ast $save -Rule 'RehydrationReadyCommitRequired' -Detail 'rehydration state publication must publish an outcome marker'
    }

    return $violations.ToArray()
}
