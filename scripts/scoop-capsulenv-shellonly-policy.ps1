# Injected into Scoop lifecycle commands after upstream libraries are loaded.
# It keeps ShellOnly installs capsule-local and fail-closes on unreviewed lifecycle code.
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

function Get-CapsulenvScoopPolicyMap {
    $policy = @{}
    if ([string]::IsNullOrWhiteSpace($env:CAPSULENV_SCOOP_LIFECYCLE_POLICY)) {
        return $policy
    }
    try {
        $parsed = $env:CAPSULENV_SCOOP_LIFECYCLE_POLICY | ConvertFrom-Json
        foreach ($property in @($parsed.PSObject.Properties)) {
            $policy[[string]$property.Name] = [string]$property.Value
        }
    } catch {
        throw "Capsulenv Scoop lifecycle policy is invalid JSON: $($_.Exception.Message)"
    }
    return $policy
}

$script:CapsulenvScoopPolicyMap = Get-CapsulenvScoopPolicyMap

function Get-CapsulenvScoopLifecycleFingerprint {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)]$Value
    )

    $text = if ($Value -is [string]) {
        [string]$Value
    } elseif ($Value -is [System.Collections.IEnumerable]) {
        (@($Value) | ForEach-Object { [string]$_ }) -join "`n"
    } else {
        [string]$Value
    }
    $payload = "$Kind`n$text"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha.Dispose()
    }
}

function Get-CapsulenvScoopLifecycleAction {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)]$Value
    )

    $fingerprint = Get-CapsulenvScoopLifecycleFingerprint -Kind $Kind -Value $Value
    $action = if ($script:CapsulenvScoopPolicyMap.ContainsKey($fingerprint)) {
        [string]$script:CapsulenvScoopPolicyMap[$fingerprint]
    } else {
        'Block'
    }
    return [pscustomobject]@{
        Kind = $Kind
        Fingerprint = $fingerprint
        Action = $action
    }
}

function Assert-CapsulenvScoopLifecycleEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)]$Value,
        [switch]$AllowSkip
    )

    $decision = Get-CapsulenvScoopLifecycleAction -Kind $Kind -Value $Value
    if ($decision.Action -eq 'Allow') {
        return $decision
    }
    if ($decision.Action -eq 'Skip' -and $AllowSkip) {
        return $decision
    }

    $hint = "Fingerprint: $($decision.Fingerprint). Review the installed/bucket manifest and add that fingerprint to Scoop.ShellOnlyLifecyclePolicy as 'Allow'"
    if ($AllowSkip) {
        $hint += " or 'Skip'"
    }
    $hint += ', or run the operation from capsulenv User mode.'
    throw "ShellOnly blocked unreviewed Scoop lifecycle '$Kind'. $hint"
}

function Get-CapsulenvScoopExternalInstallerDescriptor {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)]$Descriptor
    )

    if ($null -eq $Descriptor -or (-not $Descriptor.file -and -not $Descriptor.args)) {
        return $null
    }
    $file = if ($null -ne $Descriptor.file) { [string]$Descriptor.file } else { '' }
    $argsText = (@($Descriptor.args) | ForEach-Object { [string]$_ }) -join "`n"
    $keep = if ($Descriptor.keep) { 'true' } else { 'false' }
    return "file=$file`nargs=$argsText`nkeep=$keep"
}

function Assert-CapsulenvScoopManifestLifecyclePolicy {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ProcessorArchitecture,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Install', 'Uninstall')]
        [string]$Operation
    )

    $hookTypes = if ($Operation -eq 'Install') {
        @('pre_install', 'post_install')
    } else {
        @('pre_uninstall', 'post_uninstall')
    }
    foreach ($hookType in $hookTypes) {
        $scriptText = arch_specific $hookType $Manifest $ProcessorArchitecture
        if ($scriptText) {
            [void](Assert-CapsulenvScoopLifecycleEntry -Kind $hookType -Value $scriptText -AllowSkip)
        }
    }

    $installerType = if ($Operation -eq 'Install') { 'installer' } else { 'uninstaller' }
    $descriptor = arch_specific $installerType $Manifest $ProcessorArchitecture
    if ($descriptor) {
        $external = Get-CapsulenvScoopExternalInstallerDescriptor -Kind $installerType -Descriptor $descriptor
        if ($null -ne $external) {
            $externalArgs = @{
                Kind = "$installerType-external"
                Value = $external
            }
            if ($Operation -eq 'Uninstall') {
                $externalArgs.AllowSkip = $true
            }
            [void](Assert-CapsulenvScoopLifecycleEntry @externalArgs)
        }
        if ($descriptor.script) {
            $scriptArgs = @{
                Kind = $installerType
                Value = $descriptor.script
            }
            if ($Operation -eq 'Uninstall') {
                $scriptArgs.AllowSkip = $true
            }
            [void](Assert-CapsulenvScoopLifecycleEntry @scriptArgs)
        }
    }
}

# Scoop's system helpers persist to HKCU/HKLM. In ShellOnly they are process-only.
function Set-EnvVar {
    param(
        [string]$Name,
        [string]$Value,
        [switch]$Global
    )
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}

function Add-Path {
    param(
        [string[]]$Path,
        [string]$TargetEnvVar = 'PATH',
        [switch]$Global,
        [switch]$Force,
        [switch]$Quiet
    )

    $currentTarget = [Environment]::GetEnvironmentVariable($TargetEnvVar, 'Process')
    $inTarget, $strippedTarget = Split-PathLikeEnvVar $Path $currentTarget
    if (!$inTarget -or $Force) {
        [Environment]::SetEnvironmentVariable($TargetEnvVar, ((@($Path) + $strippedTarget) -join ';'), 'Process')
    }
    if ($TargetEnvVar -ne 'PATH') {
        $inPath, $strippedPath = Split-PathLikeEnvVar $Path $env:PATH
        if (!$inPath -or $Force) {
            $env:PATH = (@($Path) + $strippedPath) -join ';'
        }
    }
}

function Remove-Path {
    param(
        [string[]]$Path,
        [string]$TargetEnvVar = 'PATH',
        [switch]$Global,
        [switch]$Quiet,
        [switch]$PassThru
    )

    $currentTarget = [Environment]::GetEnvironmentVariable($TargetEnvVar, 'Process')
    $inTarget, $strippedTarget = Split-PathLikeEnvVar $Path $currentTarget
    if ($inTarget) {
        [Environment]::SetEnvironmentVariable($TargetEnvVar, $strippedTarget, 'Process')
    }
    if ($TargetEnvVar -ne 'PATH') {
        $inPath, $strippedPath = Split-PathLikeEnvVar $Path $env:PATH
        if ($inPath) {
            $env:PATH = $strippedPath
        }
    }
    if ($PassThru) {
        return $inTarget
    }
}

function create_startmenu_shortcuts {
    param($manifest, $dir, $global, $arch)
    if (@(arch_specific 'shortcuts' $manifest $arch | Where-Object { $null -ne $_ }).Count -gt 0) {
        Write-Host 'ShellOnly: skipping Scoop Start Menu shortcuts.' -ForegroundColor DarkGray
    }
}

function rm_startmenu_shortcuts {
    param($manifest, $global, $arch)
    # ShellOnly never owns Start Menu shortcuts, so uninstall/reset must not remove host entries.
}

$script:CapsulenvOriginalInvokeHookScript = ${function:Invoke-HookScript}
function Invoke-HookScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('installer', 'pre_install', 'post_install', 'uninstaller', 'pre_uninstall', 'post_uninstall')]
        [string]$HookType,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [PSCustomObject]$Manifest,
        [Parameter(Mandatory = $true)]
        [Alias('Arch', 'Architecture')]
        [ValidateSet('32bit', '64bit', 'arm64')]
        [string]$ProcessorArchitecture
    )

    if ($HookType -eq 'pre_install') {
        Assert-CapsulenvScoopManifestLifecyclePolicy -Manifest $Manifest -ProcessorArchitecture $ProcessorArchitecture -Operation Install
    } elseif ($HookType -eq 'pre_uninstall') {
        Assert-CapsulenvScoopManifestLifecyclePolicy -Manifest $Manifest -ProcessorArchitecture $ProcessorArchitecture -Operation Uninstall
    }

    $scriptText = arch_specific $HookType $Manifest $ProcessorArchitecture
    if ($HookType -in @('installer', 'uninstaller')) {
        $scriptText = $scriptText.script
    }
    if (-not $scriptText) {
        return
    }

    $entryArgs = @{ Kind = $HookType; Value = $scriptText }
    if ($HookType -ne 'installer') {
        $entryArgs.AllowSkip = $true
    }
    $decision = Assert-CapsulenvScoopLifecycleEntry @entryArgs
    if ($decision.Action -eq 'Skip') {
        Write-Host "ShellOnly: skipping reviewed Scoop $HookType script ($($decision.Fingerprint.Substring(0, 12)))." -ForegroundColor DarkGray
        return
    }
    & $script:CapsulenvOriginalInvokeHookScript @PSBoundParameters
}
