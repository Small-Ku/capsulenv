# CLI UX model

Capsulenv keeps one command surface and separates discovery, action intent, safety boundaries, and diagnostics instead of adding a second interactive configuration model.

## Discovery

Inside an activated PowerShell, `capsulenv` is a session function bound to the exact control launcher for that active root. Installed capsules capture `<root>\capsulenv.cmd`; source-development shells capture `scripts\capsulenv-dev.cmd`. `CAPSULENV_LAUNCHER` mirrors that resolved path for environment introspection, while the function itself captures a literal path after profiles load, so later PATH or environment rewrites cannot redirect it to another capsule. The capsule root also remains first on session `PATH` for `cmd.exe` and child-process compatibility. `capsulenv help` is the command index and groups daily commands by task rather than exposing the dispatcher switch as a flat list.

Focused help accepts both forms:

```text
capsulenv help app update
capsulenv app update --help
capsulenv cache status --help
```

Command groups can also use `capsulenv <group> help [action]` when the group has an action catalog.

## Errors are actionable

CLI input failures use Capsulenv's structured diagnostic contract. The launcher renders a short error first, optional hints second, and concrete remediation under `Try:`. Known command and action typos use bounded edit-distance matching, so for example `buckte` can suggest `bucket` without guessing an unrelated command.

Legacy command handlers that still throw `Usage: ...` are normalized at the dispatcher boundary into `Capsulenv.Cli.Usage`. This keeps old handlers compatible while preventing normal launcher use from leaking a PowerShell source location or stack-style error as the primary UX.

## Safety remains explicit

Discovery does not relax execution policy. PortableSafe package operations stay Capsulenv-owned; `--allow-trusted` remains an explicit per-invocation delegation to unmodified upstream Scoop. ShellOnly remains the default session mode, while `user-shell` / `install-user` are explicit persistent-integration entrypoints.

Unlike NyaModule, Capsulenv does not add a persistent CLI-preference store or TUI merely for consistency. Its durable configuration describes the portable environment itself; one-off command intent stays in arguments. The shared lesson is the UX structure: searchable commands, focused help, stable diagnostics, and a clear next action.

## Trusted package review

`capsulenv app review` is an effect-oriented dependency review surface, not a script allow-list. The review graph keeps direct manifest classification separate from the effective boundary propagated through dependencies, and shows root-to-blocker paths so a declarative top-level package cannot hide a scripted descendant.

For `user/<app>` and `global/<app>` updates, the default view compares the installed old closure with the current-bucket new closure before showing executable lifecycle fragments. Added/removed packages and dependency edges plus execution-relevant manifest effects are grouped first; incomplete old installed evidence is called out explicitly. `--raw` prints every source manifest in the resolved new DAG and `--json` exposes the graph, paths and diff for external review tooling.
