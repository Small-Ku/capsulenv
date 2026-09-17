# Architecture ablation and failure-mode report

## Scope, live state, and evidence classes

This report is the detailed evidence authority for the experiment-only branch
`research/architecture-ablation-20260917`. At the start of this round the live
GitHub state was re-read: `main` was
`2412f2a4f115eae2e1218c240a8d142e5013d458`; the research branch was
`0c5339b4a6627ab665fd5289a53f0bf4d3e5fec2`. Issues #1–#6 were open. Production
source was read from live `main`, including `40-Scoop.ps1`,
`44-PackageExecutor.ps1`, `45-Relocation.ps1`, `46-LegacyScoopProjection.ps1`,
and `70-Doctor.ps1`. No production module or `main` was changed.

Evidence is intentionally not mixed:

- **Linux real measured**: actual filesystems, processes, threads, HTTP
  transport, `SIGKILL`, kernel `ulimit -f`, `inotifywait`, and process-level
  concurrency.
- **Synthetic measured**: earlier logical prototypes retained as reference,
  not used as the primary evidence for new conclusions.
- **Source-backed inference**: current PowerShell behavior and existing tests.
- **Still unmeasured/deferred**: only Windows-specific semantics or unavailable
  telemetry capabilities.

The Drive handoff was also checked. The actual capsulenv runtime archive was
downloaded and inspected; it contains the PowerShell runtime scripts but not a
`pwsh` executable. Drive search found PowerShell 7.6.5/Pester validation records
and unrelated toolchain archives, but no retrievable PowerShell Linux binary or
Pester package for this environment. This is a narrow toolchain limitation, not
a blocker for the Linux architecture campaign.

## Current production shape

Source-backed current behavior:

- `Get-CapsulenvScoopRehydratePlan` currently exposes 8 nodes and 11 edges;
  only `persist-relocation` and `project-cache-links` are marked
  `ParallelSafe`.
- The largest rehydrate node is `package-projections`; it delegates to the
  package/legacy projection repair path rather than representing one package
  dependency graph.
- `Initialize-CapsulenvIntegrations` calls package projection repair and project
  cache repair on the shell path, and invokes rehydrate when relocation is
  detected.
- `Repair-CapsulenvPackageProjection(s)` creates/repairs current-root and
  persist mappings. Legacy projection code also checks running processes and
  can defer or throw.
- Package installation has temporary extraction and rollback moves, but the
  production source has no single content-addressed BlobStore,
  generation `COMPLETE` barrier, active-generation authority, or deploy lock.

Static inventory from the checked-in analyzer remains: 37 source files,
16,766 source lines, 475 PowerShell functions, 96 package/projection-related
functions, and 58 legacy/relocation functions. These counts identify surface
area; they are not alone evidence that a subsystem can be deleted.

## Linux real baseline (#1)

Harnesses:

- `linux_runtime.py`: real Resolve-like setup, Acquire, Realize, Activate
  workload with small-file-heavy and large-file-heavy packages.
- `linux_real_campaign.py`: fresh-process cold/warm deploys, startup paths,
  warm server process, four placements, and four package scheduling variants.
- Results: `linux-real-results.json`, with focused repeated measurements in
  `linux-real-focused-results.json` and `linux-real-focused-large-results.json`.

Environment: Linux kernel `6.18.44`, Python `3.12.14`, real local filesystem,
real HTTP loopback transport. `strace` exists at `/usr/bin/strace`, but every
attempt to attach failed with the exact kernel error
`PTRACE_TRACEME: Operation not permitted`. Therefore write-syscall bytes,
syscall-level metadata counts, and syscall-derived process/fork counts are
marked unavailable, not zero. `inotifywait` was available and used for actual
create/delete/move/write event telemetry.

### Baseline measurements

| Workload / placement | Cold deploy p50/p95 (ms) | Warm deploy p50/p95 (ms) | Portable logical bytes | Host logical bytes | Network bytes |
|---|---:|---:|---:|---:|---:|
| small / all portable | 283–315 / 291–337 | 234–259 / 253–291 | 938,016 | 0 | 0 |
| large / all portable | 557–706 / 575–876 | 480–613 / 528–626 | 29,360,714 | 0 | 0 |
| small / host realization + host blobs | 224–286 / 221–338 | 216–247 / 220–326 | 112 | 937,904 | 0 |
| large / host realization + host blobs | 562–724 / 562–876 | 486–539 / 512–626 | 118 | 29,360,596 | 0 |
| small / host realization + remote blobs | 743–776 / 744–796 | 745–748 / 745–764 | 112 | 470,960 | 466,944 |
| large / host realization + remote blobs | 988–1,042 / 1,005–1,158 | 957–1,062 / 953–1,088 | 118 | 14,680,532 | 14,680,064 |

Ranges above are from repeated focused runs and the full matrix; the large
workload contains 4 MB + 4 MB + 4 MB + 2 MB payloads. The small workload has
four packages with 12 files each. A representative real cold fine-DAG sample
recorded 57 creates, 5 renames, 66 metadata operations, 9 fsyncs, 5 state
mutations, and max concurrency 2. The large sample recorded 13 creates, 5
renames, 22 metadata operations, 9 fsyncs, 5 state mutations, and max
concurrency 2. `inotifywait` independently saw 199 and 65 events respectively.

Startup-equivalent results are process-sensitive:

| Path | small p50/p95 | large p50/p95 | logical bytes / state mutations |
|---|---:|---:|---:|
| startup validate-only, fresh process | 262 / 276 ms | 253 / 308 ms | 0 / 0 |
| startup auto projection, fresh process | 305 / 365 ms | 274 / 291 ms | 332 / 8 |
| warm server process validate path | 0.3–0.5 ms p50 | 0.3–0.5 ms p50 | 0 / 0 |

The warm-server p95 has occasional process/scheduler outliers; it is the
steady-process path, not a fresh shell process. The fresh-process rows include
Python process startup and are not claims about PowerShell startup time.

No `perf`, `pidstat`, `iostat`, or `bpftrace` executable was available. Network
bytes are measured by the workload’s real HTTP transfer counters; syscall-level
network accounting is consequently unavailable.

## DAG ablation (#2)

The package workload now has an executable dependency correctness check: a
package realization fails unless its dependency generation is complete. The
four real variants are:

- **Sequential reference**: acquire all packages then realize sequentially.
- **Phase-level**: acquire in one bounded phase, then realize in dependency
  waves; fewer scheduler decisions, but still correct.
- **Acquire/Realize-only DAG**: all acquires are independent; only realization
  dependency edges remain.
- **Current fine-grained DAG**: acquisition dependency edges plus realization
  dependency edges.

Repeated focused Linux real measurements on all-portable placement:

| Workload | Sequential cold / warm | Phase-level cold / warm | Acquire/Realize DAG cold / warm | Fine DAG cold / warm |
|---|---:|---:|---:|---:|
| small | 315 / 243 ms | 272 / 243 ms | 287 / 234 ms | 283 / 258 ms |
| large | 706 / 613 ms | 650 / 480 ms | 569 / 534 ms | 557 / 518 ms |

The large workload has real independent `tool-a`/`tool-b` overlap after `base`:
bounded execution reached max concurrency 2 and reduced cold p50 by about 19%
versus sequential; Acquire/Realize-only reduced it by about 19% more, and the
fine graph did not materially improve over it. Remote placement makes network
transfer dominate and narrows the scheduler benefit.

The fine graph has 8 nodes and 10 edges for the small graph, 8/12 for the large
graph; the Acquire/Realize-only graph has 8 nodes and 4 edges; phase-level
execution has 8 logical tasks but only phase/dependency-wave scheduling; the
sequential reference has no scheduler edges. The extra acquire dependency edges
did not create observed correctness or parallelism value in this workload.

**Finding:** package Acquire/Realize DAG is justified by actual dependency and
parallelism evidence. The fine-grained acquire edges are dominated by the
Acquire/Realize-only graph in this workload. Rehydrate/control DAG remains a
separate question: source-backed current nodes mix side-effecting repair and
diagnostic topology; it should not be inferred from the package DAG result.

## Immutable generations, placement, and BlobStore (#3)

The real prototype implements:

`Resolve -> Acquire -> Realize -> Activate`

with `CapsuleHome`, `BlobStore`, `RealizationRoot`, `StateRoot`, and
`ScratchRoot` as separate placement roots. Blobs are verified by SHA-256;
realizations are written to `.partial`, receive a `COMPLETE` marker, are
published by local `os.replace`, and only then replace the small active
authority. Remote placement uses a real local HTTP server as an object-store
transport; it is not mounted as a filesystem authority.

The placement result is directly measured logical application writes:

| Placement | Small portable / total local | Large portable / total local | Portable reduction vs all-portable |
|---|---:|---:|---:|
| all portable | 938,016 / 938,016 | 29,360,714 / 29,360,714 | 0%
| host realization + portable blobs | 467,056 / 938,016 | 14,680,182 / 29,360,714 | ~50%
| host realization + host blobs | 112 / 938,016 | 118 / 29,360,714 | ~99.99%
| host realization + remote blobs | 112 / 470,960 | 118 / 14,680,532 | ~99.99%

For remote placement, the local total excludes network bytes by definition. The
separate real network transfers were 466,944 bytes for small and 14,680,064
bytes for large. This is the intended trade-off: portable writes stay tiny,
host realization writes remain local, and remote storage moves immutable bytes.

The placement evidence supports keeping only small authority/config/lock and
small persistent state on portable storage while placing runnable generations
and, optionally, blob cache on host-local NVMe. It is logical write telemetry,
not SSD controller wear telemetry; filesystem journaling and device write
amplification remain unmeasured.

## Real-process failure campaign

`generation_process_campaign.py` and `failure-process-results.json` execute 16
cases. Eight cases use a separate worker process and actual `SIGKILL` at an
explicit boundary; storage failures include kernel-enforced `ulimit -f 1` and
a real `NotADirectoryError`, not a thrown placeholder.

| Failure family | Result |
|---|---|
| kill during acquire/blob write | old active generation remained valid |
| kill during extraction / before COMPLETE | `.partial` remained non-authoritative; old valid |
| kill after COMPLETE before publish/activation | complete unpublished generation was not active |
| kill during activation replacement | old or new valid authority, never partial |
| kill after activation | new valid authority with previous pointer |
| remote unavailable / corrupt hash | process failed before activation; old valid |
| target disk full / realization unavailable | OS failure before activation; old valid |
| concurrent deploy from two processes | one worker succeeded, one lost the same-generation race; authority valid |
| mutation of completed realization | hash validation selected previous valid generation |
| host/root move and derived-index deletion | authority remained valid |

Summary: 16/16 invariant cases passed; 8/8 SIGKILL cases passed. The measured
Linux invariant is:

> after each tested crash/failure point, active resolution selected a complete
> valid old or new generation; an incomplete generation was never active.

This passes the architecture prototype’s real-process campaign. It is not yet
a Windows/NTFS verdict: atomic replacement under open handles, junctions,
Scoop current/persist links, and Windows sharing semantics remain deferred.

## BlobStore and remote transport

The existing `blob_store.py` prototype covers local CAS and a transport-only
rclone adapter with `Has/Fetch/Put/Stat` semantics, hash verification, and
atomic destination replacement. Existing fake-rclone tests validate the
protocol oracle. The new Linux real campaign validates an actual loopback HTTP
remote transfer, including network byte/request counts and no persistent local
portable blob cache in the remote placement.

No Google Drive credential was available for a real rclone backend in this
environment. This is not a blocker for the transport architecture finding:
rclone/remote storage must move immutable bytes only; identity, generation,
placement, realization, activation, and recovery remain local capsulenv
authority. Resumability, remote authentication failure, and real Google Drive
latency are still unmeasured. Remote storage must not be a startup dependency.

## Package projections (#4)

`projection_real_campaign.py` measures current-like eager projection writes,
validate-only startup, and two stable resolver designs:

| Workload | Auto startup p50/p95 | Validate startup p50/p95 | Python resolver p50 | shell resolver p50 | direct process p50 |
|---|---:|---:|---:|---:|---:|
| small | 305 / 365 ms | 262 / 276 ms | 101 ms | 26 ms | 5.6 ms |
| large | 274 / 291 ms | 253 / 308 ms | 118 ms | 30 ms | 7.0 ms |

Auto startup wrote 332–344 logical bytes per call; validate wrote zero. A
naive Python resolver adds about 96–111 ms over direct process launch. A tiny
POSIX shell resolver adds about 20–23 ms. Therefore “stable shim + resolver” is
not automatically a win: a heavyweight interpreter on every executable launch
is a dominated design. The viable hypothesis is a stable/static shim with
small active-generation metadata and either native/lightweight resolution or
resolution performed once per shell/session, not a new PowerShell/Python
reconciliation process for every `git`/`pwsh`/`uv` invocation.

Windows Scoop shims, Start Menu shortcuts, persist projections, and OS
registration remain narrow compatibility tests; Linux resolver numbers do not
replace them.

## Mutable state and legacy adapters (#5)

The existing reconstruction prototype showed equal observable resolution after
derived index/cache deletion, but the real source still contains multiple state
files and repair paths. The source-backed scenario matrix remains:

| Scenario | Current evidence | Classification |
|---|---|---|
| fresh capsule | normal projection/rehydrate path | required runtime path, simplify only with before/after tests |
| relocated root / drive change | relocation fingerprint and repair code | deploy/repair or migration candidate; Windows validation needed |
| legacy Scoop tree / global Scoop | `46-LegacyScoopProjection.ps1` selectors and ownership checks | compatibility adapter; no deletion evidence yet |
| ShellOnly / User mode | mode-specific integration and shortcut branches | explicit integration path, not startup authority |
| missing/corrupt indexes | prototype reconstructs derived state; production coverage incomplete | likely reconstructible, narrow scenario tests required |
| ambiguous ownership / divergent version dirs | legacy code defers or throws | retain safety boundary until measured |

No adapter is marked removable from static function count alone. The deletion
proof required for an adapter is reproducible before/after observable behavior
across this matrix, plus failure behavior. The current evidence supports moving
relocation/legacy handling toward explicit migration/repair, but not deleting
the adapters yet.

## Architecture findings and decision states

| Question | Decision | Evidence |
|---|---|---|
| Remove automatic startup reconciliation from the critical path? | **ACCEPTED BY EVIDENCE for platform-independent fast path; narrow compatibility validation remains** | Linux validate writes 0 vs auto 332–344 bytes; same active targets validate |
| Keep current fine-grained rehydrate DAG unchanged? | **REJECTED for package Acquire edges; INCONCLUSIVE for full rehydrate control DAG** | real package DAG shows no added benefit; production nodes have different side effects |
| Keep package Acquire/Realize DAG? | **ACCEPTED BY EVIDENCE for dependency-aware realization with bounded workers** | large workload real overlap reduces cold p50 vs sequential; dependency checks pass |
| Use immutable generations and atomic active authority? | **ACCEPTED BY EVIDENCE as experiment architecture** | 16/16 real-process failure invariant cases pass |
| Put RealizationRoot on host-local storage? | **ACCEPTED BY EVIDENCE for portable write reduction** | ~99.99% portable logical-write reduction in real payload workload |
| Keep local blob cache? | **LIKELY / NEEDS NARROW VALIDATION** | cache cuts repeated network transfer but host/portable placement tradeoff is workload-dependent |
| Use remote/rclone as runtime filesystem authority? | **REJECTED** | real HTTP transport works only as byte movement; activation stayed local |
| Use a naive interpreter resolver per command? | **REJECTED** | 96–111 ms p50 overhead over direct launch |
| Replace projections with stable lightweight resolution? | **LIKELY / NEEDS NARROW VALIDATION** | shell resolver much smaller than Python but still measurable; Windows shim compatibility pending |
| Reconstruct all mutable indexes? | **INCONCLUSIVE** | prototype passes; production state ownership/divergence matrix incomplete |
| Delete legacy adapters now? | **INCONCLUSIVE** | no reproducible before/after scenario evidence yet |
| Treat Windows as blocker for Linux architecture conclusions? | **REJECTED** | Linux real evidence covers platform-independent filesystem/process/authority behavior |

## What remains Windows-specific

Only these narrow items still require Windows validation:

- NTFS atomic replacement and durability behavior;
- Windows file-sharing/open-handle failure points;
- junction/current/persist behavior and actual Scoop global/User trees;
- Windows shims, Start Menu shortcuts, and OS integration;
- Windows PowerShell 5.1 contract gate and actual PowerShell process-start cost;
- physical portable SSD controller write amplification under the real workload.

They do not invalidate the Linux findings about generation authority, content
addressing, placement separation, local-vs-remote byte movement, or the
dependency/parallelism boundary.

## Recommended convergence sequence

1. Keep the current production architecture unchanged while promoting the
   experiment harness and results as the evidence baseline.
2. Build an implementation-ready design issue for a local immutable-generation
   authority with explicit Resolve/Acquire/Realize/Activate boundaries, local
   lock, `COMPLETE`, atomic active metadata, recovery, and GC.
3. Prototype host-local `RealizationRoot` and optional host-local BlobStore
   placement behind an experiment flag; measure real SSD telemetry on Windows.
4. Simplify package scheduling to dependency-aware Acquire/Realize DAG or
   sequential reference; remove fine acquire edges unless a new workload shows
   correctness/resource value.
5. Move package projection repair to explicit deploy/repair; test stable shims
   and active-generation resolution with actual Scoop/Windows behavior.
6. Delete derived indexes only after the full scenario matrix proves
   reconstruction and preserves ambiguous-ownership safety.
7. Convert legacy paths to migration-only only after reproducible before/after
   issue acceptance evidence; do not preserve them merely because they exist.

This is the smallest evidence-backed convergence sequence. No production
architecture recommendation has been merged in this round.

## Artifact index

- `linux_runtime.py`: real filesystem/process package workload.
- `linux_real_campaign.py`: baseline, placement, network, DAG, startup harness.
- `linux-real-results.json`: full real matrix.
- `linux-real-focused-results.json`, `linux-real-focused-large-results.json`:
  repeated DAG timing runs.
- `generation_process_campaign.py`: real multi-process kill/failure harness.
- `failure-process-results.json`: 16-case result, 0 unsafe.
- `projection_real_campaign.py`, `projection-real-results.json`: real
  projection/resolver measurements.
- `blob_store.py`, `generation_prototype.py`, `test_prototypes.py`: thin
  transport and immutable-generation feasibility prototypes.
- `REPORT.md`: this evidence authority.
