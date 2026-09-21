# Migration guide

This document lists only the required upgrade actions. Do not infer current runtime behavior from historical release notes; refer to [README](../README.md), [USAGE](USAGE.md), [ARCHITECTURE](ARCHITECTURE.md), and [TOOLS](TOOLS.md) for canonical specifications.

## Migrating from `portable-scoop.ps1`

Replace the legacy session entrypoint with:

```bat
capsulenv.cmd shell
```

Legacy `EnableUser` and `RestoreUser` commands map to:

```bat
capsulenv.cmd install-user
capsulenv.cmd restore-user
```

`enable-user` remains a compatibility alias, but new scripts and documentation should use `install-user`.

Do not assume scripts will run `scoop reset *` or replay `pre_install`/`post_install` during relocation. Starting in v0.17, Capsulenv no longer executes manifest lifecycle replays; explicit PortableSafe relocation repair only touches Capsulenv-owned projections, and legacy Scoop state receives only bounded `current`/`persist` repair. When you need arbitrary lifecycle execution, run upstream Scoop explicitly. See [ARCHITECTURE](ARCHITECTURE.md#bounded-legacy-projection-adapter).

## Migrating from the v0.1.x parallel `data/` model

Early versions created directories under `data/`:

```text
data/bitwarden
data/browsers/firefox/profile
data/browsers/zen/profile
data/xdg
```

Current versions neither read nor write these paths, and do not delete them automatically. Inspect installed app manifests, confirm that persistent data has merged into corresponding Scoop persist stores (such as `scoop/persist/bitwarden/...` or `scoop/persist/firefox/profile`), and then delete the legacy `data/` folder manually.

If v0.1.x modified host browser `profiles.ini` or `user.js` and retained backup files, run restore using the old version before decommissioning it. Current versions do not manage legacy browser backups.

## Migrating from v0.4.x / v0.5.x persisted path repairs

Since v0.5, relocation path repair uses an explicit `Scoop.RelocationRepairs` allow-list instead of scanning all persisted files. When upgrading a capsule that changed drive letters before rehydration, preview repairs first:

```bat
capsulenv.cmd doctor
capsulenv.cmd repair-persist --dry-run
capsulenv.cmd rehydrate
```

To disallow built-in persisted text rewrites, set an empty map in `config/capsulenv.local.psd1`:

```powershell
@{
    Scoop = @{
        RelocationRepairs = @{}
    }
}
```

A local `RelocationRepairs` block replaces the entire allow-list rather than merging recursively.

## Migrating from v0.6 / v0.7 tool storage

These versions organized toolchain states and caches into `tool-data/` and `cache/`, adding explicit project cache links and native uv/Pixi relocation repair.

If an existing capsule relies on manual environment variables or custom cache paths, inspect current locations:

```bat
capsulenv.cmd cache paths
capsulenv.cmd tools status
```

Move required persistent data into `tool-data/`. Do not treat `CARGO_HOME`, global package manager states, or persistent configurations as disposable caches. For path classifications, see [TOOLS](TOOLS.md#storage-classes).

For repositories with existing project-cache links, preserve `.capsulenv/project-cache-links.json` and backing storage, then run:

```bat
capsulenv.cmd cache repair
```

Workspaces do not undergo automatic discovery; register lock-backed workspaces explicitly via `capsulenv tools register`.

## Migrating from v0.8.x portable PowerShell module root

Store private PowerShell modules in `PowerShell/Modules/` (or the location set by `Environment.ModulePath`). Inside a Capsulenv shell, the first module root is exposed as `$env:CAPSULENV_MODULE_ROOT`.

Update custom module build scripts to target: explicit `-InstallRoot` > `$env:CAPSULENV_MODULE_ROOT` > default Documents path. Capsulenv does not copy host module directories automatically.

## Migrating from v0.9.x install-mode state

Install mode ownership is machine- and user-scoped under:

```text
.capsulenv/user-integrations/<machine-user-hash>/
```

Do not copy legacy `.capsulenv/user-environment-backup.json` or `install-mode.json` to another host to claim User ownership. The runtime migrates legacy state only when ownership evidence confirms the current user session.

On shared computers that reset on shutdown, launch User mode directly after reboot:

```bat
capsulenv.cmd user-shell
```

You do not need to run `restore-user` with an old ledger; Capsulenv creates a fresh host-scoped backup from the clean user environment.

## Migrating from v0.10.x storage ownership

The canonical Scoop download cache is top-level `cache/scoop`. Persistent configurations (Git global config, uv/Pixi configs, npm user config) reside under `tool-data/`. Compare existing local overrides against `config/capsulenv.local.psd1.example` and `capsulenv.cmd cache paths` to eliminate outdated settings.

Capsulenv does not set a session-wide `XDG_CONFIG_HOME` override to capture pnpm or Bun global configs. Configure supported portable environment variables or project-local files instead.

## Migrating from v0.12.x PowerShell profile isolation and seeding

PowerShell executables and `$PSHOME` profiles are managed by Scoop packages and persist storage. ShellOnly mode prevents host CurrentUser profiles from executing in the isolated session.

To migrate personal aliases and modules from the host, seed profiles once:

```bat
capsulenv.cmd seed powershell
```

Deploy module files into `PowerShell/Modules/`. To import host Git configuration or Scoop inventories into capsule ownership, run `seed git` or `seed scoop`. Seeding is one-way import, not synchronization. For filtering and overwrite rules, see [TOOLS](TOOLS.md#one-way-host-seeding).

## Migrating from v0.14.x app presets and candidate paths

v0.15 unified browser, Bitwarden, and tool executable identification into installed Scoop app selectors. The runtime inspects the selected app's installed `manifest.json` and `install.json` instead of probing candidate paths under `scoop\apps\...\current`.

Update browser presets to exact manifest selectors:

```powershell
@{
    UserIntegration = @{ DefaultBrowser = 'zen-browser' }
}
```

If local configuration overrides `Bitwarden.ExecutableCandidates`, replace it with `Bitwarden.App` and optional `ShortcutName`, `BinName`, or `ExecutablePath`. Persistent data stays in the app's persist directory. Custom Gecko browsers configure under `Browsers`.

Runtime selectors accept `capsule/<app>` for Capsulenv-owned packages and `scoop/<app>` for upstream Scoop packages. Remove obsolete `Scoop.ReplayHooks` from local configuration.

## Migrating from v0.15.0–v0.15.5 source-only updates

If you applied source patches to an installed capsule without running the runtime installer, `capsulenv.cmd` will continue running the previous module. Minimal runtimes omit `src/` and the module compiler; `CAPSULENV_FORCE_REBUILD=1` does not rebuild modules in an installed capsule.

To upgrade to v0.15.6+, extract the release bundle to a staging directory outside the capsule and run:

```bat
X:\capsulenv-release\install.cmd D:\Portable\capsulenv
D:\Portable\capsulenv\capsulenv.cmd version
```

This updates managed files transactionally and preserves packages, persist data, workspaces, and configuration. Development checkouts rebuild modules automatically on launch.

Effective default-browser association detection inspects Shell association status rather than legacy `UserChoice` registry keys, ensuring compatibility with Windows 11 `UserChoiceLatest`.

### v0.15.7: Browser registration command repairs

Early versions (v0.15.3 and earlier) registered default browser handlers containing `-osint` or direct persist paths in `shell\open\command`. Gecko browsers exit immediately when encountering `-profile ... -osint -url ...`.

Starting in v0.15.7, User mode activation and `install-user --force` refresh tracked Capsulenv ProgID command strings in place. Run `capsulenv.cmd doctor` to compare actual and expected URL handler commands.

### v0.15.8: Control host isolation for built-in PowerShell modules

If running `capsulenv.cmd` from an interactive shell fails with `Import-PowerShellDataFile` not recognized, deploy an updated runtime bundle from an external staging directory:

```bat
X:\capsulenv-release\install.cmd D:\Portable\capsulenv
D:\Portable\capsulenv\capsulenv.cmd version
```

The control entrypoint isolates `$PSHOME/Modules` to load built-in utility modules reliably, preventing private `PSModulePath` entries from shadowing control commands.

### v0.16.0: Separating deployment from relocation

v0.16.0 separated release bundle contents from destination runtime installations. Release bundle metadata (`.capsulenv-runtime.json` schema 3) distinguishes `ManagedFiles` from destination-only `InstallFiles`. Installation deploys only `capsulenv.cmd`, config/bin helpers, and `modules/Capsulenv/**`. Installers, documentation, and bundle manifests remain in staging.

When upgrading from v0.15.x, run the installer once from the new bundle. The installer removes obsolete root `scripts/` helpers and staging files while preserving all mutable user state.

Subsequent relocation requires no installer. Move the directory to another drive or machine and launch `capsulenv.cmd` directly:

```bat
D:\Portable\capsulenv\capsulenv.cmd
```

The installed launcher executes `modules/Capsulenv/runtime/Invoke-Capsulenv.ps1`. The installer does not bootstrap Scoop, create mutable runtime state, or apply User integration.

### v0.16.1: Removing control-plane dependency on Import-PowerShellDataFile

v0.16.1 removed reliance on `Import-PowerShellDataFile` in the control plane. Configuration files are read using a safe AST parser.

If you encounter v0.16.0 deployment errors relating to `Import-PowerShellDataFile`, reinstall the runtime from a v0.16.1+ bundle:

```bat
X:\capsulenv-release\install.cmd D:\Portable\capsulenv
D:\Portable\capsulenv\capsulenv.cmd version
```

### v0.16.2: Session mode and User shortcut isolation

Every fresh invocation defaults to a ShellOnly session. The User ledger under `.capsulenv/user-integrations/<machine-user-hash>/` records persistent integration for rollback, but does not convert subsequent independent terminal launches into User mode. Use `user-shell` or `install-user` to enter User mode. Run `restore-user` to revert host integrations.

User mode shortcuts are isolated to:

```text
Programs\Capsulenv Apps\<capsule-id-prefix>
```

`restore-user` deletes only this capsule-specific namespace. Upstream `Programs\Scoop Apps` shortcuts are not removed automatically because ownership cannot be verified.

uv managed-Python relocation handles external JSON schemas fail-safe: records missing `key` or `path` trigger warnings and skip safely without halting rehydration under StrictMode.

### v0.16.4: Scoop gateway bootstrap context

v0.16.4 resolved an issue where intercepting mutation commands in earlier gateways caused `CommandNotFoundException` for Scoop internal helpers. Starting in v0.17, the gateway model was replaced entirely. Upgrading to v0.17+ resolves this by invoking upstream Scoop without interception.

### v0.17.0: Package and runtime boundary

v0.17.0 removed the Scoop gateway, policy injection, and reset adapter architecture:

- `scoop ...` invokes **unmodified upstream Scoop**. Capsulenv no longer rewrites libexec, overrides `shortcut_folder`, or injects lifecycle policies.
- Safe package operations use `capsulenv.cmd app plan <ref>` and `capsulenv.cmd app install <ref>`. Only packages whose complete dependency graph belongs to the declarative subset enter the `PortableSafe` executor.
- Packages with `pre_install`, `post_install`, or custom installers classify as TrustedExecution. To install them, pass `--allow-trusted` or invoke upstream `scoop install`. These operations fall outside Capsulenv reversibility guarantees.
- PortableSafe packages reside in `packages/`, `package-persist/`, `shims/`, and `.capsulenv/packages/`. The selector prefix is `capsule/<app>`. Upstream Scoop packages use `scoop/<app>`.
- The planner fails closed on unsupported manifest properties (`cookie`, `psmodule`, unknown active properties). Artifact support requires SHA-256, `http`/`https`/`file`, and ZIP or plain files.
- Relocation projection repair does not invoke Scoop private helpers. Capsulenv repairs its own package projections and performs bounded `current`/`persist` repair for legacy Scoop packages. If an active version cannot be verified, repair fails closed and guides explicit resolution.
- Obsolete `capsulenv hooks` and `Scoop.ReplayHooks` have been removed.
- User mode synchronization rebuilds the `Programs\Capsulenv Apps\<capsule-id>\PortableSafe` namespace with targets pointing to `capsulenv.cmd app run capsule/<app>`.

Upgrades do not require deleting `scoop/` or reinstalling packages. Review migration inventory and request `rehydrate` explicitly when relocation evidence requires projection repair. Remove obsolete `Scoop.ReplayHooks` from local configuration. For the package trust model, see [ARCHITECTURE](ARCHITECTURE.md#package-planner-and-portablesafe-subset).

## Verification after upgrade

After completing any upgrade across major versions, verify runtime health:

```bat
capsulenv.cmd doctor
capsulenv.cmd cache paths
capsulenv.cmd tools status
capsulenv.cmd offline status
```

If the capsule changed drive letters or paths, run `capsulenv.cmd rehydrate`. Do not delete `.capsulenv/` to clear warnings; it contains identity, relocation context, and registry evidence required for ownership verification.

## Cleaning historical ShellOnly Scoop host state (0.14.1–0.16.x)

0.14.1–0.16.x used a gateway to intercept ShellOnly mutations. In v0.17, this gateway was removed. If an earlier version allowed upstream Scoop to register capsule paths in Windows User PATH or `Programs\Scoop Apps`:

1. Inspect and remove only shortcuts or environment variables whose targets point directly inside this capsule root.
2. Allow the host's foreign Scoop to repair host-owned shortcuts.
3. Existing `scoop/apps`, `scoop/persist`, and installed manifests do not require deletion.

Directly executing `scoop ...` represents upstream TrustedExecution; for safe package management, use `capsulenv app install`.

## Installed app selector namespace migration

Capsulenv separates package providers from Scoop's provider-local root scopes:

- Use `capsule/<app>` for Capsulenv-owned PortableSafe packages.
- Use `scoop/<app>` for upstream Scoop packages.
- Existing `user/<app>` and `global/<app>` references remain accepted as compatibility aliases.
- When identical app names exist in both Scoop roots, use `scoop:user/<app>` or `scoop:global/<app>` for disambiguation.

For selector resolution rules, see [ARCHITECTURE](ARCHITECTURE.md#installed-selector-and-runtime-separation). For usage syntax, see [USAGE](USAGE.md#installed-apps).
