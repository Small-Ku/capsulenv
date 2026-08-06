function Get-CapsulenvBrowserDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Firefox', 'Zen')]
        [string]$Browser
    )

    $configuration = Get-CapsulenvConfiguration
    $definition = $configuration.Browsers[$Browser]
    if ($null -eq $definition) {
        throw "Browser is not configured: $Browser"
    }
    return $definition
}

function Get-CapsulenvBrowserStateRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Browser)

    $context = Get-CapsulenvContext
    return Join-Path $context.StateRoot ("browsers\{0}" -f $Browser.ToLowerInvariant())
}

function Get-CapsulenvBrowserExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Firefox', 'Zen')]
        [string]$Browser
    )

    $definition = Get-CapsulenvBrowserDefinition -Browser $Browser
    return Find-CapsulenvExecutable `
        -Candidates @($definition.ExecutableCandidates) `
        -CommandNames @($definition.CommandNames)
}

function Get-CapsulenvBrowserProfileRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Firefox', 'Zen')]
        [string]$Browser
    )

    $definition = Get-CapsulenvBrowserDefinition -Browser $Browser
    return Resolve-CapsulenvPath -Path $definition.ProfileDir -AllowMissing
}

function Test-CapsulenvBrowserRunning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Firefox', 'Zen')]
        [string]$Browser
    )

    $definition = Get-CapsulenvBrowserDefinition -Browser $Browser
    foreach ($processName in @($definition.ProcessNames)) {
        if (Get-Process -Name $processName -ErrorAction SilentlyContinue) {
            return $true
        }
    }
    return $false
}

function Assert-CapsulenvBrowserStopped {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Firefox', 'Zen')]
        [string]$Browser,
        [switch]$Force
    )

    if ((Test-CapsulenvBrowserRunning -Browser $Browser) -and -not $Force) {
        throw "$Browser is running. Close it before changing or migrating its profile, or pass -Force at your own risk."
    }
}

function Backup-CapsulenvBrowserFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Browser,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $stateRoot = Get-CapsulenvBrowserStateRoot -Browser $Browser
    [void](New-Item -ItemType Directory -Path $stateRoot -Force)
    $backupPath = Join-Path $stateRoot ((Split-Path -Leaf $Path) + '.original')
    $missingMarker = $backupPath + '.missing'

    if ((Test-Path -LiteralPath $backupPath) -or (Test-Path -LiteralPath $missingMarker)) {
        return $false
    }

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    } else {
        Set-Content -LiteralPath $missingMarker -Value 'The original file did not exist.' -Encoding ASCII
    }
    return $true
}

function Restore-CapsulenvBrowserFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Browser,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $stateRoot = Get-CapsulenvBrowserStateRoot -Browser $Browser
    $backupPath = Join-Path $stateRoot ((Split-Path -Leaf $Path) + '.original')
    $missingMarker = $backupPath + '.missing'

    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force)
        Copy-Item -LiteralPath $backupPath -Destination $Path -Force
        Remove-Item -LiteralPath $backupPath -Force
        return $true
    }
    if (Test-Path -LiteralPath $missingMarker -PathType Leaf) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            Remove-Item -LiteralPath $Path -Force
        }
        Remove-Item -LiteralPath $missingMarker -Force
        return $true
    }
    return $false
}

function Restore-CapsulenvFileSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$Existed,
        [byte[]]$Content
    )

    if ($Existed) {
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force)
        [System.IO.File]::WriteAllBytes($Path, $Content)
    } elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Test-CapsulenvBrowserFileBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Browser,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $stateRoot = Get-CapsulenvBrowserStateRoot -Browser $Browser
    $backupPath = Join-Path $stateRoot ((Split-Path -Leaf $Path) + '.original')
    return (
        (Test-Path -LiteralPath $backupPath -PathType Leaf) -or
        (Test-Path -LiteralPath ($backupPath + '.missing') -PathType Leaf)
    )
}

function ConvertTo-CapsulenvMozillaPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    return ([System.IO.Path]::GetFullPath($Path) -replace '\\', '/')
}

function Resolve-CapsulenvMozillaProfilePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RegistryRoot,
        [Parameter(Mandatory = $true)]$Section
    )

    if (-not $Section.Contains('Path')) {
        return $null
    }

    $path = [string]$Section['Path']
    if ($Section.Contains('IsRelative') -and $Section['IsRelative'] -eq '1') {
        return [System.IO.Path]::GetFullPath((Join-Path $RegistryRoot $path))
    }
    return [System.IO.Path]::GetFullPath($path)
}

function Resolve-CapsulenvMozillaRegistryPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RegistryRoot,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $RegistryRoot $Path))
}

function Get-CapsulenvDefaultBrowserProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Firefox', 'Zen')]
        [string]$Browser
    )

    $definition = Get-CapsulenvBrowserDefinition -Browser $Browser
    $registryRoot = [Environment]::ExpandEnvironmentVariables([string]$definition.RegistryRoot)
    $profilesIni = Join-Path $registryRoot 'profiles.ini'
    $data = Read-CapsulenvIniFile -Path $profilesIni

    $profiles = New-Object System.Collections.Generic.List[object]
    foreach ($sectionName in @($data.Keys | Where-Object { $_ -match '^Profile\d+$' })) {
        $section = $data[$sectionName]
        $resolvedPath = Resolve-CapsulenvMozillaProfilePath -RegistryRoot $registryRoot -Section $section
        if ($resolvedPath) {
            $profiles.Add([pscustomobject]@{
                SectionName = $sectionName
                Section = $section
                Path = $resolvedPath
            })
        }
    }

    $installsIni = Join-Path $registryRoot 'installs.ini'
    if (Test-Path -LiteralPath $installsIni -PathType Leaf) {
        $installs = Read-CapsulenvIniFile -Path $installsIni
        foreach ($installName in @($installs.Keys | Where-Object { $_ -match '^Install' })) {
            $install = $installs[$installName]
            if (-not $install.Contains('Default')) {
                continue
            }
            $installDefault = Resolve-CapsulenvMozillaRegistryPath `
                -RegistryRoot $registryRoot `
                -Path ([string]$install['Default'])
            $matchingProfile = $profiles | Where-Object {
                [System.StringComparer]::OrdinalIgnoreCase.Equals($_.Path, $installDefault)
            } | Select-Object -First 1
            if ($matchingProfile) {
                return $matchingProfile.Path
            }
            if (Test-Path -LiteralPath $installDefault -PathType Container) {
                return $installDefault
            }
        }
    }

    $defaultProfile = $profiles | Where-Object {
        $_.Section.Contains('Default') -and $_.Section['Default'] -eq '1'
    } | Select-Object -First 1
    if ($defaultProfile) {
        return $defaultProfile.Path
    }

    $firstProfile = $profiles | Select-Object -First 1
    if ($firstProfile) {
        return $firstProfile.Path
    }
    return $null
}

function Copy-CapsulenvDirectoryContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    [void](New-Item -ItemType Directory -Path $Destination -Force)
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
}

function Get-CapsulenvBrowserMigrationStatePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Browser)

    return Join-Path (Get-CapsulenvBrowserStateRoot -Browser $Browser) 'profile-migration.json'
}

function Restore-CapsulenvMovedBrowserProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Browser)

    $statePath = Get-CapsulenvBrowserMigrationStatePath -Browser $Browser
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $false
    }

    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $source = [System.IO.Path]::GetFullPath([string]$state.Source)
    $target = [System.IO.Path]::GetFullPath([string]$state.Target)
    $sourceExists = Test-Path -LiteralPath $source -PathType Container
    $targetExists = Test-Path -LiteralPath $target -PathType Container

    if ($sourceExists -and $targetExists) {
        throw "Cannot restore moved $Browser profile because both source and target exist: $source ; $target"
    }
    if (-not $sourceExists -and -not $targetExists) {
        throw "Cannot restore moved $Browser profile because both source and target are missing."
    }

    if ($targetExists) {
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force)
        Move-Item -LiteralPath $target -Destination $source
    }

    Remove-Item -LiteralPath $statePath -Force
    return $true
}

function Move-CapsulenvBrowserProfileData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Firefox', 'Zen')]
        [string]$Browser,
        [ValidateSet('None', 'Copy', 'Move')]
        [string]$Mode = 'None',
        [switch]$Force
    )

    if ($Mode -eq 'None') {
        return $false
    }

    Assert-CapsulenvBrowserStopped -Browser $Browser -Force:$Force
    $target = Get-CapsulenvBrowserProfileRoot -Browser $Browser
    if ((Test-Path -LiteralPath $target) -and (Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue)) {
        Write-CapsulenvMessage -Level Detail -Message "$Browser target profile is not empty; migration skipped."
        return $false
    }

    $source = Get-CapsulenvDefaultBrowserProfile -Browser $Browser
    if (-not $source -or -not (Test-Path -LiteralPath $source -PathType Container)) {
        Write-CapsulenvMessage -Level Warning -Message "No existing $Browser default profile was found to migrate."
        return $false
    }
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals(
        [System.IO.Path]::GetFullPath($source),
        [System.IO.Path]::GetFullPath($target)
    )) {
        return $false
    }

    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force)
    if ($Mode -eq 'Move') {
        $statePath = Get-CapsulenvBrowserMigrationStatePath -Browser $Browser
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            throw "An unfinished $Browser profile move is already recorded: $statePath"
        }
        if (Test-Path -LiteralPath $target -PathType Container) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force)
        [ordered]@{
            Browser = $Browser
            Source = [System.IO.Path]::GetFullPath($source)
            Target = [System.IO.Path]::GetFullPath($target)
        } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
        try {
            Move-Item -LiteralPath $source -Destination $target
        } catch {
            if ((Test-Path -LiteralPath $source -PathType Container) -and -not (Test-Path -LiteralPath $target)) {
                Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
            }
            throw
        }
    } else {
        Copy-CapsulenvDirectoryContent -Source $source -Destination $target
    }

    foreach ($lockName in @('parent.lock', '.parentlock', 'lock')) {
        $lockPath = Join-Path $target $lockName
        if (Test-Path -LiteralPath $lockPath) {
            Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
        }
    }
    Write-CapsulenvMessage -Level Success -Message "$Browser profile data migrated using mode: $Mode"
    return $true
}

function Write-CapsulenvBrowserTextFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $temporaryPath = "$Path.capsulenv.$PID.tmp"
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $Content, $encoding)
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-CapsulenvManagedUserJs {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProfilePath)

    $userJs = Join-Path $ProfilePath 'user.js'
    if (-not (Test-Path -LiteralPath $userJs -PathType Leaf)) {
        return $false
    }

    $existing = [System.IO.File]::ReadAllText($userJs)
    $pattern = '(?ms)^\s*// BEGIN CAPSULENV MANAGED.*?^\s*// END CAPSULENV MANAGED\s*'
    if (-not [regex]::IsMatch($existing, $pattern)) {
        return $false
    }
    $unmanaged = [regex]::Replace($existing, $pattern, '').TrimEnd()
    if ($unmanaged) {
        Write-CapsulenvBrowserTextFile -Path $userJs -Content ($unmanaged + "`r`n")
    } else {
        Remove-Item -LiteralPath $userJs -Force
    }
    return ($existing -ne $unmanaged)
}

function Set-CapsulenvManagedUserJs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Browser,
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [Parameter(Mandatory = $true)][string]$CachePath
    )

    $userJs = Join-Path $ProfilePath 'user.js'
    $begin = '// BEGIN CAPSULENV MANAGED'
    $end = '// END CAPSULENV MANAGED'
    $existing = if (Test-Path -LiteralPath $userJs) {
        [System.IO.File]::ReadAllText($userJs)
    } else {
        ''
    }
    $pattern = '(?ms)^\s*// BEGIN CAPSULENV MANAGED.*?^\s*// END CAPSULENV MANAGED\s*'
    $unmanaged = [regex]::Replace($existing, $pattern, '').TrimEnd()
    $escapedCache = (ConvertTo-CapsulenvMozillaPath -Path $CachePath).Replace('"', '\"')
    $managed = @(
        $begin,
        ('user_pref("browser.cache.disk.parent_directory", "{0}");' -f $escapedCache),
        'user_pref("browser.shell.checkDefaultBrowser", false);',
        $end
    ) -join "`r`n"

    $content = if ($unmanaged) { "$unmanaged`r`n`r`n$managed`r`n" } else { "$managed`r`n" }
    Write-CapsulenvBrowserTextFile -Path $userJs -Content $content
}

function Register-CapsulenvBrowserProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Firefox', 'Zen')]
        [string]$Browser,
        [ValidateSet('None', 'Copy', 'Move')]
        [string]$Migrate = 'None',
        [switch]$InstallDefault,
        [switch]$Force
    )

    $definition = Get-CapsulenvBrowserDefinition -Browser $Browser
    if (-not $definition.Enabled) {
        return
    }
    Assert-CapsulenvBrowserStopped -Browser $Browser -Force:$Force

    $registryRoot = [Environment]::ExpandEnvironmentVariables([string]$definition.RegistryRoot)
    [void](New-Item -ItemType Directory -Path $registryRoot -Force)
    $profilesIni = Join-Path $registryRoot 'profiles.ini'
    $installsIni = Join-Path $registryRoot 'installs.ini'
    $profilesExistedBefore = Test-Path -LiteralPath $profilesIni -PathType Leaf
    $profilesBefore = if ($profilesExistedBefore) { [System.IO.File]::ReadAllBytes($profilesIni) } else { $null }
    $installsExistedBefore = Test-Path -LiteralPath $installsIni -PathType Leaf
    $installsBefore = if ($installsExistedBefore) { [System.IO.File]::ReadAllBytes($installsIni) } else { $null }
    $profilesBackupCreated = Backup-CapsulenvBrowserFile -Browser $Browser -Path $profilesIni
    $installsBackupCreated = $false
    if ($InstallDefault -and (Test-Path -LiteralPath $installsIni -PathType Leaf)) {
        $installsBackupCreated = Backup-CapsulenvBrowserFile -Browser $Browser -Path $installsIni
    }

    try {
        [void](Move-CapsulenvBrowserProfileData -Browser $Browser -Mode $Migrate -Force:$Force)
        $profilePath = New-CapsulenvDirectory -Path $definition.ProfileDir
        $cachePath = New-CapsulenvDirectory -Path $definition.CacheDir
        Set-CapsulenvManagedUserJs -Browser $Browser -ProfilePath $profilePath -CachePath $cachePath

        $data = Read-CapsulenvIniFile -Path $profilesIni
        Set-CapsulenvIniValue -Data $data -Section 'General' -Name 'StartWithLastProfile' -Value '1'
        Set-CapsulenvIniValue -Data $data -Section 'General' -Name 'Version' -Value '2'

        $targetSection = $null
        $maxIndex = -1
        foreach ($sectionName in @($data.Keys)) {
            if ($sectionName -match '^Profile(\d+)$') {
                $index = [int]$matches[1]
                if ($index -gt $maxIndex) { $maxIndex = $index }
                $section = $data[$sectionName]
                if ($section.Contains('Name') -and $section['Name'] -eq [string]$definition.ProfileName) {
                    $targetSection = $sectionName
                }
            }
        }
        if (-not $targetSection) {
            $targetSection = 'Profile{0}' -f ($maxIndex + 1)
        }

        $makeDefault = $definition.ContainsKey('MakeDefaultProfile') -and [bool]$definition.MakeDefaultProfile
        if ($makeDefault) {
            foreach ($sectionName in @($data.Keys | Where-Object { $_ -match '^Profile\d+$' })) {
                $section = $data[$sectionName]
                if ($section.Contains('Default')) {
                    $section.Remove('Default')
                }
            }
        } elseif ($data.Contains($targetSection) -and $data[$targetSection].Contains('Default')) {
            $data[$targetSection].Remove('Default')
        }

        Set-CapsulenvIniValue -Data $data -Section $targetSection -Name 'Name' -Value ([string]$definition.ProfileName)
        Set-CapsulenvIniValue -Data $data -Section $targetSection -Name 'IsRelative' -Value '0'
        Set-CapsulenvIniValue -Data $data -Section $targetSection -Name 'Path' -Value (ConvertTo-CapsulenvMozillaPath -Path $profilePath)
        if ($makeDefault) {
            Set-CapsulenvIniValue -Data $data -Section $targetSection -Name 'Default' -Value '1'
        }
        Write-CapsulenvIniFile -Path $profilesIni -Data $data

        if ($InstallDefault -and (Test-Path -LiteralPath $installsIni -PathType Leaf)) {
            $installs = Read-CapsulenvIniFile -Path $installsIni
            foreach ($sectionName in @($installs.Keys | Where-Object { $_ -match '^Install' })) {
                Set-CapsulenvIniValue -Data $installs -Section $sectionName -Name 'Default' -Value (ConvertTo-CapsulenvMozillaPath -Path $profilePath)
                Set-CapsulenvIniValue -Data $installs -Section $sectionName -Name 'Locked' -Value '1'
            }
            Write-CapsulenvIniFile -Path $installsIni -Data $installs
        }
    } catch {
        $registrationError = $_
        try { [void](Remove-CapsulenvManagedUserJs -ProfilePath (Get-CapsulenvBrowserProfileRoot -Browser $Browser)) } catch { Write-Warning $_ }
        try { [void](Restore-CapsulenvMovedBrowserProfile -Browser $Browser) } catch { Write-Warning $_ }
        try {
            if ($profilesBackupCreated) {
                [void](Restore-CapsulenvBrowserFile -Browser $Browser -Path $profilesIni)
            } else {
                Restore-CapsulenvFileSnapshot -Path $profilesIni -Existed $profilesExistedBefore -Content $profilesBefore
            }
        } catch { Write-Warning $_ }
        try {
            if ($installsBackupCreated) {
                [void](Restore-CapsulenvBrowserFile -Browser $Browser -Path $installsIni)
            } else {
                Restore-CapsulenvFileSnapshot -Path $installsIni -Existed $installsExistedBefore -Content $installsBefore
            }
        } catch { Write-Warning $_ }
        throw $registrationError
    }

    Write-CapsulenvMessage -Level Success -Message "$Browser profile registered at $profilePath"
}

function Restore-CapsulenvBrowserProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Firefox', 'Zen')]
        [string]$Browser,
        [switch]$Force
    )

    Assert-CapsulenvBrowserStopped -Browser $Browser -Force:$Force
    $definition = Get-CapsulenvBrowserDefinition -Browser $Browser
    $registryRoot = [Environment]::ExpandEnvironmentVariables([string]$definition.RegistryRoot)
    $profilesIni = Join-Path $registryRoot 'profiles.ini'
    $installsIni = Join-Path $registryRoot 'installs.ini'

    $migrationStatePath = Get-CapsulenvBrowserMigrationStatePath -Browser $Browser
    $hasMigrationState = Test-Path -LiteralPath $migrationStatePath -PathType Leaf
    $hasProfilesBackup = Test-CapsulenvBrowserFileBackup -Browser $Browser -Path $profilesIni
    $hasInstallsBackup = Test-CapsulenvBrowserFileBackup -Browser $Browser -Path $installsIni
    if (-not $hasMigrationState -and -not $hasProfilesBackup -and -not $hasInstallsBackup) {
        throw "No saved $Browser profile registration or move exists."
    }

    $managedProfilePath = Get-CapsulenvBrowserProfileRoot -Browser $Browser
    if ($hasMigrationState) {
        $migrationState = Get-Content -LiteralPath $migrationStatePath -Raw | ConvertFrom-Json
        if (Test-Path -LiteralPath ([string]$migrationState.Target) -PathType Container) {
            $managedProfilePath = [string]$migrationState.Target
        } elseif (Test-Path -LiteralPath ([string]$migrationState.Source) -PathType Container) {
            $managedProfilePath = [string]$migrationState.Source
        }
    }
    [void](Remove-CapsulenvManagedUserJs -ProfilePath $managedProfilePath)
    $movedProfileRestored = Restore-CapsulenvMovedBrowserProfile -Browser $Browser
    $profilesRestored = Restore-CapsulenvBrowserFile -Browser $Browser -Path $profilesIni
    $installsRestored = Restore-CapsulenvBrowserFile -Browser $Browser -Path $installsIni

    $dataMessage = if ($movedProfileRestored) {
        'Moved profile data was returned to its original location.'
    } else {
        'Portable profile data was retained.'
    }
    Write-CapsulenvMessage -Level Success -Message "$Browser profile registration restored. $dataMessage"
}

function ConvertTo-CapsulenvProcessArgument {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Argument)

    if (-not $Argument) {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashCount = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ([int]$character -eq 92) {
            $backslashCount++
            continue
        }
        if ($character -eq '"') {
            if ($backslashCount -gt 0) {
                [void]$builder.Append([string]::new([char]92, (($backslashCount * 2) + 1)))
            } else {
                [void]$builder.Append([char]92)
            }
            [void]$builder.Append('"')
            $backslashCount = 0
            continue
        }
        if ($backslashCount -gt 0) {
            [void]$builder.Append([string]::new([char]92, $backslashCount))
            $backslashCount = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashCount -gt 0) {
        [void]$builder.Append([string]::new([char]92, ($backslashCount * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Start-CapsulenvBrowser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Firefox', 'Zen')]
        [string]$Browser,
        [string[]]$Arguments = @()
    )

    [void](Set-CapsulenvSessionEnvironment)
    $definition = Get-CapsulenvBrowserDefinition -Browser $Browser
    $profilePath = New-CapsulenvDirectory -Path $definition.ProfileDir
    $cachePath = New-CapsulenvDirectory -Path $definition.CacheDir
    Set-CapsulenvManagedUserJs -Browser $Browser -ProfilePath $profilePath -CachePath $cachePath

    $executable = Get-CapsulenvBrowserExecutable -Browser $Browser
    if (-not $executable) {
        throw "$Browser executable was not found. Install it with Scoop or configure ExecutableCandidates."
    }

    $quotedProfilePath = ConvertTo-CapsulenvProcessArgument -Argument $profilePath
    $launchArguments = @('--profile', $quotedProfilePath)
    if ($definition.NewInstance) {
        $launchArguments += '--new-instance'
    }
    $launchArguments += @($Arguments | ForEach-Object { ConvertTo-CapsulenvProcessArgument -Argument $_ })
    [void](Start-Process -FilePath $executable -ArgumentList $launchArguments -WorkingDirectory (Split-Path -Parent $executable))
}

##MOD_EXEC## Export-ModuleMember -Function Register-CapsulenvBrowserProfile, Restore-CapsulenvBrowserProfile, Start-CapsulenvBrowser, Get-CapsulenvBrowserExecutable, Get-CapsulenvBrowserProfileRoot
