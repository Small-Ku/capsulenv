@{
    SchemaVersion = 10

    Scoop = @{
        Root = 'scoop'
        GlobalRoot = 'scoop-global'
        Cache = 'cache\scoop'
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
            librewolf = @(
                @{ Path = 'Profiles\Default\compatibility.ini'; Format = 'text'; Processes = @('librewolf'); MaxBytes = 1048576 }
                @{ Path = 'Profiles\Default\extensions.json'; Format = 'json'; Processes = @('librewolf'); MaxBytes = 67108864 }
                @{ Path = 'Profiles\Default\prefs.js'; Format = 'text'; Processes = @('librewolf'); MaxBytes = 16777216 }
                @{ Path = 'Profiles\Default\user.js'; Format = 'text'; Processes = @('librewolf'); MaxBytes = 16777216 }
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

        # Directory-valued environment variables. Shared caches stay under
        # cache/ and may be discarded; global installs/toolchains/state stay
        # under tool-data/ and must not be treated as disposable cache.
        PathVariables = @{
            # uv
            UV_CACHE_DIR = 'cache\uv'
            UV_PYTHON_CACHE_DIR = 'cache\uv-python'
            UV_PYTHON_INSTALL_DIR = 'tool-data\uv\python'
            UV_PYTHON_BIN_DIR = 'bin'
            UV_TOOL_DIR = 'tool-data\uv\tools'
            UV_TOOL_BIN_DIR = 'bin'

            # Pixi
            PIXI_HOME = 'tool-data\pixi'
            PIXI_CACHE_DIR = 'cache\pixi'

            # Node package managers
            NPM_CONFIG_CACHE = 'cache\npm'
            NPM_CONFIG_PREFIX = 'tool-data\npm'
            PNPM_HOME = 'tool-data\pnpm'
            PNPM_CONFIG_STORE_DIR = 'cache\pnpm-store'
            PNPM_CONFIG_CACHE_DIR = 'cache\pnpm'
            PNPM_CONFIG_STATE_DIR = 'tool-data\pnpm-state'
            PNPM_CONFIG_GLOBAL_DIR = 'tool-data\pnpm\global'
            PNPM_CONFIG_GLOBAL_BIN_DIR = 'tool-data\pnpm\bin'
            BUN_INSTALL_GLOBAL_DIR = 'tool-data\bun\global'
            BUN_INSTALL_BIN = 'tool-data\bun\bin'
            BUN_INSTALL_CACHE_DIR = 'cache\bun'

            # Go
            GOPATH = 'tool-data\go\gopath'
            GOBIN = 'tool-data\go\bin'
            GOCACHE = 'cache\go-build'
            GOMODCACHE = 'cache\go-mod'

            # Rust/Cargo and compiler caches
            RUSTUP_HOME = 'tool-data\rustup'
            CARGO_HOME = 'tool-data\cargo'
            SCCACHE_DIR = 'cache\sccache'
            CCACHE_DIR = 'cache\ccache'
            CCACHE_TEMPDIR = 'cache\ccache\tmp'
        }

        # File-valued environment variables are kept separately so init creates
        # their parent directories/files instead of accidentally making a
        # directory whose name should have been a config file. Empty ccache and
        # sccache configs intentionally prevent fallback to host user config.
        FileVariables = @{
            # Keep user/global configuration on the USB instead of falling back
            # to host profile files. These are intentionally empty on first use.
            GIT_CONFIG_GLOBAL = 'tool-data\git\config'
            UV_CONFIG_FILE = 'tool-data\uv\uv.toml'
            PIXI_CONFIG_FILE = 'tool-data\pixi\config.toml'
            NPM_CONFIG_USERCONFIG = 'tool-data\npm\npmrc'

            # Capsulenv explicitly points PSReadLine at this file when opening
            # a child shell. PowerShell itself has no equivalent history env var.
            CAPSULENV_PSREADLINE_HISTORY = 'tool-data\powershell\PSReadLine\ConsoleHost_history.txt'

            GOENV = 'tool-data\go\env'
            CCACHE_CONFIGPATH = 'tool-data\ccache\ccache.conf'
            SCCACHE_CONF = 'tool-data\sccache\config.toml'
        }
        Variables = @{}
        Path = @(
            'tool-data\cargo\bin'
            'tool-data\pixi\bin'
            'tool-data\npm'
            'tool-data\npm\bin'
            'tool-data\pnpm'
            'tool-data\pnpm\bin'
            'tool-data\bun\bin'
            'tool-data\go\bin'
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
        StartOnEnter = $false
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
            HostExecutableCandidates = @(
                '%ProgramFiles%\Mozilla Firefox\firefox.exe'
                '%ProgramFiles(x86)%\Mozilla Firefox\firefox.exe'
            )
            HostAppPathNames = @('firefox.exe')
            HostCommandNames = @('firefox.exe')
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
            HostExecutableCandidates = @(
                '%LocalAppData%\Programs\Zen Browser\zen.exe'
                '%ProgramFiles%\Zen Browser\zen.exe'
                '%ProgramFiles(x86)%\Zen Browser\zen.exe'
            )
            HostAppPathNames = @('zen.exe')
            HostCommandNames = @('zen.exe')
        }

        LibreWolf = @{
            Enabled = $true
            CommandNames = @('librewolf.exe')
            ExecutableCandidates = @(
                'scoop\apps\librewolf\current\LibreWolf\librewolf.exe'
                'scoop-global\apps\librewolf\current\LibreWolf\librewolf.exe'
            )
            ProfileCandidates = @(
                'scoop\persist\librewolf\Profiles\Default'
                'scoop-global\persist\librewolf\Profiles\Default'
            )
            ProfileArgument = '-profile'
            ShellOnlyArguments = @('-no-remote')
            HostExecutableCandidates = @(
                '%ProgramFiles%\LibreWolf\librewolf.exe'
                '%ProgramFiles(x86)%\LibreWolf\librewolf.exe'
                '%LocalAppData%\Programs\LibreWolf\librewolf.exe'
            )
            HostAppPathNames = @('librewolf.exe')
            HostCommandNames = @('librewolf.exe')
        }
    }
}
