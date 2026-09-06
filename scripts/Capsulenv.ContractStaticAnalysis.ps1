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

function Get-CapsulenvProcessIsolationBoundaryViolations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProcessPlanPath,
        [Parameter(Mandatory = $true)][string]$AppLauncherPath,
        [Parameter(Mandatory = $true)][string]$PackageProcessPath,
        [Parameter(Mandatory = $true)][string]$ToolRelocationPath
    )

    $violations = New-Object System.Collections.Generic.List[object]
    function Add-ProcessIsolationViolation {
        param($Ast, [string]$Path, [string]$Rule, [string]$Detail)
        $violations.Add([pscustomobject]@{
            Rule = $Rule
            Path = [System.IO.Path]::GetFullPath($Path)
            Line = [int]$Ast.Extent.StartLineNumber
            Column = [int]$Ast.Extent.StartColumnNumber
            Detail = $Detail
        })
    }
    function Get-ProcessCommands {
        param($FunctionAst)
        return @($FunctionAst.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    }

    # Shortcut launch is detached by definition. It must build the canonical
    # process plan and may not mutate parent process state or bypass the plan.
    $shortcut = Get-CapsulenvFunctionAst -Path $AppLauncherPath -Name 'Start-CapsulenvScoopShortcut'
    $shortcutCommands = @(Get-ProcessCommands $shortcut)
    $shortcutNames = @($shortcutCommands | ForEach-Object { [string]$_.GetCommandName() })
    foreach ($required in @('New-CapsulenvProcessPlan', 'Invoke-CapsulenvProcessPlan')) {
        if ($shortcutNames -contains $required) { continue }
        Add-ProcessIsolationViolation -Ast $shortcut -Path $AppLauncherPath -Rule 'DetachedShortcutCanonicalProcessPlan' -Detail "Scoop shortcut launch must use $required"
    }
    foreach ($forbidden in @('Start-Process', 'Set-CapsulenvPackageProcessEnvironment')) {
        foreach ($commandAst in @($shortcutCommands | Where-Object { [string]$_.GetCommandName() -eq $forbidden })) {
            Add-ProcessIsolationViolation -Ast $commandAst -Path $AppLauncherPath -Rule 'DetachedShortcutNoParentProcessMutation' -Detail "Scoop shortcut launch must not use parent-scoped/bypass command: $forbidden"
        }
    }

    # The old package-only environment mutator and ToolRelocation-only process
    # builder are duplicate implementations. Reintroducing either recreates a
    # second process-environment authority.
    foreach ($entry in @(
        [pscustomobject]@{ Path = $PackageProcessPath; Name = 'Set-CapsulenvPackageProcessEnvironment'; Rule = 'PackageProcessNoParentEnvironmentMutator' },
        [pscustomobject]@{ Path = $ToolRelocationPath; Name = 'New-CapsulenvNativeProcessStartInfo'; Rule = 'ProcessStartInfoSingleAuthority' }
    )) {
        $ast = Get-CapsulenvStaticAst -Path $entry.Path
        foreach ($definition in @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true) | Where-Object { [string]$_.Name -eq [string]$entry.Name })) {
            Add-ProcessIsolationViolation -Ast $definition -Path $entry.Path -Rule $entry.Rule -Detail "obsolete duplicate process helper must not be reintroduced: $($entry.Name)"
        }
    }

    # Detached execution must cross into ProcessStartInfo before any host
    # environment/cwd overlay used by passthrough execution.
    $invokePlan = Get-CapsulenvFunctionAst -Path $ProcessPlanPath -Name 'Invoke-CapsulenvProcessPlan'
    $invokeCommands = @(Get-ProcessCommands $invokePlan | Sort-Object { $_.Extent.StartOffset })
    $detachedDispatch = @($invokeCommands | Where-Object { [string]$_.GetCommandName() -eq 'Invoke-CapsulenvDetachedProcessPlan' } | Select-Object -First 1)
    $hostOverlay = @($invokeCommands | Where-Object { [string]$_.GetCommandName() -in @('Push-Location', 'Pop-Location') } | Select-Object -First 1)
    if ($detachedDispatch.Count -eq 0) {
        Add-ProcessIsolationViolation -Ast $invokePlan -Path $ProcessPlanPath -Rule 'DetachedProcessPlanDispatchRequired' -Detail 'Invoke-CapsulenvProcessPlan must dispatch Detached mode through the child-local process helper'
    } elseif ($hostOverlay.Count -gt 0 -and $detachedDispatch[0].Extent.StartOffset -gt $hostOverlay[0].Extent.StartOffset) {
        Add-ProcessIsolationViolation -Ast $hostOverlay[0] -Path $ProcessPlanPath -Rule 'DetachedProcessPlanBeforeHostOverlay' -Detail 'Detached process dispatch must occur before passthrough host environment/cwd overlay'
    }

    $detached = Get-CapsulenvFunctionAst -Path $ProcessPlanPath -Name 'Invoke-CapsulenvDetachedProcessPlan'
    $detachedCommands = @(Get-ProcessCommands $detached)
    $detachedNames = @($detachedCommands | ForEach-Object { [string]$_.GetCommandName() })
    if ($detachedNames -notcontains 'New-CapsulenvProcessStartInfo') {
        Add-ProcessIsolationViolation -Ast $detached -Path $ProcessPlanPath -Rule 'DetachedProcessStartInfoRequired' -Detail 'detached process execution must use the canonical child-local ProcessStartInfo builder'
    }
    foreach ($forbidden in @('Start-Process', 'Push-Location', 'Pop-Location', 'Set-Location')) {
        foreach ($commandAst in @($detachedCommands | Where-Object { [string]$_.GetCommandName() -eq $forbidden })) {
            Add-ProcessIsolationViolation -Ast $commandAst -Path $ProcessPlanPath -Rule 'DetachedProcessNoHostOverlay' -Detail "detached process helper must not mutate/bypass host process context: $forbidden"
        }
    }
    foreach ($memberAst in @($detached.Body.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        [string]$node.Extent.Text -match 'SetEnvironmentVariable'
    }, $true))) {
        Add-ProcessIsolationViolation -Ast $memberAst -Path $ProcessPlanPath -Rule 'DetachedProcessNoHostEnvironmentMutation' -Detail 'detached process helper must not mutate the parent process environment'
    }

    return $violations.ToArray()
}

function Get-CapsulenvModeIsolationBoundaryViolations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EnvironmentPath,
        [Parameter(Mandatory = $true)][string]$PackageHostIntegrationPath,
        [Parameter(Mandatory = $true)][string]$BitwardenPath,
        [Parameter(Mandatory = $true)][string]$LegacyProjectionPath
    )

    $violations = New-Object System.Collections.Generic.List[object]

    function Add-ModeViolation {
        param($Ast, [string]$Path, [string]$Rule, [string]$Detail)
        $violations.Add([pscustomobject]@{
            Rule = $Rule
            Path = [System.IO.Path]::GetFullPath($Path)
            Line = [int]$Ast.Extent.StartLineNumber
            Column = [int]$Ast.Extent.StartColumnNumber
            Detail = $Detail
        })
    }

    function Get-CommandsInFunction {
        param($FunctionAst)
        return @($FunctionAst.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    }

    # Persistent Start Menu projection belongs exclusively to User mode.  The
    # guard must dominate the first host mutation instead of relying on callers
    # to remember the correct mode.
    $startMenu = Get-CapsulenvFunctionAst -Path $PackageHostIntegrationPath -Name 'Sync-CapsulenvPackageStartMenuShortcuts'
    $startMenuMutations = @(Get-CommandsInFunction $startMenu | Where-Object {
        [string]$_.GetCommandName() -in @('Remove-Item', 'New-Item', 'New-Object')
    } | Sort-Object { $_.Extent.StartOffset })
    $startMenuGuard = @($startMenu.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.IfStatementAst] }, $true) | Where-Object {
        $_.Extent.Text -match '\$IntegrationMode' -and
        $_.Extent.Text -match "'User'" -and
        @($_.Clauses.Item2.FindAll({ param($node) $node -is [System.Management.Automation.Language.ReturnStatementAst] }, $true)).Count -gt 0
    } | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1)
    if ($startMenuGuard.Count -eq 0 -or ($startMenuMutations.Count -gt 0 -and $startMenuGuard[0].Extent.StartOffset -gt $startMenuMutations[0].Extent.StartOffset)) {
        Add-ModeViolation -Ast $startMenu -Path $PackageHostIntegrationPath -Rule 'ModeIsolationStartMenuUserGuard' -Detail 'persistent Start Menu projection must return before host mutation unless IntegrationMode is User'
    }

    # Machine-level ssh-agent mutation is never permitted in ShellOnly.
    $disableAgent = Get-CapsulenvFunctionAst -Path $BitwardenPath -Name 'Disable-CapsulenvWindowsSshAgent'
    $serviceMutations = @(Get-CommandsInFunction $disableAgent | Where-Object {
        [string]$_.GetCommandName() -in @('Stop-Service', 'Set-Service')
    } | Sort-Object { $_.Extent.StartOffset })
    $agentGuard = @($disableAgent.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.IfStatementAst] }, $true) | Where-Object {
        $_.Extent.Text -match 'Get-CapsulenvInstallMode' -and
        $_.Extent.Text -match "'User'" -and
        @($_.Clauses.Item2.FindAll({ param($node) $node -is [System.Management.Automation.Language.ThrowStatementAst] }, $true)).Count -gt 0
    } | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1)
    if ($agentGuard.Count -eq 0 -or ($serviceMutations.Count -gt 0 -and $agentGuard[0].Extent.StartOffset -gt $serviceMutations[0].Extent.StartOffset)) {
        Add-ModeViolation -Ast $disableAgent -Path $BitwardenPath -Rule 'ModeIsolationSshAgentUserGuard' -Detail 'Windows ssh-agent service mutation must be dominated by a User-mode guard'
    }

    # ShellOnly Git integration must exit through the process-only overlay before
    # any dynamic `git config --global` command becomes reachable.
    $gitSetup = Get-CapsulenvFunctionAst -Path $BitwardenPath -Name 'Set-CapsulenvGitOpenSsh'
    $shellOnlyBranch = @($gitSetup.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.IfStatementAst] }, $true) | Where-Object {
        $_.Extent.Text -match "'ShellOnly'" -and
        @($_.Clauses.Item2.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and [string]$node.GetCommandName() -eq 'Enable-CapsulenvGitOpenSshSession' }, $true)).Count -gt 0 -and
        @($_.Clauses.Item2.FindAll({ param($node) $node -is [System.Management.Automation.Language.ReturnStatementAst] }, $true)).Count -gt 0
    } | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1)
    $globalGit = @(Get-CommandsInFunction $gitSetup | Where-Object { $_.Extent.Text -match '(?i)\bconfig\s+--global\b' } | Sort-Object { $_.Extent.StartOffset })
    if ($shellOnlyBranch.Count -eq 0 -or ($globalGit.Count -gt 0 -and $shellOnlyBranch[0].Extent.StartOffset -gt $globalGit[0].Extent.StartOffset)) {
        Add-ModeViolation -Ast $gitSetup -Path $BitwardenPath -Rule 'ModeIsolationGitShellOnlyEarlyReturn' -Detail 'ShellOnly Git integration must use the process-only overlay and return before any git config --global mutation'
    }

    # Leaving User mode is a transactional ownership boundary.  Every persistent
    # integration Capsulenv can own must be restored/removed before mode flips.
    $restoreUser = Get-CapsulenvFunctionAst -Path $EnvironmentPath -Name 'Restore-CapsulenvUserEnvironment'
    $restoreCommands = @(Get-CommandsInFunction $restoreUser | ForEach-Object { [string]$_.GetCommandName() })
    foreach ($required in @(
        'Restore-CapsulenvWindowsSshAgent',
        'Restore-CapsulenvGitOpenSshGlobal',
        'Restore-CapsulenvDefaultBrowserRegistration',
        'Remove-CapsulenvUserStartMenuShortcuts',
        'Set-CapsulenvInstallMode'
    )) {
        if ($restoreCommands -contains $required) { continue }
        Add-ModeViolation -Ast $restoreUser -Path $EnvironmentPath -Rule 'ModeIsolationRestoreUserOwnership' -Detail "Restore-CapsulenvUserEnvironment must include ownership restoration step: $required"
    }

    # A normal child shell may refresh persistent browser registration only in
    # User mode.  ShellOnly activation must not inherit persistent host writes.
    $childShell = Get-CapsulenvFunctionAst -Path $EnvironmentPath -Name 'Invoke-CapsulenvChildShell'
    foreach ($syncCommand in @(Get-CommandsInFunction $childShell | Where-Object { [string]$_.GetCommandName() -eq 'Sync-CapsulenvConfiguredDefaultBrowser' })) {
        $cursor = $syncCommand.Parent
        $guarded = $false
        while ($null -ne $cursor -and $cursor -ne $childShell) {
            if ($cursor -is [System.Management.Automation.Language.IfStatementAst] -and
                $cursor.Extent.Text -match '\$IntegrationMode' -and
                $cursor.Extent.Text -match "'User'") {
                $guarded = $true
                break
            }
            $cursor = $cursor.Parent
        }
        if (-not $guarded) {
            Add-ModeViolation -Ast $syncCommand -Path $EnvironmentPath -Rule 'ModeIsolationBrowserUserGuard' -Detail 'persistent default-browser synchronization from child-shell activation must be guarded by IntegrationMode User'
        }
    }

    # Legacy projection repair owns files/links only.  Host UI integration is a
    # separate User-mode node and must never leak back into projection repair.
    $legacyAst = Get-CapsulenvStaticAst -Path $LegacyProjectionPath
    foreach ($commandAst in @($legacyAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))) {
        $commandName = [string]$commandAst.GetCommandName()
        if ($commandName -eq 'New-Object' -and $commandAst.Extent.Text -match '(?i)WScript\.Shell') {
            Add-ModeViolation -Ast $commandAst -Path $LegacyProjectionPath -Rule 'ModeIsolationLegacyProjectionNoHostUi' -Detail 'legacy package projection code must not own host shortcut implementation'
            continue
        }
        if ($commandName -ne 'Sync-CapsulenvPackageStartMenuShortcuts') { continue }
        $cursor = $commandAst.Parent
        $guarded = $false
        while ($null -ne $cursor -and $cursor -ne $legacyAst) {
            if ($cursor -is [System.Management.Automation.Language.IfStatementAst] -and
                $cursor.Extent.Text -match '\$IntegrationMode' -and
                $cursor.Extent.Text -match "'User'") {
                $guarded = $true
                break
            }
            $cursor = $cursor.Parent
        }
        if (-not $guarded) {
            Add-ModeViolation -Ast $commandAst -Path $LegacyProjectionPath -Rule 'ModeIsolationLegacyProjectionUserHostGuard' -Detail 'legacy projection wrapper may synchronize host shortcuts only under an explicit IntegrationMode User guard'
        }
    }

    return $violations.ToArray()
}

function Get-CapsulenvScoopBootstrapHotPathViolations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BootstrapPath,
        [Parameter(Mandatory = $true)][string]$IntegrationsPath,
        [Parameter(Mandatory = $true)][string]$CommandsPath
    )

    $violations = New-Object System.Collections.Generic.List[object]
    function Add-BootstrapViolation {
        param($Ast, [string]$Path, [string]$Rule, [string]$Detail)
        $violations.Add([pscustomobject]@{
            Rule = $Rule
            Path = [System.IO.Path]::GetFullPath($Path)
            Line = [int]$Ast.Extent.StartLineNumber
            Column = [int]$Ast.Extent.StartColumnNumber
            Detail = $Detail
        })
    }
    function Get-BootstrapCommands {
        param($FunctionAst)
        return @($FunctionAst.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    }
    function Test-CommandHasParameter {
        param($CommandAst, [string]$Name)
        return @($CommandAst.CommandElements | Where-Object {
            $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
            [string]$_.ParameterName -eq $Name
        }).Count -gt 0
    }

    $ready = Get-CapsulenvFunctionAst -Path $BootstrapPath -Name 'Test-CapsulenvScoopBootstrapReady'
    foreach ($commandAst in @(Get-BootstrapCommands $ready)) {
        $name = [string]$commandAst.GetCommandName()
        if ($name -in @(
            'New-Item', 'Remove-Item', 'Set-Content', 'Add-Content', 'Get-Content', 'Get-ChildItem',
            'Copy-Item', 'Move-Item', 'Invoke-WebRequest', 'Ensure-CapsulenvScoopPortableConfig',
            'Install-CapsulenvBootstrapRepository', 'Install-CapsulenvScoopShim',
            'Remove-CapsulenvLegacyScoopPowerShellShim', 'Complete-CapsulenvScoopBootstrapMarker'
        )) {
            Add-BootstrapViolation -Ast $commandAst -Path $BootstrapPath -Rule 'ScoopBootstrapReadyMetadataOnly' -Detail "steady bootstrap readiness must not perform mutation/content enumeration: $name"
        }
    }
    foreach ($memberAst in @($ready.Body.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]
    }, $true))) {
        $member = [string]$memberAst.Member.Value
        if ($member -in @('ReadAllText', 'WriteAllText', 'ReadAllBytes', 'WriteAllBytes', 'Open', 'OpenRead', 'OpenWrite')) {
            Add-BootstrapViolation -Ast $memberAst -Path $BootstrapPath -Rule 'ScoopBootstrapReadyMetadataOnly' -Detail "steady bootstrap readiness must not read/write file contents: $member"
        }
    }

    $initialize = Get-CapsulenvFunctionAst -Path $BootstrapPath -Name 'Initialize-CapsulenvScoopBootstrap'
    $initializeCommands = @(Get-BootstrapCommands $initialize | Sort-Object { $_.Extent.StartOffset })
    $readyCall = @($initializeCommands | Where-Object { [string]$_.GetCommandName() -eq 'Test-CapsulenvScoopBootstrapReady' } | Select-Object -First 1)
    $firstRepair = @($initializeCommands | Where-Object {
        [string]$_.GetCommandName() -in @('Ensure-CapsulenvScoopPortableConfig', 'Install-CapsulenvScoopShim', 'Install-CapsulenvBootstrapRepository')
    } | Select-Object -First 1)
    if ($readyCall.Count -eq 0) {
        Add-BootstrapViolation -Ast $initialize -Path $BootstrapPath -Rule 'ScoopBootstrapReadyGateRequired' -Detail 'Initialize-CapsulenvScoopBootstrap must gate steady activation through Test-CapsulenvScoopBootstrapReady'
    } elseif ($firstRepair.Count -gt 0 -and $readyCall[0].Extent.StartOffset -gt $firstRepair[0].Extent.StartOffset) {
        Add-BootstrapViolation -Ast $readyCall[0] -Path $BootstrapPath -Rule 'ScoopBootstrapReadyGateRequired' -Detail 'bootstrap readiness gate must run before repair/mutation work'
    }

    $integrations = Get-CapsulenvFunctionAst -Path $IntegrationsPath -Name 'Initialize-CapsulenvIntegrations'
    foreach ($call in @(Get-BootstrapCommands $integrations | Where-Object { [string]$_.GetCommandName() -eq 'Initialize-CapsulenvScoopBootstrap' })) {
        if (Test-CommandHasParameter -CommandAst $call -Name 'ForceRepair') {
            Add-BootstrapViolation -Ast $call -Path $IntegrationsPath -Rule 'ScoopBootstrapSteadyActivationNotForced' -Detail 'normal activation must use bootstrap readiness fast path, not ForceRepair'
        }
    }

    $explicitInit = Get-CapsulenvFunctionAst -Path $IntegrationsPath -Name 'Initialize-Capsulenv'
    foreach ($call in @(Get-BootstrapCommands $explicitInit | Where-Object { [string]$_.GetCommandName() -eq 'Initialize-CapsulenvScoopBootstrap' })) {
        if (-not (Test-CommandHasParameter -CommandAst $call -Name 'ForceRepair')) {
            Add-BootstrapViolation -Ast $call -Path $IntegrationsPath -Rule 'ScoopBootstrapExplicitRepairForced' -Detail 'explicit init must force bootstrap normalization/repair'
        }
    }

    $dispatcher = Get-CapsulenvFunctionAst -Path $CommandsPath -Name 'Invoke-Capsulenv'
    foreach ($call in @(Get-BootstrapCommands $dispatcher | Where-Object { [string]$_.GetCommandName() -eq 'Initialize-CapsulenvScoopBootstrap' })) {
        if (-not (Test-CommandHasParameter -CommandAst $call -Name 'ForceRepair')) {
            Add-BootstrapViolation -Ast $call -Path $CommandsPath -Rule 'ScoopBootstrapExplicitRepairForced' -Detail 'capsulenv bootstrap command must force bootstrap normalization/repair'
        }
    }

    return $violations.ToArray()
}
