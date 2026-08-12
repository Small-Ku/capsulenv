function Show-CapsulenvHelp {
    [CmdletBinding()]
    param()

    @'
capsulenv commands

  capsulenv.cmd shell
      Open a child PowerShell with the shell-only portable Scoop environment active.
      Fresh installs bootstrap Scoop/Main inside the capsule; host Scoop settings
      and user environment variables are not adopted or persisted.

  capsulenv.cmd bootstrap
      Bootstrap missing Scoop/Main repositories in the capsule. Git uses a
      shallow single-branch clone; archive download is the no-Git fallback.

  capsulenv.cmd run <command> [arguments...]
      Run one command inside the portable environment.

  capsulenv.cmd init [--skip-hooks] [--skip-persist-repairs] [--skip-tool-repairs] [--strict-tool-repairs]
  capsulenv.cmd rehydrate [--skip-hooks] [--skip-persist-repairs] [--skip-tool-repairs] [--strict-tool-repairs]
      Run native `scoop reset *`, replay configured safe lifecycle hooks,
      repair allow-listed persisted text settings, then repair tool-native
      launchers and registered environments after relocation.

  capsulenv.cmd repair-persist [app...] [--dry-run] [--last]
      Repair only explicitly configured persisted files. --last reuses the
      most recently completed OldRoot -> NewRoot relocation context.

  capsulenv.cmd hooks <pre_install|post_install> <app> [app...]
      Explicitly replay one installed-manifest hook. pre_install is opt-in
      because many manifests implement it as a one-shot transformation.

  capsulenv.cmd reset [app...]
      Run native Scoop reset without lifecycle replay. Defaults to all apps.

  capsulenv.cmd install-user [--force]
  capsulenv.cmd enable-user [--force]
  capsulenv.cmd restore-user
      Install this capsule as the current Windows user's Scoop environment, or
      restore the exact previous user environment and return to shell-only mode.
      enable-user is retained as a compatibility alias for install-user.


  capsulenv.cmd cache paths
  capsulenv.cmd cache init
  capsulenv.cmd cache status [project-path]
      Show or create portable tool cache/home directories.

  capsulenv.cmd cache link <profile> [project-path] [--move]
      [--junction|--symlink|--hardlink]
      Link a project-local build/cache path to capsule storage. Directory
      profiles default to junctions; hardlink is valid for file profiles only.

  capsulenv.cmd cache unlink <profile> [project-path] [--restore]
      Remove a managed project link. --restore moves stored data back.

  capsulenv.cmd cache repair [--strict]
      Recreate registered junctions/symlinks whose absolute targets became
      stale after moving the complete capsule.


  capsulenv.cmd tools status
  capsulenv.cmd tools register <uv|pixi> [workspace]
  capsulenv.cmd tools unregister <uv|pixi> [workspace]
      Inspect or explicitly register lock-backed workspaces for native repair.

  capsulenv.cmd tools repair [uv|pixi|all] [--dry-run] [--last] [--strict]
      [--skip-workspaces] [--include-global]
      Rebuild uv-managed installations and registered uv/Pixi workspace
      environments. Pixi global sync is opt-in because its manifest may contain
      version ranges that are re-resolved during sync.

  capsulenv.cmd doctor

  capsulenv.cmd firefox [arguments...]
  capsulenv.cmd zen [arguments...]
      Start the Scoop-installed browser. Its manifest/persist store owns the profile.

  capsulenv.cmd bitwarden setup [always|never|remember-until-lock]
      Enable the Bitwarden Desktop SSH Agent setting, configure Git, and
      disable the Windows ssh-agent service when running elevated.

  capsulenv.cmd bitwarden status
  capsulenv.cmd bitwarden restore
      Inspect or precisely restore the settings changed by setup.

  capsulenv.cmd bitwarden start
  capsulenv.cmd bitwarden agent-test
  capsulenv.cmd bitwarden disable-windows-agent
  capsulenv.cmd bitwarden restore-windows-agent
  capsulenv.cmd bitwarden configure-git
  capsulenv.cmd bitwarden restore-git
'@ | Write-Host
}


function Invoke-CapsulenvCacheCommand {
    param([string[]]$Arguments)

    if ($Arguments.Count -lt 1) {
        throw 'Usage: cache <paths|init|status|link|unlink|repair> [...]'
    }

    $action = $Arguments[0].ToLowerInvariant()
    $remaining = if ($Arguments.Count -gt 1) { @($Arguments[1..($Arguments.Count - 1)]) } else { @() }
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
    $remaining = if ($Arguments.Count -gt 1) { @($Arguments[1..($Arguments.Count - 1)]) } else { @() }

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

function Invoke-CapsulenvBitwardenCommand {
    param([string[]]$Arguments)

    if ($Arguments.Count -lt 1) {
        throw 'Usage: bitwarden <setup|status|restore|start|agent-test|disable-windows-agent|restore-windows-agent|configure-git|restore-git>'
    }

    $action = $Arguments[0].ToLowerInvariant()
    $remaining = if ($Arguments.Count -gt 1) {
        @($Arguments[1..($Arguments.Count - 1)])
    } else {
        @()
    }

    switch ($action) {
        'setup' {
            $allowedFlags = @('--skip-service', '--skip-git', '--no-start')
            $unknownFlags = @($remaining | Where-Object { $_ -like '--*' -and $_ -notin $allowedFlags })
            $positionals = @($remaining | Where-Object { $_ -notlike '--*' })
            if ($unknownFlags.Count -gt 0 -or $positionals.Count -gt 1) {
                throw 'Usage: bitwarden setup [always|never|remember-until-lock] [--skip-service] [--skip-git] [--no-start]'
            }
            $authorization = if ($positionals.Count -eq 1) { [string]$positionals[0] } else { $null }
            Invoke-CapsulenvBitwardenSshAgentSetup `
                -Authorization $authorization `
                -SkipWindowsService:($remaining -contains '--skip-service') `
                -SkipGit:($remaining -contains '--skip-git') `
                -NoStart:($remaining -contains '--no-start') |
                Format-List
        }
        'status' {
            if ($remaining.Count -gt 0) {
                throw 'Usage: bitwarden status'
            }
            Get-CapsulenvBitwardenSshAgentStatus | Format-List
        }
        'restore' {
            $unknown = @($remaining | Where-Object { $_ -ne '--no-start' })
            if ($unknown.Count -gt 0) {
                throw 'Usage: bitwarden restore [--no-start]'
            }
            Restore-CapsulenvBitwardenSshAgentSetup `
                -NoStart:($remaining -contains '--no-start') |
                Format-List
        }
        'start' { Start-CapsulenvBitwarden }
        'agent-test' { Test-CapsulenvBitwardenSshAgent | Format-List }
        'disable-windows-agent' { Disable-CapsulenvWindowsSshAgent }
        'restore-windows-agent' { Restore-CapsulenvWindowsSshAgent }
        'configure-git' { Set-CapsulenvGitOpenSsh }
        'restore-git' { Restore-CapsulenvGitOpenSsh }
        default { throw "Unknown Bitwarden action: $($Arguments[0])" }
    }
}

function Invoke-Capsulenv {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments = @()
    )

    [void](Initialize-CapsulenvContext -Root $env:CAPSULENV_ROOT)
    $command = if ($Arguments.Count -gt 0) { $Arguments[0].ToLowerInvariant() } else { 'shell' }
    $remaining = if ($Arguments.Count -gt 1) { @($Arguments[1..($Arguments.Count - 1)]) } else { @() }

    switch ($command) {
        'shell' { Invoke-CapsulenvChildShell }
        'bootstrap' {
            if ($remaining.Count -gt 0) {
                throw 'Usage: bootstrap'
            }
            [void](Set-CapsulenvSessionEnvironment)
            Initialize-CapsulenvScoopBootstrap | Format-List
        }
        'run' {
            if ($remaining.Count -lt 1) {
                throw 'Usage: run <command> [arguments...]'
            }
            $externalArguments = if ($remaining.Count -gt 1) { @($remaining[1..($remaining.Count - 1)]) } else { @() }
            Invoke-CapsulenvExternalCommand -Command $remaining[0] -Arguments $externalArguments
        }
        'init' {
            $allowed = @('--skip-hooks', '--skip-persist-repairs', '--skip-tool-repairs', '--strict-tool-repairs')
            $unknown = @($remaining | Where-Object { $_ -notin $allowed })
            if ($unknown.Count -gt 0) {
                throw 'Usage: init [--skip-hooks] [--skip-persist-repairs] [--skip-tool-repairs] [--strict-tool-repairs]'
            }
            Initialize-Capsulenv `
                -SkipHooks:($remaining -contains '--skip-hooks') `
                -SkipPersistRepairs:($remaining -contains '--skip-persist-repairs') `
                -SkipToolRepairs:($remaining -contains '--skip-tool-repairs') `
                -StrictToolRepairs:($remaining -contains '--strict-tool-repairs')
        }
        'rehydrate' {
            $allowed = @('--skip-hooks', '--skip-persist-repairs', '--skip-tool-repairs', '--strict-tool-repairs')
            $unknown = @($remaining | Where-Object { $_ -notin $allowed })
            if ($unknown.Count -gt 0) {
                throw 'Usage: rehydrate [--skip-hooks] [--skip-persist-repairs] [--skip-tool-repairs] [--strict-tool-repairs]'
            }
            Invoke-CapsulenvScoopRehydrate `
                -SkipHooks:($remaining -contains '--skip-hooks') `
                -SkipPersistRepairs:($remaining -contains '--skip-persist-repairs') `
                -SkipToolRepairs:($remaining -contains '--skip-tool-repairs') `
                -StrictToolRepairs:($remaining -contains '--strict-tool-repairs')
        }
        'repair-persist' {
            $allowedFlags = @('--dry-run', '--last')
            $unknownFlags = @($remaining | Where-Object { $_ -like '--*' -and $_ -notin $allowedFlags })
            if ($unknownFlags.Count -gt 0) {
                throw 'Usage: repair-persist [app...] [--dry-run] [--last]'
            }
            $apps = @($remaining | Where-Object { $_ -notlike '--*' })
            $relocationContext = if ($remaining -contains '--last') {
                Get-CapsulenvLastRelocationContext
            } else {
                Get-CapsulenvRelocationContext
            }
            Invoke-CapsulenvPersistRelocationRepair `
                -RelocationContext $relocationContext `
                -Apps $apps `
                -DryRun:($remaining -contains '--dry-run') |
                Format-List
        }
        'hooks' {
            if ($remaining.Count -lt 2) {
                throw 'Usage: hooks <pre_install|post_install> <app> [app...]'
            }
            $apps = @($remaining[1..($remaining.Count - 1)])
            Invoke-CapsulenvScoopHookReplay -Hook $remaining[0] -Apps $apps
        }
        'reset' {
            [void](Set-CapsulenvSessionEnvironment)
            $apps = if ($remaining.Count -gt 0) { $remaining } else { @('*') }
            [void](Reset-CapsulenvScoop -Apps $apps)
        }
        'reset-shims' {
            [void](Set-CapsulenvSessionEnvironment)
            [void](Reset-CapsulenvScoop)
        }
        'install-user' {
            $unknown = @($remaining | Where-Object { $_ -ne '--force' })
            if ($unknown.Count -gt 0 -or @($remaining | Where-Object { $_ -eq '--force' }).Count -gt 1) {
                throw 'Usage: install-user [--force]'
            }
            Install-CapsulenvUserEnvironment -Force:($remaining -contains '--force')
        }
        'enable-user' {
            $unknown = @($remaining | Where-Object { $_ -ne '--force' })
            if ($unknown.Count -gt 0 -or @($remaining | Where-Object { $_ -eq '--force' }).Count -gt 1) {
                throw 'Usage: enable-user [--force]'
            }
            Install-CapsulenvUserEnvironment -Force:($remaining -contains '--force')
        }
        'restore-user' {
            if ($remaining.Count -gt 0) {
                throw 'Usage: restore-user'
            }
            Restore-CapsulenvUserEnvironment
        }
        'doctor' { Invoke-CapsulenvDoctor | Out-Null }
        'cache' { Invoke-CapsulenvCacheCommand -Arguments $remaining }
        'tools' { Invoke-CapsulenvToolsCommand -Arguments $remaining }
        'firefox' { Start-CapsulenvBrowser -Browser Firefox -Arguments $remaining }
        'zen' { Start-CapsulenvBrowser -Browser Zen -Arguments $remaining }
        'bitwarden' { Invoke-CapsulenvBitwardenCommand -Arguments $remaining }
        'help' { Show-CapsulenvHelp }
        '--help' { Show-CapsulenvHelp }
        '-h' { Show-CapsulenvHelp }
        default { throw "Unknown capsulenv command: $command. Run capsulenv.cmd help." }
    }
}

Set-Alias -Name cenv -Value Invoke-Capsulenv
##MOD_EXEC## Export-ModuleMember -Function Invoke-Capsulenv
##MOD_EXEC## Export-ModuleMember -Alias cenv
