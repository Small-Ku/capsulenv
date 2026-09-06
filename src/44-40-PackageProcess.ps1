function Get-CapsulenvPackageEnvironmentPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Installed)

    if ([string]$Installed.Scope -ne 'Capsule') {
        throw (New-CapsulenvDiagnosticErrorRecord `
            -Id 'Capsulenv.Package.PortableSafeRequired' `
            -Message "Package process environment is reserved for Capsulenv-owned PortableSafe packages: $($Installed.Selector)" `
            -Category ([System.Management.Automation.ErrorCategory]::PermissionDenied) `
            -TargetObject $Installed `
            -Context ([ordered]@{ Selector = [string]$Installed.Selector; Scope = [string]$Installed.Scope }) `
            -Remediation @('Review the package plan and use explicit TrustedExecution only when you accept upstream lifecycle semantics.'))
    }
    $pathProperty = Get-CapsulenvInstalledManifestPropertyRecord -App $Installed -Name 'env_add_path'
    $setProperty = Get-CapsulenvInstalledManifestPropertyRecord -App $Installed -Name 'env_set'
    $pathEntries = New-Object System.Collections.Generic.List[string]
    if ($null -ne $pathProperty.Value) {
        $values = if ($pathProperty.Value -is [string]) { @([string]$pathProperty.Value) } else { @($pathProperty.Value) }
        foreach ($value in $values) {
            $raw = [string]$value
            if ($raw.Contains('$dir') -or $raw.Contains('$original_dir') -or $raw.Contains('$persist_dir')) {
                $expanded = Expand-CapsulenvScoopShortcutValue -Value $raw -App $Installed
                $candidate = [System.IO.Path]::GetFullPath($expanded)
                $ownedRoots = @(
                    [System.IO.Path]::GetFullPath([string]$Installed.Current).TrimEnd([char[]]'\/'),
                    [System.IO.Path]::GetFullPath([string]$Installed.Persist).TrimEnd([char[]]'\/')
                )
                $owned = $false
                foreach ($ownedRoot in $ownedRoots) {
                    if (
                        [System.StringComparer]::OrdinalIgnoreCase.Equals($candidate.TrimEnd([char[]]'\/'), $ownedRoot) -or
                        $candidate.StartsWith($ownedRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
                    ) {
                        $owned = $true
                        break
                    }
                }
                if (-not $owned) {
                    throw "env_add_path escapes the package-owned current/persist roots: $raw"
                }
                $pathEntries.Add($candidate)
            } else {
                $pathEntries.Add((Resolve-CapsulenvScoopAppRelativePath -Root $Installed.Current -RelativePath $raw))
            }
        }
    }
    $variables = [ordered]@{}
    if ($null -ne $setProperty.Value) {
        foreach ($property in @($setProperty.Value.PSObject.Properties)) {
            $variables[[string]$property.Name] = Expand-CapsulenvScoopShortcutValue -Value ([string]$property.Value) -App $Installed
        }
    }
    return [pscustomobject]@{
        PathEntries = $pathEntries.ToArray()
        Variables = $variables
    }
}

function Set-CapsulenvPackageProcessEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Installed)

    $environment = Get-CapsulenvPackageEnvironmentPlan -Installed $Installed
    foreach ($name in $environment.Variables.Keys) {
        [Environment]::SetEnvironmentVariable([string]$name, [string]$environment.Variables[$name], 'Process')
    }
    if ($environment.PathEntries.Count -gt 0) {
        $env:PATH = Merge-CapsulenvPath -ExistingPath $env:PATH -Prepend @($environment.PathEntries)
    }
    return $environment
}

function Get-CapsulenvInstalledAppProcessPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [Parameter(Mandatory = $true)][string]$BinName,
        [string[]]$Arguments = @(),
        [AllowNull()][string]$WorkingDirectory = $null,
        [ValidateSet('Passthrough','Detached')][string]$ExecutionMode = 'Passthrough'
    )

    $installed = Get-CapsulenvInstalledApp -Selector $App
    $executable = Resolve-CapsulenvScoopAppExecutable -App $installed.Selector -BinName $BinName
    $environment = [pscustomobject]@{ PathEntries=@(); Variables=[ordered]@{} }
    if ([string]$installed.Scope -eq 'Capsule') {
        $environment = Get-CapsulenvPackageEnvironmentPlan -Installed $installed
    }
    $plan = New-CapsulenvProcessPlan `
        -Executable $executable `
        -Arguments @($Arguments) `
        -WorkingDirectory $WorkingDirectory `
        -Environment $environment.Variables `
        -PathEntries @($environment.PathEntries) `
        -ExecutionMode $ExecutionMode `
        -Metadata ([ordered]@{
            App = [string]$installed.Selector
            BinName = $BinName
            Provider = [string]$installed.Provider
            ProviderScope = $installed.ProviderScope
            Ownership = [string]$installed.Ownership
        })
    $plan | Add-Member -NotePropertyName App -NotePropertyValue ([string]$installed.Selector)
    $plan | Add-Member -NotePropertyName BinName -NotePropertyValue $BinName
    $plan | Add-Member -NotePropertyName FilePath -NotePropertyValue $plan.Executable
    $plan | Add-Member -NotePropertyName Variables -NotePropertyValue $plan.Environment
    return $plan
}

function Invoke-CapsulenvInstalledAppExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$App,
        [Parameter(Mandatory = $true)][string]$BinName,
        [string[]]$Arguments = @(),
        [AllowNull()][string]$WorkingDirectory = $null,
        [ValidateSet('Passthrough','Detached')][string]$ExecutionMode = 'Passthrough'
    )

    [void](Set-CapsulenvSessionEnvironment)
    $plan = Get-CapsulenvInstalledAppProcessPlan `
        -App $App `
        -BinName $BinName `
        -Arguments $Arguments `
        -WorkingDirectory $WorkingDirectory `
        -ExecutionMode $ExecutionMode
    return Invoke-CapsulenvProcessPlan -Plan $plan
}

##MOD_EXEC## Export-ModuleMember -Function Get-CapsulenvInstalledAppProcessPlan, Invoke-CapsulenvInstalledAppExecutable
