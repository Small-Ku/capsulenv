function Show-CapsulenvHelp {
    [CmdletBinding()]
    param([string]$Topic)

    $topicName = if ([string]::IsNullOrWhiteSpace($Topic)) { '' } else { $Topic.ToLowerInvariant() }
    switch ($topicName) {
        '' {
@'
capsulenv — portable Windows development environment

Getting started
  capsulenv.cmd
  capsulenv.cmd shell
      Open the capsule shell. No separate init step is required.

Daily commands
  capsulenv.cmd run <command> [arguments...]
  capsulenv.cmd app list [app]
  capsulenv.cmd app run <app> ["shortcut name"] [-- runtime arguments...]
  capsulenv.cmd user-shell [--force]
  capsulenv.cmd status
  capsulenv.cmd version
  capsulenv.cmd eject [--force]
  capsulenv.cmd doctor

Setup and maintenance
  capsulenv.cmd bootstrap
  capsulenv.cmd seed ...
  capsulenv.cmd cache ...
  capsulenv.cmd tools ...
  capsulenv.cmd bitwarden ...
  capsulenv.cmd rehydrate ...

Use "capsulenv.cmd help <topic>" for details.
Topics: app, browser, user, eject, seed, cache, tools, repair, offline, bitwarden
'@ | Write-Host
        }
        'app' {
@'
app commands
  capsulenv.cmd app list [app]
      List launchable shortcuts declared by installed Scoop manifests.

  capsulenv.cmd app run <app> ["shortcut name"] [-- runtime arguments...]
      Launch a shortcut without creating a Start Menu .lnk. Use user/<app> or
      global/<app> when both scopes contain the same app.
'@ | Write-Host
        }
        'browser' {
@'
browser commands
  capsulenv.cmd firefox [--host] [browser arguments...]
  capsulenv.cmd zen [--host] [browser arguments...]
  capsulenv.cmd librewolf [--host] [browser arguments...]

      By default the browser executable and profile both come from capsule
      Scoop state. --host is explicit and uses only the same Gecko product's
      machine executable with the capsule Scoop-persisted profile.
'@ | Write-Host
        }
        'user' {
@'
user integration commands
  capsulenv.cmd user-shell [--force]
      Take over/synchronize current-user integration and open a shell.

  capsulenv.cmd install-user [--force]
  capsulenv.cmd enable-user [--force]
      Install this capsule as the current Windows user's Scoop environment.
      enable-user is retained as a compatibility alias. If
      UserIntegration.DefaultBrowser is configured, also register that capsule
      Gecko browser and open its Default Apps page when confirmation is needed.

  capsulenv.cmd restore-user
      Restore Capsulenv-owned current-user settings and return to ShellOnly.
'@ | Write-Host
        }
        'eject' {
@'
eject
  capsulenv.cmd eject [--force]
      Report dirty workspace repositories, stop capsule-owned processes, record
      eject state, and remove host-local scratch. If processes remain, eject is
      blocked unless --force is used.

      Eject never changes install mode. In User mode, run restore-user before
      removing the capsule from a host that will continue to be used.
'@ | Write-Host
        }
        'seed' {
@'
seed commands
  capsulenv.cmd seed powershell [--force]
      Copy CurrentUser PowerShell 7 profiles into Scoop pwsh's persisted profile
      files. Scoop pwsh must already be installed in the capsule.

  capsulenv.cmd seed git [--force] [--include-sensitive]
      Flatten host global Git config into tool-data/git/config. Credential and
      extraHeader entries are excluded unless --include-sensitive is explicit.

  capsulenv.cmd seed scoop [--force] [--apply]
      Capture a foreign Scoop apps+buckets inventory in
      tool-data/scoop/Scoopfile.json. --apply installs it according to the
      current Capsulenv ownership mode.

  capsulenv.cmd seed weasel [backup] [--force]
      Cold-copy the registry-confirmed host Weasel Rime user directory into
      tool-data/weasel. Existing portable backup requires --force.

  capsulenv.cmd seed weasel restore
      Restore that portable Rime tree only when this machine has a confirmed
      Weasel installation. The current host tree is backed up first.
'@ | Write-Host
        }
        'cache' {
@'
cache commands
  capsulenv.cmd cache paths
  capsulenv.cmd cache init
  capsulenv.cmd cache status [project-path]
  capsulenv.cmd cache link <profile> [project-path] [--move]
      [--junction|--symlink|--hardlink]
  capsulenv.cmd cache unlink <profile> [project-path] [--restore]
  capsulenv.cmd cache repair [--strict]
'@ | Write-Host
        }
        'tools' {
@'
tool relocation commands
  capsulenv.cmd tools status
  capsulenv.cmd tools register <uv|pixi> [workspace]
  capsulenv.cmd tools unregister <uv|pixi> [workspace]
  capsulenv.cmd tools repair [uv|pixi|all] [--dry-run] [--last] [--strict]
      [--skip-workspaces] [--include-global]
'@ | Write-Host
        }
        'repair' {
@'
repair commands
  capsulenv.cmd rehydrate [--skip-hooks] [--skip-persist-repairs]
      [--skip-tool-repairs] [--strict-tool-repairs]
      Repair relocation according to install mode. Normal shell startup invokes
      relocation repair automatically when required.

  capsulenv.cmd init [...]
      Compatibility/advanced alias for explicit full initialization.

  capsulenv.cmd repair-persist [app...] [--dry-run] [--last]
  capsulenv.cmd hooks <pre_install|post_install> <app> [app...]
  capsulenv.cmd reset [app...]
'@ | Write-Host
        }
        'offline' {
@'
offline commands
  capsulenv.cmd offline status
  capsulenv.cmd offline prefetch [installed-app ...]
  capsulenv.cmd drift
      Check local/offline readiness, populate Scoop's portable download cache,
      or compare installed versions with local bucket manifests.
'@ | Write-Host
        }
        'bitwarden' {
@'
Bitwarden SSH Agent commands
  capsulenv.cmd bitwarden setup [always|never|remember-until-lock]
  capsulenv.cmd bitwarden status
  capsulenv.cmd bitwarden restore
  capsulenv.cmd bitwarden start
  capsulenv.cmd bitwarden agent-test

Advanced: disable-windows-agent, restore-windows-agent, configure-git, restore-git.
ShellOnly keeps Git/service changes process-only; User mode may own reversible
current-user integration.
'@ | Write-Host
        }
        default {
            throw "Unknown help topic: $Topic. Run capsulenv.cmd help for available topics."
        }
    }
}

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


function Invoke-CapsulenvOfflineCommand {
    param([string[]]$Arguments)

    $action = if ($Arguments.Count -gt 0) { $Arguments[0].ToLowerInvariant() } else { 'status' }
    $remaining = @($Arguments | Select-Object -Skip 1)
    switch ($action) {
        'status' {
            if ($remaining.Count -gt 0) { throw 'Usage: offline status' }
            Get-CapsulenvOfflineReadiness | Format-List
        }
        'prefetch' {
            Invoke-CapsulenvOfflinePrefetch -Apps $remaining | Format-List
        }
        default { throw 'Usage: offline <status|prefetch> [installed-app ...]' }
    }
}

function Invoke-CapsulenvSeedCommand {
    param([string[]]$Arguments)

    if ($Arguments.Count -lt 1) {
        throw 'Usage: seed <powershell|git|scoop|weasel> [...]'
    }
    $action = $Arguments[0].ToLowerInvariant()
    $remaining = @($Arguments | Select-Object -Skip 1)

    switch ($action) {
        'powershell' {
            $unknown = @($remaining | Where-Object { $_ -ne '--force' })
            if ($unknown.Count -gt 0 -or @($remaining | Where-Object { $_ -eq '--force' }).Count -gt 1) {
                throw 'Usage: seed powershell [--force]'
            }
            Seed-CapsulenvPowerShellProfiles -Force:($remaining -contains '--force') | Format-Table -AutoSize
        }
        'git' {
            $allowed = @('--force', '--include-sensitive')
            $unknown = @($remaining | Where-Object { $_ -notin $allowed })
            if ($unknown.Count -gt 0) {
                throw 'Usage: seed git [--force] [--include-sensitive]'
            }
            Seed-CapsulenvGitConfig `
                -Force:($remaining -contains '--force') `
                -IncludeSensitive:($remaining -contains '--include-sensitive') |
                Format-List
        }
        'scoop' {
            $allowed = @('--force', '--apply')
            $unknown = @($remaining | Where-Object { $_ -notin $allowed })
            if ($unknown.Count -gt 0) {
                throw 'Usage: seed scoop [--force] [--apply]'
            }
            Seed-CapsulenvScoopInventory `
                -Force:($remaining -contains '--force') `
                -Apply:($remaining -contains '--apply') |
                Format-List
        }
        'weasel' {
            $operation = if ($remaining.Count -gt 0 -and $remaining[0] -notlike '--*') {
                [string]$remaining[0].ToLowerInvariant()
            } else {
                'backup'
            }
            $options = @($remaining)
            if ($remaining.Count -gt 0 -and $remaining[0] -notlike '--*') {
                $options = @($remaining | Select-Object -Skip 1)
            }
            switch ($operation) {
                'backup' {
                    $unknown = @($options | Where-Object { $_ -ne '--force' })
                    if ($unknown.Count -gt 0 -or @($options | Where-Object { $_ -eq '--force' }).Count -gt 1) {
                        throw 'Usage: seed weasel [backup] [--force]'
                    }
                    Save-CapsulenvWeaselSeed -Force:($options -contains '--force') | Format-List
                }
                'restore' {
                    if ($options.Count -gt 0) {
                        throw 'Usage: seed weasel restore'
                    }
                    Restore-CapsulenvWeaselSeed | Format-List
                }
                default { throw "Unknown Weasel seed action: $operation. Use backup or restore." }
            }
        }
        default { throw "Unknown seed action: $($Arguments[0])" }
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

function Invoke-CapsulenvAppCommand {
    [CmdletBinding()]
    param([string[]]$Arguments)

    if ($Arguments.Count -lt 1) {
        throw 'Usage: app <list|run> [...]'
    }

    $action = $Arguments[0].ToLowerInvariant()
    $remaining = @($Arguments | Select-Object -Skip 1)
    switch ($action) {
        'list' {
            if ($remaining.Count -gt 1) {
                throw 'Usage: app list [app]'
            }
            $items = if ($remaining.Count -eq 1) {
                @(Get-CapsulenvScoopAppShortcuts -App ([string]$remaining[0]))
            } else {
                @(Get-CapsulenvScoopShortcutCatalog)
            }
            $items | Select-Object Scope, App, Name, Target, Arguments, Architecture | Format-Table -AutoSize
        }
        'run' {
            if ($remaining.Count -lt 1) {
                throw 'Usage: app run <app> ["shortcut name"] [-- runtime arguments...]'
            }
            $selector = [string]$remaining[0]
            $tail = @($remaining | Select-Object -Skip 1)
            $separatorIndex = -1
            for ($index = 0; $index -lt $tail.Count; $index++) {
                if ([string]$tail[$index] -eq '--') {
                    $separatorIndex = $index
                    break
                }
            }

            $before = @(
                if ($separatorIndex -ge 0) {
                    if ($separatorIndex -gt 0) { $tail[0..($separatorIndex - 1)] }
                } else {
                    $tail
                }
            )
            if ($before.Count -gt 1) {
                throw 'Usage: app run <app> ["shortcut name"] [-- runtime arguments...]'
            }
            $runtime = @(
                if ($separatorIndex -ge 0 -and $separatorIndex -lt ($tail.Count - 1)) {
                    $tail[($separatorIndex + 1)..($tail.Count - 1)]
                }
            )
            $shortcutName = if ($before.Count -eq 1) { [string]$before[0] } else { $null }
            [void](Start-CapsulenvScoopShortcut -App $selector -ShortcutName $shortcutName -Arguments $runtime)
        }
        default { throw "Unknown app action: $action. Use list or run." }
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
    $remaining = @($Arguments | Select-Object -Skip 1)

    switch ($command) {
        'shell' { Invoke-CapsulenvChildShell }
        'user-shell' {
            $unknown = @($remaining | Where-Object { $_ -ne '--force' })
            if ($unknown.Count -gt 0 -or @($remaining | Where-Object { $_ -eq '--force' }).Count -gt 1) {
                throw 'Usage: user-shell [--force]'
            }
            Enter-CapsulenvUserShell -Force:($remaining -contains '--force')
        }
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
            $externalArguments = @($remaining | Select-Object -Skip 1)
            Invoke-CapsulenvExternalCommand -Command $remaining[0] -Arguments $externalArguments
        }
        'app' { Invoke-CapsulenvAppCommand -Arguments $remaining }
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
        'eject' {
            $unknown = @($remaining | Where-Object { $_ -ne '--force' })
            if ($unknown.Count -gt 0 -or @($remaining | Where-Object { $_ -eq '--force' }).Count -gt 1) {
                throw 'Usage: eject [--force]'
            }
            Invoke-CapsulenvEject -Force:($remaining -contains '--force') | Format-List
        }
        'offline' { Invoke-CapsulenvOfflineCommand -Arguments $remaining }
        'drift' {
            if ($remaining.Count -gt 0) { throw 'Usage: drift' }
            Get-CapsulenvVersionDrift | Format-Table -AutoSize
        }
        'status' {
            if ($remaining.Count -gt 0) { throw 'Usage: status' }
            Get-CapsulenvStatus | Format-List
        }
        'version' {
            if ($remaining.Count -gt 0) { throw 'Usage: version' }
            Get-CapsulenvRuntimeVersion | Write-Output
        }
        'doctor' { Invoke-CapsulenvDoctor | Out-Null }
        'seed' { Invoke-CapsulenvSeedCommand -Arguments $remaining }
        'cache' { Invoke-CapsulenvCacheCommand -Arguments $remaining }
        'tools' { Invoke-CapsulenvToolsCommand -Arguments $remaining }
        'firefox' { Invoke-CapsulenvBrowserCommand -Browser Firefox -Arguments $remaining }
        'zen' { Invoke-CapsulenvBrowserCommand -Browser Zen -Arguments $remaining }
        'librewolf' { Invoke-CapsulenvBrowserCommand -Browser LibreWolf -Arguments $remaining }
        'bitwarden' { Invoke-CapsulenvBitwardenCommand -Arguments $remaining }
        'help' {
            $helpArguments = @($remaining)
            if ($helpArguments.Count -gt 1) { throw 'Usage: help [topic]' }
            $topic = if ($helpArguments.Count -eq 1) { [string]$helpArguments[0] } else { $null }
            Show-CapsulenvHelp -Topic $topic
        }
        '--help' { Show-CapsulenvHelp }
        '-h' { Show-CapsulenvHelp }
        default { throw "Unknown capsulenv command: $command. Run capsulenv.cmd help." }
    }
}

Set-Alias -Name cenv -Value Invoke-Capsulenv
##MOD_EXEC## Export-ModuleMember -Function Invoke-Capsulenv
##MOD_EXEC## Export-ModuleMember -Alias cenv
