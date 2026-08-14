# Development guide

這份文件說明 source checkout 的結構、build/test workflow 與 contributor conventions。Runtime 使用方式見 [`../README.md`](../README.md)；ownership invariants 見 [`ARCHITECTURE.md`](ARCHITECTURE.md)。Source checkout 另有根目錄 `AGENTS.md`，保存 agent-specific hard rules；minimal runtime 不依賴該檔案。

## Source layout

```text
src/*.ps1                         Capsulenv module source, ordered by filename
Capsulenv.psd1                    module manifest
Merge-ModuleScripts.ps1           deterministic module merger
scripts/Invoke-Capsulenv.ps1      PowerShell entrypoint used by capsulenv.cmd
scripts/Build-Capsulenv.ps1       produce minimal redistributable runtime
scripts/Install-Capsulenv.ps1     transactional runtime installer/updater
scripts/Test-Capsulenv.ps1        single Pester test entrypoint
tests/*.Tests.ps1                 Pester coverage
config/capsulenv.psd1             default runtime configuration
config/capsulenv.local.psd1.example local override example
```

A development checkout may build/merge the module on entry. A deployed runtime imports the prebuilt merged module under `modules/Capsulenv/` and does not need `src/`, tests or the merger.

## Editing the module

Add module implementation to the appropriately ordered `src/*.ps1` file instead of putting environment logic in `capsulenv.cmd`. The batch file must remain a thin bootstrap launcher.

Public functions/aliases are exported through the module merger. Mark export statements with the existing `##MOD_EXEC## Export-ModuleMember` convention so deterministic merge and generated manifest behavior remain consistent.

Module sources must remain compatible with Windows PowerShell 5.1. Avoid PowerShell 7-only language/runtime features unless there is a guarded compatibility path. Be especially careful around StrictMode, native `$LASTEXITCODE`, generic collection enumeration and encoding behavior shared by 5.1/7.x.

## Local development entrypoint

From the repository root:

```bat
capsulenv.cmd help
capsulenv.cmd doctor
```

Development entry uses source + deterministic merge as needed. Do not commit generated `.build/` or `modules/` output.

## Build a runtime

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build-Capsulenv.ps1 -OutputPath dist\capsulenv
```

The minimal runtime contains the launcher, prebuilt module, runtime scripts/config, README and shipped docs. Development source/tests are excluded unless `-IncludeDevelopmentFiles` is explicit.

Build output may not overwrite the repository root. A source-local output must stay under `dist/`; this is deliberately enforced because the builder replaces its output tree.

Detailed managed-file/update semantics are canonical in [`DEPLOYMENT.md`](DEPLOYMENT.md).

## Tests

Pester 6.1.0+ is the only test path:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Capsulenv.ps1
```

Tests cover static safety invariants, source/module parsing, runtime build, first install/update preservation, installed-module smoke behavior, ShellOnly/User isolation, Scoop bootstrap/reset/replay boundaries, app launcher metadata semantics, tool storage/relocation, browser ownership, Bitwarden scoped mutation and host-scoped integration state.

Where possible, test dangerous integration through isolated fixtures/static invariants instead of changing the real test host's global Git config, services, browser profiles or Scoop installation.

## Adding or changing commands

CLI help in `Show-CapsulenvHelp` is the command contract users can query with `capsulenv.cmd help`. Keep dispatch/usage text in sync with the implementation and add tests through the same argument path used by the real launcher.

When a feature wraps Scoop metadata, use the installed app's `manifest.json`/`install.json` as the runtime source of truth. Bucket manifests may have advanced since installation and must not silently replace installed-version semantics.

For operations that mutate host/User state, first define an explicit ownership proof and reversible backup. If the original state cannot be established, do not invent a generic restore operation.

## Configuration changes

`config/capsulenv.psd1` is the default schema. User overrides belong in git-ignored `config/capsulenv.local.psd1` and should be represented in `config/capsulenv.local.psd1.example` when they are intended public extension points.

`Scoop.ReplayHooks`, `Scoop.RelocationRepairs`, `Scoop.ShellOnlyLifecyclePolicy` and `ToolStorage.ProjectLinks` are allow-list style configuration and have replacement semantics where documented by the loader/config example; do not casually change them to recursive merge semantics without migration coverage.

Directory-valued and file-valued tool variables are intentionally separate. File variables must not be initialized as directories.

## Documentation ownership

To prevent the previous documentation drift, each topic has one canonical home:

| Topic | Canonical file |
|---|---|
| install/use/common workflows | `README.md` |
| runtime ownership, modes, Scoop/PowerShell/browser/Bitwarden internals | `docs/ARCHITECTURE.md` |
| tool storage, caches, project links, uv/Pixi repair | `docs/TOOLS.md` |
| build/deploy/installer mechanics | `docs/DEPLOYMENT.md` |
| source/test/contributor workflow | `docs/DEVELOPMENT.md` |
| upgrade actions from old versions | `docs/MIGRATION.md` |
| non-negotiable repository/agent invariants | `AGENTS.md` |

README should explain **what a user should do**, not reproduce implementation proofs. Developer docs may link to one another but should not copy the same ownership paragraphs/tables. Migration notes should describe only what changes an upgrader must perform, then link to the current canonical behavior.
