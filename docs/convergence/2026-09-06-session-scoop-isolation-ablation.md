# Session Scoop-isolation hot-path ablation

`Set-CapsulenvSessionEnvironment` removes foreign Scoop shim directories from the
current process PATH so the capsule-owned upstream dispatcher and shims win
resolution.  The previous implementation rediscovered possible foreign roots on
every call by reading Process/User/Machine `SCOOP*`, the reversible User
integration backup JSON, and Windows default roots.

That discovery was broader than the effect being protected: a path that is not
present in the current process PATH cannot affect current command resolution.

## Accepted ablation

The hot path now derives candidate roots only from process-visible evidence:

- current process `SCOOP` / `SCOOP_GLOBAL` before Capsulenv overwrites them;
- Windows default user/global Scoop roots as fallback evidence;
- and only returns a shim directory when it is actually present in the current
  PATH.

It no longer reads User/Machine environment targets or the portable
User-integration backup file during ordinary session setup.

## FMEA

| Failure mode | Decision |
| --- | --- |
| inherited host Scoop root in Process `SCOOP*` and PATH | still removed |
| default `%USERPROFILE%\\scoop` / `%ProgramData%\\scoop` shim in PATH | still removed on Windows |
| custom old host root exists only in User/Machine environment but not current PATH | irrelevant to current command resolution; do not scan |
| custom old host root is in current PATH while persistent User integration replaced Process `SCOOP*` with capsule values | low-probability stale/manual drift; capsule paths are prepended and remain authoritative; repair/install-user/doctor are the appropriate recovery surfaces rather than reading backup JSON on every command |

The regression boundary is structural: the foreign-shim discovery helper may
not read User/Machine environment, the user backup file, or JSON from disk.
Existing bootstrap behavior tests continue to prove that inherited process Scoop
shim paths are removed.

## Persistent User-mode boundary

The ablation is deliberately limited to `Set-CapsulenvSessionEnvironment`.
`Sync-CapsulenvUserEnvironment` remains an explicit, low-frequency persistent
mutation and therefore keeps broader User/Machine/backup evidence through
`Get-CapsulenvPersistentForeignScoopShimPaths`.  Both discovery paths share the
same path-selection primitive, so the hot path loses persistent I/O without
weakening explicit User cleanup or creating two normalization implementations.

The canonical AST gate now enforces both halves: steady session discovery is
process-only and bounded to the current `PATH`, while persistent User sync must
continue inspecting the User `PATH` through the persistent discovery helper.
