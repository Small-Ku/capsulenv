# Build and install

Development checkouts compile the module on entry with `Merge-ModuleScripts.ps1`. A deployed capsulenv should instead contain the deterministic merged module under `modules\Capsulenv` and does not need `src/`, tests, or the merge script.

Build a redistributable runtime tree:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build-Capsulenv.ps1 -OutputPath dist\capsulenv
```

Install or update it in a target directory:

```bat
install.cmd D:\Portable\capsulenv
```

Equivalent PowerShell invocation:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Install-Capsulenv.ps1 -Destination D:\Portable\capsulenv
```

The destination must be separate from the source repository; use the build script for a source-local `dist` tree. The installer updates only files recorded in `.capsulenv-install.json`. It preserves `scoop/`, `scoop-global/`, `cache/`, `tool-data/`, `project-cache/`, `workspace/`, `PowerShell/Modules/`, `.capsulenv/`, `config\capsulenv.local.psd1` and every unrelated file in the destination. A non-empty directory without the install marker requires `-Force`; this adopts the directory but still does not delete unrelated content. Managed files and the install marker are backed up before mutation; a failed update rolls them back while leaving mutable/unrelated data untouched.


## Install modes

The installer has two deliberately different ownership modes.

The default is **ShellOnly**:

```bat
install.cmd D:\Portable\capsulenv
```

Capsulenv creates and bootstraps only `D:\Portable\capsulenv\scoop`, establishes its own `scoop\config.json`, and injects `SCOOP`, `SCOOP_GLOBAL` and PATH only into Capsulenv processes. It does not adopt or update an existing user Scoop installation and does not persist Capsulenv's Scoop variables into the Windows User environment.

To make this capsule the current Windows user's Scoop installation, opt in explicitly:

```bat
install.cmd D:\Portable\capsulenv -Mode User
```

The same transition can be made after installation with `capsulenv.cmd install-user`; `enable-user` remains a compatibility alias. User mode backs up the exact pre-existing User environment under `.capsulenv\user-environment-backup.json` before changing it. `capsulenv.cmd restore-user` restores that snapshot and returns the capsule to ShellOnly mode. It also restores Capsulenv-owned Bitwarden global Git SSH configuration and any Windows `ssh-agent` service state previously changed by Capsulenv; restoring the latter requires elevation. Re-running the installer without `-Mode` preserves the installation's current mode, including v0.8.x installations inferred from an existing user-environment backup.

`restore-user` is intentionally not a generic undo engine for Scoop manifests. Start Menu shortcuts, manifest-defined environment keys, profile registrations, and other package lifecycle side effects explicitly created while operating in User mode remain Scoop/package-owned state unless that package provides its own reversible operation. Capsulenv only promises exact restoration for state it captured before changing.
Converting an existing ShellOnly capsule with `install-user` therefore does not unconditionally run `scoop reset *`. The transition installs the Scoop root/shims/environment at User scope first; future `scoop install` actions use normal User semantics. Run `capsulenv.cmd reset` explicitly in User mode when existing apps should materialize their shortcuts/environment integration. An actual relocation does run native reset automatically because already-owned User integration contains absolute targets that must be repaired.
Optional integration is not silently promoted just because the ownership mode changes. For example, a Bitwarden Git/OpenSSH setup created in ShellOnly remains an explicit session intent; after `install-user`, run `capsulenv.cmd bitwarden configure-git` (or `bitwarden setup`) if persistent User Git configuration is desired. When later running `restore-user`, a User-global Git configuration created by Capsulenv is restored and that recorded intent becomes process-only again.

Mode-sensitive integration is intentionally asymmetric:

| Integration | ShellOnly | User |
| --- | --- | --- |
| `SCOOP`, `SCOOP_GLOBAL`, `SCOOP_CACHE`, tool vars | Process only | Windows User environment |
| local/global Scoop shim dirs | Process PATH; proven foreign Scoop shim dirs removed from the session | User PATH + process PATH; original host shims backed up/restored |
| relocation reset | current/shims/persist only | native Scoop reset, including shortcuts/env |
| manifest hook replay | blocked | allow-listed replay permitted |
| Git for Bitwarden | process `GIT_CONFIG_*` overlay | reversible `git config --global` |
| Windows `ssh-agent` service | never changed | explicit/elevated setup may change it |
| Bitwarden desktop process | only capsule-owned executable; foreign instance causes refusal | same ownership check |
| Capsulenv browser command | explicit capsule profile + `-no-remote` | explicit capsule profile |

When a User-mode capsule changes drive letter, relocation also refreshes persistent User variables and removes Capsulenv-managed PATH entries from the previous drive. ShellOnly activation also strips only shim directories that can be attributed to a different inherited/User/Machine Scoop root, preventing command fall-through into a host Scoop while leaving the host PATH itself unchanged. It additionally removes only path entries nested under the relocation context's known old `ScoopRoot`/`ScoopGlobalRoot`, covering manifest `env_add_path` entries that native Scoop reset cannot remove once it only knows the new app directory. If Scoop `use_isolated_path` selects `SCOOP_PATH` or another path variable, that variable is backed up/restored and receives the same old-root cleanup. Capsulenv's own `scoop.ps1`/`scoop.cmd` launchers are relative to their shim directory and are normalized if an older installer left an absolute launcher. App `current`/persist junctions and app shims are recreated from the new roots. ShellOnly's temporary portable-reset command also overrides Scoop's internal `Add-Path`: upstream shim creation normally persists the shim directory to User/Machine PATH, but Capsulenv limits that helper to the current process during ShellOnly repair. Scoop-owned file persist links are delegated to Scoop's persist logic; Capsulenv-owned project-cache hardlinks use the stricter fingerprint rule and are repaired only when recorded content fingerprints prove ownership and the new link/store paths are still on the same volume.

## Scoop bootstrap

A fresh destination no longer needs a pre-copied Scoop tree. Before Scoop is first loaded, Capsulenv creates `scoop\config.json` so Scoop uses its portable config rather than `%USERPROFILE%\.config\scoop\config.json`. If Scoop core or Main is missing, bootstrap prefers Git and creates shallow single-branch repositories (`--depth 1 --single-branch`). It looks for capsule Git first and only then a Git executable inherited through PATH; host Git is transport only and does not select or modify a host Scoop root. If Git is unavailable or clone fails, the configured Scoop/Main archives are downloaded and expanded instead.

Bootstrap source URLs and depth live under `Scoop.Bootstrap` in `config\capsulenv.psd1`. `-SkipScoopBootstrap` exists for development/offline packaging checks; normal Windows installs should leave bootstrap enabled.

`PowerShell/Modules/` is the default portable private-module store. Capsulenv prepends it to `PSModulePath` and exposes its first configured module root as `CAPSULENV_MODULE_ROOT`; module repositories can consume that variable in their own build/install scripts without becoming capsulenv-managed runtime content.

Use `-IncludeDevelopmentFiles` only when the destination should remain able to rebuild the module itself:

```bat
install.cmd D:\Portable\capsulenv -IncludeDevelopmentFiles
```

Normal installed runtimes import `modules\Capsulenv\Capsulenv.psd1` directly. In a development checkout, set `CAPSULENV_FORCE_REBUILD=1` to ignore a prebuilt module and regenerate from `src/`.
