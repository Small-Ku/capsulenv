function Get-CapsulenvPixiExecutable {
    [CmdletBinding()]
    param()

    return Get-CapsulenvPortableToolExecutable `
        -Candidates @(
            'scoop\shims\pixi.exe'
            'scoop\apps\pixi\current\pixi.exe'
            'scoop-global\shims\pixi.exe'
            'scoop-global\apps\pixi\current\pixi.exe'
            'tool-data\cargo\bin\pixi.exe'
            'tool-data\pixi\bin\pixi.exe'
        ) `
        -CommandNames @('pixi.exe', 'pixi')
}

function Get-CapsulenvPixiHome {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    return Resolve-CapsulenvPath -Path ([string]$configuration.ToolStorage.PathVariables.PIXI_HOME) -AllowMissing
}

function Get-CapsulenvPixiGlobalManifestPath {
    [CmdletBinding()]
    param()

    return Join-Path (Get-CapsulenvPixiHome) 'manifests\pixi-global.toml'
}

function Repair-CapsulenvPixiGlobal {
    [CmdletBinding()]
    param(
        [switch]$DryRun,
        [switch]$IncludeGlobal
    )

    $settings = (Get-CapsulenvToolRelocationConfiguration).Pixi
    if (-not $settings.Enabled) {
        return @([pscustomobject]@{ Component = 'pixi-global'; Status = 'Disabled'; Changed = $false; Detail = $null })
    }
    $manifest = Get-CapsulenvPixiGlobalManifestPath
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        return @([pscustomobject]@{ Component = 'pixi-global'; Status = 'NotConfigured'; Changed = $false; Detail = $manifest })
    }
    $pixi = Get-CapsulenvPixiExecutable
    if ([string]::IsNullOrWhiteSpace($pixi)) {
        return @([pscustomobject]@{ Component = 'pixi-global'; Status = 'NotInstalled'; Changed = $false; Detail = 'Portable Pixi executable not found.' })
    }

    $allowSync = $IncludeGlobal -or [bool]$settings.RepairGlobal
    if (-not $allowSync) {
        return @([pscustomobject]@{
            Component = 'pixi-global'
            Status = 'ManualRequired'
            Changed = $false
            Detail = 'Run tools repair pixi --include-global; global sync may re-resolve versions allowed by pixi-global.toml.'
        })
    }
    if ($DryRun) {
        return @([pscustomobject]@{ Component = 'pixi-global'; Status = 'WouldSync'; Changed = $false; Detail = $manifest })
    }

    [void](Invoke-CapsulenvNativeTool -Executable $pixi -Arguments @('--no-progress', 'global', 'sync'))
    return @([pscustomobject]@{ Component = 'pixi-global'; Status = 'Synced'; Changed = $true; Detail = $manifest })
}


function Test-CapsulenvUvRelocatableVenvSupport {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$UvExecutable)

    $help = Invoke-CapsulenvNativeToolCapture `
        -Executable $UvExecutable `
        -Arguments @('venv', '--help') `
        -AllowFailure
    if ($help.ExitCode -ne 0) {
        return $false
    }
    return (($help.StdOut + "`n" + $help.StdErr).Contains('--relocatable'))
}

function Remove-CapsulenvUvWorkspaceEnvironmentPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return
    }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Remove-Item -LiteralPath $Path -Force
    } else {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Repair-CapsulenvUvWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$UvExecutable,
        [Parameter(Mandatory = $true)]$Workspace,
        [Parameter(Mandatory = $true)][bool]$RelocatableSupported,
        [switch]$DryRun
    )

    $component = "workspace:uv:$($Workspace.ProjectPath)"
    $environmentPath = [System.IO.Path]::GetFullPath([string]$Workspace.EnvironmentPath).TrimEnd([char[]]'\/')
    if ($DryRun) {
        return [pscustomobject]@{
            Component = $component
            Status = 'WouldRecreate'
            Changed = $false
            Detail = $environmentPath
        }
    }

    $environmentParent = Split-Path -Parent $environmentPath
    [void](New-Item -ItemType Directory -Path $environmentParent -Force)
    $rollbackPath = Join-Path $environmentParent ('.capsulenv-uv-env-{0}.rollback' -f [Guid]::NewGuid().ToString('N'))
    $originalItem = Get-Item -LiteralPath $environmentPath -Force -ErrorAction SilentlyContinue
    $movedOriginal = $false
    if ($null -ne $originalItem) {
        Move-Item -LiteralPath $environmentPath -Destination $rollbackPath
        $movedOriginal = $true
    }

    $previousProjectEnvironment = [Environment]::GetEnvironmentVariable('UV_PROJECT_ENVIRONMENT', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('UV_PROJECT_ENVIRONMENT', $environmentPath, 'Process')
        $venvArguments = New-Object System.Collections.Generic.List[string]
        foreach ($argument in @('venv', $environmentPath, '--project', [string]$Workspace.ProjectPath)) {
            $venvArguments.Add($argument)
        }
        if ($RelocatableSupported) {
            $venvArguments.Add('--relocatable')
        }
        $venvArguments.Add('--no-progress')
        [void](Invoke-CapsulenvNativeTool -Executable $UvExecutable -Arguments @($venvArguments))
        [void](Invoke-CapsulenvNativeTool `
            -Executable $UvExecutable `
            -Arguments @(
                'sync',
                '--project', [string]$Workspace.ProjectPath,
                '--locked',
                '--reinstall',
                '--no-progress'
            ))
    } catch {
        $repairError = $_
        try {
            Remove-CapsulenvUvWorkspaceEnvironmentPath -Path $environmentPath
            if ($movedOriginal -and $null -ne (Get-Item -LiteralPath $rollbackPath -Force -ErrorAction SilentlyContinue)) {
                Move-Item -LiteralPath $rollbackPath -Destination $environmentPath
                $movedOriginal = $false
            }
        } catch {
            throw "uv workspace repair failed: $($repairError.Exception.Message) Restoring the previous environment also failed: $($_.Exception.Message) Recovery data remains at: $rollbackPath"
        }
        throw $repairError
    } finally {
        [Environment]::SetEnvironmentVariable('UV_PROJECT_ENVIRONMENT', $previousProjectEnvironment, 'Process')
    }

    if ($movedOriginal -and $null -ne (Get-Item -LiteralPath $rollbackPath -Force -ErrorAction SilentlyContinue)) {
        try {
            Remove-CapsulenvUvWorkspaceEnvironmentPath -Path $rollbackPath
        } catch {
            Write-CapsulenvMessage -Level Warning -Message "The repaired uv environment is ready, but its previous copy remains at: $rollbackPath"
        }
    }
    return [pscustomobject]@{
        Component = $component
        Status = $(if ($RelocatableSupported) { 'RecreatedRelocatable' } else { 'Recreated' })
        Changed = $true
        Detail = $environmentPath
    }
}

function Repair-CapsulenvRegisteredToolWorkspaces {
    [CmdletBinding()]
    param(
        [ValidateSet('uv', 'pixi', 'all')][string]$Tool = 'all',
        [switch]$DryRun,
        [switch]$Strict
    )

    $settings = (Get-CapsulenvToolRelocationConfiguration).Workspaces
    if (-not $settings.Enabled -or -not $settings.RepairRegistered) {
        return @([pscustomobject]@{ Component = 'workspaces'; Status = 'Disabled'; Changed = $false; Detail = $null })
    }

    $uv = $null
    $uvRelocatableSupported = $null
    $pixi = $null
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($workspace in @(Get-CapsulenvToolWorkspaces -Tool $Tool)) {
        $component = "workspace:$($workspace.Tool):$($workspace.ProjectPath)"
        if ($workspace.Status -ne 'Ready') {
            $result = [pscustomobject]@{
                Component = $component
                Status = $workspace.Status
                Changed = $false
                Detail = $workspace.Detail
            }
            $results.Add($result)
            if ($Strict) {
                throw "Registered $($workspace.Tool) workspace is unavailable: $($workspace.ProjectPath). $($workspace.Detail)"
            }
            continue
        }

        try {
            switch ([string]$workspace.Tool) {
                'uv' {
                    if ($null -eq $uv) {
                        $uv = Get-CapsulenvUvExecutable
                    }
                    if ([string]::IsNullOrWhiteSpace($uv)) {
                        throw 'Portable uv executable not found.'
                    }
                    if ($null -eq $uvRelocatableSupported) {
                        $uvRelocatableSupported = Test-CapsulenvUvRelocatableVenvSupport -UvExecutable $uv
                    }
                    $results.Add((Repair-CapsulenvUvWorkspace `
                        -UvExecutable $uv `
                        -Workspace $workspace `
                        -RelocatableSupported ([bool]$uvRelocatableSupported) `
                        -DryRun:$DryRun))
                }
                'pixi' {
                    if ($null -eq $pixi) {
                        $pixi = Get-CapsulenvPixiExecutable
                    }
                    if ([string]::IsNullOrWhiteSpace($pixi)) {
                        throw 'Portable Pixi executable not found.'
                    }
                    if ($DryRun) {
                        $results.Add([pscustomobject]@{ Component = $component; Status = 'WouldReinstall'; Changed = $false; Detail = $workspace.LockPath })
                    } else {
                        [void](Invoke-CapsulenvNativeTool `
                            -Executable $pixi `
                            -Arguments @(
                                '--no-progress',
                                'reinstall',
                                '--all',
                                '--locked',
                                '--manifest-path', [string]$workspace.ProjectPath
                            ))
                        $results.Add([pscustomobject]@{ Component = $component; Status = 'Reinstalled'; Changed = $true; Detail = $workspace.LockPath })
                    }
                }
            }
        } catch {
            if ($Strict) {
                throw
            }
            $results.Add([pscustomobject]@{ Component = $component; Status = 'Failed'; Changed = $false; Detail = $_.Exception.Message })
            Write-CapsulenvMessage -Level Warning -Message $_.Exception.Message
        }
    }
    return @($results)
}

function Repair-CapsulenvPixiRelocation {
    [CmdletBinding()]
    param(
        [switch]$DryRun,
        [switch]$IncludeGlobal
    )

    return @(Repair-CapsulenvPixiGlobal -DryRun:$DryRun -IncludeGlobal:$IncludeGlobal)
}

function Get-CapsulenvToolRelocationStatus {
    [CmdletBinding()]
    param()

    $uv = Get-CapsulenvUvExecutable
    $pixi = Get-CapsulenvPixiExecutable
    $pixiManifest = Get-CapsulenvPixiGlobalManifestPath
    $results = New-Object System.Collections.Generic.List[object]
    $results.Add([pscustomobject]@{
        Tool = 'uv'
        Scope = 'global'
        Path = $uv
        Status = $(if ([string]::IsNullOrWhiteSpace($uv)) { 'NotInstalled' } else { 'Ready' })
        Detail = (Get-CapsulenvUvToolDirectory)
    })
    $results.Add([pscustomobject]@{
        Tool = 'pixi'
        Scope = 'global'
        Path = $pixi
        Status = $(
            if ([string]::IsNullOrWhiteSpace($pixi)) {
                'NotInstalled'
            } elseif (Test-Path -LiteralPath $pixiManifest -PathType Leaf) {
                'Ready'
            } else {
                'NoGlobalManifest'
            }
        )
        Detail = $pixiManifest
    })
    foreach ($workspace in @(Get-CapsulenvToolWorkspaces)) {
        $workspaceDetail = if ($workspace.Status -ne 'Ready') {
            $workspace.Detail
        } elseif ($workspace.Tool -eq 'uv') {
            'lock={0}; environment={1}' -f $workspace.LockPath, $workspace.EnvironmentPath
        } else {
            'lock={0}; environments={1}' -f $workspace.LockPath, $workspace.EnvironmentPath
        }
        $results.Add([pscustomobject]@{
            Tool = $workspace.Tool
            Scope = 'workspace'
            Path = $workspace.ProjectPath
            Status = $workspace.Status
            Detail = $workspaceDetail
        })
    }
    return @($results)
}

##MOD_EXEC## Export-ModuleMember -Function Repair-CapsulenvPixiRelocation, Get-CapsulenvToolRelocationStatus
