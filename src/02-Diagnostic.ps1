function Test-CapsulenvDiagnosticErrorRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    if ([string]$ErrorRecord.FullyQualifiedErrorId -like 'Capsulenv.*') { return $true }
    if ($null -eq $ErrorRecord.Exception) { return $false }
    return [string]$ErrorRecord.Exception.Data['CapsulenvDiagnosticId'] -like 'Capsulenv.*'
}

function Get-CapsulenvDiagnosticCauseMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $typeName = if ($null -ne $ErrorRecord.Exception) { [string]$ErrorRecord.Exception.GetType().FullName } else { '' }
    $safeErrorId = ''
    if (Test-CapsulenvDiagnosticErrorRecord -ErrorRecord $ErrorRecord) {
        $candidate = [string]$ErrorRecord.FullyQualifiedErrorId
        if ($candidate -notlike 'Capsulenv.*' -and $null -ne $ErrorRecord.Exception) {
            $candidate = [string]$ErrorRecord.Exception.Data['CapsulenvDiagnosticId']
        }
        if ($candidate -like 'Capsulenv.*') { $safeErrorId = $candidate }
    }
    return [pscustomobject][ordered]@{ Type = $typeName; ErrorId = $safeErrorId }
}

function New-CapsulenvDiagnosticErrorRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^Capsulenv\.[A-Za-z0-9]+(?:\.[A-Za-z0-9]+)+$')][string]$Id,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Message,
        [System.Management.Automation.ErrorCategory]$Category = [System.Management.Automation.ErrorCategory]::InvalidOperation,
        [AllowNull()][object]$TargetObject = $null,
        [AllowNull()][System.Collections.IDictionary]$Context = $null,
        [AllowNull()][AllowEmptyCollection()][string[]]$Hints = @(),
        [AllowNull()][AllowEmptyCollection()][string[]]$Remediation = @(),
        [AllowNull()][System.Management.Automation.ErrorRecord]$Cause = $null
    )

    # Never retain arbitrary upstream exception object graphs in relayable diagnostics.
    $exception = [System.InvalidOperationException]::new($Message)
    $exception.Data['CapsulenvDiagnosticId'] = $Id
    if ($null -ne $Context) { $exception.Data['CapsulenvDiagnosticContext'] = $Context }
    if (@($Hints).Count -gt 0) { $exception.Data['CapsulenvDiagnosticHints'] = [string[]]@($Hints) }
    if (@($Remediation).Count -gt 0) { $exception.Data['CapsulenvDiagnosticRemediation'] = [string[]]@($Remediation) }
    if ($null -ne $Cause) {
        $causeMetadata = Get-CapsulenvDiagnosticCauseMetadata -ErrorRecord $Cause
        if (-not [string]::IsNullOrWhiteSpace([string]$causeMetadata.ErrorId)) { $exception.Data['CapsulenvDiagnosticCauseErrorId'] = [string]$causeMetadata.ErrorId }
        if (-not [string]::IsNullOrWhiteSpace([string]$causeMetadata.Type)) { $exception.Data['CapsulenvDiagnosticCauseType'] = [string]$causeMetadata.Type }
    }
    $record = [System.Management.Automation.ErrorRecord]::new($exception, $Id, $Category, $TargetObject)
    $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($Message)
    return $record
}

function Get-CapsulenvDiagnosticContext {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    if ($null -eq $ErrorRecord.Exception) { return $null }
    return $ErrorRecord.Exception.Data['CapsulenvDiagnosticContext']
}
function Get-CapsulenvDiagnosticHints {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    if ($null -eq $ErrorRecord.Exception) { return @() }
    $value = $ErrorRecord.Exception.Data['CapsulenvDiagnosticHints']
    if ($null -eq $value) { return @() }
    return [string[]]@($value)
}
function Get-CapsulenvDiagnosticRemediation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    if ($null -eq $ErrorRecord.Exception) { return @() }
    $value = $ErrorRecord.Exception.Data['CapsulenvDiagnosticRemediation']
    if ($null -eq $value) { return @() }
    return [string[]]@($value)
}
function ConvertTo-CapsulenvDiagnosticErrorRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Message,
        [System.Management.Automation.ErrorCategory]$Category = [System.Management.Automation.ErrorCategory]::InvalidOperation,
        [AllowNull()][object]$TargetObject = $null,
        [AllowNull()][System.Collections.IDictionary]$Context = $null,
        [AllowNull()][AllowEmptyCollection()][string[]]$Hints = @(),
        [AllowNull()][AllowEmptyCollection()][string[]]$Remediation = @()
    )
    if (Test-CapsulenvDiagnosticErrorRecord -ErrorRecord $ErrorRecord) { return $ErrorRecord }
    return New-CapsulenvDiagnosticErrorRecord -Id $Id -Message $Message -Category $Category -TargetObject $TargetObject -Context $Context -Hints $Hints -Remediation $Remediation -Cause $ErrorRecord
}
