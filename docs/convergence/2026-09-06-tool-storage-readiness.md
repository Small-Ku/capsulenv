# ToolStorage readiness convergence

## Failure-mode question

`Set-CapsulenvSessionEnvironment` historically called `Initialize-CapsulenvToolStorage` on every activation. Even after reusing one ToolStorage plan, steady activation still performed a `Test-Path` sweep across every managed directory and file.

The sweep protected three different failure modes with the same recurring cost:

1. first use / plan generation change, where storage really must be materialized;
2. capsule relocation, where absolute storage paths change;
3. low-frequency post-initialization drift, such as a user manually deleting a cache/config file or replacing a file with a directory.

Only the first two need automatic steady-path recovery. The third is externally induced drift and is both detectable by `doctor` and explicitly repairable.

## Adopted boundary

ToolStorage now has a generation readiness marker derived from the resolved plan (variables, directories, files, PATH entries, creation policy, and therefore capsule root).

- Marker absent: full ToolStorage normalization runs and commits the marker only after success.
- Root/drive-letter/config/plan changes: the expected marker name changes, naturally invalidating readiness.
- Marker present: steady session activation returns after one metadata probe instead of sweeping every managed path.
- `capsulenv cache init`: always uses `-ForceRepair` and performs the complete integrity/materialization pass.
- `doctor`: retains explicit directory/file/conflict inspection and points drift to `cache init`.

A failed forced normalization removes the current marker before mutation, so a partial repair cannot leave a false-ready state.

## Deliberate ablation

After a valid marker is committed, manually deleting a managed config file no longer causes the next ordinary activation to recreate it. This is intentional: the environment variable still points at the capsule-owned path, so missing state does not silently transfer ownership to a host profile. The affected tool may create the path itself or fail visibly; `doctor` detects it and `cache init` restores it.

A file path occupied by a directory remains a hard failure during full repair and is reported by `doctor`; it is no longer polled on every unrelated command invocation.

## Static contract

`ToolStorageHotPathViolations` requires:

- readiness to remain metadata-only;
- the readiness gate to precede ToolStorage integrity probing/mutation;
- ordinary session activation not to force repair;
- explicit `cache init` to force repair;
- doctor to retain ToolStorage plan/readiness diagnostics.
