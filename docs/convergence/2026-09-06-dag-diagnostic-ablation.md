# Desired-state diagnostic topology ablation

## Question

Does Capsulenv need to construct the complete resource-conflict matrix and execution-wave view for every desired-state apply?

## Ablation

The executor was inspected independently from the diagnostic plan. Non-sequential execution is authoritative in `Invoke-CapsulenvDesiredStateReadyQueue`: it admits a node when dependencies are complete and its live resource/concurrency contract is compatible with active work. `ExecutionWaves` is not consumed by this path and static analysis already forbids reintroducing a wave barrier.

The eager plan previously materialized three derived views before every apply:

- pairwise `ResourceConflicts`;
- `OwnershipDiagnostics` derived from that matrix;
- full `ExecutionWaves`, which performs another scheduling simulation.

Removing those views from execution-only plans does not remove dependency ordering, resource ownership, worker eligibility, contract validation, or the dynamic ready queue. Explicit review still requests the same diagnostics.

## Decision

Keep the DAG and ready queue. Make diagnostic topology opt-in at the core plan boundary. Public rehydrate plan inspection keeps diagnostics by default, while activation, explicit rehydrate execution, and PortableSafe package execution use execution-only plans.

## Failure-mode analysis

The removed work cannot prevent a runtime race because it was never scheduler authority. A conflict missed by diagnostic construction would still be checked by the live ready queue; conversely, making waves authoritative would reduce parallelism by restoring a barrier that the scheduler intentionally removed. Therefore eager diagnostic construction belongs outside the critical path.

A static architecture gate now rejects conflict/wave construction outside the `IncludeDiagnostics` branch, and regression coverage checks that an execution-only plan exposes an empty diagnostic view while an explicit diagnostic plan still produces claims and waves.

## Follow-up: compile execution claims once

After diagnostic topology was removed from the critical path, the remaining scheduler cost showed a second duplication: each candidate-versus-active comparison rebuilt and normalized both nodes' claims. `ResourceClaims` are not diagnostics; they are execution metadata. The plan compiler now stores normalized claims on each decision exactly once. Contract validation, the dynamic ready queue, and opt-in diagnostic views all reuse those decision claims. The node-level conflict wrappers that existed only to regenerate claims were removed.

Static analysis rejects `Get-CapsulenvDesiredStateResourceClaims` calls outside `Get-CapsulenvDesiredStatePlan`, keeping claim normalization out of the live admission loop.

## Follow-up: remove repeated URI path decomposition

Compiled claims already carry canonical resource URIs, but conflict admission still routed each pair through a helper that normalized both strings again, split both paths into segment arrays, and allocated path-part objects. The live/diagnostic claim-conflict paths now use a canonical URI overlap helper that compares scheme plus slash-delimited prefix boundaries directly. The general overlap entrypoint still normalizes arbitrary callers before delegating, so validation semantics are unchanged.

A finite differential check over 9,604 canonical URI pairs, including case variation, root claims, and empty interior path segments, produced identical overlap results between the old segment-array algorithm and the new boundary-prefix algorithm. Pester regression cases cover parent/child, exact, misleading string prefix, sibling, and cross-scheme behavior.

## Follow-up: remove the package-to-project-cache sequencing edge

The project-cache repair fan-out does not consume package projection output. Its actual prerequisite is session preparation, which creates the configured tool/project-cache storage roots. The previous `package-projections -> project-cache-link:*` edge serialized independent I/O domains and also made the no-record project-cache barrier wait for package repair for no semantic reason.

Project-cache nodes and the empty project-cache barrier now depend directly on `session-environment`. Package projection and project-cache worker fan-outs can therefore occupy the same diagnostic wave when their resource claims are disjoint. The later `user-integration` join still waits for both the package/persist branch and `tool-relocation`, so final state publication keeps the same safety boundary.

## Follow-up: remove the global exclusive aggregate barrier

`package-projections` is a main-runspace reducer over already-published worker outputs. It performs no independent external mutation, yet it was declared `Exclusive`, so the live ready queue could not run that reducer while any unrelated project-cache/tool worker was still active. That turned an in-memory join into a global serialization point.

The reducer is now `MainRunspace + ResourceBound` with a narrow read claim on `process:///desired-state/outputs/package-projections`. Its dependency barrier still guarantees every package-projection result exists before reduction, while disjoint workers from the project-cache branch no longer block it merely because they are active.
