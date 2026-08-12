function Get-CapsulenvBitwardenScoopAppName {
    [CmdletBinding()]
    param([string]$Executable)

    if ([string]::IsNullOrWhiteSpace($Executable)) {
        $Executable = Get-CapsulenvBitwardenExecutable
    }
    if ([string]::IsNullOrWhiteSpace($Executable)) {
        return $null
    }

    $normalized = [System.IO.Path]::GetFullPath($Executable)
    if ($normalized -match '[\\/]apps[\\/](?<app>[^\\/]+)[\\/]') {
        return [string]$Matches['app']
    }
    return $null
}

function Get-CapsulenvBitwardenStatePath {
    [CmdletBinding()]
    param([switch]$AllowMissing)

    $configuration = Get-CapsulenvConfiguration
    $context = Get-CapsulenvContext
    $candidates = New-Object System.Collections.Generic.List[string]
    $appNames = New-Object System.Collections.Generic.List[string]

    $executable = Get-CapsulenvBitwardenExecutable
    $detectedApp = Get-CapsulenvBitwardenScoopAppName -Executable $executable
    foreach ($appName in @($detectedApp, 'bitwarden', 'bitwarden-portable')) {
        if (-not [string]::IsNullOrWhiteSpace($appName) -and -not $appNames.Contains($appName)) {
            $appNames.Add($appName)
        }
    }

    if ($executable) {
        $candidates.Add((Join-Path (Split-Path -Parent $executable) 'bitwarden-appdata\data.json'))
    }

    foreach ($rootValue in @($configuration.Scoop.Root, $configuration.Scoop.GlobalRoot)) {
        $root = Resolve-CapsulenvPath -Path ([string]$rootValue) -AllowMissing
        foreach ($appName in $appNames) {
            $candidates.Add((Join-Path $root "persist\$appName\bitwarden-appdata\data.json"))
            $candidates.Add((Join-Path $root "apps\$appName\current\bitwarden-appdata\data.json"))
        }
    }

    $seen = @{}
    foreach ($candidate in $candidates) {
        $fullPath = [System.IO.Path]::GetFullPath($candidate)
        if ($seen.ContainsKey($fullPath)) {
            continue
        }
        $seen[$fullPath] = $true
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            return $fullPath
        }
    }

    if ($AllowMissing -and $candidates.Count -gt 0) {
        return [System.IO.Path]::GetFullPath($candidates[0])
    }

    $expectedApp = if ($detectedApp) { $detectedApp } else { 'bitwarden' }
    $expected = Join-Path $context.Root "scoop\apps\$expectedApp\current\bitwarden-appdata\data.json"
    throw "Bitwarden persisted state was not found. Start the Scoop-installed desktop app once, or verify its persist link. Expected near: $expected"
}

function Get-CapsulenvBitwardenDesktopSettingsBackupPath {
    $context = Get-CapsulenvContext
    return Join-Path $context.StateRoot 'bitwarden\desktop-settings.json'
}

function Read-CapsulenvUtf8TextFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowMissing
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if (-not $AllowMissing) {
            throw "File not found: $Path"
        }
        return [pscustomobject]@{
            Text = '{}'
            HasUtf8Bom = $false
            Existed = $false
        }
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = (
        $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF
    )
    return [pscustomobject]@{
        Text = [System.IO.File]::ReadAllText($Path)
        HasUtf8Bom = $hasBom
        Existed = $true
    }
}

function Assert-CapsulenvJsonObjectText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text)

    $parsed = $Text | ConvertFrom-Json
    if ($null -eq $parsed -or $parsed -isnot [pscustomobject]) {
        throw 'Bitwarden data.json must contain one top-level JSON object.'
    }
}

function Get-CapsulenvJsonStringEnd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JsonText,
        [Parameter(Mandatory = $true)][int]$StartIndex
    )

    if ($StartIndex -lt 0 -or $StartIndex -ge $JsonText.Length -or $JsonText[$StartIndex] -ne '"') {
        throw "Expected a JSON string at character $StartIndex."
    }

    $index = $StartIndex + 1
    while ($index -lt $JsonText.Length) {
        $character = $JsonText[$index]
        if ($character -eq '\') {
            $index += 2
            continue
        }
        if ($character -eq '"') {
            return $index + 1
        }
        $index++
    }

    throw "Unterminated JSON string at character $StartIndex."
}

function Get-CapsulenvJsonValueEnd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JsonText,
        [Parameter(Mandatory = $true)][int]$StartIndex
    )

    if ($StartIndex -lt 0 -or $StartIndex -ge $JsonText.Length) {
        throw "Expected a JSON value at character $StartIndex."
    }

    $first = $JsonText[$StartIndex]
    if ($first -eq '"') {
        return Get-CapsulenvJsonStringEnd -JsonText $JsonText -StartIndex $StartIndex
    }

    if ($first -eq '{' -or $first -eq '[') {
        $stack = New-Object 'System.Collections.Generic.Stack[char]'
        $stack.Push($first)
        $index = $StartIndex + 1
        $insideString = $false
        $escaped = $false

        while ($index -lt $JsonText.Length) {
            $character = $JsonText[$index]
            if ($insideString) {
                if ($escaped) {
                    $escaped = $false
                } elseif ($character -eq '\') {
                    $escaped = $true
                } elseif ($character -eq '"') {
                    $insideString = $false
                }
                $index++
                continue
            }

            if ($character -eq '"') {
                $insideString = $true
            } elseif ($character -eq '{' -or $character -eq '[') {
                $stack.Push($character)
            } elseif ($character -eq '}' -or $character -eq ']') {
                $opening = $stack.Pop()
                $expected = if ($opening -eq '{') { '}' } else { ']' }
                if ($character -ne $expected) {
                    throw "Mismatched JSON delimiter at character $index."
                }
                if ($stack.Count -eq 0) {
                    return $index + 1
                }
            }
            $index++
        }

        throw "Unterminated JSON value at character $StartIndex."
    }

    $index = $StartIndex
    while (
        $index -lt $JsonText.Length -and
        $JsonText[$index] -ne ',' -and
        $JsonText[$index] -ne '}'
    ) {
        $index++
    }

    $end = $index
    while ($end -gt $StartIndex -and [char]::IsWhiteSpace($JsonText[$end - 1])) {
        $end--
    }
    if ($end -le $StartIndex) {
        throw "Empty JSON value at character $StartIndex."
    }
    return $end
}

function Get-CapsulenvJsonTopLevelProperties {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$JsonText)

    Assert-CapsulenvJsonObjectText -Text $JsonText
    $properties = New-Object System.Collections.Generic.List[object]
    $index = 0

    while ($index -lt $JsonText.Length -and [char]::IsWhiteSpace($JsonText[$index])) {
        $index++
    }
    if ($index -ge $JsonText.Length -or $JsonText[$index] -ne '{') {
        throw 'Bitwarden data.json is not a top-level JSON object.'
    }
    $index++

    while ($index -lt $JsonText.Length) {
        while ($index -lt $JsonText.Length -and [char]::IsWhiteSpace($JsonText[$index])) {
            $index++
        }
        if ($index -lt $JsonText.Length -and $JsonText[$index] -eq '}') {
            return $properties.ToArray()
        }
        if ($index -ge $JsonText.Length -or $JsonText[$index] -ne '"') {
            throw "Expected a top-level JSON property at character $index."
        }

        $propertyStart = $index
        $nameEnd = Get-CapsulenvJsonStringEnd -JsonText $JsonText -StartIndex $index
        $nameLiteral = $JsonText.Substring($index, $nameEnd - $index)
        $name = [string]($nameLiteral | ConvertFrom-Json)
        $index = $nameEnd

        while ($index -lt $JsonText.Length -and [char]::IsWhiteSpace($JsonText[$index])) {
            $index++
        }
        if ($index -ge $JsonText.Length -or $JsonText[$index] -ne ':') {
            throw "Expected ':' after JSON property $name."
        }
        $index++
        while ($index -lt $JsonText.Length -and [char]::IsWhiteSpace($JsonText[$index])) {
            $index++
        }

        $valueStart = $index
        $valueEnd = Get-CapsulenvJsonValueEnd -JsonText $JsonText -StartIndex $valueStart
        $index = $valueEnd
        while ($index -lt $JsonText.Length -and [char]::IsWhiteSpace($JsonText[$index])) {
            $index++
        }

        $properties.Add([pscustomobject]@{
            Name = $name
            PropertyStart = $propertyStart
            ValueStart = $valueStart
            ValueEnd = $valueEnd
            EntryEnd = $index
        })

        if ($index -ge $JsonText.Length) {
            throw 'Bitwarden data.json ended before its top-level object was closed.'
        }
        if ($JsonText[$index] -eq ',') {
            $index++
            continue
        }
        if ($JsonText[$index] -eq '}') {
            return $properties.ToArray()
        }
        throw "Expected ',' or '}' after JSON property $name."
    }

    throw 'Bitwarden data.json ended before its top-level object was closed.'
}

function Get-CapsulenvJsonPropertyMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JsonText,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $matches = @(
        Get-CapsulenvJsonTopLevelProperties -JsonText $JsonText |
            Where-Object { $_.Name -ceq $Name }
    )
    if ($matches.Count -gt 1) {
        throw "Duplicate top-level JSON property found in Bitwarden state: $Name"
    }
    if ($matches.Count -eq 0) {
        return $null
    }
    return $matches[0]
}

function Get-CapsulenvJsonPropertySnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JsonText,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $match = Get-CapsulenvJsonPropertyMatch -JsonText $JsonText -Name $Name
    return [pscustomobject]@{
        Name = $Name
        Exists = ($null -ne $match)
        Literal = $(
            if ($match) {
                $JsonText.Substring($match.ValueStart, $match.ValueEnd - $match.ValueStart)
            } else {
                $null
            }
        )
    }
}

function Set-CapsulenvJsonPropertyLiteral {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JsonText,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Literal
    )

    [void]($Literal | ConvertFrom-Json)
    $match = Get-CapsulenvJsonPropertyMatch -JsonText $JsonText -Name $Name
    if ($match) {
        return (
            $JsonText.Substring(0, $match.ValueStart) +
            $Literal +
            $JsonText.Substring($match.ValueEnd)
        )
    }

    $closingIndex = $JsonText.LastIndexOf('}')
    $openingIndex = $JsonText.IndexOf('{')
    if ($openingIndex -lt 0 -or $closingIndex -le $openingIndex) {
        throw 'Bitwarden data.json is not a top-level JSON object.'
    }

    $propertyName = ConvertTo-Json -InputObject $Name -Compress
    $property = $propertyName + ': ' + $Literal
    $body = $JsonText.Substring($openingIndex + 1, $closingIndex - $openingIndex - 1)
    $newline = if ($JsonText.Contains("`r`n")) { "`r`n" } else { "`n" }

    if ([string]::IsNullOrWhiteSpace($body)) {
        $replacement = $newline + '  ' + $property + $newline
        return $JsonText.Substring(0, $openingIndex + 1) + $replacement + $JsonText.Substring($closingIndex)
    }

    $beforeClose = $JsonText.Substring(0, $closingIndex)
    $trimmedBefore = $beforeClose.TrimEnd()
    $trailingWhitespace = $beforeClose.Substring($trimmedBefore.Length)
    $separator = if ($JsonText.Contains("`n")) { ',' + $newline + '  ' } else { ', ' }
    return $trimmedBefore + $separator + $property + $trailingWhitespace + $JsonText.Substring($closingIndex)
}

function Remove-CapsulenvJsonProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JsonText,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $match = Get-CapsulenvJsonPropertyMatch -JsonText $JsonText -Name $Name
    if (-not $match) {
        return $JsonText
    }

    $after = $match.EntryEnd
    if ($after -lt $JsonText.Length -and $JsonText[$after] -eq ',') {
        return $JsonText.Remove($match.PropertyStart, ($after + 1) - $match.PropertyStart)
    }

    $before = $match.PropertyStart - 1
    while ($before -ge 0 -and [char]::IsWhiteSpace($JsonText[$before])) {
        $before--
    }
    if ($before -ge 0 -and $JsonText[$before] -eq ',') {
        return $JsonText.Remove($before, $match.EntryEnd - $before)
    }

    return $JsonText.Remove($match.PropertyStart, $match.EntryEnd - $match.PropertyStart)
}

function Write-CapsulenvBitwardenStateText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][bool]$HasUtf8Bom
    )

    Assert-CapsulenvJsonObjectText -Text $Text
    $directory = Split-Path -Parent $Path
    [void](New-Item -ItemType Directory -Path $directory -Force)

    $tempPath = Join-Path $directory ('.capsulenv-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    $rollbackPath = Join-Path $directory ('.capsulenv-{0}.rollback' -f [Guid]::NewGuid().ToString('N'))

    $encoding = [System.Text.UTF8Encoding]::new($HasUtf8Bom)
    [System.IO.File]::WriteAllText($tempPath, $Text, $encoding)
    Assert-CapsulenvJsonObjectText -Text ([System.IO.File]::ReadAllText($tempPath))

    $destinationExisted = Test-Path -LiteralPath $Path -PathType Leaf
    try {
        if ($destinationExisted) {
            [System.IO.File]::Replace($tempPath, $Path, $rollbackPath, $true)
        } else {
            [System.IO.File]::Move($tempPath, $Path)
        }
    } catch {
        if ($destinationExisted -and (Test-Path -LiteralPath $rollbackPath -PathType Leaf)) {
            Copy-Item -LiteralPath $rollbackPath -Destination $Path -Force
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
        if (Test-Path -LiteralPath $rollbackPath) {
            Remove-Item -LiteralPath $rollbackPath -Force
        }
    }
}

function Get-CapsulenvBitwardenAuthorizationValue {
    [CmdletBinding()]
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $configuration = Get-CapsulenvConfiguration
        $Value = [string]$configuration.Bitwarden.Authorization
    }

    switch ($Value.ToLowerInvariant()) {
        'always' { return 'always' }
        'never' { return 'never' }
        'rememberuntillock' { return 'rememberUntilLock' }
        'remember-until-lock' { return 'rememberUntilLock' }
        default { throw "Unsupported Bitwarden SSH authorization behavior: $Value" }
    }
}

function Get-CapsulenvBitwardenPromptPropertyNames {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$JsonText)

    $names = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($property in @(Get-CapsulenvJsonTopLevelProperties -JsonText $JsonText)) {
        $name = [string]$property.Name
        if ($name -cmatch '^user_[^"]+_desktopSettings_sshAgentRememberAuthorizations$') {
            if (-not $seen.ContainsKey($name)) {
                $seen[$name] = $true
                $names.Add($name)
            }
            continue
        }

        if ($name -cmatch '^user_(?<id>[0-9A-Fa-f-]{36})_') {
            $promptName = 'user_{0}_desktopSettings_sshAgentRememberAuthorizations' -f $Matches['id']
            if (-not $seen.ContainsKey($promptName)) {
                $seen[$promptName] = $true
                $names.Add($promptName)
            }
        }
    }

    return $names.ToArray()
}

function Read-CapsulenvBitwardenDesktopSettingsBackup {
    [CmdletBinding()]
    param()

    $path = Get-CapsulenvBitwardenDesktopSettingsBackupPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Save-CapsulenvBitwardenDesktopSettingsBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Backup)

    $path = Get-CapsulenvBitwardenDesktopSettingsBackupPath
    $text = $Backup | ConvertTo-Json -Depth 8
    Write-CapsulenvBitwardenStateText -Path $path -Text $text -HasUtf8Bom $true
}

function Add-CapsulenvBitwardenDesktopSettingsBackupEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Backup,
        [Parameter(Mandatory = $true)]$Snapshot
    )

    $existing = @($Backup.Entries | Where-Object { $_.Name -eq $Snapshot.Name })
    if ($existing.Count -gt 0) {
        return
    }

    $Backup.Entries = @($Backup.Entries) + @(
        [pscustomobject]@{
            Name = [string]$Snapshot.Name
            Exists = [bool]$Snapshot.Exists
            Literal = $Snapshot.Literal
        }
    )
}

function Set-CapsulenvBitwardenDesktopSshAgent {
    [CmdletBinding()]
    param(
        [string]$Authorization,
        [switch]$NoStart
    )

    $executable = Get-CapsulenvBitwardenExecutable
    if (-not $executable) {
        throw 'The Scoop-installed Bitwarden desktop executable was not found; refusing to create detached app state.'
    }

    $authorizationValue = Get-CapsulenvBitwardenAuthorizationValue -Value $Authorization
    Stop-CapsulenvBitwarden -Force

    try {
        [void](Set-CapsulenvSessionEnvironment)
        $appName = Get-CapsulenvBitwardenScoopAppName -Executable $executable
        if ($appName) {
            [void](Reset-CapsulenvScoop -Apps @($appName) -Quiet)
        }

        $statePath = Get-CapsulenvBitwardenStatePath -AllowMissing
        $state = Read-CapsulenvUtf8TextFile -Path $statePath -AllowMissing
        Assert-CapsulenvJsonObjectText -Text $state.Text
        $json = [string]$state.Text

        $backupPath = Get-CapsulenvBitwardenDesktopSettingsBackupPath
        $backupAlreadyExisted = Test-Path -LiteralPath $backupPath -PathType Leaf
        $backup = Read-CapsulenvBitwardenDesktopSettingsBackup
        if ($null -eq $backup) {
            $backup = [pscustomobject]@{
                SchemaVersion = 1
                CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
                StatePathAtBackup = $statePath
                StateFileExisted = [bool]$state.Existed
                Entries = @()
            }
        }

        $enabledName = 'global_desktopSettings_sshAgentEnabled'
        $enabledSnapshot = Get-CapsulenvJsonPropertySnapshot -JsonText $json -Name $enabledName
        Add-CapsulenvBitwardenDesktopSettingsBackupEntry -Backup $backup -Snapshot $enabledSnapshot
        $json = Set-CapsulenvJsonPropertyLiteral -JsonText $json -Name $enabledName -Literal 'true'

        $promptNames = @(Get-CapsulenvBitwardenPromptPropertyNames -JsonText $json)
        $authorizationLiteral = ConvertTo-Json -InputObject $authorizationValue -Compress
        foreach ($name in $promptNames) {
            $snapshot = Get-CapsulenvJsonPropertySnapshot -JsonText $json -Name $name
            Add-CapsulenvBitwardenDesktopSettingsBackupEntry -Backup $backup -Snapshot $snapshot
            $json = Set-CapsulenvJsonPropertyLiteral -JsonText $json -Name $name -Literal $authorizationLiteral
        }

        if ($promptNames.Count -eq 0 -and $authorizationValue -ne 'always') {
            Write-CapsulenvMessage -Level Warning -Message 'No Bitwarden account namespace exists in data.json yet. The agent was enabled, but the non-default authorization behavior will be applied after signing in and rerunning setup.'
        }

        Save-CapsulenvBitwardenDesktopSettingsBackup -Backup $backup
        try {
            Write-CapsulenvBitwardenStateText -Path $statePath -Text $json -HasUtf8Bom ([bool]$state.HasUtf8Bom)
        } catch {
            if (-not $backupAlreadyExisted -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
                Remove-Item -LiteralPath $backupPath -Force
            }
            throw
        }

        Write-CapsulenvMessage -Level Success -Message "Bitwarden SSH Agent enabled in Scoop-persisted settings. Authorization=$authorizationValue"
    } finally {
        if (-not $NoStart) {
            Start-CapsulenvBitwarden
        }
    }
}

function Restore-CapsulenvBitwardenDesktopSettings {
    [CmdletBinding()]
    param([switch]$NoStart)

    $backupPath = Get-CapsulenvBitwardenDesktopSettingsBackupPath
    $backup = Read-CapsulenvBitwardenDesktopSettingsBackup
    if ($null -eq $backup) {
        throw "No Bitwarden desktop-settings backup exists: $backupPath"
    }
    if ([int]$backup.SchemaVersion -ne 1) {
        throw "Unsupported Bitwarden desktop-settings backup schema: $($backup.SchemaVersion)"
    }

    Stop-CapsulenvBitwarden -Force
    try {
        $statePath = Get-CapsulenvBitwardenStatePath -AllowMissing
        $state = Read-CapsulenvUtf8TextFile -Path $statePath -AllowMissing
        Assert-CapsulenvJsonObjectText -Text $state.Text
        $json = [string]$state.Text

        foreach ($entry in @($backup.Entries)) {
            if ([bool]$entry.Exists) {
                $json = Set-CapsulenvJsonPropertyLiteral `
                    -JsonText $json `
                    -Name ([string]$entry.Name) `
                    -Literal ([string]$entry.Literal)
            } else {
                $json = Remove-CapsulenvJsonProperty -JsonText $json -Name ([string]$entry.Name)
            }
        }

        $restoredProperties = @(Get-CapsulenvJsonTopLevelProperties -JsonText $json)
        if (-not [bool]$backup.StateFileExisted -and $restoredProperties.Count -eq 0) {
            if (Test-Path -LiteralPath $statePath -PathType Leaf) {
                Remove-Item -LiteralPath $statePath -Force
            }
        } else {
            Write-CapsulenvBitwardenStateText -Path $statePath -Text $json -HasUtf8Bom ([bool]$state.HasUtf8Bom)
        }
        Remove-Item -LiteralPath $backupPath -Force
        Write-CapsulenvMessage -Level Success -Message 'Bitwarden SSH Agent desktop settings restored without replacing unrelated app or vault state.'
    } finally {
        if (-not $NoStart) {
            Start-CapsulenvBitwarden
        }
    }
}

function Test-CapsulenvAdministrator {
    [CmdletBinding()]
    param()

    if (-not (Test-CapsulenvWindows)) {
        return $false
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CapsulenvBitwardenSshAgentStatus {
    [CmdletBinding()]
    param()

    $statePath = Get-CapsulenvBitwardenStatePath -AllowMissing
    $state = Read-CapsulenvUtf8TextFile -Path $statePath -AllowMissing
    $enabled = Get-CapsulenvJsonPropertySnapshot `
        -JsonText $state.Text `
        -Name 'global_desktopSettings_sshAgentEnabled'

    $authorizationValues = New-Object System.Collections.Generic.List[string]
    foreach ($name in @(Get-CapsulenvBitwardenPromptPropertyNames -JsonText $state.Text)) {
        $snapshot = Get-CapsulenvJsonPropertySnapshot -JsonText $state.Text -Name $name
        if ($snapshot.Exists) {
            try {
                $authorizationValues.Add(([string]$snapshot.Literal | ConvertFrom-Json))
            } catch {
                $authorizationValues.Add([string]$snapshot.Literal)
            }
        }
    }

    $serviceDetail = 'Unavailable'
    if (Test-CapsulenvWindows) {
        $service = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
        if (-not $service) {
            $serviceDetail = 'Not installed'
        } else {
            $serviceInfo = Get-CimInstance Win32_Service -Filter "Name='ssh-agent'" -ErrorAction SilentlyContinue
            $startMode = if ($serviceInfo) { [string]$serviceInfo.StartMode } else { 'Unknown' }
            $serviceDetail = "Status=$($service.Status); StartMode=$startMode"
        }
    }

    $gitCore = $null
    $gitSigning = $null
    try {
        $git = Get-CapsulenvGitCommand
        $gitCore = (& $git config --get core.sshCommand 2>$null) -join [Environment]::NewLine
        $gitSigning = (& $git config --get gpg.ssh.program 2>$null) -join [Environment]::NewLine
    } catch {
        $gitCore = 'Git not found'
        $gitSigning = 'Git not found'
    }

    $enabledValue = $false
    if ($enabled.Exists) {
        $enabledValue = ([string]$enabled.Literal).ToLowerInvariant() -eq 'true'
    }
    $authorization = @($authorizationValues | Sort-Object -Unique)
    if ($authorization.Count -eq 0) {
        $authorization = @('always (Bitwarden default)')
    }

    $gitSessionIntent = Test-CapsulenvGitOpenSshSessionConfigured
    $gitSessionOverlayActive = -not [string]::IsNullOrWhiteSpace(
        [Environment]::GetEnvironmentVariable('CAPSULENV_GIT_CONFIG_BASE_COUNT', 'Process')
    )
    $gitGlobalManaged = Test-Path -LiteralPath (Get-CapsulenvGitConfigBackupPath) -PathType Leaf

    return [pscustomobject]@{
        DesktopSettingEnabled = $enabledValue
        Authorization = ($authorization -join ', ')
        StatePath = $statePath
        BitwardenRunning = (@(Get-CapsulenvBitwardenProcesses).Count -gt 0)
        SshAuthSock = [Environment]::GetEnvironmentVariable('SSH_AUTH_SOCK', 'Process')
        WindowsSshAgent = $serviceDetail
        GitSshCommand = $gitCore
        GitSigningProgram = $gitSigning
        GitSessionIntent = $gitSessionIntent
        GitSessionOverlayActive = $gitSessionOverlayActive
        GitGlobalManaged = $gitGlobalManaged
        GitConfigScope = $(if ($gitSessionOverlayActive -and $gitGlobalManaged) { 'SessionOverlay+UserGlobal' } elseif ($gitSessionOverlayActive) { 'SessionOverlay' } elseif ($gitGlobalManaged) { 'UserGlobal' } else { 'Inherited' })
        SettingsBackup = (Test-Path -LiteralPath (Get-CapsulenvBitwardenDesktopSettingsBackupPath) -PathType Leaf)
    }
}

function Invoke-CapsulenvBitwardenSshAgentSetup {
    [CmdletBinding()]
    param(
        [string]$Authorization,
        [switch]$SkipWindowsService,
        [switch]$SkipGit,
        [switch]$NoStart
    )

    if (-not (Test-CapsulenvWindows)) {
        throw 'Bitwarden SSH Agent setup currently targets Windows.'
    }

    $authorizationValue = Get-CapsulenvBitwardenAuthorizationValue -Value $Authorization
    Set-CapsulenvBitwardenDesktopSshAgent -Authorization $authorizationValue -NoStart

    try {
        [void](Set-CapsulenvSessionEnvironment)

        if (-not $SkipGit) {
            Set-CapsulenvGitOpenSsh -Force
        }

        if (-not $SkipWindowsService) {
            if ((Get-CapsulenvInstallMode) -eq 'ShellOnly') {
                Write-CapsulenvMessage -Level Detail -Message 'ShellOnly mode leaves the Windows ssh-agent service unchanged.'
            } elseif (Test-CapsulenvAdministrator) {
                Disable-CapsulenvWindowsSshAgent -Confirm:$false
            } else {
                Write-CapsulenvMessage -Level Warning -Message 'Windows ssh-agent was not disabled because this terminal is not elevated. Rerun `capsulenv.cmd bitwarden disable-windows-agent` as Administrator.'
            }
        }
    } finally {
        if (-not $NoStart) {
            Start-CapsulenvBitwarden
        }
    }

    return Get-CapsulenvBitwardenSshAgentStatus
}

function Restore-CapsulenvBitwardenSshAgentSetup {
    [CmdletBinding()]
    param([switch]$NoStart)

    $restoredAny = $false
    $errors = New-Object System.Collections.Generic.List[string]
    try {
        $desktopBackup = Get-CapsulenvBitwardenDesktopSettingsBackupPath
        if (Test-Path -LiteralPath $desktopBackup -PathType Leaf) {
            $restoredAny = $true
            try {
                Restore-CapsulenvBitwardenDesktopSettings -NoStart
            } catch {
                $errors.Add("Bitwarden desktop settings: $($_.Exception.Message)")
            }
        }

        $gitBackup = Get-CapsulenvGitConfigBackupPath
        if (Test-Path -LiteralPath $gitBackup -PathType Leaf) {
            $restoredAny = $true
            try {
                Restore-CapsulenvGitOpenSsh
            } catch {
                $errors.Add("Git SSH settings: $($_.Exception.Message)")
            }
        }

        $serviceBackup = Get-CapsulenvSshAgentServiceStatePath
        if (Test-Path -LiteralPath $serviceBackup -PathType Leaf) {
            $restoredAny = $true
            if (Test-CapsulenvAdministrator) {
                try {
                    Restore-CapsulenvWindowsSshAgent -Confirm:$false
                } catch {
                    $errors.Add("Windows ssh-agent service: $($_.Exception.Message)")
                }
            } else {
                Write-CapsulenvMessage -Level Warning -Message 'The saved Windows ssh-agent service state still requires an elevated restore. Run `capsulenv.cmd bitwarden restore-windows-agent` as Administrator.'
            }
        }
    } finally {
        if (-not $NoStart) {
            Start-CapsulenvBitwarden
        }
    }

    if (-not $restoredAny) {
        throw 'No capsulenv Bitwarden SSH Agent backup exists.'
    }
    if ($errors.Count -gt 0) {
        throw "Bitwarden SSH Agent restore was incomplete:`n$($errors -join [Environment]::NewLine)"
    }

    return Get-CapsulenvBitwardenSshAgentStatus
}

##MOD_EXEC## Export-ModuleMember -Function Set-CapsulenvBitwardenDesktopSshAgent, Restore-CapsulenvBitwardenDesktopSettings, Get-CapsulenvBitwardenSshAgentStatus, Invoke-CapsulenvBitwardenSshAgentSetup, Restore-CapsulenvBitwardenSshAgentSetup
