# Environment module convergence

`src/30-Environment.ps1` had grown to 970 lines and mixed five ownership domains:
session planning, install-mode ledger state, persistent User environment mutation,
User-mode shell transitions, and child/external shell launch.

## Accepted modular split

The implementation is now separated into:

- `30-10-EnvironmentSession.ps1` — session plan/path composition and process-local setup;
- `30-20-InstallMode.ps1` — install-mode ledger and Start Menu ownership helpers;
- `30-30-UserEnvironment.ps1` — persistent User environment backup/synchronization;
- `30-40-UserShell.ps1` — enter/enable/restore User mode;
- `30-50-SessionShell.ps1` — child shell and arbitrary external command launch.

The largest resulting module is below 400 lines. Static contracts now accept the
actual ownership files instead of assuming all environment functions share one
source file.

## Ablation results

Reference analysis considered low-reference helpers for removal. The following
ablations were rejected:

- `Enable-CapsulenvUserEnvironment` is externally exported even though internal
  references are sparse; removing it without a deprecation boundary would break
  the PowerShell API surface.
- `Invoke-CapsulenvExternalCommand` has one production caller, but owns the
  semantic boundary "initialize integrations, then execute an arbitrary command"
  and prevents command-dispatch code from becoming a second process-launch
  authority.
- `Get-CapsulenvManagedPathEntriesFromState` and the path merge helpers each have
  one implementation consumer but encapsulate non-trivial state/path rules, so
  inlining would reduce modularity without reducing runtime work.

No runtime helper was deleted in this batch. The convergence gain is ownership
separation, not line-count reduction by unsafe API removal.
