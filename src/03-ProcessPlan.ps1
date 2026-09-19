function ConvertTo-CapsulenvNativeCommandLineArgument {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Argument)

    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashCount = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $backslashCount++
            continue
        }
        if ($character -eq '"') {
            if ($backslashCount -gt 0) {
                [void]$builder.Append(('\' * ($backslashCount * 2)))
            }
            [void]$builder.Append('\"')
            $backslashCount = 0
            continue
        }
        if ($backslashCount -gt 0) {
            [void]$builder.Append(('\' * $backslashCount))
            $backslashCount = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashCount -gt 0) {
        [void]$builder.Append(('\' * ($backslashCount * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function New-CapsulenvProcessStartInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [AllowNull()]$RawArgumentString = $null,
        [AllowNull()][string]$WorkingDirectory = $null,
        [AllowNull()][System.Collections.IDictionary]$Environment = $null,
        [string[]]$PathEntries = @(),
        [switch]$Capture
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Executable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $false
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = [System.IO.Path]::GetFullPath($WorkingDirectory)
    }

    if ($null -ne $RawArgumentString) {
        $startInfo.Arguments = [string]$RawArgumentString
    } else {
        $argumentListProperty = $startInfo.PSObject.Properties['ArgumentList']
        if ($null -ne $argumentListProperty) {
            foreach ($argument in @($Arguments)) {
                [void]$startInfo.ArgumentList.Add([string]$argument)
            }
        } else {
            $quotedArguments = foreach ($argument in @($Arguments)) {
                ConvertTo-CapsulenvNativeCommandLineArgument -Argument ([string]$argument)
            }
            $startInfo.Arguments = $quotedArguments -join ' '
        }
    }

    if ($null -ne $Environment) {
        foreach ($keyObject in $Environment.Keys) {
            $name = [string]$keyObject
            $value = $Environment[$keyObject]
            if ($null -eq $value) {
                [void]$startInfo.EnvironmentVariables.Remove($name)
            } else {
                $startInfo.EnvironmentVariables[$name] = [string]$value
            }
        }
    }
    if (@($PathEntries).Count -gt 0) {
        $basePath = if ($startInfo.EnvironmentVariables.ContainsKey('PATH')) {
            [string]$startInfo.EnvironmentVariables['PATH']
        } else {
            [Environment]::GetEnvironmentVariable('PATH', 'Process')
        }
        $startInfo.EnvironmentVariables['PATH'] = Merge-CapsulenvPath -ExistingPath $basePath -Prepend @($PathEntries)
    }

    if ($Capture) {
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
    }
    return $startInfo
}

function New-CapsulenvProcessPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Executable,
        [string[]]$Arguments = @(),
        [AllowNull()]$RawArgumentString = $null,
        [AllowNull()][string]$WorkingDirectory = $null,
        [AllowNull()][System.Collections.IDictionary]$Environment = $null,
        [string[]]$PathEntries = @(),
        [ValidateSet('Passthrough','Detached')][string]$ExecutionMode = 'Passthrough',
        [AllowNull()][System.Collections.IDictionary]$Metadata = $null
    )
    if ([string]::IsNullOrWhiteSpace($Executable)) {
        throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Process.ExecutableMissing' -Message '[[CapsulenvText:Process.ExecutableRequired]]' -Category ([System.Management.Automation.ErrorCategory]::InvalidArgument) -TargetObject $Executable -Hints @('[[CapsulenvText:Process.ExecutableRequired.Hint]]'))
    }
    $environmentCopy = [ordered]@{}
    if ($null -ne $Environment) {
        foreach ($key in $Environment.Keys) {
            $environmentCopy[[string]$key] = [string]$Environment[$key]
        }
    }
    $metadataCopy = [ordered]@{}
    if ($null -ne $Metadata) {
        foreach ($key in $Metadata.Keys) {
            $metadataCopy[[string]$key] = $Metadata[$key]
        }
    }
    return [pscustomobject][ordered]@{
        PSTypeName = 'Capsulenv.ProcessPlan'
        Executable = $Executable
        Arguments = [string[]]@($Arguments)
        RawArgumentString = $RawArgumentString
        WorkingDirectory = if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { $null } else { [System.IO.Path]::GetFullPath($WorkingDirectory) }
        Environment = $environmentCopy
        PathEntries = [string[]]@($PathEntries | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        ExecutionMode = $ExecutionMode
        Metadata = $metadataCopy
    }
}

function Invoke-CapsulenvDetachedProcessPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan)

    $startInfo = New-CapsulenvProcessStartInfo `
        -Executable ([string]$Plan.Executable) `
        -Arguments @($Plan.Arguments) `
        -RawArgumentString $Plan.RawArgumentString `
        -WorkingDirectory ([string]$Plan.WorkingDirectory) `
        -Environment $Plan.Environment `
        -PathEntries @($Plan.PathEntries)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        $process.Dispose()
        throw "Process could not be started: $($Plan.Executable)"
    }
    return $process
}

function Invoke-CapsulenvProcessPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan)
    $executable = [string]$Plan.Executable
    if ([string]::IsNullOrWhiteSpace($executable)) {
        throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Process.ExecutableMissing' -Message '[[CapsulenvText:Process.PlanExecutableMissing]]' -Category ([System.Management.Automation.ErrorCategory]::InvalidData) -TargetObject $Plan)
    }
    if ([System.IO.Path]::IsPathRooted($executable) -and -not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Process.ExecutableMissing' -Message ('[[CapsulenvText:Process.ExecutableNotFound]]' -f $executable) -Category ([System.Management.Automation.ErrorCategory]::ObjectNotFound) -TargetObject $executable -Context ([ordered]@{ Executable = $executable }))
    }

    if ([string]$Plan.ExecutionMode -eq 'Detached') {
        try {
            return Invoke-CapsulenvDetachedProcessPlan -Plan $Plan
        } catch {
            throw (ConvertTo-CapsulenvDiagnosticErrorRecord -ErrorRecord $_ -Id 'Capsulenv.Process.InvocationFailed' -Message ('[[CapsulenvText:Process.InvocationFailed]]' -f $executable) -TargetObject $executable -Context ([ordered]@{ Executable = $executable; ExecutionMode = [string]$Plan.ExecutionMode; WorkingDirectory = [string]$Plan.WorkingDirectory }))
        }
    }

    # Passthrough execution intentionally keeps the host PowerShell pipeline and
    # console attached. Its short-lived process overlay is restored immediately;
    # detached launches must use child-local ProcessStartInfo state above.
    $saved = @{}
    foreach ($name in $Plan.Environment.Keys) {
        $exists = Test-Path -LiteralPath ('Env:' + [string]$name)
        $saved[[string]$name] = [pscustomobject]@{
            Exists = $exists
            Value = if ($exists) { [Environment]::GetEnvironmentVariable([string]$name, 'Process') } else { $null }
        }
    }
    $savedPathExists = Test-Path -LiteralPath Env:PATH
    $savedPath = if ($savedPathExists) { [Environment]::GetEnvironmentVariable('PATH', 'Process') } else { $null }
    $pushed = $false
    try {
        foreach ($name in $Plan.Environment.Keys) {
            [Environment]::SetEnvironmentVariable([string]$name, [string]$Plan.Environment[$name], 'Process')
        }
        if (@($Plan.PathEntries).Count -gt 0) {
            $env:PATH = Merge-CapsulenvPath -ExistingPath $env:PATH -Prepend @($Plan.PathEntries)
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Plan.WorkingDirectory)) {
            Push-Location -LiteralPath ([string]$Plan.WorkingDirectory)
            $pushed = $true
        }
        Clear-CapsulenvLastExitCode
        & $executable @($Plan.Arguments)
        $succeeded = $?
        $global:LASTEXITCODE = Get-CapsulenvLastExitCode -Succeeded $succeeded
    } catch {
        throw (ConvertTo-CapsulenvDiagnosticErrorRecord -ErrorRecord $_ -Id 'Capsulenv.Process.InvocationFailed' -Message ('[[CapsulenvText:Process.InvocationFailed]]' -f $executable) -TargetObject $executable -Context ([ordered]@{ Executable = $executable; ExecutionMode = [string]$Plan.ExecutionMode; WorkingDirectory = [string]$Plan.WorkingDirectory }))
    } finally {
        if ($pushed) {
            Pop-Location
        }
        if ($savedPathExists) {
            [Environment]::SetEnvironmentVariable('PATH', [string]$savedPath, 'Process')
        } else {
            Remove-Item -LiteralPath Env:PATH -ErrorAction SilentlyContinue
        }
        foreach ($name in $saved.Keys) {
            $entry = $saved[$name]
            if ($entry.Exists) {
                [Environment]::SetEnvironmentVariable([string]$name, [string]$entry.Value, 'Process')
            } else {
                Remove-Item -LiteralPath ('Env:' + [string]$name) -ErrorAction SilentlyContinue
            }
        }
    }
}

function Invoke-CapsulenvOwnedProcessPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [string]$Role = 'child-shell',
        [string]$Provenance = 'capsulenv/child-shell'
    )

    $executable = [string]$Plan.Executable
    if ([string]::IsNullOrWhiteSpace($executable)) {
        throw 'Owned process launch requires an executable.'
    }
    if ([System.IO.Path]::IsPathRooted($executable) -and -not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Owned process executable does not exist: $executable"
    }

    $saved = @{}
    foreach ($name in $Plan.Environment.Keys) {
        $exists = Test-Path -LiteralPath ('Env:' + [string]$name)
        $saved[[string]$name] = [pscustomobject]@{ Exists = $exists; Value = if ($exists) { [Environment]::GetEnvironmentVariable([string]$name, 'Process') } else { $null } }
    }
    $savedPathExists = Test-Path -LiteralPath Env:PATH
    $savedPath = if ($savedPathExists) { [Environment]::GetEnvironmentVariable('PATH', 'Process') } else { $null }
    $pushed = $false
    $process = $null
    $record = $null
    $startIdentity = $null
    try {
        foreach ($name in $Plan.Environment.Keys) {
            [Environment]::SetEnvironmentVariable([string]$name, [string]$Plan.Environment[$name], 'Process')
        }
        if (@($Plan.PathEntries).Count -gt 0) {
            $env:PATH = Merge-CapsulenvPath -ExistingPath $env:PATH -Prepend @($Plan.PathEntries)
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Plan.WorkingDirectory)) {
            Push-Location -LiteralPath ([string]$Plan.WorkingDirectory)
            $pushed = $true
        }

        $startParameters = @{
            FilePath = $executable
            ArgumentList = @($Plan.Arguments)
            PassThru = $true
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Plan.WorkingDirectory)) {
            $startParameters.WorkingDirectory = [string]$Plan.WorkingDirectory
        }
        if (Test-CapsulenvWindows) {
            $startParameters.NoNewWindow = $true
        }
        $process = Start-Process @startParameters
        $startIdentity = Get-CapsulenvProcessStartIdentity -ProcessId ([int]$process.Id)
        $childSession = Initialize-CapsulenvOwnedChildSession -ProcessId ([int]$process.Id) -ProcessStartIdentity $startIdentity -Role $Role -Provenance $Provenance
        $record = @($childSession.ProcessRecords)[0]

        Wait-Process -Id ([int]$process.Id) -ErrorAction SilentlyContinue
        $process.Refresh()
        $exitCode = [int]$process.ExitCode
        [void](Complete-CapsulenvOwnedChildSession -ProcessRecord $record)
        $global:LASTEXITCODE = $exitCode
        return [pscustomobject][ordered]@{
            ProcessId = [int]$process.Id
            ChildSessionId = [string]$childSession.SessionId
            ProcessRecord = $record
            ExitCode = $exitCode
        }
    } catch {
        if ($null -ne $record) {
            try { [void](Stop-CapsulenvOwnedProcessRecord -ProcessRecord $record) } catch {}
            try { [void](Complete-CapsulenvOwnedChildSession -ProcessRecord $record) } catch {}
        } elseif ($null -ne $process -and -not [string]::IsNullOrWhiteSpace([string]$startIdentity)) {
            try {
                $currentIdentity = Get-CapsulenvProcessStartIdentity -ProcessId ([int]$process.Id)
                if ([string]$currentIdentity -eq [string]$startIdentity) {
                    Stop-Process -Id ([int]$process.Id) -Force -ErrorAction SilentlyContinue
                }
            } catch {}
        }
        throw
    } finally {
        if ($pushed) { Pop-Location }
        if ($savedPathExists) { [Environment]::SetEnvironmentVariable('PATH', [string]$savedPath, 'Process') } else { Remove-Item -LiteralPath Env:PATH -ErrorAction SilentlyContinue }
        foreach ($name in $saved.Keys) {
            $entry = $saved[$name]
            if ($entry.Exists) { [Environment]::SetEnvironmentVariable([string]$name, [string]$entry.Value, 'Process') } else { Remove-Item -LiteralPath ('Env:' + [string]$name) -ErrorAction SilentlyContinue }
        }
    }
}
