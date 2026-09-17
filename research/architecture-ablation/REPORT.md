/root/.profile: line 11: /workspace/scratch/9406dad8be21/.cargo/env: No such file or directory
# Architecture ablation report — first round

## Scope and provenance

This report is based on the live repository checkout at
`2412f2a4f115eae2e1218c240a8d142e5013d458` (`main`, 2026-09-05). The branch
containing this directory is experiment-only. No production module was changed.

The evidence is deliberately separated:

- **Static measured**: counts produced by `analyze_repo.py` from checked-in source.
- **Synthetic measured**: logical filesystem counters from `simulate_variants.py`.
- **Inferred**: behavior visible in current source transitions.
- **Unmeasured / hypothesis**: requires Windows runtime or a prototype not yet run.

## Baseline inventory

| Metric | Current result | Evidence class |
|---|---:|---|
| Source files / source lines | 37 / 16,766 | Static measured |
| Test files | 26 | Static measured |
| PowerShell functions in `src/` | 475 | Static measured |
| Package/projection-related functions (`src/43`–`46`) | 96 | Static measured |
| Legacy/relocation functions | 58 | Static measured |
| Rehydrate DAG nodes / edges | 8 / 11 | Static measured |
| Parallel-safe rehydrate nodes | 2 (`persist-relocation`, `project-cache-links`) | Static measured |
| Rehydrate resource claims | 22 | Static measured |
| Shell startup p50/p95 | not run | Windows-only |
| Cold/warm deploy p50/p95 | not run | Windows-only |
| Portable SSD physical bytes written | not run | Requires storage telemetry |
| Total physical bytes written | not run | Requires storage telemetry |
| Subprocess count | not run | Requires ETW or explicit collector |
| Network bytes | not run | Requires ETW/proxy or instrumented transport |

The Windows harness is now executable with separate warm/cold cases and
portable/host logical deltas, but no Windows run has been performed in this
environment. Physical SSD writes, ETW subprocess counts, and network bytes
therefore remain unmeasured rather than zero.

The configured current storage paths include `scoop`, `scoop-global`, `shims`,
`package-persist`, and `cache\\scoop`; the wider configuration additionally
defines tool-data, project-cache, workspace, PowerShell, and scratch semantics.

## Requested metric completion boundary

| Requested metric | Current evidence | Status |
|---|---|---|
| Shell startup p50/p95 | Windows warm/cold harness ready; local validate-only prototype measured | Windows runtime pending |
| Cold/warm deploy p50/p95 | Windows harness ready; local DAG/placement prototypes measured | Windows runtime pending |
| Portable storage bytes | 126,976 all-portable vs 1,792 host-realization/host-blob logical bytes | Physical SSD pending |
| Total bytes written | Placement prototype records portable + host logical writes | Controller-level pending |
| File create/delete/rename | Local prototypes record creates; Windows harness infers delete/rename | Windows runtime pending |
| Subprocess count | Explicit field in Windows schema | ETW pending |
| DAG node/edge count | 8/11 static current graph; four local variants measured | Complete for prototype scope |
| Network bytes | 62,464 modeled remote-blob bytes; fake transport tested | Real backend/ETW pending |
| State mutations | Startup/placement prototypes and Windows heuristic | Production runtime pending |
| Crash recovery | Immutable prototype 0 unsafe / 12 cases | Real PowerShell kill pending |

## Current control-flow evidence

The ordinary child-shell path calls `Initialize-CapsulenvIntegrations`, which
always calls package projection repair and project-cache repair. If the
relocation fingerprint requires it, it also invokes the eight-node rehydrate
plan. The explicit `init` command always invokes the full rehydrate plan.

The rehydrate graph is not the package dependency graph. Its largest node is
`package-projections`; its Apply callback delegates to a multi-step reconciler
that repairs installed package projections, legacy Scoop projections, shims,
and User-mode shortcuts. Package install uses a separate recursive dependency
walk and then mutates each package in sequence.

Package installation has useful local rollback protection: it extracts to a
temporary directory, may move the previous version to an update rollback
directory, moves the temporary tree into place, updates `current`, writes
installed state twice, reconciles shims, and finally deletes rollback/state
backups. This is evidence of partial transactional behavior, not proof of a
single atomic generation authority.

Rehydration state itself uses a temporary file and `File.Replace` with a rollback
path. The repository has no checked-in content-addressed BlobStore,
generation/`COMPLETE` publish barrier, activation pointer protocol, or deploy
lock in the current architecture. These are findings from source search, not a
claim that every underlying Windows filesystem operation is non-atomic.

## Synthetic ablation matrix

Workload: four packages, five files per package. Logical writes are comparable
within this prototype only.

| Variant | DAG n/e | Portable bytes | Total logical bytes | Creates | Network bytes |
|---|---:|---:|---:|---:|---:|
| A0 current fine DAG | 8 / 11 | 125,952 | 125,952 | 33 | 2,048 |
| A1 no startup reconciliation | 0 / 0 | 0 | 0 | 0 | 0 |
| A2 lazy projection | 8 / 11 | 125,696 | 125,696 | 25 | 2,048 |
| A3 phase-level DAG | 4 / 3 | 125,952 | 125,952 | 33 | 2,048 |
| A4 Acquire/Realize-only DAG | 2 / 1 | 1,792 | 124,928 | 29 | 0 |
| A5 sequential reference | 1 / 0 | 1,792 | 124,928 | 29 | 0 |
| A6 host-local realization | 2 / 1 | 1,792 | 124,928 | 29 | 0 |
| A7 no local blob cache | 2 / 1 | 1,792 | 124,928 | 29 | 122,880 |
| A8 separated roots | 2 / 1 | 1,792 | 124,928 | 29 | 0 |

Interpretation: the synthetic run supports three narrow inferences. Eager
projection adds eight creates and about 256 logical bytes in this workload;
moving realization host-local reduces portable logical writes by about 98.6%
while leaving total logical bytes nearly unchanged; removing the local blob
cache moves about 122,880 bytes to network transfer. A3 versus A4/A5 also shows
that reducing graph structure alone does not reduce writes. It only reduces
orchestration structure. Whether it reduces wall time depends on real package
parallelism and must be measured on Windows.

## Failure-mode campaign

The synthetic campaign covered acquire interruption, remote unavailable,
hash mismatch, extract kill, target disk full, realization unavailable,
root change, concurrent deploy, before/after activation, cache/index deletion,
and mutation of an otherwise immutable realization.

| Architecture | Unsafe/indeterminate cases in prototype | Main implication |
|---|---:|---|
| Current-like projection | 3 / 12 (`after-activation`, `concurrent-deploy`, `mutable-realization`) | Existing local rollback is not enough to establish one active generation authority. |
| Immutable generation prototype | 0 / 12 | Local prototype execution preserved old or new valid authority at every modeled case, including corrupted realization fallback and concurrent threads. |

The 0/12 result is now a **prototype-measured** result from
`failure_campaign.py`; it is still not a production failure verdict. Storage
and remote failures were injected before the corresponding OS operation, and
concurrency was thread-level. The Windows campaign must kill the real process
at explicit boundaries and validate both the active pointer and the complete
realization against hashes.

The branch also contains runnable local prototypes: `blob_store.py` implements
`Has/Fetch/Put/Stat` for a local immutable store plus a transport-only rclone
adapter, while `generation_prototype.py` implements `realize -> publish ->
activate` with a `COMPLETE` marker and atomic active metadata replacement.
`test_prototypes.py` passes the local round-trip and before/after activation
crash checks, including all publish/activation boundaries, mutation fallback,
and concurrent deploy. This is feasibility evidence only; it is not wired into
production.

## DAG prototype measurement

`dag_experiment.py` executes a bounded workload with the current 8/11 graph,
phase-level 4/3 graph, Acquire/Realize-only 2/1 graph, and sequential 1/0
reference. Twenty repetitions with a controlled 2 ms per-node work delay
produced:

| Variant | Nodes / edges | Wall p50 / p95 (ms) | Max parallelism observed |
|---|---:|---:|---:|
| Current fine-grained | 8 / 11 | 19.974 / 23.778 | 2 |
| Phase-level | 4 / 3 | 12.232 / 15.188 | 1 |
| Acquire/Realize-only | 2 / 1 | 7.154 / 9.007 | 1 |
| Sequential reference | 1 / 0 | 4.384 / 6.662 | 1 |

This controlled prototype indicates orchestration overhead in the fine graph;
it does not prove that the current package workload has no useful parallelism.
The exact callback costs and PowerShell worker behavior still require Windows.

## Package-projection prototype measurement

The synthetic launcher contract resolves the same three package targets in both
variants. Eager projection created 6 files / 396 bytes; a stable shim plus
active-generation metadata created 2 files / 118 bytes. This is evidence that
projection materialization is a plausible deletion target, not compatibility
evidence for Scoop shims, Start Menu shortcuts, or User-mode registration.

## Placement and write-amplification prototype

`placement_experiment.py` ran the same four-package desired state with four
placements. The measured values below are logical application writes, not SSD
controller writes:

| Placement | Portable bytes | Host bytes | Network bytes | Portable reduction |
|---|---:|---:|---:|---:|
| All portable | 126,976 | 0 | 0 | 0% |
| Host realization + portable blobs | 64,256 | 62,720 | 0 | 49.395% |
| Host realization + host blobs | 1,792 | 125,184 | 0 | 98.589% |
| Host realization + remote blobs | 1,792 | 62,720 | 62,464 | 98.589% |

This is the clearest evidence for separating `CapsuleHome` from
`RealizationRoot`: the control plane remains portable while the runnable
generation and optionally the blob cache move to host-local storage. The
remote variant trades local blob bytes for modeled network bytes; it does not
make remote storage runtime authority. Warm cumulative values include active
metadata rewrites and are not controller-level wear measurements.

## Startup reconciliation ablation

`startup_ablation.py` verified the same four active-generation targets through
both startup paths over 20 repetitions:

| Startup path | Wall p50 / p95 (ms) | File writes | Logical bytes | State mutations |
|---|---:|---:|---:|---:|
| Automatic reconcile every shell | 1.352 / 3.397 | 160 | 4,640 | 160 |
| Validate-only shell | 0.103 / 0.365 | 0 | 0 | 0 |

Both paths verified all four runnable targets. The prototype therefore gives
direct evidence that automatic repair is a write-heavy fast-path policy, while
its latency result remains local Python evidence and excludes PowerShell
startup. The implementation-ready question is whether repair can move to
explicit deploy/rehydrate without changing the real Scoop/shortcut contract.

## Derived state reconstruction

`state_reconstruction.py` reconstructed the same package resolution after
deleting or mutating the derived index, and after deleting a cache. In all four
cases `observable_resolution_equal = true` and `authority_unchanged = true`.
This supports deleting mutable indexes only when they are demonstrably derived
from desired manifests, verified generations, and active metadata. It does not
yet prove that every current Scoop state file meets that criterion.

## Blob transport and legacy compatibility audit

The local prototype tests now cover local corruption rejection and a fake
rclone-compatible transport: `Put`, `Has`, `Fetch`, atomic destination
replacement, hash mismatch, and remote corruption rejection all pass. The
fake backend is deliberately not Google Drive evidence; it validates the
thin transport contract and keeps blob identity/activation local.

The source-backed legacy matrix records five boundaries. The 287-line,
9-function `src/46-LegacyScoopProjection.ps1` is an adapter candidate, not an
authority candidate. Relocation detection remains a boundary to retain until
generation placement metadata replaces path inference. Scoop `-g` compatibility
and User-mode shortcuts remain optional/runtime compatibility surfaces. No
legacy path is deleted based on static evidence alone.

## Architecture findings

### Strong candidates for ablation / deletion evidence

1. **Startup automatic repair on the fast path.** The current child-shell path
   performs projection repair and project-cache repair before opening the shell.
   The minimum prototype should replace this with read/validate/activate and
   leave repair to explicit deploy/rehydrate. Acceptance requires unchanged
   runtime resolution and a measured startup reduction.
2. **Eager package projection rebuilding.** A stable shim plus active-generation
   metadata/resolver is a plausible replacement for rebuilding every projection
   on startup. The synthetic result is supportive but not sufficient for
   compatibility claims.
3. **Fine-grained rehydrate nodes.** The graph has 8 nodes but only 2 are
   parallel-safe, while the biggest side-effect boundary remains one node.
   Compare phase-level, Acquire/Realize-only, and sequential reference paths;
   retain a DAG only where dependency/resource conflicts or measurable
   parallelism exist.
4. **Mutable indexes that duplicate authority.** Package state and rehydration
   state are validated and repaired, but a prototype should delete derived
   indexes and reconstruct them from manifests, immutable blobs, and active
   generation metadata. If observable behavior is unchanged, this is a direct
   deletion candidate.
5. **Legacy compatibility adapters.** `src/46-LegacyScoopProjection.ps1`, the
   relocation repair paths, and compatibility selectors should be measured as
   an opt-in adapter boundary. Their presence is not itself evidence that they
   remain necessary.

### Candidates to preserve, but simplify

- **Resolve, Acquire, Realize, Activate** as four explicit phases.
- **Scoop metadata boundary** as an upstream metadata/trusted-execution
  integration, not a runtime authority.
- **PortableSafe package trust classification**, because it is an ownership
  and safety boundary rather than mere orchestration.
- **Atomic small state-file replacement**, but with one generation authority
  instead of multiple independently mutable projections.

### Still inconclusive

- Actual p50/p95 startup and cold/warm deploy time.
- Whether phase-level DAG parallelism beats sequential execution once PowerShell
  worker startup and serialization costs are included.
- Physical SSD write amplification and controller-level wear reduction.
- Whether all existing legacy projection adapters have observable users.
- Whether remote object storage improves lifecycle cost after cache misses,
  authentication failures, and offline operation are included.

## Recommended convergence sequence

1. Run the Windows measurement harness and add ETW counters for subprocess and
   network bytes.
2. Build an experiment-only generation realization prototype with a local
   object store and crash injection; do not replace the current installer yet.
3. Run the DAG four-way comparison on the same package workload.
4. Run placement comparison: portable realization versus host-local
   `RealizationRoot`, retaining control plane and small persistent state on the
   portable device.
5. Run package-projection ablation and verify stable shims plus active metadata
   against all existing launcher behaviors.
6. Only after acceptance criteria pass, open implementation issues for deleting
   dominated paths. No architecture recommendation is production-ready from
   this first round alone.

## Campaign status

This branch now contains a stronger research harness and prototype evidence,
but the campaign remains **incomplete**. The blocking evidence is the Windows
runtime run: real shell/deploy p50/p95, physical portable-SSD amplification,
ETW subprocess/network counters, real PowerShell crash injection, and the
compatibility matrix for package projections and legacy adapters.
