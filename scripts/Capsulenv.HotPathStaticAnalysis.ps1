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
