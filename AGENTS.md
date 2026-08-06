# Repository notes

- Keep persistent or machine-wide changes reversible and backed up under `.capsulenv/`.
- Do not commit `scoop/`, `data/`, local configuration, generated modules, SSH keys, Bitwarden data, or browser profiles.
- Add module source to `src/*.ps1` and mark public exports with `##MOD_EXEC## Export-ModuleMember`.
- `capsulenv.cmd` must remain a thin launcher; environment logic belongs in the PowerShell module.
- Windows PowerShell 5.1 compatibility is required. Avoid PowerShell 7-only syntax in module sources.
- Never edit Bitwarden vault internals to enable SSH Agent. Only configure supported environment, service, and Git/OpenSSH integration.
- Browser profile changes must refuse to run while the target browser is active unless the caller explicitly forces it.
