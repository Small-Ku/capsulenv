# Architecture and ownership

這份文件是 Capsulenv 目前 runtime ownership 與 isolation semantics 的權威說明。使用者操作流程放在 [`../README.md`](../README.md)；tool/cache 細節放在 [`TOOLS.md`](TOOLS.md)；build/deployment 放在 [`DEPLOYMENT.md`](DEPLOYMENT.md)。

## Core ownership rule

Capsulenv 是 orchestration/repair layer，不是第二個 application data manager。

Scoop 是以下內容的 source of truth：app files、installed-version `manifest.json`／`install.json`、`persist` data、browser profiles、local/global shims、shortcuts，以及 manifest lifecycle scripts。Capsulenv 不新增平行的 `data/bitwarden`、browser profile tree 或另一份 PowerShell profile tree。

Capsulenv 自己只擁有四類狀態：

1. process/User environment integration 與其 reversible backup；
2. relocation identity/fingerprint、link/workspace registry；
3. 明確配置的 portable tool storage/project cache；
4. 對已知 Scoop-persisted text/config 的窄範圍 repair metadata。

因此「能由 owning tool 重建的 object」優先交回 Scoop、uv、Pixi 等 native lifecycle，而不是遞迴改寫 binary、shortcut、virtual environment 或 app data。

## Runtime layout

```text
capsulenv/
├─ capsulenv.cmd                    thin launcher
├─ modules/Capsulenv/               installed merged runtime module
├─ config/                          default + local override
├─ bin/                             capsule launch helpers / common tool bins
├─ PowerShell/Modules/              private user modules
├─ scoop/                           portable local Scoop root
├─ scoop-global/                    optional portable global Scoop root
├─ cache/                           rebuildable shared caches
├─ tool-data/                       persistent toolchains/config/global tools
├─ project-cache/                   backing store for explicit project links
├─ workspace/                       recommended portable source workspace
├─ .capsulenv/                      identity, relocation/user/link registries
└─ .capsulenv-runtime.json          built-runtime metadata
```

Development-only `src/`, `tests/`, `.build/` and merge/build scripts are not required by the minimal installed runtime. See [`DEVELOPMENT.md`](DEVELOPMENT.md).

## Two integration modes

Capsulenv has exactly two integration modes: **ShellOnly** and **User**. The mode is resolved for the current machine/user; it is not a global trust profile stored on the USB.

### ShellOnly

ShellOnly is the default. Activation sets `CAPSULENV_ROOT`, `SCOOP`, `SCOOP_GLOBAL`, `SCOOP_CACHE`, tool variables, module paths and PATH only in the Capsulenv process tree. It does not adopt, rewrite or update a foreign `%USERPROFILE%\scoop` installation.

PATH isolation removes only shim directories that can be attributed to another inherited/User/Machine Scoop root (including the conventional Windows Scoop roots), then prepends the capsule local/global shim directories. This prevents command fall-through into a host Scoop without replacing the rest of host PATH.

ShellOnly is not a sandbox. A user can still explicitly run software that changes the host. The guarantee is narrower: Capsulenv's own activation/bootstrap/rehydrate/Bitwarden integration does not persistently take over host Scoop/User integration.

### User

User mode explicitly registers this capsule as the current Windows user's Scoop environment. Capsulenv snapshots every environment value it owns before changing it and stores the backup under:

```text
.capsulenv/user-integrations/<machine-user-hash>/
```

The backup distinguishes "variable absent" from "variable present with value", so `restore-user` can restore the exact prior state for Capsulenv-owned variables/PATH entries. This scope includes Scoop roots/cache, tool-storage variables, `CAPSULENV_MODULE_ROOT`, `SSH_AUTH_SOCK`, configured custom variables, and the path variable selected by Scoop `use_isolated_path` when applicable. `PSModulePath` deliberately remains session-only.

The ledger is host-scoped. A reset-on-shutdown machine can erase its User environment while the USB keeps the previous ledger; a later `install-user`/`user-shell` snapshots the newly clean host state and takes ownership again. A ledger from another machine/user is never treated as proof that the current user is already integrated.

`restore-user` only reverses state Capsulenv actually captured or explicitly owns. It is not a generic undo mechanism for arbitrary Scoop manifest side effects such as package-specific shortcuts, registry entries or environment keys whose original state was never recorded.

Optional default-browser integration follows the same ownership rule. Its per-machine/user registration snapshot lives under that host integration state root, records capsule identity, host integration key, the exact `RegisteredApplications` value that existed before Capsulenv, and only the registry subtrees Capsulenv itself creates. A state file from another capsule or machine/user is rejected rather than used as delete authority.

## Capsule identity and relocation context

`.capsulenv/identity.json` provides a stable capsule identity independent of drive letter. Relocation state records the previous root/Scoop roots and is used to decide whether stale paths belong to this same capsule before mutation.

Managed references that live inside the capsule should prefer capsule-relative or `capsule://...` identity-based references. Host-scoped integration may also require the current machine/user fingerprint. This prevents a copied ledger or stale absolute path from becoming authority to overwrite unrelated host state.

A relocation is committed only after all required reset/repair stages succeed. Failed strict repairs therefore do not save a new fingerprint that would erase evidence of the old root. Rehydration-state replacement uses a same-directory temporary file plus a real rollback path; PowerShell/.NET `File.Replace` is never called with an empty backup path.

## Scoop bootstrap boundary

Before Scoop core is loaded for the first time, Capsulenv creates capsule-local `scoop/config.json`. This prevents Scoop from silently falling back to `%USERPROFILE%\.config\scoop\config.json`.

If Scoop core or Main is missing, bootstrap prefers Git and performs shallow single-branch clones; capsule Git is preferred, with inherited host Git accepted only as transport. If Git is unavailable or clone fails, configured archives are used as fallback. These repositories are live Scoop-owned runtime data, not Git submodules or Capsulenv source files.

`SCOOP` and `SCOOP_GLOBAL` are always explicit in a Capsulenv session. This also prevents operations such as reset from accidentally discovering `%ProgramData%\scoop` as an unrelated global root.

## PowerShell bootstrap and profile isolation

`capsulenv.cmd` first searches capsule Scoop installations for a physical PowerShell 7 executable, preferring local Scoop over portable-global Scoop and avoiding stale `current` links when possible. Only then does it fall back through capsule shims/inherited PATH and finally Windows PowerShell 5.1.

Entry points use process-scope `-ExecutionPolicy Bypass`; Capsulenv never calls `Set-ExecutionPolicy` or writes execution-policy registry values. Group Policy remains authoritative.

PowerShell package ownership remains with Scoop. The portable private-module root defaults to `PowerShell/Modules/`; it is prepended to the session `PSModulePath`, while its first entry is exposed as `CAPSULENV_MODULE_ROOT`.

ShellOnly starts its child PowerShell with `-NoProfile`, then explicitly dot-sources only capsule-owned Scoop `pwsh` `$PSHOME\profile.ps1` and `$PSHOME\Microsoft.PowerShell_profile.ps1`. It never treats a fallback host PowerShell executable's `$PSHOME` profile as capsule data. This prevents host CurrentUser profiles from running after Capsulenv has established isolation.

User mode keeps PowerShell's normal profile chain because User mode intentionally integrates with that Windows user. Both modes redirect PSReadLine history to `tool-data/powershell/PSReadLine/ConsoleHost_history.txt` after profile initialization.

## Relocation lifecycle

Scoop native `reset` is not suitable as a ShellOnly primitive because it may create Start Menu shortcuts and manifest-defined User/Machine environment integration. Capsulenv therefore branches by mode.

### ShellOnly Scoop command gateway

The capsule-owned `scoop.ps1`/`scoop.cmd` shims do not point directly at Scoop core in ShellOnly. They enter a Capsulenv gateway. Read-only/package-metadata commands still delegate to upstream Scoop, while commands that can create host integration (`install`, `update`, `uninstall`, `reset`, and `shim`) execute the exact upstream libexec implementation with a process-local policy layer injected after Scoop's libraries load. `import` is also intercepted because it invokes `scoop-install.ps1` internally; `install`, `download`, and `virustotal` have their automatic nested `scoop-update.ps1` calls routed back through the gateway. If an expected upstream insertion/dispatch boundary no longer matches, the gateway fails closed. It never patches the Scoop checkout on disk.

The ShellOnly policy shadows Scoop's `Set-EnvVar`, `Add-Path`, and `Remove-Path` so environment effects are process-only. Start Menu shortcut create/remove functions are no-ops. Capsule-owned app directories, installed manifests, `current` links, shims and `persist` remain Scoop-owned and continue to use upstream implementation. `scoop update` may recreate its own shim, so the gateway reasserts the capsule-owned shim after an intercepted command. Capsulenv's internal Scoop calls resolve the canonical upstream executable directly where a controlled internal primitive must avoid recursively entering the public gateway.

Arbitrary manifest lifecycle code is fail-closed. Before an install mutates app state, the policy preflights install-side `pre_install`, `post_install`, installer script and external-installer descriptors. Before uninstall/update removes old state, it separately preflights uninstall-side hooks. Approval is keyed by SHA-256 over the hook kind plus exact script/descriptor content in `Scoop.ShellOnlyLifecyclePolicy`; an upstream text change therefore becomes unreviewed automatically. `Allow` executes the exact reviewed code. `Skip` is available for reviewed optional hooks/cleanup (for example host registry teardown that ShellOnly never installed), but cannot bypass an actual installer script/external installer. The built-in policy contains narrowly reviewed fingerprints needed by the default Git, PowerShell Core and 7-Zip portable flows; local policy replacement may tighten or extend it after source review.

User mode continues to use normal upstream Scoop semantics because that mode explicitly delegates current-user integration to the capsule. The ShellOnly gateway is an isolation boundary, not a Scoop fork and not a second package-manager implementation.

### ShellOnly portable reset

ShellOnly uses a capsule-local temporary Scoop command that rebuilds only app `current` links, local/global shims and `persist` links/permissions. It intentionally skips Start Menu shortcuts, manifest environment integration and lifecycle hook replay.

During this reset Capsulenv shadows Scoop's internal path persistence helper with a process-only implementation. Rebuilding a shim must not cause upstream Scoop to persist the shim directory into User/Machine PATH merely because ShellOnly is repairing itself.

The temporary reset may itself be hosted by a Scoop app (normally capsule `pwsh`). Its running-process check therefore ignores only the reset process's own PID. Any other process from that app still goes through Scoop's normal running-process guard. This avoids a self-deadlock while preserving the safety boundary for independently running applications; the launcher uses a physical version-directory executable so repairing `current` does not invalidate the control process.

### User Scoop reset

User mode keeps upstream Scoop reset semantics because the current Windows user has explicitly delegated current-user integration ownership to this capsule: `current`, shims, Start Menu shortcuts, manifest environment entries and `persist` links are all rebuilt. Capsulenv invokes those Scoop primitives through a temporary User-reset command rather than upstream `scoop reset` directly, solely so the shared running-process guard can ignore the current Capsulenv control PID when that process itself is hosted by an app being reset (normally `pwsh`). An independently running app still goes through Scoop's normal running-process detection, but Capsulenv treats that app reset as deferred rather than failing the whole batch: other installed apps continue to reset, the rehydration state is saved with `PendingScoopReset=true`, and the next activation retries until all deferred apps have exited. Genuine reset errors still fail the operation. On drive relocation, persistent Capsulenv-managed User variables/PATH references are refreshed from the old capsule root to the new one. If `UserIntegration.DefaultBrowser` is configured, User synchronization also rewrites the owned browser registration from the current Scoop executable/profile paths, so a changed drive letter does not leave stale URL/file handlers.

Converting an existing ShellOnly capsule with `install-user` does **not** automatically run `scoop reset *` only to materialize existing UI integration. New package installs then use normal User semantics; `capsulenv.cmd reset` is the explicit operation when existing apps should materialize their native shortcuts/environment. Actual relocation does require automatic reset because existing User integration contains stale absolute targets.

### Manifest hook replay

Lifecycle hooks are always read from each app's **installed version** metadata, never substituted with a potentially newer bucket manifest.

Automatic replay is an allow-list in `Scoop.ReplayHooks`. `pre_install` is never automatically assumed safe or idempotent. ShellOnly rejects hook replay completely because arbitrary manifest code has no contract limiting writes to the capsule. User mode can explicitly replay approved hooks.

### Persisted text repair

Some persisted UTF text/JSON files contain absolute paths that the owning app does not repair itself. `Scoop.RelocationRepairs` is an exact allow-list of app-relative files. Repairs are bounded by path, format and maximum size; missing optional files are skipped, configured processes must be closed, JSON must parse before replacement, and the write is transactional.

Capsulenv never recursively scans all of `persist` and never applies blind OldRoot -> NewRoot replacement to binaries. The built-in browser rules exist only for known Firefox/Firefox ESR/Zen/LibreWolf text/config files.

## Shortcut-aware app launcher

`capsulenv.cmd app list/run` exists so ShellOnly can launch apps whose Scoop manifest only defines `shortcuts` without creating Start Menu `.lnk` files.

The launcher reads `manifest.json` and `install.json` under the installed app's `current` directory, selects architecture-specific shortcut metadata, expands Scoop shortcut variables such as `$dir`, `$original_dir` and `$persist_dir`, and starts the target directly. It does not read the latest bucket manifest and does not mutate Start Menu state.

If the same app exists in both local and portable-global roots, scope must be explicit (`user/<app>` or `global/<app>`). If an installed manifest has multiple shortcuts, the shortcut name must be selected explicitly.

## Browser ownership

Firefox/Firefox ESR/Zen/LibreWolf profiles stay in Scoop `persist`. Capsulenv never creates a second browser profile tree. LibreWolf follows the Scoop Extras portable layout and binds `scoop/persist/librewolf/Profiles/Default`; Capsulenv launches the actual Gecko executable rather than creating another profile store.

The dedicated browser commands bind the capsule-persisted profile explicitly. ShellOnly also uses `-no-remote`, preventing the request from being handed to a foreign host browser process. `--host` is the sole opt-in path for borrowing a machine-installed executable; resolution is product-specific, excludes both capsule Scoop roots, and never falls back across Firefox, Zen, and LibreWolf. Host-executable launches always apply the configured `-no-remote` isolation argument even in User mode, so they cannot silently hand the request to an already-running host-profile process. The profile remains capsule-owned, so browser/profile format compatibility is deliberately left visible to Gecko rather than bypassed with downgrade flags. User mode may rely on normal Scoop integration, but the explicit Capsulenv launcher remains available.

Browser persisted-file relocation uses only the configured `Scoop.RelocationRepairs` allow-list. User-mode manifest `post_install` replay may repair normal user profile registration; ShellOnly does not perform that host-user registration.


`UserIntegration.DefaultBrowser` is an explicit User-mode policy for Firefox, Zen, or LibreWolf. Capsulenv registers a unique per-user Default Programs application under `HKCU\Software\RegisteredApplications`, `HKCU\Software\Clients\StartMenuInternet`, and Capsulenv-specific ProgIDs under `HKCU\Software\Classes`. Its `http`/`https` and `.htm`/`.html` open commands invoke the real capsule Gecko executable while explicitly passing the Scoop-persisted profile; portable launchers such as `LibreWolf-Portable.exe` are therefore not responsible for preserving the association.

Capsulenv treats Windows `UserChoice` as user-owned state. It reads the selected ProgIDs to detect whether its registration is active, but does not write/replay the protected association hash. When the configured registration is not selected, User synchronization opens `ms-settings:defaultapps?registeredAppUser=...` so the final default choice remains in Windows Settings. Before `restore-user` deletes the registration, Capsulenv refuses if Windows still points `http`/`https`/HTML at those ProgIDs; the user selects another default first, then the exact prior `RegisteredApplications` value and owned registry trees can be restored without leaving dangling associations.

## Weasel seed ownership

Weasel is intentionally not a Capsulenv-managed application. `seed weasel` is allowed only when machine-level Weasel installation registry evidence resolves to an installation containing both `WeaselServer.exe` and `WeaselDeployer.exe`; merely finding `%APPDATA%\Rime` or a loose executable is insufficient. The current user data directory is resolved from `HKCU\Software\Rime\Weasel\RimeUserDir` when present, otherwise the normal `%APPDATA%\Rime` location is used.

Backup/restore treats the Rime user directory as a tree because dictionaries and generated state are not limited to YAML files. Capsulenv refuses to traverse reparse points, stops a running Weasel server before copying, and restarts it only if it had been running. Restore first snapshots the host tree under the machine/user-scoped `.capsulenv/user-integrations/<host-key>/weasel/restore-backups/`, swaps the portable tree into place, then invokes `WeaselDeployer.exe /deploy`. Failed deployment restores the pre-restore tree before returning an error.

## Bitwarden SSH ownership

Bitwarden app-data and vault state remain completely Scoop-persisted. Bitwarden is intentionally excluded from generic OldRoot text replacement.

Capsulenv's SSH Agent integration changes only the known top-level Desktop setting keys required to enable the agent and remember-authorization policy. Before mutation it stops only a Bitwarden executable proven to live under this capsule's Scoop app roots, records the previous literal/presence of each owned key, validates the JSON object, writes via a same-directory temporary file, and later restores/removes only those owned keys. It does not wholesale deserialize/reserialize or restore an old `data.json` over newer vault state.

Mode behavior is asymmetric: ShellOnly sets `SSH_AUTH_SOCK` and Git OpenSSH configuration only for the process tree and never changes the Windows `ssh-agent` service. User mode may create reversible global Git configuration and, when elevated and explicitly requested, back up/change the Windows service state. `restore-user`/Bitwarden restore use those exact backups; service restoration still requires elevation.

A foreign host Bitwarden process is not borrowed or terminated. Explicit setup/start refuses instead of crossing the capsule ownership boundary. Automatic Bitwarden startup is disabled by default; if a user explicitly enables `StartOnEnter`, activation treats a foreign host Bitwarden as a non-fatal conflict, skips only the automatic capsule launch, and still enters the Capsulenv shell.

## Tool and project storage

Tool-data/cache separation, package-manager environment mapping, project-cache hardlink/junction ownership, uv/Pixi native repair and workspace registration are intentionally specified only in [`TOOLS.md`](TOOLS.md). Do not duplicate those tables here or in README.

The architecture-level rule is simple: persistent tool state is not cache, shared caches may still have tool-specific linking semantics, and any object whose relocation semantics are owned by a tool should be repaired through that tool when possible.
