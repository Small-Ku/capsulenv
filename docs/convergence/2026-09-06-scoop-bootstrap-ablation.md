# Scoop bootstrap hot-path ablation and FMEA

## Ablation result

Removing Scoop bootstrap from normal activation entirely was rejected.  A fresh
capsule must still make the upstream `scoop` command available immediately, so
first-use-only bootstrap would change an existing user-facing contract.

The accepted ablation removes only repeated *repair work* from a ready
activation.  A successful full bootstrap writes a generation marker derived
from a bootstrap schema plus the canonical `scoop.cmd` template.  Normal
activation then takes a metadata-only readiness path while explicit repair can
still force full normalization.

## Ready activation before/after

Before, every activation entered the full bootstrap routine even when healthy:

- `New-Item -Force` on Scoop/config and shim directories;
- legacy PowerShell-shim migration probe;
- `scoop.cmd` content read and exact comparison;
- Scoop core and main bucket existence probes.

After, a ready activation performs only metadata probes for:

- the current-generation bootstrap marker;
- portable `config.json`;
- upstream `apps/scoop/current/bin/scoop.ps1`;
- `buckets/main/bucket`;
- `shims/scoop.cmd`.

There are no file-content reads or filesystem mutations on the readiness path.
A missing required artifact or marker falls through to the original full
bootstrap/repair implementation.

## Failure-mode analysis

| Failure mode | Hot-path treatment | Reason |
| --- | --- | --- |
| Scoop core missing | detect and full repair | high user impact; raw `scoop` would be unavailable |
| main bucket missing | detect and full repair | common package resolution depends on it |
| portable config missing | detect and full repair | portable Scoop state boundary must be re-established |
| cmd trampoline missing | detect and full repair | cmd.exe users otherwise lose raw `scoop` |
| Capsulenv/template generation changes | marker miss -> full normalization | preserves upgrade migrations without reading shim contents every launch |
| manual edit of an existing `scoop.cmd` with a valid marker | not content-scanned on every activation | low occurrence; explicit `capsulenv bootstrap` / `capsulenv init` uses `-ForceRepair` |
| manually resurrected legacy `scoop.ps1` after a successful current-generation bootstrap | not scanned every activation | low occurrence and PowerShell PATH resolves upstream bin before shims; marker invalidation or explicit repair cleans it |

`-ForceRepair` is deliberately required by explicit `capsulenv bootstrap` and
`capsulenv init`, while normal `Initialize-CapsulenvIntegrations` is statically
forbidden from forcing repair.  AST checks also forbid content reads or
mutation from `Test-CapsulenvScoopBootstrapReady`.
