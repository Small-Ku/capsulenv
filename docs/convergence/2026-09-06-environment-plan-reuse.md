# Environment plan reuse convergence

## Question

Steady session activation already constructs `Get-CapsulenvEnvironmentPlan`. Before this change, `Set-CapsulenvSessionEnvironment` then reread configuration, recomputed the ToolStorage plan inside `Initialize-CapsulenvToolStorage`, and reprobed ToolStorage directories through `EnvironmentPlan.Directories`.

## Ablation result

The repeated planning/probing layer was removed from the steady apply path:

- `Get-CapsulenvEnvironmentPlan` passes its existing configuration into `Get-CapsulenvToolStoragePlan`.
- The resulting ToolStorage plan is retained on `EnvironmentPlan.ToolStorage`.
- `Initialize-CapsulenvToolStorage` accepts an optional `-Plan`; its no-argument public behavior remains intact.
- `Set-CapsulenvSessionEnvironment` injects the precomputed plan and only probes `SessionDirectories` after ToolStorage initialization.

This turns the desired-state Plan output into the authority consumed by Apply instead of using it only as advisory data.

## Failure-mode boundary

The ablation deliberately does **not** remove ToolStorage file integrity checks. A configured file path occupied by a directory, or a missing managed config file, is actionable corruption with direct downstream impact. The current evidence only proves that repeated plan/config/directory discovery was redundant; it does not prove that those integrity checks can be deferred safely.

Explicit `Initialize-CapsulenvToolStorage` remains self-contained and can still compute its own plan when called without `-Plan`.

## Static contract

`EnvironmentPlanReuseViolations` rejects regressions where:

- Environment planning recomputes ToolStorage more than once or fails to pass its existing configuration.
- Session Apply rereads configuration or ToolStorage planning state.
- Session Apply initializes ToolStorage without injecting the precomputed plan.
- Session Apply reprobes `EnvironmentPlan.Directories` after ToolStorage initialization.
- ToolStorage planning cannot accept a supplied configuration.
- ToolStorage initialization cannot accept a supplied plan or rereads configuration itself.
