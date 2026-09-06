# Convergence ablation and failure-mode analysis — 2026-09-06

This phase uses ablation before deletion: remove one steady-state responsibility in an experimental worktree, keep mutation-time and explicit-repair behavior unchanged, then run the relevant behavioral and architecture gates. A hot-path check is removed only when the owned mutation already establishes the invariant and a non-hot-path detection/repair route remains.

## Activation failure-mode matrix

| Candidate removed from steady activation | Failure it used to self-heal | Occurrence | Impact | Remaining detection / recovery | Decision |
| --- | --- | --- | --- | --- | --- |
| Full package projection enumeration and repair | Manual/out-of-band deletion or replacement of `current`, persist projection, or owned shim while root/host is unchanged | Low | Medium; one package may fail to launch | relocation/pending retry, `capsulenv reset`, package install/update, `doctor` projection state | Remove from steady activation |
| Full project-cache link enumeration and repair | User/manual deletion or replacement of a managed project link while root/host is unchanged | Low | Medium; project cache falls back or becomes unavailable | `capsulenv cache status`, `capsulenv cache repair`, relocation repair; link/unlink update registry synchronously | Remove from steady activation |
| PortableSafe Start Menu namespace rebuild | User manually deletes a Capsulenv-owned shortcut after a correct install | Low | Low; CLI/app execution still works | package install/update sync, relocation sync, HostIntegration doctor check | Remove from steady activation |
| Rehydration detail JSON parse and fingerprint comparison | Detail state is manually corrupted after a successful unchanged generation | Low | Low; diagnostic history is unreadable but materialized projections are unchanged | `doctor` parses/reports detail state; explicit `capsulenv rehydrate` republishes it; root/host changes select different marker paths; retry publishes a `.pending` tombstone | Replace with generation marker |
| Full relocation desired-state graph materialization after a ready generation | A graph-level invariant would have to change without any relocation/pending signal | Very low; graph repair nodes are all `NoOp` on the ready generation | Low; only session-local environment setup is required by the steady path | marker invalidation/pending tombstone re-enters the full DAG; explicit `rehydrate` always uses the DAG; session setup remains direct | Remove from steady activation |

The ablation deliberately does **not** suppress repair when `Test-CapsulenvScoopRehydrationRequired` is true. The steady signal now covers missing readiness, root/host/fingerprint generation changes, and a retryable `.pending` tombstone. Unreadable detail JSON after a committed generation is intentionally a `doctor` / explicit-rehydrate concern rather than a per-activation parse.

## Evidence

- `PackageExecutor.Tests.ps1` proves PortableSafe install/update materializes owned package state and shims at mutation time.
- `ProjectCacheLifecycle.Tests.ps1` proves managed link creation records registry ownership immediately and unlink removes it immediately.
- `ScoopReset.Tests.ps1` proves a ready generation bypasses relocation plan materialization entirely, while a required/explicit rehydration still expands and executes the resource-claimed DAG.
- Explicit repair commands remain: `capsulenv reset`, `capsulenv cache repair`, and `capsulenv rehydrate`.

## Performance-path rule

Steady activation should establish session-local state directly and perform work required by a current mutation. A desired-state graph is justified only when there is actual repair/data-flow/resource-ordering work to schedule; a graph made entirely of one session `Apply` plus relocation `NoOp` decisions is an observation/abstraction cost, not a safety boundary. Integrity sweeps for low-frequency external tampering belong in `doctor`, explicit repair, or relocation/pending-retry paths unless failure severity requires immediate prevention.
