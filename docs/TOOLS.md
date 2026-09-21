# Tool storage and native relocation

This page defines tool data classifications, cache stores, project-cache links, and uv/Pixi relocation repair semantics. For operational instructions, see [USAGE](USAGE.md#tool-state-and-project-cache). For runtime ownership rules, see [ARCHITECTURE](ARCHITECTURE.md).

`ToolStorage` is a narrow compatibility adapter for routing tool-native State,
cache, and explicitly registered project-cache data. It is not the authority
for installed program identity, provider selection, generations, sessions, or
host integration. Those decisions remain in the installed selector and state
ledgers described by [ARCHITECTURE](ARCHITECTURE.md#normative-runtime-authority).

## Storage classes

| Class | Purpose | Preservation policy |
|---|---|---|
| `tool-data/` | Configurations, toolchains, global state, and credentials | Must preserve; durable across sessions |
| `cache/` | Rebuildable download, compilation, and package caches | Inspect tool usage before deletion |
| `project-cache/` | Backing store for explicitly registered project caches | Managed alongside link registries |

Default paths are listed below. Exact variable names match `config/capsulenv.psd1` under `ToolStorage`.

| Tool | Path under `cache/` | Path under `tool-data/` |
|---|---|---|
| Scoop | `scoop/` | Apps, buckets, and persist reside in Scoop roots |
| Git | — | `git/config` |
| PowerShell | — | `powershell/PSReadLine/ConsoleHost_history.txt` |
| uv | `uv/`, `uv-python/` | `uv/python/`, `uv/tools/`, `uv/uv.toml` |
| Pixi | `pixi/` | `pixi/` |
| npm | `npm/` | `npm/` |
| pnpm | `pnpm/`, `pnpm-store/` | `pnpm/`, `pnpm-state/` |
| Bun | `bun/` | `bun/global/`, `bun/bin/` |
| Go | `go-build/`, `go-mod/` | `go/gopath/`, `go/bin/`, `go/env` |
| Rust/Cargo | Project `target/` managed separately | `rustup/`, `cargo/` |
| ccache | `ccache/` | `ccache/ccache.conf` |
| sccache | `sccache/` | `sccache/config.toml` |

`ToolStorage.PathVariables` lists directory-valued variables. `ToolStorage.FileVariables` lists file-valued variables. File variable initialization creates parent directories and missing empty files only.

Primary mappings include `GIT_CONFIG_GLOBAL`, `UV_CACHE_DIR`, `UV_PYTHON_CACHE_DIR`, `UV_CONFIG_FILE`, `PIXI_HOME`, `PIXI_CACHE_DIR`, `PIXI_CONFIG_FILE`, `NPM_CONFIG_PREFIX`, and `NPM_CONFIG_USERCONFIG`. Global tools installed by uv may use the shared capsule `bin/`.

`CARGO_HOME` contains binaries, registry/git caches, configurations, and authentication tokens. Never treat the entire directory as disposable cache.

## Host-config boundaries

Capsulenv never sets a session-wide `XDG_CONFIG_HOME` override to capture isolated tool configs.

| Tool | Capsulenv configuration boundary |
|---|---|
| pnpm | Configures portable data/cache and `.npmrc` paths; does not relocate YAML config via global XDG overrides |
| Bun | Sets global package/bin and cache locations; does not take over the host default global `bunfig.toml` |
| Go | Sets `GOENV`, `GOPATH`, `GOBIN`, `GOCACHE`, `GOMODCACHE`; does not relocate user config roots to capture telemetry |

These host settings may remain outside the capsule. Project-local configurations remain managed by their respective repositories.

## Cache cleaning and filesystem locality

Capsulenv does not provide a `cache clean all` command. Tools may treat shared stores, symlink caches, or virtual stores as active dependency storage. Run tool-native pruning commands when cache cleaning is required.

When uv, pnpm, and Pixi share the same filesystem volume with project workspaces, hardlinks and reflinks function efficiently. Cross-volume links fall back to copies.

Capsulenv does not relocate project-level `node_modules`, `.venv`, `.pixi`, or build output directories automatically. Sharing backing storage requires explicit registration.

## Project-cache links

`ToolStorage.ProjectLinks` defines allowed profile types. The default `cargo-target` profile places Rust `target/` directories into `project-cache/` using directory junctions. For usage instructions, see [USAGE](USAGE.md#tool-state-and-project-cache).

| Link type | Conditions |
|---|---|
| Junction | Default for directory profiles |
| Symlink | Requires Windows Developer Mode or elevated privileges |
| HardLink | Files only (`Kind = 'File'`); source and target must reside on the same volume |

The registry resides in `.capsulenv/project-cache-links.json`. Workspaces inside the capsule use relative identities; external workspaces use absolute paths. Moving an external workspace establishes a new cache identity.

When repairing junctions or absolute symlinks, the existing target must match the registered record exactly. The new target must fall within the original ownership scope. Normal files, normal directories, and links pointing elsewhere are never overwritten.

File hardlink registries record file length and SHA-256 hashes. After copying across drives, hardlinks are recreated only if both files match the registered hash and reside on the same volume. If content diverges, files are preserved.

## Registered uv/Pixi workspaces

Capsulenv repairs only explicitly registered workspaces with lock files. It does not scan the filesystem recursively for `.venv` or `.pixi`.

The registry resides in `.capsulenv/tool-workspaces.json`. Workspaces inside the capsule use relative paths; external workspaces retain absolute paths. For registration syntax, see [USAGE](USAGE.md#tool-state-and-project-cache).

## uv native repair

`ToolStorage.Relocation.Uv.App` specifies the installed app, defaulting to `uv`. The resolver selects the application's declared manifest binary. It accepts Capsulenv and Scoop providers; for resolver rules, see [Installed selector and runtime separation](ARCHITECTURE.md#installed-selector-and-runtime-separation).

Fallback to internal `tool-data` or `bin/` binaries occurs only when the specified app is absent. If an app is ambiguous or its executable is incompatible, resolution fails closed without borrowing host executables.

### Managed Python and global tools

Managed Python installations are reinstalled using the existing installation keys reported by uv. Capsulenv never issues untargeted reinstalls.

External uv JSON outputs are treated as untrusted input. The reader flattens records and verifies properties before access. Incomplete records trigger warnings and skip safely.

Global tool repair reads `uv-receipt.toml` and retrieves the installed version from the existing environment. It rewrites only known `OldRoot -> NewRoot` receipt paths.

During reinstall, the version is passed as a command parameter. Stored requirements are preserved without modification, retaining extras, index configurations, local paths, and VCS references. If receipts cannot be parsed, the original data is preserved.

### Workspace transaction

`UV_PROJECT_ENVIRONMENT` must reside within the workspace or capsule root.

Repair renames the existing environment, creates a new environment, and runs a locked reinstall:

```text
uv venv <environment> --project <workspace> --relocatable --no-progress
uv sync --project <workspace> --locked --reinstall --no-progress
```

The `--relocatable` flag is applied when supported by feature detection. Older uv versions use full reconstruction and locked synchronization. If environment creation or synchronization fails, the unfinished environment is removed and the original environment is restored.

## Pixi native repair

`ToolStorage.Relocation.Pixi.App` defaults to `pixi`. Executable resolution and fallback mechanics follow the same rules as uv.

Registered workspaces run:

```text
pixi reinstall --all --locked --manifest-path <workspace>
```

Pixi global state resides in `PIXI_HOME`. `pixi-global.toml` can contain version ranges, and Pixi lacks a global lock file. Therefore, Capsulenv does not run `pixi global sync` by default during relocation.

Pass `--include-global` when version re-resolution is acceptable. Setting `ToolStorage.Relocation.Pixi.RepairGlobal = $true` enables global synchronization on every relocation.

## Failure and retry

Native repair may require network access or a populated package cache. Non-strict repair reports failing components and allows remaining rehydration tasks to proceed. The last relocation context is retained for retry with `--last`.

| Option | Effect |
|---|---|
| `tools repair --dry-run` | Previews repair actions |
| `tools repair --last` | Reuses previous relocation context |
| `tools repair --strict` | Fails when a tool or workspace repair fails |
| `rehydrate --strict-tool-repairs` | Aborts committing new relocation fingerprints if tool repair fails |
| `tools repair --skip-workspaces` | Skips registered project environments |
| `rehydrate --skip-tool-repairs` | Skips the native tool repair phase entirely |

For retry instructions, see [USAGE](USAGE.md#repair).

## One-way host seeding

Seeding performs a one-way import of host data. For command syntax, see [USAGE](USAGE.md#seed-from-a-host).

### PowerShell

`seed powershell` copies host PowerShell 7 CurrentUser profiles into the resolved `pwsh` package's persisted `$PSHOME` profile files. The capsule must have an installed PowerShell app with profile persistence.

The command does not copy host module directories or rewrite host-specific absolute paths and imports. Overwriting non-empty portable profiles requires `--force`.

### Git

`seed git` temporarily removes Capsulenv's process Git overlay, runs Git to read and flatten the host global configuration, and writes the output to `tool-data/git/config`.

It strips `include.*` and `includeIf.*`, keeping Capsulenv SSH configuration separate. It excludes `credential.*` and `http.*.extraHeader` unless `--include-sensitive` is explicitly passed.

### Scoop

Capture invokes upstream Scoop export to save app and bucket lists to `tool-data/scoop/Scoopfile.json`. Host Scoop configuration is not imported.

In ShellOnly mode, apply classifies source snapshot state first. It copies missing version directories, persist trees, and readable bucket repositories into the capsule, then runs bounded projection repair. Existing capsule apps and persist data take precedence and are never overwritten.

If source app files are unreadable, apply fails closed. Snapshots containing global apps require elevated privileges, checked before copying. This path executes no installer hooks or manifest lifecycle scripts.

In User mode, apply delegates directly to upstream `scoop import`. This is explicit TrustedExecution; User mode does not convert third-party package scripts into PortableSafe guarantees.

### Weasel

Backup and restore require registry evidence of an authentic Weasel installation alongside its server and deployer binaries. An arbitrary `%APPDATA%\Rime` directory is insufficient evidence of installation.

Backup performs a cold copy of the resolved Rime user data to `tool-data/weasel/user-data`. Overwriting existing backup data requires `--force`.

Restore backs up current host user data into machine/user integration state, replaces data transactionally, and invokes Weasel deployment. If deployment fails, host data is restored from backup. Capsulenv never installs Weasel.

## Host-local scratch and offline cache

`CAPSULENV_SCRATCH` resides under host `%TEMP%\capsulenv\<capsule-id>` (or the platform temporary root in tests). Capsulenv does not overwrite `TEMP` or `TMP`; `eject` attempts to clean up scratch data.

| Command | Guarantee scope |
|---|---|
| `offline status` | Checks environment integrity and cache population; does not guarantee arbitrary new installs will succeed offline |
| `offline prefetch` | Warms download caches for installed Scoop apps using local bucket manifests |
| `drift` | Compares installed versions with local bucket manifests without network requests |
