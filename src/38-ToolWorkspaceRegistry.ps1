function Get-CapsulenvToolWorkspaceRegistryPath {
    [CmdletBinding()]
    param()

    return Join-Path (Get-CapsulenvContext).StateRoot 'tool-workspaces.json'
}

function Get-CapsulenvToolWorkspaceRecordKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Tool,
        [Parameter(Mandatory = $true)][string]$ProjectScope,
        [Parameter(Mandatory = $true)][string]$ProjectReference
    )

    return ('{0}|{1}|{2}' -f $Tool, $ProjectScope, $ProjectReference.Replace('\', '/')).ToLowerInvariant()
}

function Get-CapsulenvRelativeChildPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Child
    )

    $parentPath = [System.IO.Path]::GetFullPath($Parent).TrimEnd([char[]]'\/')
    $childPath = [System.IO.Path]::GetFullPath($Child).TrimEnd([char[]]'\/')
    if (-not (Test-CapsulenvPathNested -Parent $parentPath -Child $childPath)) {
        throw "Path is not a child of the expected root: $childPath"
    }
    $prefix = $parentPath + [System.IO.Path]::DirectorySeparatorChar
    return $childPath.Substring($prefix.Length).Replace('\', '/')
}

function Get-CapsulenvUvWorkspaceEnvironmentReference {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    $project = [System.IO.Path]::GetFullPath($ProjectPath).TrimEnd([char[]]'\/')
    $request = [string]$env:UV_PROJECT_ENVIRONMENT
    if ([string]::IsNullOrWhiteSpace($request)) {
        $request = '.venv'
    }
    $request = [Environment]::ExpandEnvironmentVariables($request)
    $environmentPath = if ([System.IO.Path]::IsPathRooted($request)) {
        [System.IO.Path]::GetFullPath($request).TrimEnd([char[]]'\/')
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $project $request)).TrimEnd([char[]]'\/')
    }

    if (Test-CapsulenvSamePath -Left $environmentPath -Right $project) {
        throw 'UV_PROJECT_ENVIRONMENT must not be the workspace root.'
    }
    if (Test-CapsulenvPathNested -Parent $project -Child $environmentPath) {
        return [pscustomobject]@{
            Scope = 'Project'
            Reference = Get-CapsulenvRelativeChildPath -Parent $project -Child $environmentPath
            Path = $environmentPath
        }
    }

    $capsuleRoot = (Get-CapsulenvContext).Root
    if (Test-CapsulenvSamePath -Left $environmentPath -Right $capsuleRoot) {
        throw 'UV_PROJECT_ENVIRONMENT must not be the capsulenv root.'
    }
    if (Test-CapsulenvPathNested -Parent $capsuleRoot -Child $environmentPath) {
        return [pscustomobject]@{
            Scope = 'Capsule'
            Reference = Get-CapsulenvRelativeChildPath -Parent $capsuleRoot -Child $environmentPath
            Path = $environmentPath
        }
    }

    throw "UV_PROJECT_ENVIRONMENT must remain inside the registered workspace or capsulenv root: $environmentPath"
}

function Resolve-CapsulenvUvWorkspaceEnvironmentPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [string]$EnvironmentScope,
        [string]$EnvironmentReference
    )

    $project = [System.IO.Path]::GetFullPath($ProjectPath).TrimEnd([char[]]'\/')
    if ([string]::IsNullOrWhiteSpace($EnvironmentScope)) {
        $EnvironmentScope = 'Project'
        $EnvironmentReference = '.venv'
    }
    if (
        [string]::IsNullOrWhiteSpace($EnvironmentReference) -or
        [System.IO.Path]::IsPathRooted($EnvironmentReference) -or
        $EnvironmentReference -match '(^|[\\/])\.\.([\\/]|$)'
    ) {
        throw "Tool-workspace record has an invalid uv environment reference: $EnvironmentReference"
    }

    switch ($EnvironmentScope) {
        'Project' {
            $resolved = [System.IO.Path]::GetFullPath((Join-Path $project $EnvironmentReference)).TrimEnd([char[]]'\/')
            if (-not (Test-CapsulenvPathNested -Parent $project -Child $resolved)) {
                throw "Registered uv environment escapes the workspace: $resolved"
            }
        }
        'Capsule' {
            $resolved = Resolve-CapsulenvPath -Path $EnvironmentReference -AllowMissing
            $capsuleRoot = (Get-CapsulenvContext).Root
            if (-not (Test-CapsulenvPathNested -Parent $capsuleRoot -Child $resolved)) {
                throw "Registered uv environment escapes the capsulenv root: $resolved"
            }
        }
        default {
            throw "Tool-workspace record has an unsupported uv environment scope: $EnvironmentScope"
        }
    }
    return $resolved
}

function Read-CapsulenvToolWorkspaceRegistry {
    [CmdletBinding()]
    param()

    $path = Get-CapsulenvToolWorkspaceRegistryPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @()
    }
    $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($null -eq $state.SchemaVersion -or [int]$state.SchemaVersion -notin @(1, 2)) {
        throw "Unsupported tool-workspace registry schema: $($state.SchemaVersion)"
    }
    return @($state.Workspaces)
}

function Write-CapsulenvToolWorkspaceRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records)

    $path = Get-CapsulenvToolWorkspaceRegistryPath
    $parent = Split-Path -Parent $path
    [void](New-Item -ItemType Directory -Path $parent -Force)
    $temporary = Join-Path $parent ('.tool-workspaces-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    $rollback = $null
    try {
        [ordered]@{
            SchemaVersion = 2
            Workspaces = @($Records | Sort-Object Tool, ProjectScope, ProjectReference)
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8

        [void]([System.IO.File]::ReadAllText($temporary) | ConvertFrom-Json)
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                [System.IO.File]::Replace($temporary, $path, $null, $true)
            } catch {
                $rollback = Join-Path $parent ('.tool-workspaces-{0}.rollback' -f [Guid]::NewGuid().ToString('N'))
                Move-Item -LiteralPath $path -Destination $rollback
                try {
                    Move-Item -LiteralPath $temporary -Destination $path
                    Remove-Item -LiteralPath $rollback -Force
                    $rollback = $null
                } catch {
                    if (Test-Path -LiteralPath $path) {
                        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                    }
                    Move-Item -LiteralPath $rollback -Destination $path -ErrorAction SilentlyContinue
                    throw
                }
            }
        } else {
            Move-Item -LiteralPath $temporary -Destination $path
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $rollback -and (Test-Path -LiteralPath $rollback)) {
            Write-CapsulenvMessage -Level Warning -Message "Tool-workspace registry recovery file remains at: $rollback"
        }
    }
}

function Get-CapsulenvToolWorkspaceDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('uv', 'pixi')][string]$Tool,
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [string]$EnvironmentScope,
        [string]$EnvironmentReference
    )

    $Tool = $Tool.ToLowerInvariant()
    $project = [System.IO.Path]::GetFullPath($ProjectPath).TrimEnd([char[]]'\/')
    if (-not (Test-Path -LiteralPath $project -PathType Container)) {
        throw "Tool workspace does not exist: $project"
    }

    $manifest = $null
    $lock = $null
    $environment = $null
    $resolvedEnvironmentScope = $null
    $resolvedEnvironmentReference = $null
    switch ($Tool) {
        'uv' {
            $manifest = Join-Path $project 'pyproject.toml'
            $lock = Join-Path $project 'uv.lock'
            if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
                throw "uv workspace is missing pyproject.toml: $project"
            }
            if (-not (Test-Path -LiteralPath $lock -PathType Leaf)) {
                throw "uv workspace is missing uv.lock: $project"
            }
            if ($PSBoundParameters.ContainsKey('EnvironmentScope')) {
                $environment = Resolve-CapsulenvUvWorkspaceEnvironmentPath `
                    -ProjectPath $project `
                    -EnvironmentScope $EnvironmentScope `
                    -EnvironmentReference $EnvironmentReference
                $resolvedEnvironmentScope = if ([string]::IsNullOrWhiteSpace($EnvironmentScope)) { 'Project' } else { $EnvironmentScope }
                $resolvedEnvironmentReference = if ([string]::IsNullOrWhiteSpace($EnvironmentReference)) { '.venv' } else { $EnvironmentReference }
            } else {
                $environmentDefinition = Get-CapsulenvUvWorkspaceEnvironmentReference -ProjectPath $project
                $environment = $environmentDefinition.Path
                $resolvedEnvironmentScope = $environmentDefinition.Scope
                $resolvedEnvironmentReference = $environmentDefinition.Reference
            }
        }
        'pixi' {
            $pixiManifest = Join-Path $project 'pixi.toml'
            $pyprojectManifest = Join-Path $project 'pyproject.toml'
            if (Test-Path -LiteralPath $pixiManifest -PathType Leaf) {
                $manifest = $pixiManifest
            } elseif (Test-Path -LiteralPath $pyprojectManifest -PathType Leaf) {
                $manifest = $pyprojectManifest
            } else {
                throw "Pixi workspace is missing pixi.toml or pyproject.toml: $project"
            }
            $lock = Join-Path $project 'pixi.lock'
            if (-not (Test-Path -LiteralPath $lock -PathType Leaf)) {
                throw "Pixi workspace is missing pixi.lock: $project"
            }
            $environment = Join-Path $project '.pixi\envs'
        }
    }

    return [pscustomobject]@{
        Tool = $Tool
        ProjectPath = $project
        ManifestPath = $manifest
        LockPath = $lock
        EnvironmentPath = $environment
        EnvironmentScope = $resolvedEnvironmentScope
        EnvironmentReference = $resolvedEnvironmentReference
    }
}

function Register-CapsulenvToolWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('uv', 'pixi')][string]$Tool,
        [string]$ProjectPath = '.'
    )

    $Tool = $Tool.ToLowerInvariant()
    $definition = Get-CapsulenvToolWorkspaceDefinition -Tool $Tool -ProjectPath $ProjectPath
    $reference = Get-CapsulenvProjectCacheReference -ProjectPath $definition.ProjectPath
    $key = Get-CapsulenvToolWorkspaceRecordKey `
        -Tool $Tool `
        -ProjectScope $reference.Scope `
        -ProjectReference $reference.Reference

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($record in @(Read-CapsulenvToolWorkspaceRegistry)) {
        $recordKey = Get-CapsulenvToolWorkspaceRecordKey `
            -Tool ([string]$record.Tool) `
            -ProjectScope ([string]$record.ProjectScope) `
            -ProjectReference ([string]$record.ProjectReference)
        if ($recordKey -ne $key) {
            $records.Add($record)
        }
    }
    $records.Add([pscustomobject][ordered]@{
        Tool = $Tool
        ProjectScope = [string]$reference.Scope
        ProjectReference = [string]$reference.Reference
        EnvironmentScope = [string]$definition.EnvironmentScope
        EnvironmentReference = [string]$definition.EnvironmentReference
        LastPath = [string]$definition.ProjectPath
        RegisteredAtUtc = [DateTime]::UtcNow.ToString('o')
    })
    Write-CapsulenvToolWorkspaceRegistry -Records $records.ToArray()

    return [pscustomobject]@{
        Tool = $Tool
        ProjectPath = $definition.ProjectPath
        ManifestPath = $definition.ManifestPath
        LockPath = $definition.LockPath
        EnvironmentPath = $definition.EnvironmentPath
        Status = 'Registered'
    }
}

function Unregister-CapsulenvToolWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('uv', 'pixi')][string]$Tool,
        [string]$ProjectPath = '.'
    )

    $Tool = $Tool.ToLowerInvariant()
    $project = [System.IO.Path]::GetFullPath($ProjectPath).TrimEnd([char[]]'\/')
    $reference = Get-CapsulenvProjectCacheReference -ProjectPath $project
    $key = Get-CapsulenvToolWorkspaceRecordKey `
        -Tool $Tool `
        -ProjectScope $reference.Scope `
        -ProjectReference $reference.Reference
    $before = @(Read-CapsulenvToolWorkspaceRegistry)
    $remaining = @(
        $before | Where-Object {
            (Get-CapsulenvToolWorkspaceRecordKey `
                -Tool ([string]$_.Tool) `
                -ProjectScope ([string]$_.ProjectScope) `
                -ProjectReference ([string]$_.ProjectReference)) -ne $key
        }
    )
    if ($remaining.Count -eq $before.Count) {
        return [pscustomobject]@{ Tool = $Tool; ProjectPath = $project; Status = 'NotRegistered' }
    }
    Write-CapsulenvToolWorkspaceRegistry -Records $remaining
    return [pscustomobject]@{ Tool = $Tool; ProjectPath = $project; Status = 'Unregistered' }
}

function Get-CapsulenvToolWorkspaces {
    [CmdletBinding()]
    param([ValidateSet('uv', 'pixi', 'all')][string]$Tool = 'all')

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($record in @(Read-CapsulenvToolWorkspaceRegistry)) {
        $recordTool = ([string]$record.Tool).ToLowerInvariant()
        if ($recordTool -notin @('uv', 'pixi')) {
            $results.Add([pscustomobject]@{
                Tool = $recordTool
                ProjectPath = [string]$record.LastPath
                ManifestPath = $null
                LockPath = $null
                EnvironmentPath = $null
                Status = 'InvalidRecord'
                Detail = 'Unsupported tool name.'
            })
            continue
        }
        if ($Tool -ne 'all' -and $recordTool -ne $Tool) {
            continue
        }
        try {
            $project = Resolve-CapsulenvProjectCacheRecordPath -Record $record
            $environmentScopeProperty = $record.PSObject.Properties['EnvironmentScope']
            $environmentReferenceProperty = $record.PSObject.Properties['EnvironmentReference']
            $environmentScope = if ($null -eq $environmentScopeProperty) { $null } else { [string]$environmentScopeProperty.Value }
            $environmentReference = if ($null -eq $environmentReferenceProperty) { $null } else { [string]$environmentReferenceProperty.Value }
            if ($recordTool -eq 'uv') {
                $definition = Get-CapsulenvToolWorkspaceDefinition `
                    -Tool $recordTool `
                    -ProjectPath $project `
                    -EnvironmentScope $environmentScope `
                    -EnvironmentReference $environmentReference
            } else {
                $definition = Get-CapsulenvToolWorkspaceDefinition -Tool $recordTool -ProjectPath $project
            }
            $results.Add([pscustomobject]@{
                Tool = $recordTool
                ProjectPath = $definition.ProjectPath
                ManifestPath = $definition.ManifestPath
                LockPath = $definition.LockPath
                EnvironmentPath = $definition.EnvironmentPath
                Status = 'Ready'
                Detail = $null
            })
        } catch {
            $detail = $_.Exception.Message
            $path = [string]$record.LastPath
            try {
                $path = Resolve-CapsulenvProjectCacheRecordPath -Record $record
            } catch {
                # Keep the last known path for diagnostics when the record is malformed.
            }
            $results.Add([pscustomobject]@{
                Tool = $recordTool
                ProjectPath = $path
                ManifestPath = $null
                LockPath = $null
                EnvironmentPath = $null
                Status = 'Unavailable'
                Detail = $detail
            })
        }
    }
    return $results.ToArray()
}

##MOD_EXEC## Export-ModuleMember -Function Register-CapsulenvToolWorkspace, Unregister-CapsulenvToolWorkspace, Get-CapsulenvToolWorkspaces
