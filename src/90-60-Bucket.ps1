function Invoke-CapsulenvBucketCommand {
    [CmdletBinding()]
    param([string[]]$Arguments)

    if ($Arguments.Count -lt 1) {
        Show-CapsulenvHelp -Topic bucket
        return
    }

    $action = $Arguments[0].ToLowerInvariant()
    $remaining = @($Arguments | Select-Object -Skip 1)
    if ($action -in @('help', '--help', '-h')) {
        if ($remaining.Count -gt 1) {
            throw (New-CapsulenvCliUsageError -Message 'bucket help accepts at most one action.' -Usage 'capsulenv bucket help [action]' -Topic bucket)
        }
        $helpAction = if ($remaining.Count -eq 1) { [string]$remaining[0] } else { $null }
        Show-CapsulenvHelp -Topic bucket -Action $helpAction
        return
    }
    if ($remaining.Count -eq 1 -and [string]$remaining[0] -in @('--help', '-h')) {
        Show-CapsulenvHelp -Topic bucket -Action $action
        return
    }
    $scoopArguments = $null
    switch ($action) {
        'list' {
            if ($remaining.Count -gt 0) {
                throw (New-CapsulenvCliUsageError -Message 'bucket list does not accept additional arguments.' -Usage 'capsulenv bucket list' -Topic bucket)
            }
            $scoopArguments = @('bucket', 'list')
        }
        'known' {
            if ($remaining.Count -gt 0) {
                throw (New-CapsulenvCliUsageError -Message 'bucket known does not accept additional arguments.' -Usage 'capsulenv bucket known' -Topic bucket)
            }
            $scoopArguments = @('bucket', 'known')
        }
        'add' {
            if ($remaining.Count -lt 1 -or $remaining.Count -gt 2) {
                throw (New-CapsulenvCliUsageError -Message 'bucket add requires a bucket name and optional repository.' -Usage 'capsulenv bucket add <name> [repository]' -Topic bucket)
            }
            $scoopArguments = @('bucket', 'add') + @($remaining)
        }
        { $_ -in @('remove', 'rm') } {
            if ($remaining.Count -ne 1) {
                throw (New-CapsulenvCliUsageError -Message 'bucket remove requires exactly one bucket name.' -Usage 'capsulenv bucket remove <name>' -Topic bucket)
            }
            $scoopArguments = @('bucket', 'rm', [string]$remaining[0])
        }
        'update' {
            if ($remaining.Count -gt 0) {
                throw (New-CapsulenvCliUsageError -Message 'Scoop refreshes configured buckets together; bucket update does not accept a bucket name.' -Usage 'capsulenv bucket update' -Topic bucket)
            }
            $scoopArguments = @('update')
        }
        default {
            throw (New-CapsulenvCliUnknownActionError -Group bucket -Action $action -Id 'Capsulenv.Cli.UnknownBucketAction')
        }
    }

    [void](Set-CapsulenvSessionEnvironment)
    [void](Invoke-CapsulenvScoopCommand -Arguments ([string[]]$scoopArguments))
}
