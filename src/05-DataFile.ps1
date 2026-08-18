function Import-CapsulenvPowerShellDataFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('Path')]
        [string]$LiteralPath
    )

    $fullPath = [System.IO.Path]::GetFullPath($LiteralPath)
    if (-not [System.IO.File]::Exists($fullPath)) {
        throw "PowerShell data file does not exist: $fullPath"
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $fullPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $details = foreach ($parseError in $parseErrors) {
            '{0}:{1}: {2}' -f (
                $parseError.Extent.StartLineNumber,
                $parseError.Extent.StartColumnNumber,
                $parseError.Message
            )
        }
        throw "PowerShell data file parse failed: $fullPath`n$($details -join [Environment]::NewLine)"
    }

    $statements = @($ast.EndBlock.Statements)
    if ($statements.Count -ne 1 -or $statements[0] -isnot [System.Management.Automation.Language.PipelineAst]) {
        throw "PowerShell data file must contain exactly one hashtable expression: $fullPath"
    }

    $pipelineElements = @($statements[0].PipelineElements)
    if (
        $pipelineElements.Count -ne 1 -or
        $pipelineElements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst] -or
        $pipelineElements[0].Expression -isnot [System.Management.Automation.Language.HashtableAst]
    ) {
        throw "PowerShell data file must contain exactly one hashtable expression: $fullPath"
    }

    try {
        $value = $pipelineElements[0].Expression.SafeGetValue()
    } catch {
        throw "PowerShell data file contains an unsafe or dynamic expression: $fullPath. $($_.Exception.Message)"
    }

    if ($value -isnot [hashtable]) {
        throw "PowerShell data file did not evaluate to a hashtable: $fullPath"
    }
    return $value
}
