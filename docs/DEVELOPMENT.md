# Development guide

這份文件說明 source checkout 的結構、build/test workflow 與 contributor conventions。Runtime 使用方式見 [`../README.md`](../README.md)；ownership invariants 見 [`ARCHITECTURE.md`](ARCHITECTURE.md)。Source checkout 另有根目錄 `AGENTS.md`，保存 agent-specific hard rules；minimal runtime 不依賴該檔案。

## Source layout

```text
src/*.ps1                         Capsulenv module source, ordered by filename
Capsulenv.psd1                    module manifest
Merge-ModuleScripts.ps1           deterministic module merger
module-runtime/*.ps1               module-owned entrypoint/helper resource sources
scripts/Build-Capsulenv.ps1       produce redistributable release bundle
scripts/Install-Capsulenv.ps1     transactional runtime installer/updater
scripts/Analyze-Capsulenv.ps1     Windows PowerShell compatibility + architecture analysis
scripts/Capsulenv.StaticAnalysis.ps1 testable custom AST ownership rules
scripts/Test-Capsulenv.ps1        single analysis + Pester test entrypoint
PSScriptAnalyzerSettings.psd1      checked-in WinPS 5.1 analyzer policy
tests/*.Tests.ps1                 Pester coverage
config/capsulenv.psd1             default runtime configuration
config/capsulenv.local.psd1.example local override example
```

A development checkout may build/merge the module on entry. `Merge-ModuleScripts.ps1` copies `module-runtime/*.ps1` into generated `modules/Capsulenv/runtime/`, so a deployed runtime imports and launches entirely from the module package; it does not need root `scripts/`, `src/`, tests, bundle metadata or the merger.

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

The release bundle contains installer/docs plus the portable payload. Its `InstallFiles` subset is narrower: launcher, config/bin helpers and the generated module package. Development source/tests are excluded unless `-IncludeDevelopmentFiles` is explicit.

Build output may not overwrite the repository root. A source-local output must stay under `dist/`; this is deliberately enforced because the builder replaces its output tree.

Detailed managed-file/update semantics are canonical in [`DEPLOYMENT.md`](DEPLOYMENT.md).

## Tests

`scripts/Test-Capsulenv.ps1` is the single test entrypoint. Development/test environments require **PSScriptAnalyzer 1.25.0+** and **Pester 6.1.0+**:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Capsulenv.ps1
```

The entrypoint runs static analysis before Pester. `PSScriptAnalyzerSettings.psd1` enables `PSUseCompatibleSyntax` for PowerShell 5.1 and `PSUseCompatibleCommands` against a Windows PowerShell 5.1 compatibility profile over runtime/module/build scripts. Development-only analyzer/Pester drivers are excluded from that runtime command profile because their tooling APIs intentionally target the supplied modern development toolchain. A compatibility diagnostic is a test failure, not a warning.

`Capsulenv.StaticAnalysis.ps1` adds fail-closed AST architecture gates for invariants that ordinary PSScriptAnalyzer cannot express. The current gates require the control bootstrap to remain command-free, forbid runtime `Import-PowerShellDataFile`, prevent runtime code from targeting the foreign Scoop `Programs\Scoop Apps` namespace, reserve Scoop's `shortcut_folder` override to the capsule-owned User policy and require that policy to keep the `Capsulenv Apps` namespace, require `Get-CapsulenvInstallMode` to stay command-free and select User only from process-scoped `CAPSULENV_MODE`, and reject direct member access on declared untrusted external JSON record variables such as uv's `$item`. When adding another external JSON ingestion boundary, register its record variable(s) in the analyzer rather than relying on StrictMode/runtime failures.

The custom rules are themselves tested with synthetic negative and positive fixtures in `tests/ArchitectureAnalysis.Tests.ps1`: each ownership rule must demonstrate that a representative forbidden implementation fails static analysis and its approved form passes. Pester then covers the corresponding runtime behavior plus source/module parsing, control-host `PSModulePath` contamination/shadowing regression, runtime build, first install/update preservation, installed-module smoke behavior, fresh-session ShellOnly defaults versus persistent User ownership, capsule-specific User Start Menu isolation, Scoop bootstrap/reset/replay boundaries, installed-manifest selector/executable semantics, external uv JSON/StrictMode tolerance, tool storage/relocation, browser/default-browser ownership, sing-box process/config ownership, Bitwarden scoped mutation and host-scoped integration state.

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
