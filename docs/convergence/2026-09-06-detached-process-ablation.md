# Detached process environment ablation

## Failure mode

`Start-CapsulenvScoopShortcut` previously prepared a Capsule package by calling
`Set-CapsulenvPackageProcessEnvironment`, which wrote package `env_set` values and
`env_add_path` entries into the **parent** PowerShell process before calling
`Start-Process`.

That behavior was unnecessary for a detached GUI launch and had poor failure
characteristics: a launch could transiently or permanently contaminate the
calling shell, unrelated concurrent runspaces share the same process
environment, and any later command could observe state belonging to an app that
had merely been launched earlier.

## Ablation

The package-only parent environment mutator was removed. Shortcut launch now
builds the canonical `Capsulenv.ProcessPlan` with package environment and PATH
entries and dispatches it as `Detached`.

Detached process plans now use the same child-local `ProcessStartInfo` primitive
as tool relocation. The ToolRelocation-only ProcessStartInfo builder was removed
instead of retained as a compatibility wrapper. Scoop shortcut manifest
arguments remain a raw command-line fragment; user-supplied runtime arguments
are appended with the existing Windows command-line escaping contract.

Passthrough execution is deliberately not changed in this ablation. It owns an
interactive/pipeline semantic that cannot be replaced by capture-based process
execution without changing observable behavior. Its short-lived parent overlay
remains a separate FMEA candidate.

## Evidence

Acceptance requires all of the following:

- detached process behavior proves child env/PATH/cwd while the parent remains unchanged,
- AppLauncher proves a Capsule shortcut emits a Detached process plan with package env/PATH and preserves parent state,
- ToolRelocation continues to pass its child-local process tests using the shared builder,
- PackageExecutor and AppLauncher regressions remain green,
- AST analysis forbids reintroducing the package parent-env mutator, a ToolRelocation-only ProcessStartInfo builder, or direct `Start-Process` in shortcut launch.

## Performance / complexity effect

This removes one environment mutation/restore authority from detached app launch
and one duplicate ProcessStartInfo implementation. More importantly, detached
execution no longer requires parent-process coordination, which keeps the
launch path compatible with the desired-state concurrency model.
