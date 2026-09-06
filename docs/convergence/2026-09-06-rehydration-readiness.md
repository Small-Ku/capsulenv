# Rehydration readiness convergence

## Failure-mode question

Ordinary activation used `Test-CapsulenvScoopRehydrationRequired` to open and JSON-parse `scoop-rehydration.json`, inspect the pending-repair flag, and compare six relocation fingerprint fields on every invocation. That detail state is useful for relocation archaeology, retry diagnostics, and `doctor`, but parsing it is not necessary to prove that the current root/host generation already completed rehydration.

The recurring check mixed three failure classes:

1. root/drive/host/user/Scoop-root change, which must trigger rehydration immediately;
2. retryable projection repair, which must keep rehydration pending;
3. post-success corruption or manual editing of the detail JSON while the already-materialized projections remain unchanged.

The first two need an activation-time signal. The third is low-frequency diagnostic-state drift and does not justify parsing JSON on every unrelated command.

## Adopted boundary

The current fingerprint derives two metadata-only generation paths: a positive `.ready` marker and a negative `.pending` tombstone. Marker contents are not authority; only existence for the exact current fingerprint matters.

- No pending tombstone plus ready marker present: the current generation is ready.
- Ready marker absent: rehydration is required.
- Pending tombstone present: rehydration is required even if a racing successful writer also left a ready marker.
- Root/drive/Scoop-root/host/user changes: the expected marker paths change, so old generations cannot suppress rehydration.
- State publication invalidates ready **before** mutating detail state.
- Retryable projection repair: after the atomic JSON commit it publishes `.pending` and does not publish readiness.
- Successful non-pending publication: after the atomic JSON commit it removes `.pending` and publishes `.ready`.
- Ordinary activation: after deriving the normal relocation fingerprint, readiness adds at most two marker metadata probes; it does not open or parse `scoop-rehydration.json`.
- `doctor`: still opens the detail JSON and reports unreadable/pending/unresolved state.
- Explicit `capsulenv rehydrate`: reconstructs and republishes detail state plus the generation outcome markers.
- Old fingerprint markers are inert because activation checks only the exact current paths; rehydrate does not scan the directory merely to prune them.

The negative tombstone is deliberately fail-safe for concurrent first activations. If a pending writer and a successful writer interleave, `.pending` wins. The worst race is therefore one unnecessary retry, not a false-ready generation. Marker publication itself is an idempotent direct write because its contents are irrelevant and the authoritative detail-state commit has already completed.

An upgrade from a pre-marker build intentionally performs one rehydrate because no current `.ready` marker exists yet.

## Deliberate ablation

If `scoop-rehydration.json` is corrupted after a successful generation has committed its marker, the next ordinary activation no longer reparses the file and therefore does not automatically rehydrate solely to rewrite diagnostic history. The already-materialized projections are unaffected by that file corruption. `doctor` reports the unreadable detail state, and explicit rehydrate replaces it.

This is fail-safe for the state that matters to execution: a root/host/fingerprint change selects different marker paths, and retryable repair both invalidates readiness before mutation and publishes a negative tombstone after commit.

## Static contract

`RehydrationHotPathViolations` requires:

- readiness derivation/testing to avoid reading or mutating the rehydration detail state;
- steady detection to use the fingerprint-derived generation marker set;
- state publication to invalidate readiness before its first file write;
- state publication to retain an explicit post-commit outcome marker.
