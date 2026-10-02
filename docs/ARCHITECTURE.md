# Capsulenv architecture

This page defines runtime ownership, trust levels, and relocation repair rules. For operational instructions, see [USAGE](USAGE.md). For packaging and deployment mechanics, see [DEPLOYMENT](DEPLOYMENT.md).

## Terms

| Term | Definition in this specification |
|---|---|
| capsule | An installed Capsulenv directory and its managed data |
| host | The computer and Windows user environment currently running the capsule |
| ownership | Proven authorization to modify and revert state based on verifiable evidence |
| provider | Installed package source and runtime owner: Capsulenv or upstream Scoop |
| projection | Derived links, shims, or environment variables constructed from installed state |
| rehydrate | Reconstructing runtime projections after relocation based on installed evidence |
| fail closed | Halting mutation when an operation cannot be proven compliant with invariants |
| DAG | Directed Acyclic Graph |

## Core ownership rule

Scoop buckets and manifests provide package metadata. Capsulenv classifies the complete package dependency graph before choosing an execution strategy.

```text
Scoop buckets / manifests
          |
          v
Capsulenv package planner
          |
    +-----+------------------+
    |                        |
    v                        v
PortableSafe             non-PortableSafe
Capsulenv executor       explicit upstream Scoop
    |                        |
    +-----------+------------+
                v
       installed runtime state
                |
     ProcessPlan / app resolver
     shims / persist / HostIntegration
```

Capsulenv owns files and state for PortableSafe packages. Upstream Scoop owns package operations executed directly or delegated explicitly.

Direct `scoop ...` invocations retain unmodified upstream semantics. Capsulenv must never introduce source adapters, transformed libexec scripts, private Scoop helper overrides, Scoop forks, or lifecycle fingerprint policies.

## Trust levels

| Level | Authorized operations | Durable state scope |
|---|---|---|
| Runtime | Resolving metadata, launching apps, establishing process environments | No persistent host modifications |
| PortableSafe | Bounded downloading, hashing, extraction, and projection construction | Inside capsule root |
| HostIntegration | Attributable, reversible Start Menu, browser, and SSH integrations | Host-scoped ledger with verifiable backup |
| TrustedExecution | Upstream Scoop lifecycle hooks, installers, third-party code | No reversibility guarantees |

Trust levels operate independently of ShellOnly and User session modes. User mode never converts third-party scripts into PortableSafe guarantees. ShellOnly mode never constrains direct user-initiated upstream Scoop execution.

## Runtime layout

| Path | Ownership and preservation policy |
|---|---|
| `capsulenv.cmd`, `modules/Capsulenv/` | Deployed runtime; update rules defined in DEPLOYMENT |
| `config/` | Default and personal configurations; local config must be preserved |
| `packages/<app>/<version>/` | Capsulenv package version directories |
| `packages/<app>/current` | Rebuildable version link derived from installed state |
| `package-persist/<app>/` | Package persistent storage; must be preserved |
| `shims/` | Capsulenv package execution entrypoints |
| `scoop/` | Upstream Scoop core, buckets, packages, and persist storage |
| `scoop-global/` | Optional capsule-local Scoop `-g` root |
| `PowerShell/Modules/` | User private PowerShell modules |
| `tool-data/`, `cache/`, `project-cache/` | Classified storage; rules defined in [TOOLS](TOOLS.md#storage-classes) |
| `workspace/` | User source repositories and working files |
| `.capsulenv/` | Identity, package states, link registries, and integration backups |

Scoop's global scope is a provider-local storage option. It does not represent machine-wide Capsulenv package ownership.

`.capsulenv/packages/<app>.json` records version, architecture, install path, persist mappings, shims, and capabilities using capsule-relative references.

## Package planner and PortableSafe subset

The planner inspects the manifest, architecture, and complete dependency graph before mutation. Every node classifies as `PortableSafe`, `TrustedScript`, `ExternalInstaller`, or `Unsupported`.

The safe executor runs only when all nodes in the closure classify as PortableSafe. All other plans report `TrustedExecutionRequired`.

| Manifest property | Capsulenv semantics |
|---|---|
| `url`, `hash`, `architecture` | Artifact selection and cryptographic verification |
| `extract_dir`, `extract_to` | Bounded archive extraction targets |
| `bin` | Capsulenv shims |
| `persist` | Persistent directory and file links |
| `env_add_path`, `env_set` | Process-level environment variables |
| `shortcuts` | HostIntegration shortcuts targeting the Capsulenv launcher |
| `depends` | Dependency graph edges |

The executor supports `http`, `https`, `file`, SHA-256 hashes, ZIP archives, and plain files. `extract_dir` applies only to ZIP archives. `env_set` must be a JSON object.

Relative paths, aliases, and shortcut names undergo boundary validation. Custom shortcut icons must reside within package projections.

The planner ignores recognized inert metadata. Unsupported execution properties (such as `cookie` or `psmodule`) block PortableSafe classification. Unknown properties at the manifest root or selected architecture block classification.

Arbitrary lifecycle scripts never belong to PortableSafe. Capsulenv does not rewrite scripts or substitute fingerprint allow-lists for trust boundaries.

### Review DAG and trust propagation

Review uses the planner's dependency graph to maintain two classifications:

- `DirectReviewRequired`: Whether the node itself requires review.
- `EffectiveReviewRequired`: Whether the node or any of its dependencies require review.

Direct blocker nodes propagate the TrustedExecution boundary upward to all ancestor packages. Review preserves root-to-blocker paths for auditing.

Upstream update review constructs the old graph from installed manifests and the new graph from bucket manifests. It compares packages, dependency edges, versions, sources, artifacts, extraction rules, projections, environment settings, shortcuts, and lifecycle scripts.

If historical dependency data is missing, removed-node and removed-edge evaluations are marked conservative. Missing evidence is never treated as a safe no-op. For CLI presentation, see [CLI-UX](CLI-UX.md#trusted-package-review).

## Provisioning and runtime separation

Runtime consumers resolve installed application metadata and projections. Bucket manifests govern provisioning only; they never override installed execution rules.

`capsule/<app>` selects Capsulenv-owned packages; `scoop/<app>` selects Scoop packages. When identical package names exist in both Scoop roots, disambiguate with `scoop:user/` or `scoop:global/`.

When prefixes are omitted, the resolver prefers Capsulenv packages. Legacy `user/` and `global/` aliases normalize to Scoop scopes. Browsers, Bitwarden, tools, and app commands share this resolver.

PortableSafe version trees retain `manifest.json` and `install.json` for runtime parsers. Capsulenv JSON state records provider identity, source fingerprints, and installed metadata fingerprints.

Runtime resolvers verify directory roots and metadata identities. If state drifts, cached ownership assumptions are invalidated.

## Shims

Capsulenv prepends its `shims/` directory before Scoop shims on the session `PATH`.

```text
shims/git.cmd
  -> ../capsulenv.cmd app exec capsule/git git -- ...
  -> resolve installed state
  -> apply package ProcessPlan
  -> execute target
```

Shims never embed absolute installation paths. Alias conflicts are resolved using ownership markers; shims belonging to other packages are never overwritten.

## Desired-state DAG execution and diagnostics

The execution contract specifies dependencies, plan decisions, execution affinities, concurrency policies, and resource ownership.

Plan building normalizes resource URIs into `ResourceClaims` shared between the scheduler and diagnostics. Active-pair admission does not repeat normalization.

Non-sequential execution utilizes a dynamic ready queue, scheduling eligible independent nodes immediately upon dependency completion.

Callbacks reading `Context.Outputs['producer']` must declare an explicit `DependsOn` constraint. Implicit ordering cannot substitute for data dependencies.

`ResourceConflicts`, `OwnershipDiagnostics`, and `ExecutionWaves` serve diagnostic inspection only. Executors must not depend on derived diagnostic data.

| API or execution path | Diagnostic behavior |
|---|---|
| `Get-CapsulenvDesiredStatePlan` | Omitted by default; enable via `-IncludeDiagnostics` |
| Public `Get-CapsulenvScoopRehydratePlan` | Included by default for plan inspection |
| `Invoke-*` in activation, rehydrate, and package install | Diagnostics disabled |

Static analysis enforces that conflict matrices and wave constructions reside within diagnostic guards. Changing diagnostic presentation must not affect scheduling correctness or concurrency.

## Stock Scoop boundary

The runtime bootstraps upstream Scoop core and the Main bucket on demand. The PowerShell session `PATH` places upstream `apps/scoop/current/bin/scoop.ps1` before Scoop shims.

For `cmd.exe`, Capsulenv provides a lightweight `scoop.cmd` trampoline that locates `../apps/scoop/current/bin/scoop.ps1` and delegates directly to the dispatcher.

Capsulenv creates no `scoop.ps1` wrapper. Bootstrap migration removes only legacy shims bearing Capsulenv ownership markers. The trampoline never alters Scoop semantics or injects transformation policies.

`app install --allow-trusted` delegates directly to upstream installation. Host state, registry modifications, and shortcuts created by upstream Scoop fall outside `restore-user` guarantees.

## ShellOnly and User session modes

### ShellOnly

Fresh standalone invocations default to ShellOnly. Setting `CAPSULENV_MODE=User` requires explicit User entrypoints or process inheritance.

ShellOnly establishes process-scoped environments. Manifest environment variables and shortcuts never modify Windows User or Machine registries. Capsulenv never adopts or mutates a foreign host Scoop installation.

### User

`user-shell` and `install-user` apply explicit, reversible HostIntegration. Backup and restore authority resides in `.capsulenv/user-integrations/<machine-user-hash>/`.

The ledger records restore evidence; it does not select future session modes. If original host state cannot be proven, Capsulenv does not invent speculative undo operations.

## Start Menu HostIntegration

PortableSafe shortcuts reside under:

```text
Programs\Capsulenv Apps\<capsule-id-prefix>\PortableSafe\<package>\...
```

The shortcut `.lnk` TargetPath points to `capsulenv.cmd`, passing arguments `app run capsule/<package> "<shortcut>"`.

Windows shortcuts record absolute launcher paths. Therefore, User synchronization rebuilds the capsule-specific namespace upon relocation.

Capsulenv never modifies Scoop's `shortcut_folder` or foreign `Programs\Scoop Apps`. Shortcuts created by upstream Scoop remain managed by upstream Scoop.

## Relocation projection repair

PortableSafe repair reconstructs `current` links, persist projections, shims, and User mode launcher shortcuts.

Persisted files bearing reparse or hardlink identities verify as projections. Normal files created during drive copies replace targets only when source and destination SHA-256 hashes match. Diverged data halts repair and preserves files.

The legacy Scoop adapter reads installed metadata only. It never loads Scoop implementation files under `lib/*.ps1` or invokes private Scoop helpers.

| Legacy state condition | Action taken |
|---|---|
| `current` points to an existing physical version directory under app root | Preserved |
| Target version matches local installed metadata | Repaired |
| Missing `current` link with exactly one metadata-verified version | Repaired |
| External target, reparse version, multiple candidate versions, normal `current` folder | Halts modification |
| Persisted file contents diverge | Halts modification |

When automatic rehydration encounters ambiguous legacy ownership, it preserves the application, records stable diagnostic IDs and remediation guidance, and continues remaining projections and activation.

Locked applications postpone repair and retry on subsequent activation. Ambiguous ownership requires explicit intervention via `doctor`.

Corrupted Capsulenv package projections fail immediately. Explicit `capsulenv reset` invocations maintain identical fail-closed invariants.

### Rehydration readiness

Generation fingerprints bind capsule identity, root paths, Scoop roots, host, and user. Each generation provides `.ready` and `.pending` markers:

1. Invalidate `.ready` before publishing detail JSON.
2. Commit detail JSON atomically.
3. Publish `.pending` if retryable items exist.
4. If no pending items remain, remove `.pending` and publish `.ready`.

Activation inspects these markers with `.pending` taking precedence. Concurrent activations perform at most one safe retry.

Subsequent detail JSON corruption does not invalidate verified projections; `doctor` reports corruption for explicit repair via `rehydrate`.

`capsulenv reset` reconciles projections. Arbitrary lifecycle scripts must execute through upstream Scoop explicitly.

## PowerShell control plane and profile isolation

The control plane runs under Windows PowerShell 5.1-compatible modules. Interactive shells may run PowerShell 7 provided by capsule packages, allowing `pwsh` updates without locking the control process executable.

ShellOnly mode prevents loading host CurrentUser profiles. Private modules are exposed through process `PSModulePath`. For profile seeding rules, see [TOOLS](TOOLS.md#one-way-host-seeding).

## Browser ownership

The browser resolver identifies executables and profile storage from installed applications. `Browsers` configuration specifies Gecko profile relative paths, arguments, and executable overrides.

The `--host` switch allows borrowing a host executable of the identical product while using the capsule profile. Default browser registration represents HostIntegration backed by registry backups; Capsulenv does not forge Windows `UserChoice` hashes.

## Bitwarden SSH ownership

Capsulenv never copies, reconstructs, or serializes Bitwarden vault and application state.

Setting patches modify verified top-level keys only, preserving exact per-key original byte values. Patches validate JSON structure before replacement and preserve unrelated bytes.

Executables and state paths resolve from installed app and persist projections. ShellOnly mode applies process-level Git and OpenSSH configurations without modifying the Windows `ssh-agent` service. User mode manages persistent backups and restorations.

## Lifecycle routine ownership

Capsulenv owns lifecycle events and executes configured commands or `App` + `BinName` targets. Successful runs update timestamps evaluated against `MinimumIntervalSeconds`.

Long-running schedules, network management, and synchronization policies belong to external orchestrators. Routines provide entrypoints only.

Child processes inherit `CAPSULENV_ROOT` and `CAPSULENV_LAUNCHER`. Orchestrators execute within this session context.

## Weasel seed ownership

Weasel integration provides host input method backup and restore. Formal installation evidence, cold backup, and rollback mechanics are defined in [TOOLS](TOOLS.md#one-way-host-seeding).

## Tool and project storage

Tool storage classes, project cache links, and native repair mechanics are defined in [TOOLS](TOOLS.md). Persisted text repair allows only entries in `Scoop.RelocationRepairs`, prohibiting recursive scanning of unknown application directories.

## Static architecture gates

Static ownership boundaries are enforced by `scripts/Capsulenv.StaticAnalysis.ps1`. Every rule requires rejecting and accepting synthetic fixtures. For test execution, see [DEVELOPMENT](DEVELOPMENT.md#tests).

## Host identity and depot retention

Capsulenv keeps capsule identity and desired state portable, while resolving a
host-local depot from an independent host record. A host record is keyed by a
stable machine/user integration key and never by the portable root or drive
letter.

Unknown hosts resolve to retention = ephemeral by default. The ephemeral
placement is namespaced by host key, capsule identity, and the current boot
epoch, so a valid realization can be reused during one host lifetime without
making reboot/reimage persistence part of correctness. No shutdown cleanup hook
is required.

Persistent placement requires an explicit host enrollment/tag such as home. An
enrolled host may provide a stable local depot root, including a custom local
volume. Portable state is not copied into this depot merely to simplify
cleanup, and a stale host-local record never overrides portable desired state.

The host placement foundation only resolves and materializes layout. Program
resolution, immutable generations, activation, and integration ownership remain
separate boundaries implemented by the downstream architecture issues.

# Program resolution boundary

Program requirements are portable desired-state records; resolved executable,
provider, scope, version, provenance, and lifecycle ownership are host-local
derived results. Legacy `capsule/<app>` package roots remain portable storage
and are not relabeled as `capsulenv-local` until #12 publishes a validated host
realization/generation source.

Exact versions compare the normalized package-version identity, including
prerelease/build suffixes. Range checks use the numeric base only when the
version grammar is valid; version-policy candidates with invalid versions are
rejected diagnostically rather than coerced to `0.0.0.0`.

# Program requirements and provider resolution

Program requirements are explicit records containing the requested name,
version policy, capabilities, executable selection metadata, and allowed
providers. Resolution is read-only and deterministic: compatible trusted host
Scoop is preferred, followed by a compatible Capsulenv-local realization, seed,
and finally an explicitly supplied provider deployment. Arbitrary PATH entries
are not package satisfaction.

The selected record carries the concrete executable, root, provider, scope,
version, provenance, trust, and lifecycle ownership. Reusing a trusted host
Scoop app does not upgrade, rewrite, or take ownership of the host
installation. The resolve command exposes this decision without performing
repair or deployment.
