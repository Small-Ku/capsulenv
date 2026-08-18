# Repository notes

## Non-negotiable ownership invariants

- Scoop is the single source of truth for application files, installed manifests, `persist` data, browser profiles, shims, shortcuts and manifest lifecycle scripts. Never add a parallel Capsulenv app-data/profile store.
- ShellOnly is the default. Capsulenv activation/bootstrap/rehydrate may change process state but must not adopt or persistently rewrite a foreign host/user Scoop installation.
- A fresh Capsulenv invocation defaults to ShellOnly even when persistent User ownership exists. Only explicit User entrypoints/process inheritance select User session semantics; the host-scoped ledger is restore authority, not session-mode selection.
- User-mode Scoop shortcuts must use a capsule-specific Start Menu namespace and must never share or overwrite a foreign Scoop `Programs\Scoop Apps` namespace.
- User integration must be explicit, host-scoped and reversible from an exact backup under `.capsulenv/user-integrations/<machine-user-hash>/`. Never treat mode as a capsule-global trust profile.
- Relocation repair must use the owning tool whenever possible. ShellOnly Scoop repair may rebuild only capsule-owned `current`/shim/persist links; User mode may use native `scoop reset`.
- Lifecycle replay must read each installed version's `manifest.json` and `install.json`, never substitute the latest bucket manifest. Arbitrary `pre_install` replay is never safe-by-default.
- Persisted-file path repair is an explicit bounded allow-list. Do not recursively rewrite `persist`, binaries or unknown app state.
- Never copy, reserialize or own Bitwarden vault/app state. Bitwarden setting integration may patch only source-verified top-level keys, preserve unrelated JSON bytes, validate before replacement and keep exact per-key restore state.
- Keep every persistent/machine-wide integration change attributable, backed up and reversible where Capsulenv claims reversibility. If the original state cannot be proven, do not invent a generic undo operation.

## Source and compatibility rules

- `capsulenv.cmd` stays a thin launcher. Environment/ownership logic belongs in the PowerShell module.
- Add module source under ordered `src/*.ps1`; mark public exports with the existing `##MOD_EXEC## Export-ModuleMember` convention.
- Windows PowerShell 5.1 compatibility is required. Avoid unguarded PowerShell 7-only syntax/runtime behavior.
- Installed runtime execution must be self-contained under `capsulenv.cmd` + `modules/Capsulenv` and must not depend on root `scripts/`, release-bundle metadata, or source/compiler files. Drive/host relocation is runtime rehydration, never an installer requirement.
- Installer/build code owns deployment only: merge/build and transactional replacement of managed program files. It must not bootstrap Scoop, create mutable runtime state, or choose/apply User integration mode.
- Generated `.build/`, `modules/`, Scoop roots, caches/tool state, local config, SSH keys, Bitwarden data, browser profiles and workspace data are not source files and must not be committed.
- PSScriptAnalyzer 1.25.0+ compatibility analysis followed by Pester 6.1.0+, both via `scripts/Test-Capsulenv.ps1`, is the single test path. Keep the checked-in Windows PowerShell 5.1 syntax/command policy enabled and add regression coverage for ownership boundaries and real CLI dispatch semantics, not only helper internals.
- Ownership boundaries that can be expressed statically belong in `scripts/Capsulenv.StaticAnalysis.ps1`, with both rejecting and accepting synthetic fixtures in `tests/ArchitectureAnalysis.Tests.ps1`. Do not weaken a fail-closed gate into a string-presence test merely to make a refactor pass.

## Documentation ownership

- `README.md` is the user guide: installation, mode choice, common workflows and discoverability. Do not put implementation proofs, internal state-machine detail or test architecture back into README.
- `docs/ARCHITECTURE.md` owns runtime invariants and mode/Scoop/PowerShell/browser/Bitwarden internals.
- `docs/TOOLS.md` owns tool-data/cache/project-cache and uv/Pixi repair semantics.
- `docs/DEPLOYMENT.md` owns build/deployment/installer mechanics; `docs/DEVELOPMENT.md` owns source/test contributor workflow.
- `docs/MIGRATION.md` contains only upgrade actions from historical behavior. It should link to current canonical docs instead of restating them.
- When behavior changes, update the one canonical detailed page plus the minimal README command/user-facing description if needed; do not copy the same explanation across files.
