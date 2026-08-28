function Import-CapsulenvTextResourceCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Capsulenv text resource catalog not found: $Path" }
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    try { $content = [System.IO.File]::ReadAllText($Path, $utf8) } catch { throw "Capsulenv text resource catalog UTF-8 read failed: $Path" }
    try { $raw = $content | ConvertFrom-Json } catch { throw "Capsulenv text resource catalog JSON is invalid: $Path" }
    if ($null -eq $raw -or [string]::IsNullOrWhiteSpace([string]$raw.language) -or $null -eq $raw.strings) { throw "Capsulenv text resource catalog is invalid: $Path" }
    $strings = @{}
    foreach ($property in @($raw.strings.PSObject.Properties)) {
        $key = [string]$property.Name
        if ([string]::IsNullOrWhiteSpace($key)) { throw "Capsulenv text resource catalog contains an empty key: $Path" }
        if ($strings.ContainsKey($key)) { throw "Capsulenv text resource catalog contains a duplicate key: $key" }
        $strings[$key] = [string]$property.Value
    }
    return [pscustomobject][ordered]@{ Language=[string]$raw.language; Path=[System.IO.Path]::GetFullPath($Path); Strings=$strings }
}
function Get-CapsulenvTextResourceValue {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Catalog,[Parameter(Mandatory = $true)][string]$Key)
    if (-not $Catalog.Strings.ContainsKey($Key)) { throw "Capsulenv text resource key not found: $Key" }
    return [string]$Catalog.Strings[$Key]
}
function ConvertTo-CapsulenvPowerShellStringLiteral {
    [CmdletBinding()]
    param([AllowEmptyString()][Parameter(Mandatory = $true)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}
function Test-CapsulenvTextResourceTokenReferences {
    [CmdletBinding()]
    param([AllowEmptyString()][Parameter(Mandatory = $true)][string]$Content,[Parameter(Mandatory = $true)]$Catalog,[string]$SourceName='<memory>')
    foreach ($match in [regex]::Matches($Content, '\[\[CapsulenvText:([A-Za-z0-9_.-]+)\]\]')) {
        $key=[string]$match.Groups[1].Value
        if(-not $Catalog.Strings.ContainsKey($key)){throw "Unknown Capsulenv text resource key '$key' in $SourceName"}
    }
}
function Expand-CapsulenvTextResourceTokens {
    [CmdletBinding()]
    param([AllowEmptyString()][Parameter(Mandatory = $true)][string]$Content,[Parameter(Mandatory = $true)]$Catalog,[string]$SourceName='<memory>')
    Test-CapsulenvTextResourceTokenReferences -Content $Content -Catalog $Catalog -SourceName $SourceName
    $pattern = '(?<quote>[''\"])\[\[CapsulenvText:(?<key>[A-Za-z0-9_.-]+)\]\]\k<quote>'
    $evaluator=[System.Text.RegularExpressions.MatchEvaluator]{param($match) ConvertTo-CapsulenvPowerShellStringLiteral -Value (Get-CapsulenvTextResourceValue -Catalog $Catalog -Key ([string]$match.Groups['key'].Value))}
    $expanded=[regex]::Replace($Content,$pattern,$evaluator)
    if($expanded -match '\[\[CapsulenvText:[A-Za-z0-9_.-]+\]\]'){throw "Capsulenv text resource tokens must occupy a complete quoted string literal: $SourceName"}
    return $expanded
}
