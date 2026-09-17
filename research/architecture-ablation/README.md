/root/.profile: line 11: /workspace/scratch/9406dad8be21/.cargo/env: No such file or directory
# Architecture ablation campaign

Branch: `research/architecture-ablation-20260917`
Baseline commit: `2412f2a4f115eae2e1218c240a8d142e5013d458`

This directory is experiment-only. It does not change the production module,
activation semantics, or Scoop integration.

Run the reproducible container-side evidence:

```bash
python3 research/architecture-ablation/analyze_repo.py \
  --output research/architecture-ablation/static-inventory.json
python3 research/architecture-ablation/simulate_variants.py \
  --output research/architecture-ablation/synthetic-results.json
```

The static inventory is source evidence. The synthetic results use a fixed
four-package workload to compare observable filesystem topology and crash
authority. They are not Windows runtime measurements.

Run `measure-windows.ps1` against a disposable test capsule to collect warm
and cold startup/deploy latency, portable/host logical byte deltas, file
create/delete counts, inferred rename counts, and inferred state mutations.
Physical SSD write amplification, subprocess count, and network bytes remain
explicitly unmeasured until an ETW/storage/network collector is attached.

Run the local research prototypes:

```bash
python3 research/architecture-ablation/dag_experiment.py \
  --output research/architecture-ablation/dag-results.json
python3 research/architecture-ablation/failure_campaign.py \
  > research/architecture-ablation/failure-results.json
python3 research/architecture-ablation/placement_experiment.py \
  > research/architecture-ablation/placement-results.json
python3 research/architecture-ablation/state_reconstruction.py \
  > research/architecture-ablation/state-results.json
python3 research/architecture-ablation/legacy_audit.py \
  > research/architecture-ablation/legacy-audit.json
python3 research/architecture-ablation/startup_ablation.py \
  > research/architecture-ablation/startup-results.json
python3 research/architecture-ablation/test_prototypes.py
```

`dag_experiment.py` executes the same bounded workload through the four DAG
shapes and records actual local scheduler/file-operation timings. It is a
prototype measurement, not a Windows runtime result. `failure_campaign.py`
executes twelve injected cases against the immutable-generation prototype and
checks the old-or-new authority invariant. The placement and state prototypes
measure portable-versus-host logical writes and derived-index reconstruction;
`legacy_audit.py` records the source-backed compatibility boundary without
claiming runtime compatibility. `startup_ablation.py` compares automatic
repair on every shell start with validate-only startup.

The current rehydrate graph has eight nodes and explicit dependencies in
`src/40-Scoop.ps1`. Only `persist-relocation` and `project-cache-links` are
declared parallel-safe. `package-projections` is one node whose Apply callback
delegates to a multi-step projection reconciler; package dependency resolution
is a separate recursive path in `src/44-PackageExecutor.ps1`.

Evidence labels: **Measured** means a real harness result; **Synthetic** means
the bounded prototype; **Inferred** means source-supported; **Hypothesis**
requires a Windows run or a future prototype.
