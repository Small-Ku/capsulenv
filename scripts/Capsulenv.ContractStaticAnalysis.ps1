Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CapsulenvRuntimeLauncherBoundaryViolations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $ast = Get-CapsulenvStaticAst -Path $fullPath
    $violations = New-Object System.Collections.Generic.List[object]
    $commands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))

    $importCommands = @($commands | Where-Object { [string]$_.GetCommandName() -eq 'Import-Module' })
    $hasDisableNameChecking = $false
    foreach ($commandAst in $importCommands) {
        if (@($commandAst.CommandElements | Where-Object {
            $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
            [string]$_.ParameterName -eq 'DisableNameChecking'
        }).Count -gt 0) {
            $hasDisableNameChecking = $true
            break
        }
    }
    if (-not $hasDisableNameChecking) {
        $violations.Add([pscustomobject]@{
            Rule = 'RuntimeLauncherDisableNameChecking'
            Path = $fullPath
            Line = 1
            Column = 1
            Detail = 'runtime launcher must import the internal Capsulenv module with -DisableNameChecking'
        })
    }

    $invokeCommands = @($commands | Where-Object { [string]$_.GetCommandName() -eq 'Invoke-Capsulenv' })
    if ($invokeCommands.Count -eq 0) {
        $violations.Add([pscustomobject]@{
            Rule = 'RuntimeLauncherDispatcherRequired'
            Path = $fullPath
            Line = 1
            Column = 1
            Detail = 'runtime launcher must dispatch through Invoke-Capsulenv'
        })
    }
    foreach ($commandAst in $invokeCommands) {
        $cursor = $commandAst.Parent
        while ($null -ne $cursor -and $cursor -isnot [System.Management.Automation.Language.StatementBlockAst]) {
            if ($cursor -is [System.Management.Automation.Language.AssignmentStatementAst]) {
                $violations.Add([pscustomobject]@{
                    Rule = 'RuntimeLauncherNoDispatcherCapture'
                    Path = $fullPath
                    Line = [int]$commandAst.Extent.StartLineNumber
                    Column = [int]$commandAst.Extent.StartColumnNumber
                    Detail = 'runtime launcher must stream Invoke-Capsulenv output directly instead of assigning or buffering its success stream'
                })
                break
            }
            $cursor = $cursor.Parent
        }
    }

    $lastExitCodeReference = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
        [string]$node.VariablePath.UserPath -eq 'LASTEXITCODE'
    }, $true)).Count -gt 0
    if (-not $lastExitCodeReference) {
        foreach ($commandAst in $commands) {
            if ([string]$commandAst.GetCommandName() -ne 'Get-Variable') { continue }
            $text = [string]$commandAst.Extent.Text
            if ($text -match '(?i)(?:-Name\s+)?LASTEXITCODE') {
                $lastExitCodeReference = $true
                break
            }
        }
    }
    if (-not $lastExitCodeReference) {
        $violations.Add([pscustomobject]@{
            Rule = 'RuntimeLauncherExitCodePreservation'
            Path = $fullPath
            Line = 1
            Column = 1
            Detail = 'runtime launcher must preserve native package-exec LASTEXITCODE without capturing dispatcher output'
        })
    }

    return $violations.ToArray()
}

function Get-CapsulenvInstallerLifecycleBoundaryViolations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $ast = Get-CapsulenvStaticAst -Path $fullPath
    $violations = New-Object System.Collections.Generic.List[object]
    $forbiddenCommands = @(
        'Initialize-CapsulenvScoopBootstrap',
        'Ensure-CapsulenvScoopPortableConfig',
        'Install-CapsulenvUserEnvironment',
        'Restore-CapsulenvUserEnvironment',
        'Set-CapsulenvInstallMode',
        'Import-Module'
    )

    foreach ($commandAst in @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))) {
        $commandName = [string]$commandAst.GetCommandName()
        if ($commandName -in $forbiddenCommands) {
            $violations.Add([pscustomobject]@{
                Rule = 'InstallerDeploymentOnlyCommand'
                Path = $fullPath
                Line = [int]$commandAst.Extent.StartLineNumber
                Column = [int]$commandAst.Extent.StartColumnNumber
                Detail = "installer must remain deployment-only; lifecycle command is forbidden: $commandName"
            })
        }
    }

    foreach ($parameterAst in @($ast.ParamBlock.Parameters)) {
        $parameterName = [string]$parameterAst.Name.VariablePath.UserPath
        if ($parameterName -eq 'SkipScoopBootstrap' -or $parameterName -eq 'InstallMode' -or $parameterName -eq 'Mode') {
            $violations.Add([pscustomobject]@{
                Rule = 'InstallerDeploymentOnlyParameter'
                Path = $fullPath
                Line = [int]$parameterAst.Extent.StartLineNumber
                Column = [int]$parameterAst.Extent.StartColumnNumber
                Detail = "installer must not expose lifecycle/host-integration parameter: $parameterName"
            })
        }
        foreach ($attribute in @($parameterAst.Attributes)) {
            if ([string]$attribute.TypeName.FullName -ne 'ValidateSet') { continue }
            $values = @($attribute.PositionalArguments | ForEach-Object { $_.SafeGetValue() })
            if ($values -contains 'ShellOnly' -or $values -contains 'User') {
                $violations.Add([pscustomobject]@{
                    Rule = 'InstallerDeploymentOnlyModeSelector'
                    Path = $fullPath
                    Line = [int]$attribute.Extent.StartLineNumber
                    Column = [int]$attribute.Extent.StartColumnNumber
                    Detail = 'installer must not own ShellOnly/User activation mode selection'
                })
            }
        }
    }

    return $violations.ToArray()
}

function Get-CapsulenvPersistRelocationScanViolations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $violations = New-Object System.Collections.Generic.List[object]
    foreach ($path in $Paths) {
        $fullPath = [System.IO.Path]::GetFullPath($path)
        $ast = Get-CapsulenvStaticAst -Path $fullPath
        foreach ($commandAst in @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            [string]$node.GetCommandName() -eq 'Get-ChildItem'
        }, $true))) {
            $recursive = @($commandAst.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                [string]$_.ParameterName -eq 'Recurse'
            }).Count -gt 0
            if (-not $recursive) { continue }
            $violations.Add([pscustomobject]@{
                Rule = 'PersistRelocationNoRecursiveScan'
                Path = $fullPath
                Line = [int]$commandAst.Extent.StartLineNumber
                Column = [int]$commandAst.Extent.StartColumnNumber
                Detail = 'persist relocation must operate only on explicitly approved files and must not recursively scan app data'
            })
        }
    }
    return $violations.ToArray()
}

function Get-CapsulenvProjectCacheOrderingViolations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $functionAst = Get-CapsulenvFunctionAst -Path $fullPath -Name 'Get-CapsulenvProjectLinkInfo'
    $commands = @($functionAst.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    $reparse = @($commands | Where-Object { [string]$_.GetCommandName() -eq 'Get-CapsulenvReparseTarget' } | Select-Object -First 1)
    $hardLink = @($commands | Where-Object { [string]$_.GetCommandName() -eq 'Test-CapsulenvHardLinkMatch' } | Select-Object -First 1)
    $violations = New-Object System.Collections.Generic.List[object]

    if ($reparse.Count -eq 0 -or $hardLink.Count -eq 0) {
        $violations.Add([pscustomobject]@{
            Rule = 'ProjectCacheLinkInspectionRequired'
            Path = $fullPath
            Line = [int]$functionAst.Extent.StartLineNumber
            Column = [int]$functionAst.Extent.StartColumnNumber
            Detail = 'project-cache link inspection must handle both reparse targets and hard-link file identity'
        })
    } elseif ($reparse[0].Extent.StartOffset -gt $hardLink[0].Extent.StartOffset) {
        $violations.Add([pscustomobject]@{
            Rule = 'ProjectCacheReparseBeforeHardLink'
            Path = $fullPath
            Line = [int]$hardLink[0].Extent.StartLineNumber
            Column = [int]$hardLink[0].Extent.StartColumnNumber
            Detail = 'reparse points must be detected before file identity checks so symlinks cannot masquerade as hard links'
        })
    }

    return $violations.ToArray()
}

function Get-CapsulenvBitwardenStateBoundaryViolations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $violations = New-Object System.Collections.Generic.List[object]
    $requiredCalls = [ordered]@{
        'Set-CapsulenvBitwardenDesktopSshAgent' = @('Repair-CapsulenvInstalledAppProjections', 'Assert-CapsulenvJsonObjectText')
        'Restore-CapsulenvBitwardenDesktopSettings' = @('Assert-CapsulenvJsonObjectText', 'Get-CapsulenvJsonTopLevelProperties')
    }
    foreach ($functionName in $requiredCalls.Keys) {
        $functionAst = Get-CapsulenvFunctionAst -Path $fullPath -Name $functionName
        $commandNames = @($functionAst.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { [string]$_.GetCommandName() })
        foreach ($required in @($requiredCalls[$functionName])) {
            if ($commandNames -contains $required) { continue }
            $violations.Add([pscustomobject]@{
                Rule = 'BitwardenPreciseStateBoundary'
                Path = $fullPath
                Line = [int]$functionAst.Extent.StartLineNumber
                Column = [int]$functionAst.Extent.StartColumnNumber
                Detail = "$functionName must call $required before changing persisted Bitwarden state"
            })
        }
    }

    $ast = Get-CapsulenvStaticAst -Path $fullPath
    foreach ($commandAst in @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        [string]$node.GetCommandName() -eq 'ConvertTo-Json'
    }, $true))) {
        $elements = @($commandAst.CommandElements)
        for ($index = 1; $index -lt $elements.Count; $index++) {
            if ($elements[$index] -isnot [System.Management.Automation.Language.CommandParameterAst] -or [string]$elements[$index].ParameterName -ne 'Depth') { continue }
            if ($index + 1 -ge $elements.Count) { continue }
            try { $depth = [int]$elements[$index + 1].SafeGetValue() } catch { continue }
            if ($depth -lt 100) { continue }
            $violations.Add([pscustomobject]@{
                Rule = 'BitwardenNoWholesaleJsonReserialization'
                Path = $fullPath
                Line = [int]$commandAst.Extent.StartLineNumber
                Column = [int]$commandAst.Extent.StartColumnNumber
                Detail = 'Bitwarden desktop settings must not be wholesale reserialized; patch only scoped top-level properties'
            })
        }
    }

    return $violations.ToArray()
}
