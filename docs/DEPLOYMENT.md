# Build and deployment

This page defines release bundle creation and installer mechanics. For standard installation, updates, and removal, see [README](../README.md#installation-and-first-launch). For explicit runtime relocation repair, see [ARCHITECTURE](ARCHITECTURE.md#bounded-legacy-projection-adapter).

## Deployment boundary

Deployment compiles or extracts the generated module and replaces managed program files transactionally.

The installer does not bootstrap Scoop, create mutable runtime state, import installed modules, or select User session mode. On first launch, the runtime bootstraps dependencies and rehydrates projections according to its active location.

| Surface | Entrypoint | Purpose |
|---|---|---|
| Source checkout | `scripts/capsulenv-dev.cmd`, `scripts/install.cmd` | Local development or deployment from source |
| Release bundle | `install.cmd` | Distribution staging and installation |
| Installed capsule | `capsulenv.cmd` | Everyday execution and relocation |

A source repository does not provide root `capsulenv.cmd` or `install.cmd`. An installed capsule does not retain the installer.

## Build a release bundle

Run from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build-Capsulenv.ps1 -OutputPath dist\capsulenv
```

The builder replaces the output directory. Output paths must not target the repository root, its ancestors, or source paths outside `dist/`.

The release bundle contains the launcher, installer, generated module, default configuration, launch helpers, documentation, and `.capsulenv-runtime.json`. A standard bundle contains no module source files or compilers.

Schema 3 separates two file manifests:

| Manifest | Purpose |
|---|---|
| `ManagedFiles` | Full release bundle manifest for packaging and integrity verification |
| `InstallFiles` | Destination payload deployed into the target capsule |

`InstallFiles` contains the launcher, config/bin helpers, and `modules/Capsulenv/**`. Documentation, installers, and bundle manifests remain in staging.

## Install or update a destination

From a source checkout:

```bat
scripts\install.cmd D:\Portable\capsulenv
```

From an extracted release bundle:

```bat
install.cmd D:\Portable\capsulenv
```

To invoke the installer script directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Install-Capsulenv.ps1 -Destination D:\Portable\capsulenv
```

The source installer compiles a temporary bundle in a scratch directory. The release installer validates the existing bundle manifest. Schema 3 deploys `InstallFiles`; legacy schema 2 uses `ManagedFiles` as a compatibility payload.

The destination directory must not equal, reside within, or be an ancestor of the source directory.

### Managed-file transaction

The destination `.capsulenv-install.json` defines ownership of deployed program files:

1. Back up existing managed files.
2. Delete obsolete managed files not present in the new payload.
3. Deploy new and updated files via temporary-file atomic replacement.
4. Update the installation marker.

If deployment fails, the installer restores previous files and markers in reverse order.

Unmanaged user data is preserved, including packages, persist storage, shims, tool data, caches, workspaces, private modules, `.capsulenv/`, and local configuration. For data classifications, see [Runtime layout](ARCHITECTURE.md#runtime-layout).

Targeting a non-empty directory without an install marker requires `-Force`. This switch does not authorize deleting unmanaged files.

## Runtime artifact contract

The installed launcher invokes `modules/Capsulenv/runtime/Invoke-Capsulenv.ps1`. The module package provides all control and runtime code.

The runtime does not depend on root `scripts/`, source files, compilers, README files, or bundle metadata. `CAPSULENV_FORCE_REBUILD=1` prompts for redeployment; it does not compile modules inside an installed capsule.

If the launcher detects a bundle manifest without an install marker, it requires installation to a destination directory first.

`install.cmd` and the installed launcher require Windows PowerShell 5.1. Bootstrap prepends `$PSHOME/Modules` to the inherited `PSModulePath` using language intrinsics and .NET APIs; it does not import or probe the Utility module.

Capsulenv parses configuration files using a safe AST reader. For interactive PowerShell isolation rules, see [ARCHITECTURE](ARCHITECTURE.md#powershell-control-plane-and-profile-isolation).

## Release and update workflow

1. Run the test suite via [DEVELOPMENT release gates](DEVELOPMENT.md#tests).
2. Build a release bundle from source.
3. Run the installer from external staging targeting the destination capsule.
4. Verify destination version: `capsulenv.cmd version`.

Distribution packages must originate from builder output. Never distribute development checkouts or capsules containing user data.

When changing drives, directories, or PCs, launch the existing capsule directly. Relocation requires no deployment.

## Development-file deployment

For debugging on target machines, pass `-IncludeDevelopmentFiles` during installation.

The source installer passes this switch to its temporary build. Prebuilt bundles must already include development files at build time for the installer to deploy them.

This switch is a diagnostic feature. Production runtimes must adhere to the self-contained artifact contract.

## Release verification checks

When modifying build, installer, or packaging logic, verify changes using the [DEVELOPMENT test gate](DEVELOPMENT.md#tests).

Verification must cover bundle/payload separation, runtime self-containment, obsolete file pruning, user data preservation, and transaction rollback on failure. Newly added documentation must be included in release bundles and resolve without broken links.
