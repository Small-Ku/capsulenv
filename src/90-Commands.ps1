function Show-CapsulenvHelp {
    [CmdletBinding()]
    param()

    @'
capsulenv commands

  capsulenv.cmd shell
      Open a child PowerShell with the portable Scoop environment active.
      On a new host/path, rehydrate Scoop once before opening the shell.

  capsulenv.cmd run <command> [arguments...]
      Run one command inside the portable environment.

  capsulenv.cmd init [--skip-hooks] [--skip-persist-repairs]
  capsulenv.cmd rehydrate [--skip-hooks] [--skip-persist-repairs]
      Run native `scoop reset *`, replay configured safe lifecycle hooks,
      then repair allow-listed persisted text settings after relocation.

  capsulenv.cmd repair-persist [app...] [--dry-run] [--last]
      Repair only explicitly configured persisted files. --last reuses the
      most recently completed OldRoot -> NewRoot relocation context.

  capsulenv.cmd hooks <pre_install|post_install> <app> [app...]
      Explicitly replay one installed-manifest hook. pre_install is opt-in
      because many manifests implement it as a one-shot transformation.

  capsulenv.cmd reset [app...]
      Run native Scoop reset without lifecycle replay. Defaults to all apps.

  capsulenv.cmd enable-user
  capsulenv.cmd restore-user
      Persist or restore SCOOP/PATH/SSH_AUTH_SOCK using an exact backup.

  capsulenv.cmd doctor

  capsulenv.cmd firefox [arguments...]
  capsulenv.cmd zen [arguments...]
      Start the Scoop-installed browser. Its manifest/persist store owns the profile.

  capsulenv.cmd bitwarden setup [always|never|remember-until-lock]
      Enable the Bitwarden Desktop SSH Agent setting, configure Git, and
      disable the Windows ssh-agent service when running elevated.

  capsulenv.cmd bitwarden status
  capsulenv.cmd bitwarden restore
      Inspect or precisely restore the settings changed by setup.

  capsulenv.cmd bitwarden start
  capsulenv.cmd bitwarden agent-test
  capsulenv.cmd bitwarden disable-windows-agent
  capsulenv.cmd bitwarden restore-windows-agent
  capsulenv.cmd bitwarden configure-git
  capsulenv.cmd bitwarden restore-git
'@ | Write-Host
}

function Invoke-CapsulenvBitwardenCommand {
    param([string[]]$Arguments)

    if ($Arguments.Count -lt 1) {
        throw 'Usage: bitwarden <setup|status|restore|start|agent-test|disable-windows-agent|restore-windows-agent|configure-git|restore-git>'
    }

    $action = $Arguments[0].ToLowerInvariant()
    $remaining = if ($Arguments.Count -gt 1) {
        @($Arguments[1..($Arguments.Count - 1)])
    } else {
        @()
    }

    switch ($action) {
        'setup' {
            $allowedFlags = @('--skip-service', '--skip-git', '--no-start')
            $unknownFlags = @($remaining | Where-Object { $_ -like '--*' -and $_ -notin $allowedFlags })
            $positionals = @($remaining | Where-Object { $_ -notlike '--*' })
            if ($unknownFlags.Count -gt 0 -or $positionals.Count -gt 1) {
                throw 'Usage: bitwarden setup [always|never|remember-until-lock] [--skip-service] [--skip-git] [--no-start]'
            }
            $authorization = if ($positionals.Count -eq 1) { [string]$positionals[0] } else { $null }
            Invoke-CapsulenvBitwardenSshAgentSetup `
                -Authorization $authorization `
                -SkipWindowsService:($remaining -contains '--skip-service') `
                -SkipGit:($remaining -contains '--skip-git') `
                -NoStart:($remaining -contains '--no-start') |
                Format-List
        }
        'status' {
            if ($remaining.Count -gt 0) {
                throw 'Usage: bitwarden status'
            }
            Get-CapsulenvBitwardenSshAgentStatus | Format-List
        }
        'restore' {
            $unknown = @($remaining | Where-Object { $_ -ne '--no-start' })
            if ($unknown.Count -gt 0) {
                throw 'Usage: bitwarden restore [--no-start]'
            }
            Restore-CapsulenvBitwardenSshAgentSetup `
                -NoStart:($remaining -contains '--no-start') |
                Format-List
        }
        'start' { Start-CapsulenvBitwarden }
        'agent-test' { Test-CapsulenvBitwardenSshAgent | Format-List }
        'disable-windows-agent' { Disable-CapsulenvWindowsSshAgent }
        'restore-windows-agent' { Restore-CapsulenvWindowsSshAgent }
        'configure-git' { Set-CapsulenvGitOpenSsh }
        'restore-git' { Restore-CapsulenvGitOpenSsh }
        default { throw "Unknown Bitwarden action: $($Arguments[0])" }
    }
}

function Invoke-Capsulenv {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments = @()
    )

    [void](Initialize-CapsulenvContext -Root $env:CAPSULENV_ROOT)
    $command = if ($Arguments.Count -gt 0) { $Arguments[0].ToLowerInvariant() } else { 'shell' }
    $remaining = if ($Arguments.Count -gt 1) { @($Arguments[1..($Arguments.Count - 1)]) } else { @() }

    switch ($command) {
        'shell' { Invoke-CapsulenvChildShell }
        'run' {
            if ($remaining.Count -lt 1) {
                throw 'Usage: run <command> [arguments...]'
            }
            $externalArguments = if ($remaining.Count -gt 1) { @($remaining[1..($remaining.Count - 1)]) } else { @() }
            Invoke-CapsulenvExternalCommand -Command $remaining[0] -Arguments $externalArguments
        }
        'init' {
            $allowed = @('--skip-hooks', '--skip-persist-repairs')
            $unknown = @($remaining | Where-Object { $_ -notin $allowed })
            if ($unknown.Count -gt 0) {
                throw 'Usage: init [--skip-hooks] [--skip-persist-repairs]'
            }
            Initialize-Capsulenv `
                -SkipHooks:($remaining -contains '--skip-hooks') `
                -SkipPersistRepairs:($remaining -contains '--skip-persist-repairs')
        }
        'rehydrate' {
            $allowed = @('--skip-hooks', '--skip-persist-repairs')
            $unknown = @($remaining | Where-Object { $_ -notin $allowed })
            if ($unknown.Count -gt 0) {
                throw 'Usage: rehydrate [--skip-hooks] [--skip-persist-repairs]'
            }
            Invoke-CapsulenvScoopRehydrate `
                -SkipHooks:($remaining -contains '--skip-hooks') `
                -SkipPersistRepairs:($remaining -contains '--skip-persist-repairs')
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
            if ($remaining.Count -lt 2) {
                throw 'Usage: hooks <pre_install|post_install> <app> [app...]'
            }
            $apps = @($remaining[1..($remaining.Count - 1)])
            Invoke-CapsulenvScoopHookReplay -Hook $remaining[0] -Apps $apps
        }
        'reset' {
            [void](Set-CapsulenvSessionEnvironment)
            $apps = if ($remaining.Count -gt 0) { $remaining } else { @('*') }
            [void](Reset-CapsulenvScoop -Apps $apps)
        }
        'reset-shims' {
            [void](Set-CapsulenvSessionEnvironment)
            [void](Reset-CapsulenvScoop)
        }
        'enable-user' { Enable-CapsulenvUserEnvironment }
        'restore-user' { Restore-CapsulenvUserEnvironment }
        'doctor' { Invoke-CapsulenvDoctor | Out-Null }
        'firefox' { Start-CapsulenvBrowser -Browser Firefox -Arguments $remaining }
        'zen' { Start-CapsulenvBrowser -Browser Zen -Arguments $remaining }
        'bitwarden' { Invoke-CapsulenvBitwardenCommand -Arguments $remaining }
        'help' { Show-CapsulenvHelp }
        '--help' { Show-CapsulenvHelp }
        '-h' { Show-CapsulenvHelp }
        default { throw "Unknown capsulenv command: $command. Run capsulenv.cmd help." }
    }
}

Set-Alias -Name cenv -Value Invoke-Capsulenv
##MOD_EXEC## Export-ModuleMember -Function Invoke-Capsulenv
##MOD_EXEC## Export-ModuleMember -Alias cenv
