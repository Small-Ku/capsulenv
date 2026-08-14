# Tool storage and native relocation

這份文件是 `tool-data/`、`cache/`、`project-cache/` 與 uv/Pixi native repair 的權威 reference。README 只保留日常命令；runtime mode/ownership 則見 [`ARCHITECTURE.md`](ARCHITECTURE.md)。

## Storage classes

Capsulenv 不把所有 package-manager 資料都叫做 cache。預設分成：

```text
cache/                              rebuildable shared caches/stores
├─ scoop/
├─ uv/
├─ uv-python/
├─ pixi/
├─ npm/
├─ pnpm/
├─ pnpm-store/
├─ bun/
├─ go-build/
├─ go-mod/
├─ ccache/
└─ sccache/

tool-data/                          persistent tool state/global installs
├─ git/config
├─ powershell/PSReadLine/
├─ uv/python/
├─ uv/tools/
├─ uv/uv.toml
├─ pixi/
├─ npm/
├─ pnpm/
├─ pnpm-state/
├─ bun/global/
├─ bun/bin/
├─ go/gopath/
├─ go/bin/
├─ go/env
├─ rustup/
├─ cargo/
├─ ccache/ccache.conf
└─ sccache/config.toml
```

預設 environment mapping：

| Tool | Rebuildable cache/store | Persistent capsule state |
|---|---|---|
| Scoop | `SCOOP_CACHE` -> `cache/scoop` | app/bucket/persist state under Scoop roots |
| Git | — | `GIT_CONFIG_GLOBAL` -> `tool-data/git/config` |
| PowerShell | — | PSReadLine history -> `tool-data/powershell/PSReadLine/ConsoleHost_history.txt` |
| uv | `UV_CACHE_DIR`, `UV_PYTHON_CACHE_DIR` | managed Python, global tools, `UV_CONFIG_FILE`, shared `bin/` |
| Pixi | `PIXI_CACHE_DIR` | `PIXI_HOME`, `PIXI_CONFIG_FILE` |
| npm | `NPM_CONFIG_CACHE` | `NPM_CONFIG_PREFIX`, `NPM_CONFIG_USERCONFIG` |
| pnpm | store/cache dirs | `PNPM_HOME`, state/global/global-bin dirs; npmrc fallback |
| Bun | install cache | global package/bin dirs |
| Go | `GOCACHE`, `GOMODCACHE` | `GOPATH`, `GOBIN`, `GOENV` |
| Rust/Cargo | project `target/` is separate | `RUSTUP_HOME`, mixed `CARGO_HOME` |
| ccache | cache/temp dirs | `CCACHE_CONFIGPATH` |
| sccache | cache dir | `SCCACHE_CONF` |

`ToolStorage.PathVariables` only contains directory-valued variables. `ToolStorage.FileVariables` is separate so `cache init` creates the parent + missing empty file instead of accidentally making a directory named `config.toml`, `npmrc`, etc.

`tool-data/` is persistent state and may contain credentials/tokens. In particular `CARGO_HOME` is mixed state: installed binaries, registry/git cache and potentially config/credentials coexist, and Cargo does not expose a complete set of independent official redirects that would make the whole directory safely disposable.

## Host-config boundaries

Capsulenv does not redirect session-wide `XDG_CONFIG_HOME` merely to capture every package manager's last config file. Doing so would change unrelated child applications.

Current pnpm portable data/cache paths and `NPM_CONFIG_USERCONFIG` are used, but pnpm's newer global YAML config discovery is not forcibly moved through a global XDG override. Bun likewise has no dedicated environment variable for the default global `bunfig.toml`; project-local config remains project-owned, and an explicit per-command config may still be used.

Go has a similar deliberate exception: `go env GOTELEMETRYDIR` is calculated by Go and is not an environment-settable redirect. Capsulenv owns `GOENV`, `GOPATH`, `GOBIN`, `GOCACHE` and `GOMODCACHE`, but does not repoint the entire Windows/XDG user-config root solely to move telemetry state.

These are documented host-owned boundaries rather than silently claiming full portability.

## Cache cleaning and filesystem locality

`cache/` is conceptually rebuildable, but Capsulenv does not expose a destructive `cache clean all`. Tool modes can turn a shared store/cache into a live dependency: uv symlink linking, package-manager virtual stores, daemons and active hardlinks/reflinks all have tool-specific semantics. Use native cleaning commands when required; `capsulenv.cmd cache paths` tells you which paths are capsule-owned.

uv, pnpm and Pixi stores perform best when the consuming project environment is on the same filesystem. If the capsule is on `F:` while a project is on `D:`, hardlink/reflink materialization may fall back to copies. Put performance-sensitive portable projects under `workspace/` or otherwise on the same filesystem when practical.

Capsulenv does not globally redirect `node_modules`, `.venv`, `.pixi` or every project's build output into one shared directory. Correct project ownership/isolation takes priority over maximum deduplication.

## Project-cache links

Project-local caches/build directories can be backed by `project-cache/` only through explicit profiles. The default `cargo-target` profile moves a Rust project's `target/` into capsule storage and leaves a managed directory junction:

```bat
capsulenv.cmd cache link cargo-target D:\src\project --move
capsulenv.cmd cache status D:\src\project
capsulenv.cmd cache unlink cargo-target D:\src\project --restore
```

Directory hardlinks do not exist on Windows. Directory profiles default to junctions; `--symlink` is available where Windows permissions/Developer Mode permit. `HardLink` is valid only for `Kind = 'File'` profiles and only when link/store remain on the same volume.

Registry state is stored in `.capsulenv/project-cache-links.json`. Capsule-internal projects use a capsule-relative identity, so moving `workspace/project` with the USB keeps the same project ID. External projects are identified by absolute path and intentionally become a new cache identity when the project itself moves elsewhere.

Junctions/absolute symlinks store absolute targets. After relocation Capsulenv only replaces a stale link when its current target exactly matches the previously registered target and the new target is still within the recorded ownership boundary. Ordinary directories/files or links pointing elsewhere are never replaced opportunistically.

File-hardlink records also store length + SHA-256. A cross-drive copy can turn one hardlink pair into two independent regular files; repair recreates the hardlink only if both copies still match the stored fingerprint and the new paths are on the same volume. Diverged copies are left untouched.

Manual repair:

```bat
capsulenv.cmd cache repair
capsulenv.cmd cache repair --strict
```

## Registered uv/Pixi workspaces

Capsulenv does not recursively discover every `.venv` or `.pixi`; only explicitly registered lock-backed workspaces are eligible for automatic native repair.

```bat
capsulenv.cmd tools register uv D:\Portable\capsulenv\workspace\python-app
capsulenv.cmd tools register pixi D:\Portable\capsulenv\workspace\science-app
capsulenv.cmd tools unregister uv D:\Portable\capsulenv\workspace\python-app
capsulenv.cmd tools status
```

An uv workspace must contain `pyproject.toml` + `uv.lock`. A Pixi workspace must contain `pixi.lock` plus `pixi.toml` or `pyproject.toml`. Registry state lives in `.capsulenv/tool-workspaces.json`; paths inside the capsule are stored relative to the capsule, while external workspaces intentionally remain absolute.

## uv native repair

Tool metadata/launchers may contain absolute paths even when the backing directories moved successfully. uv repair is therefore native rather than a recursive text rewrite:

```bat
capsulenv.cmd tools repair uv --dry-run --last
capsulenv.cmd tools repair uv --last --strict
```

Managed Python installs are enumerated using uv's existing installation keys and reinstalled by exact key; Capsulenv never issues a target-less reinstall that could silently select a different default Python.

For global tools, Capsulenv reads each `uv-receipt.toml`, obtains the installed package version from the existing environment, relocates only known OldRoot -> NewRoot receipt metadata, and asks uv to reinstall the same tool/version. The version is supplied to the command rather than rewriting the saved requirement, preserving extras/index/local/VCS intent encoded in the receipt. An uninterpretable receipt/version is reported and left untouched.

For a registered workspace, an explicit `UV_PROJECT_ENVIRONMENT` is accepted only when it resolves inside the workspace or Capsulenv root. Repair transactionally renames the old environment, creates a new environment and performs a locked reinstall:

```text
uv venv <environment> --project <workspace> --relocatable --no-progress
uv sync --project <workspace> --locked --reinstall --no-progress
```

`--relocatable` is feature-detected. Older uv falls back to full recreation + locked sync. If native recreation/sync fails, the partial new environment is removed and the previous environment restored.

## Pixi native repair

Registered Pixi workspaces are rebuilt with:

```text
pixi reinstall --all --locked --manifest-path <workspace>
```

Pixi global executables are backed by state under `PIXI_HOME`, but `pixi-global.toml` may contain version ranges and Pixi has no documented global lock file that Capsulenv can rely on. `pixi global sync` can therefore re-resolve dependencies and is **not** automatic by default.

Explicit opt-in:

```bat
capsulenv.cmd tools repair pixi --last --include-global
capsulenv.cmd tools repair all --last --include-global
```

Or set `ToolStorage.Relocation.Pixi.RepairGlobal = $true` in local config if re-resolution is acceptable on every relocation.

## Failure and retry

Automatic tool repair may need network access or a warm package cache. Non-strict relocation reports failed components but can allow the rest of rehydration to complete. The last relocation context remains available for retry:

```bat
capsulenv.cmd tools repair all --last --strict
```

`--strict` turns a tool/workspace repair failure into relocation failure before the new fingerprint is committed. `--skip-workspaces` excludes registered project environments; `rehydrate --skip-tool-repairs` skips the entire tool-native stage.

## One-way host seeding

Seeding imports selected host state into the portable ownership model once; it is not a machine profile or sync service.

```bat
capsulenv.cmd seed powershell
capsulenv.cmd seed git
capsulenv.cmd seed scoop
capsulenv.cmd seed weasel
capsulenv.cmd seed weasel restore
```

`seed powershell` copies the host PowerShell 7 CurrentUserAllHosts/CurrentUserCurrentHost profiles into the Scoop `pwsh` persisted `$PSHOME` profile files. The capsule must already have Scoop `pwsh` installed so that the persist contract exists. It does not bulk-copy host module directories and does not rewrite host-only absolute paths/imports. Existing non-empty portable profile files require `--force`.

`seed git` temporarily removes Capsulenv's process Git overlay, asks Git to read/flatten the real host global config, omits `include.*`/`includeIf.*`, keeps Capsulenv-owned SSH configuration separate, and excludes `credential.*`/`http.*.extraHeader` unless `--include-sensitive` is explicit. The result is written to `tool-data/git/config`.

`seed scoop` uses foreign Scoop's native export but keeps only apps+buckets in `tool-data/scoop/Scoopfile.json`; host Scoop config is not imported. Capture is allowed in either mode. In ShellOnly, `seed scoop --apply` requires the source host Scoop to remain readable and snapshots each missing installed version directory plus its persist data and available bucket repo into the capsule, then invokes only the ShellOnly portable reset path. It deliberately does **not** execute native `scoop import/install`, arbitrary manifest installer/pre/post hooks, shortcuts or persistent environment integration. Existing capsule apps/persist win and are not replaced. An inventory containing global apps requires an elevated terminal, and Capsulenv checks this before copying snapshot state. If the original app files are gone, ShellOnly apply fails closed. In User mode, `--apply` uses native `scoop import`, because normal Scoop current-user lifecycle integration is allowed by that mode.

`seed weasel` is the one seed with an explicit reverse operation because the target is an already installed Windows input method rather than another capsule-owned tool. Backup and restore both fail closed unless Weasel is confirmed from machine installation registry state and its server/deployer pair exists. Backup cold-copies the resolved Rime user-data tree to `tool-data/weasel/user-data`; an existing seed requires `--force`. Restore saves the current host tree first under machine/user-scoped integration state, replaces it transactionally, runs Weasel deployment, and rolls the host tree back if deployment fails. Capsulenv never installs Weasel and never treats an arbitrary `%APPDATA%\Rime` folder as sufficient installation evidence.

## Host-local scratch and offline cache

`CAPSULENV_SCRATCH` is deliberately non-portable and resolves under host `%TEMP%\capsulenv\<capsule-id>` (or the platform temporary root in non-Windows tests). Capsulenv does not overwrite `TEMP`/`TMP`; `eject` removes this scratch when possible.

Offline helpers operate on the portable Scoop state:

```bat
capsulenv.cmd offline status
capsulenv.cmd offline prefetch
capsulenv.cmd offline prefetch git nodejs python
capsulenv.cmd drift
```

`offline status` checks structural readiness of the existing installed environment and reports cache population; it does not promise arbitrary future installs will work offline. `offline prefetch` warms downloads for installed apps using the current local bucket snapshot without silently updating that snapshot. `drift` compares installed versions with local bucket manifests and performs no network update.
