Describe 'Capsulenv portable environment ownership contracts' {
    BeforeAll {
        $script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $env:CAPSULENV_ROOT = $script:Root
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
        $script:Build = & (Join-Path $script:Root 'Merge-ModuleScripts.ps1') -Clean
        Import-Module $script:Build.ModulePath -Force -DisableNameChecking
        $script:Module = @(Get-Module Capsulenv)[-1]
    }

    AfterAll {
        Remove-Module Capsulenv -Force -ErrorAction SilentlyContinue
    }

    It 'keeps app-data ownership with Scoop persist and lifecycle policy generic' {
        $config = Get-CapsulenvConfiguration -Refresh
        $config.Scoop.ContainsKey('ConfigHome') | Should -BeFalse
        $config.Bitwarden.ContainsKey('AppDataDir') | Should -BeFalse
        $config.Scoop.RelocationRepairs.ContainsKey('bitwarden') | Should -BeFalse
        foreach ($browserApp in @('firefox', 'firefox-esr', 'zen-browser', 'librewolf')) {
            $config.Scoop.RelocationRepairs.ContainsKey($browserApp) | Should -BeTrue
        }
        foreach ($browser in @('Firefox', 'FirefoxESR', 'Zen', 'LibreWolf')) {
            $config.Browsers[$browser].ContainsKey('ProfileDir') | Should -BeFalse
            $config.Browsers[$browser].ContainsKey('CacheDir') | Should -BeFalse
            [string]$config.Browsers[$browser].App | Should -Not -BeNullOrEmpty
            [string]$config.Browsers[$browser].ProfilePath | Should -Not -BeNullOrEmpty
        }
        [string]$config.Browsers.LibreWolf.ProfilePath | Should -Be 'Profiles\Default'
        $config.Bitwarden.ContainsKey('ExecutableCandidates') | Should -BeFalse
        [string]$config.Bitwarden.App | Should -Be 'bitwarden'
        $config.ContainsKey('Routines') | Should -BeTrue
        $config.ContainsKey('SingBox') | Should -BeFalse
        [string]$config.ToolStorage.Relocation.Uv.App | Should -Be 'uv'
        [string]$config.ToolStorage.Relocation.Pixi.App | Should -Be 'pixi'
    }

    It 'resolves portable tool variables to absolute capsule-owned locations without claiming project or scratch state' {
        $plan = & $script:Module { Get-CapsulenvEnvironmentPlan }
        [System.IO.Path]::IsPathRooted([string]$plan.Variables['SCOOP']) | Should -BeTrue
        [System.IO.Path]::IsPathRooted([string]$plan.Variables['SCOOP_GLOBAL']) | Should -BeTrue
        $plan.Variables.Contains('XDG_CONFIG_HOME') | Should -BeFalse
        $plan.Variables.Contains('BITWARDEN_APPDATA_DIR') | Should -BeFalse
        foreach ($name in @(
            'UV_CACHE_DIR','UV_PYTHON_CACHE_DIR','UV_PYTHON_INSTALL_DIR','UV_PYTHON_BIN_DIR','UV_TOOL_DIR','UV_TOOL_BIN_DIR',
            'PIXI_HOME','PIXI_CACHE_DIR','NPM_CONFIG_CACHE','NPM_CONFIG_PREFIX','PNPM_HOME','PNPM_CONFIG_STORE_DIR',
            'PNPM_CONFIG_CACHE_DIR','PNPM_CONFIG_STATE_DIR','PNPM_CONFIG_GLOBAL_DIR','PNPM_CONFIG_GLOBAL_BIN_DIR',
            'BUN_INSTALL_GLOBAL_DIR','BUN_INSTALL_BIN','BUN_INSTALL_CACHE_DIR','GOPATH','GOBIN','GOCACHE','GOMODCACHE',
            'GIT_CONFIG_GLOBAL','UV_CONFIG_FILE','NPM_CONFIG_USERCONFIG','GOENV','RUSTUP_HOME','CARGO_HOME',
            'SCCACHE_DIR','SCCACHE_CONF','CCACHE_DIR','CCACHE_TEMPDIR','CCACHE_CONFIGPATH'
        )) {
            $plan.Variables.Contains($name) | Should -BeTrue -Because "$name must be capsule-owned"
            [System.IO.Path]::IsPathRooted([string]$plan.Variables[$name]) | Should -BeTrue
        }
        foreach ($name in @('CARGO_TARGET_DIR','GOTMPDIR','GOTELEMETRYDIR')) {
            $plan.Variables.Contains($name) | Should -BeFalse
        }
    }

    It 'separates file-valued config, disposable cache, and Scoop-owned package cache' {
        $status = @(Get-CapsulenvToolStorageStatus)
        $plan = & $script:Module { Get-CapsulenvToolStoragePlan }
        @($plan.Files).Count | Should -Be 8
        Initialize-CapsulenvToolStorage | Out-Null

        foreach ($name in @('GIT_CONFIG_GLOBAL','UV_CONFIG_FILE','PIXI_CONFIG_FILE','NPM_CONFIG_USERCONFIG','CAPSULENV_PSREADLINE_HISTORY','GOENV','CCACHE_CONFIGPATH','SCCACHE_CONF')) {
            $item = @($status | Where-Object Name -eq $name | Select-Object -First 1)
            if ($item.Count -eq 0) { $item = @(Get-CapsulenvToolStorageStatus | Where-Object Name -eq $name | Select-Object -First 1) }
            $item.Count | Should -Be 1
            $item[0].Kind | Should -Be 'File'
            $item[0].Class | Should -Be 'Config'
            Test-Path -LiteralPath $item[0].Value -PathType Leaf | Should -BeTrue
        }
        foreach ($name in @('UV_CACHE_DIR','PIXI_CACHE_DIR','NPM_CONFIG_CACHE','PNPM_CONFIG_STORE_DIR','BUN_INSTALL_CACHE_DIR','GOCACHE','GOMODCACHE','CCACHE_DIR','SCCACHE_DIR')) {
            $item = @(Get-CapsulenvToolStorageStatus | Where-Object Name -eq $name | Select-Object -First 1)
            $item.Count | Should -Be 1
            $item[0].Class | Should -Be 'Cache'
        }
        $scoopCache = @($status | Where-Object Name -eq 'SCOOP_CACHE' | Select-Object -First 1)
        $scoopCache.Count | Should -Be 1
        @($plan.Directories) | Should -Not -Contain $scoopCache[0].Value
    }

    It 'keeps capsule-relative project-cache identity stable' {
        $config = Get-CapsulenvConfiguration -Refresh
        $config.ToolStorage.ProjectLinks.ContainsKey('cargo-target') | Should -BeTrue
        $first = @(Get-CapsulenvProjectCacheStatus -ProjectPath $script:Root)
        $second = @(Get-CapsulenvProjectCacheStatus -ProjectPath $script:Root)
        $first.Count | Should -Be 1
        $first[0].ProjectId | Should -Be $second[0].ProjectId
    }

    It 'merges PATH case-insensitively and quotes native arguments predictably' {
        (& $script:Module { Merge-CapsulenvPath -ExistingPath 'C:\Tools;C:\Else' -Prepend @('c:\tools\', 'C:\New') }) | Should -Be 'c:\tools\;C:\New;C:\Else'
        (& $script:Module { ConvertTo-CapsulenvProcessArgument -Argument 'C:\Path With Space\' }) | Should -Be '"C:\Path With Space\\"'
    }
}
