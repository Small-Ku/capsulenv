function New-CapsulenvCliUsageError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$Usage,
        [string]$Topic = ''
    )

    $remediation = New-Object System.Collections.Generic.List[string]
    $remediation.Add(('Usage: {0}' -f $Usage))
    if (-not [string]::IsNullOrWhiteSpace($Topic)) {
        $remediation.Add(("Run 'capsulenv help {0}' for details." -f $Topic))
    } else {
        $remediation.Add("Run 'capsulenv help' to see available commands.")
    }
    return New-CapsulenvDiagnosticErrorRecord `
        -Id 'Capsulenv.Cli.Usage' `
        -Message $Message `
        -Category ([System.Management.Automation.ErrorCategory]::InvalidArgument) `
        -Remediation $remediation.ToArray()
}

function New-CapsulenvCliUnknownCommandError {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Command)

    $remediation = New-Object System.Collections.Generic.List[string]
    $suggestion = Get-CapsulenvCliCommandSuggestion -Command $Command
    if (-not [string]::IsNullOrWhiteSpace([string]$suggestion)) {
        $remediation.Add(("Did you mean 'capsulenv {0}'?" -f $suggestion))
    }
    $remediation.Add("Run 'capsulenv help' to see available commands.")
    return New-CapsulenvDiagnosticErrorRecord `
        -Id 'Capsulenv.Cli.UnknownCommand' `
        -Message "Unknown capsulenv command '$Command'." `
        -Category ([System.Management.Automation.ErrorCategory]::InvalidArgument) `
        -TargetObject $Command `
        -Remediation $remediation.ToArray()
}
