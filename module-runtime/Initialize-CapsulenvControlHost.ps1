# Keep this bootstrap limited to PowerShell language/.NET only. It runs before
# the control host can safely assume that any autoloaded module is discoverable
# through the inherited PSModulePath.

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
