# Root discovery keeps the stable 'help <topic>' entrypoint and states 'No separate init step is required'; an optional action adds focused help.
function Show-CapsulenvHelp {
    [CmdletBinding()]
    param(
        [string]$Topic,
        [string]$Action
    )

    $topicName = if ([string]::IsNullOrWhiteSpace($Topic)) { '' } else { $Topic.ToLowerInvariant() }
    if (-not [string]::IsNullOrWhiteSpace($Action)) {
        if (Write-CapsulenvCliActionHelp -Group $topicName -Action $Action) { return }
        throw (New-CapsulenvCliUnknownActionError -Group $topicName -Action $Action -Id 'Capsulenv.Cli.UnknownHelpAction')
    }
    switch ($topicName) {
        '' {
            Write-CapsulenvCliOverview
        }
        'app' {
@'
app commands
  capsulenv.cmd app plan <app|bucket/app> [--json]
      Resolve dependencies and classify manifest semantics without changing the
      capsule. PortableSafe plans contain only the bounded declarative subset.

  capsulenv.cmd app review <app|bucket/app|user/app|global/app> [--raw|--json]
      Review the resolved dependency DAG and propagate every direct blocker to
      its ancestors with auditable root-to-blocker paths. Upstream-owned update
      reviews also compare the installed-old and current-bucket-new DAG/effects.
      --raw prints every source manifest in the resolved DAG; --json exposes the
      graph, effect delta, lifecycle surface and explicit next action.

  capsulenv.cmd app install <app|bucket/app> [--allow-trusted]
      Install a PortableSafe plan with the Capsulenv executor. --allow-trusted
      explicitly delegates the requested package to unmodified upstream Scoop;
      arbitrary lifecycle code and host mutation are then outside PortableSafe.

  capsulenv.cmd app update <app|bucket/app|scope/app> [--allow-trusted] [--local]
      Refresh Scoop/bucket metadata, then update an installed app without changing
      its owner. capsule/<app> remains Capsulenv-owned PortableSafe; user/<app>
      and global/<app> require --allow-trusted and use unmodified upstream Scoop.
      --local skips the metadata refresh and uses the current local bucket snapshot.

  capsulenv.cmd app update --all [--local]
      Update all Capsulenv-owned PortableSafe packages. This deliberately does not
      opt every upstream Scoop install into TrustedExecution.

  capsulenv.cmd app list [app]
      List launchable shortcut declarations from Capsulenv-owned packages and
      legacy/upstream Scoop installs.

  capsulenv.cmd app run <app> ["shortcut name"] [-- runtime arguments...]
      Launch through the unified runtime selector. Use capsule/<app>, user/<app>
      or global/<app> when an explicit provider/scope is required. Unscoped names
      prefer Capsulenv-owned PortableSafe packages.

  scoop ...
      Direct Scoop commands are never intercepted. They use upstream Scoop
      semantics and are an explicit TrustedExecution boundary.
'@ | Write-Host
        }
        'bucket' {
@'
bucket commands
  capsulenv.cmd bucket list
  capsulenv.cmd bucket known
  capsulenv.cmd bucket add <name> [repository]
  capsulenv.cmd bucket remove <name>
  capsulenv.cmd bucket update

      Bucket operations are a thin facade over the capsule's unmodified upstream
      Scoop. add/remove change only package metadata repositories. update invokes
      stock scoop update to refresh Scoop core and all configured bucket repos;
      it does not update installed apps.
'@ | Write-Host
        }
        'browser' {
@'
browser commands
  capsulenv.cmd browser <app> [--host] [browser arguments...]
  capsulenv.cmd firefox [--host] [browser arguments...]
  capsulenv.cmd zen [--host] [browser arguments...]
  capsulenv.cmd librewolf [--host] [browser arguments...]

      The selector resolves an installed runtime app. Use capsule/<app> for a
      Capsulenv-owned PortableSafe package or user/<app>/global/<app> for an
      upstream Scoop install. A matching Browsers entry describes only
      Gecko-specific details such as the persisted profile path.

      --host is explicit and uses only the configured product's machine
      executable with the selected app's persisted profile. The three
      short commands above remain compatibility aliases for firefox,
      zen-browser, and librewolf.
'@ | Write-Host
        }
        'user' {
@'
user integration commands
  capsulenv.cmd user-shell [--force]
      Explicitly take over/synchronize persistent current-user integration and
      open a User-mode shell. Nested Capsulenv commands inherit User mode.
      A later standalone capsulenv.cmd still defaults to ShellOnly.

  capsulenv.cmd install-user [--force]
  capsulenv.cmd enable-user [--force]
      Synchronize explicit current-user integrations for this capsule.
      PortableSafe Start Menu entries point back through the Capsulenv launcher;
      direct upstream Scoop remains responsible for any integration it creates.
      enable-user is retained as a compatibility alias. If
      UserIntegration.DefaultBrowser is configured, also register that capsule
      Gecko browser and open its Default Apps page when confirmation is needed.

  capsulenv.cmd restore-user
      Restore Capsulenv-owned current-user settings and remove this capsule's
      isolated Start Menu shortcut namespace. Fresh invocations are ShellOnly
      by default even before this persistent takeover is restored.
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
  capsulenv.cmd rehydrate [--skip-persist-repairs]
      [--skip-tool-repairs] [--strict-tool-repairs]
      Repair Capsulenv-owned package projections and bounded legacy Scoop
      current/persist projections after relocation. It never replays manifest
      lifecycle code. Ambiguous legacy state fails closed and must be repaired
      explicitly with upstream Scoop.

  capsulenv.cmd init [...]
      Compatibility/advanced alias for explicit full initialization. The legacy
      --skip-hooks flag is accepted but lifecycle replay no longer exists.

  capsulenv.cmd repair-persist [app...] [--dry-run] [--last]
  capsulenv.cmd reset [app...]
      Reconcile only package/runtime projections; this is not `scoop reset`.
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
        'sing-box' {
@'
sing-box private-network commands
  capsulenv.cmd sing-box status
  capsulenv.cmd sing-box check
  capsulenv.cmd sing-box connect
  capsulenv.cmd sing-box disconnect [--force]

The executable and configuration are resolved from SingBox.App and that
installed Scoop manifest/persist root. Automatic connection only runs when the
selected app is installed and its persisted configuration is non-empty.
'@ | Write-Host
        }
        default {
            if (Write-CapsulenvCliCommandHelp -Command $topicName) { return }
            $remediation = New-Object System.Collections.Generic.List[string]
            $suggestion = Get-CapsulenvCliCommandSuggestion -Command $topicName
            if (-not [string]::IsNullOrWhiteSpace([string]$suggestion)) {
                $remediation.Add(("Did you mean 'capsulenv help {0}'?" -f $suggestion))
            }
            $remediation.Add("Run 'capsulenv help' to see available commands.")
            throw (New-CapsulenvDiagnosticErrorRecord `
                -Id 'Capsulenv.Cli.UnknownHelpTopic' `
                -Message "Unknown help topic '$Topic'." `
                -Category ([System.Management.Automation.ErrorCategory]::InvalidArgument) `
                -TargetObject $Topic `
                -Remediation $remediation.ToArray())
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
    $remaining = @($Arguments | Select-Object -Skip 1)

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

function New-CapsulenvCliUsageError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$Usage,
        [string]$Topic = ''
    )

    $remediation = New-Object System.Collections.Generic.List[string]
    $remediation.Add(('Usage: {0}' -f $Usage))
    if (-not [string]::IsNullOrWhiteSpace($Topic)) {
        $remediation.Add(("Run 'capsulenv help {0}' for details." -f $Topic))
    } else {
        $remediation.Add("Run 'capsulenv help' to see available commands.")
    }
    return New-CapsulenvDiagnosticErrorRecord `
        -Id 'Capsulenv.Cli.Usage' `
        -Message $Message `
        -Category ([System.Management.Automation.ErrorCategory]::InvalidArgument) `
        -Remediation $remediation.ToArray()
}

function New-CapsulenvCliUnknownCommandError {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Command)

    $remediation = New-Object System.Collections.Generic.List[string]
    $suggestion = Get-CapsulenvCliCommandSuggestion -Command $Command
    if (-not [string]::IsNullOrWhiteSpace([string]$suggestion)) {
        $remediation.Add(("Did you mean 'capsulenv {0}'?" -f $suggestion))
    }
    $remediation.Add("Run 'capsulenv help' to see available commands.")
    return New-CapsulenvDiagnosticErrorRecord `
        -Id 'Capsulenv.Cli.UnknownCommand' `
        -Message "Unknown capsulenv command '$Command'." `
        -Category ([System.Management.Automation.ErrorCategory]::InvalidArgument) `
        -TargetObject $Command `
        -Remediation $remediation.ToArray()
}

function Invoke-CapsulenvBucketCommand {
    [CmdletBinding()]
    param([string[]]$Arguments)

    if ($Arguments.Count -lt 1) {
        Show-CapsulenvHelp -Topic bucket
        return
    }

    $action = $Arguments[0].ToLowerInvariant()
    $remaining = @($Arguments | Select-Object -Skip 1)
    if ($action -in @('help', '--help', '-h')) {
        if ($remaining.Count -gt 1) {
            throw (New-CapsulenvCliUsageError -Message 'bucket help accepts at most one action.' -Usage 'capsulenv bucket help [action]' -Topic bucket)
        }
        $helpAction = if ($remaining.Count -eq 1) { [string]$remaining[0] } else { $null }
        Show-CapsulenvHelp -Topic bucket -Action $helpAction
        return
    }
    if ($remaining.Count -eq 1 -and [string]$remaining[0] -in @('--help', '-h')) {
        Show-CapsulenvHelp -Topic bucket -Action $action
        return
    }
    $scoopArguments = $null
    switch ($action) {
        'list' {
            if ($remaining.Count -gt 0) {
                throw (New-CapsulenvCliUsageError -Message 'bucket list does not accept additional arguments.' -Usage 'capsulenv bucket list' -Topic bucket)
            }
            $scoopArguments = @('bucket', 'list')
        }
        'known' {
            if ($remaining.Count -gt 0) {
                throw (New-CapsulenvCliUsageError -Message 'bucket known does not accept additional arguments.' -Usage 'capsulenv bucket known' -Topic bucket)
            }
            $scoopArguments = @('bucket', 'known')
        }
        'add' {
            if ($remaining.Count -lt 1 -or $remaining.Count -gt 2) {
                throw (New-CapsulenvCliUsageError -Message 'bucket add requires a bucket name and optional repository.' -Usage 'capsulenv bucket add <name> [repository]' -Topic bucket)
            }
            $scoopArguments = @('bucket', 'add') + @($remaining)
        }
        { $_ -in @('remove', 'rm') } {
            if ($remaining.Count -ne 1) {
                throw (New-CapsulenvCliUsageError -Message 'bucket remove requires exactly one bucket name.' -Usage 'capsulenv bucket remove <name>' -Topic bucket)
            }
            $scoopArguments = @('bucket', 'rm', [string]$remaining[0])
        }
        'update' {
            if ($remaining.Count -gt 0) {
                throw (New-CapsulenvCliUsageError -Message 'Scoop refreshes configured buckets together; bucket update does not accept a bucket name.' -Usage 'capsulenv bucket update' -Topic bucket)
            }
            $scoopArguments = @('update')
        }
        default {
            throw (New-CapsulenvCliUnknownActionError -Group bucket -Action $action -Id 'Capsulenv.Cli.UnknownBucketAction')
        }
    }

    [void](Set-CapsulenvSessionEnvironment)
    [void](Invoke-CapsulenvScoopCommand -Arguments ([string[]]$scoopArguments))
}

function Update-CapsulenvAppMetadata {
    [CmdletBinding()]
    param()

    [void](Set-CapsulenvSessionEnvironment)
    [void](Invoke-CapsulenvScoopCommand -Arguments @('update'))
}

function Resolve-CapsulenvAppUpdateTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Reference)

    $separator = $Reference.IndexOf('/')
    if ($separator -gt 0) {
        $prefix = $Reference.Substring(0, $separator).ToLowerInvariant()
        if ($prefix -in @('capsule', 'user', 'global')) {
            $installed = Get-CapsulenvInstalledScoopApp -Selector $Reference
            if ([string]$installed.Scope -eq 'Capsule') {
                $state = Get-CapsulenvInstalledPackageState -Name ([string]$installed.Name)
                return [pscustomobject]@{ Scope='Capsule'; Name=[string]$installed.Name; Reference=[string]$state.Reference }
            }
            return [pscustomobject]@{ Scope=[string]$installed.Scope; Name=[string]$installed.Name; Reference=[string]$installed.Selector }
        }

        $parsed = Split-CapsulenvPackageReference -Reference $Reference
        $state = Get-CapsulenvInstalledPackageState -Name ([string]$parsed.Name) -AllowMissing
        if ($null -eq $state) {
            throw (New-CapsulenvDiagnosticErrorRecord `
                -Id 'Capsulenv.Package.NotInstalled' `
                -Message "Package is not installed as a Capsulenv-owned PortableSafe package: $Reference" `
                -Category ([System.Management.Automation.ErrorCategory]::ObjectNotFound) `
                -TargetObject $Reference `
                -Remediation @("Install it first with 'capsulenv app install $Reference'."))
        }
        return [pscustomobject]@{ Scope='Capsule'; Name=[string]$state.Name; Reference=$Reference }
    }

    $match = Get-CapsulenvInstalledScoopApp -Selector $Reference
    if ([string]$match.Scope -eq 'Capsule') {
        $state = Get-CapsulenvInstalledPackageState -Name ([string]$match.Name)
        return [pscustomobject]@{ Scope='Capsule'; Name=[string]$match.Name; Reference=[string]$state.Reference }
    }
    return [pscustomobject]@{ Scope=[string]$match.Scope; Name=[string]$match.Name; Reference=[string]$match.Selector }
}

function Invoke-CapsulenvAppCommand {
    [CmdletBinding()]
    param([string[]]$Arguments)

    if ($Arguments.Count -lt 1) {
        Show-CapsulenvHelp -Topic app
        return
    }

    $action = $Arguments[0].ToLowerInvariant()
    $remaining = @($Arguments | Select-Object -Skip 1)
    if ($action -in @('help', '--help', '-h')) {
        if ($remaining.Count -gt 1) {
            throw (New-CapsulenvCliUsageError -Message 'app help accepts at most one action.' -Usage 'capsulenv app help [action]' -Topic app)
        }
        $helpAction = if ($remaining.Count -eq 1) { [string]$remaining[0] } else { $null }
        Show-CapsulenvHelp -Topic app -Action $helpAction
        return
    }
    if ($remaining.Count -eq 1 -and [string]$remaining[0] -in @('--help', '-h')) {
        Show-CapsulenvHelp -Topic app -Action $action
        return
    }
    switch ($action) {
        'plan' {
            $json = $remaining -contains '--json'
            $unknownFlags = @($remaining | Where-Object { $_ -like '--*' -and $_ -ne '--json' })
            $references = @($remaining | Where-Object { $_ -notlike '--*' })
            if ($unknownFlags.Count -gt 0 -or $references.Count -ne 1) {
                throw (New-CapsulenvCliUsageError -Message 'app plan requires exactly one package reference.' -Usage 'capsulenv app plan <app|bucket/app> [--json]' -Topic app)
            }
            $plan = Get-CapsulenvPackageInstallPlan -Reference ([string]$references[0])
            if ($json) {
                ConvertTo-CapsulenvPackageInstallPlanContract -Plan $plan |
                    ConvertTo-Json -Depth 8 |
                    Write-Output
                break
            }
            $plan.Packages |
                Select-Object Reference, Version, Architecture, Classification,
                    @{ Name = 'Capabilities'; Expression = { @($_.Capabilities) -join ',' } },
                    @{ Name = 'Reasons'; Expression = { @($_.Reasons) -join '; ' } } |
                Format-Table -AutoSize
            if ([string]$plan.Classification -ne 'PortableSafe') {
                Write-CapsulenvMessage -Level Warning -Message "TrustedExecution review is required. Run 'capsulenv app review $([string]$plan.Reference)' to inspect the exact lifecycle surface before allowing upstream Scoop execution."
            }
        }
        'review' {
            $raw = $remaining -contains '--raw'
            $json = $remaining -contains '--json'
            $unknownFlags = @($remaining | Where-Object { $_ -like '--*' -and $_ -notin @('--raw', '--json') })
            $references = @($remaining | Where-Object { $_ -notlike '--*' })
            if ($unknownFlags.Count -gt 0 -or $references.Count -ne 1 -or ($raw -and $json)) {
                throw (New-CapsulenvCliUsageError -Message 'app review requires one package reference and at most one output mode.' -Usage 'capsulenv app review <app|bucket/app|user/app|global/app> [--raw|--json]' -Topic app)
            }
            $review = Get-CapsulenvPackageReviewPlan -Reference ([string]$references[0])
            if ($json) {
                $review | ConvertTo-Json -Depth 12 | Write-Output
                break
            }
            Write-CapsulenvPackageReview -Review $review -Raw:$raw
        }
        'install' {
            $allowTrusted = $remaining -contains '--allow-trusted'
            $unknownFlags = @($remaining | Where-Object { $_ -like '--*' -and $_ -ne '--allow-trusted' })
            $references = @($remaining | Where-Object { $_ -notlike '--*' })
            if ($unknownFlags.Count -gt 0 -or $references.Count -ne 1) {
                throw (New-CapsulenvCliUsageError -Message 'app install requires exactly one package reference.' -Usage 'capsulenv app install <app|bucket/app> [--allow-trusted]' -Topic app)
            }
            $reference = [string]$references[0]
            $plan = Get-CapsulenvPackageInstallPlan -Reference $reference
            if ([string]$plan.Classification -eq 'PortableSafe') {
                Install-CapsulenvPortablePackage -Reference $reference |
                    Select-Object Name, Version, Architecture, Reference, InstallRoot |
                    Format-Table -AutoSize
                break
            }
            if (-not $allowTrusted) {
                $blocked = @($plan.BlockedPackages | ForEach-Object {
                    '{0} [{1}] {2}' -f $_.Reference, $_.Classification, (@($_.Reasons) -join '; ')
                }) -join [Environment]::NewLine
                throw (New-CapsulenvDiagnosticErrorRecord `
                    -Id 'Capsulenv.Package.TrustedExecutionRequired' `
                    -Message "Package requires semantics outside PortableSafe. Review the plan before using TrustedExecution.`n$blocked" `
                    -Category ([System.Management.Automation.ErrorCategory]::PermissionDenied) `
                    -TargetObject $reference `
                    -Context ([ordered]@{ Reference = $reference; BlockedPackages = @($plan.BlockedPackages) }) `
                    -Remediation @(
                        "Run 'capsulenv app review $reference' to inspect lifecycle scripts, complete manifests and review guidance.",
                        "Use 'capsulenv app review $reference --raw' when you need the exact source manifest.",
                        'Use --allow-trusted only if upstream Scoop lifecycle execution is acceptable.'
                    ))
            }

            [void](Set-CapsulenvSessionEnvironment)
            Write-CapsulenvMessage -Level Warning -Message "Delegating '$reference' to unmodified upstream Scoop. Third-party lifecycle code may execute and is outside Capsulenv's PortableSafe guarantees."
            [void](Invoke-CapsulenvScoopCommand -Arguments @('install', $reference))
        }
        'update' {
            $allowTrusted = $remaining -contains '--allow-trusted'
            $localOnly = $remaining -contains '--local'
            $all = $remaining -contains '--all'
            $knownFlags = @('--allow-trusted', '--local', '--all')
            $unknownFlags = @($remaining | Where-Object { $_ -like '--*' -and $_ -notin $knownFlags })
            $references = @($remaining | Where-Object { $_ -notlike '--*' })
            if (
                $unknownFlags.Count -gt 0 -or
                ($all -and $references.Count -gt 0) -or
                (-not $all -and $references.Count -ne 1) -or
                ($all -and $allowTrusted)
            ) {
                throw (New-CapsulenvCliUsageError `
                    -Message 'app update accepts one installed app, or --all for Capsulenv-owned PortableSafe packages.' `
                    -Usage 'capsulenv app update <app|bucket/app|capsule/app|user/app|global/app> [--allow-trusted] [--local] | capsulenv app update --all [--local]' `
                    -Topic app)
            }

            if (-not $localOnly) {
                Update-CapsulenvAppMetadata
            }
            if ($all) {
                $states = @(Get-CapsulenvInstalledPackageStates -Strict | Sort-Object Name)
                foreach ($state in $states) {
                    Update-CapsulenvPortablePackage -Reference ([string]$state.Reference) |
                        Select-Object Name, Version, Architecture, Reference, InstallRoot |
                        Format-Table -AutoSize
                }
                break
            }

            $target = Resolve-CapsulenvAppUpdateTarget -Reference ([string]$references[0])
            if ([string]$target.Scope -eq 'Capsule') {
                Update-CapsulenvPortablePackage -Reference ([string]$target.Reference) |
                    Select-Object Name, Version, Architecture, Reference, InstallRoot |
                    Format-Table -AutoSize
                break
            }
            if (-not $allowTrusted) {
                throw (New-CapsulenvDiagnosticErrorRecord `
                    -Id 'Capsulenv.Package.TrustedUpdateRequired' `
                    -Message "'$($target.Reference)' is owned by upstream Scoop, so its update may execute package lifecycle code." `
                    -Category ([System.Management.Automation.ErrorCategory]::PermissionDenied) `
                    -TargetObject ([string]$target.Reference) `
                    -Remediation @(
                        "Run 'capsulenv app review $($target.Reference)' to inspect the current source manifest and dependency graph that Scoop would use for the update.",
                        "Re-run with --allow-trusted only after that review, or use upstream Scoop directly."
                    ))
            }
            [void](Set-CapsulenvSessionEnvironment)
            Write-CapsulenvMessage -Level Warning -Message "Delegating update of '$($target.Reference)' to unmodified upstream Scoop. Package lifecycle code and host mutation are outside Capsulenv's PortableSafe guarantees."
            $scoopArguments = if ([string]$target.Scope -eq 'Global') {
                @('update', [string]$target.Name, '--global')
            } else {
                @('update', [string]$target.Name)
            }
            [void](Invoke-CapsulenvScoopCommand -Arguments $scoopArguments)
        }
        'list' {
            if ($remaining.Count -gt 1) {
                throw (New-CapsulenvCliUsageError -Message 'app list accepts at most one app selector.' -Usage 'capsulenv app list [app]' -Topic app)
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
                throw (New-CapsulenvCliUsageError -Message 'app run requires an installed app selector.' -Usage 'capsulenv app run <app> ["shortcut name"] [-- runtime arguments...]' -Topic app)
            }
            $selector = [string]$remaining[0]
            $tail = @($remaining | Select-Object -Skip 1)
            $separatorIndex = [Array]::IndexOf([object[]]$tail, '--')
            $before = @(
                if ($separatorIndex -ge 0) {
                    if ($separatorIndex -gt 0) { $tail[0..($separatorIndex - 1)] }
                } else { $tail }
            )
            if ($before.Count -gt 1) {
                throw (New-CapsulenvCliUsageError -Message 'app run accepts at most one shortcut name before --.' -Usage 'capsulenv app run <app> ["shortcut name"] [-- runtime arguments...]' -Topic app)
            }
            $runtime = @(
                if ($separatorIndex -ge 0 -and $separatorIndex -lt ($tail.Count - 1)) {
                    $tail[($separatorIndex + 1)..($tail.Count - 1)]
                }
            )
            $shortcutName = if ($before.Count -eq 1) { [string]$before[0] } else { $null }
            [void](Start-CapsulenvScoopShortcut -App $selector -ShortcutName $shortcutName -Arguments $runtime)
        }
        'exec' {
            if ($remaining.Count -lt 2) {
                throw (New-CapsulenvCliUsageError -Message 'app exec requires a capsule app and bin alias.' -Usage 'capsulenv app exec capsule/<app> <bin> [-- arguments...]' -Topic app)
            }
            $selector = [string]$remaining[0]
            $binName = [string]$remaining[1]
            $tail = @($remaining | Select-Object -Skip 2)
            if ($tail.Count -gt 0 -and [string]$tail[0] -eq '--') {
                $tail = @($tail | Select-Object -Skip 1)
            }
            return Invoke-CapsulenvPackageExecutable -App $selector -BinName $binName -Arguments $tail
        }
        default {
            throw (New-CapsulenvCliUnknownActionError -Group app -Action $action -Id 'Capsulenv.Cli.UnknownAppAction')
        }
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

    $catalogCommand = Get-CapsulenvCliCommandCatalog | Where-Object { [string]$_.Name -eq $command } | Select-Object -First 1
    if ($null -ne $catalogCommand -and $remaining.Count -eq 1 -and [string]$remaining[0] -in @('--help', '-h')) {
        Show-CapsulenvHelp -Topic $command
        return
    }

    $knownGroupActions = @(Get-CapsulenvCliActionCatalog -Group $command)
    if ($knownGroupActions.Count -gt 0 -and $remaining.Count -gt 0) {
        $requestedAction = ([string]$remaining[0]).ToLowerInvariant()
        if ($requestedAction -in @('help', '--help', '-h')) {
            if ($remaining.Count -gt 2) {
                throw (New-CapsulenvCliUsageError -Message ("{0} help accepts at most one action." -f $command) -Usage ("capsulenv {0} help [action]" -f $command) -Topic $command)
            }
            $helpAction = if ($remaining.Count -eq 2) { [string]$remaining[1] } else { $null }
            Show-CapsulenvHelp -Topic $command -Action $helpAction
            return
        }
        if ($remaining.Count -eq 2 -and [string]$remaining[1] -in @('--help', '-h')) {
            Show-CapsulenvHelp -Topic $command -Action $requestedAction
            return
        }
    }

    try {
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
        'bucket' { Invoke-CapsulenvBucketCommand -Arguments $remaining }
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
            throw "capsulenv hooks was removed with the Scoop runtime adapter. Arbitrary manifest lifecycle code belongs to explicit upstream Scoop execution; use 'scoop reset/install/update' only after reviewing that package's semantics."
        }
        'reset' {
            [void](Set-CapsulenvSessionEnvironment)
            $apps = if ($remaining.Count -gt 0) { $remaining } else { @('*') }
            [void](Repair-CapsulenvInstalledAppProjections -Apps $apps)
        }
        'reset-shims' {
            [void](Set-CapsulenvSessionEnvironment)
            [void](Repair-CapsulenvInstalledAppProjections)
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
        'context' {
            if ($remaining.Count -gt 1 -or ($remaining.Count -eq 1 -and [string]$remaining[0] -ne '--json')) {
                throw 'Usage: context [--json]'
            }
            $runtimeContext = Get-CapsulenvRuntimeContext
            if ($remaining -contains '--json') {
                $runtimeContext | ConvertTo-Json -Depth 6 | Write-Output
            } else {
                $runtimeContext | Format-List
            }
        }
        'doctor' { Invoke-CapsulenvDoctor | Out-Null }
        'seed' { Invoke-CapsulenvSeedCommand -Arguments $remaining }
        'cache' { Invoke-CapsulenvCacheCommand -Arguments $remaining }
        'tools' { Invoke-CapsulenvToolsCommand -Arguments $remaining }
        'browser' {
            if ($remaining.Count -lt 1) {
                throw 'Usage: browser <scoop-app> [--host] [browser arguments...]'
            }
            Invoke-CapsulenvBrowserCommand `
                -App ([string]$remaining[0]) `
                -Arguments @($remaining | Select-Object -Skip 1)
        }
        'firefox' { Invoke-CapsulenvBrowserCommand -App firefox -Arguments $remaining }
        'zen' { Invoke-CapsulenvBrowserCommand -App zen-browser -Arguments $remaining }
        'librewolf' { Invoke-CapsulenvBrowserCommand -App librewolf -Arguments $remaining }
        'bitwarden' { Invoke-CapsulenvBitwardenCommand -Arguments $remaining }
        'sing-box' { Invoke-CapsulenvSingBoxCommand -Arguments $remaining }
        'help' {
            $helpArguments = @($remaining)
            if ($helpArguments.Count -gt 2) { throw 'Usage: help [topic] [action]' }
            $topic = if ($helpArguments.Count -ge 1) { [string]$helpArguments[0] } else { $null }
            $action = if ($helpArguments.Count -eq 2) { [string]$helpArguments[1] } else { $null }
            Show-CapsulenvHelp -Topic $topic -Action $action
        }
        '--help' { Show-CapsulenvHelp }
        '-h' { Show-CapsulenvHelp }
        default { throw (New-CapsulenvCliUnknownCommandError -Command $command) }
        }
    } catch {
        $converted = ConvertTo-CapsulenvCliErrorRecord -ErrorRecord $_ -Command $command
        throw $converted
    }
}

Set-Alias -Name cenv -Value Invoke-Capsulenv
##MOD_EXEC## Export-ModuleMember -Function Invoke-Capsulenv
##MOD_EXEC## Export-ModuleMember -Alias cenv
