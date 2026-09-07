English | [繁體中文](README.zh-TW.md)

# capsulenv

Capsulenv is a portable Windows development environment that travels on a USB drive. It provides an isolated working shell, package launchers, tool cache storage, and post-relocation repair.

The default **ShellOnly** mode confines environment variables and PATH changes to the Capsulenv process tree. When persistent Windows user integration is required, select **User** mode explicitly.

## Installation and first launch

Requires Windows PowerShell 5.1.

1. Extract the release bundle to a temporary directory.
2. From Command Prompt in that directory, run the installer:

   ```bat
   install.cmd D:\Portable\capsulenv
   ```

3. Launch the installed capsule:

   ```bat
   D:\Portable\capsulenv\capsulenv.cmd
   ```

First launch bootstraps unmodified upstream Scoop and the Main bucket on demand. Once installed, launch directly without running `init`.

Inside the Capsulenv PowerShell session, use `capsulenv`. This command is bound to the current capsule:

```powershell
capsulenv status
capsulenv help
```

To install from a source checkout, run `scripts\install.cmd <destination>`. For developer entrypoints, see [Development guide](docs/DEVELOPMENT.md#local-development-entrypoint).

## Select a session mode

| Mode | When to use | Impact |
|---|---|---|
| **ShellOnly** (default) | Using your own PC or keeping the host clean | Environment variables and PATH affect only the current process tree |
| **User** | Requiring persistent Windows user integration | Applies backed-up, reversible user configuration owned by Capsulenv |

Open a User shell:

```powershell
capsulenv user-shell
```

Before leaving a shared host, revert Capsulenv user integration:

```powershell
capsulenv restore-user
```

A fresh standalone invocation defaults to ShellOnly. Closing a User shell does not automatically revert persistent settings. For session modes and host departure, see [Session modes](docs/USAGE.md#session-modes).

## Common tasks

Inspect a package plan before installation:

```powershell
capsulenv app plan <app>
capsulenv app install <app>
```

Capsulenv installs the package only when its entire dependency graph belongs to the **PortableSafe** subset. If a plan is blocked, inspect the reason with `capsulenv app review <app>`.

`--allow-trusted` and direct `scoop ...` commands invoke unmodified upstream Scoop. Third-party scripts and host mutations belong to **TrustedExecution**, which falls outside Capsulenv reversibility guarantees. ShellOnly mode does not alter this trust boundary.

| Task | Command |
|---|---|
| View installed apps | `capsulenv app list` |
| Launch an app | `capsulenv app run <app>` |
| Update PortableSafe packages | `capsulenv app update --all` |
| Run a command in capsule environment | `capsulenv run git status` |
| View tool storage paths | `capsulenv cache paths` |
| Diagnose issues | `capsulenv doctor` |
| View command help | `capsulenv help app update` |

For step-by-step instructions, see [Usage guide](docs/USAGE.md) ([繁體中文](docs/USAGE.zh-TW.md)).

## Relocation, updates, and removal

After moving to another drive letter or PC, launch `capsulenv.cmd` from the new location. The runtime repairs projections automatically. If unresolved items remain, run `doctor` and follow the [Repair workflow](docs/USAGE.md#repair).

To update Capsulenv, run the installer from a **new release bundle** targeting the existing capsule:

```bat
X:\capsulenv-release\install.cmd D:\Portable\capsulenv
D:\Portable\capsulenv\capsulenv.cmd version
```

Updates preserve personal configuration, package data, and workspaces. Source edits or Git commits take effect in an installed runtime only after redeployment.

Before permanent removal, run `restore-user` on any host where User mode was used, then run `eject`. Verify your backups, then delete the capsule directory. `eject` terminates capsule processes and reports uncommitted workspace changes; it does not run `restore-user`.

## Documentation

| Topic | Document |
|---|---|
| Install packages, launch apps, configure integrations, or repair | [USAGE](docs/USAGE.md) ([繁體中文](docs/USAGE.zh-TW.md)) |
| Execution invariants, trust levels, and ownership rules | [ARCHITECTURE](docs/ARCHITECTURE.md) |
| Tool storage paths, caches, seeding, and uv/Pixi repair | [TOOLS](docs/TOOLS.md) |
| Build release bundles and installer mechanics | [DEPLOYMENT](docs/DEPLOYMENT.md) |
| Modify source code, run tests, and maintain documentation | [DEVELOPMENT](docs/DEVELOPMENT.md) |
| CLI design, error hints, and review UX specifications | [CLI-UX](docs/CLI-UX.md) |
| Upgrade actions from earlier versions | [MIGRATION](docs/MIGRATION.md) |
