# Command module convergence

`src/90-Commands.ps1` had grown to 1098 lines and mixed help rendering, group
handlers, CLI diagnostic construction, app update orchestration, and the root
dispatcher.

## Accepted modular split

The command surface is now separated into help, cache/tools, offline/seed,
Bitwarden, CLI diagnostics, bucket, app, and root-dispatch modules.  The largest
resulting file is below 260 lines.  The bootstrap AST contract now points at the
root dispatcher module rather than assuming all command handlers share one file.

## Ablation results

Reference analysis found several one-caller private handlers, but their deletion
was rejected:

- group handlers (`Invoke-Capsulenv*Command`) own CLI parsing/error boundaries;
  inlining them into the root dispatcher would recreate the original monolith;
- `New-CapsulenvCliUnknownCommandError` is a stable diagnostic constructor and
  keeps error identity/remediation separate from dispatch control flow;
- `Show-CapsulenvHelp` overlaps with structured command/action catalogs only at
  discovery metadata; its topic-specific explanatory text is observable UX and
  is not redundant.

No runtime behavior is ablated in this structural batch.  The convergence gain
is smaller authority surfaces and cheaper future change review.
