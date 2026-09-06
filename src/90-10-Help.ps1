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

  capsulenv.cmd app review <app|bucket/app|scoop/app|scoop:user/app|scoop:global/app> [--raw|--json]
      Review the resolved dependency DAG and propagate every direct blocker to
      its ancestors with auditable root-to-blocker paths. Upstream-owned update
      reviews also compare the installed-old and current-bucket-new DAG/effects.
      --raw prints every source manifest in the resolved DAG; --json exposes the
      graph, effect delta, lifecycle surface and explicit next action.

  capsulenv.cmd app install <app|bucket/app> [--allow-trusted]
      Install a PortableSafe plan with the Capsulenv executor. --allow-trusted
      explicitly delegates the requested package to unmodified upstream Scoop;
      arbitrary lifecycle code and host mutation are then outside PortableSafe.

  capsulenv.cmd app update <app|bucket/app|capsule/app|scoop/app> [--allow-trusted] [--local]
      Refresh Scoop/bucket metadata, then update an installed app without changing
      its provider. capsule/<app> remains Capsulenv-owned PortableSafe; scoop/<app>
      requires --allow-trusted and uses unmodified upstream Scoop. Use scoop:user/<app>
      or scoop:global/<app> only when both upstream Scoop roots contain the same name.
      --local skips the metadata refresh and uses the current local bucket snapshot.

  capsulenv.cmd app update --all [--local]
      Update all Capsulenv-owned PortableSafe packages. This deliberately does not
      opt every upstream Scoop install into TrustedExecution.

  capsulenv.cmd app list [app]
      List launchable shortcut declarations from Capsulenv-owned packages and
      legacy/upstream Scoop installs.

  capsulenv.cmd app run <app> ["shortcut name"] [-- runtime arguments...]
      Launch through the unified runtime selector. Use capsule/<app> for a
      Capsulenv-owned package or scoop/<app> for an upstream Scoop package.
      Unscoped names prefer Capsulenv-owned PortableSafe packages; Scoop user/global
      scope is a provider detail and is explicit only when disambiguation is needed.

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
      Capsulenv-owned PortableSafe package or scoop/<app> for an upstream Scoop
      install. scoop:user/<app> / scoop:global/<app> are disambiguation forms.
      A matching Browsers entry describes only
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
