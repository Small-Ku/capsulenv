# Desired-state ready-queue convergence — 2026-09-06

The dynamic scheduler previously recomputed readiness by scanning every pending `NoOp` decision to closure and then scanning every pending `Apply` decision after each completion/poll iteration. Each scan re-walked the decision's dependency list. This preserved correct dynamic dispatch but repeated dependency work as package/project-cache fan-out grew.

The converged scheduler builds one dependency index from the already validated plan: an unmet-dependency count per decision plus a dependent-index list per producer. Completing a worker, main-runspace decision, or `NoOp` decrements only its direct dependents and inserts newly-ready decisions into stable original-plan-index `SortedSet<int>` queues.

The scheduling policy is intentionally unchanged. Resource compatibility, `Exclusive` semantics, MainRunspace selection, worker throttle capacity, lazy worker-pool creation, output publication, and final result ordering stay in the existing coordinator loop. Only readiness bookkeeping changes.

## Differential evidence

A separate randomized model compared the old repeated-scan readiness/no-op closure with the indexed completion model across 49,000 random topologically ordered DAG cases containing mixed `Apply`/`NoOp` decisions and occasional duplicate dependency declarations. After every arbitrary valid Apply completion, the completed set, automatic NoOp closure, and ordered ready-Apply set matched exactly.

`DesiredState.Tests.ps1` additionally covers a two-level NoOp chain that must cascade before a dependent Apply is dispatched, while the existing parallel tests continue to cover newly-ready worker dependents, compatible MainRunspace/worker overlap, output publication, and resource-conflict scheduling.

This differential evidence supplements, but does not replace, the canonical PowerShell/Pester gate.
