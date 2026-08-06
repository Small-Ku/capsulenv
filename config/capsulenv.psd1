@{
    SchemaVersion = 1

    Scoop = @{
        Root = 'scoop'
        ConfigHome = 'data\xdg'
        ResetShimsOnEnter = $true
    }

    Environment = @{
        Path = @('bin')
        PathVariables = @{}
        Variables = @{}
    }

    Bitwarden = @{
        Enabled = $true
        AppDataDir = 'data\bitwarden'
        StartOnEnter = $true
        SetSshAuthSock = $true
        ExecutableCandidates = @(
            'scoop\apps\bitwarden\current\Bitwarden.exe'
            'scoop\apps\bitwarden-portable\current\Bitwarden-Portable.exe'
            'scoop\apps\bitwarden-portable\current\Bitwarden.exe'
        )
    }

    Browsers = @{
        Firefox = @{
            Enabled = $true
            AutoRegisterProfile = $true
            RegisterInstallDefaults = $false
            MakeDefaultProfile = $false
            ProfileName = 'capsulenv'
            ProfileDir = 'data\browsers\firefox\profile'
            CacheDir = 'data\browsers\firefox\cache'
            RegistryRoot = '%APPDATA%\Mozilla\Firefox'
            NewInstance = $true
            ProcessNames = @('firefox')
            CommandNames = @('firefox.exe')
            ExecutableCandidates = @(
                'scoop\apps\firefox\current\firefox.exe'
                'scoop\apps\firefox-esr\current\firefox.exe'
            )
        }

        Zen = @{
            Enabled = $true
            AutoRegisterProfile = $true
            RegisterInstallDefaults = $false
            MakeDefaultProfile = $false
            ProfileName = 'capsulenv'
            ProfileDir = 'data\browsers\zen\profile'
            CacheDir = 'data\browsers\zen\cache'
            RegistryRoot = '%APPDATA%\zen'
            NewInstance = $true
            ProcessNames = @('zen', 'zen-alpha')
            CommandNames = @('zen.exe')
            ExecutableCandidates = @(
                'scoop\apps\zen-browser\current\zen.exe'
                'scoop\apps\zen-browser-bin\current\zen.exe'
                'scoop\apps\zen\current\zen.exe'
            )
        }
    }
}
