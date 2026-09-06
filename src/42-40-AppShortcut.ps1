function Get-CapsulenvScoopAppShortcuts {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$App)

    $installed = Get-CapsulenvInstalledApp -Selector $App
    $results = New-Object System.Collections.Generic.List[object]
    $entrySet = Get-CapsulenvInstalledShortcutEntries -App $installed
    foreach ($entry in @($entrySet.Entries)) {
        $results.Add((ConvertTo-CapsulenvInstalledShortcut -App $installed -Entry $entry))
    }
    return $results.ToArray()
}

function Get-CapsulenvScoopShortcutCatalog {
    [CmdletBinding()]
    param()

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($scope in @('Capsule', 'User', 'Global')) {
        $rootRecord = Get-CapsulenvInstalledAppRootRecord -Scope $scope
        if (-not (Test-Path -LiteralPath $rootRecord.AppsRoot -PathType Container)) {
            continue
        }
        foreach ($directory in @(Get-ChildItem -LiteralPath $rootRecord.AppsRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $current = Join-Path $directory.FullName 'current'
            if (-not (Test-Path -LiteralPath $current -PathType Container)) {
                continue
            }
            try {
                $selector = if ($scope -eq 'Capsule') {
                    'capsule/{0}' -f $directory.Name
                } else {
                    'scoop:{0}/{1}' -f $scope.ToLowerInvariant(), $directory.Name
                }
                foreach ($shortcut in @(Get-CapsulenvScoopAppShortcuts -App $selector)) {
                    $results.Add($shortcut)
                }
            } catch {
                Write-Verbose $_.Exception.Message
            }
        }
    }
    return $results.ToArray()
}

function Start-CapsulenvScoopShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [string]$ShortcutName,
        [string[]]$Arguments = @(),
        [switch]$PassThru
    )

    [void](Set-CapsulenvSessionEnvironment)
    $installed = Get-CapsulenvInstalledApp -Selector $App
    $shortcuts = @(Get-CapsulenvScoopAppShortcuts -App $installed.Selector)
    if ($shortcuts.Count -eq 0) {
        throw "Installed app '$App' does not define a shortcut. Use its shim/bin command when available."
    }

    $selected = $null
    if (-not [string]::IsNullOrWhiteSpace($ShortcutName)) {
        $matches = @($shortcuts | Where-Object { [string]$_.Name -eq $ShortcutName })
        if ($matches.Count -eq 0) {
            $available = @($shortcuts | ForEach-Object { [string]$_.Name }) -join ', '
            throw "Shortcut '$ShortcutName' was not found for '$App'. Available shortcuts: $available"
        }
        if ($matches.Count -gt 1) {
            throw "Shortcut name '$ShortcutName' is ambiguous for '$App'."
        }
        $selected = $matches[0]
    } elseif ($shortcuts.Count -eq 1) {
        $selected = $shortcuts[0]
    } else {
        $available = @($shortcuts | ForEach-Object { [string]$_.Name }) -join ', '
        throw "Installed app '$App' defines multiple shortcuts. Specify one of: $available"
    }

    if (-not (Test-Path -LiteralPath $selected.Target -PathType Leaf)) {
        throw "Shortcut target does not exist: $($selected.Target)"
    }

    # Scoop shortcut arguments are already one Windows command-line fragment.
    # Preserve that fragment, then append correctly escaped runtime arguments.
    $argumentFragments = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace([string]$selected.Arguments)) {
        $argumentFragments.Add([string]$selected.Arguments)
    }
    foreach ($argument in @($Arguments)) {
        $argumentFragments.Add((ConvertTo-CapsulenvProcessArgument -Argument ([string]$argument)))
    }
    $rawArguments = if ($argumentFragments.Count -gt 0) { $argumentFragments.ToArray() -join ' ' } else { '' }

    $environment = [pscustomobject]@{ PathEntries = @(); Variables = [ordered]@{} }
    if ([string]$installed.Scope -eq 'Capsule') {
        $environment = Get-CapsulenvPackageEnvironmentPlan -Installed $installed
    }
    $plan = New-CapsulenvProcessPlan `
        -Executable ([string]$selected.Target) `
        -RawArgumentString $rawArguments `
        -WorkingDirectory ([string]$selected.WorkingDirectory) `
        -Environment $environment.Variables `
        -PathEntries @($environment.PathEntries) `
        -ExecutionMode Detached `
        -Metadata ([ordered]@{
            App = [string]$installed.Selector
            Shortcut = [string]$selected.Name
            Ownership = [string]$installed.Ownership
        })
    $process = Invoke-CapsulenvProcessPlan -Plan $plan
    if ($PassThru) {
        return $process
    }
    if ($process -is [System.IDisposable]) {
        $process.Dispose()
    }
    return $null
}

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvScoopAppShortcuts, Get-CapsulenvScoopAppBins, Get-CapsulenvScoopShortcutCatalog, Start-CapsulenvScoopShortcut, Resolve-CapsulenvScoopAppExecutable, Resolve-CapsulenvScoopAppPersistPath
