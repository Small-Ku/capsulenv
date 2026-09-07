# Development guide

This page defines source layout, testing, and documentation workflows. For everyday usage, see [USAGE](USAGE.md). For runtime rules, see [ARCHITECTURE](ARCHITECTURE.md). Non-negotiable repository invariants reside in `AGENTS.md`.

## Source layout

| Path | Purpose |
|---|---|
| `src/*.ps1` | Ordered module source files |
| `Capsulenv.psd1` | Module manifest |
| `Merge-ModuleScripts.ps1` | Deterministic module merger |
| `module-runtime/*.ps1` | Module entrypoint and runtime helper sources |
| `packaging/*.cmd` | Release and installed launcher templates |
| `scripts/capsulenv-dev.cmd` | Local development CLI entrypoint |
| `scripts/install.cmd` | Source installer entrypoint |
| `scripts/Build-Capsulenv.ps1` | Release bundle builder |
| `scripts/Install-Capsulenv.ps1` | Transactional installer |
| `scripts/Test-Capsulenv.ps1` | Unified testing and analysis entrypoint |
| `scripts/Analyze-Capsulenv.ps1` | Static architecture and compatibility analyzer |
| `scripts/Capsulenv.StaticAnalysis.ps1` | Custom AST ownership rules |
| `PSScriptAnalyzerSettings.psd1` | Windows PowerShell 5.1 analyzer policy |
| `build/CapsulenvTextResource.ps1`, `build/i18n/*.json` | Build-time text resources |
| `tests/` | Pester test suites and Windows PowerShell contracts |
| `config/` | Default schema and local configuration template |

Generated `.build/`, `modules/`, tool states, and user data must not be committed.

## Editing the module

Place new implementations in ordered `src/*.ps1` files. Keep the launcher thin; place environment and ownership logic in the module.

Mark public functions with `##MOD_EXEC## Export-ModuleMember`. The merger extracts exports and generates the manifest automatically.

`[[CapsulenvText:<key>]]` tokens resolve against `build/i18n/<language>.json`. The merger's `-Language` switch replaces quoted tokens with strings at build time. Unknown keys or tokens embedded within longer strings fail the build. Deployed runtimes do not perform catalog lookups.

Maintain Windows PowerShell 5.1 compatibility. Introduce compatible fallbacks before using newer PowerShell syntax or .NET APIs. Beware of StrictMode, native `$LASTEXITCODE`, collection enumeration, and stream encodings.

## Local development entrypoint

Run from the repository root:

```bat
scripts\capsulenv-dev.cmd help
scripts\capsulenv-dev.cmd doctor
```

The development entrypoint clean-merges module sources on demand, preventing stale builds from shadowing source edits. The merger copies `module-runtime/` to `modules/Capsulenv/runtime/`.

The repository root contains no runnable `capsulenv.cmd` or `install.cmd`. For deployment boundaries, see [DEPLOYMENT](DEPLOYMENT.md#deployment-boundary).

## Build a runtime

Follow the build instructions in [DEPLOYMENT](DEPLOYMENT.md#build-a-release-bundle). That page governs output constraints, file manifests, and installer transactions.

## Tests

The single test entrypoint is `scripts/Test-Capsulenv.ps1`. Requires **PSScriptAnalyzer 1.25.0+** and **Pester 6.1.0+**.

Full release gate (default):

```powershell
pwsh -NoProfile -File scripts\Test-Capsulenv.ps1
```

Fast profile for local development iterations:

```powershell
pwsh -NoProfile -File scripts\Test-Capsulenv.ps1 -Profile Fast
```

### Gate execution order

1. Execute PSScriptAnalyzer and custom AST ownership rules.
2. Execute the Windows PowerShell 5.1 runtime contract under `powershell.exe`.
3. Execute selected Pester test suites.

The 5.1 contract executes without Pester. It performs a clean build, imports the module, constructs the rehydration DAG, and verifies that `Plan`, `Apply`, and `Verify` callbacks are valid `ScriptBlock` objects.

`PSUseCompatibleSyntax` and `PSUseCompatibleCommands` cover runtime, module, and build scripts. Compatibility warnings fail the gate.

### Suite isolation

Every Pester suite runs in an isolated child process with dedicated temporary, build, artifact, and result directories.

| Option | Default | Purpose |
|---|---|---|
| `-ThrottleLimit` | 4 | Parallel process concurrency for dynamic ready queues |
| `-SuiteTimeoutSeconds` | 120 | Maximum execution time per suite |
| `-ThrottleLimit 1` | — | Sequential execution for deterministic differential runs |

Functional suites share an immutable test module build. Build, install, and text-resource suites create isolated builds. Passing logs write to test artifacts; failing output displays directly in terminal logs.

### Architecture rules and regression coverage

Encode static ownership boundaries in `scripts/Capsulenv.StaticAnalysis.ps1`. Every rule must provide matching rejection and acceptance fixtures in `tests/ArchitectureAnalysis.Tests.ps1`.

Rules cover command-free bootstrap, disallowing runtime `Import-PowerShellDataFile`, disallowing Scoop adapters and private overrides, shortcut namespace isolation, direct upstream dispatch, and session mode provenance. DAG diagnostics must remain within explicit diagnostic guards.

The analyzer also guards against direct property access on untrusted JSON records, provable mandatory null or empty arguments, and array `+=` inside loops.

Regression tests must verify real launcher argument pathways and ownership boundaries. Use isolated fixtures to test dispatch, projection repairs, host integrations, metadata parsing, and deployment.

Do not mutate real host Git configs, Windows services, browser profiles, or Scoop installations during tests.

## Adding or changing commands

Update the dispatcher, `Show-CapsulenvHelp`, and focused action help together. Add regression coverage through the launcher argument path. For formatting rules, see [CLI-UX](CLI-UX.md).

Runtime commands must resolve applications using installed app resolvers. For resolver rules, see [ARCHITECTURE](ARCHITECTURE.md#provisioning-and-runtime-separation). Before introducing persistent host changes, define ownership evidence and rollback methods.

## Configuration changes

`config/capsulenv.psd1` defines the default schema. User overrides reside in git-ignored `config/capsulenv.local.psd1`. Document public options in `config/capsulenv.local.psd1.example`.

`Scoop.RelocationRepairs` and `ToolStorage.ProjectLinks` replace entire allow-lists. Do not alter them into recursive merges without migration tests.

Distinguish file-valued and directory-valued variables. For initialization semantics, see [TOOLS](TOOLS.md#storage-classes).

## Documentation ownership

Direct readers to a single canonical page based on their question:

| Question | Canonical document |
|---|---|
| What is Capsulenv? How do I install and get started? | `README.md`: Installation, session modes, common commands, document index |
| How do I complete a specific task? | `docs/USAGE.md` (and `docs/USAGE.zh-TW.md`): Prerequisites, steps, commands, error recovery |
| Why does the runtime operate this way? | `docs/ARCHITECTURE.md`: Ownership, trust boundaries, execution model, DAG invariants |
| How are tool caches preserved and repaired? | `docs/TOOLS.md`: Storage paths, caches, seeding, uv/Pixi repair |
| How do I build and deploy the runtime? | `docs/DEPLOYMENT.md`: Release bundles, installer transactions, self-containment |
| How do I contribute and test code? | `docs/DEVELOPMENT.md`: Contributor workflows, static gates, testing practices |
| How should the CLI format output and errors? | `docs/CLI-UX.md`: Discovery, error hints, review UX, selector presentation |
| What changes are required when upgrading? | `docs/MIGRATION.md`: Upgrade actions for previous versions |
| Why were historical architectural decisions made? | `docs/convergence/`: Dated ablation and FMEA experiment records (source review only) |

README provides high-level overviews with safety reminders. USAGE omits exhaustive schema definitions. Technical specifications avoid duplicating tutorial steps. Migration guides state affected audiences and actions, linking to canonical rules.

Update only the canonical document responsible for a specific topic, then adjust links and brief summaries elsewhere. Do not create monolithic `technical.md` files that blur topic boundaries.

### Writing style

Follow [ASD-STE100 principles](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf) and [FAQ](https://www.asd-ste100.org/STE_faq.html).

- Express one main topic per sentence. State only one action per instruction step.
- State prerequisites before commands. State observable outcomes after commands.
- State who or what performs each action. Avoid passive voice clusters.
- Use identical terminology for identical concepts. Keep code identifiers intact.
- Target <= 20 words for English procedural sentences.
- Use tables for side-by-side comparisons; use numbered lists for sequential workflows. Use notes for supplementary context, not essential steps.
- Write each detailed rule once. Use descriptive section links elsewhere.

### Documentation verification

Verify relative links, heading anchors, command examples, and configuration keys before committing. Preserve existing anchors or update all inbound references.

When adding new documentation files, update the bundle manifest in `scripts/Build-Capsulenv.ps1`. Historical convergence logs remain in source checkouts.

When modifying packaging, run the complete test gate and verify documentation links within compiled release bundles. Do not execute live host integrations or real package installations while testing documentation.

Historical performance, ablation, and FMEA evidence resides in the [convergence directory](https://github.com/Small-Ku/capsulenv/tree/main/docs/convergence). These records do not define the current runtime contract.
