function Invoke-CapsulenvOfflineCommand {
    param([string[]]$Arguments)

    $action = if ($Arguments.Count -gt 0) { $Arguments[0].ToLowerInvariant() } else { 'status' }
    $remaining = @($Arguments | Select-Object -Skip 1)
    switch ($action) {
        'status' {
            if ($remaining.Count -gt 0) { throw 'Usage: offline status' }
            Get-CapsulenvOfflineReadiness | Format-List
        }
        'prefetch' {
            Invoke-CapsulenvOfflinePrefetch -Apps $remaining | Format-List
        }
        default { throw 'Usage: offline <status|prefetch> [installed-app ...]' }
    }
}

function Invoke-CapsulenvSeedCommand {
    param([string[]]$Arguments)

    if ($Arguments.Count -lt 1) {
        throw 'Usage: seed <powershell|git|scoop|weasel> [...]'
    }
    $action = $Arguments[0].ToLowerInvariant()
    $remaining = @($Arguments | Select-Object -Skip 1)

    switch ($action) {
        'powershell' {
            $unknown = @($remaining | Where-Object { $_ -ne '--force' })
            if ($unknown.Count -gt 0 -or @($remaining | Where-Object { $_ -eq '--force' }).Count -gt 1) {
                throw 'Usage: seed powershell [--force]'
            }
            Seed-CapsulenvPowerShellProfiles -Force:($remaining -contains '--force') | Format-Table -AutoSize
        }
        'git' {
            $allowed = @('--force', '--include-sensitive')
            $unknown = @($remaining | Where-Object { $_ -notin $allowed })
            if ($unknown.Count -gt 0) {
                throw 'Usage: seed git [--force] [--include-sensitive]'
            }
            Seed-CapsulenvGitConfig `
                -Force:($remaining -contains '--force') `
                -IncludeSensitive:($remaining -contains '--include-sensitive') |
                Format-List
        }
        'scoop' {
            $allowed = @('--force', '--apply')
            $unknown = @($remaining | Where-Object { $_ -notin $allowed })
            if ($unknown.Count -gt 0) {
                throw 'Usage: seed scoop [--force] [--apply]'
            }
            Seed-CapsulenvScoopInventory `
                -Force:($remaining -contains '--force') `
                -Apply:($remaining -contains '--apply') |
                Format-List
        }
        'weasel' {
            $operation = if ($remaining.Count -gt 0 -and $remaining[0] -notlike '--*') {
                [string]$remaining[0].ToLowerInvariant()
            } else {
                'backup'
            }
            $options = @($remaining)
            if ($remaining.Count -gt 0 -and $remaining[0] -notlike '--*') {
                $options = @($remaining | Select-Object -Skip 1)
            }
            switch ($operation) {
                'backup' {
                    $unknown = @($options | Where-Object { $_ -ne '--force' })
                    if ($unknown.Count -gt 0 -or @($options | Where-Object { $_ -eq '--force' }).Count -gt 1) {
                        throw 'Usage: seed weasel [backup] [--force]'
                    }
                    Save-CapsulenvWeaselSeed -Force:($options -contains '--force') | Format-List
                }
                'restore' {
                    if ($options.Count -gt 0) {
                        throw 'Usage: seed weasel restore'
                    }
                    Restore-CapsulenvWeaselSeed | Format-List
                }
                default { throw "Unknown Weasel seed action: $operation. Use backup or restore." }
            }
        }
        default { throw "Unknown seed action: $($Arguments[0])" }
    }
}
