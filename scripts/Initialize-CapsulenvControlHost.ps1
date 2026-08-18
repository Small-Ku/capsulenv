# Keep this bootstrap limited to PowerShell language/.NET and commands exported by
# Microsoft.PowerShell.Core.  It runs before the control host can safely assume
# Microsoft.PowerShell.Utility (or any other autoloaded built-in module) is
# discoverable through the inherited PSModulePath.

if ($PSVersionTable.PSVersion -lt [version]'5.1') {
    throw "Capsulenv requires PowerShell 5.1 or newer for its control-plane scripts; found $($PSVersionTable.PSVersion)."
}

$builtInModuleRoot = [System.IO.Path]::Combine($PSHOME, 'Modules')
if (-not [System.IO.Directory]::Exists($builtInModuleRoot)) {
    throw "PowerShell built-in module directory is missing: $builtInModuleRoot"
}

$pathSeparator = [System.IO.Path]::PathSeparator
if ([string]::IsNullOrEmpty($env:PSModulePath)) {
    $env:PSModulePath = $builtInModuleRoot
} else {
    $modulePathEntries = @($env:PSModulePath -split [regex]::Escape([string]$pathSeparator))
    $alreadyFirst = (
        $modulePathEntries.Count -gt 0 -and
        [System.StringComparer]::OrdinalIgnoreCase.Equals(
            [string]$modulePathEntries[0].TrimEnd([char[]]'\/'),
            [string]$builtInModuleRoot.TrimEnd([char[]]'\/')
        )
    )
    if (-not $alreadyFirst) {
        $env:PSModulePath = $builtInModuleRoot + [string]$pathSeparator + $env:PSModulePath
    }
}

$utilityManifest = [System.IO.Path]::Combine(
    $builtInModuleRoot,
    'Microsoft.PowerShell.Utility',
    'Microsoft.PowerShell.Utility.psd1'
)
if (-not [System.IO.File]::Exists($utilityManifest)) {
    throw "PowerShell built-in Utility module manifest is missing: $utilityManifest"
}

# Import by absolute path.  Name-based autoload is deliberately insufficient:
# a Capsulenv/private module path inherited from an interactive shell must not
# be able to shadow the operating system's control-plane Utility module.
Import-Module -Name $utilityManifest -Force -ErrorAction Stop
$importPowerShellDataFile = Get-Command -Name Import-PowerShellDataFile -CommandType Cmdlet -ErrorAction SilentlyContinue
if ($null -eq $importPowerShellDataFile) {
    throw "PowerShell built-in Utility module did not provide Import-PowerShellDataFile: $utilityManifest"
}
