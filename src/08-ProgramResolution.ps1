function New-CapsulenvProgramRequirement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ExactVersion,
        [string]$MinimumVersion,
        [string]$MaximumVersion,
        [string[]]$RequiredCapabilities = @(),
        [string[]]$AllowedProviders = @('host-scoop', 'capsulenv-local', 'seed', 'provider'),
        [string]$RelativePath,
        [string]$BinName,
        [string]$ShortcutName
    )

    if ($AllowedProviders.Count -eq 0) {
        throw 'Program requirements must allow at least one provider.'
    }
    return [pscustomobject][ordered]@{
        Name = $Name
        ExactVersion = $ExactVersion
        MinimumVersion = $MinimumVersion
        MaximumVersion = $MaximumVersion
        RequiredCapabilities = @($RequiredCapabilities | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        AllowedProviders = @($AllowedProviders | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
        RelativePath = $RelativePath
        BinName = $BinName
        ShortcutName = $ShortcutName
    }
}

function New-CapsulenvProgramCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Executable,
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [ValidateSet('host-scoop', 'capsulenv-local', 'seed', 'provider')]
        [string]$Provider,
        [string]$Scope,
        [string]$Version,
        [string[]]$Capabilities = @(),
        [bool]$Trusted = $true,
        [bool]$OwnsLifecycle = $false,
        [string]$Provenance
    )

    return [pscustomobject][ordered]@{
        Name = $Name
        Executable = $Executable
        Root = $Root
        Provider = $Provider.ToLowerInvariant()
        Scope = $Scope
        Version = $Version
        Capabilities = @($Capabilities | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        Trusted = $Trusted
        OwnsLifecycle = $OwnsLifecycle
        Provenance = if ([string]::IsNullOrWhiteSpace($Provenance)) { $Provider } else { $Provenance }
    }
}

function ConvertTo-CapsulenvProgramVersion {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return [version]::new(0, 0, 0, 0)
    }
    $normalized = $Version.Trim()
    if ($normalized.StartsWith('v', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(1)
    }
    $normalized = ($normalized -split '[-+]')[0]
    try {
        return [version]$normalized
    } catch {
        return [version]::new(0, 0, 0, 0)
    }
}

function Test-CapsulenvProgramCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Requirement,
        [Parameter(Mandatory = $true)]$Candidate
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    $name = [string]$Requirement.Name
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($name, [string]$Candidate.Name)) {
        $reasons.Add('name-mismatch')
    }
    $provider = [string]$Candidate.Provider
    $allowedProviders = @($Requirement.AllowedProviders | ForEach-Object { ([string]$_).ToLowerInvariant() })
    if ([string]::IsNullOrWhiteSpace($provider) -or $allowedProviders -notcontains $provider.ToLowerInvariant()) {
        $reasons.Add('provider-not-allowed')
    }
    if (-not [bool]$Candidate.Trusted) {
        $reasons.Add('provider-not-trusted')
    }
    if ([string]::IsNullOrWhiteSpace([string]$Candidate.Executable) -or
        -not (Test-Path -LiteralPath ([string]$Candidate.Executable) -PathType Leaf)) {
        $reasons.Add('executable-missing')
    }

    $candidateVersion = ConvertTo-CapsulenvProgramVersion -Version ([string]$Candidate.Version)
    if (-not [string]::IsNullOrWhiteSpace([string]$Requirement.ExactVersion)) {
        if ($candidateVersion -ne (ConvertTo-CapsulenvProgramVersion -Version ([string]$Requirement.ExactVersion))) {
            $reasons.Add('version-not-exact')
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Requirement.MinimumVersion) -and
        $candidateVersion -lt (ConvertTo-CapsulenvProgramVersion -Version ([string]$Requirement.MinimumVersion))) {
        $reasons.Add('below-minimum-version')
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Requirement.MaximumVersion) -and
        $candidateVersion -gt (ConvertTo-CapsulenvProgramVersion -Version ([string]$Requirement.MaximumVersion))) {
        $reasons.Add('above-maximum-version')
    }

    $capabilities = @($Candidate.Capabilities | ForEach-Object { ([string]$_).ToLowerInvariant() })
    foreach ($required in @($Requirement.RequiredCapabilities)) {
        if ($capabilities -notcontains ([string]$required).ToLowerInvariant()) {
            $reasons.Add('missing-capability:{0}' -f $required)
        }
    }
    return [pscustomobject][ordered]@{
        Compatible = ($reasons.Count -eq 0)
        Reasons = @($reasons.ToArray())
        Candidate = $Candidate
    }
}

function Resolve-CapsulenvProgram {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Requirement,
        [object[]]$Candidates = @()
    )

    $evaluated = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in @($Candidates)) {
        if ($null -eq $candidate) { continue }
        $check = Test-CapsulenvProgramCandidate -Requirement $Requirement -Candidate $candidate
        $evaluated.Add([pscustomobject][ordered]@{
            Candidate = $candidate
            Compatible = [bool]$check.Compatible
            Reasons = @($check.Reasons)
        })
    }
    $providerRank = @{
        'host-scoop' = 0
        'capsulenv-local' = 1
        'seed' = 2
        'provider' = 3
    }
    $selected = @($evaluated | Where-Object { $_.Compatible } | Sort-Object @{ Expression = { if ($providerRank.ContainsKey([string]$_.Candidate.Provider)) { $providerRank[[string]$_.Candidate.Provider] } else { 99 } } ; Ascending = $true }, @{ Expression = { ConvertTo-CapsulenvProgramVersion -Version ([string]$_.Candidate.Version) } ; Descending = $true }, @{ Expression = { [string]$_.Candidate.Executable } ; Ascending = $true } | Select-Object -First 1)
    return [pscustomobject][ordered]@{
        Requirement = $Requirement
        Succeeded = ($selected.Count -eq 1)
        Selected = if ($selected.Count -eq 1) { $selected[0].Candidate } else { $null }
        Candidates = @($evaluated)
        Diagnostics = if ($selected.Count -eq 1) {
            @('selected provider {0} from trusted resolution order' -f $selected[0].Candidate.Provider)
        } else {
            @('no compatible trusted program realization was found')
        }
    }
}

function Get-CapsulenvProgramCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Requirement
    )

    $candidates = New-Object System.Collections.Generic.List[object]
    $selectors = @(
        [pscustomobject]@{ Selector = 'scoop:user/{0}' -f $Requirement.Name; Provider = 'host-scoop'; Scope = 'user' },
        [pscustomobject]@{ Selector = 'scoop:global/{0}' -f $Requirement.Name; Provider = 'host-scoop'; Scope = 'global' },
        [pscustomobject]@{ Selector = 'capsule/{0}' -f $Requirement.Name; Provider = 'capsulenv-local'; Scope = 'capsule' }
    )
    foreach ($selector in $selectors) {
        $installed = Get-CapsulenvInstalledApp -Selector $selector.Selector -AllowMissing
        if ($null -eq $installed) { continue }
        try {
            $executable = Resolve-CapsulenvScoopAppExecutable -App $installed.Selector -RelativePath $Requirement.RelativePath -BinName $Requirement.BinName -ShortcutName $Requirement.ShortcutName
        } catch {
            continue
        }
        $provider = [string]$selector.Provider
        $candidates.Add((New-CapsulenvProgramCandidate -Name $Requirement.Name -Executable $executable -Root $installed.Current -Provider $provider -Scope ([string]$selector.Scope) -Version ([string]$installed.Manifest.version) -Trusted:$true -OwnsLifecycle:($provider -eq 'capsulenv-local') -Provenance ([string]$installed.Selector)))
    }
    return @($candidates.ToArray())
}

function Get-CapsulenvProgramResolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Requirement,
        [object[]]$Candidates
    )

    $available = if ($PSBoundParameters.ContainsKey('Candidates')) {
        @($Candidates)
    } else {
        @(Get-CapsulenvProgramCandidates -Requirement $Requirement)
    }
    return Resolve-CapsulenvProgram -Requirement $Requirement -Candidates $available
}

function Invoke-CapsulenvResolveCommand {
    [CmdletBinding()]
    param([string[]]$Arguments)

    $unknown = @($Arguments | Where-Object { $_ -like '--*' -and $_ -ne '--json' })
    $positionals = @($Arguments | Where-Object { $_ -notlike '--*' })
    if ($unknown.Count -gt 0 -or $positionals.Count -ne 1) {
        throw 'Usage: resolve <app> [--json]'
    }
    $requirement = New-CapsulenvProgramRequirement -Name ([string]$positionals[0])
    $resolution = Get-CapsulenvProgramResolution -Requirement $requirement
    if ($Arguments -contains '--json') {
        $resolution | ConvertTo-Json -Depth 8 | Write-Output
    } else {
        $resolution | Format-List
    }
    if ($resolution.Succeeded) {
        return $resolution.Selected.Executable
    }
}

##MOD_EXEC## Export-ModuleMember -Function New-CapsulenvProgramRequirement, New-CapsulenvProgramCandidate, Test-CapsulenvProgramCandidate, Resolve-CapsulenvProgram, Get-CapsulenvProgramCandidates, Get-CapsulenvProgramResolution
