@{
    SchemaVersion = 11

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

        # ShellOnly executes arbitrary Scoop lifecycle code only when the exact
        # hook content has been reviewed. Keys are SHA-256 fingerprints over
        # "<hook-kind>\n<hook-text>"; changed upstream scripts fail closed.
        ShellOnlyLifecyclePolicy = @{
            # Git for Windows: pre/post install and pre-uninstall only touch
            # the portable app/persist trees; host registry cleanup is skipped.
            'd6857b7f6285519dc3533297dcb7a65a87caa1609649fcbfab58ae953c3a1bb3' = 'Allow' # git pre_install
            '6b042340f965a08bd8ea56e9539323209be35a04b87b8443d641c6810dc5c014' = 'Allow' # git post_install
            '42d82cee7bdb43f03b9b03f248fdde9fb75ac7f813f0c15cf888fd3dd6972314' = 'Allow' # git pre_uninstall
            '3aa480bdaf42fb9d71b9461f4dcc94d15a0a85b2b2050bb0646c0003a951f45e' = 'Skip'  # git uninstaller registry import

            # PowerShell Core: create portable profile/reg files, but never
            # import host Explorer/file-context registry state in ShellOnly.
            'c920d94bd74d5db22ee044c0bea6b526f680e633953832d224bf9aabb350d97d' = 'Allow' # pwsh pre_install
            'dddc13ba33b5873c2a6b828c66e2a0aa7fb87ae8044e6d82e5d21dd91e1cfadb' = 'Allow' # pwsh post_install
            'f999bc68d63c37ea6a85909141fb3a88ac2dea05181e55075ddebbdd32e32c1c' = 'Skip'  # pwsh uninstaller registry import

            # 7-Zip: generated registry files remain capsule-local; the ARM64
            # extraction hook is content-pinned; host context-menu cleanup skips.
            '0d041655dbee067bfc7c9a953da35d1bfbbfa4c514f78a338e52b9eb24d059b7' = 'Allow' # 7zip ARM64 pre_install
            '1c06af011c6f4abe1ef55c23b5804841e5579d6ac384a431bf5966721911fa6a' = 'Allow' # 7zip post_install
            '3206ade55d362efb7245555b43c9a205f6dff093f0599b18660e9a4ea1af68b5' = 'Skip'  # 7zip uninstaller registry import
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

    UserIntegration = @{
        # Empty by default: changing Windows defaults requires an explicit
        # per-user choice. Set this to an installed Scoop app selector such as
        # librewolf, firefox, user/firefox, or global/librewolf. The selector
        # must have a matching Browsers entry below.
        DefaultBrowser = ''
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
                # Prefer the executable exposed by this installed Scoop app
                # manifest. Custom bucket app names and explicit scope selectors
                # are supported; tool-data remains a non-Scoop fallback.
                App = 'uv'
                BinName = 'uv'
                RepairManagedPython = $true
                RepairGlobalTools = $true
            }
            Pixi = @{
                Enabled = $true
                App = 'pixi'
                BinName = 'pixi'

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
        # Installed Scoop app selector. This may point at any compatible
        # Bitwarden desktop manifest, including a custom bucket app name.
        App = 'bitwarden'
        ShortcutName = 'Bitwarden'
        # Relative to the selected app's Scoop persist root.
        StatePath = 'bitwarden-appdata\data.json'
    }

    SingBox = @{
        Enabled = $true
        # Installed Scoop app selector. `user/` or `global/` may be used when
        # the same manifest exists in both portable roots.
        App = 'sing-box'
        BinName = 'sing-box'
        # Paths are relative to the selected app's Scoop persist root.
        ConfigPath = 'config.json'
        ConfigDirectory = ''
        AutoConnect = $true
        ExtraArguments = @()
    }

    Browsers = @{
        Firefox = @{
            Enabled = $true
            App = 'firefox'
            DisplayName = 'Firefox'
            BinName = 'firefox'
            ProfilePath = 'profile'
            ProfileArgument = '-profile'
            ShellOnlyArguments = @('-no-remote')
            HostExecutableCandidates = @(
                '%ProgramFiles%\Mozilla Firefox\firefox.exe'
                '%ProgramFiles(x86)%\Mozilla Firefox\firefox.exe'
            )
            HostAppPathNames = @('firefox.exe')
            HostCommandNames = @('firefox.exe')
        }

        FirefoxESR = @{
            Enabled = $true
            App = 'firefox-esr'
            DisplayName = 'Firefox ESR'
            BinName = 'firefox'
            ProfilePath = 'profile'
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
            App = 'zen-browser'
            DisplayName = 'Zen Browser'
            BinName = 'zen'
            ProfilePath = 'profile'
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
            App = 'librewolf'
            DisplayName = 'LibreWolf'
            BinName = 'librewolf'
            DefaultExecutablePath = 'LibreWolf\librewolf.exe'
            ProfilePath = 'Profiles\Default'
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
