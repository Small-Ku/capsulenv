# Usage guide

English | [繁體中文](USAGE.zh-TW.md)

This document lists step-by-step instructions by task. For initial setup, see [README](../README.md). For runtime execution rules, see [ARCHITECTURE](ARCHITECTURE.md). For tool storage rules, see [TOOLS](TOOLS.md).

## Command conventions

Run the following commands inside an active Capsulenv PowerShell session. Replace placeholders such as `<app>` with actual names without angle brackets.

When running from an external Command Prompt, replace `capsulenv` with the full path `D:\Portable\capsulenv\capsulenv.cmd`. From an external PowerShell session, run `& 'D:\Portable\capsulenv\capsulenv.cmd' status`.

To query full command parameters:

```powershell
capsulenv help
capsulenv help app update
capsulenv app update --help
```

## Session modes

Use the default ShellOnly shell for everyday work. To apply persistent Windows user integration, run:

```powershell
capsulenv user-shell
```

The new shell and its child processes inherit User mode. To apply persistent integration without opening a new shell, run `capsulenv install-user`.

Run `capsulenv status` to inspect current session mode and persistent User integration. Host backup state does not automatically turn a fresh standalone invocation into User mode.

Before leaving a shared host that remains in use:

1. Save your work.
2. Run `capsulenv restore-user`.
3. Run `capsulenv eject`.
4. Resolve any running processes or uncommitted files reported by the command.

Closing a shell or running `eject` does not automatically revert User integration. Capsulenv reverts only changes for which it has ownership evidence. For session mode rules, see [ARCHITECTURE](ARCHITECTURE.md#shellonly-and-user-session-modes).

## Packages

### Install and review

1. Inspect the package and its dependencies:

   ```powershell
   capsulenv app plan <app>
   ```

2. If all nodes are PortableSafe, install the package:

   ```powershell
   capsulenv app install <app>
   ```

You can specify a source bucket as `<bucket>/<app>`. This specifies an installation source, which differs from installed app selectors.

If a package requires manual review:

```powershell
capsulenv app review <app>
capsulenv app review <app> --raw
```

Inspect blocker paths, sources, and scripts before execution. `--raw` displays all source manifests in the dependency graph; `--json` provides machine-readable output. Review approval does not prove that scripts are safe.

Run the following command only when you accept third-party scripts and host mutations:

```powershell
capsulenv app install <app> --allow-trusted
```

This delegates installation to unmodified upstream Scoop. Running `scoop install <app>` directly shares the same trust boundary. For the PortableSafe subset, see [ARCHITECTURE](ARCHITECTURE.md#package-planner-and-portablesafe-subset). For review UI layout, see [CLI-UX](CLI-UX.md#trusted-package-review).

### Update

Update a single PortableSafe package, or update all Capsulenv packages:

```powershell
capsulenv app update capsule/<app>
capsulenv app update --all
```

The command updates Scoop and bucket metadata by default. Add `--local` to use existing local metadata. `--all` updates only Capsulenv-owned PortableSafe packages.

Before updating an upstream Scoop package, update metadata and review changes:

```powershell
capsulenv bucket update
capsulenv app review scoop/<app>
```

After accepting the changes, run update with the same local metadata:

```powershell
capsulenv app update scoop/<app> --allow-trusted --local
```

Review compares installed manifests with current bucket manifests across dependencies and effects. Resolve any conservative warnings before proceeding.

### Buckets

```powershell
capsulenv bucket list
capsulenv bucket known
capsulenv bucket add <name> <repository>
capsulenv bucket remove <name>
capsulenv bucket update
```

These commands use upstream Scoop to manage bucket metadata. `bucket update` updates Scoop core and bucket repositories; it does not update installed packages.

## Installed apps

Run `capsulenv app list` to inspect installed apps and shortcuts.

| Selector | Target |
|---|---|
| `capsule/<app>` | Capsulenv-owned PortableSafe app |
| `scoop/<app>` | Upstream Scoop app |
| `scoop:user/<app>` | App in Scoop user root (for disambiguation) |
| `scoop:global/<app>` | App in Scoop global root (for disambiguation) |

When you omit a prefix, the resolver prefers Capsulenv packages. When identical package names exist in both Scoop roots, specify the Scoop scope.

Launch an app or a named shortcut:

```powershell
capsulenv app run capsule/<app>
capsulenv app run scoop/<app> "<shortcut name>"
```

Execute a manifest binary with arguments:

```powershell
capsulenv app exec capsule/<app> <bin> -- <arguments>
```

For general external commands, run `capsulenv run <command> <arguments>`. For selector resolution rules, see [ARCHITECTURE](ARCHITECTURE.md#provisioning-and-runtime-separation).

## Configuration

From the capsule root, run once:

```powershell
Copy-Item config\capsulenv.local.psd1.example config\capsulenv.local.psd1
```

If `config/capsulenv.local.psd1` already exists, edit that file directly. Store personal settings in `config/capsulenv.local.psd1` to keep the default configuration upgradable.

For available fields, see [config example](../config/capsulenv.local.psd1.example). Merge configuration blocks into the outermost hashtable.

### Private PowerShell modules

Store private modules in `PowerShell/Modules/`. Capsulenv shells prepend configured module roots to `PSModulePath`.

In module installer scripts, read `$env:CAPSULENV_MODULE_ROOT` to target the first module root. Set `Environment.ModulePath` to customize locations.

### Browser

Launch an installed Gecko browser:

```powershell
capsulenv browser capsule/librewolf
capsulenv browser scoop/firefox
```

Add `--host` only when you need to borrow the host executable of the same product. The browser still uses the capsule profile.

To register a capsule browser as a candidate default browser in Windows, configure:

```powershell
UserIntegration = @{
    DefaultBrowser = 'scoop/firefox'
}
```

Run `capsulenv install-user`, then confirm the choice in Windows Settings. Configure custom Gecko profiles and arguments under `Browsers`.

### Bitwarden SSH Agent

Install compatible Bitwarden Desktop first. If the app name differs, set `Bitwarden.App` to your selector.

```powershell
capsulenv bitwarden setup
capsulenv bitwarden status
capsulenv bitwarden agent-test
```

ShellOnly mode applies process-level Git SSH configuration. User mode applies backed-up persistent integration. Capsulenv does not move or copy vault data.

To revert Bitwarden SSH integration:

```powershell
capsulenv bitwarden restore
```

For Bitwarden integration rules, see [ARCHITECTURE](ARCHITECTURE.md#bitwarden-ssh-ownership).

### Lifecycle routines

To run external workflows on capsule lifecycle events, configure `Routines`:

```powershell
Routines = @{
    Network = @{
        Trigger = @('OnEnter', 'OnRehydrate')
        Command = 'powershell.exe'
        Arguments = @('-NoLogo', '-NoProfile', '-Command', "Import-Module NyaModule -Force; Invoke-NyaJob -Name 'portable-network'")
        MinimumIntervalSeconds = 60
        FailurePolicy = 'Warn'
    }
}
```

Available trigger events are `OnEnter`, `OnExit`, `OnRehydrate`, and `OnEject`. Routines can also specify installed apps via `App` and `BinName`.

List routines or trigger an event manually:

```powershell
capsulenv routine list
capsulenv routine run OnEnter Network
```

Add `--force` only when you need to bypass the minimum execution interval. Child processes inherit `CAPSULENV_ROOT` and `CAPSULENV_LAUNCHER`. External orchestrators manage schedules and retry policies.

## Tool storage

Initialize and inspect tool storage paths:

```powershell
capsulenv cache init
capsulenv cache paths
```

Preserve `tool-data/` across backups; it contains toolchains, global state, and credentials. Before cleaning `cache/`, verify that tools do not treat it as an active dependency store. For path classifications, see [TOOLS](TOOLS.md#storage-classes).

Link a Rust project's `target/` directory to registered cache storage:

```powershell
capsulenv cache link cargo-target D:\src\project --move
capsulenv cache status D:\src\project
```

Restore the original project directory:

```powershell
capsulenv cache unlink cargo-target D:\src\project --restore
```

Only explicitly registered uv and Pixi workspaces undergo automatic relocation repair. uv requires `pyproject.toml` and `uv.lock`. Pixi requires `pixi.lock` and project manifests.

```powershell
capsulenv tools register uv D:\Portable\capsulenv\workspace\python-app
capsulenv tools register pixi D:\Portable\capsulenv\workspace\science-app
capsulenv tools status
```

To unregister, run `tools unregister <uv|pixi> <workspace>`. For link and repair requirements, see [TOOLS](TOOLS.md#project-cache-links).

## Seed from a host

Seeding imports host state once. Select commands by task:

| Task | Command | Prerequisites / Result |
|---|---|---|
| Import PowerShell 7 profiles | `capsulenv seed powershell` | Capsule has resolved `pwsh` with profile persist |
| Import Git global configuration | `capsulenv seed git` | Excludes credentials and HTTP headers by default |
| Capture Scoop inventory | `capsulenv seed scoop` | Saves apps and buckets only |
| Back up Weasel user data | `capsulenv seed weasel` | Host has verified Weasel installation |
| Restore Weasel user data | `capsulenv seed weasel restore` | Backs up current host data before restore |

When portable seed data already exists, inspect content first. Add `--force` only when you accept overwriting.

To apply a captured Scoop inventory, run `capsulenv seed scoop --apply`. Check session mode via `capsulenv status` first:

- In ShellOnly mode, Capsulenv copies existing package directories from the host. Source files must remain readable; global app snapshots require elevation.
- In User mode, Capsulenv runs upstream `scoop import`. This is explicit TrustedExecution that may run installer scripts and modify the host.

For filtering and backup semantics, see [TOOLS](TOOLS.md#one-way-host-seeding).

## Repair

After moving the drive, launch Capsulenv from the new location. If warnings appear, run:

```powershell
capsulenv status
capsulenv doctor
```

To rerun full relocation repair explicitly, run `capsulenv rehydrate`.

| Symptom | Next step |
|---|---|
| Individual app projection needs rebuild | `capsulenv reset capsule/<app>` or `capsulenv reset scoop/<app>` |
| Registered project cache link broken | `capsulenv cache repair --strict` |
| Preview allow-listed text path repair | `capsulenv repair-persist --dry-run` |
| uv or Pixi relocation repair failed | Preview via `capsulenv tools repair all --last --dry-run` |
| Retry tool relocation repair | `capsulenv tools repair all --last --strict` |

`capsulenv reset` repairs projections only. If diagnostics show ambiguous active versions or diverged data, inspect versions and files first. Repair via upstream Scoop or reinstall as guided by `doctor`. Do not delete `.capsulenv/` to clear warnings. For projection repair rules, see [ARCHITECTURE](ARCHITECTURE.md#relocation-projection-repair).

Pixi global sync may re-resolve version ranges. Run `tools repair pixi --last --include-global` only when you accept re-resolution. For failure and retry rules, see [TOOLS](TOOLS.md#failure-and-retry).

## Offline checks

Before disconnecting from the network, inspect installed state and prefetch package downloads:

```powershell
capsulenv offline status
capsulenv offline prefetch
capsulenv drift
```

These commands rely on local Scoop metadata and bucket repositories. `offline status` does not guarantee arbitrary new installations will succeed offline. `drift` does not fetch network updates. For offline cache guarantees, see [TOOLS](TOOLS.md#host-local-scratch-and-offline-cache).
