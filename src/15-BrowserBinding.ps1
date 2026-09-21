if (-not (Get-Variable -Name CapsulenvBrowserLeaseWatchers -Scope Script -ErrorAction SilentlyContinue)) {
    $script:CapsulenvBrowserLeaseWatchers = @{}
}

function Get-CapsulenvBrowserStateIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$App)

    $parsed = Split-CapsulenvInstalledAppSelector -Selector $App
    return ([string]$parsed.Name).Trim().ToLowerInvariant()
}

function Get-CapsulenvPortableBrowserProfilePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [switch]$Create
    )

    $context = Get-CapsulenvContext
    $stateIdentity = Get-CapsulenvBrowserStateIdentity -App $App
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $key = (($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($stateIdentity)) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 24)
    } finally {
        $sha256.Dispose()
    }
    $profile = Join-Path (Join-Path (Join-Path $context.Root 'state/portable/browser') $key) 'profile'
    if ($Create) {
        [void](New-Item -ItemType Directory -Path $profile -Force)
    }
    return [System.IO.Path]::GetFullPath($profile)
}

function Get-CapsulenvBrowserCompatibilityPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProfilePath)

    return Join-Path $ProfilePath '.capsulenv-gecko-compatibility.json'
}

function Get-CapsulenvBrowserCompatibilityEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [Parameter(Mandatory = $true)]$Program
    )

    $versionText = [string]$Program.Version
    if ([string]::IsNullOrWhiteSpace($versionText)) {
        throw "Browser program '$App' does not provide Gecko compatibility version evidence."
    }
    $version = ConvertTo-CapsulenvProgramVersion -Version $versionText
    if ($version.Major -le 0) {
        throw "Browser program '$App' has invalid Gecko compatibility version evidence: $versionText"
    }
    return [pscustomobject][ordered]@{
        ProductId = Get-CapsulenvBrowserStateIdentity -App $App
        GeckoMajor = [int]$version.Major
        ProgramVersion = $versionText
    }
}

function Test-CapsulenvBrowserProfileCompatibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [Parameter(Mandatory = $true)]$Program,
        [switch]$ProfileWasCreated
    )

    $expected = Get-CapsulenvBrowserCompatibilityEvidence -App $App -Program $Program
    $path = Get-CapsulenvBrowserCompatibilityPath -ProfilePath $ProfilePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        if (-not $ProfileWasCreated) {
            return [pscustomobject][ordered]@{
                Compatible = $false
                Established = $false
                Evidence = $expected
                Path = $path
                Diagnostic = 'portable profile has no compatibility provenance; refusing to auto-bless an existing profile'
            }
        }
        return [pscustomobject][ordered]@{
            Compatible = $true
            Established = $false
            Evidence = $expected
            Path = $path
            Diagnostic = 'new portable profile has no Gecko compatibility evidence; establish it before launch'
        }
    }
    try {
        $actual = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $sameProduct = [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$actual.ProductId, [string]$expected.ProductId)
        $sameMajor = [int]$actual.GeckoMajor -eq [int]$expected.GeckoMajor
        return [pscustomobject][ordered]@{
            Compatible = ($sameProduct -and $sameMajor)
            Established = $true
            Evidence = $actual
            Path = $path
            Diagnostic = if ($sameProduct -and $sameMajor) { 'Gecko profile compatibility evidence matches' } else { 'Gecko profile compatibility evidence does not match the selected browser' }
        }
    } catch {
        return [pscustomobject][ordered]@{
            Compatible = $false
            Established = $true
            Evidence = $null
            Path = $path
            Diagnostic = "Gecko profile compatibility evidence is unreadable: $($_.Exception.Message)"
        }
    }
}

function Set-CapsulenvBrowserProfileCompatibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [Parameter(Mandatory = $true)]$Evidence
    )

    $path = Get-CapsulenvBrowserCompatibilityPath -ProfilePath $ProfilePath
    $temporary = Join-Path $ProfilePath ('.gecko-compatibility.{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        $encoding = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText(
            $temporary,
            ([pscustomobject][ordered]@{
                SchemaVersion = 1
                ProductId = [string]$Evidence.ProductId
                GeckoMajor = [int]$Evidence.GeckoMajor
                ProgramVersion = [string]$Evidence.ProgramVersion
                UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
            } | ConvertTo-Json -Depth 4),
            $encoding
        )
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            [System.IO.File]::Replace($temporary, $path, $null, $true)
        } else {
            Move-Item -LiteralPath $temporary -Destination $path
        }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Register-CapsulenvBrowserLeaseWatcher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Process,
        [Parameter(Mandatory = $true)]$Lease,
        [Parameter(Mandatory = $true)][string]$SessionId
    )

    $Process.EnableRaisingEvents = $true
    $key = '{0}:{1}' -f $SessionId, $Process.Id
    $subscription = Register-ObjectEvent -InputObject $Process -EventName Exited -MessageData ([pscustomobject]@{
        Key = $key
        Lease = $Lease
    }) -Action {
        $payload = $event.MessageData
        try {
            [void](Release-CapsulenvStateLease -Lease $payload.Lease)
        } finally {
            $script:CapsulenvBrowserLeaseWatchers.Remove([string]$payload.Key)
            Unregister-Event -SubscriptionId $event.SubscriptionId -ErrorAction SilentlyContinue
            Remove-Job -Id $event.EventIdentifier -Force -ErrorAction SilentlyContinue
        }
    }
    $script:CapsulenvBrowserLeaseWatchers[$key] = [pscustomobject][ordered]@{
        Key = $key
        Process = $Process
        Lease = $Lease
        SubscriptionId = $subscription.Id
    }
    return $script:CapsulenvBrowserLeaseWatchers[$key]
}

function Complete-CapsulenvPortableBrowserBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Binding,
        [switch]$WaitForExit
    )

    $hasProcess = $null -ne $Binding.PSObject.Properties['Process'] -and $null -ne $Binding.Process
    $hasLease = $null -ne $Binding.PSObject.Properties['Lease'] -and $null -ne $Binding.Lease
    if ($WaitForExit -and $hasProcess) {
        Wait-Process -Id ([int]$Binding.Process.Id) -ErrorAction SilentlyContinue
    }
    if ($hasLease) {
        [void](Release-CapsulenvStateLease -Lease $Binding.Lease)
    }
    return $Binding
}

function Stop-CapsulenvPortableBrowser {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Browser)

    if ($null -eq $Browser.ProcessRecord -or
        -not (Test-CapsulenvProcessRecordLive -ProcessRecord $Browser.ProcessRecord)) {
        return [pscustomobject][ordered]@{ Stopped = $false; Reason = 'process is not an exact live owned browser record' }
    }
    $stop = Stop-CapsulenvOwnedProcessRecord -ProcessRecord $Browser.ProcessRecord
    if (-not $stop.Stopped) {
        return $stop
    }
    [void](Complete-CapsulenvPortableBrowserBinding -Binding $Browser.Binding)
    return [pscustomobject][ordered]@{ Stopped = $true; PID = $Browser.ProcessRecord.PID; Reason = 'exact owned browser stopped and profile lease released' }
}

function Close-CapsulenvPortableBrowser {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Browser)

    $stopped = $true
    if ($null -ne $Browser.ProcessRecord -and (Test-CapsulenvProcessRecordLive -ProcessRecord $Browser.ProcessRecord)) {
        $stopped = [bool](Stop-CapsulenvOwnedProcessRecord -ProcessRecord $Browser.ProcessRecord).Stopped
    }
    if (-not $stopped) {
        return $Browser
    }
    [void](Complete-CapsulenvPortableBrowserBinding -Binding $Browser.Binding)
    return $Browser
}

function Get-CapsulenvBrowserProgramRequirement {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$App)

    $definition = Get-CapsulenvBrowserDefinition -App $App
    $parsed = Split-CapsulenvInstalledAppSelector -Selector $App
    $parameters = @{}
    if ($definition.ContainsKey('ExecutablePath')) { $parameters['RelativePath'] = [string]$definition.ExecutablePath }
    if ($definition.ContainsKey('BinName')) { $parameters['BinName'] = [string]$definition.BinName }
    if ($definition.ContainsKey('ShortcutName')) { $parameters['ShortcutName'] = [string]$definition.ShortcutName }
    return New-CapsulenvProgramRequirement -Name ([string]$parsed.Name) @parameters
}

function Resolve-CapsulenvBrowserBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$App,
        $Requirement,
        [object[]]$Candidates,
        $Program,
        $ActivationSnapshot,
        [ValidateSet('required', 'optional')]
        [string]$Criticality = 'required',
        [string]$SessionId
    )

    if ($null -eq $Requirement) {
        $Requirement = Get-CapsulenvBrowserProgramRequirement -App $App
    }
    $resolution = if ($PSBoundParameters.ContainsKey('Program')) {
        Get-CapsulenvProgramResolution -Requirement $Requirement -Candidates @($Program)
    } elseif ($PSBoundParameters.ContainsKey('Candidates')) {
        Get-CapsulenvProgramResolution -Requirement $Requirement -Candidates $Candidates
    } elseif ($PSBoundParameters.ContainsKey('ActivationSnapshot')) {
        Get-CapsulenvProgramResolution -Requirement $Requirement -Candidates @(
            Get-CapsulenvActiveGenerationProgram -Requirement $Requirement -ActivationSnapshot $ActivationSnapshot
        )
    } else {
        Get-CapsulenvProgramResolution -Requirement $Requirement -Candidates @(Get-CapsulenvActiveGenerationProgram -Requirement $Requirement)
    }
    if (-not $resolution.Succeeded) {
        $message = "Browser program '$App' has no compatible trusted realization."
        if ($Criticality -eq 'required') {
            throw $message
        }
        return [pscustomobject][ordered]@{
            Succeeded = $false
            Diagnostics = @($message + ' Optional browser skipped.')
            Program = $null
            ProfilePath = $null
            Lease = $null
        }
    }
    $profile = Get-CapsulenvPortableBrowserProfilePath -App $App
    $profileWasCreated = -not (Test-Path -LiteralPath $profile -PathType Container)
    if ($profileWasCreated) {
        [void](New-Item -ItemType Directory -Path $profile -Force)
    }
    $lease = Acquire-CapsulenvStateLease -StatePath $profile -Policy exclusive -SessionId $SessionId
    try {
        $compatibility = Test-CapsulenvBrowserProfileCompatibility -App $App -ProfilePath $profile -Program $resolution.Selected -ProfileWasCreated:$profileWasCreated
        if (-not $compatibility.Compatible) {
            throw "Browser '$App' cannot use the portable profile: $($compatibility.Diagnostic)"
        }
        if (-not $compatibility.Established) {
            Set-CapsulenvBrowserProfileCompatibility -ProfilePath $profile -Evidence $compatibility.Evidence
        }
        return [pscustomobject][ordered]@{
            Succeeded = $true
            Diagnostics = @('browser uses an explicit portable profile and exclusive state lease')
            Program = $resolution.Selected
            ProfilePath = $profile
            Lease = $lease
        }
    } catch {
        [void](Release-CapsulenvStateLease -Lease $lease)
        throw
    }
}

function Start-CapsulenvPortableBrowser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [string[]]$Arguments = @(),
        $Requirement,
        [object[]]$Candidates,
        $Program,
        $ActivationSnapshot,
        [ValidateSet('required', 'optional')]
        [string]$Criticality = 'required',
        [string]$SessionId
    )

    if (Test-CapsulenvBrowserProfileArgument -Arguments $Arguments) {
        throw 'Portable browser launch owns the profile argument; do not supply an unrelated profile path.'
    }
    if ($null -eq $Requirement) {
        $Requirement = Get-CapsulenvBrowserProgramRequirement -App $App
    }
    if (-not $PSBoundParameters.ContainsKey('Program') -and -not $PSBoundParameters.ContainsKey('Candidates') -and -not $PSBoundParameters.ContainsKey('ActivationSnapshot')) {
        $ensure = Ensure-CapsulenvProgramGeneration -Requirement $Requirement
        if (-not $ensure.Succeeded -or $null -eq $ensure.Selected) {
            throw "Browser program '$App' could not be acquired for activation."
        }
        $ActivationSnapshot = $ensure.ActivationSnapshot
    }
    $effectiveSessionId = $SessionId
    if ([string]::IsNullOrWhiteSpace($effectiveSessionId)) {
        $effectiveSessionId = (Initialize-CapsulenvSession -Role browser -Provenance $App).SessionId
    }
    $parameters = @{
        App = $App
        Criticality = $Criticality
        SessionId = $effectiveSessionId
    }
    if ($null -ne $Requirement) { $parameters['Requirement'] = $Requirement }
    if ($PSBoundParameters.ContainsKey('Candidates')) { $parameters['Candidates'] = $Candidates }
    if ($PSBoundParameters.ContainsKey('Program')) { $parameters['Program'] = $Program }
    if ($null -ne $ActivationSnapshot) { $parameters['ActivationSnapshot'] = $ActivationSnapshot }
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) { $parameters['SessionId'] = $SessionId }
    $binding = Resolve-CapsulenvBrowserBinding @parameters
    if (-not $binding.Succeeded) {
        return $binding
    }
    $launchArguments = @('-profile', (ConvertTo-CapsulenvProcessArgument -Argument $binding.ProfilePath)) + @($Arguments | ForEach-Object { ConvertTo-CapsulenvProcessArgument -Argument $_ })
    $process = $null
    $startIdentity = $null
    $record = $null
    try {
        $launch = Start-CapsulenvOwnedProcess `
            -FilePath ([string]$binding.Program.Executable) `
            -ArgumentList $launchArguments `
            -WorkingDirectory (Split-Path -Parent ([string]$binding.Program.Executable)) `
            -SessionId $effectiveSessionId `
            -Role browser `
            -Provenance ([string]$binding.Program.Provenance) `
            -HeldLeases @($binding.Lease.LeaseId)
        $process = $launch.Process
        $startIdentity = $launch.ProcessStartIdentity
        $record = $launch.ProcessRecord
        $binding | Add-Member -NotePropertyName Process -NotePropertyValue $process -Force
        $watcher = Register-CapsulenvBrowserLeaseWatcher -Process $process -Lease $binding.Lease -SessionId $effectiveSessionId
        return [pscustomobject][ordered]@{
            Succeeded = $true
            Process = $process
            ProcessRecord = $record
            Binding = $binding
            LeaseWatcher = $watcher
        }
    } catch {
        try {
            if ($null -ne $record) {
                [void](Stop-CapsulenvOwnedProcessRecord -ProcessRecord $record)
            }
        } finally {
            [void](Release-CapsulenvStateLease -Lease $binding.Lease)
        }
        throw
    }
}

function Wait-CapsulenvPortableBrowser {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Browser)

    $binding = $Browser
    if ($Browser.PSObject.Properties.Match('Binding').Count -gt 0) {
        $binding = $Browser.Binding
    }
    [void](Complete-CapsulenvPortableBrowserBinding -Binding $binding -WaitForExit)
    return $Browser}

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvPortableBrowserProfilePath, Get-CapsulenvBrowserProgramRequirement, Get-CapsulenvBrowserCompatibilityEvidence, Test-CapsulenvBrowserProfileCompatibility, Resolve-CapsulenvBrowserBinding, Start-CapsulenvPortableBrowser, Wait-CapsulenvPortableBrowser, Stop-CapsulenvPortableBrowser, Close-CapsulenvPortableBrowser
