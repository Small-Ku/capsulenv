function Get-CapsulenvBrowserDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Firefox', 'Zen')]
        [string]$Browser
    )

    $configuration = Get-CapsulenvConfiguration
    $definition = $configuration.Browsers[$Browser]
    if ($null -eq $definition) {
        throw "Browser is not configured: $Browser"
    }
    return $definition
}

function Get-CapsulenvBrowserExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Firefox', 'Zen')]
        [string]$Browser
    )

    $definition = Get-CapsulenvBrowserDefinition -Browser $Browser
    return Find-CapsulenvExecutable `
        -Candidates @($definition.ExecutableCandidates) `
        -CommandNames @($definition.CommandNames)
}

function ConvertTo-CapsulenvProcessArgument {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Argument)

    if (-not $Argument) {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashCount = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ([int]$character -eq 92) {
            $backslashCount++
            continue
        }
        if ($character -eq '"') {
            if ($backslashCount -gt 0) {
                [void]$builder.Append([string]::new([char]92, (($backslashCount * 2) + 1)))
            } else {
                [void]$builder.Append([char]92)
            }
            [void]$builder.Append('"')
            $backslashCount = 0
            continue
        }
        if ($backslashCount -gt 0) {
            [void]$builder.Append([string]::new([char]92, $backslashCount))
            $backslashCount = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashCount -gt 0) {
        [void]$builder.Append([string]::new([char]92, ($backslashCount * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Start-CapsulenvBrowser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Firefox', 'Zen')]
        [string]$Browser,
        [string[]]$Arguments = @()
    )

    [void](Set-CapsulenvSessionEnvironment)
    $definition = Get-CapsulenvBrowserDefinition -Browser $Browser
    if (-not $definition.Enabled) {
        throw "$Browser integration is disabled."
    }

    $executable = Get-CapsulenvBrowserExecutable -Browser $Browser
    if (-not $executable) {
        throw "$Browser executable was not found. Install it with Scoop or configure ExecutableCandidates."
    }

    $launchArguments = @($Arguments | ForEach-Object { ConvertTo-CapsulenvProcessArgument -Argument $_ })
    $startParameters = @{
        FilePath = $executable
        WorkingDirectory = (Split-Path -Parent $executable)
    }
    if ($launchArguments.Count -gt 0) {
        $startParameters['ArgumentList'] = $launchArguments
    }
    [void](Start-Process @startParameters)
}

##MOD_EXEC## Export-ModuleMember -Function Start-CapsulenvBrowser, Get-CapsulenvBrowserExecutable
