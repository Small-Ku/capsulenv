# App launcher modularization and ablation

The launcher previously mixed selector/provider identity, installed-manifest normalization, runtime path resolution, and shortcut launch in one 900+ line source file. The convergence split makes those ownership boundaries explicit as `42-10` through `42-40` modules without adding a compatibility layer.

## Ablation

`Get-CapsulenvInstalledScoopApp` was a private compatibility wrapper over the provider-neutral `Get-CapsulenvInstalledApp`. Repository reference analysis showed no production caller; the only remaining use was a test. The wrapper is removed rather than moved, and that test now exercises the canonical resolver directly.

A source-text launcher snapshot test was also removed. Host-integration ownership and child-local detached process behavior are already enforced by canonical AST boundaries and behavior suites, so keeping a textual copy of those contracts would punish equivalent refactors without improving failure detection.

## Resulting ownership

- `42-10-AppIdentity.ps1`: selector/provider identity and installed-app discovery.
- `42-20-AppManifest.ps1`: installed manifest/bin/shortcut normalization.
- `42-30-AppResolution.ps1`: executable, persist, and owned-path resolution.
- `42-40-AppShortcut.ps1`: shortcut catalog and detached shortcut launch.

The change is accepted only when AppLauncher, AppCommand, PackageExecutor, ArchitectureAnalysis, canonical analyzer, Fast, and Full gates remain green.
