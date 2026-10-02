function ConvertTo-CapsulenvLauncherArgument {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value.Contains('"')) {
        throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.HostIntegration.LauncherArgumentUnsupported' -Message '[[CapsulenvText:HostIntegration.LauncherArgumentUnsupported.Message]]' -TargetObject $Value -Remediation @('[[CapsulenvText:HostIntegration.LauncherArgumentUnsupported.Remediation]]'))
    }
    return '"' + $Value + '"'
}

function New-CapsulenvStartMenuShortcutShell {
    [CmdletBinding()]
    param()

    return New-Object -ComObject WScript.Shell
}

function Sync-CapsulenvPackageStartMenuShortcuts {
    [CmdletBinding()]
    param(
        [ValidateSet('ShellOnly', 'User')]
        [string]$IntegrationMode = (Get-CapsulenvInstallMode)
    )

    if (-not (Test-CapsulenvWindows)) {
        return
    }
    if ($IntegrationMode -ne 'User') {
        return
    }

    # The whole capsule-specific namespace is Capsulenv-owned. Rebuild it as
    # one projection so shortcuts created by the pre-0.17 Scoop override cannot
    # survive relocation or coexist with the new launcher-based declarations.
    $capsuleRoot = Get-CapsulenvUserStartMenuShortcutRoot
    if ([string]::IsNullOrWhiteSpace([string]$capsuleRoot)) {
        return
    }
    if (Test-Path -LiteralPath $capsuleRoot -PathType Container) {
        Remove-Item -LiteralPath $capsuleRoot -Recurse -Force
    }
    $ownedRoot = Join-Path $capsuleRoot 'PortableSafe'

    $declarations = New-Object System.Collections.Generic.List[object]
    foreach ($state in @(Get-CapsulenvInstalledPackageStates -Strict)) {
        foreach ($shortcut in @(Get-CapsulenvScoopAppShortcuts -App ('capsule/' + $state.Name))) {
            $declarations.Add([pscustomobject]@{
                Package = [string]$state.Name
                Name = [string]$shortcut.Name
                Target = [string]$shortcut.Target
                Icon = [string]$shortcut.Icon
            })
        }
    }
    if ($declarations.Count -eq 0) {
        return
    }

    $capsuleId = Get-CapsulenvIdentity
    # Persistent shortcuts must remain usable after a removable capsule moves.
    # The host-local package bridge owns capsule discovery and is the only
    # persistent entrypoint allowed to name the capsule launcher.
    $packageBridge = New-CapsulenvUserIntegrationPackageBridge -CapsuleId $capsuleId
    $hostPowerShell = Get-CapsulenvPersistentHostPowerShellExecutable
    [void](New-Item -ItemType Directory -Path $ownedRoot -Force)
    $shell = New-CapsulenvStartMenuShortcutShell
    try {
        foreach ($declaration in $declarations.ToArray()) {
            $packageRoot = Join-Path $ownedRoot ([string]$declaration.Package)
            [void](New-Item -ItemType Directory -Path $packageRoot -Force)
            $shortcutPath = Resolve-CapsulenvScoopAppRelativePath `
                -Root $packageRoot `
                -RelativePath (([string]$declaration.Name) + '.lnk')
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $shortcutPath) -Force)
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $hostPowerShell
            $shortcut.Arguments = @(
                '-NoLogo',
                '-NoProfile',
                '-ExecutionPolicy',
                'Bypass',
                '-File',
                (ConvertTo-CapsulenvLauncherArgument -Value ([string]$packageBridge)),
                '-CapsuleId',
                (ConvertTo-CapsulenvLauncherArgument -Value ([string]$capsuleId)),
                '-Package',
                (ConvertTo-CapsulenvLauncherArgument -Value ('capsule/' + [string]$declaration.Package)),
                '-Shortcut',
                (ConvertTo-CapsulenvLauncherArgument -Value ([string]$declaration.Name))
            ) -join ' '
            $shortcut.WorkingDirectory = Split-Path -Parent ([string]$packageBridge)
            $shortcut.Description = "Capsulenv PortableSafe package: $($declaration.Package)"
            # Do not persist a removable package target as the shortcut icon.
            # The host runner is stable and keeps the complete .lnk host-local.
            $shortcut.IconLocation = $hostPowerShell + ',0'
            $shortcut.Save()
        }
    } finally {
        if ($null -ne $shell -and [System.Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
}

Register-CapsulenvDoctorCheck -Id 'Capsulenv.Doctor.HostIntegration.PackageLauncher' -Area 'HostIntegration' -Name 'PortableSafe package launcher integration' -Importance Optional -Handler {
    if (-not (Test-CapsulenvWindows)) {
        return New-CapsulenvDoctorResult -Id 'Capsulenv.Doctor.HostIntegration.PackageLauncher' -Name 'PortableSafe package launcher integration' -Area 'HostIntegration' -Status Skipped -Importance Optional -Summary 'Windows-only host integration is not applicable on this host.'
    }
    if (-not (Test-CapsulenvCurrentUserIntegrationOwnership)) {
        return New-CapsulenvDoctorResult -Id 'Capsulenv.Doctor.HostIntegration.PackageLauncher' -Name 'PortableSafe package launcher integration' -Area 'HostIntegration' -Status Skipped -Importance Optional -Summary 'This capsule does not currently own persistent User integration on this host.'
    }
    $launcher = Join-Path (Get-CapsulenvContext).Root 'capsulenv.cmd'
    $launcherExists = Test-Path -LiteralPath $launcher -PathType Leaf
    $shortcutRoot = Get-CapsulenvUserStartMenuShortcutRoot
    New-CapsulenvDoctorResult -Id 'Capsulenv.Doctor.HostIntegration.PackageLauncher' -Name 'PortableSafe package launcher integration' -Area 'HostIntegration' -Status $(if($launcherExists){'Healthy'}else{'Advisory'}) -Importance Optional -Summary $(if($launcherExists){"Launcher=$launcher; StartMenu=$shortcutRoot"}else{"Capsulenv launcher is missing: $launcher"}) -Detail $(if($launcherExists){"Launcher=$launcher; StartMenu=$shortcutRoot"}else{"Capsulenv launcher is missing: $launcher"}) -Data ([ordered]@{ Launcher=$launcher; LauncherExists=$launcherExists; StartMenuRoot=$shortcutRoot }) -Remediation $(if($launcherExists){@()}else{@('Rebuild or reinstall the capsule launcher before synchronizing User-mode Start Menu integration.')})
}

##MOD_EXEC## Export-ModuleMember -Function Sync-CapsulenvPackageStartMenuShortcuts
