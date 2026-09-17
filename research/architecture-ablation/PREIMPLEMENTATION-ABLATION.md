# Pre-implementation ablation and failure-mode review for #7

## Scope

This pass reviews the proposed production refactor in issue #7 against the current `main` integration logic before implementation. It intentionally does not re-open the already-deferred Windows/NTFS/Scoop compatibility campaign. The goal is narrower: find missing product/runtime semantics, ablate new abstractions that are not needed, and identify current fallback behavior that should not be carried into the new architecture.

Current source surfaces inspected include `30-Environment.ps1`, `32-PowerShell.ps1`, `45-PackageHostIntegration.ps1`, `50-Bitwarden.ps1`, `60-Browser.ps1`, `62-DefaultBrowser.ps1`, `64-Routine.ps1`, `72-Lifecycle.ps1`, and `config/capsulenv.psd1` on `main`.

Real Linux experiments in this addendum use actual processes, `/proc` process identity, OS file locks, concurrent writers and real filesystem detach/rename behavior. They are architecture evidence, not Windows API validation.

## Missing semantics discovered before implementation

### 1. Session ownership must replace executable-path ownership

Current `Get-CapsulenvOwnedProcesses` defines ownership by whether the executable path is under the capsule root. That is incompatible with #7's central host-local-program model:

- a capsulenv-launched host-local browser/pwsh/sing-box process is outside the portable root, so the current rule misses it;
- changing the rule to "under the host depot" would claim unrelated/foreign processes using the same host-local executable.

The new core therefore needs a small **session ledger**, not broader process scanning. A process record should include at least:

- session ID;
- PID;
- process-start identity (start time/ticks or equivalent nonce), not PID alone;
- role (`shell`, `app`, `service`, etc.);
- ownership (`owned` vs attached/foreign);
- resources/state leases held by the process.

Eject/stop must act on ledger ownership, never merely executable provenance.

### 2. Portable mutable state needs an explicit concurrency/lease policy

`State(scope=portable)` is insufficient by itself. Browser profiles and other mutable stores cannot safely be opened by two capsule sessions at once.

Each binding should declare a concurrency policy, minimally:

- `exclusive` — one live writer/session, appropriate for Gecko profiles;
- `shared-read` — multiple readers but no writer;
- `unmanaged` — capsulenv does not serialize access.

Use OS-held locks/leases where possible. A sentinel lockfile whose mere existence means "locked" is a stale-lock failure after process crash.

Eject must block or warn while an exclusive portable-state lease is live even when the executable itself is host-local.

### 3. `SessionService` must not be implemented as a detached `Routine`

Current generic Routine behavior treats detached execution as exit code 0 immediately. It has no required health condition and no owned-process lifecycle record. That is adequate for best-effort hooks but not for sing-box or another service whose availability affects the session.

Keep `Routine` only as an optional hook surface if it remains useful. A real `SessionService` needs:

- resolve program;
- start;
- readiness/health test;
- process identity registration;
- optional dependency ordering;
- explicit required/optional policy;
- stop-on-exit/eject only when capsulenv owns it.

`OnRehydrate` should not survive as a core lifecycle concept once broad rehydrate stops being the architecture center.

### 4. Portable desired requirements and per-host resolution are different authorities

Reusing host-installed programs creates a distinction that #7 currently under-specifies:

- **portable desired state**: what capability/program/version/trust policy is acceptable;
- **host resolution/generation**: the concrete executable, provider, version and path selected on this host.

Do not treat an arbitrary PATH hit as satisfying a portable requirement. Program resolution needs provider trust and version/capability constraints.

Per-program version policy should be explicit rather than one global rule. Examples:

- developer compiler/toolchain: often exact/pinned;
- browser/Bitwarden: often host-managed but must satisfy compatibility policy;
- host system utility: may be capability/version-range based.

Capsulenv must not automatically upgrade or mutate a host-owned Scoop/system program just because it was selected for reuse.

### 5. Persistent `UserIntegration` cannot point directly at removable paths

Current Start Menu package shortcuts target the portable `capsulenv.cmd`. Current default-browser registration embeds a concrete browser executable and portable profile path. After eject/removal those persistent registrations are inherently dangling.

Under #7, persistent User integration must choose one of two explicit models:

1. install a **host-local integration bridge/pinned launcher** keyed by capsule identity, which can report that the capsule is absent or use an explicitly pinned local copy; or
2. do not create persistent integration at all unless the capsule has an appropriate host-local pinned representation.

Do not add a chain of fallback guesses when the device is absent. Failing diagnostically is preferable to silently opening an unrelated host profile.

### 6. Do not add a generic host-mirror/sync layer for portable state

A tempting response to portable SSD writes is to copy mutable portable state to the host and sync it back later. That creates a second authority and introduces crash-before-sync, stale-mirror and conflict semantics.

Default policy should instead be:

- direct portable state for data that genuinely must travel and is safe for the application's own durability model;
- host-local cache/temp/state when the application natively supports separating it;
- host/home-local state for data that does not need to travel;
- no generic bidirectional directory synchronization in the core.

Browser adapters may later redirect known cache locations host-locally if the browser supports that safely, but the generic Binding abstraction should not invent file synchronization.

### 7. Host depot retention is a host/invocation policy

A repeat visit benefits strongly from retaining local program realizations. A borrowed/trusted-but-temporary machine may instead require minimal residue. Therefore host deployment retention should not be hard-coded.

Suggested policy:

- home/known host: persistent depot by default;
- unknown host: configurable `persistent` vs `ephemeral`/cleanup mode;
- portable user state is never copied into the host depot merely to make cleanup easier.

### 8. Integration criticality must be explicit

Current code contains several ad-hoc fail/warn/return choices. Replace them with resource policy rather than more fallback branches:

- interactive pwsh: normally required;
- browser integration: usually optional until invoked;
- Bitwarden SSH integration: optional or required according to capsule policy;
- sing-box: required only if the session/network policy says so.

Required resources fail closed or trigger deploy. Optional resources degrade with a diagnostic. Do not silently replace a required PowerShell 7 shell with the control host simply because pwsh is missing.

### 9. Bootstrap dependencies need a narrow pre-network tier

If sing-box/proxy is required to reach package providers, acquiring sing-box through that same network path is circular. Solve this without a generic orchestration DAG:

- existing trusted host program, or
- portable seed/bootstrap payload,
- then establish bootstrap networking,
- then normal provider acquisition.

### 10. Home/trusted-host classification must be explicit

An optional `home` state scope requires an enrolled host identity/tag. Do not infer "home" from paths, network, hostname similarity or previous caches. Host-local placement and persistent User integration can use this explicit host record.

### 11. Host-local GC and generation retention need a simple policy

Package realizations are immutable, but without GC every update accumulates local copies. Keep:

- current generation;
- a small configurable number of previous complete generations or explicitly pinned generations;
- realizations referenced by those generations;
- nothing else after GC unless retained as provider/cache data.

Do not add a second package-index authority solely for GC; derive reachability from generation manifests.

### 12. Sensitive-state residue is an adapter concern, not a promise of zero host traces

Browser profiles, credentials and shell history may be sensitive. Direct portable binding avoids intentionally copying them into the host depot, but host OS/app temp files can still exist. The core should make placement explicit and avoid unnecessary copies; adapters may provide best-effort cleanup where justified. It should not claim forensic zero-residue guarantees.

## Real ablation results

### A. Process ownership: path scan vs session ledger

Two live processes were launched from the same host-local program path; only one belonged to the capsule session.

| Rule | Result |
|---|---|
| current capsule-root path rule | missed the owned host-local process |
| naive host-depot path rule | classified both owned and foreign processes as owned |
| session ledger + process start identity | selected exactly the owned process |

A stale PID record was also simulated against a live unrelated process. PID-only identity would accept it; PID + process-start identity rejected it.

**Decision:** executable-path process ownership is dominated. Replace it with session ledger ownership. Keep path/provenance only as diagnostics.

### B. Ownership lookup cost

80 real Linux repetitions:

| Lookup | p50 | p95 |
|---|---:|---:|
| scan `/proc` and inspect process executable paths | ~1.0 ms | ~1.4 ms |
| read/validate one session ledger record | ~0.15 ms | ~0.31 ms |

The ledger is not justified by performance alone, but it is both more correct for host-local programs and cheaper in this workload.

### C. Detached Routine vs health-checked SessionService

A detached process that immediately exits with code 7 was launched. Current Routine semantics would report detached invocation success immediately; waiting for service readiness/health correctly detected the failure. A healthy test service exposed readiness and was detected.

**Decision:** generic detached Routine is not a SessionService fallback. Keep generic hooks non-authoritative; use explicit service health/ownership semantics for sing-box-like processes.

### D. Portable mutable-state concurrency

Two real processes performed a coordinated read-modify-write on the same portable-state file.

- without an exclusive lease/lock: expected counter `2`, observed `1` (lost update);
- with OS lock + atomic capsulenv metadata write: observed `2`.

A crash while using an existence-only sentinel lock left a stale lock file. An OS file lock was automatically released and could be reacquired after the crashing process exited.

**Decision:** state bindings need concurrency policy and OS-held lease semantics. Do not use lockfile existence as authority.

### E. Provider-resolution fallback

A path-first candidate set contained an untrusted fake Firefox version 999 before a trusted host Scoop Firefox 130. Path-first resolution selected the wrong executable. Trust+version constrained resolution selected the compatible host Scoop program. When the host program was newer but outside the allowed compatibility range, constrained resolution selected the compatible capsulenv-local realization instead.

**Decision:** no arbitrary PATH fallback for satisfying a capsule Program requirement. Resolution must enforce trust/provenance and version/capability constraints.

### F. Host depot retention

An 8 MiB real payload was deployed locally:

- first copy: ~10 ms in this environment;
- retained repeat existence/activation check: ~0.13 ms;
- cleanup + redeploy: ~4.1 ms (page-cache-sensitive and not a production timing claim).

**Decision:** retained host realizations are clearly valuable for repeat visits, but cleanup/residue is a product policy. Expose retention rather than hard-code either behavior.

### G. Generic host mirror vs direct portable state

8 MiB mutable state, 800 random 4 KiB writes:

- direct portable mutation: 3.28 MiB logical writes to portable state;
- whole-file host-mirror sync-back: 8 MiB portable write plus 3.28 MiB host mutation;
- crash before sync: portable copy remained stale;
- two stale host mirrors followed by whole-file sync: last writer erased the other mirror's independent change.

This workload also shows that a mirror can write *more* to the portable device than direct mutation; other write-heavy workloads may invert that number, but the synchronization failure modes remain.

**Decision:** reject generic host-mirror/bidirectional-sync as a core abstraction. Prefer direct portable authority plus app-native host-local caches where safe.

### H. Persistent UserIntegration target

A persistent integration target pointing directly at a simulated removable capsule existed before detach and became dangling immediately after the capsule directory was detached. A host-local integration bridge remained addressable.

**Decision:** persistent UserIntegration must be host-local/pinned or not persistent.

## Existing fallbacks/compatibility behavior not to carry forward blindly

1. **Broad startup repair / rehydrate** — already rejected from the healthy fast path by prior campaign.
2. **Executable-path process ownership** — remove from authority/lifecycle decisions; retain only diagnostics.
3. **Browser `--host` special mode** — once Program resolution is provider-agnostic, host reuse becomes normal resolution rather than a special launch flag.
4. **Browser profile ownership through Scoop persist** — replace with explicit State binding. Any actual profile path migration remains adapter-specific and explicit, not startup-wide repair.
5. **Bitwarden foreign-process rejection** — retain for actions requiring lifecycle ownership, but do not reject a trusted host Bitwarden merely to attach to its SSH-agent integration.
6. **Interactive PowerShell fallback to the current control process** — keep as bootstrap/control-plane escape hatch only; do not silently use it as the requested interactive runtime.
7. **Detached Routine success = spawn succeeded** — not acceptable for SessionService. Remove as service fallback.
8. **`OnRehydrate` generic hook** — retire with broad rehydrate; replace concrete needs with deploy/migrate/repair/service semantics.
9. **Persistent shortcuts/default-browser commands pointing at removable paths** — replace with host-local UserIntegration bridge or require pinned host representation.
10. **Generic portable ToolStorage rooted under `CAPSULENV_ROOT`** — replace with explicit portable/host/home placement. This should delete many relocation-repair reasons rather than reproducing them under new names.
11. **Catch-all publication fallbacks that delete old state before moving new state** — for authority/ownership metadata, fail while preserving old valid state rather than weakening atomic publication semantics. Recovery belongs to explicit repair.
12. **Best-effort warning as an implicit dependency policy** — replace ad-hoc warn/return with explicit required/optional resource policy.

## Refined minimal production model

The pre-implementation architecture can stay small:

```text
Portable Capsule
  Desired requirements / policy
  Portable state
  Host records/tags
  Optional seed

Host Resolution
  Program provider + concrete version/path/provenance
  Immutable local package realizations where capsulenv deploys them
  Small generation manifest

Session
  Environment/PATH/PSModulePath
  Bindings
  SessionIntegrations
  SessionServices
  Session ledger + resource leases

Persistent Host Integration (User mode only)
  Host-local bridge / pinned launcher
  reversible ownership metadata
```

No mandatory BlobStore, no generic state mirror/sync, no broad rehydrate, no process ownership by filesystem location, and no generic detached Routine pretending to be a service manager.

## Recommended changes to issue #7 before implementation

Add the following as explicit acceptance requirements:

- session ledger with PID + process-start identity and exact ownership;
- portable-state lease/concurrency policy and eject blocking for live exclusive leases;
- desired requirement vs per-host concrete resolution distinction;
- trust/version/capability constraints for host program reuse;
- explicit host retention policy;
- explicit required/optional integration policy;
- host-local persistent UserIntegration bridge/pinning rule;
- SessionService readiness/health semantics;
- no generic portable-state mirror/sync;
- explicit home-host enrollment;
- generation reachability-based GC;
- bootstrap networking tier for proxy-dependent acquisition;
- adapter-specific sensitive-state/residue behavior without zero-residue claims.

The first implementation boundary should therefore be **host identity/placement + Program resolution + session ledger/resource leases**, not immutable package installation itself. That boundary is required for browser, pwsh, Bitwarden integration, sing-box and eject to agree on ownership before old projection/lifecycle logic is removed.
