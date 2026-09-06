function Invoke-CapsulenvCacheCommand {
    param([string[]]$Arguments)

    if ($Arguments.Count -lt 1) {
        throw 'Usage: cache <paths|init|status|link|unlink|repair> [...]'
    }

    $action = $Arguments[0].ToLowerInvariant()
    $remaining = @($Arguments | Select-Object -Skip 1)
    switch ($action) {
        'paths' {
            if ($remaining.Count -gt 0) {
                throw 'Usage: cache paths'
            }
            Get-CapsulenvToolStorageStatus | Format-Table -AutoSize
        }
        'init' {
            if ($remaining.Count -gt 0) {
                throw 'Usage: cache init'
            }
            [void](Initialize-CapsulenvToolStorage)
            Get-CapsulenvToolStorageStatus | Format-Table -AutoSize
        }
        'status' {
            if ($remaining.Count -gt 1) {
                throw 'Usage: cache status [project-path]'
            }
            $projectPath = if ($remaining.Count -eq 1) { [string]$remaining[0] } else { '.' }
            Get-CapsulenvProjectCacheStatus -ProjectPath $projectPath | Format-Table -AutoSize
        }
        'link' {
            $allowedFlags = @('--move', '--junction', '--symlink', '--hardlink')
            $unknownFlags = @($remaining | Where-Object { $_ -like '--*' -and $_ -notin $allowedFlags })
            $positionals = @($remaining | Where-Object { $_ -notlike '--*' })
            if ($unknownFlags.Count -gt 0 -or $positionals.Count -lt 1 -or $positionals.Count -gt 2) {
                throw 'Usage: cache link <profile> [project-path] [--move] [--junction|--symlink|--hardlink]'
            }
            $selectedFlags = @($remaining | Where-Object { $_ -in @('--junction', '--symlink', '--hardlink') })
            if ($selectedFlags.Count -gt 1) {
                throw 'Choose only one cache link type.'
            }
            $linkType = if ($selectedFlags.Count -eq 0) {
                $null
            } else {
                switch ($selectedFlags[0]) {
                    '--junction' { 'Junction' }
                    '--symlink' { 'SymbolicLink' }
                    '--hardlink' { 'HardLink' }
                }
            }
            $projectPath = if ($positionals.Count -eq 2) { [string]$positionals[1] } else { '.' }
            $linkParameters = @{
                Profile = [string]$positionals[0]
                ProjectPath = $projectPath
                MoveExisting = $remaining -contains '--move'
            }
            if (-not [string]::IsNullOrWhiteSpace($linkType)) {
                $linkParameters['LinkType'] = $linkType
            }
            New-CapsulenvProjectCacheLink @linkParameters | Format-List
        }
        'unlink' {
            $unknownFlags = @($remaining | Where-Object { $_ -like '--*' -and $_ -ne '--restore' })
            $positionals = @($remaining | Where-Object { $_ -notlike '--*' })
            if ($unknownFlags.Count -gt 0 -or $positionals.Count -lt 1 -or $positionals.Count -gt 2) {
                throw 'Usage: cache unlink <profile> [project-path] [--restore]'
            }
            $projectPath = if ($positionals.Count -eq 2) { [string]$positionals[1] } else { '.' }
            Remove-CapsulenvProjectCacheLink `
                -Profile ([string]$positionals[0]) `
                -ProjectPath $projectPath `
                -Restore:($remaining -contains '--restore') |
                Format-List
        }
        'repair' {
            $unknown = @($remaining | Where-Object { $_ -ne '--strict' })
            if ($unknown.Count -gt 0) {
                throw 'Usage: cache repair [--strict]'
            }
            Repair-CapsulenvProjectCacheLinks -Strict:($remaining -contains '--strict') |
                Format-Table -AutoSize
        }
        default { throw "Unknown cache action: $($Arguments[0])" }
    }
}

function Invoke-CapsulenvToolsCommand {
    param([string[]]$Arguments)

    if ($Arguments.Count -lt 1) {
        throw 'Usage: tools <status|register|unregister|repair> [...]'
    }
    $action = $Arguments[0].ToLowerInvariant()
    $remaining = @($Arguments | Select-Object -Skip 1)

    switch ($action) {
        'status' {
            if ($remaining.Count -gt 0) {
                throw 'Usage: tools status'
            }
            Get-CapsulenvToolRelocationStatus | Format-Table -AutoSize
        }
        'register' {
            if ($remaining.Count -lt 1 -or $remaining.Count -gt 2) {
                throw 'Usage: tools register <uv|pixi> [workspace]'
            }
            $tool = $remaining[0].ToLowerInvariant()
            if ($tool -notin @('uv', 'pixi')) {
                throw 'Usage: tools register <uv|pixi> [workspace]'
            }
            $workspace = if ($remaining.Count -eq 2) { [string]$remaining[1] } else { '.' }
            Register-CapsulenvToolWorkspace -Tool $tool -ProjectPath $workspace | Format-List
        }
        'unregister' {
            if ($remaining.Count -lt 1 -or $remaining.Count -gt 2) {
                throw 'Usage: tools unregister <uv|pixi> [workspace]'
            }
            $tool = $remaining[0].ToLowerInvariant()
            if ($tool -notin @('uv', 'pixi')) {
                throw 'Usage: tools unregister <uv|pixi> [workspace]'
            }
            $workspace = if ($remaining.Count -eq 2) { [string]$remaining[1] } else { '.' }
            Unregister-CapsulenvToolWorkspace -Tool $tool -ProjectPath $workspace | Format-List
        }
        'repair' {
            $allowedFlags = @('--dry-run', '--last', '--strict', '--skip-workspaces', '--include-global')
            $unknownFlags = @($remaining | Where-Object { $_ -like '--*' -and $_ -notin $allowedFlags })
            $positionals = @($remaining | Where-Object { $_ -notlike '--*' })
            if ($unknownFlags.Count -gt 0 -or $positionals.Count -gt 1) {
                throw 'Usage: tools repair [uv|pixi|all] [--dry-run] [--last] [--strict] [--skip-workspaces] [--include-global]'
            }
            $tool = if ($positionals.Count -eq 1) { $positionals[0].ToLowerInvariant() } else { 'all' }
            if ($tool -notin @('uv', 'pixi', 'all')) {
                throw 'Usage: tools repair [uv|pixi|all] [--dry-run] [--last] [--strict] [--skip-workspaces] [--include-global]'
            }
            if ($remaining -contains '--include-global' -and $tool -eq 'uv') {
                throw '--include-global applies to Pixi global tools only.'
            }
            $relocationContext = if ($remaining -contains '--last') {
                Get-CapsulenvLastRelocationContext
            } else {
                Get-CapsulenvRelocationContext
            }
            Invoke-CapsulenvToolRelocationRepair `
                -RelocationContext $relocationContext `
                -Tool $tool `
                -DryRun:($remaining -contains '--dry-run') `
                -Strict:($remaining -contains '--strict') `
                -SkipWorkspaces:($remaining -contains '--skip-workspaces') `
                -IncludePixiGlobal:($remaining -contains '--include-global') |
                Format-Table -AutoSize
        }
        default { throw "Unknown tools action: $($Arguments[0])" }
    }
}
