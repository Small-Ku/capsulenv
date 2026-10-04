# Repository notes

## Authority and review workflow

- Public Capsulenv issues own durable product and architecture decisions.
- `Small-Ku/private-tracker` may coordinate cross-repository work, bounded integration trains, and machine-specific execution.
- Private-tracker state does not define Capsulenv product authority. Public issues and PRs must remain understandable without it.
- Search for an existing issue or PR with the same goal before starting new review work.
- Continue an existing PR when it already owns the goal. Do not create a replacement PR to restart review.
- Keep exploration local while feasibility or value is unknown.
- Open the first authority PR when evidence shows the direction is technically feasible, materially useful, and has no known blocker likely to overturn it.
- PR-ready means the direction and current slice can be reviewed. It does not mean implementation is complete or accepted.
- Continue cleanup, broader validation, portability, edge cases, documentation, and review fallout on the same PR.
- Treat PR-branch commits as review and evidence carriers. Additive corrective commits are expected.
- Avoid cosmetic history rewrites after review has started.
- Use branch-by-abstraction when safe intermediate states can land.
- Use a bounded integration train only when an intermediate `main` state would be unsafe.
- Do not build a deep, long-lived PR-base chain.
- The maintainer later uses `Merge-NyaGitHubPullRequest` to squash the accepted tree into canonical history.

## Non-negotiable ownership invariants

- Scoop buckets/manifests are an external package metadata ecosystem. They are not Capsulenv's safety/runtime engine.
- Direct `scoop ...` must retain unmodified upstream semantics.
- Do not reintroduce source rewriting, transformed libexec, lifecycle fingerprint policy, private Scoop helper overrides, or a Scoop fork.
- PortableSafe package ownership belongs to Capsulenv under `packages/`, `package-persist/`, `shims/`, and `.capsulenv/packages/`.
- Before mutation, the planner must classify the complete dependency graph and accept only the bounded declarative subset.
- Arbitrary scripts/installers are TrustedExecution. Do not try to sanitize them into PortableSafe.
- Keep provisioning and runtime separate.
- Runtime consumers resolve provider-neutral installed app selectors and installed metadata/projections. Do not hard-code provisioning history.
  - Use `capsule/<app>` for Capsulenv ownership.
  - Use `scoop/<app>` for upstream Scoop.
- Scoop `User`/`Global` is provider-local scope. Expose `scoop:user/<app>` / `scoop:global/<app>` only when disambiguation is required.
- Legacy `user/` / `global/` aliases may remain accepted, but they must not define the primary model.
- ShellOnly is the default. Capsulenv activation/bootstrap/rehydrate may change process state but must not adopt or persistently rewrite a foreign host/user Scoop installation.
- A fresh Capsulenv invocation defaults to ShellOnly, even when persistent User ownership exists.
- Only explicit User entrypoints or process inheritance select User session semantics.
- The host-scoped ledger is restore authority. It does not select session mode.
- User HostIntegration is explicit and host-scoped. It must be reversible where Capsulenv claims ownership.
- PortableSafe Start Menu shortcuts must use `Programs\Capsulenv Apps\<capsule-id>\PortableSafe` and target the Capsulenv launcher.
- Do not target or override upstream Scoop's `Programs\Scoop Apps` / `shortcut_folder`.
- Legacy Scoop relocation compatibility may repair only `current`/`persist` projections whose active version and ownership can be proven from installed state.
- Do not load Scoop implementation `lib/*.ps1`.
- Ambiguous versions, normal directories, and diverged files fail closed and require explicit upstream Scoop repair.
- File projection repair may replace a copied normal file only when identity/content evidence proves it is the same projection; diverged data must not be overwritten.
- Persisted-file path repair is an explicit bounded allow-list. Do not recursively rewrite `persist`, binaries or unknown app state.
- Never copy, reserialize, or own Bitwarden vault/app state.
- Bitwarden setting integration may patch only source-verified top-level keys.
- Preserve unrelated JSON bytes, validate before replacement, and keep exact per-key restore state.
- Keep every persistent or machine-wide integration change attributable and backed up.
- Where Capsulenv claims reversibility, the change must be reversible.
- If the original state cannot be proven, do not invent a generic undo operation.

## Source and compatibility rules

- The installed/release `capsulenv.cmd` template lives under `packaging/` and stays a thin launcher.
- A development checkout must not expose root `capsulenv.cmd` or `install.cmd`. Source-only entrypoints live under `scripts/`.
- Environment and ownership logic belongs in the PowerShell module.
- Add module source under ordered `src/*.ps1`; mark public exports with the existing `##MOD_EXEC## Export-ModuleMember` convention.
- Windows PowerShell 5.1 compatibility is required. Avoid unguarded PowerShell 7-only syntax/runtime behavior.
- Installed runtime execution must be self-contained under `capsulenv.cmd` + `modules/Capsulenv`.
- Installed runtime must not depend on root `scripts/`, release-bundle metadata, or source/compiler files.
- Drive/host relocation is runtime rehydration. It is not an installer requirement.
- Installer/build code owns deployment only: merge/build and transactional replacement of managed program files.
- Installer/build code must not bootstrap Scoop, create mutable runtime state, or choose/apply User integration mode.
- Do not commit generated or machine state as source.
- This includes `.build/`, `modules/`, Scoop roots, caches/tool state, local config, SSH keys, Bitwarden data, browser profiles, and workspace data.
- The single test path is `scripts/Test-Capsulenv.ps1`: PSScriptAnalyzer 1.25.0+ compatibility analysis followed by Pester 6.1.0+.
- Keep the checked-in Windows PowerShell 5.1 syntax/command policy enabled.
- Add regression coverage for ownership boundaries and real CLI dispatch semantics, not only helper internals.
- Put statically expressible ownership boundaries in `scripts/Capsulenv.StaticAnalysis.ps1`.
- Add both rejecting and accepting synthetic fixtures in `tests/ArchitectureAnalysis.Tests.ps1`.
- Do not weaken a fail-closed gate into a string-presence test merely to make a refactor pass.

## Documentation ownership

- `README.md` is the user guide for installation, mode choice, common workflows, and discoverability.
- Do not put implementation proofs, internal state-machine detail, or test architecture back into README.
- `docs/ARCHITECTURE.md` owns runtime invariants and mode/Scoop/PowerShell/browser/Bitwarden internals.
- `docs/TOOLS.md` owns tool-data/cache/project-cache and uv/Pixi repair semantics.
- `docs/DEPLOYMENT.md` owns build/deployment/installer mechanics; `docs/DEVELOPMENT.md` owns source/test contributor workflow.
- `docs/MIGRATION.md` contains only upgrade actions from historical behavior. It should link to current canonical docs instead of restating them.
- When behavior changes, update the one canonical detailed page plus the minimal README command/user-facing description if needed; do not copy the same explanation across files.
