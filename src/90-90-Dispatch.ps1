function Invoke-Capsulenv {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments = @()
    )

    [void](Initialize-CapsulenvContext -Root $env:CAPSULENV_ROOT)
    $command = if ($Arguments.Count -gt 0) { $Arguments[0].ToLowerInvariant() } else { 'shell' }
    $remaining = @($Arguments | Select-Object -Skip 1)

    $catalogCommand = Get-CapsulenvCliCommandCatalog | Where-Object { [string]$_.Name -eq $command } | Select-Object -First 1
    if ($null -ne $catalogCommand -and $remaining.Count -eq 1 -and [string]$remaining[0] -in @('--help', '-h')) {
        Show-CapsulenvHelp -Topic $command
        return
    }

    $knownGroupActions = @(Get-CapsulenvCliActionCatalog -Group $command)
    if ($knownGroupActions.Count -gt 0 -and $remaining.Count -gt 0) {
        $requestedAction = ([string]$remaining[0]).ToLowerInvariant()
        if ($requestedAction -in @('help', '--help', '-h')) {
            if ($remaining.Count -gt 2) {
                throw (New-CapsulenvCliUsageError -Message ("{0} help accepts at most one action." -f $command) -Usage ("capsulenv {0} help [action]" -f $command) -Topic $command)
            }
            $helpAction = if ($remaining.Count -eq 2) { [string]$remaining[1] } else { $null }
            Show-CapsulenvHelp -Topic $command -Action $helpAction
            return
        }
        if ($remaining.Count -eq 2 -and [string]$remaining[1] -in @('--help', '-h')) {
            Show-CapsulenvHelp -Topic $command -Action $requestedAction
            return
        }
    }

    try {
        switch ($command) {
        'shell' { Invoke-CapsulenvChildShell }
        'user-shell' {
            $unknown = @($remaining | Where-Object { $_ -ne '--force' })
            if ($unknown.Count -gt 0 -or @($remaining | Where-Object { $_ -eq '--force' }).Count -gt 1) {
                throw 'Usage: user-shell [--force]'
            }
            Enter-CapsulenvUserShell -Force:($remaining -contains '--force')
        }
        'bootstrap' {
            if ($remaining.Count -gt 0) {
                throw 'Usage: bootstrap'
            }
            [void](Set-CapsulenvSessionEnvironment)
            Initialize-CapsulenvScoopBootstrap -ForceRepair | Format-List
        }
        'run' {
            if ($remaining.Count -lt 1) {
                throw 'Usage: run <command> [arguments...]'
            }
            $externalArguments = @($remaining | Select-Object -Skip 1)
            Invoke-CapsulenvExternalCommand -Command $remaining[0] -Arguments $externalArguments
        }
        'app' { Invoke-CapsulenvAppCommand -Arguments $remaining }
        'bucket' { Invoke-CapsulenvBucketCommand -Arguments $remaining }
        'init' {
            $allowed = @('--skip-hooks', '--skip-persist-repairs', '--skip-tool-repairs', '--strict-tool-repairs')
            $unknown = @($remaining | Where-Object { $_ -notin $allowed })
            if ($unknown.Count -gt 0) {
                throw 'Usage: init [--skip-hooks] [--skip-persist-repairs] [--skip-tool-repairs] [--strict-tool-repairs]'
            }
            Initialize-Capsulenv `
                -SkipHooks:($remaining -contains '--skip-hooks') `
                -SkipPersistRepairs:($remaining -contains '--skip-persist-repairs') `
                -SkipToolRepairs:($remaining -contains '--skip-tool-repairs') `
                -StrictToolRepairs:($remaining -contains '--strict-tool-repairs')
        }
        'rehydrate' {
            $allowed = @('--skip-hooks', '--skip-persist-repairs', '--skip-tool-repairs', '--strict-tool-repairs')
            $unknown = @($remaining | Where-Object { $_ -notin $allowed })
            if ($unknown.Count -gt 0) {
                throw 'Usage: rehydrate [--skip-hooks] [--skip-persist-repairs] [--skip-tool-repairs] [--strict-tool-repairs]'
            }
            Invoke-CapsulenvScoopRehydrate `
                -SkipHooks:($remaining -contains '--skip-hooks') `
                -SkipPersistRepairs:($remaining -contains '--skip-persist-repairs') `
                -SkipToolRepairs:($remaining -contains '--skip-tool-repairs') `
                -StrictToolRepairs:($remaining -contains '--strict-tool-repairs')
        }
        'repair-persist' {
            $allowedFlags = @('--dry-run', '--last')
            $unknownFlags = @($remaining | Where-Object { $_ -like '--*' -and $_ -notin $allowedFlags })
            if ($unknownFlags.Count -gt 0) {
                throw 'Usage: repair-persist [app...] [--dry-run] [--last]'
            }
            $apps = @($remaining | Where-Object { $_ -notlike '--*' })
            $relocationContext = if ($remaining -contains '--last') {
                Get-CapsulenvLastRelocationContext
            } else {
                Get-CapsulenvRelocationContext
            }
            Invoke-CapsulenvPersistRelocationRepair `
                -RelocationContext $relocationContext `
                -Apps $apps `
                -DryRun:($remaining -contains '--dry-run') |
                Format-List
        }
        'hooks' {
            throw "capsulenv hooks was removed with the Scoop runtime adapter. Arbitrary manifest lifecycle code belongs to explicit upstream Scoop execution; use 'scoop reset/install/update' only after reviewing that package's semantics."
        }
        'reset' {
            [void](Set-CapsulenvSessionEnvironment)
            $apps = if ($remaining.Count -gt 0) { $remaining } else { @('*') }
            [void](Repair-CapsulenvInstalledAppProjections -Apps $apps)
        }
        'reset-shims' {
            [void](Set-CapsulenvSessionEnvironment)
            [void](Repair-CapsulenvInstalledAppProjections)
        }
        'install-user' {
            $unknown = @($remaining | Where-Object { $_ -ne '--force' })
            if ($unknown.Count -gt 0 -or @($remaining | Where-Object { $_ -eq '--force' }).Count -gt 1) {
                throw 'Usage: install-user [--force]'
            }
            Install-CapsulenvUserEnvironment -Force:($remaining -contains '--force')
        }
        'enable-user' {
            $unknown = @($remaining | Where-Object { $_ -ne '--force' })
            if ($unknown.Count -gt 0 -or @($remaining | Where-Object { $_ -eq '--force' }).Count -gt 1) {
                throw 'Usage: enable-user [--force]'
            }
            Install-CapsulenvUserEnvironment -Force:($remaining -contains '--force')
        }
        'restore-user' {
            if ($remaining.Count -gt 0) {
                throw 'Usage: restore-user'
            }
            Restore-CapsulenvUserEnvironment
        }
        'eject' {
            $unknown = @($remaining | Where-Object { $_ -ne '--force' })
            if ($unknown.Count -gt 0 -or @($remaining | Where-Object { $_ -eq '--force' }).Count -gt 1) {
                throw 'Usage: eject [--force]'
            }
            Invoke-CapsulenvEject -Force:($remaining -contains '--force') | Format-List
        }
        'offline' { Invoke-CapsulenvOfflineCommand -Arguments $remaining }
        'drift' {
            if ($remaining.Count -gt 0) { throw 'Usage: drift' }
            Get-CapsulenvVersionDrift | Format-Table -AutoSize
        }
        'resolve' { Invoke-CapsulenvResolveCommand -Arguments $remaining }
        'status' {
            if ($remaining.Count -gt 0) { throw 'Usage: status' }
            Get-CapsulenvStatus | Format-List
        }
        'version' {
            if ($remaining.Count -gt 0) { throw 'Usage: version' }
            Get-CapsulenvRuntimeVersion | Write-Output
        }
        'context' {
            if ($remaining.Count -gt 1 -or ($remaining.Count -eq 1 -and [string]$remaining[0] -ne '--json')) {
                throw 'Usage: context [--json]'
            }
            $runtimeContext = Get-CapsulenvRuntimeContext
            if ($remaining -contains '--json') {
                $runtimeContext | ConvertTo-Json -Depth 6 | Write-Output
            } else {
                $runtimeContext | Format-List
            }
        }
        'doctor' { Invoke-CapsulenvDoctor | Out-Null }
        'seed' { Invoke-CapsulenvSeedCommand -Arguments $remaining }
        'cache' { Invoke-CapsulenvCacheCommand -Arguments $remaining }
        'tools' { Invoke-CapsulenvToolsCommand -Arguments $remaining }
        'browser' {
            if ($remaining.Count -lt 1) {
                throw 'Usage: browser <scoop-app> [--host] [browser arguments...]'
            }
            Invoke-CapsulenvBrowserCommand `
                -App ([string]$remaining[0]) `
                -Arguments @($remaining | Select-Object -Skip 1)
        }
        'firefox' { Invoke-CapsulenvBrowserCommand -App firefox -Arguments $remaining }
        'zen' { Invoke-CapsulenvBrowserCommand -App zen-browser -Arguments $remaining }
        'librewolf' { Invoke-CapsulenvBrowserCommand -App librewolf -Arguments $remaining }
        'bitwarden' { Invoke-CapsulenvBitwardenCommand -Arguments $remaining }
        'routine' { Invoke-CapsulenvRoutineCommand -Arguments $remaining }
        'help' {
            $helpArguments = @($remaining)
            if ($helpArguments.Count -gt 2) { throw 'Usage: help [topic] [action]' }
            $topic = if ($helpArguments.Count -ge 1) { [string]$helpArguments[0] } else { $null }
            $action = if ($helpArguments.Count -eq 2) { [string]$helpArguments[1] } else { $null }
            Show-CapsulenvHelp -Topic $topic -Action $action
        }
        '--help' { Show-CapsulenvHelp }
        '-h' { Show-CapsulenvHelp }
        default { throw (New-CapsulenvCliUnknownCommandError -Command $command) }
        }
    } catch {
        $converted = ConvertTo-CapsulenvCliErrorRecord -ErrorRecord $_ -Command $command
        throw $converted
    }
}

Set-Alias -Name cenv -Value Invoke-Capsulenv
##MOD_EXEC## Export-ModuleMember -Function Invoke-Capsulenv
##MOD_EXEC## Export-ModuleMember -Alias cenv
