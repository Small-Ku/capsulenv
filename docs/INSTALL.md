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

The same transition can be made after installation with `capsulenv.cmd install-user`; `enable-user` remains a compatibility alias. User mode backs up the exact pre-existing User environment under `.capsulenv\user-environment-backup.json` before changing it. `capsulenv.cmd restore-user` restores that snapshot and returns the capsule to ShellOnly mode. Re-running the installer without `-Mode` preserves the installation's current mode, including v0.8.x installations inferred from an existing user-environment backup.

## Scoop bootstrap

A fresh destination no longer needs a pre-copied Scoop tree. Before Scoop is first loaded, Capsulenv creates `scoop\config.json` so Scoop uses its portable config rather than `%USERPROFILE%\.config\scoop\config.json`. If Scoop core or Main is missing, bootstrap prefers Git and creates shallow single-branch repositories (`--depth 1 --single-branch`). It looks for capsule Git first and only then a Git executable inherited through PATH; host Git is transport only and does not select or modify a host Scoop root. If Git is unavailable or clone fails, the configured Scoop/Main archives are downloaded and expanded instead.

Bootstrap source URLs and depth live under `Scoop.Bootstrap` in `config\capsulenv.psd1`. `-SkipScoopBootstrap` exists for development/offline packaging checks; normal Windows installs should leave bootstrap enabled.

`PowerShell/Modules/` is the default portable private-module store. Capsulenv prepends it to `PSModulePath` and exposes its first configured module root as `CAPSULENV_MODULE_ROOT`; module repositories can consume that variable in their own build/install scripts without becoming capsulenv-managed runtime content.

Use `-IncludeDevelopmentFiles` only when the destination should remain able to rebuild the module itself:

```bat
install.cmd D:\Portable\capsulenv -IncludeDevelopmentFiles
```

Normal installed runtimes import `modules\Capsulenv\Capsulenv.psd1` directly. In a development checkout, set `CAPSULENV_FORCE_REBUILD=1` to ignore a prebuilt module and regenerate from `src/`.
