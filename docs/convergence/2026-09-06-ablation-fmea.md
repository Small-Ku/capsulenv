# Convergence ablation and failure-mode analysis — 2026-09-06

This phase uses ablation before deletion: remove one steady-state responsibility in an experimental worktree, keep mutation-time and explicit-repair behavior unchanged, then run the relevant behavioral and architecture gates. A hot-path check is removed only when the owned mutation already establishes the invariant and a non-hot-path detection/repair route remains.

## Activation failure-mode matrix

| Candidate removed from steady activation | Failure it used to self-heal | Occurrence | Impact | Remaining detection / recovery | Decision |
| --- | --- | --- | --- | --- | --- |
| Full package projection enumeration and repair | Manual/out-of-band deletion or replacement of `current`, persist projection, or owned shim while root/host is unchanged | Low | Medium; one package may fail to launch | relocation/pending retry, `capsulenv reset`, package install/update, `doctor` projection state | Remove from steady activation |
| Full project-cache link enumeration and repair | User/manual deletion or replacement of a managed project link while root/host is unchanged | Low | Medium; project cache falls back or becomes unavailable | `capsulenv cache status`, `capsulenv cache repair`, relocation repair; link/unlink update registry synchronously | Remove from steady activation |
| PortableSafe Start Menu namespace rebuild | User manually deletes a Capsulenv-owned shortcut after a correct install | Low | Low; CLI/app execution still works | package install/update sync, relocation sync, HostIntegration doctor check | Remove from steady activation |

The ablation deliberately does **not** suppress repair when `Test-CapsulenvScoopRehydrationRequired` is true. That signal already covers root/host changes, unreadable/missing rehydration state, and retryable pending projection repair.

## Evidence

- `PackageExecutor.Tests.ps1` proves PortableSafe install/update materializes owned package state and shims at mutation time.
- `ProjectCacheLifecycle.Tests.ps1` proves managed link creation records registry ownership immediately and unlink removes it immediately.
- `ScoopReset.Tests.ps1` proves steady-state plan construction does not even enumerate package/project-cache repair descriptors, while rehydration still expands them into the resource-claimed DAG.
- Explicit repair commands remain: `capsulenv reset`, `capsulenv cache repair`, and `capsulenv rehydrate`.

## Performance-path rule

Steady activation should establish session-local state and perform work required by a current mutation. Integrity sweeps for low-frequency external tampering belong in `doctor`, explicit repair, or relocation/pending-retry paths unless failure severity requires immediate prevention.
