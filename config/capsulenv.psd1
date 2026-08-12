@{
    SchemaVersion = 7

    Scoop = @{
        Root = 'scoop'
        GlobalRoot = 'scoop-global'
        RehydrateOnRelocation = $true

        # Fresh portable Scoop bootstrap. Git is preferred when available and
        # uses a shallow single-branch clone; archives keep first install
        # possible on machines that do not have Git yet.
        Bootstrap = @{
            Enabled = $true
            GitDepth = 1
            Scoop = @{
                Repository = 'https://github.com/ScoopInstaller/Scoop.git'
                Branch = 'master'
                Archive = 'https://github.com/ScoopInstaller/Scoop/archive/refs/heads/master.zip'
            }
            Main = @{
                Repository = 'https://github.com/ScoopInstaller/Main.git'
                Branch = 'master'
                Archive = 'https://github.com/ScoopInstaller/Main/archive/refs/heads/master.zip'
            }
        }

        ReplayHooks = @{
            firefox = @('post_install')
            'firefox-esr' = @('post_install')
            'zen-browser' = @('post_install')
        }

        # Exact allow-list of Scoop-persisted text files that may contain
        # the previous capsule path. Missing files are ignored; running apps
        # must be closed before any matching file is changed.
        RelocationRepairs = @{
            firefox = @(
                @{ Path = 'profile\compatibility.ini'; Format = 'text'; Processes = @('firefox'); MaxBytes = 1048576 }
                @{ Path = 'profile\extensions.json'; Format = 'json'; Processes = @('firefox'); MaxBytes = 67108864 }
                @{ Path = 'profile\prefs.js'; Format = 'text'; Processes = @('firefox'); MaxBytes = 16777216 }
                @{ Path = 'profile\user.js'; Format = 'text'; Processes = @('firefox'); MaxBytes = 16777216 }
                @{ Path = 'distribution\policies.json'; Format = 'json'; Processes = @('firefox'); MaxBytes = 4194304 }
            )
            'firefox-esr' = @(
                @{ Path = 'profile\compatibility.ini'; Format = 'text'; Processes = @('firefox'); MaxBytes = 1048576 }
                @{ Path = 'profile\extensions.json'; Format = 'json'; Processes = @('firefox'); MaxBytes = 67108864 }
                @{ Path = 'profile\prefs.js'; Format = 'text'; Processes = @('firefox'); MaxBytes = 16777216 }
                @{ Path = 'profile\user.js'; Format = 'text'; Processes = @('firefox'); MaxBytes = 16777216 }
                @{ Path = 'distribution\policies.json'; Format = 'json'; Processes = @('firefox'); MaxBytes = 4194304 }
            )
            'zen-browser' = @(
                @{ Path = 'profile\compatibility.ini'; Format = 'text'; Processes = @('zen'); MaxBytes = 1048576 }
                @{ Path = 'profile\extensions.json'; Format = 'json'; Processes = @('zen'); MaxBytes = 67108864 }
                @{ Path = 'profile\prefs.js'; Format = 'text'; Processes = @('zen'); MaxBytes = 16777216 }
                @{ Path = 'profile\user.js'; Format = 'text'; Processes = @('zen'); MaxBytes = 16777216 }
                @{ Path = 'distribution\policies.json'; Format = 'json'; Processes = @('zen'); MaxBytes = 4194304 }
            )
        }
    }

    Environment = @{
        Path = @('bin')
        # Portable PowerShell module roots. The first entry is also exposed as
        # CAPSULENV_MODULE_ROOT for private module build/install scripts.
        ModulePath = @('PowerShell\Modules')
        PathVariables = @{}
        Variables = @{}
    }


    ToolStorage = @{
        Enabled = $true
        CreateDirectories = $true

        # Portable caches and tool-managed installations. All relative paths
        # are resolved from CAPSULENV_ROOT and are included in user backup/
        # restore when `enable-user` is used.
        PathVariables = @{
            UV_CACHE_DIR = 'cache\uv'
            UV_PYTHON_CACHE_DIR = 'cache\uv-python'
            UV_PYTHON_INSTALL_DIR = 'tool-data\uv\python'
            UV_PYTHON_BIN_DIR = 'bin'
            UV_TOOL_DIR = 'tool-data\uv\tools'
            UV_TOOL_BIN_DIR = 'bin'
            PIXI_HOME = 'tool-data\pixi'
            PIXI_CACHE_DIR = 'cache\pixi'
            RUSTUP_HOME = 'tool-data\rustup'
            CARGO_HOME = 'tool-data\cargo'
            SCCACHE_DIR = 'cache\sccache'
            CCACHE_DIR = 'cache\ccache'
            CCACHE_TEMPDIR = 'cache\ccache\tmp'
        }
        Variables = @{}
        Path = @(
            'tool-data\cargo\bin'
            'tool-data\pixi\bin'
        )

        # Project-local paths can be backed by storage inside the capsule.
        # Directory caches use junctions by default; hard links are valid only
        # for profiles with Kind = 'File'.
        ProjectLinks = @{
            'cargo-target' = @{
                Kind = 'Directory'
                ProjectPath = 'target'
                StorePath = 'project-cache\{ProjectId}\cargo-target'
                LinkType = 'Junction'
            }
        }


        # Tool-native repair is used for metadata and launchers that cannot be
        # fixed by reconnecting a directory junction. uv receipts remain the
        # source of truth; capsulenv supplies the installed version only to the
        # repair command so relocation does not become an implicit upgrade.
        Relocation = @{
            Enabled = $true
            AutoRepair = $true
            Uv = @{
                Enabled = $true
                RepairManagedPython = $true
                RepairGlobalTools = $true
            }
            Pixi = @{
                Enabled = $true

                # pixi-global.toml can contain version ranges and Pixi does not
                # keep a documented global lock file. Keep global sync opt-in
                # unless a local configuration explicitly accepts re-resolution.
                RepairGlobal = $false
            }
            Workspaces = @{
                Enabled = $true
                RepairRegistered = $true
            }
        }
    }

    Bitwarden = @{
        Enabled = $true
        StartOnEnter = $true
        SetSshAuthSock = $true
        Authorization = 'always'
        ExecutableCandidates = @(
            'scoop\apps\bitwarden\current\Bitwarden.exe'
            'scoop\apps\bitwarden-portable\current\Bitwarden.exe'
            'scoop-global\apps\bitwarden\current\Bitwarden.exe'
            'scoop-global\apps\bitwarden-portable\current\Bitwarden.exe'
        )
    }

    Browsers = @{
        Firefox = @{
            Enabled = $true
            CommandNames = @('firefox.exe')
            ExecutableCandidates = @(
                'scoop\apps\firefox\current\firefox.exe'
                'scoop\apps\firefox-esr\current\firefox.exe'
            )
            ProfileCandidates = @(
                'scoop\persist\firefox\profile'
                'scoop\persist\firefox-esr\profile'
            )
            ProfileArgument = '-profile'
            ShellOnlyArguments = @('-no-remote')
        }

        Zen = @{
            Enabled = $true
            CommandNames = @('zen.exe')
            ExecutableCandidates = @(
                'scoop\apps\zen-browser\current\zen.exe'
                'scoop\apps\zen-browser-bin\current\zen.exe'
                'scoop\apps\zen\current\zen.exe'
            )
            ProfileCandidates = @(
                'scoop\persist\zen-browser\profile'
                'scoop\persist\zen-browser-bin\profile'
                'scoop\persist\zen\profile'
            )
            ProfileArgument = '-profile'
            ShellOnlyArguments = @('-no-remote')
        }
    }
}
