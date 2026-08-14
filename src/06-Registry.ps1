function Get-CapsulenvRegistryStringValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('CurrentUser', 'LocalMachine')]
        [string]$Hive,
        [Parameter(Mandatory = $true)][string]$SubKey,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name
    )

    if (-not (Test-CapsulenvWindows)) {
        return $null
    }

    $registryHive = if ($Hive -eq 'CurrentUser') {
        [Microsoft.Win32.RegistryHive]::CurrentUser
    } else {
        [Microsoft.Win32.RegistryHive]::LocalMachine
    }
    $views = @(
        [Microsoft.Win32.RegistryView]::Registry64,
        [Microsoft.Win32.RegistryView]::Registry32,
        [Microsoft.Win32.RegistryView]::Default
    )
    foreach ($view in $views) {
        $base = $null
        $key = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($registryHive, $view)
            $key = $base.OpenSubKey($SubKey, $false)
            if ($null -eq $key) {
                continue
            }
            $value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                return [Environment]::ExpandEnvironmentVariables([string]$value)
            }
        } catch {
            # Registry views are architecture-dependent. Continue to the next view.
        } finally {
            if ($null -ne $key) { $key.Dispose() }
            if ($null -ne $base) { $base.Dispose() }
        }
    }
    return $null
}
