function Get-CapsulenvConfiguredDefaultBrowser {
    [CmdletBinding()]
    param()

    $configuration = Get-CapsulenvConfiguration
    if (
        -not $configuration.ContainsKey('UserIntegration') -or
        $configuration.UserIntegration -isnot [hashtable]
    ) {
        return $null
    }
    $browser = [string]$configuration.UserIntegration.DefaultBrowser
    if ([string]::IsNullOrWhiteSpace($browser)) {
        return $null
    }
    return $browser
}

function Get-CapsulenvDefaultBrowserStatePath {
    [CmdletBinding()]
    param()

    return Join-Path (Get-CapsulenvUserIntegrationStateRoot) 'default-browser-registration.json'
}

function Get-CapsulenvDefaultBrowserRegistration {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$App)

    $definition = Get-CapsulenvBrowserDefinition -App $App
    $displayName = Get-CapsulenvBrowserDisplayName -App $App -Definition $definition
    $identity = (Get-CapsulenvIdentity).Replace('-', '')
    $shortIdentity = $identity.Substring(0, 12)
    $appToken = ([regex]::Replace($App, '[^A-Za-z0-9._-]+', '.')).Trim('.')
    if ([string]::IsNullOrWhiteSpace($appToken)) {
        throw "Cannot derive a Windows registration token from Scoop app selector '$App'."
    }
    $token = 'Capsulenv.{0}.{1}' -f $shortIdentity, $appToken
    $registeredName = 'Capsulenv {0} ({1})' -f $displayName, $shortIdentity
    $clientPath = 'Software\Clients\StartMenuInternet\{0}' -f $token
    $capabilitiesPath = $clientPath + '\Capabilities'

    return [pscustomobject]@{
        App = $App
        Token = $token
        DisplayName = '{0} (Capsulenv)' -f $displayName
        RegisteredName = $registeredName
        ClientPath = $clientPath
        CapabilitiesPath = $capabilitiesPath
        UrlProgId = $token + '.URL'
        HtmlProgId = $token + '.HTML'
        UrlClassPath = 'Software\Classes\' + $token + '.URL'
        HtmlClassPath = 'Software\Classes\' + $token + '.HTML'
    }
}

function Get-CapsulenvDefaultBrowserStateApp {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State)

    $appProperty = $State.PSObject.Properties['App']
    if ($null -ne $appProperty -and -not [string]::IsNullOrWhiteSpace([string]$appProperty.Value)) {
        return [string]$appProperty.Value
    }
    $browserProperty = $State.PSObject.Properties['Browser']
    if ($null -eq $browserProperty) {
        return $null
    }
    switch ([string]$browserProperty.Value) {
        'Firefox' { return 'firefox' }
        'Zen' { return 'zen-browser' }
        'LibreWolf' { return 'librewolf' }
        default { return [string]$browserProperty.Value }
    }
}

function Get-CapsulenvDefaultBrowserRegistrationFromState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    return [pscustomobject]@{
        App = (Get-CapsulenvDefaultBrowserStateApp -State $State)
        DisplayName = '{0} (Capsulenv)' -f $DisplayName
        RegisteredName = [string]$State.RegisteredName
        ClientPath = [string]$State.ClientPath
        CapabilitiesPath = ([string]$State.ClientPath) + '\Capabilities'
        UrlProgId = [string]$State.UrlProgId
        HtmlProgId = [string]$State.HtmlProgId
        UrlClassPath = [string]$State.UrlClassPath
        HtmlClassPath = [string]$State.HtmlClassPath
    }
}

function Get-CapsulenvCurrentUserRegistryRawValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SubKey,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name
    )

    if (-not (Test-CapsulenvWindows)) {
        return [pscustomobject]@{ Exists = $false; Value = $null }
    }
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey, $false)
        if ($null -eq $key) {
            return [pscustomobject]@{ Exists = $false; Value = $null }
        }
        $names = @($key.GetValueNames())
        if ($names -notcontains $Name) {
            return [pscustomobject]@{ Exists = $false; Value = $null }
        }
        return [pscustomobject]@{
            Exists = $true
            Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
    } finally {
        if ($null -ne $key) { $key.Dispose() }
    }
}

function Test-CapsulenvCurrentUserRegistryKey {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SubKey)

    if (-not (Test-CapsulenvWindows)) {
        return $false
    }
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey, $false)
        return $null -ne $key
    } finally {
        if ($null -ne $key) { $key.Dispose() }
    }
}

function Set-CapsulenvCurrentUserRegistryStringValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SubKey,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    if (-not (Test-CapsulenvWindows)) {
        throw 'Current-user default-browser registration is supported only on Windows.'
    }
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($SubKey)
        if ($null -eq $key) {
            throw "Could not create HKCU registry key: $SubKey"
        }
        $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::String)
    } finally {
        if ($null -ne $key) { $key.Dispose() }
    }
}

function Remove-CapsulenvCurrentUserRegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SubKey,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name
    )

    if (-not (Test-CapsulenvWindows)) {
        return
    }
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey, $true)
        if ($null -ne $key) {
            $key.DeleteValue($Name, $false)
        }
    } finally {
        if ($null -ne $key) { $key.Dispose() }
    }
}

function Remove-CapsulenvCurrentUserRegistryTree {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SubKey)

    if (-not (Test-CapsulenvWindows)) {
        return
    }
    try {
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($SubKey, $false)
    } catch [System.ArgumentException] {
        # Already absent.
    }
}

function Send-CapsulenvAssociationChanged {
    [CmdletBinding()]
    param()

    if (-not (Test-CapsulenvWindows)) {
        return
    }
    $type = [System.Management.Automation.PSTypeName]::new('Capsulenv.ShellAssociationNotifier').Type
    if ($null -eq $type) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Capsulenv {
    public static class ShellAssociationNotifier {
        [DllImport("shell32.dll")]
        private static extern void SHChangeNotify(uint wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);
        public static void Notify() {
            SHChangeNotify(0x08000000, 0x0000, IntPtr.Zero, IntPtr.Zero);
        }
    }
}
'@
    }
    [Capsulenv.ShellAssociationNotifier]::Notify()
}

function ConvertTo-CapsulenvDefaultBrowserCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][string]$ProfileArgument,
        [Parameter(Mandatory = $true)][ValidateSet('Url', 'File')][string]$Kind
    )

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add((ConvertTo-CapsulenvProcessArgument -Argument $Executable))
    $parts.Add($ProfileArgument)
    $parts.Add((ConvertTo-CapsulenvProcessArgument -Argument $Profile))
    if ($Kind -eq 'Url') {
        $parts.Add('-osint')
        $parts.Add('-url')
    }
    $parts.Add('"%1"')
    return ($parts -join ' ')
}

function Write-CapsulenvDefaultBrowserState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State)

    $path = Get-CapsulenvDefaultBrowserStatePath
    $parent = Split-Path -Parent $path
    [void](New-Item -ItemType Directory -Path $parent -Force)
    $temporary = Join-Path $parent ('.default-browser-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                [System.IO.File]::Replace($temporary, $path, $null, $true)
            } catch {
                Remove-Item -LiteralPath $path -Force
                Move-Item -LiteralPath $temporary -Destination $path
            }
        } else {
            Move-Item -LiteralPath $temporary -Destination $path
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-CapsulenvDefaultBrowserState {
    [CmdletBinding()]
    param()

    $path = Get-CapsulenvDefaultBrowserStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $schema = [int]$state.SchemaVersion
        $stateApp = Get-CapsulenvDefaultBrowserStateApp -State $state
        if (
            $schema -notin @(1, 2) -or
            [string]::IsNullOrWhiteSpace([string]$state.CapsuleId) -or
            [string]::IsNullOrWhiteSpace([string]$state.HostIntegrationKey) -or
            [string]::IsNullOrWhiteSpace([string]$stateApp) -or
            [string]::IsNullOrWhiteSpace([string]$state.RegisteredName) -or
            [string]::IsNullOrWhiteSpace([string]$state.ClientPath) -or
            [string]::IsNullOrWhiteSpace([string]$state.UrlClassPath) -or
            [string]::IsNullOrWhiteSpace([string]$state.HtmlClassPath) -or
            [string]::IsNullOrWhiteSpace([string]$state.UrlProgId) -or
            [string]::IsNullOrWhiteSpace([string]$state.HtmlProgId)
        ) {
            throw 'invalid schema'
        }
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$state.CapsuleId, [string](Get-CapsulenvIdentity))) {
            throw 'state belongs to a different capsule'
        }
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$state.HostIntegrationKey, [string](Get-CapsulenvHostIntegrationKey))) {
            throw 'state belongs to a different machine/user integration'
        }
        return $state
    } catch {
        throw "Default-browser integration state is invalid: $path"
    }
}

function Install-CapsulenvDefaultBrowserRegistration {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$App)

    if (-not (Test-CapsulenvWindows)) {
        return $null
    }
    $definition = Get-CapsulenvBrowserDefinition -App $App
    $displayName = Get-CapsulenvBrowserDisplayName -App $App -Definition $definition
    $registration = Get-CapsulenvDefaultBrowserRegistration -App $App
    $executable = Get-CapsulenvBrowserExecutable -App $App
    if ([string]::IsNullOrWhiteSpace([string]$executable) -or -not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Cannot register $displayName as a User default-browser candidate because its capsule executable is missing."
    }
    $profile = Get-CapsulenvBrowserProfilePath -App $App
    if ([string]::IsNullOrWhiteSpace([string]$profile) -or -not (Test-Path -LiteralPath $profile -PathType Container)) {
        throw "Cannot register $displayName as a User default-browser candidate because its Scoop-persisted profile is missing."
    }
    $profileArgument = [string]$definition.ProfileArgument
    if ([string]::IsNullOrWhiteSpace($profileArgument)) {
        throw "Cannot register $displayName as a User default-browser candidate because its profile argument is not configured."
    }

    $state = Get-CapsulenvDefaultBrowserState
    if ($null -eq $state) {
        foreach ($path in @($registration.ClientPath, $registration.UrlClassPath, $registration.HtmlClassPath)) {
            if (Test-CapsulenvCurrentUserRegistryKey -SubKey $path) {
                throw "Refusing to overwrite an untracked default-browser registration key: HKCU\$path"
            }
        }
        $previousRegistered = Get-CapsulenvCurrentUserRegistryRawValue `
            -SubKey 'Software\RegisteredApplications' `
            -Name $registration.RegisteredName
        $state = [ordered]@{
            SchemaVersion = 2
            CapsuleId = (Get-CapsulenvIdentity)
            HostIntegrationKey = (Get-CapsulenvHostIntegrationKey)
            App = $App
            RegisteredName = $registration.RegisteredName
            ClientPath = $registration.ClientPath
            UrlClassPath = $registration.UrlClassPath
            HtmlClassPath = $registration.HtmlClassPath
            UrlProgId = $registration.UrlProgId
            HtmlProgId = $registration.HtmlProgId
            PreviousRegisteredApplication = [ordered]@{
                Exists = [bool]$previousRegistered.Exists
                Value = $previousRegistered.Value
            }
            CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        Write-CapsulenvDefaultBrowserState -State $state
    } elseif (-not [System.StringComparer]::OrdinalIgnoreCase.Equals((Get-CapsulenvDefaultBrowserStateApp -State $state), $App)) {
        throw "This host/user already has a Capsulenv default-browser registration for $(Get-CapsulenvDefaultBrowserStateApp -State $state). Run restore-user before switching it to $App."
    } else {
        # Preserve the exact ProgIDs and registry paths already tracked by the
        # reversible state. This keeps schema-1 preset registrations restorable
        # while new configuration addresses the browser by Scoop app selector.
        $registration = Get-CapsulenvDefaultBrowserRegistrationFromState -State $state -DisplayName $displayName
    }

    $urlCommand = ConvertTo-CapsulenvDefaultBrowserCommand -Executable $executable -Profile $profile -ProfileArgument $profileArgument -Kind Url
    $fileCommand = ConvertTo-CapsulenvDefaultBrowserCommand -Executable $executable -Profile $profile -ProfileArgument $profileArgument -Kind File
    $icon = '{0},0' -f $executable

    Set-CapsulenvCurrentUserRegistryStringValue -SubKey 'Software\RegisteredApplications' -Name $registration.RegisteredName -Value $registration.CapabilitiesPath
    Set-CapsulenvCurrentUserRegistryStringValue -SubKey $registration.ClientPath -Name '' -Value $registration.DisplayName
    Set-CapsulenvCurrentUserRegistryStringValue -SubKey ($registration.ClientPath + '\DefaultIcon') -Name '' -Value $icon
    Set-CapsulenvCurrentUserRegistryStringValue -SubKey ($registration.ClientPath + '\shell\open\command') -Name '' -Value $urlCommand
    Set-CapsulenvCurrentUserRegistryStringValue -SubKey $registration.CapabilitiesPath -Name 'ApplicationName' -Value $registration.DisplayName
    Set-CapsulenvCurrentUserRegistryStringValue -SubKey $registration.CapabilitiesPath -Name 'ApplicationDescription' -Value ("Portable $displayName managed by Capsulenv User integration.")
    Set-CapsulenvCurrentUserRegistryStringValue -SubKey $registration.CapabilitiesPath -Name 'ApplicationIcon' -Value $icon
    foreach ($protocol in @('http', 'https')) {
        Set-CapsulenvCurrentUserRegistryStringValue -SubKey ($registration.CapabilitiesPath + '\URLAssociations') -Name $protocol -Value $registration.UrlProgId
    }
    foreach ($extension in @('.htm', '.html')) {
        Set-CapsulenvCurrentUserRegistryStringValue -SubKey ($registration.CapabilitiesPath + '\FileAssociations') -Name $extension -Value $registration.HtmlProgId
    }

    Set-CapsulenvCurrentUserRegistryStringValue -SubKey $registration.UrlClassPath -Name '' -Value ($registration.DisplayName + ' URL')
    Set-CapsulenvCurrentUserRegistryStringValue -SubKey $registration.UrlClassPath -Name 'URL Protocol' -Value ''
    Set-CapsulenvCurrentUserRegistryStringValue -SubKey ($registration.UrlClassPath + '\DefaultIcon') -Name '' -Value $icon
    Set-CapsulenvCurrentUserRegistryStringValue -SubKey ($registration.UrlClassPath + '\shell\open\command') -Name '' -Value $urlCommand

    Set-CapsulenvCurrentUserRegistryStringValue -SubKey $registration.HtmlClassPath -Name '' -Value ($registration.DisplayName + ' HTML')
    Set-CapsulenvCurrentUserRegistryStringValue -SubKey ($registration.HtmlClassPath + '\DefaultIcon') -Name '' -Value $icon
    Set-CapsulenvCurrentUserRegistryStringValue -SubKey ($registration.HtmlClassPath + '\shell\open\command') -Name '' -Value $fileCommand

    Send-CapsulenvAssociationChanged
    return $registration
}

function Test-CapsulenvDefaultBrowserProgIdsSelected {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$UrlProgId,
        [Parameter(Mandatory = $true)][string]$HtmlProgId
    )

    if (-not (Test-CapsulenvWindows)) {
        return $false
    }
    $expected = [ordered]@{
        'Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice' = $UrlProgId
        'Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' = $UrlProgId
        'Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.htm\UserChoice' = $HtmlProgId
        'Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.html\UserChoice' = $HtmlProgId
    }
    foreach ($subKey in $expected.Keys) {
        $progId = Get-CapsulenvRegistryStringValue -Hive CurrentUser -SubKey $subKey -Name 'ProgId'
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$progId, [string]$expected[$subKey])) {
            return $false
        }
    }
    return $true
}

function Test-CapsulenvDefaultBrowserSelected {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$App)

    $registration = Get-CapsulenvDefaultBrowserRegistration -App $App
    return Test-CapsulenvDefaultBrowserProgIdsSelected `
        -UrlProgId $registration.UrlProgId `
        -HtmlProgId $registration.HtmlProgId
}

function Open-CapsulenvDefaultAppsSettings {
    [CmdletBinding()]
    param([AllowNull()][string]$RegisteredName)

    if (-not (Test-CapsulenvWindows)) {
        return
    }
    $uri = 'ms-settings:defaultapps'
    if (-not [string]::IsNullOrWhiteSpace($RegisteredName)) {
        $uri += '?registeredAppUser=' + [Uri]::EscapeDataString($RegisteredName)
    }
    [void](Start-Process -FilePath $uri)
}

function Sync-CapsulenvConfiguredDefaultBrowser {
    [CmdletBinding()]
    param()

    $app = Get-CapsulenvConfiguredDefaultBrowser
    if ([string]::IsNullOrWhiteSpace([string]$app)) {
        return
    }
    if ((Get-CapsulenvInstallMode) -ne 'User') {
        throw 'Default-browser integration is persistent and may only be synchronized in User mode.'
    }

    $registration = Install-CapsulenvDefaultBrowserRegistration -App $app
    if (Test-CapsulenvDefaultBrowserProgIdsSelected -UrlProgId $registration.UrlProgId -HtmlProgId $registration.HtmlProgId) {
        Write-CapsulenvMessage -Level Detail -Message "$(Get-CapsulenvBrowserDisplayName -App $app) is already the Windows default browser for this User integration."
        return
    }

    Open-CapsulenvDefaultAppsSettings -RegisteredName $registration.RegisteredName
    Write-CapsulenvMessage -Level Warning -Message "Windows requires user confirmation before changing http/https default handlers. Default Apps was opened directly on '$($registration.DisplayName)'; choose Set default, then return to Capsulenv."
}

function Assert-CapsulenvDefaultBrowserRestorable {
    [CmdletBinding()]
    param()

    $state = Get-CapsulenvDefaultBrowserState
    if ($null -eq $state -or -not (Test-CapsulenvWindows)) {
        return
    }
    $app = Get-CapsulenvDefaultBrowserStateApp -State $state
    if (Test-CapsulenvDefaultBrowserProgIdsSelected -UrlProgId ([string]$state.UrlProgId) -HtmlProgId ([string]$state.HtmlProgId)) {
        Open-CapsulenvDefaultAppsSettings -RegisteredName $null
        throw "Capsulenv's portable $app is still the Windows default browser. Choose another default browser in Windows Settings, then run restore-user again; Capsulenv will not forge or replay UserChoice hashes."
    }
}

function Restore-CapsulenvDefaultBrowserRegistration {
    [CmdletBinding()]
    param()

    $state = Get-CapsulenvDefaultBrowserState
    if ($null -eq $state) {
        return
    }
    if (-not (Test-CapsulenvWindows)) {
        Remove-Item -LiteralPath (Get-CapsulenvDefaultBrowserStatePath) -Force
        return
    }

    Assert-CapsulenvDefaultBrowserRestorable
    Remove-CapsulenvCurrentUserRegistryTree -SubKey ([string]$state.ClientPath)
    Remove-CapsulenvCurrentUserRegistryTree -SubKey ([string]$state.UrlClassPath)
    Remove-CapsulenvCurrentUserRegistryTree -SubKey ([string]$state.HtmlClassPath)

    $previous = $state.PreviousRegisteredApplication
    if ($null -ne $previous -and [bool]$previous.Exists) {
        Set-CapsulenvCurrentUserRegistryStringValue `
            -SubKey 'Software\RegisteredApplications' `
            -Name ([string]$state.RegisteredName) `
            -Value ([string]$previous.Value)
    } else {
        Remove-CapsulenvCurrentUserRegistryValue `
            -SubKey 'Software\RegisteredApplications' `
            -Name ([string]$state.RegisteredName)
    }
    Send-CapsulenvAssociationChanged
    Remove-Item -LiteralPath (Get-CapsulenvDefaultBrowserStatePath) -Force
}
