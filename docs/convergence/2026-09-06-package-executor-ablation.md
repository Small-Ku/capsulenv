# Package executor modularization and ablation

## Scope

The former `44-PackageExecutor.ps1` mixed four independently evolving responsibilities:

1. package state and dependency planning,
2. artifact acquisition/materialization and archive handling,
3. installation/projection/update orchestration,
4. installed-app process planning and launch.

The convergence split keeps those boundaries explicit as `44-10` through `44-40` modules.  The split is deliberately behavior-preserving; it is not a compatibility-layer expansion.

## Ablation result

Three private package-only wrappers were removed instead of moved:

- `Get-CapsulenvPackageInstallPlanContract`
- `Get-CapsulenvPackageProcessPlan`
- `Invoke-CapsulenvPackageExecutable`

Repository reference analysis found no production callers that required the first wrapper and no production callers for the latter two.  The package-only process wrappers duplicated the canonical installed-app path:

- `Get-CapsulenvInstalledAppProcessPlan`
- `Invoke-CapsulenvInstalledAppExecutable`

The executable stream/exit-code regression test now exercises that canonical path directly.  This prevents a test-only parallel implementation from becoming an accidental compatibility surface.

## Failure-mode reasoning

Keeping duplicate private wrappers has low immediate runtime cost but high maintenance failure probability: fixes to process environment, exit-code propagation, or manifest-drift checks can land in one path and not the other.  Removing the duplicate path reduces semantic divergence while preserving the user-visible app execution surface.

The modular split also narrows future failure domains.  Artifact/archive changes no longer require editing the same 1,000+ line file that owns state planning and process launch, while source load ordering remains deterministic through the existing numbered module build.

## Evidence

The ablation is accepted only if:

- removed wrapper names have zero repository references,
- package executor regression tests pass through the canonical launcher,
- app command and app launcher suites pass,
- architecture analysis and canonical static analysis remain clean,
- the canonical Fast gate passes before commit.
