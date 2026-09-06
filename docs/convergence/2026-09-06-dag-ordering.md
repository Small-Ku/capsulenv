# Desired-state DAG ordering convergence — 2026-09-06

`Resolve-CapsulenvDesiredStateOrder` previously implemented stable topological ordering by repeatedly scanning the entire unresolved node list and selecting the first ready node. That preserves a useful deterministic tie-break, but the repeated scan grows poorly with package-projection and project-cache fan-out.

The converged resolver uses Kahn's algorithm with a `SortedSet<int>` of original node indexes. Choosing the minimum ready index exactly preserves the previous semantic rule: at every step, select the earliest node in the caller's original node order among all currently-ready nodes. Dependency validation, duplicate-id rejection, cycle rejection, and the original relative order of unresolved nodes in cycle diagnostics remain at the resolver boundary.

## Ablation / differential evidence

A naïve FIFO Kahn queue was rejected because it changes ordering when an earlier node becomes ready after a later independent node was already queued. `DesiredState.Tests.ps1` now contains that counterexample (`a -> b` expressed as `a DependsOn b`, with independent `c`), whose stable order is `b,a,c` rather than `b,c,a`.

An external differential model compared the old scan resolver against the indexed Kahn resolver across 24,000 random DAGs, including occasional duplicate dependency declarations, with identical complete order. A second randomized comparison included cyclic and acyclic arbitrary graphs and matched both the resolved prefix and unresolved nodes exactly. This evidence supplements, but does not replace, the canonical PowerShell/Pester gate.

## Complexity boundary

The old resolver repeatedly rescanned unresolved nodes and their dependency lists. The new resolver builds indegree/dependent indexes once and performs ordered ready selection in `O((V + E) log V)`, with deterministic original-index priority. No execution-wave behavior, resource conflict policy, worker eligibility, or Apply/Verify semantics are changed.
