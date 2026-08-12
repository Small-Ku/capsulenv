# Tool storage and native relocation

## Package-manager storage ownership

Capsulenv splits tool storage into rebuildable shared cache, persistent tool data,
and project-local state. The default environment mappings are intentionally
process-only in ShellOnly mode and become User environment variables only after
`install-user`.

| Tool | Cache/store under `cache/` | Persistent state under `tool-data/` | Project-local policy |
|---|---|---|---|
| uv | `uv`, `uv-python` | managed Python and global tools | `.venv` remains project-owned; registered lock-backed workspaces can be rebuilt |
| Pixi | `pixi` | `PIXI_HOME` | `.pixi` remains Pixi/workspace-owned |
| npm | `npm` | global prefix `npm` | `node_modules` remains project-owned |
| pnpm | `pnpm`, `pnpm-store` | home/global/state/bin | project virtual store remains project-owned |
| Bun | `bun` | global packages/bin | `node_modules` remains project-owned; global virtual store is not enabled by Capsulenv |
| Go | `go-build`, `go-mod` | GOPATH/GOBIN/GOENV | temporary scratch remains OS/tool-owned |
| Rust/Cargo | no separate Cargo-home split | rustup and Cargo home | `target` can use the `cargo-target` project-link profile |
| ccache | `ccache` | `ccache/ccache.conf` | project `ccache.conf` remains project-owned |
| sccache | `sccache` | `sccache/config.toml` | file-based config is capsule-owned; explicit environment overrides still apply |

`ToolStorage.PathVariables` are directory-valued environment variables.
`ToolStorage.FileVariables` are file-valued variables; initialization creates the
parent directory and a missing empty file. This distinction matters for `GOENV`,
`CCACHE_CONFIGPATH`, and `SCCACHE_CONF`.

`CARGO_HOME` is deliberately **not** placed under `cache/`: it is mixed state
containing installed binaries and potentially configuration/credentials as well
as registry/git caches. Likewise pnpm state/global dirs and package-manager global
installs are persistent data even though some can be reconstructed from manifests.

Go has one host-owned exception that cannot be represented honestly as another
ToolStorage path: `GOTELEMETRYDIR` is reported by the Go command but is not an
environment-settable redirect. Capsulenv isolates `GOENV`, `GOPATH`, `GOBIN`,
`GOCACHE`, and `GOMODCACHE`, but does not rewrite the process-wide Windows/XDG
user-config root merely to move telemetry state. Go telemetry therefore remains
a documented host-owned exception.

The central stores for uv, pnpm and Pixi perform best when the consuming project
environment is on the same filesystem. A project on another drive may force copy
fallbacks instead of hardlink/reflink materialization. Capsulenv favors portable
isolation by default; put projects under `workspace/` (or otherwise on the same
filesystem) when deduplication performance matters.

Capsulenv does not expose a generic destructive `cache clean all`. Several tools
have daemon or linking semantics, and optional modes such as Bun/pnpm global
virtual stores or uv symlink linking can make a shared cache a live dependency.
Use tool-native cleaning commands when required; `cache paths` shows which paths
belong to the capsule.


Directory hardlinks do not exist on Windows, and not every portable tool link is
a filesystem junction owned by capsulenv. Package hardlinks usually survive a
move on the same NTFS volume, but launchers, virtual environments, Conda prefixes,
and tool metadata can retain the previous absolute capsule path. Capsulenv repairs
those objects through the owning tool instead of recursively rewriting binaries.

## Status and workspace registry

```bat
capsulenv.cmd tools status
capsulenv.cmd tools register uv D:\Portable\capsulenv\workspace\python-app
capsulenv.cmd tools register pixi D:\Portable\capsulenv\workspace\science-app
capsulenv.cmd tools unregister uv D:\Portable\capsulenv\workspace\python-app
```

Registration is explicit. An uv workspace must contain `pyproject.toml` and
`uv.lock`; a Pixi workspace must contain `pixi.lock` plus either `pixi.toml` or
`pyproject.toml`. Capsule-relative workspace paths remain relative in
`.capsulenv\tool-workspaces.json`, so moving the whole capsule does not turn the
registry into stale absolute paths. External workspaces remain absolute by design.

Capsulenv does not recursively discover every `.venv` or `.pixi` directory. That
would be expensive and could rebuild unrelated environments. Only registered
lock-backed workspaces are automatically repaired.

## uv

```bat
capsulenv.cmd tools repair uv --dry-run --last
capsulenv.cmd tools repair uv --last --strict
```

Automatic repair runs during relocation unless `--skip-tool-repairs` is used.
Capsulenv asks uv for the exact keys of managed Python installations under the
portable `UV_PYTHON_INSTALL_DIR`, then reinstalls each key explicitly. It never
uses a target-less `uv python install --reinstall`, which could select a different
default Python.

For each global tool, capsulenv reads `uv-receipt.toml`, determines the installed
package version from its environment, relocates only OldRoot -> NewRoot metadata,
and invokes `uv tool upgrade --reinstall <name>==<installed-version>`. The exact
version is a command argument, not a mutation of the saved requirement, so uv can
reuse the receipt's original Python, index, extras, local path, URL, or VCS source
settings without turning relocation into an implicit upgrade. If the receipt or
installed version cannot be interpreted safely, the tool is reported and left
untouched.

Registered uv workspaces record their actual environment location when they are
registered. `UV_PROJECT_ENVIRONMENT` is accepted only when the resolved path stays
inside the workspace or the capsulenv root; capsulenv will not delete or recreate an
arbitrary system environment outside those ownership boundaries. On relocation it
transactionally renames the old environment, then runs:

```text
uv venv <environment> --project <workspace> --relocatable --no-progress
uv sync --project <workspace> --locked --reinstall --no-progress
```

The `--relocatable` flag is feature-detected for compatibility with older uv builds.
When unavailable, capsulenv still recreates the environment from scratch before the
locked sync and reports the non-relocatable fallback. `--locked` prevents relocation
repair from changing `uv.lock`. If either native command fails, the partial new
environment is removed and the previous environment is restored.

## Pixi

```bat
capsulenv.cmd tools repair pixi --dry-run --last
capsulenv.cmd tools repair pixi --last --strict
```

Registered Pixi workspaces are rebuilt with:

```text
pixi reinstall --all --locked --manifest-path <workspace>
```

This asks Pixi to recreate every environment declared by the workspace while
refusing to update a stale lock file.

Pixi global executables are trampolines backed by configuration under
`PIXI_HOME`. Their hardlinks can survive a move, while the trampoline environment
or prefix can still require regeneration. Pixi's documented global source of
truth is `PIXI_HOME\manifests\pixi-global.toml`, but it may contain version ranges
and has no documented global lock file. Therefore global sync is opt-in by
default:

```bat
capsulenv.cmd tools repair pixi --last --include-global
capsulenv.cmd tools repair all --last --include-global
```

This runs `pixi global sync` and may resolve another version permitted by the
global manifest. To accept that automatically on every relocation, set:

```powershell
@{
    ToolStorage = @{
        Relocation = @{
            Pixi = @{
                RepairGlobal = $true
            }
        }
    }
}
```

## Failure and retry behavior

Tool repair may need the network or a warm uv/Pixi package cache. Non-strict
automatic repair reports a failed component and lets Scoop rehydration complete.
`LastRelocation` remains available, so repair can be retried without moving the
capsule again:

```bat
capsulenv.cmd tools repair all --last --strict
```

With `--strict`, a tool or registered workspace failure aborts relocation before
the new Scoop fingerprint is saved. `--skip-workspaces` repairs only global uv and
Pixi components. `--skip-tool-repairs` skips the complete tool-native stage during
`init` or `rehydrate`.
