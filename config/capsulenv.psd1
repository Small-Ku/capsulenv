@{
    SchemaVersion = 2

    Scoop = @{
        Root = 'scoop'
        GlobalRoot = 'scoop-global'
        RehydrateOnRelocation = $true
        ReplayHooks = @{
            firefox = @('post_install')
            'firefox-esr' = @('post_install')
            'zen-browser' = @('post_install')
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
