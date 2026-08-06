@{
    SchemaVersion = 3

    Scoop = @{
        Root = 'scoop'
        GlobalRoot = 'scoop-global'
        RehydrateOnRelocation = $true
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
        PathVariables = @{}
        Variables = @{}
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
        }

        Zen = @{
            Enabled = $true
            CommandNames = @('zen.exe')
            ExecutableCandidates = @(
                'scoop\apps\zen-browser\current\zen.exe'
                'scoop\apps\zen-browser-bin\current\zen.exe'
                'scoop\apps\zen\current\zen.exe'
            )
        }
    }
}
