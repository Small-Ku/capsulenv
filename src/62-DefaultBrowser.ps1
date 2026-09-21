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
        # Gecko's -osint safety gate accepts only the exact four-argument
        # shape `app -osint -url URL`. A profile-specific portable handler
        # necessarily adds `-profile <path>`, so combining the two makes Gecko
        # exit 127 before opening the URL. The association is already scoped to
        # http/https and `%1` is kept as one quoted argument; use Gecko's normal
        # delegated-URL form while preserving the explicit portable profile.
        $parts.Add('-url')
    }
    $parts.Add('"%1"')
    return ($parts -join ' ')
}

function Write-CapsulenvDefaultBrowserState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State)

    $path = Get-CapsulenvDefaultBrowserStatePath
    Publish-CapsulenvFileAuthorityAtomically -Path $path -Value $State
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

function Resolve-CapsulenvRequiredDefaultBrowserBridge {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$App)

    try {
        $bridge = Get-CapsulenvUserIntegrationBridge -CapsuleId (Get-CapsulenvIdentity)
        if ($null -eq $bridge -or [bool]$bridge.Persistent -ne $true) {
            throw 'the host-local bridge is missing or not persistent'
        }
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$bridge.CapsuleId, [string](Get-CapsulenvIdentity))) {
            throw 'the bridge belongs to a different capsule'
        }
        $expectedIdentity = Get-CapsulenvBrowserStateIdentity -App $App
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$bridge.BrowserStateIdentity, $expectedIdentity)) {
            throw 'the bridge is bound to a different browser'
        }
        if ([string]::IsNullOrWhiteSpace([string]$bridge.BridgePath) -or -not (Test-Path -LiteralPath ([string]$bridge.BridgePath) -PathType Leaf)) {
            throw 'the bridge script is missing'
        }
        [void](Resolve-CapsulenvUserIntegrationCapsuleRoot -CapsuleId (Get-CapsulenvIdentity))
        $handler = Get-CapsulenvUserIntegrationBridgeCommand -Bridge $bridge
        return [pscustomobject][ordered]@{ Bridge = $bridge; Handler = $handler }
    } catch {
        throw "Persistent default-browser registration requires a valid host-local UserIntegration bridge: $($_.Exception.Message)"
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
    $bridgeBinding = Resolve-CapsulenvRequiredDefaultBrowserBridge -App $App
    $bridge = $bridgeBinding.Bridge
    $handler = $bridgeBinding.Handler
    $executable = [string]$handler.Executable
    $profile = ''
    $profileArgument = ''
    $urlCommand = [string]$handler.Command
    $fileCommand = [string]$handler.Command
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

    $icon = '{0},0' -f $executable

    Set-CapsulenvCurrentUserRegistryStringValue -SubKey 'Software\RegisteredApplications' -Name $registration.RegisteredName -Value $registration.CapabilitiesPath
    Set-CapsulenvCurrentUserRegistryStringValue -SubKey $registration.ClientPath -Name '' -Value $registration.DisplayName
    Set-CapsulenvCurrentUserRegistryStringValue -SubKey ($registration.ClientPath + '\DefaultIcon') -Name '' -Value $icon
    Set-CapsulenvCurrentUserRegistryStringValue -SubKey ($registration.ClientPath + '\shell\open\command') -Name '' -Value $urlCommand
    # Windows uses the named value under RegisteredApplications as the
    # application identity for Default Apps deep links. Keep ApplicationName
    # byte-for-byte aligned with that registered name; using a prettier display
    # label here can leave the application registered but make
    # `registeredAppUser=` fail to resolve it in Settings.
    Set-CapsulenvCurrentUserRegistryStringValue -SubKey $registration.CapabilitiesPath -Name 'ApplicationName' -Value $registration.RegisteredName
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

function Get-CapsulenvEffectiveAssociationProgId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Association,
        [Parameter(Mandatory = $true)][ValidateSet('Protocol', 'FileExtension')][string]$Type
    )

    if (-not (Test-CapsulenvWindows)) {
        return $null
    }

    if ($null -eq ('Capsulenv.WindowsAssociationQuery' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Capsulenv
{
    internal enum AssociationLevel
    {
        Machine = 0,
        Effective = 1,
        User = 2
    }

    internal enum AssociationType
    {
        FileExtension = 0,
        UrlProtocol = 1,
        StartMenuClient = 2,
        MimeType = 3
    }

    [ComImport]
    [Guid("4e530b0a-e611-4c77-a3ac-9031d022281b")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IApplicationAssociationRegistration
    {
        [return: MarshalAs(UnmanagedType.LPWStr)]
        string QueryCurrentDefault(
            [MarshalAs(UnmanagedType.LPWStr)] string query,
            AssociationType queryType,
            AssociationLevel queryLevel);

        [return: MarshalAs(UnmanagedType.Bool)]
        bool QueryAppIsDefault(
            [MarshalAs(UnmanagedType.LPWStr)] string query,
            AssociationType queryType,
            AssociationLevel queryLevel,
            [MarshalAs(UnmanagedType.LPWStr)] string appRegistryName);

        [return: MarshalAs(UnmanagedType.Bool)]
        bool QueryAppIsDefaultAll(
            AssociationLevel queryLevel,
            [MarshalAs(UnmanagedType.LPWStr)] string appRegistryName);

        void SetAppAsDefault(
            [MarshalAs(UnmanagedType.LPWStr)] string appRegistryName,
            [MarshalAs(UnmanagedType.LPWStr)] string set,
            AssociationType setType);

        void SetAppAsDefaultAll([MarshalAs(UnmanagedType.LPWStr)] string appRegistryName);
        void ClearUserAssociations();
    }

    [ComImport]
    [Guid("591209c7-767b-42b2-9fba-44ee4615f2c7")]
    internal class ApplicationAssociationRegistration
    {
    }

    public static class WindowsAssociationQuery
    {
        public static string QueryCurrentDefault(string association, bool protocol)
        {
            object instance = null;
            try
            {
                instance = new ApplicationAssociationRegistration();
                IApplicationAssociationRegistration registration =
                    (IApplicationAssociationRegistration)instance;
                return registration.QueryCurrentDefault(
                    association,
                    protocol ? AssociationType.UrlProtocol : AssociationType.FileExtension,
                    AssociationLevel.Effective);
            }
            finally
            {
                if (instance != null && Marshal.IsComObject(instance))
                {
                    Marshal.FinalReleaseComObject(instance);
                }
            }
        }
    }
}
'@
    }

    try {
        return Invoke-CapsulenvEffectiveAssociationComQuery -Association $Association -Type $Type
    } catch {
        # QueryCurrentDefault is the supported Windows 8+ read path, but keep a
        # bounded registry fallback for damaged/older hosts where COM lookup is
        # unavailable. Prefer UserChoiceLatest when present because some Windows
        # 11 hosts retain a stale UserChoice while ShellExecute uses the rotated
        # association.
        $base = if ($Type -eq 'Protocol') {
            "Software\Microsoft\Windows\Shell\Associations\UrlAssociations\$Association"
        } else {
            "Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$Association"
        }
        $latest = Get-CapsulenvRegistryStringValue `
            -Hive CurrentUser `
            -SubKey ($base + '\UserChoiceLatest\ProgId') `
            -Name 'ProgId'
        if (-not [string]::IsNullOrWhiteSpace([string]$latest)) {
            return [string]$latest
        }
        return Get-CapsulenvRegistryStringValue `
            -Hive CurrentUser `
            -SubKey ($base + '\UserChoice') `
            -Name 'ProgId'
    }
}

function Invoke-CapsulenvEffectiveAssociationComQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Association,
        [Parameter(Mandatory = $true)][ValidateSet('Protocol', 'FileExtension')][string]$Type
    )

    return [Capsulenv.WindowsAssociationQuery]::QueryCurrentDefault(
        $Association,
        $Type -eq 'Protocol'
    )
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
    $expected = @(
        [pscustomobject]@{ Association = 'http'; Type = 'Protocol'; ProgId = $UrlProgId }
        [pscustomobject]@{ Association = 'https'; Type = 'Protocol'; ProgId = $UrlProgId }
        [pscustomobject]@{ Association = '.htm'; Type = 'FileExtension'; ProgId = $HtmlProgId }
        [pscustomobject]@{ Association = '.html'; Type = 'FileExtension'; ProgId = $HtmlProgId }
    )
    foreach ($entry in $expected) {
        $progId = Get-CapsulenvEffectiveAssociationProgId `
            -Association $entry.Association `
            -Type $entry.Type
        if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$progId, [string]$entry.ProgId)) {
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
    if ((Get-CapsulenvInstallMode) -ne 'User') {
        if ([string]::IsNullOrWhiteSpace([string]$app)) {
            return
        }
        throw 'Default-browser integration is persistent and may only be synchronized in User mode.'
    }

    if ([string]::IsNullOrWhiteSpace([string]$app)) {
        # A tracked registration is Capsulenv-owned persistent state even when
        # the current config no longer asks Windows to select it as the default.
        # Runtime upgrades must still refresh that owned ProgID in place: older
        # handlers may contain obsolete executable/profile arguments and Windows
        # can continue using the tracked ProgID through UserChoiceLatest. Do not
        # reopen Default Apps when the preference is blank; only repair what we
        # already own.
        $state = Get-CapsulenvDefaultBrowserState
        if ($null -eq $state) {
            return
        }
        $trackedApp = Get-CapsulenvDefaultBrowserStateApp -State $state
        if ([string]::IsNullOrWhiteSpace([string]$trackedApp)) {
            return
        }
        [void](Install-CapsulenvDefaultBrowserRegistration -App $trackedApp)
        Write-CapsulenvMessage -Level Detail -Message "Refreshed tracked default-browser registration for $trackedApp; no browser is currently configured for Default Apps prompting."
        return
    }

    $registration = Install-CapsulenvDefaultBrowserRegistration -App $app
    if (Test-CapsulenvDefaultBrowserProgIdsSelected -UrlProgId $registration.UrlProgId -HtmlProgId $registration.HtmlProgId) {
        Write-CapsulenvMessage -Level Detail -Message "$(Get-CapsulenvBrowserDisplayName -App $app) is already the Windows default browser for this User integration."
        return
    }

    Open-CapsulenvDefaultAppsSettings -RegisteredName $registration.RegisteredName
    Write-CapsulenvMessage -Level Warning -Message "Windows requires user confirmation before changing http/https default handlers. Default Apps was opened directly on '$($registration.DisplayName)'; choose Set default, then return to Capsulenv."
}

function Get-CapsulenvTrackedDefaultBrowserCommandStatus {
    [CmdletBinding()]
    param()

    if (-not (Test-CapsulenvWindows)) {
        return $null
    }
    $state = Get-CapsulenvDefaultBrowserState
    if ($null -eq $state) {
        return $null
    }

    $app = Get-CapsulenvDefaultBrowserStateApp -State $state
    if ([string]::IsNullOrWhiteSpace([string]$app)) {
        return $null
    }
    $actual = Get-CapsulenvRegistryStringValue `
        -Hive CurrentUser `
        -SubKey (([string]$state.UrlClassPath) + '\shell\open\command') `
        -Name ''
    $expected = $null
    $diagnostic = $null
    try {
        $bridgeBinding = Resolve-CapsulenvRequiredDefaultBrowserBridge -App $app
        $expected = [string]$bridgeBinding.Handler.Command
        $diagnostic = 'valid host-local UserIntegration bridge command'
    } catch {
        $diagnostic = $_.Exception.Message
    }

    [pscustomobject]@{
        App = $app
        ProgId = [string]$state.UrlProgId
        RegistryPath = 'HKCU\' + ([string]$state.UrlClassPath) + '\shell\open\command'
        ExpectedCommand = $expected
        ActualCommand = $actual
        Matches = ($null -ne $expected -and [System.StringComparer]::Ordinal.Equals([string]$expected, [string]$actual))
        Diagnostic = $diagnostic
    }
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
