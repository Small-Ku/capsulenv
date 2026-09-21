function Get-CapsulenvUserIntegrationBridgeRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CapsuleId)

    if ($CapsuleId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw 'CapsuleId must be a safe host-local bridge path component.'
    }
    $record = Get-CapsulenvHostRecord
    if (-not [bool]$record.Enrolled -or [string]$record.Retention -ne 'persistent') {
        return $null
    }
    return Join-Path (Join-Path (Get-CapsulenvHostLocalStateRoot) 'user-bridges') $CapsuleId
}

function Get-CapsulenvUserIntegrationBridgeManifestPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CapsuleId)

    $root = Get-CapsulenvUserIntegrationBridgeRoot -CapsuleId $CapsuleId
    if ([string]::IsNullOrWhiteSpace($root)) {
        return $null
    }
    return Join-Path $root 'bridge.json'
}

function Get-CapsulenvUserIntegrationCapsuleLocatorPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CapsuleId)

    $root = Get-CapsulenvUserIntegrationBridgeRoot -CapsuleId $CapsuleId
    if ([string]::IsNullOrWhiteSpace($root)) {
        return $null
    }
    return Join-Path $root 'capsule-locator.json'
}

function New-CapsulenvUserIntegrationCapsuleLocator {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CapsuleId)

    $root = Get-CapsulenvUserIntegrationBridgeRoot -CapsuleId $CapsuleId
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw 'Persistent UserIntegration requires explicit host enrollment with retention=persistent; ephemeral hosts do not publish a capsule locator.'
    }
    [void](New-Item -ItemType Directory -Path $root -Force)
    $context = Get-CapsulenvContext
    $rootReference = [System.IO.Path]::GetFullPath($context.Root)
    if (-not (Test-CapsulenvRegisteredCapsuleRoot -Root $rootReference -CapsuleId $CapsuleId)) {
        throw "Capsule root does not prove the requested CapsuleId: $CapsuleId"
    }
    $pathRoot = [System.IO.Path]::GetPathRoot($rootReference)
    $relativePath = $rootReference.Substring($pathRoot.Length).TrimStart([char[]]'\/')
    $locator = [pscustomobject][ordered]@{
        SchemaVersion = 1
        CapsuleId = $CapsuleId
        HostKey = Get-CapsulenvHostKey
        CapsuleRoots = @($rootReference)
        CapsuleLocators = @([ordered]@{ RelativePath = $relativePath })
        LauncherName = 'capsulenv.cmd'
        CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-CapsulenvHostJsonAtomically -Path (Get-CapsulenvUserIntegrationCapsuleLocatorPath -CapsuleId $CapsuleId) -Value $locator
    return $locator
}

function Get-CapsulenvUserIntegrationCapsuleLocator {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CapsuleId)

    $path = Get-CapsulenvUserIntegrationCapsuleLocatorPath -CapsuleId $CapsuleId
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        $locator = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if (
            [int]$locator.SchemaVersion -ne 1 -or
            -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$locator.CapsuleId, $CapsuleId) -or
            [string]::IsNullOrWhiteSpace([string]$locator.HostKey)
        ) {
            return $null
        }
        return $locator
    } catch {
        return $null
    }
}

function Test-CapsulenvRegisteredCapsuleRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$CapsuleId
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $false }
    $identityPath = Join-Path $Root '.capsulenv/identity.json'
    if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) { return $false }
    try {
        $identity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
        return [int]$identity.SchemaVersion -eq 1 -and [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$identity.Id, $CapsuleId)
    } catch {
        return $false
    }
}

function Get-CapsulenvCapsuleLocatorCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Alias('Bridge')]
        $Locator
    )

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($root in @($Locator.CapsuleRoots)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$root)) {
            $candidates.Add([string]$root)
        }
    }
    foreach ($locatorEntry in @($Locator.CapsuleLocators)) {
        $relative = [string]$locatorEntry.RelativePath
        if ([string]::IsNullOrWhiteSpace($relative)) { continue }
        foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            try {
                $candidate = [System.IO.Path]::GetFullPath((Join-Path ([string]$drive.Root) $relative))
                if (-not $candidates.Contains($candidate)) {
                    $candidates.Add($candidate)
                }
            } catch {}
        }
    }
    return @($candidates.ToArray())
}

function Resolve-CapsulenvUserIntegrationCapsuleRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CapsuleId)

    $locator = Get-CapsulenvUserIntegrationCapsuleLocator -CapsuleId $CapsuleId
    if ($null -eq $locator) {
        # Existing browser bridges carry the same locator fields. Keep reading
        # them for migration, but new package integrations never depend on a
        # browser bridge being present.
        $locator = Get-CapsulenvUserIntegrationBridge -CapsuleId $CapsuleId
    }
    if ($null -eq $locator) {
        throw "No host-local UserIntegration capsule locator is registered for capsule '$CapsuleId'."
    }
    foreach ($root in @(Get-CapsulenvCapsuleLocatorCandidates -Locator $locator)) {
        if (Test-CapsulenvRegisteredCapsuleRoot -Root ([string]$root) -CapsuleId $CapsuleId) {
            return [System.IO.Path]::GetFullPath([string]$root)
        }
    }
    throw "Capsule '$CapsuleId' is absent. The bridge will not guess a drive letter, browser executable, or unrelated profile."
}

function Get-CapsulenvPersistentHostPowerShellExecutable {
    [CmdletBinding()]
    param()

    if (Test-CapsulenvWindows) {
        $windir = [Environment]::GetEnvironmentVariable('WINDIR')
        if ([string]::IsNullOrWhiteSpace($windir)) {
            throw 'WINDIR is unavailable; refusing to install a persistent host bridge.'
        }
        $windowsPowerShell = [System.IO.Path]::GetFullPath((Join-Path $windir 'System32/WindowsPowerShell/v1.0/powershell.exe'))
        if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
            throw "The persistent host bridge runner is unavailable: $windowsPowerShell"
        }
        return $windowsPowerShell
    }

    $command = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command -and (Test-Path -LiteralPath ([string]$command.Source) -PathType Leaf)) {
        return [System.IO.Path]::GetFullPath([string]$command.Source)
    }
    $runtimePwsh = Join-Path $PSHOME 'pwsh'
    if (-not (Test-Path -LiteralPath $runtimePwsh -PathType Leaf)) {
        $runtimePwsh = Join-Path $PSHOME 'pwsh.exe'
    }
    if (-not (Test-Path -LiteralPath $runtimePwsh -PathType Leaf)) {
        throw 'A host PowerShell runner is required for the persistent bridge.'
    }
    return [System.IO.Path]::GetFullPath($runtimePwsh)
}

function Get-CapsulenvUserIntegrationBridgeCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Bridge)

    $hostPowerShell = Get-CapsulenvPersistentHostPowerShellExecutable
    return [pscustomobject][ordered]@{
        Executable = $hostPowerShell
        Arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', [string]$Bridge.BridgePath, '-CapsuleId', [string]$Bridge.CapsuleId, '-BrowserApp', [string]$Bridge.BrowserApp, '-Arguments', '%1')
        Command = ('"{0}" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "{1}" -CapsuleId "{2}" -BrowserApp "{3}" -Arguments "%1"' -f $hostPowerShell, [string]$Bridge.BridgePath, [string]$Bridge.CapsuleId, [string]$Bridge.BrowserApp)
    }
}

function New-CapsulenvUserIntegrationBridge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CapsuleId,
        [Parameter(Mandatory = $true)][string]$BrowserApp,
        $BrowserBinding
    )

    $root = Get-CapsulenvUserIntegrationBridgeRoot -CapsuleId $CapsuleId
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw 'Persistent UserIntegration requires explicit host enrollment with retention=persistent; ephemeral hosts do not install a bridge.'
    }
    [void](New-Item -ItemType Directory -Path $root -Force)
    $bridgePath = Join-Path $root 'capsulenv-bridge.ps1'
    $manifestPath = Join-Path $root 'bridge.json'
    $locator = New-CapsulenvUserIntegrationCapsuleLocator -CapsuleId $CapsuleId
    $rootReference = [string](@($locator.CapsuleRoots)[0])
    $browserIdentity = [string]$BrowserApp
    if ($null -ne $BrowserBinding -and $null -ne $BrowserBinding.PSObject.Properties['Program']) {
        $boundName = [string]$BrowserBinding.Program.Name
        if (-not [string]::IsNullOrWhiteSpace($boundName)) {
            $browserIdentity = $boundName
        }
    }
    $bridgeScript = @'
param(
    [Parameter(Mandatory = $true)][string]$CapsuleId,
    [string]$BrowserApp = 'firefox',
    [string[]]$Arguments = @()
)

$locatorPath = Join-Path $PSScriptRoot 'capsule-locator.json'
if (-not (Test-Path -LiteralPath $locatorPath -PathType Leaf)) {
    throw "No host-local capsule locator exists for capsule '$CapsuleId'."
}
$locator = Get-Content -LiteralPath $locatorPath -Raw | ConvertFrom-Json
$capsuleRoot = $null
foreach ($candidate in @($locator.CapsuleRoots) + @($locator.CapsuleLocators | ForEach-Object {
    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$_.RelativePath)) {
            try { Join-Path ([string]$drive.Root) ([string]$_.RelativePath) } catch {}
        }
    }
})) {
    $identityPath = Join-Path ([string]$candidate) '.capsulenv/identity.json'
    if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) { continue }
    try {
        $identity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
        if ([int]$identity.SchemaVersion -eq 1 -and [string]$identity.Id -eq [string]$CapsuleId) {
            $capsuleRoot = [System.IO.Path]::GetFullPath([string]$candidate)
            break
        }
    } catch {}
}
if ([string]::IsNullOrWhiteSpace($capsuleRoot)) {
    throw "Capsule '$CapsuleId' is absent. Attach the intended capsule and retry; no drive letter or unrelated profile will be guessed."
}
$launcher = Join-Path $capsuleRoot 'capsulenv.cmd'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw "Capsule '$CapsuleId' is attached but its host launcher is unavailable."
}
& $launcher browser $BrowserApp @Arguments
'@
    Set-Content -LiteralPath $bridgePath -Value $bridgeScript -Encoding UTF8
    $manifest = [pscustomobject][ordered]@{
        SchemaVersion = 1
        CapsuleId = $CapsuleId
        HostKey = Get-CapsulenvHostKey
        BrowserApp = $BrowserApp
        BridgePath = $bridgePath
        Persistent = $true
        ProfileBinding = 'capsulenv-browser-binding'
        BrowserStateIdentity = $browserIdentity.Trim().ToLowerInvariant()
        CapsuleRoots = @($locator.CapsuleRoots)
        CapsuleLocators = @($locator.CapsuleLocators)
        Handler = 'host-local-powershell-bridge'
        CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-CapsulenvHostJsonAtomically -Path $manifestPath -Value $manifest
    return $manifest
}

function New-CapsulenvUserIntegrationPackageBridge {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CapsuleId)

    $root = Get-CapsulenvUserIntegrationBridgeRoot -CapsuleId $CapsuleId
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw 'Persistent package integration requires explicit host enrollment with retention=persistent.'
    }
    [void](New-Item -ItemType Directory -Path $root -Force)
    [void](New-CapsulenvUserIntegrationCapsuleLocator -CapsuleId $CapsuleId)
    $path = Join-Path $root 'capsulenv-package-bridge.ps1'
    $scriptText = @'
param(
    [Parameter(Mandatory = $true)][string]$CapsuleId,
    [Parameter(Mandatory = $true)][string]$Package,
    [Parameter(Mandatory = $true)][string]$Shortcut
)
$locatorPath = Join-Path $PSScriptRoot 'capsule-locator.json'
if (-not (Test-Path -LiteralPath $locatorPath -PathType Leaf)) {
    throw "No host-local capsule locator exists for capsule '$CapsuleId'."
}
$locator = Get-Content -LiteralPath $locatorPath -Raw | ConvertFrom-Json
$capsuleRoot = $null
foreach ($candidate in @($locator.CapsuleRoots) + @($locator.CapsuleLocators | ForEach-Object {
    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$_.RelativePath)) {
            try { Join-Path ([string]$drive.Root) ([string]$_.RelativePath) } catch {}
        }
    }
})) {
    $identityPath = Join-Path ([string]$candidate) '.capsulenv/identity.json'
    if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) { continue }
    try {
        $identity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
        if ([int]$identity.SchemaVersion -eq 1 -and [string]$identity.Id -eq [string]$CapsuleId) {
            $capsuleRoot = [System.IO.Path]::GetFullPath([string]$candidate)
            break
        }
    } catch {}
}
if ([string]::IsNullOrWhiteSpace($capsuleRoot)) {
    throw "Capsule '$CapsuleId' is absent. The host-local package bridge will not guess a drive letter."
}
$launcher = Join-Path $capsuleRoot 'capsulenv.cmd'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw "Capsule '$CapsuleId' is attached but its host launcher is unavailable."
}
& $launcher app run $Package $Shortcut
'@
    Set-Content -LiteralPath $path -Value $scriptText -Encoding UTF8
    return [System.IO.Path]::GetFullPath($path)
}

function Get-CapsulenvUserIntegrationBridge {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CapsuleId)

    $path = Get-CapsulenvUserIntegrationBridgeManifestPath -CapsuleId $CapsuleId
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Invoke-CapsulenvUserIntegrationBridge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CapsuleId,
        [string[]]$Arguments = @()
    )

    $bridge = Get-CapsulenvUserIntegrationBridge -CapsuleId $CapsuleId
    if ($null -eq $bridge) {
        throw "No host-local UserIntegration bridge is registered for capsule '$CapsuleId'."
    }
    $capsuleRoot = Resolve-CapsulenvUserIntegrationCapsuleRoot -CapsuleId $CapsuleId
    $launcher = Join-Path $capsuleRoot 'capsulenv.cmd'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        throw "Capsule '$CapsuleId' is attached but its host launcher is unavailable."
    }
    $browserIdentity = [string]$bridge.BrowserStateIdentity
    return [pscustomobject][ordered]@{
        Ready = $true
        CapsuleId = $CapsuleId
        BrowserApp = [string]$bridge.BrowserApp
        BrowserStateIdentity = $browserIdentity
        CapsuleRoot = $capsuleRoot
        LauncherPath = $launcher
        Arguments = @($Arguments)
        BridgePath = [string]$bridge.BridgePath
    }
}

function Install-CapsulenvUserIntegration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CapsuleId,
        [Parameter(Mandatory = $true)][string]$BrowserApp,
        $BrowserBinding,
        [switch]$DefaultBrowser
    )

    $bridge = New-CapsulenvUserIntegrationBridge -CapsuleId $CapsuleId -BrowserApp $BrowserApp -BrowserBinding $BrowserBinding
    $handler = Get-CapsulenvUserIntegrationBridgeCommand -Bridge $bridge
    if ($DefaultBrowser -and (Test-CapsulenvWindows)) {
        [void](Install-CapsulenvDefaultBrowserRegistration -App $BrowserApp)
    }
    return [pscustomobject][ordered]@{ Bridge = $bridge; Handler = $handler; DefaultBrowser = [bool]$DefaultBrowser }
}

function Remove-CapsulenvUserIntegrationBridge {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string]$CapsuleId)

    $root = Get-CapsulenvUserIntegrationBridgeRoot -CapsuleId $CapsuleId
    if ([string]::IsNullOrWhiteSpace($root)) {
        return [pscustomobject]@{ Removed = $false; Reason = 'host is not explicitly enrolled as persistent' }
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return [pscustomobject]@{ Removed = $false; Reason = 'bridge does not exist' }
    }
    if ($PSCmdlet.ShouldProcess($root, 'Remove host-local UserIntegration bridge')) {
        if (Test-CapsulenvWindows) {
            Restore-CapsulenvDefaultBrowserRegistration
        }
        Remove-Item -LiteralPath $root -Recurse -Force
        return [pscustomobject]@{ Removed = $true; Root = $root }
    }
    return [pscustomobject]@{ Removed = $false; Root = $root; Reason = 'WhatIf' }
}

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvUserIntegrationBridgeRoot, Get-CapsulenvUserIntegrationCapsuleLocatorPath, New-CapsulenvUserIntegrationCapsuleLocator, Get-CapsulenvUserIntegrationCapsuleLocator, New-CapsulenvUserIntegrationBridge, New-CapsulenvUserIntegrationPackageBridge, Get-CapsulenvUserIntegrationBridge, Resolve-CapsulenvUserIntegrationCapsuleRoot, Get-CapsulenvUserIntegrationBridgeCommand, Invoke-CapsulenvUserIntegrationBridge, Install-CapsulenvUserIntegration, Remove-CapsulenvUserIntegrationBridge
