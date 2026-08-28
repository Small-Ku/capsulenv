$script:CapsulenvDoctorCheckRegistry = [ordered]@{}

function New-CapsulenvDoctorResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Area,
        [ValidateSet('Healthy', 'Advisory', 'Unavailable', 'Failed', 'Skipped')][string]$Status = 'Healthy',
        [ValidateSet('Required', 'Optional')][string]$Importance = 'Required',
        [string]$Summary = '', [string]$Detail = '',
        [AllowNull()][AllowEmptyCollection()][string[]]$Remediation = @(),
        [AllowNull()][object]$Data = $null
    )
    return [pscustomobject][ordered]@{
        Id = $Id; Name = $Name; Area = $Area; Status = $Status
        Passed = ($Status -in @('Healthy', 'Skipped')); Importance = $Importance
        Summary = $Summary; Detail = $Detail; Remediation = [string[]]@($Remediation); Data = $Data
    }
}

function New-CapsulenvCheckResult {
    [CmdletBinding()]
    param(
        [string]$Name, [bool]$Passed, [string]$Detail,
        [ValidateSet('Required', 'Optional')][string]$Importance = 'Required',
        [string]$Area = 'Core', [string]$Id = 'Capsulenv.Doctor.Legacy'
    )
    $status = if ($Passed) { 'Healthy' } elseif ($Importance -eq 'Required') { 'Failed' } else { 'Advisory' }
    return New-CapsulenvDoctorResult -Id $Id -Name $Name -Area $Area -Status $status -Importance $Importance -Summary $Detail -Detail $Detail
}

function Register-CapsulenvDoctorCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Area,
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateSet('Required', 'Optional')][string]$Importance = 'Required',
        [Parameter(Mandatory = $true)][scriptblock]$Handler
    )
    if ($script:CapsulenvDoctorCheckRegistry.Contains($Id)) { throw "Duplicate Capsulenv doctor check id: $Id" }
    $script:CapsulenvDoctorCheckRegistry[$Id] = [pscustomobject][ordered]@{ Id=$Id; Area=$Area; Name=$Name; Importance=$Importance; Handler=$Handler }
}

function Invoke-CapsulenvDoctorChecks {
    [CmdletBinding()]
    param([string[]]$Ids = @())
    $selectedIds = if (@($Ids).Count -eq 0) { @($script:CapsulenvDoctorCheckRegistry.Keys) } else { @($Ids) }
    foreach ($id in $selectedIds) {
        if (-not $script:CapsulenvDoctorCheckRegistry.Contains($id)) { throw "Unknown Capsulenv doctor check id: $id" }
        $definition = $script:CapsulenvDoctorCheckRegistry[$id]
        try {
            $result = & $definition.Handler
            if ($null -eq $result) {
                New-CapsulenvDoctorResult -Id $definition.Id -Name $definition.Name -Area $definition.Area -Status Skipped -Importance $definition.Importance -Summary 'Check returned no result.'
                continue
            }
            foreach ($item in @($result)) {
                if ($null -eq $item.PSObject.Properties['Id']) { throw "Doctor check '$id' returned an invalid result without Id." }
                $item
            }
        } catch {
            $remediation = @(); $diagnosticId = ''
            if (Test-CapsulenvDiagnosticErrorRecord -ErrorRecord $_) {
                $diagnosticId = [string]$_.FullyQualifiedErrorId
                $remediation = @(Get-CapsulenvDiagnosticRemediation -ErrorRecord $_)
            }
            New-CapsulenvDoctorResult -Id $definition.Id -Name $definition.Name -Area $definition.Area -Status Failed -Importance $definition.Importance -Summary $_.Exception.Message -Detail $_.Exception.Message -Remediation $remediation -Data ([ordered]@{ DiagnosticId = $diagnosticId })
        }
    }
}
