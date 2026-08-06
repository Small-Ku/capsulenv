# Tool-native relocation

Directory hardlinks do not exist on Windows, and not every portable tool link is
a filesystem junction owned by capsulenv. uv virtual environments and executable
wrappers contain installation-prefix metadata, so capsulenv asks uv to rebuild
them after the complete capsule moves.

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

Tool repair may need the network or a warm uv cache. The normal relocation state
still retains `LastRelocation`, so an omitted or failed repair can be retried with
`--last`.
