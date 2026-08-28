function New-CapsulenvProcessPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Executable,
        [string[]]$Arguments = @(),
        [AllowNull()][string]$WorkingDirectory = $null,
        [AllowNull()][System.Collections.IDictionary]$Environment = $null,
        [string[]]$PathEntries = @(),
        [ValidateSet('Passthrough','Detached')][string]$ExecutionMode = 'Passthrough',
        [AllowNull()][System.Collections.IDictionary]$Metadata = $null
    )
    if ([string]::IsNullOrWhiteSpace($Executable)) {
        throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Process.ExecutableMissing' -Message '[[CapsulenvText:Process.ExecutableRequired]]' -Category ([System.Management.Automation.ErrorCategory]::InvalidArgument) -TargetObject $Executable -Hints @('[[CapsulenvText:Process.ExecutableRequired.Hint]]'))
    }
    $environmentCopy=[ordered]@{}; if($null -ne $Environment){foreach($key in $Environment.Keys){$environmentCopy[[string]$key]=[string]$Environment[$key]}}
    $metadataCopy=[ordered]@{}; if($null -ne $Metadata){foreach($key in $Metadata.Keys){$metadataCopy[[string]$key]=$Metadata[$key]}}
    return [pscustomobject][ordered]@{
        PSTypeName='Capsulenv.ProcessPlan'; Executable=$Executable; Arguments=[string[]]@($Arguments)
        WorkingDirectory=if([string]::IsNullOrWhiteSpace($WorkingDirectory)){$null}else{[System.IO.Path]::GetFullPath($WorkingDirectory)}
        Environment=$environmentCopy; PathEntries=[string[]]@($PathEntries | Where-Object {-not [string]::IsNullOrWhiteSpace([string]$_)})
        ExecutionMode=$ExecutionMode; Metadata=$metadataCopy
    }
}

function Invoke-CapsulenvProcessPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan)
    $executable=[string]$Plan.Executable
    if([string]::IsNullOrWhiteSpace($executable)){throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Process.ExecutableMissing' -Message '[[CapsulenvText:Process.PlanExecutableMissing]]' -Category ([System.Management.Automation.ErrorCategory]::InvalidData) -TargetObject $Plan)}
    if([System.IO.Path]::IsPathRooted($executable) -and -not(Test-Path -LiteralPath $executable -PathType Leaf)){throw (New-CapsulenvDiagnosticErrorRecord -Id 'Capsulenv.Process.ExecutableMissing' -Message ('[[CapsulenvText:Process.ExecutableNotFound]]' -f $executable) -Category ([System.Management.Automation.ErrorCategory]::ObjectNotFound) -TargetObject $executable -Context ([ordered]@{Executable=$executable}))}
    $saved=@{}; foreach($name in $Plan.Environment.Keys){$exists=Test-Path -LiteralPath ('Env:'+ [string]$name); $saved[[string]$name]=[pscustomobject]@{Exists=$exists;Value=if($exists){[Environment]::GetEnvironmentVariable([string]$name,'Process')}else{$null}}}
    $savedPathExists=Test-Path -LiteralPath Env:PATH; $savedPath=if($savedPathExists){[Environment]::GetEnvironmentVariable('PATH','Process')}else{$null}; $pushed=$false
    try {
        foreach($name in $Plan.Environment.Keys){[Environment]::SetEnvironmentVariable([string]$name,[string]$Plan.Environment[$name],'Process')}
        if(@($Plan.PathEntries).Count -gt 0){$env:PATH=Merge-CapsulenvPath -ExistingPath $env:PATH -Prepend @($Plan.PathEntries)}
        if(-not [string]::IsNullOrWhiteSpace([string]$Plan.WorkingDirectory)){Push-Location -LiteralPath ([string]$Plan.WorkingDirectory);$pushed=$true}
        if([string]$Plan.ExecutionMode -eq 'Detached'){
            $arguments=@($Plan.Arguments); $params=@{FilePath=$executable;ArgumentList=$arguments;PassThru=$true}
            if(-not [string]::IsNullOrWhiteSpace([string]$Plan.WorkingDirectory)){$params.WorkingDirectory=[string]$Plan.WorkingDirectory}
            return Start-Process @params
        }
        Clear-CapsulenvLastExitCode
        & $executable @($Plan.Arguments)
        $succeeded=$?
        $global:LASTEXITCODE=Get-CapsulenvLastExitCode -Succeeded $succeeded
    } catch {
        throw (ConvertTo-CapsulenvDiagnosticErrorRecord -ErrorRecord $_ -Id 'Capsulenv.Process.InvocationFailed' -Message ('[[CapsulenvText:Process.InvocationFailed]]' -f $executable) -TargetObject $executable -Context ([ordered]@{Executable=$executable;ExecutionMode=[string]$Plan.ExecutionMode;WorkingDirectory=[string]$Plan.WorkingDirectory}))
    } finally {
        if($pushed){Pop-Location}
        if($savedPathExists){[Environment]::SetEnvironmentVariable('PATH',[string]$savedPath,'Process')}else{Remove-Item -LiteralPath Env:PATH -ErrorAction SilentlyContinue}
        foreach($name in $saved.Keys){$entry=$saved[$name]; if($entry.Exists){[Environment]::SetEnvironmentVariable([string]$name,[string]$entry.Value,'Process')}else{Remove-Item -LiteralPath ('Env:'+ [string]$name) -ErrorAction SilentlyContinue}}
    }
}
