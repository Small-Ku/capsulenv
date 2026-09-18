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

function Resolve-CapsulenvUserIntegrationCapsuleRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CapsuleId)

    $bridge = Get-CapsulenvUserIntegrationBridge -CapsuleId $CapsuleId
    if ($null -eq $bridge) {
        throw "No host-local UserIntegration bridge is registered for capsule '$CapsuleId'."
    }
    foreach ($root in @($bridge.CapsuleRoots)) {
        if (Test-CapsulenvRegisteredCapsuleRoot -Root ([string]$root) -CapsuleId $CapsuleId) {
            return [System.IO.Path]::GetFullPath([string]$root)
        }
    }
    throw "Capsule '$CapsuleId' is absent. The bridge will not guess a drive letter, browser executable, or unrelated profile."
}

function Get-CapsulenvUserIntegrationBridgeCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Bridge)

    $hostPowerShell = if (Test-CapsulenvWindows) {
        $windowsPowerShell = Join-Path ([Environment]::GetEnvironmentVariable('WINDIR')) 'System32/WindowsPowerShell/v1.0/powershell.exe'
        if (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf) { $windowsPowerShell } else { 'powershell.exe' }
    } else {
        $command = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) { throw 'A host PowerShell runner is required for the persistent bridge.' }
        [string]$command.Source
    }
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
    $context = Get-CapsulenvContext
    $rootReference = [System.IO.Path]::GetFullPath($context.Root)
    if (-not (Test-CapsulenvRegisteredCapsuleRoot -Root $rootReference -CapsuleId $CapsuleId)) {
        throw "Capsule root does not prove the requested CapsuleId: $CapsuleId"
    }
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

$manifestPath = Join-Path $PSScriptRoot 'bridge.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "No host-local UserIntegration manifest exists for capsule '$CapsuleId'."
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$capsuleRoot = $null
foreach ($candidate in @($manifest.CapsuleRoots)) {
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
        CapsuleRoots = @($rootReference)
        Handler = 'host-local-powershell-bridge'
        CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-CapsulenvHostJsonAtomically -Path $manifestPath -Value $manifest
    return $manifest
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
            try { Restore-CapsulenvDefaultBrowserRegistration } catch {}
        }
        Remove-Item -LiteralPath $root -Recurse -Force
        return [pscustomobject]@{ Removed = $true; Root = $root }
    }
    return [pscustomobject]@{ Removed = $false; Root = $root; Reason = 'WhatIf' }
}

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvUserIntegrationBridgeRoot, New-CapsulenvUserIntegrationBridge, Get-CapsulenvUserIntegrationBridge, Resolve-CapsulenvUserIntegrationCapsuleRoot, Get-CapsulenvUserIntegrationBridgeCommand, Invoke-CapsulenvUserIntegrationBridge, Install-CapsulenvUserIntegration, Remove-CapsulenvUserIntegrationBridge
