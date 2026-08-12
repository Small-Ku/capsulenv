# Repository notes

- Scoop is the single source of truth for application files, `persist` data, browser profiles, shims, shortcuts, and manifest lifecycle scripts.
- Do not add a parallel `data/` or profile store to capsulenv. App state belongs under the configured Scoop root, normally `scoop/persist/` or `scoop-global/persist/`.
- Relocation repair must call native `scoop reset` first, then replay only explicitly configured installed-manifest hooks.
- Never enable arbitrary `pre_install` replay by default. Many manifests use it for one-shot renames or migrations and are not idempotent.
- Lifecycle replay must read each installed version's `manifest.json` and `install.json`; do not substitute the latest bucket manifest.
- Keep persistent or machine-wide integration changes reversible and backed up under `.capsulenv/`.
- Do not commit `scoop/`, generated modules, local configuration, SSH keys, Bitwarden data, or browser profiles.
- Add module source to `src/*.ps1` and mark public exports with `##MOD_EXEC## Export-ModuleMember`.
- `capsulenv.cmd` must remain a thin launcher; environment logic belongs in the PowerShell module.
- Windows PowerShell 5.1 compatibility is required. Avoid PowerShell 7-only syntax in module sources.
- Never copy, reserialize, or own Bitwarden vault/app state. A setting integration may patch only source-verified top-level keys, must preserve unrelated JSON byte-for-byte, validate before replacement, and keep an exact per-key restore record.
- ShellOnly is the default install mode. Its activation/bootstrap may set process environment but must not adopt, rewrite, or register a host/user Scoop installation.
- Fresh Scoop bootstrap prefers shallow single-branch Git checkout of Scoop/Main with archive fallback; live Scoop repositories are mutable Scoop-owned runtime data, never Git submodules of capsulenv.
- User installation is explicit and reversible: back up the exact User environment before registering the capsule as the user's Scoop, and keep `restore-user` capable of returning it to ShellOnly.
