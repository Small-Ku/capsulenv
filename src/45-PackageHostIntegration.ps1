function ConvertTo-CapsulenvLauncherArgument {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value.Contains('"')) {
        throw "Launcher argument contains an unsupported quote: $Value"
    }
    return '"' + $Value + '"'
}

function Sync-CapsulenvPackageStartMenuShortcuts {
    [CmdletBinding()]
    param()

    if (-not (Test-CapsulenvWindows)) {
        return
    }
    if ((Get-CapsulenvInstallMode) -ne 'User') {
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

    $launcher = Join-Path (Get-CapsulenvContext).Root 'capsulenv.cmd'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        throw "Capsulenv launcher is missing; Start Menu integration cannot be created: $launcher"
    }
    [void](New-Item -ItemType Directory -Path $ownedRoot -Force)
    $shell = New-Object -ComObject WScript.Shell
    try {
        foreach ($declaration in $declarations.ToArray()) {
            $packageRoot = Join-Path $ownedRoot ([string]$declaration.Package)
            [void](New-Item -ItemType Directory -Path $packageRoot -Force)
            $shortcutPath = Resolve-CapsulenvScoopAppRelativePath `
                -Root $packageRoot `
                -RelativePath (([string]$declaration.Name) + '.lnk')
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $shortcutPath) -Force)
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $launcher
            $shortcut.Arguments = @(
                'app',
                'run',
                (ConvertTo-CapsulenvLauncherArgument -Value ('capsule/' + [string]$declaration.Package)),
                (ConvertTo-CapsulenvLauncherArgument -Value ([string]$declaration.Name))
            ) -join ' '
            $shortcut.WorkingDirectory = (Get-CapsulenvContext).Root
            $shortcut.Description = "Capsulenv PortableSafe package: $($declaration.Package)"
            $icon = if (
                -not [string]::IsNullOrWhiteSpace([string]$declaration.Icon) -and
                (Test-Path -LiteralPath ([string]$declaration.Icon) -PathType Leaf)
            ) {
                [string]$declaration.Icon
            } else {
                [string]$declaration.Target
            }
            if (Test-Path -LiteralPath $icon -PathType Leaf) {
                $shortcut.IconLocation = $icon
            }
            $shortcut.Save()
        }
    } finally {
        if ($null -ne $shell -and [System.Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
}

##MOD_EXEC## Export-ModuleMember -Function Sync-CapsulenvPackageStartMenuShortcuts
