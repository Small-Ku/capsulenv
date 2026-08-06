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

The destination must be separate from the source repository; use the build script for a source-local `dist` tree. The installer updates only files recorded in `.capsulenv-install.json`. It preserves `scoop/`, `scoop-global/`, `cache/`, `tool-data/`, `project-cache/`, `workspace/`, `.capsulenv/`, `config\capsulenv.local.psd1` and every unrelated file in the destination. A non-empty directory without the install marker requires `-Force`; this adopts the directory but still does not delete unrelated content. Managed files and the install marker are backed up before mutation; a failed update rolls them back while leaving mutable/unrelated data untouched.

Use `-IncludeDevelopmentFiles` only when the destination should remain able to rebuild the module itself:

```bat
install.cmd D:\Portable\capsulenv -IncludeDevelopmentFiles
```

Normal installed runtimes import `modules\Capsulenv\Capsulenv.psd1` directly. In a development checkout, set `CAPSULENV_FORCE_REBUILD=1` to ignore a prebuilt module and regenerate from `src/`.
