# CLI UX model

This page defines the command-line interface, discovery, error presentation, and review display rules. For operational steps, see [USAGE](USAGE.md). For runtime ownership and trust boundaries, see [ARCHITECTURE](ARCHITECTURE.md).

## Discovery

Inside an active Capsulenv PowerShell session, `capsulenv` is a session function bound to the exact control launcher of the active root. Installed capsules bind to `<root>\capsulenv.cmd`; source development shells bind to `scripts\capsulenv-dev.cmd`.

`CAPSULENV_LAUNCHER` exposes the resolved launcher path. The function captures this literal path after profiles load to prevent subsequent PATH or environment changes from redirecting commands to another capsule. The capsule root remains first on the session `PATH` for `cmd.exe` and child-process compatibility.

`capsulenv help` groups daily commands by task rather than exposing a flat switch catalog.

Focused help accepts two forms:

```text
capsulenv help app update
capsulenv app update --help
capsulenv cache status --help
```

Command groups with an action catalog also accept `capsulenv <group> help [action]`.

## Errors are actionable

CLI input errors follow a structured diagnostic contract:

1. Render a short description of the error first.
2. Render optional hints second.
3. Render concrete remediation commands under `Try:`.

Known command and action typos use bounded Levenshtein distance matching. For example, `buckte` suggests `bucket` without guessing unrelated commands.

Legacy handlers that throw `Usage: ...` normalize at the dispatcher boundary into `Capsulenv.Cli.Usage`. This prevents normal terminal usage from leaking PowerShell source locations or stack traces.

## Safety remains explicit

Discovery convenience never relaxes execution policy:

- PortableSafe package operations remain owned and executed by Capsulenv.
- `--allow-trusted` requires explicit per-invocation confirmation to delegate to unmodified upstream Scoop.
- The default mode is ShellOnly; `user-shell` and `install-user` are explicit persistent-integration entrypoints.

Capsulenv avoids persistent CLI preference stores or interactive TUIs; durable configuration lives in `config/capsulenv.local.psd1`, and one-off command intent stays in arguments. For trust levels, see [ARCHITECTURE](ARCHITECTURE.md#trust-levels).

## Trusted package review

`capsulenv app review` is an effect-oriented dependency review interface, not a script allow-list.

The review surface follows these display rules:

- Distinguish direct node classifications (`Direct`) from propagated dependency boundaries (`Effective`).
- Display root-to-blocker paths so a declarative top-level package cannot obscure scripted descendant risks.
- For upstream `scoop/<app>` updates, compare installed old closures with local bucket new closures to present a closure diff.
- Group added or removed packages, dependency edges, execution-relevant manifest properties, and lifecycle script fragments. Call out incomplete old installed evidence explicitly.
- Provide `--raw` to output all resolved source manifests, and `--json` for external automated review tooling.

For DAG classification and trust propagation rules, see [ARCHITECTURE](ARCHITECTURE.md#review-dag-and-trust-propagation). For command syntax, see [USAGE](USAGE.md#install-and-review).

## Installed app selector model

The primary selector namespace represents the runtime provider: `capsule/<app>` for Capsulenv-owned PortableSafe packages, and `scoop/<app>` for upstream Scoop packages.

CLI display rules:

- `capsulenv app list` displays `Provider` and `ScoopScope` as distinct columns.
- Displays launchable apps, declared binaries, and named shortcuts.

For selector resolution and disambiguation rules, see [ARCHITECTURE](ARCHITECTURE.md#installed-selector-and-runtime-separation). For execution commands, see [USAGE](USAGE.md#installed-apps).
