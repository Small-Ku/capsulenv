function Show-CapsulenvHelp {
    [CmdletBinding()]
    param()

    @'
capsulenv commands

  capsulenv.cmd shell
      Open a child PowerShell with the portable environment active.

  capsulenv.cmd run <command> [arguments...]
      Run one command inside the portable environment.

  capsulenv.cmd init [none|copy|move]
      Create state/data directories and register enabled browser profiles.
      Browser migration is disabled unless copy or move is explicitly supplied.

  capsulenv.cmd enable-user
  capsulenv.cmd restore-user
      Persist or restore User environment variables using an exact backup.

  capsulenv.cmd doctor
  capsulenv.cmd reset-shims

  capsulenv.cmd firefox [arguments...]
  capsulenv.cmd zen [arguments...]
      Start the browser with its capsulenv profile using --profile.

  capsulenv.cmd browser configure <firefox|zen> [none|copy|move]
  capsulenv.cmd browser restore <firefox|zen>

  capsulenv.cmd bitwarden start
  capsulenv.cmd bitwarden agent-test
  capsulenv.cmd bitwarden disable-windows-agent
  capsulenv.cmd bitwarden restore-windows-agent
  capsulenv.cmd bitwarden configure-git
  capsulenv.cmd bitwarden restore-git
'@ | Write-Host
}

function Invoke-CapsulenvBrowserCommand {
    param([string[]]$Arguments)

    if ($Arguments.Count -lt 2) {
        throw 'Usage: browser <configure|restore|start> <firefox|zen> [none|copy|move]'
    }
    $action = $Arguments[0].ToLowerInvariant()
    $browser = switch ($Arguments[1].ToLowerInvariant()) {
        'firefox' { 'Firefox' }
        'zen' { 'Zen' }
        default { throw "Unknown browser: $($Arguments[1])" }
    }

    switch ($action) {
        'configure' {
            $migration = if ($Arguments.Count -ge 3) { $Arguments[2] } else { 'None' }
            $definition = Get-CapsulenvBrowserDefinition -Browser $browser
            Register-CapsulenvBrowserProfile `
                -Browser $browser `
                -Migrate $migration `
                -InstallDefault:$definition.RegisterInstallDefaults
        }
        'restore' {
            Restore-CapsulenvBrowserProfile -Browser $browser
        }
        'start' {
            $remaining = if ($Arguments.Count -gt 2) { @($Arguments[2..($Arguments.Count - 1)]) } else { @() }
            Start-CapsulenvBrowser -Browser $browser -Arguments $remaining
        }
        default { throw "Unknown browser action: $action" }
    }
}

function Invoke-CapsulenvBitwardenCommand {
    param([string[]]$Arguments)

    if ($Arguments.Count -lt 1) {
        throw 'Usage: bitwarden <start|agent-test|disable-windows-agent|restore-windows-agent|configure-git|restore-git>'
    }
    switch ($Arguments[0].ToLowerInvariant()) {
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
            if ($remaining.Count -lt 1) { throw 'Usage: run <command> [arguments...]' }
            $externalArguments = if ($remaining.Count -gt 1) { @($remaining[1..($remaining.Count - 1)]) } else { @() }
            Invoke-CapsulenvExternalCommand -Command $remaining[0] -Arguments $externalArguments
        }
        'init' {
            $migration = if ($remaining.Count -gt 0) { $remaining[0] } else { 'None' }
            Initialize-Capsulenv -MigrateBrowserProfiles $migration
        }
        'enable-user' { Enable-CapsulenvUserEnvironment }
        'restore-user' { Restore-CapsulenvUserEnvironment }
        'doctor' { Invoke-CapsulenvDoctor | Out-Null }
        'reset-shims' { [void](Set-CapsulenvSessionEnvironment); [void](Reset-CapsulenvScoopShims) }
        'firefox' { Start-CapsulenvBrowser -Browser Firefox -Arguments $remaining }
        'zen' { Start-CapsulenvBrowser -Browser Zen -Arguments $remaining }
        'browser' { Invoke-CapsulenvBrowserCommand -Arguments $remaining }
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
