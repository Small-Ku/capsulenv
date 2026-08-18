# Injected into Scoop mutation commands in Capsulenv User mode.
# Keep Scoop as shortcut owner while isolating this capsule from a foreign
# Scoop installation's shared "Scoop Apps" Start Menu namespace.
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

function Get-CapsulenvScoopShortcutIdentity {
    if ([string]::IsNullOrWhiteSpace($env:CAPSULENV_ID)) {
        throw 'CAPSULENV_ID is not set. Capsulenv User shortcut ownership cannot be resolved.'
    }
    $normalized = ([string]$env:CAPSULENV_ID) -replace '[^0-9A-Fa-f]', ''
    if ($normalized.Length -lt 12) {
        throw 'CAPSULENV_ID is invalid. Capsulenv User shortcut ownership cannot be resolved.'
    }
    return $normalized.Substring(0, 12).ToLowerInvariant()
}

function shortcut_folder($global) {
    $startmenu = if ($global) { 'CommonStartMenu' } else { 'StartMenu' }
    $root = [Environment]::GetFolderPath($startmenu)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "Windows $startmenu folder could not be resolved."
    }
    $identity = Get-CapsulenvScoopShortcutIdentity
    return Convert-Path (ensure ([System.IO.Path]::Combine($root, 'Programs', 'Capsulenv Apps', $identity)))
}
